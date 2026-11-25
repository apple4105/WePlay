import Foundation
import UIKit
import CryptoKit

/// 链路子系统总控——把所有模块串成完整管线。
///
/// ## 管线（数据流）
///
/// ```
/// ①  start()            → 身份装载 + 虚拟 accessory 启动
/// ②  transport.onData   → LinkParser 解 iAP2 包
///                        → MFi challenge（Authenticator 签名回）
///                        → startSession → MediaTCPListener 端口告知
/// ③  MediaTCPListener   → CarPlayMediaSession（视频+音频+触摸事件）
/// ④  视频帧             → RTPPacketizer → DisplaySource → 车机
/// ⑤  车机触摸           → InputServer → TouchRelay → HID report → processIncomingData
/// ```
///
/// ## 每一步的回调都汇到 Diagnostics
///
/// 任何一步出问题，诊断报告里都能看到最后停在哪一行。
/// SwiftUI 主页订阅的轻量状态桥——只在主线程写。
final class PipelineState: ObservableObject {
    static let shared = PipelineState()
    @Published var phaseText: String = "未启动"
    /// 车机要求配对码（主页据此弹输入框）
    @Published var pinRequired = false
    /// 需要用户手动加入车机 Wi-Fi（免费账号无 HotspotConfiguration entitlement）。
    /// 主页据此显示 SSID/密码卡片，用户去「设置 → Wi-Fi」连一次。
    @Published var manualJoin: ManualJoinInfo?
}

/// 手动加入车机 Wi-Fi 的凭证。
struct ManualJoinInfo {
    let ssid: String
    let psk: String
}

final class LinkController {
    static let shared = LinkController()


    // MARK: - 模块实例

    private(set) var identity: AccessoryIdentity?
    private(set) var authenticator: Authenticator?
    private(set) var transport: DirectAccessoryTransport!
    private(set) var linkParser: LinkParser!
    private(set) var bleBootstrap: LinkBootstrap!
    private(set) var wifiJoiner: WiFiJoiner!
    private(set) var displaySource: DisplaySource!
    private(set) var rtpPacketizer: RTPPacketizer!
    private(set) var mediaListener: MediaTCPListener!
    private(set) var touchRelay: TouchRelay!

    // MARK: - 状态

    /// 链路层发送/接收序列号（发包用 ACK 位 + 递增序列）
    private var txSequence: UInt8 = 0
    private var rxSequence: UInt8 = 0

    enum Phase: String, CaseIterable {
        case idle = "未启动"
        case identityLoaded = "身份已装载"
        case transportReady = "虚拟 accessory 就绪"
        case transportFailed = "虚拟 accessory 启动失败"
        case bleScanning = "正在搜索车机…"
        case carNotFound = "未发现车机（确认车机已开投屏）"
        case bleConnected = "BLE 已连车机"
        case wifiManualJoin = "等待手动加入车机 Wi-Fi"
        case wifiJoined = "已加入车机网络"
        case wfdNegotiating = "WFD 协商中"
        case carPlayActive = "CarPlay 已激活"
    }

    private(set) var phase: Phase = .idle {
        didSet {
            let text = phase.rawValue
            Diagnostics.shared.log("状态", "→ \(text)")
            // UI 直接同步——不依赖订阅时机，onAppear 前发生的状态迁移也能显示
            DispatchQueue.main.async { PipelineState.shared.phaseText = text }
            onPhaseChanged?(phase)
        }
    }

    var onPhaseChanged: ((Phase) -> Void)?

    // MARK: - 启动

    /// 完整启动序列（UI 打开时调）。**不发布虚拟 accessory**——
    /// 它只在"连接车机"期间存在，否则 iOS 里挂着幽灵 CarPlay 配件，
    /// OpenXPlay 等其他 CarPlay 会话会被顶掉（0.0.1-b51 实测教训）。
    func start() {
        let diag = Diagnostics.shared
        diag.log("管线", "════ 启动 ════")

        // ── M2: 身份 ──
        do {
            try loadIdentity()
        } catch {
            diag.error("身份", "\(error)")
            diag.error("管线", "身份装载失败，停止")
            return
        }

        // ── M4: 媒体监听提前起好，startSession 时端口已绑定 ──
        startMediaSession()
    }

    /// M2: 装载配件身份
    func loadIdentity(bundle: Bundle = .main) throws {
        let identity = try AccessoryIdentityStore.loadFromBundle(bundle: bundle)
        self.identity = identity
        self.authenticator = Authenticator(identity: identity)
        self.authenticator?.onLog = { Diagnostics.shared.log("认证", $0) }
        phase = .identityLoaded
        Diagnostics.shared.log("身份", "✅ 证书 \(identity.leafCertificate.count) B / 私钥 \(identity.privateKeyRaw.count) B")
        logEntitlements()
    }

    /// 打印签名 entitlements——用来确定 `NEHotspotConfiguration` 到底能不能用。
    ///
    /// b91 实测 `apply()` 返回 `NEHotspotConfigurationErrorDomain Code=8 "internal error."`：
    /// 按枚举 8 = invalidHS20Settings、14 = internal，两者矛盾，所以不能凭报错断言
    /// 是"缺 entitlement"。直接读 App 里嵌入的 provisioning profile 才是一手证据。
    private func logEntitlements() {
        let diag = Diagnostics.shared
        // ① 读 embedded.mobileprovision（AltStore 侧载时会嵌入），直接搜权限名
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            let text = String(decoding: data, as: UTF8.self)
            let hasHotspot = text.contains("com.apple.developer.networking.HotspotConfiguration")
            diag.log("签名", "embedded.mobileprovision \(data.count) B；含 HotspotConfiguration = \(hasHotspot)")
            // 顺带把 profile 里出现的 com.apple.developer.* 权限名列出来
            var found = Set<String>()
            var rest = Substring(text)
            while let r = rest.range(of: "com.apple.developer.") {
                var end = r.lowerBound
                while end < text.endIndex,
                      text[end].isLetter || text[end].isNumber || text[end] == "." || text[end] == "-" {
                    end = text.index(after: end)
                }
                found.insert(String(text[r.lowerBound..<end]))
                rest = text[end...]
            }
            diag.log("签名", "profile 里的 developer 权限：\(found.sorted().joined(separator: ", "))")
        } else {
            diag.log("签名", "没找到 embedded.mobileprovision（可能被移除或未签名嵌入）")
        }
    }

    /// M3: 启动虚拟 accessory（dlopen CoreAccessories → createConnection/Endpoint）
    private func startTransport() {
        let diag = Diagnostics.shared
        diag.log("管线", "── M3: 虚拟 accessory ──")

        transport = DirectAccessoryTransport()
        transport.identity = identity          // 供派生配件 MAC（identification 蓝牙组 + 连接 identifier）
        transport.onLog = { diag.log("传输", $0) }
        transport.onFailure = { [weak self] msg in
            diag.error("传输", msg)
            // 私有框架初始化失败是致命的——把失败也显示到状态卡上
            self?.phase = .transportFailed
        }
        transport.onReady = { [weak self] in
            guard let self else { return }
            // 防覆盖：onReady 异步晚到会把"搜索中"打回"就绪"，按钮变回启动导致二次触发
            // （0.0.1-b53 真机实锤）。状态只进不退。
            if self.phase == .identityLoaded || self.phase == .idle || self.phase == .transportFailed {
                self.phase = .transportReady
            } else {
                diag.log("管线", "虚拟 accessory 就绪（管线已推进，保持当前状态）")
            }
            diag.log("管线", "发送 presence，随后 SYN（等 iOS 的 SYN-ACK）")
            // CarWithin SameDeviceProbe：**先发 presence 包**，0.1 秒后再发 SYN。
            // 少了 presence，iOS 的 iAP2 栈可能直接不认这条链路。
            self.sendRaw(LinkPacket.presence)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.sendSYN()
            }
            // 兜底：2.5 秒内没等到 SYN-ACK（链路没进 Connected），仍发一次
            // identification——纯粹为了让日志能记录"我们尝试过"，不作为正常路径。
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, !self.identificationSent else { return }
                diag.warn("iAP2", "2.5 秒未收到 SYN-ACK（链路未进入 Connected）——仍尝试 identification 供诊断")
                self.sendIdentification()
            }
        }

        // LinkParser 解 iAP2 包，消息/原始数据都打日志
        linkParser = LinkParser()
        linkParser.onPacket = { [weak self] packet in
            guard let self else { return }
            // **相同包去重**：iOS 在对端没 ACK 时会原样重传（b91 里同一个 16B 包发了 17 次），
            // 逐条打印会瞬间冲满 500 条缓冲。相同包只计数，内容变化时才打。
            let sig = packet.encode()
            if sig == self.lastInboundSignature {
                self.repeatedInbound += 1
            } else {
                if self.repeatedInbound > 0 {
                    diag.log("iAP2", "（上一包重复 \(self.repeatedInbound) 次）")
                    self.repeatedInbound = 0
                }
                self.lastInboundSignature = sig
                diag.log("iAP2", "← 包 control=0x\(String(packet.control, radix: 16)) seq=\(packet.sequence) ack=\(packet.acknowledgement) payload=\(packet.payload.count)B")
            }
            self.rxSequence = packet.sequence
            self.handleLinkPacket(packet)
        }
        linkParser.onMessage = { [weak self] message in
            diag.log("iAP2", "← 消息 id=0x\(String(message.id, radix: 16)) 参数 \(message.parameters.count) 条")
            self?.handleMessage(message)
        }
        linkParser.onError = { diag.warn("iAP2", String(describing: $0)) }

        transport.onData = { [weak self] data in
            // 原始 hex 只在数据较短（控制/认证类）时记；视频心跳那种长包不记
            if data.count <= 64 { Diagnostics.shared.hex("传输", "← iPhone", data) }
            self?.linkParser.append(data)
        }
        transport.onFailure = { [weak self] msg in
            diag.error("传输", msg)
            // 私有框架初始化失败是致命的——把失败也显示到状态卡上
            self?.phase = .transportFailed
        }

        // 私有框架加载 + ObjC runtime 调用不能占主线程（dlopen 可能阻塞），
        // 放后台队列；回调里都有主线程跳转
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.transport.start()
        }
    }

    // MARK: - iAP2 链路层（SYN / SYN-ACK / ACK）

    /// 是否已发出 identification（防重复）
    private var identificationSent = false
    /// 链路是否已协商完成（收到 SYN-ACK 并回 ACK 之后）
    private var linkConnected = false

    /// 发送 SYN。
    ///
    /// **payload 必须是合法 SYN**（verx 规范 `iap2_link_establish/spec/03-syn-negotiation.md`）：
    /// - version=1 时载荷长度 = `10 + 3n`，**没有显式 n 字段**，条目数由长度推出
    /// - `n >= 1`（接收校验路径明确要求"至少一条特性条目"）
    /// - 每条 3 字节 `{id, type, second}`：`id != 0`、`type <= 4`、至少一条 `type == 0`
    ///
    /// 旧 payload 抄自 CarWithin 的 `[1,5,8,0,7,0xd0,0,0xfa,3,3,1,0,1]`：在 version=1 下
    /// 它把偏移 10 的字节当成第一条目的 id=0，**违反 `id != 0` 且不足 3 字节**——非法帧，
    /// iOS 直接丢弃，于是后面的 identification 无人应答（b77 实锤：presence 有回声、
    /// identification 零响应）。
    private func sendSYN() {
        // 固定头 10 字节：version, MOP, maxPacket(BE16), ackTimeout(BE16), cumAck(BE16), MR, MCA
        // 尾部 n 条特性条目，各 3 字节
        let synPayload = Data([
            1,            // version = 1
            8,            // MaxOutstandingPackets = 8（1..127）
            0xFF, 0xFF,   // maxPacketSize = 65535（> 23）
            0x03, 0xE8,   // ACK timeout = 1000 ms（> 19）
            0x00, 0x0A,   // CumAckTimeout = 10（10..32767）
            30,           // MaxRetransmissions = 30（1..30，缺省值）
            0,            // MaxCumAck = 0（0..MOP，缺省值）
            1, 0, 0,      // 条目 0：id=1, type=0（满足"至少一条 type==0"）, second=0
        ])
        Diagnostics.shared.log("iAP2", "→ SYN (\(synPayload.count) B，n=\((synPayload.count - 10) / 3))")
        let packet = LinkPacket(control: LinkPacket.controlSYN,
                                sequence: 0,
                                acknowledgement: 0,
                                sessionID: LinkPacket.controlSessionID,
                                payload: synPayload)
        sendRaw(packet.encode())
    }

    /// 处理链路层控制包：SYN-ACK / SYN / ACK。
    ///
    /// 状态机（`spec/05-state-machine.md`）：链路必须走到 **Connected** 才能发控制消息。
    /// 路径 `Idle → Pending（SYN/ACK 交换）→ Connected`。之前从不处理这些包，
    /// 链路永远停在 Pending，identification 自然没人理。
    private func handleLinkPacket(_ packet: LinkPacket) {
        let diag = Diagnostics.shared
        let isSYN = packet.control & LinkPacket.controlSYN != 0
        let isACK = packet.control & LinkPacket.controlACK != 0

        if isSYN && isACK {
            // 对端 SYN-ACK：回 ACK，链路进入 Connected，**然后**才发 identification
            diag.log("iAP2", "← SYN-ACK（seq=\(packet.sequence)）→ 回 ACK，链路 Connected")
            let ack = LinkPacket(control: LinkPacket.controlACK,
                                 sequence: 0,
                                 acknowledgement: packet.sequence,
                                 sessionID: LinkPacket.controlSessionID,
                                 payload: Data())
            sendRaw(ack.encode())
            markLinkConnected()
            return
        }
        if isSYN {
            // 对端先发 SYN：回 SYN-ACK（ACK 位 + 自己的 SYN payload）
            diag.log("iAP2", "← 对端 SYN（seq=\(packet.sequence)）→ 回 SYN-ACK")
            let synPayload = Data([1, 8, 0xFF, 0xFF, 0x03, 0xE8, 0x00, 0x0A, 30, 0, 1, 0, 0])
            let synack = LinkPacket(control: LinkPacket.controlSYN | LinkPacket.controlACK,
                                    sequence: 0,
                                    acknowledgement: packet.sequence,
                                    sessionID: LinkPacket.controlSessionID,
                                    payload: synPayload)
            sendRaw(synack.encode())
            markLinkConnected()
            return
        }
        if isACK {
            if packet.payload.isEmpty {
                diag.log("iAP2", "← ACK（ack=\(packet.acknowledgement)）")
            } else {
                // **收到数据包必须立刻回 ACK**，否则对端每秒重传（b91 实测：iOS 连发 17 次）。
                txSequence &+= 1
                let ack = LinkPacket(control: LinkPacket.controlACK,
                                     sequence: txSequence,
                                     acknowledgement: packet.sequence,
                                     sessionID: LinkPacket.controlSessionID,
                                     payload: Data())
                sendRaw(ack.encode())
                diag.log("iAP2", "← 数据包 seq=\(packet.sequence)（\(packet.payload.count) B）→ 已回 ACK")
            }
        }
    }

    /// 链路协商完成 → 发 identification（只发一次）
    private func markLinkConnected() {
        guard !linkConnected else { return }
        linkConnected = true
        sendIdentification()
    }

    private func sendIdentification() {
        guard !identificationSent, let transport else { return }
        identificationSent = true
        let name = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "CP-Receiver-1"
        let mac = transport.accessoryMAC
        let ident = AccessoryMessages.identification(name: name, mac: mac)
        Diagnostics.shared.log("iAP2", "→ identification (0x1D01)，\(ident.parameters.count) 参数，MAC=\(mac)")
        send(message: ident)
    }

    // MARK: - iAP2 消息收发

    /// 链路层发包：ACK 位 + 递增序列 + 对端确认号
    private func send(message: LinkMessage) {
        txSequence &+= 1
        let packet = LinkPacket(control: LinkPacket.controlACK,
                                sequence: txSequence,
                                acknowledgement: rxSequence,
                                sessionID: LinkPacket.controlSessionID,
                                payload: message.encoded())
        sendRaw(packet.encode())
    }

    private func sendRaw(_ data: Data) {
        transport.sendToPhone(data)
    }

    /// iPhone → 配件的消息分发（MFi 认证等）。
    /// 认证子参数 ID 按公开 iAP2 规范；真机第一轮对不上时靠诊断日志的 hex 校准。
    private func handleMessage(_ message: LinkMessage) {
        let diag = Diagnostics.shared
        for p in message.parameters {
            diag.hex("iAP2", "参数 0x\(String(p.id, radix: 16))", p.value)
        }

        switch message.id {
        // ── iAP2 标准认证消息族（0xAA00..0xAA05）──────────────
        case 0xAA00:
            // AuthenticationInformation：对端告知支持的认证方式 → 回我们的证书
            diag.log("认证", "← AuthenticationInformation (0xAA00) → 发送配件证书")
            if let cert = identity?.leafCertificate, !cert.isEmpty {
                send(message: AccessoryMessages.authenticationCertificate(chain: cert))
            } else {
                diag.warn("认证", "0xAA00 但身份未装载")
            }
        case 0xAA02:
            diag.log("认证", "← AuthenticationChallenge (0xAA02)")
            if let challenge = message.parameter(0x000D)?.value
                ?? message.parameters.first?.value, let authenticator {
                do {
                    let resp = try authenticator.respond(toChallenge: challenge)
                    diag.log("认证", "challenge 已签名（\(resp.signature.count) B）→ 0xAA03")
                    send(message: LinkMessage(id: 0xAA03, parameters: [
                        LinkParameter(id: 0x000E, value: resp.signature)
                    ]))
                } catch { diag.error("认证", "签名失败：\(error)") }
            } else {
                diag.warn("认证", "0xAA02 缺少挑战数据或身份未装载")
            }
        case 0xAA04:
            diag.log("认证", "← AuthenticationStatus (0xAA04)：\(message.parameters.first?.uintValue() ?? 0)")
        case 0x0022:   // AuthenticationChallenge
            guard let challenge = message.parameter(0x000D)?.value, let authenticator else {
                diag.warn("认证", "challenge 消息但缺少 0x000D 参数或身份未装载")
                return
            }
            do {
                let response = try authenticator.respond(toChallenge: challenge)
                diag.log("认证", "challenge 已签名（\(response.signature.count) B）→ 0x0023")
                send(message: AccessoryMessages.authenticationResponse(signature: response.signature))
            } catch {
                diag.error("认证", "签名失败：\(error)")
            }
        case 0x0024:   // AuthenticationFailed
            diag.error("认证", "iPhone 拒绝认证：\(message.parameter(0x000C)?.uintValue() ?? 0)")
        default:
            break
        }
    }

    // MARK: - M5: BLE → WiFi → WFD（含断线恢复）

    /// BLE 最近一次拿到的车机凭证。断线重连时优先用它跳过 BLE 扫描；
    /// 车机 SSID/PSK 长期稳定（车主实测），WFD 反复失败才降级重扫。
    private var cachedReply: Link.HeadUnitReply?

    /// WFD 连续失败计数（连接成功即清零）
    private var wfdRetry = 0
    private let wfdMaxRetry = 3
    /// WFD 重试退避（秒）
    private let wfdBackoff = [1, 2, 4]

    /// BLE 扫描超时任务
    private var bleTimeout: DispatchWorkItem?

    /// 链路内部错误（统一进恢复入口）
    private enum PipelineError: Error, CustomStringConvertible {
        case mediaDisconnected
        var description: String { "媒体连接断开" }
    }

    /// UI 的"连接车机"按钮。有缓存凭证时跳过 BLE 直连，失败自动降级重扫。
    func connectToCar() {
        let diag = Diagnostics.shared
        diag.log("管线", "── 连接车机 ──")
        wfdRetry = 0

        // 防重入：已在扫描/等回复时重复按 = 忽略（0.0.1-b53 真机教训：
        // 双击创建两个并行 GATT 客户端，车机懵了不回凭证）
        if bleBootstrap != nil, phase == .bleScanning || phase == .bleConnected {
            diag.log("管线", "已在扫描/等回复中，忽略重复触发")
            return
        }

        // 虚拟 accessory 只在连接期间存在（避免幽灵配件顶掉其他 CarPlay 会话）
        if transport == nil {
            startTransport()
        }

        // 上次 stop 可能停掉了媒体监听，重新起一个（端口随 startSession 通告给 iPhone）
        startMediaSession()

        if let reply = cachedReply {
            diag.log("管线", "有缓存凭证（SSID=\(reply.ssid)），跳过 BLE 直连")
            phase = .bleConnected
            joinCarWiFi(reply)
            return
        }
        scanBLE()
    }

    /// BLE 扫描拿凭证。12 秒扫不到广播 = 车机不在附近（熄火/未开投屏），停止。
    private func scanBLE() {
        let diag = Diagnostics.shared

        bleBootstrap = LinkBootstrap()
        // Client Info 的身份字段：真实手机发的是
        //   id = 6 位十六进制、mac = 本地管理单播地址、manufactures = "Xiaomi"
        // （依据 ft-app `IccoaClientProfile.kt`，注释写明是给 UCAR 车机的兼容身份）
        let mac = transport?.accessoryMAC ?? "02:00:00:00:00:00"
        bleBootstrap.accessoryMAC = mac
        let digest = SHA256.hash(data: identity?.leafCertificate ?? Data())
        bleBootstrap.clientID = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        // 重连时沿用本次会话已输入的配对码（车机码约 120 秒刷新，会话内复用）
        if let pin = savedPin { bleBootstrap.submitPinCode(pin) }
        bleBootstrap.onLog = { diag.log("BLE", $0) }
        bleBootstrap.onFailure = { diag.error("BLE", String(describing: $0)) }
        bleBootstrap.onCredentials = { [weak self] reply in
            guard let self else { return }
            self.bleTimeout?.cancel()
            self.bleTimeout = nil
            diag.log("BLE", "✅ 凭证到手 SSID=\(reply.ssid) freq=\(reply.freq) port=\(reply.port)")
            self.cachedReply = reply
            self.phase = .bleConnected
            self.joinCarWiFi(reply)
        }
        // 配对码由 UI 输入后调 bleBootstrap.submitPinCode(_:)
        bleBootstrap.onPinCodeRequired = { code in
            diag.log("BLE", "车机要求配对码——请查看车机屏幕上的 6 位数字并输入")
            DispatchQueue.main.async { PipelineState.shared.pinRequired = true }
            _ = code
        }

        let foreground = UIApplication.shared.applicationState == .active

        // 车机连上后：取消"未发现"超时，换成 20 秒"等凭证回复"超时（仅前台；
        // 后台自动发现模式不限时——它就是"车机要连了自动唤醒"的机制本身）
        bleBootstrap.onConnected = { [weak self] in
            guard let self else { return }
            self.bleTimeout?.cancel()
            guard foreground else {
                diag.log("BLE", "后台自动发现：车机已连上，等待凭证（不限时）")
                return
            }
            diag.log("BLE", "车机已连上，等待凭证回复（最长 20 秒）")
            let replyTimeout = DispatchWorkItem { [weak self] in
                guard let self, self.cachedReply == nil,
                      self.phase == .bleScanning || self.phase == .bleConnected else { return }
                diag.warn("BLE", "20 秒未收到凭证回复。请看上面三行定性：①『写特征成功』= 车机收到了但不回 → 车机侧策略/身份问题；②『写入 8 秒未确认』或『写特征失败』= 车机 GATT 没收下（MTU/CCCD/栈忙）；③只有 PhoneRequest 没有后续 = 请求根本没发出去")
                diag.log("管线", "确认车机 CarLink 状态后，再按「连接车机」重试")
                self.bleBootstrap?.stop()
                self.bleBootstrap = nil
                self.phase = .carNotFound
            }
            self.bleTimeout = replyTimeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: replyTimeout)
        }

        bleBootstrap.startScanning()
        phase = .bleScanning

        // 后台模式不设发现超时（车机随时可能开 ICCOA；发现即唤醒）
        guard foreground else { return }

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.cachedReply == nil, self.phase == .bleScanning else { return }
            let seen = self.bleBootstrap?.scannedDeviceCount ?? 0
            diag.warn("BLE", "12 秒未发现车机广播（本轮见到 \(seen) 个 BLE 设备，均不带 ICCOA 服务/名称）——车机可能不在附近（熄火/未开投屏）")
            diag.log("管线", "停止扫描。车机就绪后再按「连接车机」")
            self.bleBootstrap?.stop()
            self.bleBootstrap = nil
            self.phase = .carNotFound
        }
        bleTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }

    /// 用户在扫描过程中按"停止"：取消扫描与超时，回到就绪待机。
    func stopScan() {
        bleTimeout?.cancel()
        bleTimeout = nil
        bleBootstrap?.stop()
        bleBootstrap = nil
        phase = .transportReady
        Diagnostics.shared.log("管线", "已停止扫描")
    }

    /// 加入车机网络。NEHotspot 失败自动重试一次；系统对记住的网络通常会自己回连。
    private func joinCarWiFi(_ reply: Link.HeadUnitReply) {
        let diag = Diagnostics.shared
        wifiJoiner = WiFiJoiner()
        wifiJoiner.onLog = { diag.log("WiFi", $0) }
        // 只在"用户拒绝系统弹窗"这类可重试的情况下重试；权限缺失类错误走手动，不重试
        wifiJoiner.onFailure = { error in
            diag.error("WiFi", String(describing: error))
            diag.log("WiFi", "自动加入失败，请按主页卡片手动加入网络后按「连接车机」")
        }
        wifiJoiner.onJoined = { [weak self] ssid in
            guard let self else { return }
            DispatchQueue.main.async { PipelineState.shared.manualJoin = nil }
            self.phase = .wifiJoined
            diag.log("管线", "已加入车机网络 \(ssid)")
            self.startWFD(reply)
        }
        wifiJoiner.onManualJoinRequired = { [weak self] (ssid, psk) in
            diag.warn("WiFi", "需要手动加入：SSID=\(ssid) 密码=\(psk)")
            // 免费账号没有 HotspotConfiguration entitlement → 只能手动加。
            // 把凭证推到主页卡片（可复制），用户连好后按「连接车机」走缓存凭证直连。
            DispatchQueue.main.async {
                self?.phase = .wifiManualJoin
                PipelineState.shared.manualJoin = ManualJoinInfo(ssid: ssid, psk: psk)
            }
        }
        wifiJoiner.join(ssid: reply.ssid, psk: reply.psk)
    }

    /// Carlink 会话（认证 + 服务端口编排）。RTSP 由车机拨入后交给 DisplaySource。
    private var carlinkSession: CarlinkSession?

    /// 上一包签名与其连续重复次数（用于压掉重传刷屏）
    private var lastInboundSignature: Data?
    private var repeatedInbound = 0

    /// 本次会话输入的 6 位配对码（重连时复用）
    private var savedPin: String?

    /// 后台自动发现拿到凭证后置位——App 打开时自动续连（用户点通知即可）
    var autoConnectPending = false
    /// CarPlay 媒体管道（iPhone 回环 → RTP → 车机），WFD 就绪后创建
    private var mediaPipe: CarPlayMediaPipe?
    /// WFD 就绪前已拨入的媒体连接（管道建好后补挂）
    private var pendingMediaConnections: [MediaTCPConnection] = []
    /// "返回车机"手势（左上角长按 1.5s）
    private let returnGesture = ReturnGesture()

    /// 加入车机网络后启动 Carlink 会话（认证 → 车机拨入 RTSP → WFD 协商）。
    /// 失败由统一恢复入口按指数退避重试。
    private func startWFD(_ reply: Link.HeadUnitReply) {
        let diag = Diagnostics.shared
        diag.log("管线", "── Carlink 会话 ──")
        carlinkSession?.stop()

        // BLE 只给了 MAC/端口；车机 IP 用网关推断（快捷指令路径 wifiJoiner 为空 → 静态方法）
        let host = WiFiJoiner.guessGatewayIPv4() ?? "192.168.43.1"
        let localIP = WiFiJoiner.currentLocalIPv4() ?? "192.168.43.2"
        diag.log("管线", "车机 \(host) / 本机 \(localIP)（MAC=\(reply.mac)）")

        do {
            let identity = try CarlinkTrustStore.shared.loadOrCreateIdentity()
            let session = CarlinkSession(headUnitIP: host, localIP: localIP,
                                         identity: identity, trust: .shared, pin: nil)
            carlinkSession = session
            session.onLog = { diag.log("Carlink", $0) }
            session.onState = { st in
                diag.log("Carlink", "→ \(st.rawValue)")
            }
            session.onPinRequired = {
                diag.warn("Carlink", "车机要求配对码")
                PipelineState.shared.pinRequired = true
            }
            session.onError = { [weak self] error in
                diag.error("Carlink", "\(error)")
                self?.handleLinkFailure(error)
            }
            session.onRtspAccepted = { [weak self] transport in
                diag.log("管线", "车机已拨入 RTSP → 启动 WFD 协商")
                self?.startDisplay(with: transport, host: host)
            }
            session.onUibcData = { [weak self] data in
                Diagnostics.shared.hex("UIBC", "← 车机触摸", data)
                self?.handleUibc(data)
            }
            session.start()
        } catch {
            diag.error("Carlink", "启动失败：\(error)")
            handleLinkFailure(error)
        }
    }

    /// 车机拨入 RTSP 后，用该连接跑 WFD M1-M5；就绪后发 iAP2 startSession
    private func startDisplay(with transport: DisplayTransport, host: String) {
        let diag = Diagnostics.shared
        displaySource = DisplaySource()
        displaySource.onLog = { diag.log("WFD", $0) }
        displaySource.onFailure = { [weak self] error in
            self?.handleLinkFailure(error)
        }
        displaySource.onDisplayMode = { mode in
            diag.log("WFD", "车机声明 display=\(mode.width)×\(mode.height) dpi=\(mode.dpi) fps=\(mode.fps)")
            // 把车机的分辨率/帧率告诉 CarPlay（iAP2 identification 时用）
        }
        displaySource.onReady = { [weak self] session in
            guard let self else { return }
            self.wfdRetry = 0
            self.phase = .wfdNegotiating
            diag.log("管线", "WFD 会话已建立 → 等待 CarPlay 数据")

            // 媒体管道：iPhone 回环 TCP → H.264 → RTP → 车机声明的 RTP 端口
            let rtpPort = self.displaySource?.sinkRTPPort ?? UInt16(19000)
            let pipe = CarPlayMediaPipe(targetHost: host, targetPort: rtpPort) {
                diag.log("媒体", $0)
            }
            self.mediaPipe = pipe
            for conn in self.pendingMediaConnections {
                pipe.attach(conn)
            }
            self.pendingMediaConnections.removeAll()
            diag.log("管线", "媒体管道就绪（RTP → \(host):\(rtpPort)）")
            self.sendStartSession()
        }
        // 窗口模式：不请求全屏（保留车机"返回车机"入口的基础）
        displaySource.connect(host: host, port: CarlinkSession.Ports.rtsp, transport: transport)
    }

    // MARK: - UIBC（车机触摸 → iPhone HID）+ 返回车机手势

    private func handleUibc(_ data: Data) {
        for touch in UIBCTouch.parse(data) {
            // 左上角长按 1.5s = 返回车机（teardown 投屏，保留 accessory/凭证）
            returnGesture.handle(touch) { [weak self] in
                Diagnostics.shared.log("管线", "返回车机手势命中——teardown 投屏")
                self?.teardownProjection()
            }
            // 触摸透传给 iPhone CarPlay（HID report）
            touchRelay?.handleTouch(phase: touch.phase.rawValue,
                                    normalizedX: touch.x,
                                    normalizedY: touch.y)
        }
    }

    /// 结束投屏（销毁虚拟 accessory，保留凭证缓存——再按连接可直接重连）
    func teardownProjection() {
        carlinkSession?.stop()
        carlinkSession = nil
        displaySource?.stop()
        mediaPipe?.stop()
        mediaPipe = nil
        transport?.stop()
        transport = nil
        returnGesture.reset()
        phase = .wifiJoined
    }

    /// UI 配对码输入 → Carlink 认证续跑
    func submitPin(_ code: String) {
        Diagnostics.shared.log("配对码", "用户输入（\(code.count) 位）")
        // BLE 首次配对阶段要用（Client Info 的 pinCodeOrAuthentication）；
        // Carlink 认证阶段也要用，两条路都喂一遍。
        bleBootstrap?.submitPinCode(code)
        carlinkSession?.submitPin(code)
        savedPin = code
        PipelineState.shared.pinRequired = false
    }

    /// 快捷指令/自动化入口（可能后台执行）：
    /// 有缓存凭证 → 直接 Carlink（Wi-Fi 自动化触发时 iPhone 已在 DIRECT 网内）；
    /// 没有 → 走 BLE（后台服务过滤扫描会自动发现车机）。
    @discardableResult
    func connectFromShortcut() -> Bool {
        if let reply = cachedReply {
            Diagnostics.shared.log("管线", "快捷指令：缓存凭证 SSID=\(reply.ssid) 直连 Carlink")
            phase = .bleConnected
            startWFD(reply)
            return true
        }
        Diagnostics.shared.log("管线", "快捷指令：无缓存凭证，走 BLE 扫描")
        connectToCar()
        return false
    }

    /// WFD 就绪后把媒体会话指向本机 MediaTCPListener（同机回环）
    private func sendStartSession() {
        let diag = Diagnostics.shared
        let port = mediaListener?.port ?? 0
        guard port != 0 else {
            diag.error("管线", "媒体监听端口未就绪，无法发 startSession")
            return
        }
        // CarWithin startSession：param 3 = deviceID（MAC 形串，与 identification 一致）
        let deviceID = transport?.accessoryMAC ?? "02:00:00:00:00:01"
        let ss = AccessoryMessages.startSession(address: "127.0.0.1", port: port, deviceID: deviceID)
        diag.log("iAP2", "→ startSession (0x4301) 127.0.0.1:\(port)")
        send(message: ss)
    }

    // MARK: - 断线恢复

    /// 链路断开的统一入口。策略（不依赖真机，真机联调再校准车机侧行为）：
    /// - WFD/媒体断（Wi-Fi 一般还在）→ 退避重试 RTSP（1s/2s/4s），状态回退到 wifiJoined/wfdNegotiating
    /// - 3 次仍失败 → 清凭证缓存，降级重扫 BLE（车机可能重启换了端口）
    /// - 用户已按停止（phase == .idle）→ 在途重试自动放弃
    private func handleLinkFailure(_ error: Error) {
        let diag = Diagnostics.shared
        let wasActive = (phase == .carPlayActive)
        diag.warn("管线", "链路断开（\(wasActive ? "投屏中" : "协商中")）：\(error)")

        guard phase != .idle, let reply = cachedReply else {
            diag.error("管线", "无缓存凭证且链路已断，请手动重连")
            return
        }

        if wfdRetry >= wfdMaxRetry {
            diag.error("管线", "WFD 重试 \(wfdRetry) 次仍失败——清凭证缓存，降级重扫 BLE")
            cachedReply = nil
            wfdRetry = 0
            phase = .transportReady
            displaySource?.stop()
            scanBLE()
            return
        }

        let delay = wfdBackoff[min(wfdRetry, wfdBackoff.count - 1)]
        wfdRetry += 1
        phase = wasActive ? .wfdNegotiating : .wifiJoined
        diag.log("管线", "\(wfdRetry)/\(wfdMaxRetry) 次重试 WFD，\(delay) 秒后")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self, self.phase != .idle else { return }
            self.displaySource?.stop()
            self.startWFD(reply)
        }
    }

    // MARK: - M4: CarPlay 媒体会话

    /// CarPlay 栈连入媒体端口后建立会话。
    /// 连入 = 投屏真正激活（phase → carPlayActive）；关闭 = 进断线恢复。
    func startMediaSession() {
        let diag = Diagnostics.shared
        diag.log("管线", "── M4: 媒体会话 ──")

        mediaListener?.stop()   // 重建前先 cancel 旧的，避免端口泄漏
        mediaListener = MediaTCPListener()
        mediaListener.onLog = { diag.log("媒体", $0) }
        mediaListener.onError = { diag.error("媒体", String(describing: $0)) }
        mediaListener.onConnection = { [weak self] conn in
            diag.log("媒体", "iPhone 已连入媒体端口 \(conn.peerAddress)")
            self?.phase = .carPlayActive
            diag.log("管线", "CarPlay 媒体通道建立——投屏激活")

            // 媒体管道就绪就挂上，否则暂存（WFD 就绪后补挂）
            if let pipe = self?.mediaPipe {
                pipe.attach(conn)
            } else {
                self?.pendingMediaConnections.append(conn)
            }

            conn.onClose = { [weak self] in
                diag.warn("媒体", "媒体连接关闭")
                self?.handleLinkFailure(PipelineError.mediaDisconnected)
            }

            // 触摸回传
            self?.touchRelay = TouchRelay()
            self?.touchRelay.onTouchReport = { [weak self] report in
                diag.hex("触摸", "HID report", report)
                // 发回 iPhone：transport.sendToPhone(report)
                self?.transport?.sendToPhone(report)
            }
        }
        mediaListener.start(port: 0)
    }

    // MARK: - 停止

    /// 用户主动断开。注意 **不停 transport**（虚拟 accessory 保持就绪，
    /// 下次连接不用重建端点）；车机凭证缓存也保留，重连可跳过 BLE。
    func stop() {
        bleTimeout?.cancel()
        bleTimeout = nil
        wfdRetry = 0
        bleBootstrap?.stop()
        carlinkSession?.stop()
        carlinkSession = nil
        displaySource?.stop()
        mediaPipe?.stop()
        mediaPipe = nil
        pendingMediaConnections.removeAll()
        mediaListener?.stop()
        // 销毁虚拟 accessory——否则 iOS 里挂着幽灵 CarPlay 配件，
        // OpenXPlay 等其他 CarPlay 会话会被顶掉（0.0.1-b51 实测教训）
        transport?.stop()
        transport = nil
        // 链路层状态一并复位，否则下次点「启动」不会重新发 SYN/identification
        linkConnected = false
        identificationSent = false
        savedPin = nil
        txSequence = 0
        rxSequence = 0
        PipelineState.shared.pinRequired = false
        phase = .idle
        Diagnostics.shared.log("管线", "已停止（保留车机凭证缓存）")
    }
}

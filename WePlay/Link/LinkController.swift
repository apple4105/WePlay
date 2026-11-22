import Foundation
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
    }

    /// M3: 启动虚拟 accessory（dlopen CoreAccessories → createConnection/Endpoint）
    private func startTransport() {
        let diag = Diagnostics.shared
        diag.log("管线", "── M3: 虚拟 accessory ──")

        transport = DirectAccessoryTransport()
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
            diag.log("管线", "发送 SYN + identification")
            // 控制会话先同步（SYN），再报身份
            self.sendRaw(LinkPacket(control: LinkPacket.controlSYN, sequence: 0,
                                    sessionID: LinkPacket.controlSessionID).encode())
            let name = (Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String) ?? "CP-Receiver-1"
            let certData = self.identity?.leafCertificate ?? Data()
            let deviceID = SHA256.hash(data: certData).prefix(8)
                .map { String(format: "%02X", $0) }.joined()
            let ident = AccessoryMessages.identification(name: name, deviceID: deviceID)
            diag.log("iAP2", "→ identification (0x1D01)，\(ident.parameters.count) 参数")
            self.send(message: ident)
        }

        // LinkParser 解 iAP2 包，消息/原始数据都打日志
        linkParser = LinkParser()
        linkParser.onPacket = { [weak self] packet in
            guard let self else { return }
            Diagnostics.shared.hex("iAP2", "包", packet.encode())
            self.rxSequence = packet.sequence
        }
        linkParser.onMessage = { [weak self] message in
            diag.log("iAP2", "← 消息 id=0x\(String(message.id, radix: 16)) 参数 \(message.parameters.count) 条")
            self?.handleMessage(message)
        }
        linkParser.onError = { diag.warn("iAP2", String(describing: $0)) }

        transport.onData = { [weak self] data in
            Diagnostics.shared.hex("传输", "← iPhone", data)
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
            diag.log("BLE", "车机请求配对码：\(code)（请在车机屏幕查看后输入）")
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
                diag.warn("BLE", "20 秒未收到凭证回复——请求已发出但车机未应答")
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
            diag.warn("BLE", "12 秒未发现车机广播——车机可能不在附近（熄火/未开投屏），或广播不带 ICCOA 服务（看诊断里『周围设备』清单）")
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
        wifiJoiner.onFailure = { [weak self] error in
            diag.error("WiFi", String(describing: error))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.phase != .idle else { return }
                diag.log("WiFi", "3 秒后重试加入 \(reply.ssid)")
                self.wifiJoiner?.join(ssid: reply.ssid, psk: reply.psk)
            }
        }
        wifiJoiner.onJoined = { [weak self] ssid in
            guard let self else { return }
            self.phase = .wifiJoined
            diag.log("管线", "已加入车机网络 \(ssid)")
            self.startWFD(reply)
        }
        wifiJoiner.onManualJoinRequired = { (ssid, psk) in
            diag.warn("WiFi", "需要手动加入：SSID=\(ssid) 密码=\(psk)")
            diag.log("管线", "请在 设置→Wi-Fi 里连接 \(ssid)，然后回到 App 再按「连接车机」（凭证已缓存，会直连）")
            // 手动模式下不自动继续：用户连好后再按连接，走缓存凭证 → join 立即成功 → WFD
        }
        wifiJoiner.join(ssid: reply.ssid, psk: reply.psk)
    }

    /// Carlink 会话（认证 + 服务端口编排）。RTSP 由车机拨入后交给 DisplaySource。
    private var carlinkSession: CarlinkSession?

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

        // BLE 只给了 MAC/端口；车机 IP 用网关推断
        let host = wifiJoiner?.guessGatewayIPv4() ?? "192.168.43.1"
        let localIP = wifiJoiner?.currentLocalIPv4() ?? "192.168.43.2"
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
        Diagnostics.shared.log("Carlink", "用户输入配对码（\(code.count) 位）")
        carlinkSession?.submitPin(code)
        PipelineState.shared.pinRequired = false
    }

    /// WFD 就绪后把媒体会话指向本机 MediaTCPListener（同机回环）
    private func sendStartSession() {
        let diag = Diagnostics.shared
        let port = mediaListener?.port ?? 0
        guard port != 0 else {
            diag.error("管线", "媒体监听端口未就绪，无法发 startSession")
            return
        }
        let deviceID = SHA256.hash(data: identity?.leafCertificate ?? Data()).prefix(8)
            .map { String(format: "%02X", $0) }.joined()
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
        PipelineState.shared.pinRequired = false
        phase = .idle
        Diagnostics.shared.log("管线", "已停止（保留车机凭证缓存）")
    }
}

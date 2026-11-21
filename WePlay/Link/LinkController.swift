import Foundation

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
/// SwiftUI 主页订阅的轻量状态桥——只在主线程写 phaseText。
final class PipelineState: ObservableObject {
    static let shared = PipelineState()
    @Published var phaseText: String = "未启动"
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

    enum Phase: String, CaseIterable {
        case idle = "未启动"
        case identityLoaded = "身份已装载"
        case transportReady = "虚拟 accessory 就绪"
        case bleConnected = "BLE 已连车机"
        case wifiJoined = "已加入车机网络"
        case wfdNegotiating = "WFD 协商中"
        case carPlayActive = "CarPlay 已激活"
    }

    private(set) var phase: Phase = .idle {
        didSet {
            Diagnostics.shared.log("状态", "→ \(phase.rawValue)")
            onPhaseChanged?(phase)
        }
    }

    var onPhaseChanged: ((Phase) -> Void)?

    // MARK: - 启动

    /// 完整启动序列（UI 的"开始"按钮调这个）
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

        // ── M3: 虚拟 accessory ──
        startTransport()
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
        transport.onFailure = { msg in
            diag.error("传输", msg)
        }
        transport.onReady = { [weak self] in
            guard let self else { return }
            self.phase = .transportReady
            diag.log("管线", "虚拟 accessory 就绪，等待 iPhone CarPlay 接入")
            self.startLinkParser()
        }

        // LinkParser 解 iAP2 包，消息/原始数据都打日志
        linkParser = LinkParser()
        linkParser.onPacket = { packet in
            Diagnostics.shared.hex("iAP2", "包", packet.encode())
            // M2: MFi challenge 处理——真机确认具体消息 ID 后在这里分发
        }
        linkParser.onMessage = { message in
            diag.log("iAP2", "消息 id=0x\(String(message.id, radix: 16)) 参数 \(message.parameters.count) 条")
            // M2: 如果消息里有 challenge → authenticator.respond(toChallenge:) → 构造回消息
        }
        linkParser.onError = { diag.warn("iAP2", String(describing: $0)) }

        transport.onData = { [weak self] data in
            Diagnostics.shared.hex("传输", "← iPhone", data)
            self?.linkParser.append(data)
        }
        transport.onFailure = { msg in
            diag.error("传输", msg)
        }

        transport.start()
    }

    /// 收到 iPhone 数据后走这里（LinkParser 的回调链）
    private func startLinkParser() {
        // 由 startTransport 里启动——此处是消息层处理（M2 challenge 等）
    }

    // MARK: - M5: BLE → WiFi → WFD

    /// BLE 扫描车机 + 拿凭证 + 加入网络 + WFD 协商（由外部触发——UI"连接车机"按钮）
    func connectToCar() {
        let diag = Diagnostics.shared
        diag.log("管线", "── M5: 连接车机 ──")

        bleBootstrap = LinkBootstrap()
        bleBootstrap.onLog = { diag.log("BLE", $0) }
        bleBootstrap.onFailure = { diag.error("BLE", String(describing: $0)) }
        bleBootstrap.onCredentials = { [weak self] reply in
            guard let self else { return }
            diag.log("BLE", "✅ 凭证到手 SSID=\(reply.ssid) freq=\(reply.freq) port=\(reply.port)")
            self.phase = .bleConnected

            // 加入车机网络
            self.wifiJoiner = WiFiJoiner()
            self.wifiJoiner.onLog = { diag.log("WiFi", $0) }
            self.wifiJoiner.onFailure = { diag.error("WiFi", String(describing: $0)) }
            self.wifiJoiner.onJoined = { [weak self] ssid in
                guard let self else { return }
                self.phase = .wifiJoined
                diag.log("管线", "已加入车机网络 \(ssid)")
                // BLE 只给了 MAC/端口；RTSP 在车机（AP 网关）上，IP 用网关推断
                let host = self.wifiJoiner.guessGatewayIPv4() ?? "192.168.43.1"
                diag.log("管线", "车机 IP 推断为 \(host)（MAC=\(reply.mac)）")
                self.startWFD(host: host, port: UInt16(reply.port))
            }
            self.wifiJoiner.onManualJoinRequired = { (ssid, psk) in
                diag.warn("WiFi", "需要手动加入：SSID=\(ssid) 密码=\(psk)")
                diag.log("管线", "请在 设置→Wi-Fi 里连接 \(ssid)，然后回到 App")
                self.phase = .wifiJoined
                // 手动加入后无法监听系统回调——用户告知已连上后调 startWFD
            }
            self.wifiJoiner.join(ssid: reply.ssid, psk: reply.psk)
        }

        // 配对码由 UI 输入后调 bleBootstrap.submitPinCode(_:)
        bleBootstrap.onPinCodeRequired = { code in
            diag.log("BLE", "车机请求配对码：\(code)")
        }

        bleBootstrap.startScanning()
    }

    /// BLE 凭证到手 + 已加入车机网络后启动 WFD
    private func startWFD(host: String, port: UInt16) {
        let diag = Diagnostics.shared
        diag.log("管线", "── M5: WFD Source ──")

        displaySource = DisplaySource()
        displaySource.onLog = { diag.log("WFD", $0) }
        displaySource.onFailure = { diag.error("WFD", String(describing: $0)) }
        displaySource.onDisplayMode = { mode in
            diag.log("WFD", "车机声明 display=\(mode.width)×\(mode.height) dpi=\(mode.dpi) fps=\(mode.fps)")
            // 把车机的分辨率/帧率告诉 CarPlay（iAP2 identification 时用）
        }
        displaySource.onReady = { [weak self] session in
            guard let self else { return }
            self.phase = .wfdNegotiating
            diag.log("管线", "WFD 会话已建立 → 等待 CarPlay 数据")

            // M4: iPhone 的 CarPlay 数据从 transport.onData 进来，
            // 解出视频帧后 → 这里做 RTP 打包 → 车机
            self.rtpPacketizer = RTPPacketizer()
            diag.log("管线", "RTP 打包器就绪（视频 \(session.host):\(session.port)）")
        }

        displaySource.connect(host: host, port: port)
    }

    // MARK: - M4: CarPlay 媒体会话

    /// CarPlay 栈连入媒体端口后建立会话
    func startMediaSession() {
        let diag = Diagnostics.shared
        diag.log("管线", "── M4: 媒体会话 ──")

        mediaListener = MediaTCPListener()
        mediaListener.onLog = { diag.log("媒体", $0) }
        mediaListener.onError = { diag.error("媒体", String(describing: $0)) }
        mediaListener.onConnection = { conn in
            diag.log("媒体", "iPhone 已连入媒体端口 \(conn.peerAddress)")

            // 触摸回传
            self.touchRelay = TouchRelay()
            self.touchRelay.onTouchReport = { [weak self] report in
                diag.hex("触摸", "HID report", report)
                // 发回 iPhone：transport.sendToPhone(report)
                self?.transport?.sendToPhone(report)
            }
        }
        mediaListener.start(port: 0)
    }

    // MARK: - 停止

    func stop() {
        transport?.stop()
        bleBootstrap?.stop()
        displaySource?.stop()
        mediaListener?.stop()
        phase = .idle
        Diagnostics.shared.log("管线", "已停止")
    }
}

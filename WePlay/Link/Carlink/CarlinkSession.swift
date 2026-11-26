import Foundation
import Network
import CryptoKit

/// Carlink 会话编排（规格：oxp-clink session.rs run()，2026-11-22 提炼）。
///
/// ## 连接拓扑（与直觉相反——车机拨入手机！）
///
/// ```
/// 手机 ──dial──► 车机:57209(auth)   认证握手（唯一一个手机主动发起的连接）
/// 手机 ◄──dial── 车机 ──► 手机监听的各服务端口（认证成功后车机反向拨入）：
///         rtsp 7236   明文标准 WFD RTSP（不走加密帧！）
///         uibc 4321   明文 UIBC 触摸回传
///         control 57219 / cert 57249 / media 57229 / sensor 57239
///                     CarlinkFrame + SecureRecord 加密（每服务独立密码状态）
/// ```
///
/// ## 认证重试语义（照 Rust authenticate）
/// - 未配对：先发 quick=false 且无 PIN 的 start（车机会回 PinRequired）
///   → 回调 onPinRequired → 用户输码 → sequence+=2、forceFull 重发（仅重试一次）
/// - 已配对（信任存储有车机公钥）：直接 quick 模式免 PIN
///
/// ## 状态机（照 ClinkState）
/// connecting → authenticating → negotiating（等车机拨入各服务）→ playing → ended
final class CarlinkSession {

    struct Ports {
        static let auth: UInt16 = 57209
        static let control: UInt16 = 57219
        static let media: UInt16 = 57229
        static let cert: UInt16 = 57249
        static let rtsp: UInt16 = 7236
        static let uibc: UInt16 = 4321
        static let rtp: UInt16 = 15550
        static let sensor: UInt16 = 57239

        static let all: [UInt16] = [control, cert, media, sensor, rtsp, uibc]
    }

    enum State: String {
        case connecting = "连接车机服务"
        case authenticating = "认证中"
        case negotiating = "等待车机连接"
        case playing = "CarLink 已建立"
        case ended = "会话结束"
    }

    // MARK: - 回调

    var onLog: ((String) -> Void)?
    var onState: ((State) -> Void)?
    var onPinRequired: (() -> Void)?
    var onError: ((Error) -> Void)?
    /// RTSP 连接被车机拨入——把该连接包成 DisplayTransport 交给投屏状态机
    var onRtspAccepted: ((DisplayTransport) -> Void)?
    /// UIBC 连接被车机拨入——触摸回传字节（解析接 TouchRelay）
    var onUibcData: ((Data) -> Void)?
    /// 其他加密服务的解密后帧（v1 主要用于日志）
    var onServiceFrame: ((UInt16, CarlinkFrame, Data) -> Void)?

    // MARK: - 状态

    private let headUnitIP: String
    private let localIP: String
    private let identity: CarlinkAuth.Identity
    private let trust: CarlinkTrustStore
    private var pin: String?

    private(set) var state: State = .connecting {
        didSet {
            onLog?("状态 → \(state.rawValue)")
            onState?(state)
        }
    }

    private var authConnection: NWConnection?
    private var authMachine: CarlinkAuth?
    private var authSequence: UInt32 = 1
    private var authRetries = 0
    private var authFrameReader = CarlinkFrameReader()
    private var rtspTransport: CarlinkTransport?
    private var authTimeout: DispatchWorkItem?
    private(set) var awaitingPin = false

    private var listeners: [NWListener] = []
    private var sockets: [UInt16: NWConnection] = [:]
    private var frameReaders: [UInt16: CarlinkFrameReader] = [:]
    private var ciphers: [UInt16: CarlinkSecureRecord] = [:]
    private var txSequence: UInt32 = 2   // 认证用掉 1（start）和 2（确认）

    private let queue = DispatchQueue(label: "weplay.carlink.session")

    init(headUnitIP: String, localIP: String,
         identity: CarlinkAuth.Identity, trust: CarlinkTrustStore, pin: String?) {
        self.headUnitIP = headUnitIP
        self.localIP = localIP
        self.identity = identity
        self.trust = trust
        self.pin = pin
    }

    // MARK: - 启动

    /// 起服务监听 → 拨 auth 端口发起认证
    func start() {
        let diag = onLog
        for port in Ports.all {
            startListener(port)
        }
        state = .connecting
        dialAuth()
    }

    private func startListener(_ port: UInt16) {
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            listener.newConnectionHandler = { [weak self] conn in
                self?.carDialed(port: port, connection: conn)
            }
            listener.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st {
                    self?.onLog?("监听 \(port) 失败：\(e)")
                    self?.onError?(e)
                }
            }
            listener.start(queue: queue)
            listeners.append(listener)
            onLog?("监听服务端口 \(port)")
        } catch {
            onError?(error)
        }
    }

    private func dialAuth() {
        state = .authenticating
        let conn = NWConnection(host: NWEndpoint.Host(headUnitIP),
                                port: NWEndpoint.Port(rawValue: Ports.auth)!,
                                using: .tcp)
        authConnection = conn
        onLog?("认证 → 连接车机 \(headUnitIP):\(Ports.auth)")
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .preparing:
                self.onLog?("认证 TCP 状态 preparing")
            case .ready:
                self.onLog?("认证 TCP 已连接")
                self.authTimeout?.cancel()
                self.beginAuthExchange()
                self.receiveAuthLoop(conn)
            case .failed(let e):
                self.authTimeout?.cancel()
                self.onLog?("认证 TCP 失败：\(e)")
                self.onError?(e)
                self.state = .ended
            case .cancelled:
                self.onLog?("认证 TCP 已取消")
            default:
                break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.state == .authenticating else { return }
            self.onLog?("认证 TCP 连接超时（57209）")
            self.authConnection?.cancel()
            self.state = .ended
            self.onError?(CarlinkError.badPacket("auth_connect_timeout"))
        }
        authTimeout = timeout
        queue.asyncAfter(deadline: .now() + 12, execute: timeout)
        conn.start(queue: queue)
    }

    // MARK: - 认证交换

    private func beginAuthExchange() {
        do {
            let identity = try trust.loadOrCreateIdentity()
            // device_id 用公钥哈希（稳定、不泄露密钥材料）
            let deviceID = SHA256.hash(data: identity.rawPublic).prefix(8)
                .map { String(format: "%02x", $0) }.joined()
            let auth = try CarlinkAuth(identity: identity,
                                       deviceID: deviceID,
                                       name: "WePlay",
                                       localIPv4: localIP,
                                       peerPublic: trust.peerKey(for: headUnitIP))
            authMachine = auth
            authSequence = 1
            onLog?("认证状态机启动（quick=\(trust.peerKey(for: headUnitIP) != nil)，PIN=\(pin == nil ? "无" : "有")）")
            let attempt = try auth.start(time: nowSeconds(), sequence: authSequence, pin: pin)
            awaitingPin = false
            onLog?("认证首帧准备完成（\(attempt.frames.count) 帧）")
            sendAuthFrames(attempt)
        } catch CarlinkError.pinRequired {
            onLog?("首配需要配对码——请在车机查看后输入")
            awaitingPin = true
            onPinRequired?()
        } catch {
            onError?(error)
        }
    }

    /// UI 输入配对码后调用：强制全模式重发（sequence += 2，仅一次重试）
    func submitPin(_ code: String) {
        guard awaitingPin, let auth = authMachine else { return }
        do {
            pin = code
            authSequence &+= 2
            let attempt = try auth.start(time: nowSeconds(), sequence: authSequence,
                                         pin: code, forceFull: true)
            awaitingPin = false
            sendAuthFrames(attempt)
        } catch {
            onError?(error)
        }
    }

    private func sendAuthFrames(_ attempt: CarlinkAuth.Output) {
        if attempt.pinRequired {
            authRetries += 1
            guard authRetries <= 1 else {
                failAuthentication(CarlinkError.badPacket("auth_pin_required"))
                return
            }
            awaitingPin = true
            onLog?("车机要求配对码（PinRequired）")
            onPinRequired?()
            return
        }
        if attempt.confirmationRequired {
            failAuthentication(CarlinkError.pinConfirmationRequired)
            return
        }
        if attempt.rejected {
            failAuthentication(CarlinkError.rejected)
            return
        }

        sendAuthFrame(attempt.frames, index: 0) { [weak self] in
            guard let self, let key = attempt.sessionKey else { return }
            self.authSucceeded(key: key, peerKey: attempt.peerVerified)
        }
    }

    private func sendAuthFrame(_ frames: [CarlinkFrame], index: Int, completion: @escaping () -> Void) {
        guard index < frames.count else {
            completion()
            return
        }
        guard let connection = authConnection else {
            failAuthentication(CarlinkError.badPacket("auth_connection_missing"))
            return
        }
        connection.send(content: frames[index].encode(), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.failAuthentication(error)
            } else {
                self.sendAuthFrame(frames, index: index + 1, completion: completion)
            }
        })
    }

    private func receiveAuthLoop(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, self.authConnection === connection else { return }
            if let data, !data.isEmpty {
                self.handleAuthInbound(data)
            }
            if self.authConnection == nil { return }
            if let error {
                self.failAuthentication(error)
            } else if isComplete {
                self.failAuthentication(CarlinkError.badPacket("auth_connection_closed"))
            } else {
                self.receiveAuthLoop(connection)
            }
        }
    }

    private func handleAuthInbound(_ data: Data) {
        do {
            let frames = try authFrameReader.feed(data)
            guard let authMachine else {
                throw CarlinkError.badPacket("auth_state_missing")
            }
            for frame in frames {
                onLog?("认证 ← 帧 seq=\(frame.sequence) method=\(frame.method) body=\(frame.body.count)B")
                let result = authMachine.receive(frame: frame, time: nowSeconds())
                sendAuthFrames(result)
            }
        } catch {
            failAuthentication(error)
        }
    }

    private func failAuthentication(_ error: Error) {
        onLog?("认证失败：\(error)")
        authConnection?.cancel()
        authConnection = nil
        authMachine = nil
        onError?(error)
        state = .ended
    }

    private func authSucceeded(key: Data, peerKey: Data?) {
        onLog?("认证成功，会话密钥 \(key.count)B；等待车机拨入服务端口")
        if let pk = peerKey {
            trust.rememberPeerKey(pk, for: headUnitIP)
        }
        for port in [Ports.control, Ports.cert, Ports.media, Ports.sensor] {
            ciphers[port] = try? CarlinkSecureRecord(key: key)
            frameReaders[port] = CarlinkFrameReader()
        }
        // 认证连接用完即关（照 Rust：auth.shutdown()）
        authConnection?.cancel()
        authConnection = nil
        authMachine = nil
        authFrameReader.reset()
        state = .negotiating
    }

    // MARK: - 车机拨入的服务连接

    private func carDialed(port: UInt16, connection: NWConnection) {
        onLog?("车机拨入端口 \(port)")
        sockets[port] = connection

        connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            if case .failed(let e) = st {
                if port == Ports.rtsp { self.rtspTransport?.onError?(e) }
                self.onError?(e)
            } else if case .cancelled = st {
                self.sockets[port] = nil
                if port == Ports.rtsp { self.rtspTransport = nil }
            }
        }
        connection.start(queue: queue)
        receiveLoop(port: port, connection: connection)

        guard [Ports.control, Ports.cert, Ports.media, Ports.sensor].contains(port) else {
            if port == Ports.rtsp {
                state = .playing
                onLog?("RTSP 通道建立（明文 WFD）——交投屏状态机")
                let transport = CarlinkTransport(connection: connection)
                rtspTransport = transport
                onRtspAccepted?(transport)
            } else if port == Ports.uibc {
                state = .playing
                onLog?("UIBC 通道建立（明文触摸回传）")
            }
            return
        }

        // control 端口接通后先发两条配置帧（照 session.rs：method 24 sync + method 9）
        if port == Ports.control {
            let zeros = Data((1...4).flatMap { _ in Data([0]) })   // 4 个 Varint(0)
            send(service: port, category: 1, method: 24, body: Data(), kind: 1)
            send(service: port, category: 1, method: 9, body: zeros, kind: 0)
        }
    }

    private func receiveLoop(port: UInt16, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.handleInbound(port: port, data: data)
            }
            if isComplete || error != nil {
                self.onLog?("端口 \(port) 连接关闭")
                self.sockets[port] = nil
                return
            }
            self.receiveLoop(port: port, connection: connection)
        }
    }

    private func handleInbound(port: UInt16, data: Data) {
        if port == Ports.rtsp {
            rtspTransport?.deliver(data)
            return
        }
        // UIBC = 明文直通
        if port == Ports.uibc {
            onUibcData?(data)
            return
        }
        // 其余服务 = CarlinkFrame + SecureRecord（字典取的是引用语义包装前的值类型，需可变拷贝）
        guard frameReaders[port] != nil, ciphers[port] != nil else { return }
        var reader = frameReaders[port]!
        var cipher = ciphers[port]!
        do {
            for frame in try reader.feed(data) {
                let plain = try cipher.open(frame.body)
                frameReaders[port] = reader
                ciphers[port] = cipher
                onServiceFrame?(port, frame, plain)
                // control 端口：车机的 ACK 帧（method 对应回执）v1 记日志
                if port == Ports.control {
                    onLog?("control 帧 method=\(frame.method) body \(plain.count)B")
                }
            }
            frameReaders[port] = reader
            ciphers[port] = cipher
        } catch {
            frameReaders[port] = reader
            ciphers[port] = cipher
            onLog?("端口 \(port) 解帧失败：\(error)")
            onError?(error)
        }
    }

    // MARK: - 发送（加密服务帧，照 session.rs owner.send）

    /// source=1、kind=0（异步）/1（要 ACK）、body 走该服务的 SecureRecord
    func send(service: UInt16, category: UInt8, method: UInt16,
              body: Data, kind: UInt8 = 0, format: UInt8 = 1) {
        guard let conn = sockets[service], let cipher = ciphers[service] else {
            onLog?("端口 \(service) 未连接，发送丢弃")
            return
        }
        do {
            txSequence &+= 1
            let frame = CarlinkFrame(sequence: txSequence, unixSeconds: nowSeconds(),
                                     source: 1, format: format, kind: kind,
                                     category: category, method: method,
                                     body: try cipher.seal(body))
            conn.send(content: frame.encode(), completion: .contentProcessed { _ in })
        } catch {
            onError?(error)
        }
    }

    private func nowSeconds() -> UInt32 {
        UInt32(Date().timeIntervalSince1970)
    }

    // MARK: - 停止

    func stop() {
        for l in listeners { l.cancel() }
        listeners.removeAll()
        for (_, c) in sockets { c.cancel() }
        sockets.removeAll()
        authConnection?.cancel()
        authConnection = nil
        rtspTransport = nil
        ciphers.removeAll()
        frameReaders.removeAll()
        state = .ended
    }
}

/// 把车机拨入的 RTSP 连接包成 DisplayTransport，交给 DisplaySource 跑 RTSP 状态机
final class CarlinkTransport: DisplayTransport {
    var onData: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    private let connection: NWConnection

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        // CarlinkSession owns the NWConnection lifecycle and forwards received bytes.
    }

    func deliver(_ data: Data) {
        onData?(data)
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection.cancel()
    }
}

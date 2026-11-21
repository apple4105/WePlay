import Foundation
import Network

/// CarPlay 媒体会话的 TCP 服务端。
///
/// iPhone 的 CarPlay 栈在 iAP2 握手阶段收到 `startSession(address:)` 后，
/// 会主动连到这个 TCP 地址建立媒体会话。
///
/// 会话里复用了三类流（照 CarWithin `CarPlayMediaSession` 的成员还原）：
///   - video：H.264/HEVC NAL 流
///   - audio：AAC/Opus 音频
///   - event：加密的触摸/按键事件（`eventCipher`）
///
/// 帧定界：CarPlay 的 TCP 流按「流 ID + 长度前缀」分帧，
/// 具体字段宽度待真机日志定（`onRawFrame` 钩子已留）。
final class MediaTCPListener {

    // MARK: - 回调

    var onLog: ((String) -> Void)?

    /// iPhone 连入
    var onConnection: ((MediaTCPConnection) -> Void)?

    var onError: ((Error) -> Void)?

    // MARK: - 状态

    private(set) var port: UInt16 = 0
    private var listener: NWListener?
    private var connections: [MediaTCPConnection] = []

    init() {}

    /// 在指定端口启动监听（0 = 系统分配）
    func start(port: UInt16 = 0) {
        self.port = port
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port) ?? .any)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = listener.port?.rawValue ?? 0
                    self?.onLog?("[MediaTCP] 监听端口 \(self?.port ?? 0)")
                case .failed(let error):
                    self?.onError?(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                let conn = MediaTCPConnection(connection: connection)
                conn.onClose = { [weak self] in
                    self?.connections.removeAll { $0 === conn }
                }
                self?.connections.append(conn)
                connection.start(queue: .global(qos: .userInitiated))
                self?.onLog?("[MediaTCP] iPhone 已连入（当前 \(self?.connections.count ?? 0) 连接）")
                self?.onConnection?(conn)
            }
            self.listener = listener
            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            onError?(error)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for c in connections { c.stop() }
        connections.removeAll()
    }
}

/// 单条 TCP 连接的收发包装。
final class MediaTCPConnection {

    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "weplay.media.tcp", qos: .userInitiated)
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    var peerAddress: String {
        if let endpoint = connection.currentPath?.remoteEndpoint {
            return "\(endpoint)"
        }
        return "?"
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receiveLoop()
            case .failed(let error):
                self?.onError?(error)
            case .cancelled:
                self?.onClose?()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onData?(data)
            }
            if error == nil, !isComplete {
                self.receiveLoop()
            } else {
                if let error { self.onError?(error) }
                self.onClose?()
            }
        }
    }
}

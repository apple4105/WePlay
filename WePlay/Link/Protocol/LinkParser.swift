import Foundation

/// 字节流解析器：把传输层交上来的零碎字节累积成完整的包 / 消息。
///
/// 用法：
/// ```swift
/// let parser = LinkParser()
/// parser.onPacket = { packet in … }
/// parser.onMessage = { message in … }      // 只对控制会话（sessionID == 0）回调
/// parser.append(chunkFromTransport)
/// ```
final class LinkParser {

    /// 解出一个完整链路层包
    var onPacket: ((LinkPacket) -> Void)?

    /// 收到 iAP2 link initialization presence marker (`FF 55 02 00 EE 10`)
    var onPresence: (() -> Void)?

    /// 解出一条控制会话消息
    var onMessage: ((LinkMessage) -> Void)?

    /// 当前协商出的控制会话 ID。未设置时不解析业务消息。
    var controlSessionID: UInt8?

    /// 原始包 hex（真机联调时打开，用来核对包头布局）
    var onRawPacket: ((Data) -> Void)?

    /// 解析出错（校验失败 / 重新同步）
    var onError: ((String) -> Void)?

    private var buffer = Data()
    private var messageBuffer = Data()
    private let maxMessageBufferSize = 65_536
    private let presenceMarker = LinkPacket.presence

    init() {}

    func append(_ chunk: Data) {
        buffer.append(chunk)
        drain()
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        messageBuffer.removeAll(keepingCapacity: true)
        controlSessionID = nil
    }

    private func drain() {
        while true {
            guard !buffer.isEmpty else { return }

            if buffer.first == presenceMarker.first {
                guard buffer.count >= presenceMarker.count else { return }
                if buffer.prefix(presenceMarker.count) == presenceMarker {
                    buffer.removeSubrange(0 ..< presenceMarker.count)
                    onPresence?()
                    continue
                }
            }

            switch LinkPacket.decode(buffer) {
            case .needMore:
                return

            case .badSync:
                // SOP 或校验不对：丢到下一个 0xFF 重新同步。
                // 真机联调时这里会频繁触发，正好说明包头布局需要按日志修正。
                onError?("[LinkParser] 同步失败，缓冲 \(buffer.count) B，头部 \(buffer.prefix(16).hexString)")
                guard let nextFF = buffer[1...].firstIndex(of: 0xFF) else {
                    buffer.removeAll(keepingCapacity: true)
                    return
                }
                buffer.removeSubrange(0 ..< nextFF)

            case .packet(let packet, let consumed):
                onRawPacket?(Data(buffer.prefix(consumed)))
                buffer.removeSubrange(0 ..< consumed)
                onPacket?(packet)

                // 只在协商出的控制会话里拆 CSM；未协商或其他 session 只保留包级回调。
                if let controlSessionID, packet.sessionID == controlSessionID,
                   !packet.payload.isEmpty {
                    parseMessages(packet.payload)
                }
            }
        }
    }

    private func parseMessages(_ payload: Data) {
        guard messageBuffer.count + payload.count <= maxMessageBufferSize else {
            onError?("[LinkParser] 消息缓存超限（\(maxMessageBufferSize) B），丢弃缓存")
            messageBuffer.removeAll(keepingCapacity: true)
            return
        }
        messageBuffer.append(payload)
        while !messageBuffer.isEmpty {
            switch LinkMessage.parse(messageBuffer) {
            case .needMore:
                return
            case .badFormat:
                onError?("[LinkParser] 消息格式错误，\(messageBuffer.count) B")
                messageBuffer.removeAll(keepingCapacity: true)
                return
            case .message(let message, let consumed):
                messageBuffer.removeSubrange(0 ..< consumed)
                onMessage?(message)
            }
        }
    }
}

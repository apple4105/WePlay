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

    /// 解出一条控制会话消息
    var onMessage: ((LinkMessage) -> Void)?

    /// 原始包 hex（真机联调时打开，用来核对包头布局）
    var onRawPacket: ((Data) -> Void)?

    /// 解析出错（校验失败 / 重新同步）
    var onError: ((String) -> Void)?

    private var buffer = Data()

    init() {}

    func append(_ chunk: Data) {
        buffer.append(chunk)
        drain()
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private func drain() {
        while true {
            guard !buffer.isEmpty else { return }

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

                // 控制会话里再拆消息
                if packet.sessionID == LinkPacket.controlSessionID, !packet.payload.isEmpty {
                    parseMessages(packet.payload)
                }
            }
        }
    }

    private func parseMessages(_ payload: Data) {
        var data = payload
        while !data.isEmpty {
            switch LinkMessage.parse(data) {
            case .needMore:
                // 一条消息被拆到多个包里：v1 先按"整包一条消息"处理，
                // 真机若出现跨包消息，再在这里加消息级缓冲。
                onError?("[LinkParser] 消息跨包，暂不处理（\(data.count) B 残留）")
                return
            case .badFormat:
                onError?("[LinkParser] 消息格式错误，\(data.count) B")
                return
            case .message(let message, let consumed):
                data.removeSubrange(0 ..< consumed)
                onMessage?(message)
            }
        }
    }
}

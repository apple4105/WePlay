import Foundation
import Network

/// CarPlay 媒体数据管道：iPhone 回环 TCP → H.264 AVCC → Annex-B → RTP → 车机。
///
/// ## 输入侧（待真机校准的一处假设）
/// CarPlay 媒体 TCP 流按 `be32 长度 + 载荷` 分帧，载荷 = AVCC 编码的 NAL
/// （4 字节 NAL 长度头，ScreenStream.convertFromAVCC 负责转起始码）。
/// 真机若对不上，诊断会打出前 64 字节 hex——只需改 parseChunk 一处。
///
/// ## 输出侧
/// RTP 发往车机声明的 `wfd_client_rtp_ports`（M2 协商捕获，VideoPort/首次数字）。
final class CarPlayMediaPipe {

    private let rtp: RTPPacketizer
    private let screen = ScreenStream()
    private var udp: NWConnection?
    private let targetHost: String
    private let targetPort: UInt16
    private let onLog: ((String) -> Void)?

    /// 输入缓冲 + be32 分帧状态
    private var buffer = Data()
    private var payloadBuffer = Data()

    /// 90kHz 时间戳基准（单调）
    private let base = UInt32(Date().timeIntervalSince1970 * 90)

    /// 已解析帧计数（诊断）
    private(set) var nalCount = 0
    private(set) var sentPackets = 0

    init(targetHost: String, targetPort: UInt16, onLog: ((String) -> Void)?) {
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.onLog = onLog
        self.rtp = RTPPacketizer()
    }

    // MARK: - 输入（iPhone 回环）

    func attach(_ connection: MediaTCPConnection) {
        connection.onData = { [weak self] data in
            self?.ingest(data)
        }
        connection.start()
    }

    func ingest(_ data: Data) {
        buffer.append(data)
        parseChunk()
    }

    private func parseChunk() {
        while true {
            guard buffer.count >= 4 else { return }
            let length = buffer.be32(at: 0)
            guard length > 0, length <= 4 * 1024 * 1024 else {
                // 分帧假设失效：打出现场，清缓冲（真机校准点）
                let head = buffer.prefix(64).map { String(format: "%02x", $0) }.joined()
                onLog?("[媒体] 分帧失配（len=\(length)），头部 \(head)——清缓冲重同步")
                buffer.removeAll(keepingCapacity: true)
                return
            }
            guard buffer.count >= 4 + Int(length) else { return }
            let payload = buffer.subdata(in: (buffer.startIndex + 4) ..< (buffer.startIndex + 4 + Int(length)))
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + Int(length))
            handleNAL(payload)
        }
    }

    private func handleNAL(_ avcc: Data) {
        // 吸参数集（SPS/PPS → avcC）
        screen.absorb(nal: avcc)

        guard let annexB = (try? H264AnnexB.convertFromAVCC(avcc)) ?? nil, !annexB.isEmpty else { return }
        nalCount += 1

        let ts = UInt32(Date().timeIntervalSince1970 * 90) &- base
        let isKey = rtp.containsIDR(annexB)
        for packet in rtp.packetizeH264(annexB, isKeyFrame: isKey, timestamp: ts) {
            sendUDP(packet)
            sentPackets += 1
        }
    }

    // MARK: - 输出（RTP → 车机）

    private func sendUDP(_ packet: Data) {
        if udp == nil {
            let conn = NWConnection(host: NWEndpoint.Host(targetHost),
                                    port: NWEndpoint.Port(rawValue: targetPort) ?? 19000,
                                    using: .udp)
            conn.start(queue: DispatchQueue(label: "weplay.carlink.rtp"))
            udp = conn
            onLog?("[媒体] RTP → \(targetHost):\(targetPort) 开始发送")
        }
        udp?.send(content: packet, completion: .contentProcessed { _ in })
    }

    func stop() {
        udp?.cancel()
        udp = nil
        buffer.removeAll()
        payloadBuffer.removeAll()
    }
}

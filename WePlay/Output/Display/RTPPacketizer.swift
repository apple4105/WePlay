import Foundation

/// H.264 / AAC 的 RTP 打包。
///
/// `AVCUtils`（SPS/PPS 解析）。我们作 Source 只负责**打包**，不需要解码。
///
/// ## H.264 的三种打包方式（RFC 6184）
///
/// 1. **Single NAL Unit**：一个 NAL 一个 RTP 包（NAL ≤ MTU 时用，最常见）
/// 2. **STAP-A**：把多个小 NAL（典型是 SPS+PPS）合并成一个包
/// 3. **FU-A**：大 NAL 切片（车机屏 1920×1080 的 IDR 帧经常超过 MTU，必须会）
///
/// v1 策略：SPS/PPS 用 STAP-A 合并在关键帧前发；普通小 NAL 用 Single NAL；
/// 超过 MTU 的 NAL 用 FU-A 切片。
final class RTPPacketizer {

    static let defaultVideoPort: UInt16 = 19000
    static let defaultAudioPort: UInt16 = 19002

    /// 典型 Wi-Fi MTU 对应的安全载荷上限
    static let maxPayloadSize = 1200

    private let videoSSRC: UInt32
    private let audioSSRC: UInt32

    private var videoSequence: UInt16 = 0
    private var audioSequence: UInt16 = 0
    private var videoTimestamp: UInt32 = 0

    init(videoSSRC: UInt32 = UInt32.random(in: 0 ... UInt32.max),
         audioSSRC: UInt32 = UInt32.random(in: 0 ... UInt32.max)) {
        self.videoSSRC = videoSSRC
        self.audioSSRC = audioSSRC
    }

    // MARK: - H.264

    /// 把一个 Annex-B 帧（可能含多个 NAL）打包成若干 RTP 包。
    ///
    /// - Parameter annexB: `H264AnnexB.convertFromAVCC()` 的输出（00 00 00 01 分隔）
    /// - Parameter isKeyFrame: 是否关键帧（决定 marker + 时间戳跳变处理）
    /// - Parameter timestamp: RTP 时间戳（90kHz 时钟）
    func packetizeH264(_ annexB: Data, isKeyFrame: Bool, timestamp: UInt32) -> [Data] {
        let nals = splitAnnexB(annexB)
        guard !nals.isEmpty else { return [] }

        var packets: [Data] = []
        packets.reserveCapacity(nals.count * 2)

        for (index, nal) in nals.enumerated() {
            let isLast = index == nals.count - 1
            _ = nal.first.map { $0 & 0x1F }

            // 参数集（SPS=7 / PPS=8）：小块，和后面的 IDR 合并意义不大，
            // 直接按 Single NAL 发（车机 Assembler 会认）
            if nal.count <= Self.maxPayloadSize {
                packets.append(rtpPacket(payload: nal,
                                         marker: isLast,
                                         payloadType: 96,
                                         sequence: nextVideoSequence(),
                                         timestamp: timestamp))
            } else {
                packets.append(contentsOf: fragmentFU_A(nal,
                                                        isLast: isLast,
                                                        timestamp: timestamp))
            }
        }

        return packets
    }

    /// FU-A 切片（RFC 6184 §5.8）
    private func fragmentFU_A(_ nal: Data, isLast: Bool, timestamp: UInt32) -> [Data] {
        let nalHeader = nal[nal.startIndex]
        let fuIndicator = (nalHeader & 0xE0) | 28      // FU-A type = 28
        let maxFragment = Self.maxPayloadSize - 2      // 去掉 FU indicator + header

        var packets: [Data] = []
        var offset = nal.startIndex + 1                 // 跳过原 NAL header
        let end = nal.endIndex
        var first = true

        while offset < end {
            let chunkEnd = min(offset + maxFragment, end)
            let last = chunkEnd >= end

            var fuHeader: UInt8 = (nalHeader & 0x1F)    // 原 NAL type
            if first { fuHeader |= 0x80 }               // Start bit
            if last { fuHeader |= 0x40 }                // End bit

            var payload = Data([fuIndicator, fuHeader])
            payload.append(nal[offset ..< chunkEnd])

            packets.append(rtpPacket(payload: payload,
                                     marker: isLast && last,
                                     payloadType: 96,
                                     sequence: nextVideoSequence(),
                                     timestamp: timestamp))
            offset = chunkEnd
            first = false
        }
        return packets
    }

    /// STAP-A：把多个 NAL 合并成一个 RTP 包（聚合小 NAL 用）
    func packetizeSTAP_A(_ nals: [Data], timestamp: UInt32) -> Data? {
        guard let firstNAL = nals.first else { return nil }
        let stapType: UInt8 = 24
        var payload = Data([(firstNAL.first ?? 0) & 0xE0 | stapType])

        for nal in nals {
            guard nal.count <= Self.maxPayloadSize else { return nil }
            // 2 字节小端长度 + NAL
            payload.append(UInt8(nal.count >> 8))
            payload.append(UInt8(nal.count & 0xFF))
            payload.append(nal)
        }
        return rtpPacket(payload: payload, marker: true, payloadType: 96,
                         sequence: nextVideoSequence(), timestamp: timestamp)
    }

    // MARK: - AAC

    /// AAC-ADTS → RTP（RFC 3640 风格：每个 AU 前带 2 字节 AU 长度，车机声明 `audio/aac-adts`）
    func packetizeAAC(_ au: Data, timestamp: UInt32) -> Data {
        var payload = Data()
        payload.append(UInt8(au.count >> 8))
        payload.append(UInt8(au.count & 0xFF))
        payload.append(au)

        return rtpPacket(payload: payload, marker: true, payloadType: 97,
                         sequence: nextAudioSequence(), timestamp: timestamp, ssrc: audioSSRC)
    }

    // MARK: - RTP 头

    /// RTP 固定头（RFC 3550 §5.1）：V=2, P=0, X=0, CC=0, M, PT, seq, timestamp, SSRC
    private func rtpPacket(payload: Data, marker: Bool, payloadType: UInt8,
                           sequence: UInt16, timestamp: UInt32, ssrc: UInt32? = nil) -> Data {
        var header = Data()
        header.append(0x80 | (marker ? 0x20 : 0x00))       // V=2 + M
        header.append(payloadType)
        header.append(UInt8(sequence >> 8))
        header.append(UInt8(sequence & 0xFF))
        header.append(UInt8(timestamp >> 24))
        header.append(UInt8((timestamp >> 16) & 0xFF))
        header.append(UInt8((timestamp >> 8) & 0xFF))
        header.append(UInt8(timestamp & 0xFF))
        let s = ssrc ?? videoSSRC
        header.append(UInt8(s >> 24))
        header.append(UInt8((s >> 16) & 0xFF))
        header.append(UInt8((s >> 8) & 0xFF))
        header.append(UInt8(s & 0xFF))

        var out = header
        out.append(payload)
        return out
    }

    private func nextVideoSequence() -> UInt16 {
        defer { videoSequence = videoSequence &+ 1 }
        return videoSequence
    }

    private func nextAudioSequence() -> UInt16 {
        defer { audioSequence = audioSequence &+ 1 }
        return audioSequence
    }

    // MARK: - Annex-B 切分

    /// 把 `00 00 00 01 | NAL | 00 00 01 | NAL …` 切成 NAL 数组
    func splitAnnexB(_ data: Data) -> [Data] {
        var nals: [Data] = []
        let bytes = [UInt8](data)

        var nalStart: Int?
        var j = 0
        while j < bytes.count {
            // 找 start code（3 或 4 字节）
            if j + 2 < bytes.count, bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 1 {
                if let start = nalStart {
                    nals.append(Data(bytes[start ..< j]))
                }
                j += 3
                nalStart = j
                continue
            }
            if j + 3 < bytes.count, bytes[j] == 0, bytes[j + 1] == 0, bytes[j + 2] == 0, bytes[j + 3] == 1 {
                if let start = nalStart {
                    nals.append(Data(bytes[start ..< j]))
                }
                j += 4
                nalStart = j
                continue
            }
            j += 1
        }
        if let start = nalStart, start < bytes.count {
            nals.append(Data(bytes[start...]))
        }
        return nals.filter { !$0.isEmpty }
    }

    /// 判断一个 Annex-B 帧是否含 IDR（type 5）
    func containsIDR(_ annexB: Data) -> Bool {
        for nal in splitAnnexB(annexB) {
            if let first = nal.first, (first & 0x1F) == 5 { return true }
        }
        return false
    }
}

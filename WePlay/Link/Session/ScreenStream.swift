import Foundation

/// CarPlay 视频流的 NAL 级处理：AVCC（长度前缀）→ Annex-B（起始码）。
///
/// CarPlay 的媒体会话里，视频以 **AVCC** 格式传输（4 字节大端长度前缀 + NAL 数据），
/// 而投屏输出端（RTP 打包）需要 **Annex-B** 格式（00 00 00 01 起始码）。
/// 这两个格式之间的转换是零解码的——纯字节流重排。
///
/// SPS/PPS（或 HEVC 的 VPS）作为 **参数集** 单独提取，
/// 在 RTP 打包时放在关键帧前面发一次（decoder configuration record）。
final class VideoParameterSets {

    enum Codec: String, CaseIterable {
        case avc = "avc1"
        case hevc = "hvc1"
    }

    private(set) var codec: Codec = .avc
    private(set) var vps: Data?           // HEVC 专属
    private(set) var sps: Data?
    private(set) var pps: Data?
    private(set) var isComplete: Bool = false

    /// 吸收流里的参数集 NAL（遇到 type 7/8 = AVC SPS/PPS，type 32/33/34 = HEVC VPS/SPS/PPS）
    func absorb(nal: Data) {
        guard let first = nal.first else { return }
        let type = first & 0x1F
        switch codec {
        case .avc:
            if type == 7 { sps = stripStartCode(nal) }
            if type == 8 { pps = stripStartCode(nal) }
            isComplete = sps != nil && pps != nil
        case .hevc:
            // HEVC: type 32=VPS, 33=SPS, 34=PPS（NAL header 是 2 字节，type 在第 2 字节低 6 位）
            if nal.count >= 2 {
                let hType = nal[0] & 0x7E >> 1
                if hType == 32 { vps = stripStartCode(nal) }
                if hType == 33 { sps = stripStartCode(nal) }
                if hType == 34 { pps = stripStartCode(nal) }
                isComplete = vps != nil && sps != nil && pps != nil
            }
        }
    }

    /// 构造 avcC/hvcC decoder configuration record（RTP 打包时用）
    func decoderConfigurationRecord() -> Data? {
        guard isComplete else { return nil }
        switch codec {
        case .avc:
            // avcC: configurationVersion(1) + AVCProfileIndication(1) +
            //       profile_compatibility(1) + AVCLevelIndication(1) +
            //       0xFF(2 reserved+numSPS) + spsLen(2) + sps +
            //       0xFE(1 reserved+numPPS) + ppsLen(2) + pps
            guard let sps, let pps else { return nil }
            var out = Data([0x01, sps[0], sps[1], sps[2]])
            out.append(0xFF)                                     // reserved + numSPS = 31
            out.appendBigEndianUInt16(UInt16(sps.count))
            out.append(sps)
            out.append(0xE1)                                     // reserved + numPPS = 1
            out.appendBigEndianUInt16(UInt16(pps.count))
            out.append(pps)
            return out
        case .hevc:
            // hvcC 复杂得多（HEVCDecoderConfigurationRecord 含数组），
            // v1 直接拼 VPS/SPS/PPS 的简化版本——真机联调时按车机 Assembler 的期望调
            guard let vps, let sps, let pps else { return nil }
            var out = Data()
            out.append(vps); out.append(sps); out.append(pps)
            return out
        }
    }

    private func stripStartCode(_ nal: Data) -> Data {
        var d = nal
        // 去掉可能的 00 00 00 01 或 00 00 01 前缀
        while d.count >= 3 {
            if d[0] == 0, d[1] == 0 {
                if d[2] == 1 { d.removeSubrange(0..<3); continue }
                if d.count >= 4, d[2] == 0, d[3] == 1 { d.removeSubrange(0..<4); continue }
            }
            break
        }
        return d
    }
}

/// Annex-B ↔ AVCC 转换（照 CarWithin 的 `H264AnnexB` 两个成员）。
enum H264AnnexB {

    /// 检查 Annex-B 流里是否包含指定类型的 NAL
    static func containsNAL(type: UInt8, in stream: Data) -> Bool {
        for nal in split(stream) {
            if let first = nal.first, (first & 0x1F) == type { return true }
        }
        return false
    }

    /// AVCC（4 字节大端长度前缀 + NAL）→ Annex-B（00 00 00 01 + NAL）
    static func convertFromAVCC(_ avcc: Data) throws -> Data {
        guard avcc.count >= 4 else { throw NALError.tooShort }
        var out = Data()
        var offset = avcc.startIndex
        let end = avcc.endIndex
        while offset + 4 <= end {
            let length = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16 |
                         Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
            guard length > 0, offset + 4 + length <= end else {
                throw NALError.badLength(offset, length)
            }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(avcc[offset + 4 ..< offset + 4 + length])
            offset += 4 + length
        }
        return out
    }

    /// 切分 Annex-B 为 NAL 列表
    static func split(_ annexb: Data) -> [Data] {
        let bytes = [UInt8](annexb)
        var nals: [Data] = []
        var start: Int?
        var i = 0
        while i < bytes.count {
            if i + 3 <= bytes.count, bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start { nals.append(Data(bytes[s ..< i])) }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if let s = start { nals.append(Data(bytes[s...])) }
        return nals.filter { !$0.isEmpty }
    }

    enum NALError: Error {
        case tooShort
        case badLength(Int, Int)
    }
}

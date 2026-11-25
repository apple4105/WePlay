import Foundation

/// link 链路层数据包。
///
/// ## 9 字节头布局（2026-11-21 定稿：Wireshark 公开解析器 + CarWithin 二进制双源一致）
///
/// ```
///  偏移  大小  字段
///   0     2    SOP = 0xFF 0x5A
///   2     2    包总长（BE16，含这 9 字节头 + 载荷 + 1 字节载荷校验）
///   4     1    控制字节
///   5     1    序列号
///   6     1    确认号（ACK 位置位时有效）
///   7     1    会话 ID（1 字节；控制会话 = 0x00）
///   8     1    头校验
///   9     N    载荷（N = 总长 - 10）
///  末     1    载荷校验
/// ```
///
/// ## 控制字节位
///
/// | 位 | 掩码 | 含义 |
/// |----|------|------|
/// | 7 | 0x80 | SYN 链路同步 |
/// | 6 | 0x40 | ACK（确认号有效） |
/// | 5 | 0x20 | EAK 扩展确认（载荷里是一串乱序序列号） |
/// | 4 | 0x10 | RST 链路重置 |
/// | 3 | 0x08 | SLP 设备休眠 |
///
/// ## 校验
///
/// 2 的补码和：被覆盖的所有字节与校验字节相加 ≡ 0 (mod 256)。
/// 头校验覆盖偏移 2..7，载荷校验覆盖整个载荷。
struct LinkPacket: Equatable {

    // MARK: 控制位

    static let controlSYN: UInt8 = 0x80
    static let controlACK: UInt8 = 0x40
    static let controlEAK: UInt8 = 0x20
    static let controlRST: UInt8 = 0x10
    static let controlSLP: UInt8 = 0x08

    static let sop: (UInt8, UInt8) = (0xFF, 0x5A)
    static let headerSize = 9

    /// 控制会话 ID
    static let controlSessionID: UInt8 = 0x00

    /// iAP2 链路 presence 包（CarWithin `IAP2Packet.presence`）。
    ///
    /// 在 SYN 之前原样发出，**不是** `FF 5A` 包格式——是 6 字节固定签名。
    /// 漏发它 iOS 的 iAP2 栈可能不认这条链路（CarWithin 是先发它、0.1 秒后才 SYN）。
    static let presence = Data([0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10])

    // MARK: 字段

    var control: UInt8
    var sequence: UInt8
    var acknowledgement: UInt8
    var sessionID: UInt8
    var payload: Data

    init(control: UInt8,
         sequence: UInt8 = 0,
         acknowledgement: UInt8 = 0,
         sessionID: UInt8 = LinkPacket.controlSessionID,
         payload: Data = Data()) {
        self.control = control
        self.sequence = sequence
        self.acknowledgement = acknowledgement
        self.sessionID = sessionID
        self.payload = payload
    }

    var isACK: Bool { control & Self.controlACK != 0 }
    var isSYN: Bool { control & Self.controlSYN != 0 }
    var isEAK: Bool { control & Self.controlEAK != 0 }

    // MARK: 校验

    /// 2 的补码校验：所有被覆盖字节 + 校验字节 ≡ 0 (mod 256)
    static func checksum(_ bytes: Data) -> UInt8 {
        var sum = 0
        for b in bytes { sum += Int(b) }
        return UInt8((256 - (sum % 256)) % 256)
    }

    static func verify(_ covered: Data, checksum: UInt8) -> Bool {
        var sum = 0
        for b in covered { sum += Int(b) }
        sum += Int(checksum)
        return sum % 256 == 0
    }

    // MARK: 编解码

    /// 编码成完整字节流（含 SOP、两个校验）。
    ///
    /// 两个曾经导致 iOS **静默丢弃我们所有包**的错误，已按固件规范修正：
    ///
    /// 1. **头校验必须覆盖全部 8 个头部字节，含 `FF 5A`**
    ///    （carvex 固件规范 `iap2_link_establish/spec/02` R-2.7「头部校验覆盖全部
    ///    8 个头部字节（含 FF 5A）」，R-2.12 伪代码 `iap2_hdr_checksum =
    ///    checksum(hdr, 8, type)`）。原来只覆盖偏移 2..7 的 6 字节，漏了同步字节，
    ///    于是每帧校验都错——这就是"presence 有回显（它没有校验和）、SYN 与
    ///    identification 全部零响应"的真因。
    /// 2. **无载荷帧不追加载荷校验**（R-2.1：总长 9，不追加空载荷校验）。
    ///    原来无条件追一个 0 字节变成 10 字节，而 10 字节在解析侧是非法长度。
    func encode() -> Data {
        // 无载荷时总长 9（SOP2+长度2+控制1+序号1+确认1+会话1+头校验1）；
        // 有载荷时再加 载荷 + 载荷校验。
        let total = Self.headerSize + (payload.isEmpty ? 0 : payload.count + 1)

        var out = Data(capacity: total)
        out.append(Self.sop.0)
        out.append(Self.sop.1)
        out.appendBE16(UInt16(total))
        out.append(control)
        out.append(sequence)
        out.append(acknowledgement)
        out.append(sessionID)

        // 头校验覆盖全部 8 个头部字节（含 FF 5A）——R-2.7
        out.append(Self.checksum(out))

        if !payload.isEmpty {
            out.append(payload)
            out.append(Self.checksum(payload))
        }

        assert(out.count == total)
        return out
    }

    struct SYNEntry: Equatable {
        let id: UInt8
        let type: UInt8
        let second: UInt8
    }

    struct SYNParameters: Equatable {
        let version: UInt8
        let maxOutstandingPackets: UInt8
        let maxPacketSize: UInt16
        let acknowledgementTimeout: UInt16
        let cumulativeAcknowledgementTimeout: UInt16
        let maxRetransmissions: UInt8
        let maxCumulativeAcknowledgements: UInt8
        let extensionBytes: Data
        let entries: [SYNEntry]
        let raw: Data

        /// Parse the on-wire SYN payload. Version 1 has no explicit entry count;
        /// each remaining three bytes form one entry. Version 2+ carries extension
        /// length and entry count before the entries.
        static func parse(_ payload: Data) throws -> SYNParameters {
            guard payload.count >= 10 else { throw LinkPacketError.invalidSYN("too_short") }
            let version = payload[0]
            guard version <= 3 else { throw LinkPacketError.invalidSYN("version") }
            let mop = payload[1]
            let maxPacket = UInt16(payload[2]) << 8 | UInt16(payload[3])
            let ackTimeout = UInt16(payload[4]) << 8 | UInt16(payload[5])
            let cumAckTimeout = UInt16(payload[6]) << 8 | UInt16(payload[7])
            let retransmissions = payload[8]
            let maxCumAck = payload[9]
            var offset = 10
            var extensions = Data()
            var count: Int

            if version >= 2 {
                guard payload.count >= 12 else { throw LinkPacketError.invalidSYN("extension_header") }
                let extensionCount = Int(payload[offset])
                offset += 1
                guard extensionCount <= 5, offset + extensionCount < payload.count else {
                    throw LinkPacketError.invalidSYN("extension_length")
                }
                extensions = Data(payload[offset ..< offset + extensionCount])
                offset += extensionCount
                count = Int(payload[offset])
                offset += 1
                guard count <= 5 else { throw LinkPacketError.invalidSYN("entry_count") }
            } else {
                guard (payload.count - offset) % 3 == 0 else {
                    throw LinkPacketError.invalidSYN("entry_alignment")
                }
                count = (payload.count - offset) / 3
            }

            guard count > 0, offset + count * 3 == payload.count else {
                throw LinkPacketError.invalidSYN("entry_length")
            }
            guard mop == 0 || (1...127).contains(mop) else {
                throw LinkPacketError.invalidSYN("mop")
            }
            guard maxPacket > 23 else { throw LinkPacketError.invalidSYN("max_packet") }
            let noRetransmit = ackTimeout == 0 && cumAckTimeout == 0
                && retransmissions == 0 && maxCumAck == 0
            if !noRetransmit {
                guard ackTimeout > 19, (10...32767).contains(cumAckTimeout),
                      (1...30).contains(retransmissions), maxCumAck <= mop else {
                    throw LinkPacketError.invalidSYN("timers")
                }
            }

            var entries = [SYNEntry]()
            var ids = Set<UInt8>()
            var types = Set<UInt8>()
            for index in 0..<count {
                let at = offset + index * 3
                let id = payload[at]
                let encodedType = payload[at + 1]
                let type = encodedType & 0x7F
                guard id != 0, encodedType & 0x80 == 0, type <= 4,
                      ids.insert(id).inserted, types.insert(type).inserted else {
                    throw LinkPacketError.invalidSYN("entry")
                }
                entries.append(SYNEntry(id: id, type: type, second: payload[at + 2]))
            }
            guard entries.contains(where: { $0.type == 0 }) else {
                throw LinkPacketError.invalidSYN("missing_control_entry")
            }
            return SYNParameters(version: version,
                                 maxOutstandingPackets: mop,
                                 maxPacketSize: maxPacket,
                                 acknowledgementTimeout: ackTimeout,
                                 cumulativeAcknowledgementTimeout: cumAckTimeout,
                                 maxRetransmissions: retransmissions,
                                 maxCumulativeAcknowledgements: maxCumAck,
                                 extensionBytes: extensions,
                                 entries: entries,
                                 raw: payload)
        }

        var controlSessionID: UInt8? {
            entries.first(where: { $0.type == 0 })?.id
        }

        var summary: String {
            let table = entries.map { "\($0.id):\($0.type):\($0.second)" }.joined(separator: ",")
            return "v=\(version) mop=\(maxOutstandingPackets) max=\(maxPacketSize) table=[\(table)]"
        }
    }

    enum LinkPacketError: Error, CustomStringConvertible {
        case invalidSYN(String)

        var description: String {
            switch self {
            case .invalidSYN(let reason): return "无效 SYN：\(reason)"
            }
        }
    }

    enum DecodeResult {
        /// 解出一个包，consumed 为占用的字节数
        case packet(LinkPacket, consumed: Int)
        /// 字节不够一个完整包，还需要更多数据
        case needMore
        /// SOP 不对，调用方应该重新同步（丢到下一个 0xFF）
        case badSync
    }

    /// 从一段字节流头部解出一个包。
    static func decode(_ data: Data) -> DecodeResult {
        guard data.count >= headerSize else { return .needMore }

        guard data[data.startIndex] == sop.0, data[data.startIndex + 1] == sop.1 else {
            return .badSync
        }

        let length = data.be16(at: 2)
        // 合法长度：9（无载荷，只有头+头校验）或 >= 11（头9 + 载荷 + 载荷校验）。
        // 10 是非法值（CarWithin 的解析器同样显式拒绝 length==10）。
        guard length >= headerSize, length != headerSize + 1 else { return .badSync }
        guard length > headerSize || data.count >= headerSize else { return .needMore }
        guard data.count >= length else { return .needMore }

        let base = data.startIndex
        let controlByte = data[base + 4]
        let seq = data[base + 5]
        let ack = data[base + 6]
        let session = data[base + 7]
        let headerChecksum = data[base + 8]

        // 头校验覆盖全部 8 个头部字节（含 FF 5A）——固件规范 R-2.7
        let headerCovered = data[base ..< base + 8]
        guard verify(headerCovered, checksum: headerChecksum) else { return .badSync }

        // 无载荷帧（长度 9）没有载荷校验
        guard length > headerSize else {
            return .packet(LinkPacket(control: controlByte, sequence: seq,
                                      acknowledgement: ack, sessionID: session,
                                      payload: Data()),
                           consumed: length)
        }

        let payloadStart = base + headerSize
        let payloadEnd = base + length - 1        // 最后 1 字节是载荷校验
        let payload = data[payloadStart ..< payloadEnd]
        let payloadChecksum = data[base + length - 1]
        guard verify(payload, checksum: payloadChecksum) else { return .badSync }

        return .packet(LinkPacket(control: controlByte, sequence: seq,
                                  acknowledgement: ack, sessionID: session,
                                  payload: Data(payload)),
                       consumed: length)
    }
}

extension Data {
    /// 大端 16 位写入（link 层长度/消息 ID/参数 ID 一律大端——2026-11-21 双源验证定稿）
    mutating func appendBE16(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    /// 大端 16 位读取（绝对偏移，从 startIndex 起算）
    func be16(at offset: Int) -> Int {
        let base = startIndex
        return (Int(self[base + offset]) << 8) | Int(self[base + offset + 1])
    }
}

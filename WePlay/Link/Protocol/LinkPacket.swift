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
    func encode() -> Data {
        // 总长先定下来（9 字节头 + 载荷 + 1 字节载荷校验）——
        // 头校验覆盖真实长度，所以必须在写长度字段之后、算校验之前把长度确定好。
        let total = Self.headerSize + payload.count + 1

        var out = Data(capacity: total)
        out.append(Self.sop.0)
        out.append(Self.sop.1)
        out.appendBE16(UInt16(total))
        out.append(control)
        out.append(sequence)
        out.append(acknowledgement)
        out.append(sessionID)

        // 头校验覆盖 偏移 2..7（长度+控制+序列+确认号+会话ID 共 6 字节，不含 SOP）
        out.append(Self.checksum(out.suffix(6)))

        out.append(payload)
        out.append(Self.checksum(payload))

        assert(out.count == total)
        return out
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
        guard length >= headerSize + 1 else { return .badSync }   // 至少有载荷校验位
        guard data.count >= length else { return .needMore }

        let base = data.startIndex
        let controlByte = data[base + 4]
        let seq = data[base + 5]
        let ack = data[base + 6]
        let session = data[base + 7]
        let headerChecksum = data[base + 8]

        let headerCovered = data[base + 2 ..< base + 8]
        guard verify(headerCovered, checksum: headerChecksum) else { return .badSync }

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

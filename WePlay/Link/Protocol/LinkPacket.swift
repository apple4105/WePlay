import Foundation

/// link 链路层数据包。
///
/// ## 9 字节头布局（按 Apple link 规范）
///
/// ```
///  偏移  大小  字段
///   0     2    SOP = 0xFF 0x5A
///   2     2    包总长（LE16，含这 9 字节头 + 载荷 + 载荷校验）
///   4     1    控制字节
///   5     1    序列号（置了 ACK 位时，这个字节表示"确认到哪个序列号"）
///   6     2    会话 ID（LE16；控制会话 = 0x0000）
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
/// | 6 | 0x40 | ACK（确认号有效，见序列号字段） |
/// | 5 | 0x20 | EAK 扩展确认（载荷里是一串乱序序列号） |
/// | 4 | 0x10 | RST 链路重置 |
/// | 3 | 0x08 | SLP 设备休眠 |
///
/// ## 校验
///
/// 2 的补码和：被覆盖的所有字节与校验字节相加 ≡ 0 (mod 256)。
/// 头校验覆盖偏移 2..7（长度+控制+序列+会话ID），载荷校验覆盖整个载荷。
///
///
/// 偏移 6..7 的字段切分按规范定义实施；联调时若握手失败，先打印原始 hex
/// 核对（`LinkParser` 已留 `onRawPacket` 钩子），对不上只需改 `decode`/`encode` 一处。
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
    static let controlSessionID: UInt16 = 0x0000

    // MARK: 字段

    var control: UInt8
    var sequence: UInt8
    var sessionID: UInt16
    var payload: Data

    init(control: UInt8, sequence: UInt8 = 0, sessionID: UInt16 = LinkPacket.controlSessionID, payload: Data = Data()) {
        self.control = control
        self.sequence = sequence
        self.sessionID = sessionID
        self.payload = payload
    }

    /// ACK 位是否置位
    var isACK: Bool { control & Self.controlACK != 0 }

    /// SYN 位是否置位
    var isSYN: Bool { control & Self.controlSYN != 0 }

    /// EAK 位是否置位
    var isEAK: Bool { control & Self.controlEAK != 0 }

    /// 置了 ACK 位时，序列号字段的含义变成"确认号"
    var acknowledgement: UInt8? {
        isACK ? sequence : nil
    }

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
        out.append(UInt8(total & 0xFF))
        out.append(UInt8((total >> 8) & 0xFF))
        out.append(control)
        out.append(sequence)
        out.append(UInt8(sessionID & 0xFF))
        out.append(UInt8((sessionID >> 8) & 0xFF))

        // 头校验覆盖 偏移 2..7（长度+控制+序列+会话ID 共 6 字节，不含 SOP）
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

        let length = Int(data[data.startIndex + 2]) | (Int(data[data.startIndex + 3]) << 8)
        guard length >= headerSize + 1 else { return .badSync }   // 至少有载荷校验位
        guard data.count >= length else { return .needMore }

        let base = data.startIndex
        let controlByte = data[base + 4]
        let seq = data[base + 5]
        let session = UInt16(data[base + 6]) | (UInt16(data[base + 7]) << 8)
        let headerChecksum = data[base + 8]

        let headerCovered = data[base + 2 ..< base + 8]
        guard verify(headerCovered, checksum: headerChecksum) else { return .badSync }

        let payloadStart = base + headerSize
        let payloadEnd = base + length - 1        // 最后 1 字节是载荷校验
        let payload = data[payloadStart ..< payloadEnd]
        let payloadChecksum = data[base + length - 1]
        guard verify(payload, checksum: payloadChecksum) else { return .badSync }

        return .packet(LinkPacket(control: controlByte, sequence: seq, sessionID: session, payload: Data(payload)),
                       consumed: length)
    }
}

import Foundation

/// Carlink TCP 帧层（规格：OpenXPlay oxp-clink protocol/frame.rs，2026-11-22 提炼）。
///
/// ## 20 字节头（全大端）
///
/// ```
///  偏移  大小  字段
///   0     4    总长 BE32（含这 20 字节头 + body）
///   4     4    sequence BE32
///   8     4    unix_seconds BE32
///  12     1    flags：source(bit0) | format<<1 (bit1-2) | kind<<3 (bit3-4)，高 3 位必须 0
///  13     1    category
///  14     2    method BE16
///  16     2    保留（必须 [0,0]）
///  18     2    CRC16 BE16（CRC-16/MODBUS：poly 0xa001，初值 0，覆盖前 18 字节）
///  20     N    body
/// ```
struct CarlinkFrame: Equatable {

    static let headerSize = 20
    static let maxBytes = 4 * 1024 * 1024

    var sequence: UInt32
    var unixSeconds: UInt32
    /// 0 = 车机→手机，1 = 手机→车机
    var source: UInt8
    /// 0..=3
    var format: UInt8
    /// 0..=3
    var kind: UInt8
    var category: UInt8
    var method: UInt16
    var body: Data

    init(sequence: UInt32, unixSeconds: UInt32, source: UInt8, format: UInt8,
         kind: UInt8, category: UInt8, method: UInt16, body: Data = Data()) {
        self.sequence = sequence
        self.unixSeconds = unixSeconds
        self.source = source
        self.format = format
        self.kind = kind
        self.category = category
        self.method = method
        self.body = body
    }

    // MARK: 编解码

    func encode() -> Data {
        var out = Data(capacity: Self.headerSize + body.count)
        out.appendBE32(UInt32(Self.headerSize + body.count))
        out.appendBE32(sequence)
        out.appendBE32(unixSeconds)
        out.append(source | (format << 1) | (kind << 3))
        out.append(category)
        out.appendBE16(method)
        out.append(contentsOf: [0, 0])
        let crc = Self.crc16(out)
        out.appendBE16(crc)
        out.append(body)
        return out
    }

    enum DecodeResult {
        case frame(CarlinkFrame)
        case needMore
        case badFrame(String)
    }

    /// 从字节流头部解出一帧（b 需为完整一帧）。
    static func decode(_ b: Data) -> DecodeResult {
        guard b.count >= Self.headerSize else { return .needMore }
        let length = Int(b.be32(at: 0))
        guard length >= Self.headerSize, length <= Self.maxBytes else {
            return .badFrame("invalid_packet_length")
        }
        guard b.count == length else { return .needMore }
        let flags = b[b.startIndex + 12]
        guard flags & 0xE0 == 0,
              b[b.startIndex + 16] == 0, b[b.startIndex + 17] == 0 else {
            return .badFrame("invalid_packet_header")
        }
        let crc = b.be16(at: 18)
        guard crc == Self.crc16(b.prefix(18)) else {
            return .badFrame("invalid_packet_crc")
        }
        return .frame(CarlinkFrame(
            sequence: b.be32(at: 4),
            unixSeconds: b.be32(at: 8),
            source: flags & 1,
            format: (flags >> 1) & 3,
            kind: (flags >> 3) & 3,
            category: b[b.startIndex + 13],
            method: UInt16(b.be16(at: 14)),
            body: b.subdata(in: (b.startIndex + headerSize) ..< (b.startIndex + length))
        ))
    }

    /// CRC-16/MODBUS（反射 0xa001，初值 0）
    static func crc16(_ bytes: Data) -> UInt16 {
        var c: UInt16 = 0
        for byte in bytes {
            c ^= UInt16(byte)
            for _ in 0..<8 {
                c = (c >> 1) ^ (c & 1 != 0 ? 0xA001 : 0)
            }
        }
        return c
    }
}

/// 流式拆帧：TCP 半包/粘包在此缓冲。
struct CarlinkFrameReader {
    private var buffer = Data()

    mutating func feed(_ chunk: Data) throws -> [CarlinkFrame] {
        guard buffer.count + chunk.count <= CarlinkFrame.maxBytes + 65536 else {
            throw CarlinkError.packetTooLarge
        }
        buffer.append(chunk)
        var frames: [CarlinkFrame] = []
        var pos = buffer.startIndex
        while buffer.endIndex - pos >= 4 {
            let length = Int(buffer.be32(at: pos - buffer.startIndex))
            guard length >= CarlinkFrame.headerSize, length <= CarlinkFrame.maxBytes else {
                throw CarlinkError.badPacket("invalid_packet_length")
            }
            if buffer.endIndex - pos < length { break }
            let slice = buffer.subdata(in: pos ..< pos + length)
            switch CarlinkFrame.decode(slice) {
            case .frame(let f): frames.append(f)
            case .needMore: break
            case .badFrame(let why): throw CarlinkError.badPacket(why)
            }
            pos += length
        }
        buffer.removeSubrange(buffer.startIndex ..< pos)
        return frames
    }

    mutating func reset() { buffer.removeAll(keepingCapacity: true) }
}

enum CarlinkError: Error, CustomStringConvertible {
    case packetTooLarge
    case badPacket(String)
    case authFailed(String)
    case pinRequired
    case pinConfirmationRequired
    case rejected

    var description: String {
        switch self {
        case .packetTooLarge: return "包过大"
        case .badPacket(let why): return "坏包：\(why)"
        case .authFailed(let why): return "认证失败：\(why)"
        case .pinRequired: return "车机要求配对码"
        case .pinConfirmationRequired: return "车机要求确认"
        case .rejected: return "被车机拒绝"
        }
    }
}

extension Data {
    /// 大端 32 位写入
    mutating func appendBE32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    /// 大端 32 位读取（绝对偏移，从 startIndex 起算）
    func be32(at offset: Int) -> UInt32 {
        let base = startIndex
        return (UInt32(self[base + offset]) << 24)
            | (UInt32(self[base + offset + 1]) << 16)
            | (UInt32(self[base + offset + 2]) << 8)
            | UInt32(self[base + offset + 3])
    }

    /// 大端 16 位读取（绝对偏移，从 startIndex 起算）
    func be16(at offset: Int) -> Int {
        let base = startIndex
        return (Int(self[base + offset]) << 8) | Int(self[base + offset + 1])
    }
}

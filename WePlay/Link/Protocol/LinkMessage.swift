import Foundation

/// link 控制会话消息 / 参数。
///
/// ## 线格式（2026-11-21 定稿：Wireshark 公开解析器 + CarWithin 二进制双源一致，全部大端）
///
/// ```
///  SOM          0x4040        (2 字节)
///  消息长度     BE16          (2 字节；含 SOM+长度字段+消息ID+全部参数，即整条消息的字节数)
///  消息 ID      BE16          (2 字节)
///  参数…                      (每条 = 2字节长度 + 2字节ID + 数据)
/// ```
///
/// 参数：
///
/// ```
///  参数长度  BE16   (2 字节；含 长度字段+参数ID+数据，即 4 + 数据长度)
///  参数 ID   BE16   (2 字节)
///  数据             (长度 - 4 字节)
/// ```
///
/// 长度字段都是**自包含**的（把头部算进去），最小值：消息 6、参数 4。
struct LinkMessage: Equatable {
    static let startOfMessage: (UInt8, UInt8) = (0x40, 0x40)

    var id: UInt16
    var parameters: [LinkParameter]

    init(id: UInt16, parameters: [LinkParameter] = []) {
        self.id = id
        self.parameters = parameters
    }

    func parameter(_ id: UInt16) -> LinkParameter? {
        parameters.first { $0.id == id }
    }

    /// 完整消息字节（SOM + 长度 + ID + 参数）
    func encoded() -> Data {
        var body = Data()
        for p in parameters {
            body.append(p.encoded())
        }

        var out = Data()
        out.append(Self.startOfMessage.0)
        out.append(Self.startOfMessage.1)
        out.appendBE16(UInt16(6 + body.count))   // 长度含 SOM+长度+ID 头 6 字节
        out.appendBE16(id)
        out.append(body)
        return out
    }

    enum ParseResult {
        case message(LinkMessage, consumed: Int)
        case needMore
        case badFormat
    }

    /// 从一段字节流头部解出一条消息。
    static func parse(_ data: Data) -> ParseResult {
        guard data.count >= 6 else { return .needMore }
        guard data[data.startIndex] == startOfMessage.0,
              data[data.startIndex + 1] == startOfMessage.1 else {
            return .badFormat
        }

        let length = data.be16(at: 2)
        guard length >= 6 else { return .badFormat }          // 最小 = 头 6 字节
        guard data.count >= length else { return .needMore }

        let id = UInt16(data.be16(at: 4))
        let end = data.startIndex + length

        var params: [LinkParameter] = []
        var offset = data.startIndex + 6
        while offset + 4 <= end {
            let pLen = data.be16(at: offset - data.startIndex)
            guard pLen >= 4, offset + pLen <= end else { return .badFormat }
            let pID = UInt16(data.be16(at: offset - data.startIndex + 2))
            let value = Data(data[offset + 4 ..< offset + pLen])
            params.append(LinkParameter(id: pID, value: value))
            offset += pLen
        }
        guard offset == end else { return .badFormat }

        return .message(LinkMessage(id: id, parameters: params), consumed: length)
    }
}

/// link 参数 = 长度 + ID + 数据（长度含自身 4 字节头）。
struct LinkParameter: Equatable {
    var id: UInt16
    var value: Data

    init(id: UInt16, value: Data) {
        self.id = id
        self.value = value
    }

    /// 便捷构造：整数值参数（大端）
    init(id: UInt16, uint: UInt64) {
        var v = uint
        var bytes = [UInt8]()
        while v > 0 { bytes.append(UInt8(v & 0xFF)); v >>= 8 }
        self.init(id: id, value: Data(bytes.reversed()))
    }

    /// 便捷构造：字符串参数（UTF-8）
    init(id: UInt16, string: String) {
        self.init(id: id, value: Data(string.utf8))
    }

    /// 编码成 `长度 + ID + 数据`（长度字段含自身）
    func encoded() -> Data {
        var out = Data()
        out.appendBE16(UInt16(4 + value.count))
        out.appendBE16(id)
        out.append(value)
        return out
    }

    /// 按大端整数解读（1/2/4/8 字节）
    func uintValue() -> UInt64? {
        var v: UInt64 = 0
        for b in value { v = (v << 8) | UInt64(b) }
        return value.isEmpty ? nil : v
    }

    func stringValue() -> String? {
        String(data: value, encoding: .utf8)
    }
}

import Foundation

/// link 控制会话消息 / 参数。
///
/// ## 控制会话消息结构
///
/// ```
///  SOM          0x4040        (2 字节)
///  消息长度     LE16          (2 字节；不含 SOM 与长度字段本身，含消息ID+全部参数)
///  消息 ID      LE16          (2 字节)
///  参数…                      (每条 = 2字节长度 + 2字节ID + 数据)
/// ```
///
/// ## 参数结构
///
/// ```
///  参数长度  LE16   (2 字节；不含长度字段本身，含参数ID + 数据)
///  参数 ID   LE16   (2 字节)
///  数据             (长度 - 2 字节)
/// ```
///
///   - Identification（配件向 iPhone 声明能力）
///   - Authentication（challenge/response 走这里，具体子参数待真机核对）
///   - StartSession / WiFi（`startSession(address:)`、`WiFi{ssid,password,channels}`）
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

    /// 编码成控制会话载荷（不含 SOM/长度，由调用方拼）；
    /// 需要完整消息时用 `encoded()`。
    /// 注意：link 所有多字节字段都是**小端**。
    private func body() -> Data {
        var out = Data()
        out.appendLittleEndianUInt16(id)
        for p in parameters {
            let enc = p.encode()
            out.appendLittleEndianUInt16(UInt16(enc.count + 2))   // 参数长度含 ID+数据
            out.append(enc)
        }
        return out
    }

    /// 完整消息字节（SOM + 长度 + ID + 参数）
    func encoded() -> Data {
        let body = body()
        var out = Data()
        out.append(Self.startOfMessage.0)
        out.append(Self.startOfMessage.1)
        out.appendLittleEndianUInt16(UInt16(body.count))
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

        let base = data.startIndex
        let length = Int(data[base + 2]) | (Int(data[base + 3]) << 8)
        guard length >= 2 else { return .badFormat }
        let total = 4 + length                       // SOM+长度字段 + 消息体
        guard data.count >= total else { return .needMore }

        let id = UInt16(data[base + 4]) | (UInt16(data[base + 5]) << 8)

        var params: [LinkParameter] = []
        var offset = base + 6
        let end = base + total
        while offset + 4 <= end {
            let pLen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            guard pLen >= 2, offset + pLen <= end else { return .badFormat }
            let pID = UInt16(data[offset + 2]) | (UInt16(data[offset + 3]) << 8)
            let value = Data(data[offset + 4 ..< offset + pLen])
            params.append(LinkParameter(id: pID, value: value))
            offset += pLen
        }
        guard offset == end else { return .badFormat }

        return .message(LinkMessage(id: id, parameters: params), consumed: total)
    }
}

/// link 参数 = 长度 + ID + 数据。
struct LinkParameter: Equatable {
    var id: UInt16
    var value: Data

    init(id: UInt16, value: Data) {
        self.id = id
        self.value = value
    }

    /// 便捷构造：整数值参数
    init(id: UInt16, uint: UInt64) {
        var v = uint
        var bytes = Data()
        while v > 0 { bytes.append(UInt8(v & 0xFF)); v >>= 8 }
        if bytes.isEmpty { bytes.append(0) }
        self.init(id: id, value: bytes)
    }

    /// 便捷构造：字符串参数（UTF-8）
    init(id: UInt16, string: String) {
        self.init(id: id, value: Data(string.utf8))
    }

    /// 编码出 `ID + 数据` 部分（长度字段由消息层补）
    func encode() -> Data {
        var out = Data()
        out.appendLittleEndianUInt16(id)
        out.append(value)
        return out
    }

    /// 按小端整数解读（1/2/4/8 字节）
    func uintValue() -> UInt64? {
        var v: UInt64 = 0
        for (i, b) in value.enumerated() {
            guard i < 8 else { break }
            v |= UInt64(b) << (8 * i)
        }
        return value.isEmpty ? nil : v
    }

    func stringValue() -> String? {
        String(data: value, encoding: .utf8)
    }
}

extension Data {
    /// link 多字节字段一律小端
    mutating func appendLittleEndianUInt16(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
    }
}

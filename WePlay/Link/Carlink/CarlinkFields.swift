import Foundation

/// Carlink body 的 TLV 字段层——就是 protobuf 线格式
/// （key = field << 3 | wire_type，wire: 0=varint / 1=fixed64 / 2=length-delimited / 5=fixed32）。
/// 编码按 field id 升序（Rust 侧 BTreeMap 语义）。
struct CarlinkField: Equatable {
    enum Value: Equatable {
        case varint(UInt64)
        case bytes(Data)
        case fixed64(Data)   // 8 字节
        case fixed32(Data)   // 4 字节
    }
    var id: UInt32
    var value: Value
}

enum CarlinkFields {

    static func encode(_ fields: [CarlinkField]) throws -> Data {
        let sorted = fields.sorted { $0.id < $1.id }
        var out = Data()
        for f in sorted {
            guard f.id > 0, f.id < 1 << 29 else { throw CarlinkError.badPacket("invalid_field_number") }
            switch f.value {
            case .varint(let n):
                appendVarint(&out, UInt64(f.id) << 3)
                appendVarint(&out, n)
            case .bytes(let b):
                appendVarint(&out, (UInt64(f.id) << 3) | 2)
                appendVarint(&out, UInt64(b.count))
                out.append(b)
            case .fixed64(let b):
                appendVarint(&out, (UInt64(f.id) << 3) | 1)
                out.append(b)
            case .fixed32(let b):
                appendVarint(&out, (UInt64(f.id) << 3) | 5)
                out.append(b)
            }
        }
        return out
    }

    static func decode(_ b: Data) throws -> [CarlinkField] {
        var fields: [CarlinkField] = []
        var seen = Set<UInt32>()
        var c = b.startIndex
        while c < b.endIndex {
            let key = try readVarint(b, &c)
            let id = UInt32(key >> 3)
            guard id > 0, id < 1 << 29 else { throw CarlinkError.badPacket("invalid_field_number") }
            guard seen.insert(id).inserted else { throw CarlinkError.badPacket("duplicate_field") }
            let wire = key & 7
            let value: CarlinkField.Value
            if wire == 0 {
                value = .varint(try readVarint(b, &c))
            } else {
                let n: Int
                switch wire {
                case 1: n = 8
                case 5: n = 4
                case 2: n = Int(try readVarint(b, &c))
                default: throw CarlinkError.badPacket("unsupported_wire_type")
                }
                guard c + n <= b.endIndex else { throw CarlinkError.badPacket("truncated_field") }
                let s = b.subdata(in: c ..< c + n)
                c += n
                switch wire {
                case 1: value = .fixed64(s)
                case 5: value = .fixed32(s)
                default: value = .bytes(s)
                }
            }
            fields.append(CarlinkField(id: id, value: value))
        }
        return fields
    }

    static func varintField(_ fields: [CarlinkField], _ id: UInt32) -> UInt64 {
        if let f = fields.first(where: { $0.id == id }), case .varint(let n) = f.value { return n }
        return 0
    }

    static func bytesField(_ fields: [CarlinkField], _ id: UInt32) -> Data? {
        guard let f = fields.first(where: { $0.id == id }) else { return nil }
        switch f.value {
        case .bytes(let b), .fixed64(let b), .fixed32(let b): return b
        case .varint: return nil
        }
    }

    private static func appendVarint(_ out: inout Data, _ v: UInt64) {
        var v = v
        while v >= 128 {
            out.append(UInt8(v & 127) | 128)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func readVarint(_ b: Data, _ pos: inout Data.Index) throws -> UInt64 {
        var n: UInt64 = 0
        for i in 0..<10 {
            guard pos < b.endIndex else { throw CarlinkError.badPacket("truncated_varint") }
            let v = b[pos]
            pos += 1
            if i == 9 && v > 1 { throw CarlinkError.badPacket("varint_overflow") }
            n |= UInt64(v & 127) << (7 * i)
            if v & 128 == 0 { return n }
        }
        throw CarlinkError.badPacket("varint_overflow")
    }
}

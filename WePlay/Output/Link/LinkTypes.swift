import Foundation
import CoreBluetooth

/// 显示端 BLE 链路的常量与载荷类型。
///
/// ## 载荷是 JSON，不是二进制
///
/// - 手机 → 对端（写特征 `…101`）：
///   `{"id":…,"name":…,"model":…,"band":0|1,"mac":"aa:bb:…","type":1001|1002}`
///   （`type==0` 规范成 1001；≤512 B）
/// - 对端 → 手机（读/通知特征 `…102`）：
///   `{"name":…,"ssid":…,"psk":…,"mac":…,"freq":0..7125,"port":0..65535,"type":1001|1002}`
///   （≤4096 B；MAC 小写、17 字节冒号分隔）
///
/// `type` 的 1001/1002 两个变体分别对应哪一步（初始建网 / 配对确认 / 二频段）尚未
/// 完全确认。v1 先发 1001、按回复里的 type 决定是否再发一轮，并把原始 JSON 全量
/// 打进日志，联调时对一遍即可。
enum Link {

    // MARK: - BLE UUID

    /// 对端广播的服务 UUID
    static let serviceUUID = CBUUID(string: "2ABCC850-9935-4F8A-BA84-123456789100")

    /// 手机侧特征：手机把 PhoneRequest 写到这里
    static let phoneCharacteristicUUID = CBUUID(string: "2ABCC850-9935-4F8A-BA84-123456789101")

    /// 车机侧特征：车机把 HeadUnitReply 放这里（读/通知）
    static let headUnitCharacteristicUUID = CBUUID(string: "2ABCC850-9935-4F8A-BA84-123456789102")

    /// 广播/厂商标识 UUID（车机 advertisement 里带 0xFCFB）
    static let vendorUUID = CBUUID(string: "0000FCFB-0000-1000-8000-00805F9B34FB")

    /// CCCD
    static let cccdUUID = CBUUID(string: "00002902-0000-1000-8000-00805F9B34FB")

    // MARK: - 消息变体

    static let typeNetworkBootstrap: Int = 1001
    static let typeSecondRound: Int = 1002

    // MARK: - 载荷

    /// 手机发给车机的请求
    struct PhoneRequest: Encodable {
        var id: String
        var name: String
        var model: String
        var band: Int          // 0..=1
        var mac: String        // 17 字节冒号分隔，小写
        var type: Int          // JSON 键名是 type（对应 Rust 的 kind）

        enum CodingKeys: String, CodingKey {
            case id, name, model, band, mac, type
        }

        /// 序列化成 JSON（≤512 B）
        func encode() throws -> Data {
            let out = try JSONEncoder().encode(self)
            guard out.count <= 512 else { throw LinkError.payloadTooLarge(out.count) }
            return out
        }
    }

    /// 车机回的回复
    struct HeadUnitReply: Decodable {
        var name: String
        var ssid: String
        var psk: String
        var mac: String
        var freq: Int          // 0..=7125
        var port: Int          // 0..=65535
        var type: Int          // 1001..=1002

        /// 从车机特征里收到的 JSON 解析（≤4096 B）
        static func parse(_ data: Data) throws -> HeadUnitReply {
            guard data.count <= 4096 else {
                throw LinkError.payloadTooLarge(data.count)
            }
            let reply = try JSONDecoder().decode(HeadUnitReply.self, from: data)
            guard (typeNetworkBootstrap...typeSecondRound).contains(reply.type) else {
                throw LinkError.badType(reply.type)
            }
            guard (0...7125).contains(reply.freq) else {
                throw LinkError.badFrequency(reply.freq)
            }
            guard (0...65535).contains(reply.port) else {
                throw LinkError.badPort(reply.port)
            }
            guard !reply.ssid.isEmpty, reply.ssid.count <= 32 else {
                throw LinkError.badSSID
            }
            guard !reply.psk.isEmpty, reply.psk.count <= 64 else {
                throw LinkError.badPSK
            }
            let macParts = reply.mac.split(separator: ":", omittingEmptySubsequences: false)
            guard macParts.count == 6,
                  macParts.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isHexDigit) }) else {
                throw LinkError.badMAC(reply.mac)
            }
            return reply
        }
    }
}

enum LinkError: Error, CustomStringConvertible {
    case identityNotLoaded
    case notImplemented(String)
    case payloadTooLarge(Int)
    case badType(Int)
    case badFrequency(Int)
    case badPort(Int)
    case badMAC(String)
    case badSSID
    case badPSK
    case characteristicMissing(String)
    case notConnected

    var description: String {
        switch self {
        case .identityNotLoaded: return "配件身份未装载"
        case .notImplemented(let w): return "\(w) 尚未实现"
        case .payloadTooLarge(let n): return "载荷超限：\(n) B"
        case .badType(let t): return "未知消息变体 type=\(t)（应 1001/1002）"
        case .badFrequency(let f): return "频段越界：\(f)"
        case .badPort(let p): return "端口越界：\(p)"
        case .badMAC(let m): return "MAC 格式错：\(m)"
        case .badSSID: return "SSID 格式错"
        case .badPSK: return "Wi-Fi 密码格式错"
        case .characteristicMissing(let u): return "找不到特征 \(u)"
        case .notConnected: return "尚未连上车机"
        }
    }
}

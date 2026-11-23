import Foundation

/// 配件主动发给 iPhone 的 iAP2 控制会话消息。
///
/// ## 消息 ID（2026-11-21 从 CarWithin 二进制逆向 + 全二进制 movz 扫描唯一性确认）
///
/// | 消息 | ID | 方向 |
/// |------|-----|------|
/// | identification | `0x1D01` | 配件 → iPhone |
/// | startSession | `0x4301` | 配件 → iPhone |
/// | （iOS 回应，SameDeviceProbe.handle 匹配） | `0x4300` | iPhone → 配件 |
///
/// 认证按公开 iAP2 规范：证书 `0x0021` / 挑战 `0x0022` / 应答 `0x0023` / 失败 `0x0024`。
///
/// ## identification 参数（逐条对照 CarWithin `AccessoryMessages.identification`，2026-11-23）

/// | 参数 ID | 内容 |
/// |---------|------|
/// | 0 | name |
/// | 1..5 | `"CP-Receiver-1"` / `"OEM"` / `"SN000001"` / `"1.0.0"` / `"1.0.0"` |
/// | 6 | `[0x43,0x01]` = MessagesReceived 位掩码（含 0x4301） |
/// | 7 | `[0x43,0x00]` = MessagesSent 位掩码（含 0x4300） |
/// | 8 | `[0x00]` 供电能力 |
/// | 9 | `[0x00,0x00]` 最大取流 |
/// | 12/13 | `"en"` 语言 |
/// | 0x10 组 | `[0:[0,1], 1:"USBHost", 2:[], 3:[1], 4:[]]` 传输编号 1 |
/// | 0x11 组 | `[0:[0,2], 1:"Bluetooth", 2:[], 3:MAC(6B)]` 传输编号 2 |
/// | 0x18 组 | `[0:[0,3], 1:"WiFiCarPlay", 2:[], 4:[]]` 传输编号 3 |
///
/// 字符串参数**必须 NUL 结尾**（CarWithin `string()` = utf8 + 0x00）。
/// param 6..9 是消息位掩码/电气参数，**不是放设备 ID 的地方**——早前误填导致
/// iOS 收到 identification 后毫无回应（0.0.1-b65 真机实锤：发了 15 参数但零回包）。
enum AccessoryMessages {

    // MARK: - identification

    /// 配件身份声明。发出去之后 iOS 才会知道"有台 CarPlay 车机接上了"。
    /// - Parameter mac: `"AA:BB:CC:DD:EE:FF"` 形式，解析出 6 字节
    static func identification(name: String, mac: String) -> LinkMessage {
        let macBytes = Data(hexString: mac) ?? Data(repeating: 0, count: 6)
        // 字符串一律 NUL 结尾
        let s: (UInt16, String) -> LinkParameter = { id, v in
            LinkParameter(id: id, value: Data(v.utf8) + Data([0]))
        }

        let usb = LinkParameter(id: 0x10, value: encodedGroup([
            LinkParameter(id: 0, value: Data([0, 1])),   // 传输编号 1
            s(1, "USBHost"),
            LinkParameter(id: 2, value: Data()),
            LinkParameter(id: 3, value: Data([1])),
            LinkParameter(id: 4, value: Data()),
        ]))

        let bluetooth = LinkParameter(id: 0x11, value: encodedGroup([
            LinkParameter(id: 0, value: Data([0, 2])),   // 传输编号 2
            s(1, "Bluetooth"),
            LinkParameter(id: 2, value: Data()),
            LinkParameter(id: 3, value: macBytes),
        ]))

        let wifi = LinkParameter(id: 0x18, value: encodedGroup([
            LinkParameter(id: 0, value: Data([0, 3])),   // 传输编号 3
            s(1, "WiFiCarPlay"),
            LinkParameter(id: 2, value: Data()),
            LinkParameter(id: 4, value: Data()),
        ]))

        return LinkMessage(id: 0x1D01, parameters: [
            s(0, name),
            s(1, "CP-Receiver-1"),
            s(2, "OEM"),
            s(3, "SN000001"),
            s(4, "1.0.0"),
            s(5, "1.0.0"),
            LinkParameter(id: 6, value: Data([0x43, 0x01])),   // MessagesReceived
            LinkParameter(id: 7, value: Data([0x43, 0x00])),   // MessagesSent
            LinkParameter(id: 8, value: Data([0x00])),
            LinkParameter(id: 9, value: Data([0x00, 0x00])),
            s(12, "en"),
            s(13, "en"),
            usb, bluetooth, wifi,
        ])
    }

    // MARK: - startSession

    /// 把媒体会话指向 App 自己的 MediaTCPListener（同机回环）。
    ///
    /// 对照 CarWithin `startSession`：param 0 = 地址组、param 2 = 端口（BE32）、
    /// param 3 = deviceID、param 5 = sourceVersion；无线时 param 1 = Wi-Fi 组。
    static func startSession(address: String, port: UInt16, deviceID: String) -> LinkMessage {
        let portBytes = Data([0, 0, UInt8(truncatingIfNeeded: port >> 8), UInt8(truncatingIfNeeded: port)])
        let addressGroup = LinkParameter(id: 0, value: encodedGroup([
            LinkParameter(id: 0, value: Data(address.utf8) + Data([0])),
        ]))
        return LinkMessage(id: 0x4301, parameters: [
            addressGroup,
            LinkParameter(id: 2, value: portBytes),
            LinkParameter(id: 3, value: Data(deviceID.utf8) + Data([0])),
            LinkParameter(id: 4, value: Data([0])),
            LinkParameter(id: 5, value: Data("509.11".utf8) + Data([0])),
        ])
    }

    // MARK: - MFi 认证

    /// 把配件证书链发给 iPhone（消息 0x0021）。
    static func authenticationCertificate(chain: Data) -> LinkMessage {
        LinkMessage(id: 0x0021, parameters: [
            LinkParameter(id: 0x000B, value: chain),   // Authentication Certificate
        ])
    }

    /// 对 challenge 签名并回 0x0023。
    static func authenticationResponse(signature: Data) -> LinkMessage {
        LinkMessage(id: 0x0023, parameters: [
            LinkParameter(id: 0x000E, value: signature),   // Authentication Response Data
        ])
    }

    // MARK: - 组参数

    /// 组参数 = 一条参数，其数据是若干子参数的完整编码。
    private static func encodedGroup(_ params: [LinkParameter]) -> Data {
        var out = Data()
        for p in params { out.append(p.encoded()) }
        return out
    }
}

private extension Data {
    /// "AA:BB:CC…" / "AABBCC" → 字节；解析失败返回 nil
    init?(hexString: String) {
        let clean = hexString.filter { $0.isHexDigit }
        guard clean.count % 2 == 0, !clean.isEmpty else { return nil }
        var bytes = [UInt8]()
        var it = clean.utf8.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let h = UInt8(String(UnicodeScalar(hi)), radix: 16),
                  let l = UInt8(String(UnicodeScalar(lo)), radix: 16) else { return nil }
            bytes.append(h << 4 | l)
        }
        self.init(bytes)
    }
}

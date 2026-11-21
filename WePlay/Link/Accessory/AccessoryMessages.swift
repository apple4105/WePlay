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
/// ## identification 参数（CarWithin `identification(name:deviceID:)` 逐条反汇编）
///
/// | 参数 ID | 内容 | 来源 |
/// |---------|------|------|
/// | 0 | name 实参 | 调用方 |
/// | 1 | `"CP-Receiver-1"` | 常量 |
/// | 2 | `"OEM"` | 常量 |
/// | 3 | `"SN000001"` | 常量 |
/// | 4/5 | `"1.0.0"` | 常量（固件/硬件版本） |
/// | 6..9 | Data（deviceID 十六进制解析出的字节） | 实参 |
/// | 12/13 | `"en"` | 常量（语言） |
/// | 0x10 组 | `[0:Data, 1:"USBHost", 2:nil, 3:Data, 4:nil]` | 传输能力 |
/// | 0x11 组 | `[0:Data, 1:"Bluetooth", 2:nil, 3:Data]` | 传输能力 |
/// | 0x18 组 | `[0:Data, 1:"WiFiCarPlay", 2:nil, 4:nil]` | 传输能力 |
///
/// 参数 6..9 的确切切分与屏幕/编解码能力声明（W×H、fps、AVC-only）留待真机
/// 用诊断日志校准——iOS 的回应会直接暴露它期望的字段。
enum AccessoryMessages {

    // MARK: - identification

    /// 配件身份声明。发出去之后 iOS 才会知道"有台 CarPlay 车机接上了"。
    static func identification(name: String, deviceID: String) -> LinkMessage {
        let uid = Data(hexString: deviceID) ?? Data()

        let usb = LinkParameter(id: 0x10, value: encodedGroup([
            LinkParameter(id: 0, value: uid),                          // 设备字节
            LinkParameter(id: 1, string: "USBHost"),                   // 传输名
            LinkParameter(id: 2, value: Data()),                       // nil 占位
            LinkParameter(id: 3, value: uid),
            LinkParameter(id: 4, value: Data()),
        ]))

        let bluetooth = LinkParameter(id: 0x11, value: encodedGroup([
            LinkParameter(id: 0, value: uid),
            LinkParameter(id: 1, string: "Bluetooth"),
            LinkParameter(id: 2, value: Data()),
            LinkParameter(id: 3, value: uid),
        ]))

        let wifi = LinkParameter(id: 0x18, value: encodedGroup([
            LinkParameter(id: 0, value: uid),
            LinkParameter(id: 1, string: "WiFiCarPlay"),
            LinkParameter(id: 2, value: Data()),
            LinkParameter(id: 4, value: Data()),
        ]))

        return LinkMessage(id: 0x1D01, parameters: [
            LinkParameter(id: 0, string: name),
            LinkParameter(id: 1, string: "CP-Receiver-1"),
            LinkParameter(id: 2, string: "OEM"),
            LinkParameter(id: 3, string: "SN000001"),
            LinkParameter(id: 4, string: "1.0.0"),
            LinkParameter(id: 5, string: "1.0.0"),
            LinkParameter(id: 6, value: uid),
            LinkParameter(id: 7, value: uid),
            LinkParameter(id: 8, value: uid),
            LinkParameter(id: 9, value: uid),
            LinkParameter(id: 12, string: "en"),
            LinkParameter(id: 13, string: "en"),
            usb, bluetooth, wifi,
        ])
    }

    // MARK: - startSession

    /// 把媒体会话指向 App 自己的 MediaTCPListener（同机回环）。
    /// iOS 收到后会把 H.264/音频流连到 `address:port`。
    ///
    /// 参数布局：param 0 = 地址（反汇编确证）；param 1..3 为最贴近
    /// CarWithin 结构的重构（端口/设备ID/版本串），确切分组留待真机校准。
    static func startSession(address: String, port: UInt16, deviceID: String) -> LinkMessage {
        return LinkMessage(id: 0x4301, parameters: [
            LinkParameter(id: 0, string: address),
            LinkParameter(id: 1, uint: UInt64(port)),
            LinkParameter(id: 2, string: deviceID),
            LinkParameter(id: 3, string: "509.11"),
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

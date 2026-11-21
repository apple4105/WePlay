import Foundation

/// CarPlay 的输入回传：USB HID 报告描述符 + 触摸/按键报告。
///
/// CarPlay 的触摸/按键不是自定义协议——**配件就是一个 USB HID 设备**，
/// iPhone 通过 iAP2 的 HID 通道读报告。所以要做的只是：
///   1. 提供 HID Report Descriptor（声明自己是触摸屏 + 可选旋钮/按键）
///   2. 每次车机触摸时按描述符格式组一个 report 发过去
///
/// 描述符照标准 USB HID 多点触摸数字化仪定义（Usage Page 0x0D Digitizers）。
final class CarPlayHID {

    // MARK: - 触摸事件

    struct TouchContact {
        var id: UInt8         // 触点编号（多点）
        var x: UInt16         // 归一化 0..1（按描述符 logical range 换算）
        var y: UInt16
        var pressure: UInt8?
    }

    enum TouchPhase {
        case down             // 报告里 tip switch = 1
        case move
        case up               // 报告里 tip switch = 0
    }

    // MARK: - HID Report Descriptor（十六进制字节流，标准 USB HID 格式）

    /// 多点触摸数字化仪描述符（单触点版本——CarPlay 最低要求）。
    /// Usage Page(Digitizers) → Usage(TouchScreen) → 点集合 → TipSwitch + X/Y。
    /// 这个描述符字段排布是标准 USB HID Touch Screen 的最小实现。
    static let touchReportDescriptor: [UInt8] = [
        0x05, 0x0D,        // Usage Page (Digitizers)
        0x09, 0x04,        // Usage (Touch Screen)
        0xA1, 0x01,        // Collection (Application)
        0x09, 0x22,        //   Collection (Finger)
        0x09, 0x42,        //     Usage (Tip Switch)
        0x15, 0x00,        //     Logical Min 0
        0x25, 0x01,        //     Logical Max 1
        0x75, 0x01,        //     Report Size 1
        0x95, 0x01,        //     Report Count 1
        0x81, 0x02,        //     Input (Data,Var,Abs)
        0x09, 0x32,        //     Usage (In Range)
        0x81, 0x02,        //     Input (Data,Var,Abs)
        0x95, 0x06,        //     Report Count 6 (padding)
        0x81, 0x03,        //     Input (Const,Var,Abs)
        0x05, 0x01,        //     Usage Page (Generic Desktop)
        0x09, 0x30,        //     Usage (X)
        0x26, 0xFF, 0xFF,  //     Logical Max 65535
        0x75, 0x10,        //     Report Size 16
        0x95, 0x01,        //     Report Count 1
        0x81, 0x02,        //     Input (Data,Var,Abs)
        0x09, 0x31,        //     Usage (Y)
        0x81, 0x02,        //     Input (Data,Var,Abs)
        0xC0,              //   End Collection (Finger)
        0xC0,              // End Collection (Application)
    ]

    /// 构造一条触摸 report（按上面的描述符：1B status + 2B X + 2B Y = 5 字节）
    static func touchReport(_ phase: TouchPhase, x: UInt16, y: UInt16) -> Data {
        // status byte: bit0 = tip switch
        let tip: UInt8 = (phase == .up) ? 0x00 : 0x01
        var report = Data([tip])
        report.appendBigEndianUInt16(x)
        report.appendBigEndianUInt16(y)
        return report
    }

    // MARK: - 按键（方向盘/按键面板，可选）

    /// 消费控制类按键 HID 描述符（播放/暂停/下一首/音量等——CarPlay 支持集）
    /// 车机按键通过 iAP2 的按键事件 → 我们映射成 HID Consumer Control 报告
    static let mediaKeyReportDescriptor: [UInt8] = [
        0x05, 0x0C,        // Usage Page (Consumer)
        0x09, 0x01,        // Usage (Consumer Control)
        0xA1, 0x01,        // Collection (Application)
        0x15, 0x00,        // Logical Min 0
        0x25, 0x01,        // Logical Max 1
        0x75, 0x01,        // Report Size 1
        0x95, 0x02,        // Report Count 2 (2 个按钮位)
        0x09, 0xB5,        //   Usage (Scan Next Track)
        0x09, 0xB6,        //   Usage (Scan Previous Track)
        0x81, 0x02,        // Input (Data,Var,Abs)
        0x09, 0xCD,        //   Usage (Play/Pause)
        0x81, 0x02,        // Input
        0x95, 0x05,        // Report Count 5 (padding)
        0x81, 0x03,        // Input (Const)
        0xC0,              // End Collection
    ]

    enum MediaKey: UInt8 {
        case nextTrack = 0x01
        case previousTrack = 0x02
        case playPause = 0x04
    }

    static func mediaKeyReport(_ key: MediaKey, pressed: Bool) -> Data {
        let bit = key.rawValue
        let report: UInt8 = pressed ? bit : 0x00
        return Data([report])
    }
}

/// 触摸会话：接收车机 UIBC 的触摸 → 转换坐标 → 组 HID report → 发给 iPhone。
final class TouchRelay {

    var onLog: ((String) -> Void)?

    /// 目标屏幕尺寸（车机 `wfd_car_display_mode` 里的 display=W:H）
    var displayWidth: Int = 1920
    var displayHeight: Int = 1080

    /// 产出 HID touch report（由会话层发到 iPhone）
    var onTouchReport: ((Data) -> Void)?

    private var lastPhase: CarPlayHID.TouchPhase?

    /// 收到车机 UIBC 的归一化坐标 → 转 HID report
    func handleTouch(phase: String, normalizedX: Int, normalizedY: Int) {
        // 归一化 0..65535 → 描述符 logical 0..65535（一致，无需换算坐标值本身）
        let x = UInt16(clamping: normalizedX)
        let y = UInt16(clamping: normalizedY)

        let hidPhase: CarPlayHID.TouchPhase
        switch phase {
        case "down": hidPhase = .down
        case "move": hidPhase = .move
        case "up":   hidPhase = .up
        default:     return
        }

        // 上报规则：move 只在 down 之后有意义；up 之后没有 move
        switch (lastPhase, hidPhase) {
        case (nil, .move):
            // 没有按下就 move：补一个 down 再 move
            onTouchReport?(CarPlayHID.touchReport(.down, x: x, y: y))
            onTouchReport?(CarPlayHID.touchReport(.move, x: x, y: y))
        case (.up, .move):
            onTouchReport?(CarPlayHID.touchReport(.down, x: x, y: y))
            onTouchReport?(CarPlayHID.touchReport(.move, x: x, y: y))
        default:
            onTouchReport?(CarPlayHID.touchReport(hidPhase, x: x, y: y))
        }
        lastPhase = hidPhase

        if hidPhase == .up {
            lastPhase = nil
        }
    }
}

extension Data {
    mutating func appendBigEndianUInt16(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }
}

import Foundation

/// Display Input（User Input Back Channel）——车机的触摸事件怎么回到我们这侧。
///
///
/// ```
/// wfd_uibc_capability: input_category_list=GENERIC;
///                      generic_cap_list=Keyboard, Mouse, SingleTouch;
///                      hidc_cap_list=none;
///                      port=none
/// ```
///
/// **`port=none` 的含义：Input 复用 RTSP 连接**，不开独立端口。
/// 所以车机的触摸事件是以 RTSP 消息的形式发过来的，不是单独的 TCP/UDP 通道。
///
/// 另外车机支持加密 Input（`uibc_encrypted=true`），但它的日志里有
/// "Source do not support uibc encprted" 的降级分支——我们声明不支持即可降级。
///
/// ## Input 报文格式（Display 规范 §Input）
///
/// ```
///  0        1        2        3        4..
/// +--------+--------+--------+--------+
/// | version|  MBZ   |  input category  |
/// |  (0)   |  (0)   |  GENERIC=1 / HIDC=2 |
/// +--------+--------+--------+--------+
/// | input type (GENERIC)               |
/// +--------+--------+--------+--------+
/// | 长度 (LE16) | 时间戳 (LE32) | 载荷…
/// ```
///
/// GENERIC 类下的 input type：
/// - 0 = Mouse（绝对坐标，含按键）
/// - 1 = Keyboard（含修饰键 + 键码）
/// - 2 = SingleTouch（单点触摸：down/move/up + 绝对坐标）
///
/// 我们只实现 **SingleTouch**（车机 generic_cap_list 里有，够 Link 用）。
final class InputServer {

    static let defaultPort: UInt16 = 0     // port=none → 复用 RTSP

    var onLog: ((String) -> Void)?

    /// 收到车机的触摸事件（坐标是车机屏幕坐标系，0..65535 归一化）
    var onTouch: ((TouchEvent) -> Void)?

    /// 收到的 Input 报文分类（调试用）
    var onUnknownMessage: ((Data) -> Void)?

    init() {}

    // MARK: - 收

    /// 处理一条从 RTSP 连接上收到的 Input 报文。
    /// - Parameter payload: Input 报文体（已去掉 RTSP 头）
    func handle(_ payload: Data) {
        guard payload.count >= 4 else {
            onUnknownMessage?(payload)
            return
        }
        let bytes = [UInt8](payload)

        let version = bytes[0] >> 4
        let inputCategory = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
        guard version == 0 else {
            onLog?("[Input] 不支持的版本 \(version)")
            onUnknownMessage?(payload)
            return
        }

        switch inputCategory {
        case 1:  // GENERIC
            handleGeneric(Data(bytes[4...]))
        case 2:  // HIDC
            onLog?("[Input] 车机发了 HIDC 类输入（我们没声明 HIDC，忽略）")
            onUnknownMessage?(payload)
        default:
            onLog?("[Input] 未知 input category \(inputCategory)")
            onUnknownMessage?(payload)
        }
    }

    private func handleGeneric(_ data: Data) {
        guard data.count >= 4 else { onUnknownMessage?(data); return }
        let bytes = [UInt8](data)
        let inputType = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let length = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)

        switch inputType {
        case 2:  // SingleTouch
            parseSingleTouch(Data(bytes[4...]), declaredLength: Int(length))
        case 0:
            onLog?("[Input] 收到 Mouse 事件（暂不处理）")
            onUnknownMessage?(data)
        case 1:
            onLog?("[Input] 收到 Keyboard 事件（暂不处理）")
            onUnknownMessage?(data)
        default:
            onLog?("[Input] 未知 GENERIC input type \(inputType)")
            onUnknownMessage?(data)
        }
    }

    /// SingleTouch 载荷：
    /// ```
    ///  +0  1B  event type: 0=down 1=move 2=up
    ///  +1  2B  保留（0）
    ///  +3  2B  X（LE16，归一化 0..65535）
    ///  +5  2B  Y（LE16，归一化 0..65535）
    /// ```
    private func parseSingleTouch(_ data: Data, declaredLength: Int) {
        guard data.count >= 7 else {
            onLog?("[Input] SingleTouch 报文太短：\(data.count) B")
            onUnknownMessage?(data)
            return
        }
        let bytes = [UInt8](data)
        let eventType = bytes[0]
        let x = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
        let y = UInt16(bytes[5]) | (UInt16(bytes[6]) << 8)

        let phase: TouchEvent.Phase
        switch eventType {
        case 0: phase = .down
        case 1: phase = .move
        case 2: phase = .up
        default:
            onLog?("[Input] 未知 SingleTouch event type \(eventType)")
            onUnknownMessage?(data)
            return
        }

        onTouch?(TouchEvent(phase: phase, normalizedX: x, normalizedY: y))
    }

    // MARK: - 我们声明不支持加密（让车机降级）

    /// SET_PARAMETER 里 Input 能力声明
    static func capabilityString(port: UInt16 = 0) -> String {
        // port=0 → 复用 RTSP 连接（车机声明就是 port=none）
        "input_category_list=GENERIC;generic_cap_list=Keyboard, Mouse, SingleTouch;hidc_cap_list=none;port=\(port)"
    }

    // MARK: - 事件

    struct TouchEvent {
        enum Phase { case down, move, up }
        var phase: Phase
        /// 归一化坐标（0..65535），要乘上车机屏幕宽高才是像素
        var normalizedX: UInt16
        var normalizedY: UInt16

        /// 换算成车机屏幕像素坐标
        func pixel(in display: CarDisplayMode) -> (x: Int, y: Int) {
            let x = Int(normalizedX) * display.width / 65535
            let y = Int(normalizedY) * display.height / 65535
            return (x, y)
        }
    }
}

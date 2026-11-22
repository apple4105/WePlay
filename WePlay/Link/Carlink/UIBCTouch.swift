import Foundation

/// UIBC 触摸解析（WFD 1.0 generic body， SingleTouch）。
///
/// ## 帧格式（best-effort，真机校准点）
/// UIBC generic input frame：body = [长度 BE16][触点数][每触点：opcode(1B) | x BE16 | y BE16]
/// opcode：0x04 down / 0x05 move / 0x06 up（指纹鲁棒：缓冲里扫描合法 opcode+坐标模式）。
/// 真机对不上时诊断 hex 只改 parse 一处。
enum UIBCTouch {

    enum Phase: String {
        case down, move, up
    }

    struct Touch {
        let phase: Phase
        /// 归一化 0..65535
        let x: Int
        let y: Int
    }

    static let opDown: UInt8 = 0x04
    static let opMove: UInt8 = 0x05
    static let opUp: UInt8 = 0x06

    /// 从一段字节流提取所有可识别的触点。
    /// 容错策略：跳过非 0x04/05/06 头字节（头部若有额外字段自动滑过）。
    static func parse(_ data: Data) -> [Touch] {
        var touches: [Touch] = []
        var i = 0
        let bytes = [UInt8](data)
        while i + 5 <= bytes.count {
            let op = bytes[i]
            let phase: Phase?
            switch op {
            case opDown: phase = .down
            case opMove: phase = .move
            case opUp: phase = .up
            default: phase = nil
            }
            guard let p = phase else { i += 1; continue }
            let x = Int(bytes[i + 1]) << 8 | Int(bytes[i + 2])
            let y = Int(bytes[i + 3]) << 8 | Int(bytes[i + 4])
            touches.append(Touch(phase: p, x: x, y: y))
            i += 5
        }
        return touches
    }
}

/// "返回车机"手势：投屏画面左上角区域按下保持 1.5 秒 → teardown 回车机桌面。
/// （CarLink 的"返回车机"是手机端框架画在投屏内容里的；我们投的是 CarPlay 裸画面，
///  用角落长按等效实现——比 OpenXPlay 多的入口。）
final class ReturnGesture {

    /// 触发区域（归一化比例）
    static let regionWidth = 0.08
    static let regionHeight = 0.10
    static let holdSeconds: TimeInterval = 1.5

    private var downAt: Date?
    private var fired = false

    /// 处理一个触点；命中时执行 onReturn（主线程）
    func handle(_ t: UIBCTouch.Touch, onReturn: @escaping () -> Void) {
        switch t.phase {
        case .down:
            let inRegion = Double(t.x) / 65535 < ReturnGesture.regionWidth
                && Double(t.y) / 65535 < ReturnGesture.regionHeight
            if inRegion {
                downAt = Date()
                fired = false
                DispatchQueue.main.asyncAfter(deadline: .now() + ReturnGesture.holdSeconds) { [weak self] in
                    guard let self, let at = self.downAt, !self.fired,
                          Date().timeIntervalSince(at) >= ReturnGesture.holdSeconds - 0.05 else { return }
                    self.fired = true
                    onReturn()
                }
            } else {
                downAt = nil
            }
        case .move:
            if let at = downAt, !fired {
                let out = Double(t.x) / 65535 >= ReturnGesture.regionWidth
                    || Double(t.y) / 65535 >= ReturnGesture.regionHeight
                if out { downAt = nil }
            }
        case .up:
            downAt = nil
        }
    }

    func reset() {
        downAt = nil
        fired = false
    }
}

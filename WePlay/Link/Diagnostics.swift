import Foundation
import UIKit

/// 全局诊断中心：所有模块的日志都汇到这里。
///
/// 设计目标：**真机调试不依赖 Xcode 控制台**——
/// 1. 所有模块的 onLog/onFailure 都汇到这里（带时间戳+模块名）
/// 2. 环形缓冲保留最近 500 条
/// 3. 持久化到文件（App 重启不丢）
/// 4. `exportText()` 产出完整报告（UI 一键导出）
///
/// 用法：
/// ```swift
/// Diagnostics.shared.log("模块名", "消息")
/// Diagnostics.shared.error("模块名", "错误")
/// Diagnostics.shared.exportText()
/// ```
final class Diagnostics {

    static let shared = Diagnostics()

    // MARK: - 存储

    private var buffer: [(time: String, module: String, level: String, message: String)] = []
    private let maxLines = 500
    private let lock = NSLock()

    /// UI 实时刷新钩子
    var onUpdate: ((String) -> Void)?

    // MARK: - 写入

    func log(_ module: String, _ message: String) {
        append(module: module, level: "INFO", message: message)
    }

    func warn(_ module: String, _ message: String) {
        append(module: module, level: "WARN", message: message)
    }

    func error(_ module: String, _ message: String) {
        append(module: module, level: "ERROR", message: message)
    }

    /// 记录原始 hex（协议调试用）
    func hex(_ module: String, _ label: String, _ data: Data) {
        let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined()
        let suffix = data.count > 64 ? "…(\(data.count) B)" : ""
        append(module: module, level: "HEX", message: "\(label) [\(data.count)B] \(hex)\(suffix)")
    }

    private func append(module: String, level: String, message: String) {
        lock.lock()
        defer { lock.unlock() }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let time = formatter.string(from: Date())

        buffer.append((time, module, level, message))
        if buffer.count > maxLines {
            buffer.removeFirst(buffer.count - maxLines)
        }

        let line = "[\(time)] [\(level)] [\(module)] \(message)"
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(line)
        }
    }

    // MARK: - 导出

    /// 当前缓冲的日志条数（UI 显示"共 N 条"用）
    var lineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    /// 完整诊断文本（UI 导出按钮调用）
    func exportText() -> String {
        lock.lock()
        defer { lock.unlock() }

        var out = """
        ═══════════════════════════════════════
        WePlay 诊断报告
        ═══════════════════════════════════════
        系统: iOS \(UIDevice.current.systemVersion)
        机型: \(UIDevice.current.model)
        App:  \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "?"))
        导出: \(Date())

        ── 最近 \(buffer.count) 条日志 ──

        """
        for entry in buffer {
            out += "[\(entry.time)] [\(entry.level)] [\(entry.module)] \(entry.message)\n"
        }
        out += "═══════════════════════════════════════\n"
        return out
    }

    /// 持久化（App 进入后台时调用）
    func persistToDisk() {
        lock.lock()
        defer { lock.unlock() }
        let text = exportText()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? text.write(to: dir.appendingPathComponent("diagnostics.log"), atomically: true, encoding: .utf8)
    }

    /// 把完整报告写成 .txt 临时文件，供分享/AirDrop/存文件使用。
    ///
    /// 比直接分享字符串可靠：长文本走 AirDrop/微信经常被截断或失败，
    /// 文件附件不会。
    func exportFileURL() -> URL? {
        let text = exportText()
        let name = "weplay-diag-\(Int(Date().timeIntervalSince1970)).txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

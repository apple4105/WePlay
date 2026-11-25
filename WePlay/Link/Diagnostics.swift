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

    /// 日志文件句柄——**每行立即同步落盘**。
    ///
    /// 之前只在进后台时 `persistToDisk()`，App 一崩全丢，导致每次闪退都拿不到现场
    /// （用户反馈"点完启动就闪退，日志因为重新打开都采集不到"）。现在每行都写盘 +
    /// `synchronizeFile()`（fsync），崩溃也不丢最后几行。
    private var logFile: FileHandle?

    /// 日志文件 URL（启动时加载上次会话用）
    static var logFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics.log")
    }

    /// UI 实时刷新钩子
    var onUpdate: ((String) -> Void)?

    // MARK: - 初始化 / 历史加载

    private init() {
        openLogFile()
        loadPreviousSession()
    }

    private func openLogFile() {
        let url = Self.logFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // 超过 1 MB 就截断重来，避免无限增长
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            try? Data().write(to: url)
        }
        logFile = try? FileHandle(forWritingTo: url)
        try? logFile?.seekToEnd()          // 定位到文件末尾，追加写
    }

    /// 把上次会话的日志尾部载入缓冲，并在 UI 里标出会话边界。
    /// 这样闪退后重新打开 App，诊断页仍看得到崩溃前的现场。
    private func loadPreviousSession() {
        guard let text = try? String(contentsOf: Self.logFileURL, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let tail = lines.suffix(maxLines)
        var loaded = 0
        for line in tail {
            guard let s = String(line) as String?, !s.isEmpty else { continue }
            // 文件里是 "[time] [level] [module] message" 的扁平格式，拆回元组
            let parts = s.components(separatedBy: "] ")
            if parts.count >= 4 {
                let time = parts[0].replacingOccurrences(of: "[", with: "")
                let level = parts[1].replacingOccurrences(of: "[", with: "")
                let module = parts[2].replacingOccurrences(of: "[", with: "")
                let message = parts[3...].joined(separator: "] ")
                buffer.append((time, module, level, message))
                loaded += 1
            }
        }
        if loaded > 0 {
            // 会话分隔标记，让用户知道前面是上次的
            let sep = (time: "────", module: "会话", level: "INFO",
                       message: "↑ 上次会话（崩溃前）的 \(loaded) 条；↓ 本次会话")
            buffer.append(sep)
            writeToDisk("[────] [INFO] [会话] 上次会话载入 \(loaded) 条")
        }
    }

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
        // 立即同步落盘——崩溃也不丢最后几行（用户痛点：闪退后日志全没）
        writeToDisk(line)
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(line)
        }
    }

    /// 追加一行到日志文件并 fsync。调用方需持有 `lock`。
    private func writeToDisk(_ line: String) {
        guard let handle = logFile else { return }
        handle.write(Data((line + "\n").utf8))
        handle.synchronizeFile()
    }

    // MARK: - 导出

    /// 清空内存和持久化诊断日志。
    ///
    /// 保留一条新的会话标记，方便确认清空已经生效。
    func clear() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        try? logFile?.close()
        logFile = nil
        try? Data().write(to: Self.logFileURL, options: .atomic)
        openLogFile()
        lock.unlock()
        log("诊断", "日志已清空，开始新会话")
    }

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

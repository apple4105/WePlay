import AppIntents
import Foundation

/// 快捷指令入口——Shortcuts 自动化的触发器（Wi-Fi 加入 DIRECT-xxx / 蓝牙连接车机）
/// 可以后台调用本意图，实现"点一下车机 ICCOA → 手机自动开始投屏"。
@available(iOS 16.0, *)
struct ConnectCarIntent: AppIntent {

    static var title: LocalizedStringResource = "连接车机"
    static var description: IntentDescription = .init(
        "启动 WePlay 的车机连接流程（Carlink 认证 + 投屏）",
        categoryName: "WePlay"
    )
    /// 后台执行：不把 App 拉到前台（自动化触发时无感）
    static var openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let dialog: String = await MainActor.run {
            LinkController.shared.start()
            if LinkController.shared.connectFromShortcut() {
                return "正在连接车机（使用缓存凭证）"
            }
            return "正在搜索车机…"
        }
        return .result(dialog: dialog)
    }
}

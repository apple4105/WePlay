import UIKit

/// App 入口。
///
/// v1 只做：建窗口 + 拉起根视图控制器 + 准备链路子系统占位。
/// 后续 M3（虚拟 accessory）会在这里启动 `AccessorySession`。
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    /// 链路子系统
    let link = LinkController()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        #if DEBUG
        print("[App] didFinishLaunching")
        #endif

        // 尝试装载配件身份；失败只告警不退出（方便先开发 UI / 其它模块）
        do {
            try link.loadIdentity()
        } catch {
            #if DEBUG
            print("[App] 配件身份装载失败：\(error)")
            #endif
        }

        return true
    }

    // MARK: UISceneSession lifecycle

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    }
}

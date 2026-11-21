import SwiftUI

@main
struct WePlayApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}

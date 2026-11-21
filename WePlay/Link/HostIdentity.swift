import Foundation
import UIKit

/// 我们向车机/iPhone 表明的身份信息。
enum HostIdentity {

    /// 对端界面上显示的本机名
    static var deviceName: String {
        // 可后续在设置里改
        "WePlay"
    }

    static var deviceID: String {
        UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }
}

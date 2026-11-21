import Foundation
import NetworkExtension

/// 加入显示端的 Wi-Fi 网络。
///
/// 对端在本模式下是 Wi-Fi Direct 的 Group Owner，BLE 握手下发的 SSID 形如
/// `DIRECT-xxx-…`。iPhone **不需要实现 P2P 协议**：P2P group 本质上就是一个
/// WPA2-PSK 网络，当普通 Wi-Fi 加入即可。
///
/// ## 两条路
///
/// 1. **自动加入**（`NEHotspotConfiguration`）：需要
///    `com.apple.developer.networking.HotspotConfiguration` entitlement（付费账号）。
///    系统每次弹"是否加入 DIRECT-xxx 网络？"的对话框，因为用 `joinOnce = true`。
/// 2. **手动加入**：App 把 BLE 拿到的 SSID/PSK 显示出来，让用户去
///    "设置 → Wi-Fi" 连一次。零授权、免费账号可开发。
///    iOS 会记住这个网络，对端凭证不变的话之后自动连，只需手动连一次。
///
/// 两条都实现，用 `useHotspotConfiguration` 开关切；没 entitlement 时
/// 自动 fallback 到手动（把凭证显示给用户）。
struct WiFiJoiner {

    var onLog: ((String) -> Void)?

    /// 是否尝试用 NEHotspotConfiguration（没 entitlement 会失败并 fallback）
    var useHotspotConfiguration = true

    /// 加入成功
    var onJoined: ((String) -> Void)?

    /// 需要用户手动加入（把 SSID/PSK 显示出来）
    var onManualJoinRequired: ((ssid: String, psk: String) -> Void)?

    /// 失败
    var onFailure: ((Error) -> Void)?

    /// 加入车机网络。
    /// - Parameters:
    ///   - ssid: BLE 握手里拿到的（形如 DIRECT-xxx）
    ///   - psk: BLE 握手里拿到的密码
    func join(ssid: String, psk: String, joinOnce: Bool = true) {
        onLog?("[WiFi] 准备加入 SSID=\(ssid)（psk \(psk.count) 位）")

        guard useHotspotConfiguration else {
            onManualJoinRequired?((ssid, psk))
            return
        }

        let configuration = NEHotspotConfiguration(
            ssid: ssid,
            passphrase: psk,
            isWEP: false,
            joinOnce: joinOnce
        )
        configuration.hidden = false

        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            guard let self else { return }
            if let error {
                self.onLog?("[WiFi] NEHotspotConfiguration 失败：\(error.localizedDescription)")
                // 常见原因：没有 HotspotConfiguration entitlement（免费账号）、
                // 或用户拒绝了系统对话框。前者 fallback 到手动，后者直接报错。
                let nsError = error as NSError
                if nsError.domain == NEHotspotConfigurationErrorDomain,
                   nsError.code == NEHotspotConfigurationError.invalid.rawValue {
                    self.onLog?("[WiFi] 可能是没有 entitlement，转手动加入")
                    self.onManualJoinRequired?((ssid, psk))
                    return
                }
                self.onFailure?(error)
                return
            }
            self.onLog?("[WiFi] 已加入 \(ssid)（joinOnce=\(joinOnce)）")
            self.onJoined?(ssid)
        }
    }

    /// 用户手动加入后，用这个确认当前连的确实是目标网络
    func currentSSID() -> String? {
        // iOS 16+ 需要 com.apple.developer.networking.multicast 或读不了当前 SSID；
        // v1 不依赖它，交由调用方按 Display 连接结果判断。
        nil
    }
}

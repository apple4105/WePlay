import Foundation

/// 链路子系统总控。
///
///   - credentials  ok
///   - link codec   ok (transport pending)
///   - session      pending
///   - output       pending
final class LinkController {

    /// 已装载的配件身份（bundle 里那枚 2018–2049 的苹果真证书）
    private(set) var identity: AccessoryIdentity?

    /// 认证器
    private(set) var authenticator: Authenticator?

    /// 状态变化（UI 展示用）
    var onStateChanged: ((String) -> Void)?

    // MARK: - M2

    func loadIdentity(bundle: Bundle = .main) throws {
        let identity = try AccessoryIdentityStore.loadFromBundle(bundle: bundle)
        self.identity = identity
        self.authenticator = Authenticator(identity: identity)
        self.authenticator?.onLog = { msg in
            #if DEBUG
            print(msg)
            #endif
        }
        onStateChanged?("配件身份已装载（证书 \(identity.leafCertificate.count) B / 私钥 \(identity.privateKeyRaw.count) B）")
    }

    // MARK: - M3（占位，下一步实现）

    /// 处理一次 challenge（联调时由消息层调进来）
    func handleChallenge(_ challenge: Data) throws -> AuthResponse {
        guard let authenticator else { throw LinkError.identityNotLoaded }
        return try authenticator.respond(toChallenge: challenge)
    }
}

import Foundation

///  身份自检工具（开发用，不参与产品逻辑）。
///
/// 在 Mac 上跑 `Tools/selftest.swift` 之前，可以先用这个在真机上验证：
/// 把 leaf.cer / private.x963 拖进 bundle，启动 App 看日志里的自校验结果。
enum IdentitySelfTest {

    /// 校验一枚身份是否自洽：私钥推出的公钥 == 证书里的公钥点。
    static func run(bundle: Bundle = .main) -> String {
        do {
            let identity = try AccessoryIdentityStore.loadFromBundle(bundle: bundle)
            let derived = try derivedPublicKeyPoint(from: identity)
            let match = derived == identity.publicKeyPoint
            return """
            [自检] 证书 \(identity.leafCertificate.count) B
            [自检] 私钥 \(identity.privateKeyRaw.count) B
            [自检] 文件内公钥点 \(identity.publicKeyPoint.prefix(8).hexString)…
            [自检] 私钥推出公钥 \(derived.prefix(8).hexString)…
            [自检] 结论：\(match ? "一致 ✅" : "不一致 ❌")
            """
        } catch {
            return "[自检] 失败：\(error)"
        }
    }

    /// 用 CryptoKit 从私钥标量推出非压缩公钥点
    private static func derivedPublicKeyPoint(from identity: AccessoryIdentity) throws -> Data {
        let key = try P256.Signing.PrivateKey(rawRepresentation: identity.privateKeyRaw)
        return key.publicKey.rawRepresentation
    }
}

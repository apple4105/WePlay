import Foundation

/// 从 App bundle 装载配件身份。
///
/// `readPrivateKey` / `privateKeyQuery` / `keyTag` / `replacePrivateKey` /
/// `importFromDocuments` / `deleteStored` / `stagingDirectory` / `readData` / `replaceData`。
enum AccessoryIdentityStore {

    /// bundle 内的文件名（不含扩展名）
    static let certificateResource = "leaf"      // leaf.cer
    static let privateKeyResource = "private"    // private.x963

    /// 从 bundle 读取 `leaf.cer` + `private.x963` 并构造身份。
    static func loadFromBundle(bundle: Bundle = .main) throws -> AccessoryIdentity {
        guard let certURL = bundle.url(forResource: certificateResource, withExtension: "cer") else {
            throw AccessoryIdentityError.missingBundleFile("\(certificateResource).cer")
        }
        guard let keyURL = bundle.url(forResource: privateKeyResource, withExtension: "x963") else {
            throw AccessoryIdentityError.missingBundleFile("\(privateKeyResource).x963")
        }
        return try AccessoryIdentity(
            leafCertificate: Data(contentsOf: certURL),
            privateKeyBlob: Data(contentsOf: keyURL)
        )
    }
}

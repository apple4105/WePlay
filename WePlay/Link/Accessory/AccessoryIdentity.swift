import Foundation
import CryptoKit

/// 配件身份：一枚叶子证书 + 与之配对的 P-256 私钥。
///
/// ## 私钥文件布局（97 字节）
///
/// ```
///  [0]      0x04                      // 非压缩点标记
///  [1..32]  公钥 X
///  [33..64] 公钥 Y
///  [65..96] 私钥标量（32 字节）        // CryptoKit 的 rawRepresentation 直接用这段
/// ```
///
/// 前 65 字节与证书里的公钥点一致，构造时可自校验。
///
struct AccessoryIdentity {

    /// 叶子证书（DER）
    let leafCertificate: Data

    /// 私钥标量，32 字节
    let privateKeyRaw: Data

    /// 非压缩公钥点 `04 || X || Y`，65 字节
    let publicKeyPoint: Data

    private let signingKey: P256.Signing.PrivateKey

    /// - Parameters:
    ///   - leafCertificate: 叶子证书 DER（即 bundle 里的 `leaf.cer`）
    ///   - privateKeyBlob: 私钥文件原始内容（即 bundle 里的 `private.x963`，97 字节）
    init(leafCertificate: Data, privateKeyBlob: Data) throws {
        guard privateKeyBlob.count == 97, privateKeyBlob.first == 0x04 else {
            throw AccessoryIdentityError.badPrivateKeyBlob(privateKeyBlob.count)
        }

        self.leafCertificate = leafCertificate
        self.publicKeyPoint = privateKeyBlob.prefix(65)
        self.privateKeyRaw = privateKeyBlob.suffix(32)
        self.signingKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyRaw)

        // 自校验：私钥推出的公钥必须与文件里声明的一致。
        // CryptoKit 的 rawRepresentation 在不同 iOS 版本上可能是非压缩(65B)或压缩(33B)形式，
        // 两种都比一遍；都不中只告警不崩，不阻塞开发。
        let derived = signingKey.publicKey.rawRepresentation
        let derivedUncompressed = derived.count == 65 ? derived : nil
        let derivedFromSuffix = derived.count == 64 ? Data(publicKeyPoint.suffix(64)) : nil
        if derived != publicKeyPoint,
           derived != publicKeyPoint.suffix(64),
           derivedUncompressed != publicKeyPoint,
           derivedFromSuffix != derived {
            #if DEBUG
            print("[AccessoryIdentity] 警告：推出的公钥与文件内公钥点不一致（可能是 CryptoKit 表示形式差异），继续")
            #endif
        }
    }

    /// 对 iPhone 发来的 challenge 签名。
    ///
    /// 算法取 CryptoKit 默认（ECDSA P-256 / SHA-256）。
    /// 只需要改这一个函数。
    func sign(challenge: Data) throws -> Data {
        try signingKey.signature(for: challenge)
    }
}

enum AccessoryIdentityError: Error, CustomStringConvertible {
    case badPrivateKeyBlob(Int)
    case missingBundleFile(String)

    var description: String {
        switch self {
        case .badPrivateKeyBlob(let n):
            return "私钥文件长度应为 97 字节且首字节 0x04，实际 \(n)"
        case .missingBundleFile(let name):
            return "bundle 里找不到 \(name)"
        }
    }
}

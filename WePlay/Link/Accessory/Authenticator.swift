import Foundation

///  认证应答。
struct AuthResponse {
    /// 对 challenge 的签名
    let signature: Data
    /// 证书链（v1 只回叶子证书；如需中间证书在这里追加）
    let certificateChain: [Data]
}

///  认证状态机。
///
///   1. iPhone 通过 link 控制会话发来 challenge
///   2. 我们用私钥签名
///   3. 回传 签名 + 证书链
///
/// 具体挂在哪个 link 消息 ID 上、challenge 怎么分包，要等第一次真机握手时
/// 按日志定；所以这里只把"签名"这个确定的核心做实，消息层留好接口。
struct Authenticator {

    let identity: AccessoryIdentity

    /// 日志钩子（真机联调时打开，把 challenge/签名 hex 打出来）
    var onLog: ((String) -> Void)?

    init(identity: AccessoryIdentity) {
        self.identity = identity
    }

    /// 处理一次 challenge，产出应答。
    func respond(toChallenge challenge: Data) throws -> AuthResponse {
        onLog?("[] challenge \(challenge.count) B: \(challenge.prefix(32).hexString)…")
        let signature = try identity.sign(challenge: challenge)
        onLog?("[] signature \(signature.count) B: \(signature.prefix(32).hexString)…")
        return AuthResponse(signature: signature,
                               certificateChain: [identity.leafCertificate])
    }
}

extension Data {
    /// 小工具：转成连续小写 hex，真机联调日志用。
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

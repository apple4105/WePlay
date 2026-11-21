import Foundation
import CryptoKit

/// Carlink 认证握手（规格：oxp-clink protocol/auth.rs，2026-11-22 提炼）。
///
/// ## 流程（全模式，首配）
/// 手机 → 车机：Frame{source:1, format:1, kind:1, category:3, method:1}
///   body 字段：1=版本 Varint(0x0701)；4=临时 ECDH 公钥(64B 裸)；5=身份签名(DER，
///     签名内容=临时公钥‖nonce)；6=nonce(32B)；7=device_id；8=name；9=confirmed Varint；
///     首配再加：2=身份公钥(64B 裸)、3=PIN 证明=HMAC-SHA256(key=SHA256(nonce‖pin), msg=身份公钥)
/// 车机 → 手机：Frame{source:0, kind:2, method:2, sequence 必须一致}
///   body：1=版本；7=结果（0 ok / 1 PinRequired / 2 ConfirmationRequired / 3 InternalError / 其他 Rejected）；
///     ok 时：4=车机临时公钥(64B)；5=车机签名(DER)；6=车机 nonce(32B)；首配加 2=车机身份公钥、3=车机 PIN 证明
///   手机验证车机 PIN 证明（双向）+ 车机签名
/// 会话密钥 = HMAC(HMAC(SHA256(手机nonce‖车机nonce), ECDH共享), "session_key\x01")[..16]
/// 手机 → 车机：确认帧 Frame{kind:0, method:3}，body 字段 1 = SecureRecord(key).seal(local_ipv4)
///
/// ## quick 模式
/// 信任存储里已有车机公钥（pinned）→ 不发字段 2/3、不带 PIN（"首次配对后免配对"）。
///
/// ## 身份
/// Carlink 认证用的 P-256 密钥与 MFi 身份**无关**（oxp-clink 里是独立生成/存储的）。
/// 首次生成后持久化（v1 存 UserDefaults，后续升级 Keychain）——车机按公钥记忆设备，
/// 换密钥 = 重新配对输码。
final class CarlinkAuth {

    struct Output {
        var frames: [CarlinkFrame] = []
        var sessionKey: Data?
        var pinRequired = false
        var confirmationRequired = false
        var rejected = false
        var peerVerified: Data?
    }

    /// 本机认证身份（P-256）
    struct Identity {
        let signing: P256.Signing.PrivateKey

        init() throws {
            signing = P256.Signing.PrivateKey()
        }

        init(rawScalar: Data) throws {
            signing = try P256.Signing.PrivateKey(rawRepresentation: rawScalar)
        }

        var rawScalar: Data { signing.rawRepresentation }
        /// 64 字节裸公钥（无 0x04 前缀）
        var rawPublic: Data { Data(signing.publicKey.rawRepresentation.dropFirst()) }
    }

    // MARK: - 状态

    private let identity: Identity
    private let deviceID: String
    private let name: String
    private let localIPv4: String
    /// 信任存储里的车机公钥（nil = 未配对，走全模式）
    private let peerPublic: Data?

    private var ephemeral: P256.KeyAgreement.PrivateKey?
    private var nonce = Data()
    private var pin = Data()
    private var quick = false
    private var sequence: UInt32 = 0
    private var complete = false

    init(identity: Identity, deviceID: String, name: String, localIPv4: String,
         peerPublic: Data?) throws {
        guard !deviceID.isEmpty, !name.isEmpty else {
            throw CarlinkError.badPacket("invalid_device_identity")
        }
        let parts = localIPv4.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
              parts.compactMap({ UInt8($0) }).count == 4 else {
            throw CarlinkError.badPacket("invalid_local_ipv4")
        }
        if let p = peerPublic { try Self.decodePublic(p) }
        self.identity = identity
        self.deviceID = deviceID
        self.name = name
        self.localIPv4 = localIPv4
        self.peerPublic = peerPublic
    }

    // MARK: - 第一步：手机 → 车机

    /// 发起认证。未配对时必须给 pin（≥6 位）。
    func start(time: UInt32, sequence: UInt32, pin: String?, forceFull: Bool = false) throws -> Output {
        var nonce = Data(count: 32)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        return try startWithMaterial(time: time, sequence: sequence, pin: pin,
                                     forceFull: forceFull, ephemeral: ephemeral, nonce: nonce)
    }

    func startWithMaterial(time: UInt32, sequence: UInt32, pin: String?,
                           forceFull: Bool, ephemeral: P256.KeyAgreement.PrivateKey,
                           nonce: Data) throws -> Output {
        guard !complete, self.ephemeral == nil else {
            throw CarlinkError.badPacket("unexpected_auth_request")
        }
        quick = (peerPublic != nil) && !forceFull
        self.pin = Data((pin ?? "").utf8)
        guard self.pin.count <= 64, self.pin.isEmpty || self.pin.count >= 6 else {
            throw CarlinkError.badPacket("invalid_pin")
        }
        guard quick || self.pin.count >= 6 else { throw CarlinkError.pinRequired }

        let epRaw = rawPublic(ephemeral.publicKey)
        // 签名 transcript = 临时公钥 ‖ nonce
        let transcript = epRaw + nonce
        let signature = try identity.signing.signature(for: transcript)
        var fields: [CarlinkField] = [
            CarlinkField(id: 1, value: .varint(0x0701)),
            CarlinkField(id: 4, value: .bytes(epRaw)),
            CarlinkField(id: 5, value: .bytes(signature.derRepresentation)),
            CarlinkField(id: 6, value: .bytes(nonce)),
            CarlinkField(id: 7, value: .bytes(Data(deviceID.utf8))),
            CarlinkField(id: 8, value: .bytes(Data(name.utf8))),
            CarlinkField(id: 9, value: .varint(0)),   // confirmed = false
        ]
        if !quick {
            let public64 = identity.rawPublic
            fields.append(CarlinkField(id: 3, value: .bytes(Self.proof(pin: self.pin, nonce: nonce, bytes: public64))))
            fields.append(CarlinkField(id: 2, value: .bytes(public64)))
        }
        self.ephemeral = ephemeral
        self.nonce = nonce
        self.sequence = sequence
        let frame = CarlinkFrame(sequence: sequence, unixSeconds: time, source: 1,
                                 format: 1, kind: 1, category: 3, method: 1,
                                 body: try CarlinkFields.encode(fields))
        return Output(frames: [frame])
    }

    // MARK: - 第二步：车机 → 手机

    func receive(frame: CarlinkFrame, time: UInt32) -> Output {
        guard !complete, ephemeral != nil else {
            return failed("unexpected_auth_response")
        }
        do {
            return try receiveInner(frame, time)
        } catch let e as CarlinkError {
            ephemeral = nil
            complete = true
            pin = Data()
            return failed("\(e)")
        } catch {
            ephemeral = nil
            complete = true
            pin = Data()
            return failed("\(error)")
        }
    }

    private func receiveInner(_ frame: CarlinkFrame, _ time: UInt32) throws -> Output {
        guard frame.category == 3, frame.method == 2, frame.kind == 2,
              frame.sequence == sequence, frame.source == 0, frame.format == 1 else {
            throw CarlinkError.badPacket("invalid_auth_header")
        }
        let fields = try CarlinkFields.decode(frame.body)
        let version = CarlinkFields.varintField(fields, 1)
        guard [1, 0x0501, 0x0701, 0x0901].contains(version) else {
            throw CarlinkError.authFailed("auth_version_unsupported")
        }
        let result = CarlinkFields.varintField(fields, 7)
        if result != 0 {
            ephemeral = nil
            switch result {
            case 1: return Output(pinRequired: true)
            case 2: return Output(confirmationRequired: true)
            case 3: return Output(rejected: true)
            default: return Output(rejected: true)
            }
        }

        let carNonce = try sizedBytes(fields, 6, 32)
        let carAgreementRaw = try sizedBytes(fields, 4, 64)
        let signature = try bytesField(fields, 5) ?? Data()
        guard (1...80).contains(signature.count) else {
            throw CarlinkError.authFailed("invalid_auth_signature")
        }

        // 车机身份：quick 模式用信任存储的；全模式从字段 2 取并验证车机也知道 PIN
        let carIdentityRaw: Data
        if quick {
            guard let peer = peerPublic else { throw CarlinkError.badPacket("invalid_peer_key") }
            carIdentityRaw = peer
        } else {
            let p = try sizedBytes(fields, 2, 64)
            var nonces = carNonce
            nonces.append(nonce)
            var proofInput = p
            proofInput.append(identity.rawPublic)
            let proofKey = SHA256.hash(data: nonces + pin)
            let mac = HMAC<SHA256>.authenticationCode(for: proofInput, using: SymmetricKey(data: proofKey))
            guard mac == (bytesField(fields, 3) ?? Data()) else {
                throw CarlinkError.authFailed("auth_pin_proof_failed")
            }
            if let peer = peerPublic, peer != p {
                throw CarlinkError.authFailed("peer_key_changed")
            }
            carIdentityRaw = p
        }

        // 验证车机签名：transcript = 车机临时公钥 ‖ 手机临时公钥 ‖ 车机nonce ‖ 手机nonce
        let epRaw = rawPublic(ephemeral!.publicKey)
        let transcript = carAgreementRaw + epRaw + carNonce + nonce
        let carKey = try Self.decodePublic(carIdentityRaw)
        let der = try P256.Signing.ECDSASignature(derRepresentation: signature)
        guard carKey.isValidSignature(der, for: transcript) else {
            throw CarlinkError.authFailed("auth_signature_failed")
        }

        // ECDH → 会话密钥
        let carAgreement = try Self.decodeAgreement(carAgreementRaw)
        let shared = try ephemeral!.sharedSecretFromKeyAgreement(with: carAgreement)
        let salt = SHA256.hash(data: nonce + carNonce)
        let prk = Self.hmac(key: Data(salt), bytes: shared.withUnsafeBytes { Data($0) })
        let expanded = Self.hmac(key: prk, bytes: Data("session_key".utf8) + Data([0x01]))
        let sessionKey = expanded.prefix(16)

        // 确认帧：SecureRecord(key).seal(local_ipv4)
        let record = try CarlinkSecureRecord(key: sessionKey).seal(Data(localIPv4.utf8))
        let confirmation = CarlinkFrame(
            sequence: sequence &+ 1, unixSeconds: time, source: 1,
            format: 1, kind: 0, category: 3, method: 3,
            body: try CarlinkFields.encode([CarlinkField(id: 1, value: .bytes(record))])
        )
        complete = true
        ephemeral = nil
        pin = Data()
        var out = Output(frames: [confirmation], sessionKey: Data(sessionKey))
        out.peerVerified = carIdentityRaw
        return out
    }

    private func failed(_ why: String) -> Output {
        var out = Output()
        out.rejected = true
        return out
    }

    // MARK: - 工具

    private func sizedBytes(_ fields: [CarlinkField], _ id: UInt32, _ n: Int) throws -> Data {
        guard let b = CarlinkFields.bytesField(fields, id), b.count == n else {
            throw CarlinkError.badPacket("invalid_field_size")
        }
        return b
    }

    private func bytesField(_ fields: [CarlinkField], _ id: UInt32) throws -> Data {
        guard let b = CarlinkFields.bytesField(fields, id) else {
            throw CarlinkError.badPacket("missing_byte_field")
        }
        return b
    }

    static func rawPublic(_ key: P256.KeyAgreement.PublicKey) -> Data {
        Data(key.rawRepresentation.dropFirst())   // 去掉 0x04
    }

    static func decodePublic(_ raw: Data) throws -> P256.Signing.PublicKey {
        guard raw.count == 64 else { throw CarlinkError.badPacket("invalid_peer_key") }
        return try P256.Signing.PublicKey(rawRepresentation: Data([0x04]) + raw)
    }

    static func decodeAgreement(_ raw: Data) throws -> P256.KeyAgreement.PublicKey {
        guard raw.count == 64 else { throw CarlinkError.badPacket("invalid_peer_key") }
        return try P256.KeyAgreement.PublicKey(rawRepresentation: Data([0x04]) + raw)
    }

    static func hmac(key: Data, bytes: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: key)))
    }

    /// PIN 证明 = HMAC-SHA256(key = SHA256(nonce ‖ pin), msg)
    static func proof(pin: Data, nonce: Data, bytes: Data) -> Data {
        hmac(key: Data(SHA256.hash(data: nonce + pin)), bytes: bytes)
    }
}

/// 车机信任存储（v1：UserDefaults 持久化"车机 id → 公钥"，pinned 后免配对）。
/// 后续升级 Keychain。公钥与认证身份密钥都按"车机 id"隔离。
final class CarlinkTrustStore {
    static let shared = CarlinkTrustStore()
    private let defaults = UserDefaults.standard
    private let identityKey = "carlink.identity.raw"
    private let peerPrefix = "carlink.peer."

    /// 本机认证身份（首次生成后持久化——车机按公钥记忆我们）
    func loadOrCreateIdentity() throws -> CarlinkAuth.Identity {
        if let raw = defaults.data(forKey: identityKey) {
            return try CarlinkAuth.Identity(rawScalar: raw)
        }
        let fresh = try CarlinkAuth.Identity()
        defaults.set(fresh.rawScalar, forKey: identityKey)
        return fresh
    }

    func peerKey(for headUnitID: String) -> Data? {
        defaults.data(forKey: peerPrefix + headUnitID)
    }

    func rememberPeerKey(_ key: Data, for headUnitID: String) {
        defaults.set(key, forKey: peerPrefix + headUnitID)
    }
}

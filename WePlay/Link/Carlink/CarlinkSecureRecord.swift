import Foundation
import CryptoKit

/// Carlink 会话加密记录（规格：oxp-clink protocol/secure_record.rs）。
///
/// 密钥 = 认证握手表生的 16 字节会话密钥；算法 AES-128-GCM。
/// 封包 `[ivLen BE32][IV][payloadLen BE32][密文+16B tag]`；
/// 解包兼容 IV 12..32（车机 Java 侧可能发长 IV），防重放 = 记录 SHA256 指纹（保留最近 4096）。
/// WePlay 发送固定用 12 字节 IV；接收如遇非 12 长度先报错（真机抓到再加长 IV 支持）。
struct CarlinkSecureRecord {
    private let key: SymmetricKey
    private var buffer = Data()
    private var seen = [Data]()
    private let seenMax = 4096

    init(key: Data) throws {
        guard key.count == 16 else { throw CarlinkError.badPacket("invalid_session_key") }
        self.key = SymmetricKey(data: key)
    }

    // MARK: 封包（手机 → 车机）

    func seal(_ plain: Data) throws -> Data {
        let iv = (0..<12).map { _ in UInt8.random(in: 0...255) }
        let sealed = try AES.GCM.seal(plain, using: key, nonce: AES.GCM.Nonce(data: Data(iv)))
        var out = Data()
        out.appendBE32(12)
        out.append(contentsOf: iv)
        out.appendBE32(UInt32(sealed.ciphertext.count + 16))
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    // MARK: 拆包（车机 → 手机）

    mutating func open(_ b: Data) throws -> Data {
        guard buffer.isEmpty else { throw CarlinkError.badPacket("partial_record_pending") }
        let plain = try tryOpen(b)
        return plain
    }

    /// 流式：TCP 半包在此缓冲
    mutating func feed(_ b: Data) throws -> [Data] {
        guard buffer.count + b.count <= CarlinkFrame.maxBytes + 65576 else {
            throw CarlinkError.packetTooLarge
        }
        buffer.append(b)
        var out: [Data] = []
        var pos = buffer.startIndex
        while true {
            guard buffer.endIndex - pos >= 4 else { break }
            let ivLen = Int(buffer.be32(at: pos - buffer.startIndex))
            guard (12...32).contains(ivLen) else {
                throw CarlinkError.badPacket("invalid_cipher_record")
            }
            guard buffer.endIndex - pos >= ivLen + 8 else { break }
            let size = Int(buffer.be32(at: pos - buffer.startIndex + ivLen + 4))
            guard size >= 16, size <= CarlinkFrame.maxBytes else {
                throw CarlinkError.badPacket("invalid_cipher_record")
            }
            let total = ivLen + 8 + size
            guard buffer.endIndex - pos >= total else { break }
            let record = buffer.subdata(in: pos ..< pos + total)
            out.append(try tryOpen(record))
            pos += total
        }
        buffer.removeSubrange(buffer.startIndex ..< pos)
        return out
    }

    private func fingerprint(_ b: Data) -> Data {
        Data(SHA256.hash(data: b))
    }

    private func tryOpen(_ b: Data) throws -> Data {
        guard b.count >= 8 else { throw CarlinkError.badPacket("invalid_cipher_record") }
        let ivLen = Int(b.be32(at: 0))
        guard (12...32).contains(ivLen), b.count >= ivLen + 8 else {
            throw CarlinkError.badPacket("invalid_cipher_record")
        }
        let iv = b.subdata(in: (b.startIndex + 4) ..< (b.startIndex + 4 + ivLen))
        let size = Int(b.be32(at: ivLen + 4))
        guard size >= 16, b.count == ivLen + 8 + size else {
            throw CarlinkError.badPacket("invalid_cipher_record")
        }
        let payload = b.subdata(in: (b.startIndex + ivLen + 8) ..< (b.startIndex + ivLen + 8 + size))

        let fp = fingerprint(b)
        if seen.contains(fp) { throw CarlinkError.badPacket("replayed_cipher_record") }
        if seen.count == seenMax { seen.removeFirst() }
        seen.append(fp)

        guard ivLen == 12 else {
            // CryptoKit 只支持 12 字节 nonce；车机 Java 侧可能发 12..32。
            // 先按错误上报，真机抓到非 12 长度再补长 IV 的 GCM J0 计算。
            throw CarlinkError.badPacket("unsupported_iv_len_\(ivLen)")
        }
        let sealed = try AES.GCM.SealedBox(combined: payload)
        return try AES.GCM.open(sealed, using: key, nonce: AES.GCM.Nonce(data: iv))
    }
}

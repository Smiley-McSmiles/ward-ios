import Foundation
import CryptoKit

struct AESGCMLink {
    var httpsURL: String
    var iv: Data
    var key: Data
}

/// XEP-0454 (AES-256-GCM encrypted file sharing). The fragment carries the IV and key as hex,
/// exactly like Ward for Android. Files are sealed with a 16-byte GCM tag appended to the
/// ciphertext, so receivers can decrypt with the fragment alone.
enum FileCrypto {
    static func encrypt(_ data: Data) throws -> (ciphertext: Data, key: Data, iv: Data) {
        let key = SymmetricKey(size: .bits256)
        let nonce = AES.GCM.Nonce()
        let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
        var ciphertext = sealed.ciphertext
        ciphertext.append(sealed.tag)
        let keyData = key.withUnsafeBytes { Data($0) }
        let iv = nonce.withUnsafeBytes { Data($0) }
        return (ciphertext, keyData, iv)
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard data.count > 16 else { throw WardError.encryption("The encrypted file is too short.") }
        let tag = data.suffix(16)
        let ciphertext = data.dropLast(16)
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key))
    }

    static func aesgcmURL(httpsURL: String, key: Data, iv: Data) -> String {
        let body = httpsURL.hasPrefix("https://") ? String(httpsURL.dropFirst("https://".count)) : httpsURL
        let fragment = (iv + key).map { String(format: "%02x", $0) }.joined()
        return "aesgcm://\(body)#\(fragment)"
    }

    static func parse(_ uri: String) -> AESGCMLink? {
        guard uri.lowercased().hasPrefix("aesgcm://"),
              let hash = uri.firstIndex(of: "#") else { return nil }
        let body = String(uri[uri.index(uri.startIndex, offsetBy: 9)..<hash])
        let fragment = String(uri[uri.index(after: hash)...])
        guard fragment.count == 88 || fragment.count == 96 else { return nil }
        var raw = Data()
        var index = fragment.startIndex
        while index < fragment.endIndex {
            let next = fragment.index(index, offsetBy: 2)
            guard let byte = UInt8(String(fragment[index..<next]), radix: 16) else { return nil }
            raw.append(byte)
            index = next
        }
        let ivLength = raw.count == 44 ? 12 : 16
        let iv = raw.prefix(ivLength)
        let key = raw.dropFirst(ivLength)
        guard key.count == 32 else { return nil }
        return AESGCMLink(httpsURL: "https://\(body)", iv: Data(iv), key: Data(key))
    }
}

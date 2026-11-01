import Foundation
import Sodium
import Clibsodium
import CryptoSwift

public enum WardCryptoError: LocalizedError {
    case invalidKey(String)
    case invalidMessage(String)
    case authentication(String)
    case randomFailure
    case noDevices
    case noSession
    case noPreKey
    case invalidBundle
    case encryption(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let value): return value
        case .invalidMessage(let value): return value
        case .authentication(let value): return value
        case .randomFailure: return "Could not obtain secure random data."
        case .noDevices: return "No OMEMO devices are available."
        case .noSession: return "No OMEMO session exists."
        case .noPreKey: return "The OMEMO bundle has no usable prekey."
        case .invalidBundle: return "The OMEMO bundle signature is invalid."
        case .encryption(let value): return value
        }
    }
}

public struct Ed25519KeyPair: Codable, Equatable {
    public var publicKey: Data
    public var secretKey: Data
    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

public struct X25519KeyPair: Codable, Equatable {
    public var publicKey: Data
    public var secretKey: Data
    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

public enum CryptoPrimitives {
    private static let sodium = Sodium()

    public static func randomBytes(_ count: Int) throws -> Data {
        guard let bytes = sodium.randomBytes.buf(length: count) else { throw WardCryptoError.randomFailure }
        return Data(bytes)
    }

    public static func identityKeyPair() throws -> Ed25519KeyPair {
        guard let pair = sodium.sign.keyPair() else { throw WardCryptoError.invalidKey("Could not generate an Ed25519 key.") }
        return Ed25519KeyPair(publicKey: Data(pair.publicKey), secretKey: Data(pair.secretKey))
    }

    public static func x25519KeyPair() throws -> X25519KeyPair {
        guard let pair = sodium.keyExchange.keyPair() else { throw WardCryptoError.invalidKey("Could not generate an X25519 key.") }
        return X25519KeyPair(publicKey: Data(pair.publicKey), secretKey: Data(pair.secretKey))
    }

    public static func sign(_ message: Data, with identity: Ed25519KeyPair) throws -> Data {
        guard let signature = sodium.sign.signature(message: [UInt8](message), secretKey: [UInt8](identity.secretKey)) else {
            throw WardCryptoError.invalidKey("Could not sign with the identity key.")
        }
        return Data(signature)
    }

    public static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        sodium.sign.verify(message: [UInt8](message), publicKey: [UInt8](publicKey), signature: [UInt8](signature))
    }

    public static func edPublicToX25519(_ publicKey: Data) throws -> Data {
        guard publicKey.count == 32 else { throw WardCryptoError.invalidKey("Ed25519 public key must be 32 bytes.") }
        var output = [UInt8](repeating: 0, count: 32)
        let result = publicKey.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                crypto_sign_ed25519_pk_to_curve25519(
                    out.bindMemory(to: UInt8.self).baseAddress!,
                    input.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        guard result == 0 else { throw WardCryptoError.invalidKey("Could not convert the Ed25519 public key.") }
        return Data(output)
    }

    public static func edSecretToX25519(_ secretKey: Data) throws -> Data {
        guard secretKey.count == 64 else { throw WardCryptoError.invalidKey("Ed25519 secret key must be 64 bytes.") }
        var output = [UInt8](repeating: 0, count: 32)
        let result = secretKey.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { out in
                crypto_sign_ed25519_sk_to_curve25519(
                    out.bindMemory(to: UInt8.self).baseAddress!,
                    input.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
        guard result == 0 else { throw WardCryptoError.invalidKey("Could not convert the Ed25519 secret key.") }
        return Data(output)
    }

    public static func dh(secretKey: Data, publicKey: Data) throws -> Data {
        guard secretKey.count == 32, publicKey.count == 32 else {
            throw WardCryptoError.invalidKey("X25519 keys must be 32 bytes.")
        }
        var output = [UInt8](repeating: 0, count: 32)
        let result = secretKey.withUnsafeBytes { secret in
            publicKey.withUnsafeBytes { publicBytes in
                output.withUnsafeMutableBytes { out in
                    crypto_scalarmult_curve25519(
                        out.bindMemory(to: UInt8.self).baseAddress!,
                        secret.bindMemory(to: UInt8.self).baseAddress!,
                        publicBytes.bindMemory(to: UInt8.self).baseAddress!)
                }
            }
        }
        guard result == 0 else { throw WardCryptoError.invalidKey("X25519 key agreement failed.") }
        return Data(output)
    }

    public static func hkdf(ikm: Data, salt: Data, info: String, count: Int) -> Data {
        var prk = [UInt8](repeating: 0, count: 32)
        salt.withUnsafeBytes { saltBytes in
            ikm.withUnsafeBytes { ikmBytes in
                _ = crypto_kdf_hkdf_sha256_extract(&prk,
                                                   saltBytes.bindMemory(to: UInt8.self).baseAddress!,
                                                   salt.count,
                                                   ikmBytes.bindMemory(to: UInt8.self).baseAddress!,
                                                   ikm.count)
            }
        }
        var output = [UInt8](repeating: 0, count: count)
        info.withCString { context in
            output.withUnsafeMutableBytes { out in
                _ = crypto_kdf_hkdf_sha256_expand(out.bindMemory(to: UInt8.self).baseAddress!, count,
                                                  context, strlen(context), prk)
            }
        }
        return Data(output)
    }

    public static func hmac(key: Data, message: Data) -> Data {
        var state = crypto_auth_hmacsha256_state()
        key.withUnsafeBytes { keyBytes in
            _ = crypto_auth_hmacsha256_init(&state, keyBytes.bindMemory(to: UInt8.self).baseAddress, key.count)
        }
        message.withUnsafeBytes { messageBytes in
            _ = crypto_auth_hmacsha256_update(&state, messageBytes.bindMemory(to: UInt8.self).baseAddress,
                                              UInt64(message.count))
        }
        var output = [UInt8](repeating: 0, count: 32)
        _ = crypto_auth_hmacsha256_final(&state, &output)
        return Data(output)
    }

    public static func sha256(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { bytes in
            _ = crypto_hash_sha256(&output, bytes.bindMemory(to: UInt8.self).baseAddress, UInt64(data.count))
        }
        return Data(output)
    }

    public static func aesCBCEncrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try aesCBC(data, key: key, iv: iv, decrypt: false)
    }

    public static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        try aesCBC(data, key: key, iv: iv, decrypt: true)
    }

    private static func aesCBC(_ data: Data, key: Data, iv: Data, decrypt: Bool) throws -> Data {
        guard key.count == 32, iv.count == 16 else { throw WardCryptoError.invalidKey("AES-256-CBC needs a 32-byte key and 16-byte IV.") }
        do {
            let aes = try AES(key: [UInt8](key), blockMode: CBC(iv: [UInt8](iv)), padding: .pkcs7)
            let result = decrypt ? try aes.decrypt([UInt8](data)) : try aes.encrypt([UInt8](data))
            return Data(result)
        } catch {
            throw WardCryptoError.encryption("AES-256-CBC failed.")
        }
    }

    public static func fingerprint(_ identityKey: Data) -> String {
        sha256(identityKey).hexString
    }
}

import Foundation
import Security
import CryptoKit

/// Passwords and other secrets live in the Keychain, never in the SQLite file or UserDefaults.
struct SecureStore {
    static let shared = SecureStore()
    private let service = "org.ward.ios"

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func set(_ value: String, for account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { _, new in new }
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    func get(_ account: String) -> String? {
        var item = query(account)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func remove(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }

    func setData(_ data: Data, for account: String) {
        set(data.base64EncodedString(), for: account)
    }

    func data(_ account: String) -> Data? {
        get(account).flatMap { Data(base64Encoded: $0) }
    }

    // MARK: Device identity

    /// A stable random OMEMO device id. Android uses 31-bit ids; we do the same so the id fits
    /// comfortably in every client's XML parser.
    func deviceId() -> UInt32 {
        if let stored = get("omemo.deviceId"), let value = UInt32(stored), value > 0 { return value }
        var value: UInt32 = 0
        repeat {
            value = UInt32.random(in: 1...UInt32(Int32.max))
        } while value == 0
        set(String(value), for: "omemo.deviceId")
        return value
    }

    func passcodeHash() -> String? { get("applock.passcode") }
    func setPasscode(_ passcode: String) {
        let salt = UUID().uuidString
        let digest = SHA256.hash(data: Data((salt + passcode).utf8))
        set(salt + ":" + digest.map { String(format: "%02x", $0) }.joined(), for: "applock.passcode")
    }
    func verifyPasscode(_ passcode: String) -> Bool {
        guard let stored = passcodeHash() else { return false }
        let parts = stored.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return false }
        let digest = SHA256.hash(data: Data((String(parts[0]) + passcode).utf8))
        return digest.map { String(format: "%02x", $0) }.joined() == parts[1]
    }
    func clearPasscode() { remove("applock.passcode") }
}

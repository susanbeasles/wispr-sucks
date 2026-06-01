import Foundation
import Security
import CryptoKit

// Keychain-backed master key for the recordings database.
//
// Why Keychain rather than the Secure Enclave key we already use for WAVs:
// the SE key gets you Touch ID prompts when accessed from non-foreground
// contexts (background daemons, signed-but-not-active processes) which has
// bitten us repeatedly this session. A Generic Password item with
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly gives us:
//   - encrypted at rest under the user's account password / FileVault key
//   - readable by the app with NO user interaction after first login
//   - never syncs to iCloud Keychain (ThisDeviceOnly)
//   - codesign-bound: only an app with the same signing identity can read it
//
// The key it stores is 32 random bytes used as the AES-GCM key for column-
// level encryption of sensitive content in recordings.db. If the keychain item
// is destroyed (sonar-dictate reset wipes it), the DB is cryptographically
// gone - matches the SE-key story we already have for the WAVs.

enum KeychainStoreError: Error, CustomStringConvertible {
    case unexpectedKeySize(Int)
    case osStatus(OSStatus, action: String)

    var description: String {
        switch self {
        case .unexpectedKeySize(let n):
            return "keychain returned key of unexpected size: \(n) bytes"
        case .osStatus(let s, let action):
            return "keychain \(action) failed: OSStatus \(s) (\(SecCopyErrorMessageString(s, nil) as String? ?? "unknown"))"
        }
    }
}

enum KeychainStore {
    private static let service = "com.sonarmd.dictate.dbkey"
    private static let account = "main"
    private static let keyByteCount = 32  // 256-bit AES-GCM

    // Returns the existing key if one is stored; otherwise generates a fresh
    // 32-byte key, persists it, and returns it. Idempotent across launches.
    static func loadOrCreateDBKey() throws -> SymmetricKey {
        if let existing = try readKey() {
            return SymmetricKey(data: existing)
        }
        var bytes = Data(count: keyByteCount)
        let status = bytes.withUnsafeMutableBytes { buf -> OSStatus in
            guard let base = buf.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, keyByteCount, base)
        }
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status, action: "generate random key")
        }
        try writeKey(bytes)
        return SymmetricKey(data: bytes)
    }

    // Destroy the keychain item. Called by `sonar-dictate reset` so the DB
    // becomes cryptographically unrecoverable.
    static func deleteKey() throws {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        // errSecItemNotFound is fine - means there was nothing to delete.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.osStatus(status, action: "delete key")
        }
    }

    // MARK: - Internals

    private static func readKey() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainStoreError.osStatus(status, action: "decode key item")
            }
            guard data.count == keyByteCount else {
                throw KeychainStoreError.unexpectedKeySize(data.count)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainStoreError.osStatus(status, action: "read key")
        }
    }

    private static func writeKey(_ key: Data) throws {
        let attrs: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecValueData as String:    key,
            // After-first-unlock-this-device-only: readable post-login without
            // prompts, never syncs to iCloud Keychain. Right level for a local
            // dev-loop app holding a corpus key.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainStoreError.osStatus(status, action: "store key")
        }
    }
}

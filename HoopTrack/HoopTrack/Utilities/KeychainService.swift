// Phase 7 — Security
import Foundation
import Security

/// Thread-safe Keychain wrapper. All callers must be on @MainActor.
@MainActor
final class KeychainService {

    // MARK: - String convenience

    func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        save(data, forKey: key)
    }

    func string(forKey key: String) -> String? {
        guard let data = data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Data primitives

    func save(_ data: Data, forKey key: String) {
        delete(forKey: key)

        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrAccount:    key,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData:      data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        assert(status == errSecSuccess, "KeychainService: SecItemAdd failed with \(status) for key \(key)")
    }

    func data(forKey key: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - Deletion

    func delete(forKey key: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Deletes all keys managed by this app. Called during GDPR account deletion.
    func deleteAll() {
        let allKeys = [
            HoopTrack.KeychainKey.accessToken,
            HoopTrack.KeychainKey.refreshToken,
            HoopTrack.KeychainKey.userID,
            HoopTrack.KeychainKey.biometricToken
        ]
        allKeys.forEach { delete(forKey: $0) }
    }

    // MARK: - Biometric-protected storage (Phase 9)

    /// Saves a value that requires biometric or device passcode to read.
    func saveBiometricProtected(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(forKey: key)

        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,
            nil
        ) else { return } // device has no passcode; biometric storage unavailable

        let query: [CFString: Any] = [
            kSecClass:             kSecClassGenericPassword,
            kSecAttrAccount:       key,
            kSecAttrAccessControl: access,
            kSecValueData:         data
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        assert(status == errSecSuccess, "KeychainService: saveBiometricProtected SecItemAdd failed with \(status)")
    }
}

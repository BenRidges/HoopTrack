// HoopTrack/Auth/SupabaseClient+Shared.swift
// Phase 8: only the Auth product is needed. Phase 9 will add a richer wrapper
// that composes Auth + PostgREST + Storage into a single SupabaseClient.

import Foundation
import Security
import Auth

enum SupabaseContainer {
    /// Lazily-initialised AuthClient. Built from HoopTrack.Backend (which
    /// reads BackendSecrets.swift).
    static let auth: AuthClient = {
        AuthClient(
            url: HoopTrack.Backend.supabaseURL.appendingPathComponent("auth/v1"),
            headers: [
                "apikey": HoopTrack.Backend.supabaseAnonKey,
                "Authorization": "Bearer \(HoopTrack.Backend.supabaseAnonKey)"
            ],
            flowType: .pkce,
            localStorage: KeychainAuthStorage(),
            logger: nil
        )
    }()
}

/// Plugs Supabase's session persistence into the keychain so tokens live
/// alongside the other sensitive values we already protect.
struct KeychainAuthStorage: AuthLocalStorage, Sendable {
    func store(key: String, value: Data) throws {
        // Supabase passes through arbitrary keys (session, codeVerifier, …).
        // Prefix each with our namespace so they don't collide.
        try KeychainRawStorage.store(namespaced(key), data: value)
    }

    func retrieve(key: String) throws -> Data? {
        try KeychainRawStorage.retrieve(namespaced(key))
    }

    func remove(key: String) throws {
        try KeychainRawStorage.remove(namespaced(key))
    }

    private func namespaced(_ key: String) -> String {
        "com.hooptrack.keychain.supabase.\(key)"
    }
}

/// Minimal raw-keychain wrapper. Kept separate from KeychainService (which is
/// @MainActor) because Supabase calls storage hooks from arbitrary actors.
nonisolated enum KeychainRawStorage {
    static func store(_ account: String, data: Data) throws {
        let query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrAccount:    account,
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "KeychainRawStorage", code: Int(status))
        }
    }

    static func retrieve(_ account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: "KeychainRawStorage", code: Int(status))
        }
        return result as? Data
    }

    static func remove(_ account: String) throws {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

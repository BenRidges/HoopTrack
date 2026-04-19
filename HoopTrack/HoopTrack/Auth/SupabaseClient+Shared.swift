// HoopTrack/Auth/SupabaseClient+Shared.swift
// Phase 8: AuthClient for email/password + biometric re-lock.
// Phase 9: PostgrestClient for row sync, RLS-gated via the current JWT.

import Foundation
import Security
import Auth
import PostgREST
import Storage

enum SupabaseContainer {
    /// Lazily-initialised AuthClient. Built from HoopTrack.Backend (which
    /// reads BackendSecrets.swift).
    static let auth: AuthClient = {
        AuthClient(
            url: HoopTrack.Backend.supabaseURL.appendingPathComponent("auth/v1"),
            headers: anonHeaders,
            flowType: .pkce,
            localStorage: KeychainAuthStorage(),
            logger: nil
        )
    }()

    /// Fresh PostgrestClient per call, built with the current session's
    /// access token in the Authorization header so RLS resolves correctly.
    /// The client is cheap; constructing it on demand avoids stale JWTs
    /// after sign-out or token refresh.
    static func postgrest() async throws -> PostgrestClient {
        let accessToken = try await auth.session.accessToken
        var headers = anonHeaders
        headers["Authorization"] = "Bearer \(accessToken)"
        return PostgrestClient(
            url: HoopTrack.Backend.supabaseURL.appendingPathComponent("rest/v1"),
            headers: headers,
            logger: nil
        )
    }

    /// Fresh SupabaseStorageClient per call — same pattern as postgrest(),
    /// uses the current session's access token so bucket RLS resolves
    /// against the authenticated user. CV-A uploads use this.
    static func storage() async throws -> SupabaseStorageClient {
        let accessToken = try await auth.session.accessToken
        var headers = anonHeaders
        headers["Authorization"] = "Bearer \(accessToken)"
        let config = StorageClientConfiguration(
            url: HoopTrack.Backend.supabaseURL.appendingPathComponent("storage/v1"),
            headers: headers
        )
        return SupabaseStorageClient(configuration: config)
    }

    private static var anonHeaders: [String: String] {
        [
            "apikey": HoopTrack.Backend.supabaseAnonKey,
            "Authorization": "Bearer \(HoopTrack.Backend.supabaseAnonKey)"
        ]
    }
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

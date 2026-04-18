// HoopTrackTests/Mocks/MockAuthProvider.swift
import Foundation
@testable import HoopTrack

/// In-memory AuthProviding stub. Scripts responses per method via the
/// `scripted*` properties; defaults to empty/success paths so tests only set
/// what they care about.
final class MockAuthProvider: AuthProviding, @unchecked Sendable {

    // Scripts — set these in the test before calling the method under test.
    var scriptedRestoreResult: Result<AuthUser?, Error> = .success(nil)
    var scriptedSignUpResult:  Result<AuthUser, Error>?
    var scriptedSignInResult:  Result<AuthUser, Error>?
    var scriptedSignOutResult: Result<Void, Error> = .success(())
    var scriptedResendResult:  Result<Void, Error> = .success(())
    var scriptedRefreshResult: Result<AuthUser?, Error> = .success(nil)
    var scriptedDeepLinkResult: Result<AuthUser, Error>?

    // Call recorders — tests assert on these.
    private(set) var signUpCalls:  [(email: String, password: String)] = []
    private(set) var signInCalls:  [(email: String, password: String)] = []
    private(set) var signOutCount = 0
    private(set) var resendCalls: [String] = []
    private(set) var deepLinkCalls: [URL] = []

    func restoreSession() async throws -> AuthUser? {
        try scriptedRestoreResult.get()
    }

    func signUp(email: String, password: String) async throws -> AuthUser {
        signUpCalls.append((email, password))
        guard let scripted = scriptedSignUpResult else {
            return AuthUser(id: UUID(), email: email, emailVerified: false, createdAt: Date())
        }
        return try scripted.get()
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        signInCalls.append((email, password))
        guard let scripted = scriptedSignInResult else {
            return AuthUser(id: UUID(), email: email, emailVerified: true, createdAt: Date())
        }
        return try scripted.get()
    }

    func signOut() async throws {
        signOutCount += 1
        try scriptedSignOutResult.get()
    }

    func resendConfirmationEmail(to email: String) async throws {
        resendCalls.append(email)
        try scriptedResendResult.get()
    }

    func refreshUser() async throws -> AuthUser? {
        try scriptedRefreshResult.get()
    }

    func handleDeepLink(_ url: URL) async throws -> AuthUser {
        deepLinkCalls.append(url)
        guard let scripted = scriptedDeepLinkResult else {
            return AuthUser(id: UUID(), email: "deeplink@example.com",
                             emailVerified: true, createdAt: Date())
        }
        return try scripted.get()
    }
}

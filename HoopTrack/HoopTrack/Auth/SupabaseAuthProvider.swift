// HoopTrack/Auth/SupabaseAuthProvider.swift
import Foundation
import Auth

final class SupabaseAuthProvider: AuthProviding, @unchecked Sendable {

    private let client: AuthClient

    init(client: AuthClient = SupabaseContainer.auth) {
        self.client = client
    }

    func restoreSession() async throws -> AuthUser? {
        do {
            let session = try await client.session
            return mapUser(session.user)
        } catch {
            // No session cached — not an error at app launch.
            return nil
        }
    }

    func signUp(email: String, password: String) async throws -> AuthUser {
        do {
            let response = try await client.signUp(
                email: email,
                password: password,
                redirectTo: HoopTrack.Auth.redirectURL
            )
            return mapUser(response.user)
        } catch {
            throw mapError(error)
        }
    }

    func signIn(email: String, password: String) async throws -> AuthUser {
        do {
            let session = try await client.signIn(email: email, password: password)
            return mapUser(session.user)
        } catch {
            throw mapError(error)
        }
    }

    func signOut() async throws {
        try await client.signOut()
    }

    func resendConfirmationEmail(to email: String) async throws {
        try await client.resend(email: email, type: .signup)
    }

    func refreshUser() async throws -> AuthUser? {
        do {
            let user = try await client.user()
            return mapUser(user)
        } catch {
            return nil
        }
    }

    func handleDeepLink(_ url: URL) async throws -> AuthUser {
        do {
            let session = try await client.session(from: url)
            return mapUser(session.user)
        } catch {
            throw mapError(error)
        }
    }

    // MARK: - Mapping

    private func mapUser(_ user: User) -> AuthUser {
        AuthUser(
            id: user.id,
            email: user.email ?? "",
            emailVerified: user.emailConfirmedAt != nil,
            createdAt: user.createdAt
        )
    }

    /// Maps supabase-swift's AuthError subtypes into our AuthError enum.
    /// The SDK's error surface is large; we pattern-match on messages when
    /// structured codes aren't exposed.
    private func mapError(_ error: Error) -> Error {
        let description = error.localizedDescription.lowercased()
        if description.contains("invalid login credentials") { return AuthError.invalidCredentials }
        if description.contains("email not confirmed")        { return AuthError.emailNotConfirmed }
        if description.contains("user already registered")     { return AuthError.emailAlreadyRegistered }
        if description.contains("network")                     { return AuthError.networkUnavailable }
        return AuthError.underlying(error.localizedDescription)
    }
}

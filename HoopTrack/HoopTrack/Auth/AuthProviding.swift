// HoopTrack/Auth/AuthProviding.swift
import Foundation

/// Abstracts every network-touching auth operation behind a protocol so
/// tests can inject a MockAuthProvider and production uses SupabaseAuthProvider.
/// All methods are `async throws` — they may block on the network.
protocol AuthProviding: Sendable {
    /// Returns the signed-in user, or nil if no valid session is cached.
    func restoreSession() async throws -> AuthUser?

    /// Email + password sign-up. Supabase sends a confirmation email before
    /// the account is usable; the returned AuthUser will have emailVerified=false
    /// until the user clicks the link.
    func signUp(email: String, password: String) async throws -> AuthUser

    /// Email + password sign-in. Throws `AuthError.emailNotConfirmed` when
    /// the server rejects because the email hasn't been verified.
    func signIn(email: String, password: String) async throws -> AuthUser

    /// Clears the local session. Does not revoke the Supabase session on the
    /// server (cheap, non-critical on sign-out).
    func signOut() async throws

    /// Triggers Supabase to re-send the confirmation email. Rate-limited server-side.
    func resendConfirmationEmail(to email: String) async throws

    /// Polls the server for a fresh user state — used by VerifyEmailView after
    /// the user clicks the email link to check whether verification landed.
    func refreshUser() async throws -> AuthUser?
}

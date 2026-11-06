// HoopTrack/Auth/AuthViewModel.swift
import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md


    @Published private(set) var state: AuthState = .unauthenticated
    /// Set when a password-reset link opened the app; RootView then asks
    /// for the new password.
    @Published var isSettingNewPassword = false

    private let provider: AuthProviding

    init(provider: AuthProviding) {
        self.provider = provider
    }

    // MARK: - Restore (called at app launch)

    func restore() async {
        state = .authenticating
        do {
            if let user = try await provider.restoreSession() {
                state = .authenticated(user)
            } else {
                state = .unauthenticated
            }
        } catch {
            state = .error(mapError(error))
        }
    }

    // MARK: - Sign up

    func signUp(email: String, password: String, confirmPassword: String) async {
        guard isValidEmail(email) else {
            state = .error(.invalidEmail); return
        }
        guard password.count >= HoopTrack.Auth.minPasswordLength else {
            state = .error(.passwordTooShort(minimum: HoopTrack.Auth.minPasswordLength)); return
        }
        guard password == confirmPassword else {
            state = .error(.passwordMismatch); return
        }

        state = .authenticating
        do {
            let user = try await provider.signUp(email: email, password: password)
            state = .authenticated(user)
        } catch {
            state = .error(mapError(error))
        }
    }

    // MARK: - Sign in

    func signIn(email: String, password: String) async {
        guard isValidEmail(email) else {
            state = .error(.invalidEmail); return
        }
        state = .authenticating
        do {
            let user = try await provider.signIn(email: email, password: password)
            state = .authenticated(user)
        } catch {
            state = .error(mapError(error))
        }
    }

    // MARK: - Sign out

    func signOut() async {
        do {
            try await provider.signOut()
        } catch {
            // Sign-out failures are non-fatal; swallow and drop the session locally.
        }
        state = .unauthenticated
    }

    // MARK: - Email confirmation

    /// Re-sends the sign-up confirmation email. Returns false on failure.
    func resendConfirmation() async -> Bool {
        guard let email = state.user?.email, !email.isEmpty else { return false }
        do {
            try await provider.resendConfirmationEmail(to: email)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Error recovery

    /// Clears an error state back to unauthenticated so the UI can accept input again.
    func dismissError() {
        if case .error = state {
            state = .unauthenticated
        }
    }

    // MARK: - Refresh (call after user verifies email)

    func refresh() async {
        do {
            if let user = try await provider.refreshUser() {
                state = .authenticated(user)
            }
        } catch {
            state = .error(mapError(error))
        }
    }

    // MARK: - Deep link (email confirmation)

    /// Handles the `hooptrack://auth/callback?...` URL Supabase sends users to
    /// after they click the confirmation email link. Exchanges the embedded
    /// code for a session and lands the user in the authenticated state.
    func handleDeepLink(_ url: URL) async {
        state = .authenticating
        do {
            let user = try await provider.handleDeepLink(url)
            state = .authenticated(user)
            if url.path.lowercased().hasPrefix(HoopTrack.Auth.passwordResetURL.path) {
                isSettingNewPassword = true
            }
        } catch {
            state = .error(mapError(error))
        }
    }

    // MARK: - Forgotten password

    /// Sends the reset email. Errors are returned, not put in `state`, so a
    /// failed send doesn't knock the sign-in form into an error state.
    func sendPasswordReset(email: String) async -> AuthError? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidEmail(trimmed) else { return .invalidEmail }
        do {
            try await provider.sendPasswordReset(to: trimmed)
            return nil
        } catch {
            return mapError(error)
        }
    }

    func setNewPassword(_ password: String, confirm: String) async -> AuthError? {
        guard password.count >= HoopTrack.Auth.minPasswordLength else {
            return .passwordTooShort(minimum: HoopTrack.Auth.minPasswordLength)
        }
        guard password == confirm else { return .passwordMismatch }
        do {
            try await provider.updatePassword(password)
            isSettingNewPassword = false
            return nil
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Delete account

    /// Deletes the account and its cloud data. Nil on success, after which
    /// the user is signed out.
    func deleteAccount() async -> AuthError? {
        guard state.isAuthenticated else { return nil }
        do {
            try await provider.deleteAccount()
            state = .unauthenticated
            return nil
        } catch {
            return mapError(error)
        }
    }

    // MARK: - Private

    private func isValidEmail(_ email: String) -> Bool {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 5
    }

    private func mapError(_ error: Error) -> AuthError {
        if let authError = error as? AuthError { return authError }
        return .underlying(error.localizedDescription)
    }
}

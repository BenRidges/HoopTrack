// HoopTrack/Auth/AuthViewModel.swift
import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {

    @Published private(set) var state: AuthState = .unauthenticated

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

    // MARK: - Locking

    func lock() {
        if case .authenticated(let user) = state {
            state = .locked(user)
        }
    }

    func unlock() {
        if case .locked(let user) = state {
            state = .authenticated(user)
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
        } catch {
            state = .error(mapError(error))
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

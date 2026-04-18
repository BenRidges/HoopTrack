// HoopTrack/Auth/AuthState.swift
import Foundation

enum AuthState: Sendable, Equatable {
    /// Fresh install or signed out.
    case unauthenticated
    /// Network call in flight (sign-in, sign-up, refresh).
    case authenticating
    /// Signed in, session valid, ready to use the app.
    case authenticated(AuthUser)
    /// Session present but biometrically locked — app was backgrounded
    /// past the timeout. Requires unlock before reaching the main UI.
    case locked(AuthUser)
    /// An operation failed in a way the UI should render.
    case error(AuthError)

    var user: AuthUser? {
        switch self {
        case .authenticated(let u), .locked(let u): return u
        default: return nil
        }
    }

    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
}

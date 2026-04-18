// HoopTrack/Auth/AuthError.swift
import Foundation

enum AuthError: LocalizedError, Sendable, Equatable {
    case invalidEmail
    case passwordTooShort(minimum: Int)
    case passwordMismatch
    case invalidCredentials
    case emailNotConfirmed
    case emailAlreadyRegistered
    case networkUnavailable
    case sessionExpired
    case biometricUnavailable
    case biometricFailed
    case keychainFailure
    case underlying(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "Enter a valid email address."
        case .passwordTooShort(let minimum):
            return "Password must be at least \(minimum) characters."
        case .passwordMismatch:
            return "Passwords don't match."
        case .invalidCredentials:
            return "Email or password is incorrect."
        case .emailNotConfirmed:
            return "Check your inbox and confirm your email before signing in."
        case .emailAlreadyRegistered:
            return "An account with that email already exists. Try signing in instead."
        case .networkUnavailable:
            return "Can't reach the server. Check your internet connection."
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        case .biometricUnavailable:
            return "Face ID / Touch ID isn't set up on this device."
        case .biometricFailed:
            return "Biometric authentication failed."
        case .keychainFailure:
            return "Couldn't access the secure keychain."
        case .underlying(let message):
            return message
        }
    }
}

// HoopTrack/Auth/AuthUser.swift
import Foundation

/// Minimum user identity we persist and surface to the rest of the app.
/// Excludes tokens (those live in KeychainService) and anything PII-sensitive
/// beyond the email the user signed up with.
struct AuthUser: Sendable, Codable, Equatable {
    let id: UUID           // Supabase `auth.uid()`
    let email: String
    let emailVerified: Bool
    let createdAt: Date
}

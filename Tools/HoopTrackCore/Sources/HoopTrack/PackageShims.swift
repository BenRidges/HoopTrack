// PackageShims.swift
// Stand-ins for things the iOS target provides that the pure sources
// reference. Never compiled into the app.

import Foundation

/// Constants.swift reads the Supabase settings from the gitignored
/// BackendSecrets.swift; the package doesn't need real ones.
nonisolated enum BackendSecrets {
    static let supabaseURL = URL(string: "https://example.invalid")!
    static let supabaseAnonKey = ""
}

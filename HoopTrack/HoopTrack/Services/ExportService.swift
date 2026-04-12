// ExportService.swift
// Transforms SwiftData profile + sessions into JSON and writes to a temp file.
// Returns a URL that can be passed directly to ShareLink or UIActivityViewController.

import Foundation

/// Top-level export envelope — the JSON root object.
private struct ProfileExport: Codable {
    let exportedAt: Date
    let profileName: String
    let sessions: [SessionExportRecord]
}

@MainActor
final class ExportService {

    // MARK: - Public Interface

    /// Builds JSON from `profile` and writes it to a dated temp file.
    /// Deletes any previous export file for this profile before writing.
    /// - Returns: URL of the written file in the system temp directory.
    func exportJSON(for profile: PlayerProfile) async throws -> URL {
        let envelope = ProfileExport(
            exportedAt:  .now,
            profileName: profile.name.isEmpty ? "Player" : profile.name,
            sessions:    profile.sessions
                .filter { $0.isComplete }
                .sorted { $0.startedAt > $1.startedAt }
                .map    { SessionExportRecord(from: $0) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        let fileName = "hooptrack-export-\(dateStamp()).json"
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Private Helpers

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: .now)
    }
}

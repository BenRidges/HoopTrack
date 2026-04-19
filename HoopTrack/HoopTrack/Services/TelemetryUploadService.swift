// TelemetryUploadService.swift
// Uploads pending TelemetryUpload rows to the Supabase `telemetry-sessions`
// bucket. Wi-Fi-only, waits for connectivity. On success: deletes the local
// session directory, updates the row. On failure: increments attempt count,
// records error; abandoned after `maxUploadAttempts`.

import Foundation
import SwiftData
import Storage

@MainActor
final class TelemetryUploadService {

    private let modelContext: ModelContext
    private let fileManager = FileManager.default

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Walk pending/failed rows and attempt upload for each. Safe to call
    /// repeatedly; rows already in `.uploading` are skipped.
    func uploadPending(userID: UUID) async {
        let rows = (try? fetchEligible()) ?? []
        for row in rows {
            await upload(row: row, userID: userID)
        }
    }

    // MARK: - Per-row upload

    private func upload(row: TelemetryUpload, userID: UUID) async {
        guard Self.isEligibleForRetry(state: row.state, attempts: row.attemptCount) else { return }

        row.state = .uploading
        row.lastAttemptAt = .now
        row.attemptCount += 1
        try? modelContext.save()

        let sessionDir = telemetryDir(sessionID: row.sessionID)
        let remotePrefix = "\(userID.uuidString)/\(row.sessionID.uuidString)/"

        do {
            let storage = try await SupabaseContainer.storage()
            let bucket = storage.from(HoopTrack.Telemetry.supabaseBucketName)

            // 1. Upload manifest + detections.jsonl first (tiny — smoke tests
            //    the network before spending time on 30 MB of frames).
            for name in ["manifest.json", "detections.jsonl"] {
                let localURL = sessionDir.appendingPathComponent(name)
                guard fileManager.fileExists(atPath: localURL.path) else { continue }
                let data = try Data(contentsOf: localURL)
                let contentType = name.hasSuffix(".json") ? "application/json" : "application/x-ndjson"
                _ = try await bucket.upload(
                    "\(remotePrefix)\(name)",
                    data: data,
                    options: FileOptions(contentType: contentType, upsert: true)
                )
            }

            // 2. Upload frames in parallel with a bounded concurrency.
            let frameURLs = try fileManager.contentsOfDirectory(
                at: sessionDir,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "jpg" }

            try await withThrowingTaskGroup(of: Void.self) { group in
                var inFlight = 0
                for url in frameURLs {
                    if inFlight >= HoopTrack.Telemetry.concurrentFrameUploads {
                        try await group.next()
                        inFlight -= 1
                    }
                    let filename = url.lastPathComponent
                    let data = try Data(contentsOf: url)
                    group.addTask {
                        _ = try await bucket.upload(
                            "\(remotePrefix)\(filename)",
                            data: data,
                            options: FileOptions(contentType: "image/jpeg", upsert: true)
                        )
                    }
                    inFlight += 1
                }
                try await group.waitForAll()
            }

            // 3. All succeeded — mark row, delete local dir.
            row.state = .uploaded
            row.remoteBucketPath = remotePrefix
            row.errorMessage = nil
            try? modelContext.save()

            try? fileManager.removeItem(at: sessionDir)

        } catch {
            row.state = Self.nextStateAfterFailure(
                currentAttempts: row.attemptCount,
                maxAttempts: HoopTrack.Telemetry.maxUploadAttempts
            )
            row.errorMessage = String(describing: error)
            try? modelContext.save()
        }
    }

    // MARK: - Pure helpers (testable)

    /// Given a row's current attempt count, decide the state to move to
    /// after a failed upload. Exposed for tests.
    static func nextStateAfterFailure(currentAttempts: Int, maxAttempts: Int) -> UploadState {
        currentAttempts >= maxAttempts ? .abandoned : .failed
    }

    /// Whether a row is eligible for another upload attempt.
    static func isEligibleForRetry(state: UploadState, attempts: Int) -> Bool {
        switch state {
        case .pending:   return true
        case .failed:    return attempts < HoopTrack.Telemetry.maxUploadAttempts
        case .uploading, .uploaded, .abandoned: return false
        }
    }

    // MARK: - Private helpers

    private func fetchEligible() throws -> [TelemetryUpload] {
        let descriptor = FetchDescriptor<TelemetryUpload>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let all = try modelContext.fetch(descriptor)
        return all.filter { Self.isEligibleForRetry(state: $0.state, attempts: $0.attemptCount) }
    }

    private func telemetryDir(sessionID: UUID) -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent(HoopTrack.Telemetry.telemetryDirectoryName)
            .appendingPathComponent(sessionID.uuidString)
    }
}

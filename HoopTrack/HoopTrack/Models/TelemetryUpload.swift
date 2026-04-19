// TelemetryUpload.swift
// One row per session that has captured telemetry and needs to be (or has
// been) uploaded to Supabase Storage. Deliberately loose-coupled to
// TrainingSession / GameSession via UUID so the upload row outlives the
// session if the user deletes it mid-upload.

import Foundation
import SwiftData

@Model
final class TelemetryUpload {
    @Attribute(.unique) var sessionID: UUID
    var stateRaw: String            // UploadState.rawValue
    var sessionKindRaw: String      // SessionKind.rawValue
    var frameCount: Int
    var totalBytes: Int
    var remoteBucketPath: String?
    var createdAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var errorMessage: String?

    init(
        sessionID: UUID,
        sessionKind: SessionKind,
        frameCount: Int,
        totalBytes: Int
    ) {
        self.sessionID = sessionID
        self.stateRaw = UploadState.pending.rawValue
        self.sessionKindRaw = sessionKind.rawValue
        self.frameCount = frameCount
        self.totalBytes = totalBytes
        self.createdAt = .now
        self.attemptCount = 0
    }

    var state: UploadState {
        get { UploadState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    var sessionKind: SessionKind {
        get { SessionKind(rawValue: sessionKindRaw) ?? .training }
        set { sessionKindRaw = newValue.rawValue }
    }
}

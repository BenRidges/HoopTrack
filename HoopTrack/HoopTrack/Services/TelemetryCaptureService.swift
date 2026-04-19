// TelemetryCaptureService.swift
// Post-session: reads detections.jsonl, applies FrameSampler rules,
// extracts JPEGs from the recorded .mov, writes manifest.json, creates a
// TelemetryUpload @Model row in .pending state.
//
// Runs off-main via Task.detached so it doesn't block session summary.

import Foundation
import AVFoundation
import UIKit
import SwiftData

@MainActor
final class TelemetryCaptureService {

    private let modelContext: ModelContext
    private let fileManager = FileManager.default

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    struct CaptureResult: Sendable {
        let frameCount: Int
        let totalBytes: Int
    }

    /// Main entry point. Called from SessionFinalizationCoordinator step 10.
    /// Returns a CaptureResult if work happened, nil if skipped.
    func capture(
        sessionID: UUID,
        sessionKind: SessionKind,
        videoURL: URL,
        shotTimestamps: [Double],
        sessionStartedAt: Date,
        sessionDurationSec: Double,
        modelVersion: String,
        appVersion: String
    ) async -> CaptureResult? {

        // Short-circuit if session is too trivial.
        guard sessionDurationSec >= HoopTrack.Telemetry.minSessionDurationSec else {
            return nil
        }

        // Short-circuit if detections.jsonl is missing.
        let sessionDir = telemetryDir(sessionID: sessionID)
        let logURL = sessionDir.appendingPathComponent("detections.jsonl")
        guard fileManager.fileExists(atPath: logURL.path) else { return nil }

        // Capture all the parameters the detached task needs as Sendable locals.
        let capturedVideoURL = videoURL
        let capturedShots = shotTimestamps
        let capturedDuration = sessionDurationSec
        let capturedLogURL = logURL
        let capturedSessionDir = sessionDir

        // Phase A — off-main: read log + extract frames.
        let extraction = await Task.detached { () -> (timestamps: [Double], triggerSummary: [String: Int], frameBytes: [(name: String, bytes: Int)])? in
            do {
                let log = try Self.readLog(at: capturedLogURL)
                let timestamps = FrameSampler.sampleTimestamps(
                    log: log,
                    shotTimestamps: capturedShots,
                    sessionDurationSec: capturedDuration
                )
                let triggerSummary = Self.computeTriggerSummary(
                    log: log,
                    shotTimestamps: capturedShots,
                    selected: timestamps,
                    sessionDurationSec: capturedDuration
                )
                let frameBytes = try Self.extractFrames(
                    videoURL: capturedVideoURL,
                    timestamps: timestamps,
                    outputDir: capturedSessionDir
                )
                return (timestamps, triggerSummary, frameBytes)
            } catch {
                return nil
            }
        }.value

        guard let extraction else { return nil }

        // Phase B — on main: write manifest + TelemetryUpload row.
        do {
            try writeManifest(
                sessionDir: sessionDir,
                sessionID: sessionID,
                sessionKind: sessionKind,
                sessionStartedAt: sessionStartedAt,
                sessionDurationSec: sessionDurationSec,
                shotCount: shotTimestamps.count,
                modelVersion: modelVersion,
                appVersion: appVersion,
                triggerSummary: extraction.triggerSummary,
                frames: extraction.frameBytes,
                timestamps: extraction.timestamps
            )
        } catch {
            return nil
        }

        let manifestBytes = (try? Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")).count) ?? 0
        let logBytes = (try? Data(contentsOf: logURL).count) ?? 0
        let totalBytes = extraction.frameBytes.reduce(0, { $0 + $1.bytes }) + manifestBytes + logBytes

        let row = TelemetryUpload(
            sessionID: sessionID,
            sessionKind: sessionKind,
            frameCount: extraction.frameBytes.count,
            totalBytes: totalBytes
        )
        modelContext.insert(row)
        try? modelContext.save()

        return CaptureResult(
            frameCount: extraction.frameBytes.count,
            totalBytes: totalBytes
        )
    }

    // MARK: - Helpers

    private func telemetryDir(sessionID: UUID) -> URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent(HoopTrack.Telemetry.telemetryDirectoryName)
            .appendingPathComponent(sessionID.uuidString)
    }

    nonisolated private static func readLog(at url: URL) throws -> [DetectionLogEntry] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                try? DetectionLogEntry.decode(jsonLine: String(line))
            }
    }

    nonisolated private static func computeTriggerSummary(
        log: [DetectionLogEntry],
        shotTimestamps: [Double],
        selected: [Double],
        sessionDurationSec: Double
    ) -> [String: Int] {
        var summary: [String: Int] = ["baseline": 0, "around_shot": 0, "flicker": 0, "boundaries": 0]
        let step = 1.0 / HoopTrack.Telemetry.baselineSampleFPS
        let boundary = Set(log.prefix(HoopTrack.Telemetry.boundaryFrames).map(\.timestampSec)
            + log.suffix(HoopTrack.Telemetry.boundaryFrames).map(\.timestampSec))
        for t in selected {
            if boundary.contains(t) {
                summary["boundaries", default: 0] += 1
            } else if shotTimestamps.contains(where: { abs($0 - t) <= 0.334 }) {
                summary["around_shot", default: 0] += 1
            } else if abs(t.truncatingRemainder(dividingBy: step)) < 1e-3 ||
                      abs(step - t.truncatingRemainder(dividingBy: step)) < 1e-3 {
                summary["baseline", default: 0] += 1
            } else {
                summary["flicker", default: 0] += 1
            }
        }
        return summary
    }

    nonisolated private static func extractFrames(
        videoURL: URL,
        timestamps: [Double],
        outputDir: URL
    ) throws -> [(name: String, bytes: Int)] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let edge = CGFloat(HoopTrack.Telemetry.frameMaxLongestEdgePx)
        generator.maximumSize = CGSize(width: edge, height: edge)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: 30)

        var out: [(name: String, bytes: Int)] = []
        for (idx, ts) in timestamps.enumerated() {
            let cmTime = CMTime(seconds: ts, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: nil) else {
                continue
            }
            let image = UIImage(cgImage: cgImage)
            guard let jpeg = image.jpegData(compressionQuality: HoopTrack.Telemetry.frameJpegQuality) else {
                continue
            }
            let name = String(format: "frame_%04d.jpg", idx)
            let url = outputDir.appendingPathComponent(name)
            try jpeg.write(to: url, options: [.completeFileProtection])
            out.append((name, jpeg.count))
        }
        return out
    }

    private struct ManifestFrame: Encodable {
        let file: String
        let timestamp_sec: Double
        let width: Int
        let height: Int
    }

    private struct Manifest: Encodable {
        let session_id: String
        let session_kind: String
        let app_version: String
        let model_version: String
        let session_started_at: String
        let session_duration_sec: Double
        let total_shots: Int
        let frame_count: Int
        let trigger_summary: [String: Int]
        let frames: [ManifestFrame]
    }

    private func writeManifest(
        sessionDir: URL,
        sessionID: UUID,
        sessionKind: SessionKind,
        sessionStartedAt: Date,
        sessionDurationSec: Double,
        shotCount: Int,
        modelVersion: String,
        appVersion: String,
        triggerSummary: [String: Int],
        frames: [(name: String, bytes: Int)],
        timestamps: [Double]
    ) throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let manifestFrames = zip(frames, timestamps).map { (pair, ts) in
            ManifestFrame(
                file: pair.name,
                timestamp_sec: ts,
                width: HoopTrack.Telemetry.frameMaxLongestEdgePx,
                height: HoopTrack.Telemetry.frameMaxLongestEdgePx
            )
        }

        let manifest = Manifest(
            session_id: sessionID.uuidString,
            session_kind: sessionKind.rawValue,
            app_version: appVersion,
            model_version: modelVersion,
            session_started_at: iso.string(from: sessionStartedAt),
            session_duration_sec: sessionDurationSec,
            total_shots: shotCount,
            frame_count: frames.count,
            trigger_summary: triggerSummary,
            frames: manifestFrames
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: sessionDir.appendingPathComponent("manifest.json"),
                       options: [.completeFileProtection])
    }
}

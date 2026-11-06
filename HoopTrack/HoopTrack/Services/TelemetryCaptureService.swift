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

    /// Main entry point. Called from SessionFinalizationCoordinator.
    /// Returns a CaptureResult if work happened, nil if skipped.
    func capture(
        sessionID: UUID,
        sessionKind: SessionKind,
        videoURL: URL,
        shots: [TelemetryManifest.Shot],
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

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let startedAt = iso.string(from: sessionStartedAt)
        let kind = sessionKind.rawValue

        // Off-main: read the log, pull the frames, write the manifest.
        let extraction = await Task.detached { () -> (frames: Int, frameBytes: Int)? in
            do {
                let log = try Self.readLog(at: logURL).sorted { $0.timestampSec < $1.timestampSec }
                let shotTimes = shots.map(\.videoSec)
                let timestamps = FrameSampler.sampleTimestamps(
                    log: log,
                    shotTimestamps: shotTimes,
                    sessionDurationSec: sessionDurationSec
                )
                let extracted = try Self.extractFrames(videoURL: videoURL, timestamps: timestamps,
                                                       outputDir: sessionDir)
                let frames = extracted.map { frame in
                    TelemetryManifest.Frame(
                        file: frame.name,
                        timestampSec: frame.actualTime,
                        width: frame.width,
                        height: frame.height,
                        trigger: TelemetryManifest.trigger(for: frame.requestedTime, log: log,
                                                           shotTimes: shotTimes),
                        detections: TelemetryManifest.detections(near: frame.actualTime, in: log)
                    )
                }
                var summary = ["baseline": 0, "around_shot": 0, "flicker": 0, "boundaries": 0]
                for frame in frames { summary[frame.trigger, default: 0] += 1 }

                let manifest = TelemetryManifest(
                    sessionId: sessionID.uuidString,
                    sessionKind: kind,
                    appVersion: appVersion,
                    modelVersion: modelVersion,
                    sessionStartedAt: startedAt,
                    sessionDurationSec: sessionDurationSec,
                    totalShots: shots.count,
                    frameCount: frames.count,
                    triggerSummary: summary,
                    frames: frames,
                    shots: shots
                )
                try TelemetryManifest.encoder().encode(manifest)
                    .write(to: sessionDir.appendingPathComponent("manifest.json"),
                           options: [.completeFileProtection])
                return (frames.count, extracted.reduce(0) { $0 + $1.bytes })
            } catch {
                return nil
            }
        }.value

        guard let extraction else { return nil }

        let manifestBytes = (try? Data(contentsOf: sessionDir.appendingPathComponent("manifest.json")).count) ?? 0
        let logBytes = (try? Data(contentsOf: logURL).count) ?? 0
        let totalBytes = extraction.frameBytes + manifestBytes + logBytes

        let row = TelemetryUpload(
            sessionID: sessionID,
            sessionKind: sessionKind,
            frameCount: extraction.frames,
            totalBytes: totalBytes
        )
        modelContext.insert(row)
        try? modelContext.save()

        return CaptureResult(frameCount: extraction.frames, totalBytes: totalBytes)
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

    nonisolated private struct ExtractedFrame: Sendable {
        let name: String
        let bytes: Int
        let requestedTime: Double
        let actualTime: Double
        let width: Int
        let height: Int
    }

    /// Frames that fail to decode are skipped, so each result carries its
    /// own times and size rather than relying on its position.
    nonisolated private static func extractFrames(
        videoURL: URL,
        timestamps: [Double],
        outputDir: URL
    ) throws -> [ExtractedFrame] {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let edge = CGFloat(HoopTrack.Telemetry.frameMaxLongestEdgePx)
        generator.maximumSize = CGSize(width: edge, height: edge)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: 60)

        var out: [ExtractedFrame] = []
        for (idx, ts) in timestamps.enumerated() {
            var actual = CMTime.invalid
            let cmTime = CMTime(seconds: ts, preferredTimescale: 600)
            guard let cgImage = try? generator.copyCGImage(at: cmTime, actualTime: &actual) else {
                continue
            }
            let image = UIImage(cgImage: cgImage)
            guard let jpeg = image.jpegData(compressionQuality: HoopTrack.Telemetry.frameJpegQuality) else {
                continue
            }
            let name = String(format: "frame_%04d.jpg", idx)
            try jpeg.write(to: outputDir.appendingPathComponent(name), options: [.completeFileProtection])
            out.append(ExtractedFrame(name: name, bytes: jpeg.count, requestedTime: ts,
                                      actualTime: actual.isValid ? CMTimeGetSeconds(actual) : ts,
                                      width: cgImage.width, height: cgImage.height))
        }
        return out
    }
}

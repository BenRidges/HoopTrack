// TelemetryManifest.swift
// manifest.json for a shared session (CV-A): which frames were pulled from
// the video, what the detector saw in each, and what every shot turned out
// to be. Tools/dataset/build_dataset.py turns a folder of these into a
// training set; the boxes are the starting labels, the shots say where the
// model went wrong.
//
// Boxes here are normalised [x, y, w, h] with the origin at the TOP-left,
// as image tools expect — not Vision's bottom-left.
//
// Pure logic; TelemetryCaptureService does the file and video work.

import Foundation

nonisolated struct TelemetryManifest: Codable, Sendable, Equatable {

    /// 2 added per-frame detections, triggers and the shots list.
    static let currentSchema = 2

    struct Detection: Codable, Sendable, Equatable {
        /// "ball" or "basket" (the model's class names).
        let label: String
        let box: [Double]
        let confidence: Double
    }

    struct Frame: Codable, Sendable, Equatable {
        let file: String
        /// Where the frame really is in the video (may differ slightly from
        /// the time asked for).
        let timestampSec: Double
        let width: Int
        let height: Int
        /// Why it was picked: baseline, around_shot, flicker or boundaries.
        let trigger: String
        /// From the log frame nearest `timestampSec`; empty when there was none.
        let detections: [Detection]

        enum CodingKeys: String, CodingKey {
            case file, width, height, trigger, detections
            case timestampSec = "timestamp_sec"
        }
    }

    struct Shot: Codable, Sendable, Equatable {
        /// Release time for auto calls, tap time for hand-logged shots.
        let videoSec: Double
        /// "make" or "miss", after any correction.
        let result: String
        /// The tracker's confidence; nil = logged by hand.
        let autoConfidence: Double?
        let needsReview: Bool
        let userCorrected: Bool

        enum CodingKeys: String, CodingKey {
            case result
            case videoSec       = "video_sec"
            case autoConfidence = "auto_confidence"
            case needsReview    = "needs_review"
            case userCorrected  = "user_corrected"
        }
    }

    var schemaVersion = TelemetryManifest.currentSchema
    let sessionId: String
    let sessionKind: String
    let appVersion: String
    let modelVersion: String
    let sessionStartedAt: String
    let sessionDurationSec: Double
    var boxFormat = "normalised [x, y, w, h], origin top-left"
    let totalShots: Int
    let frameCount: Int
    let triggerSummary: [String: Int]
    let frames: [Frame]
    let shots: [Shot]

    enum CodingKeys: String, CodingKey {
        case frames, shots
        case schemaVersion      = "schema_version"
        case sessionId          = "session_id"
        case sessionKind        = "session_kind"
        case appVersion         = "app_version"
        case modelVersion       = "model_version"
        case sessionStartedAt   = "session_started_at"
        case sessionDurationSec = "session_duration_sec"
        case boxFormat          = "box_format"
        case totalShots         = "total_shots"
        case frameCount         = "frame_count"
        case triggerSummary     = "trigger_summary"
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: - Building

    /// The detections logged for the frame nearest `time`, if one is within
    /// `tolerance`. `log` must be in time order.
    static func detections(near time: Double, in log: [DetectionLogEntry],
                           tolerance: Double = 1.0 / 40) -> [Detection] {
        guard let entry = nearest(to: time, in: log),
              abs(entry.timestampSec - time) <= tolerance else { return [] }
        var out: [Detection] = []
        if let balls = entry.balls {
            for ball in balls where ball.count >= 5 {
                if let box = topLeft(Array(ball.prefix(4))) {
                    out.append(Detection(label: "ball", box: box, confidence: ball[4]))
                }
            }
        } else if let ball = entry.ballBox, let box = topLeft(ball) {
            out.append(Detection(label: "ball", box: box, confidence: entry.ballConfidence ?? 0))
        }
        if let rim = entry.rimBox, let box = topLeft(rim) {
            out.append(Detection(label: "basket", box: box, confidence: entry.rimConfidence ?? 0))
        }
        return out
    }

    /// Vision box (origin bottom-left) to image box (origin top-left).
    static func topLeft(_ box: [Double]) -> [Double]? {
        guard box.count >= 4, box[2] > 0, box[3] > 0 else { return nil }
        return [box[0], 1 - box[1] - box[3], box[2], box[3]]
    }

    /// Why a sampled timestamp was picked (FrameSampler's triggers).
    static func trigger(for time: Double, log: [DetectionLogEntry], shotTimes: [Double]) -> String {
        let edge = HoopTrack.Telemetry.boundaryFrames
        let boundary = log.prefix(edge).map(\.timestampSec) + log.suffix(edge).map(\.timestampSec)
        if boundary.contains(where: { abs($0 - time) < 1e-6 }) { return "boundaries" }
        if shotTimes.contains(where: { abs($0 - time) <= 0.334 }) { return "around_shot" }
        let step = 1.0 / HoopTrack.Telemetry.baselineSampleFPS
        let phase = time.truncatingRemainder(dividingBy: step)
        if phase < 1e-3 || step - phase < 1e-3 { return "baseline" }
        return "flicker"
    }

    private static func nearest(to time: Double, in log: [DetectionLogEntry]) -> DetectionLogEntry? {
        guard !log.isEmpty else { return nil }
        var low = 0, high = log.count - 1
        while low < high {
            let mid = (low + high) / 2
            if log[mid].timestampSec < time { low = mid + 1 } else { high = mid }
        }
        // `low` is the first entry at or after `time`; the one before may be closer.
        if low > 0, abs(log[low - 1].timestampSec - time) <= abs(log[low].timestampSec - time) {
            return log[low - 1]
        }
        return log[low]
    }
}

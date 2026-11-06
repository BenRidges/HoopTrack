// DetectionLogEntry.swift
// One line of detections.jsonl — the per-frame metadata written by
// DetectionLogger during a live session and read back post-session by
// TelemetryCaptureService to find sampling-worthy timestamps. The
// shot-eval tool (Tools/HoopTrackCore) replays these logs through
// ShotTracker to measure tuning changes.
//
// The fields after `state` were added later and are optional, so older
// logs still decode.

import Foundation

nonisolated struct DetectionLogEntry: Codable, Sendable, Equatable {
    /// Seconds since session start (aligned to recorded .mov timeline).
    let timestampSec: Double

    /// Ball detection confidence 0–1; nil when no ball detected.
    let ballConfidence: Double?

    /// Ball bbox normalized [x, y, w, h]; nil when no ball.
    let ballBox: [Double]?

    /// Rim detection confidence; nil when no rim lock.
    let rimConfidence: Double?

    /// Rim bbox normalized; nil when no rim.
    let rimBox: [Double]?

    /// CVPipeline state at the frame.
    let state: String

    /// Every ball candidate: [x, y, w, h, confidence], most confident first.
    var balls: [[Double]]? = nil

    /// Detection crop for the frame, [x, y, w, h]; nil = full frame.
    var region: [Double]? = nil

    /// Tracker event on this frame: "start", "make" or "miss".
    var event: String? = nil

    /// Confidence of a make/miss call made on this frame.
    var eventConfidence: Double? = nil

    /// Net movement since the previous frame (NetMotion.activity), nil when
    /// the net wasn't sampled.
    var netActivity: Double? = nil

    /// Call published after the net check ("make"/"miss"), when it was held.
    var checkedEvent: String? = nil
    var checkedConfidence: Double? = nil

    enum CodingKeys: String, CodingKey {
        case timestampSec    = "t"
        case ballConfidence  = "ci"
        case ballBox         = "bb"
        case rimConfidence   = "ri"
        case rimBox          = "rb"
        case state           = "st"
        case balls           = "bs"
        case region          = "roi"
        case event           = "ev"
        case eventConfidence = "ec"
        case netActivity     = "na"
        case checkedEvent    = "cv"
        case checkedConfidence = "cc"
    }

    /// Encode as a single-line JSON terminated with `\n`. Safe to append
    /// directly to a FileHandle.
    func jsonLine() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let s = String(data: data, encoding: .utf8) else {
            throw DetectionLogEntryError.encodingFailed
        }
        return s + "\n"
    }

    /// Decode a single line (with or without trailing newline).
    static func decode(jsonLine: String) throws -> DetectionLogEntry {
        let trimmed = jsonLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw DetectionLogEntryError.decodingFailed
        }
        return try JSONDecoder().decode(DetectionLogEntry.self, from: data)
    }
}

nonisolated enum DetectionLogEntryError: Error {
    case encodingFailed
    case decodingFailed
}

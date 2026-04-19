// DetectionLogEntry.swift
// One line of detections.jsonl — the per-frame metadata written by
// DetectionLogger during a live session and read back post-session by
// TelemetryCaptureService to find sampling-worthy timestamps.

import Foundation

struct DetectionLogEntry: Codable, Sendable, Equatable {
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

    enum CodingKeys: String, CodingKey {
        case timestampSec   = "t"
        case ballConfidence = "ci"
        case ballBox        = "bb"
        case rimConfidence  = "ri"
        case rimBox         = "rb"
        case state          = "st"
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

enum DetectionLogEntryError: Error {
    case encodingFailed
    case decodingFailed
}

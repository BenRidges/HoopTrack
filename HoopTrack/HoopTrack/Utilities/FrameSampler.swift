// FrameSampler.swift
// Pure-logic trigger-rule engine for CV-A. Given a detection log + shot
// timestamps + session duration, returns the sorted, unique list of
// timestamps to extract frames at. Tested in isolation without Vision or
// AVFoundation.

import Foundation

nonisolated enum FrameSampler {

    /// Main entry point. Applies all four triggers, dedupes, decimates if
    /// over cap. Return value is sorted ascending; timestamps in seconds.
    static func sampleTimestamps(
        log: [DetectionLogEntry],
        shotTimestamps: [Double],
        sessionDurationSec: Double
    ) -> [Double] {
        guard !log.isEmpty, sessionDurationSec > 0 else { return [] }

        let baseline   = baselineTimestamps(durationSec: sessionDurationSec)
        let aroundShot = aroundShotTimestamps(log: log, shots: shotTimestamps)
        let flicker    = flickerTimestamps(log: log)
        let boundary   = boundaryTimestamps(log: log)

        let merged = dedupe(priority: [boundary, aroundShot, flicker, baseline])

        return decimateIfNeeded(
            timestamps: merged,
            baseline: baseline,
            flicker: flicker,
            aroundShot: aroundShot,
            boundary: boundary,
            cap: HoopTrack.Telemetry.maxFramesPerSession
        )
    }

    // MARK: - Triggers

    private static func baselineTimestamps(durationSec: Double) -> [Double] {
        let step = 1.0 / HoopTrack.Telemetry.baselineSampleFPS
        return Array(stride(from: 0.0, to: durationSec, by: step))
    }

    /// Picks the `preFrames` frames ending at the shot timestamp plus
    /// `postFrames` starting at the shot timestamp. Operates on the log so
    /// the timestamps are real frame times (not interpolated).
    private static func aroundShotTimestamps(
        log: [DetectionLogEntry],
        shots: [Double]
    ) -> [Double] {
        var out: [Double] = []
        let pre = HoopTrack.Telemetry.aroundShotPreFrames
        let post = HoopTrack.Telemetry.aroundShotPostFrames
        for shot in shots {
            guard let idx = nearestIndex(in: log, to: shot) else { continue }
            let start = max(0, idx - pre)
            let end = min(log.count - 1, idx + post)
            for i in start...end {
                out.append(log[i].timestampSec)
            }
        }
        return out
    }

    /// Finds runs where `ballConfidence` drops from ≥ high to < low for
    /// ≥ `flickerMinConsecutiveFrames` frames. Samples every 3rd frame in the
    /// run plus a 3-frame shoulder on each side.
    private static func flickerTimestamps(log: [DetectionLogEntry]) -> [Double] {
        let high = HoopTrack.Telemetry.flickerThresholdHigh
        let low = HoopTrack.Telemetry.flickerThresholdLow
        let minRun = HoopTrack.Telemetry.flickerMinConsecutiveFrames

        var out: [Double] = []
        var runStart: Int? = nil
        var i = 0
        while i < log.count {
            let conf = log[i].ballConfidence ?? 0
            if conf < low {
                if runStart == nil { runStart = i }
            } else {
                if let start = runStart, i - start >= minRun, conf >= high {
                    let from = max(0, start - 3)
                    let to = min(log.count - 1, i + 2)
                    var j = from
                    while j <= to {
                        out.append(log[j].timestampSec)
                        j += 3
                    }
                }
                runStart = nil
            }
            i += 1
        }
        return out
    }

    private static func boundaryTimestamps(log: [DetectionLogEntry]) -> [Double] {
        let n = HoopTrack.Telemetry.boundaryFrames
        let head = log.prefix(n).map(\.timestampSec)
        let tail = log.suffix(n).map(\.timestampSec)
        return head + tail
    }

    // MARK: - Dedupe + decimate

    private static func nearestIndex(in log: [DetectionLogEntry], to t: Double) -> Int? {
        guard !log.isEmpty else { return nil }
        var best = 0
        var bestDelta = abs(log[0].timestampSec - t)
        for (i, entry) in log.enumerated() {
            let d = abs(entry.timestampSec - t)
            if d < bestDelta {
                best = i
                bestDelta = d
            }
        }
        return best
    }

    private static func dedupe(priority: [[Double]]) -> [Double] {
        let tolerance = 1.0 / 60.0   // 16.7ms — slightly less than one frame at 30fps
        let all = priority.flatMap { $0 }.sorted()
        var result: [Double] = []
        for t in all {
            if let last = result.last, t - last < tolerance { continue }
            result.append(t)
        }
        return result
    }

    private static func decimateIfNeeded(
        timestamps: [Double],
        baseline: [Double],
        flicker: [Double],
        aroundShot: [Double],
        boundary: [Double],
        cap: Int
    ) -> [Double] {
        if timestamps.count <= cap { return timestamps }

        let protectedSet = Set(boundary + aroundShot)
        let baselineSet = Set(baseline)
        let flickerSet = Set(flicker)

        var current = timestamps

        // Tier 1: drop baseline that isn't protected, evenly-spaced
        var droppable = current.filter { baselineSet.contains($0) && !protectedSet.contains($0) }
        if !droppable.isEmpty, current.count > cap {
            let need = current.count - cap
            let step = max(1, droppable.count / max(1, need))
            var toRemove: Set<Double> = []
            var i = 0
            while i < droppable.count, toRemove.count < need {
                toRemove.insert(droppable[i])
                i += step
            }
            current.removeAll { toRemove.contains($0) }
        }
        if current.count <= cap { return current }

        // Tier 2: drop flicker
        droppable = current.filter { flickerSet.contains($0) && !protectedSet.contains($0) }
        let need = current.count - cap
        let toRemove = Set(droppable.prefix(need))
        current.removeAll { toRemove.contains($0) }

        return current
    }
}

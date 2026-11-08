// VideoCuts.swift
// Time cut out of a session video while nobody was shooting. The recorder
// stops writing frames during a long break and closes the gap, so the file
// (and the replay) skips straight to the next shot; this keeps track of
// how much has been cut so a moment on the camera's clock can still be
// found in the file.

import Foundation

nonisolated struct VideoCuts: Equatable, Sendable {

    private struct Cut: Equatable {
        /// Camera time of the last frame written before the gap.
        let lastBefore: Double
        /// Camera time of the first frame written after it.
        let firstAfter: Double
        /// Total cut from the file up to and including this gap.
        let totalAfter: Double
    }

    private var cuts: [Cut] = []
    /// Camera time of the last frame written.
    private var lastWritten: Double?
    /// Frames have been skipped since `lastWritten`.
    private var inGap = false

    /// Seconds cut so far.
    var total: Double { cuts.last?.totalAfter ?? 0 }

    /// A frame the recorder dropped.
    mutating func skipped() {
        if lastWritten != nil { inGap = true }
    }

    /// A frame about to be written at camera time `time`. Returns how far
    /// to move it back in the file, closing any gap since the last frame
    /// written down to one `frameInterval`.
    mutating func writing(at time: Double, frameInterval: Double) -> Double {
        defer { lastWritten = time }
        guard inGap, let last = lastWritten else { return total }
        inGap = false
        let gap = time - last - frameInterval
        guard gap > 0 else { return total }
        cuts.append(Cut(lastBefore: last, firstAfter: time, totalAfter: total + gap))
        return total
    }

    /// Where camera time `time` is in the file, given the file's first
    /// frame at camera time `start`. A moment inside a gap maps to where
    /// the gap was closed.
    func fileOffset(of time: Double, start: Double) -> Double {
        var cut = 0.0
        for c in cuts {
            if time >= c.firstAfter {
                cut = c.totalAfter
            } else if time > c.lastBefore {
                return max(0, c.lastBefore - start - cut)
            } else {
                break
            }
        }
        return max(0, time - start - cut)
    }
}

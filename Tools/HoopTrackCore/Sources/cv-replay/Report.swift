// Report.swift
// Turns a live run into shots.csv, summary.txt, fidelity.txt and
// shot-eval.txt.
//
// Fidelity: the calls the delegate received are compared with what
// shot-eval makes of the detections.jsonl the same run wrote — the check
// that offline replay (which is how the tracker gets tuned) tells the same
// story as the live pipeline. Three comparisons:
//   1. shot-eval (the real binary, run on the log) vs ShotReplay.run in
//      process — the same function, so they must agree;
//   2. ReplayTrace (ShotReplay.run with the frame bookkeeping kept) vs
//      ShotReplay.run — must agree too, or the harness is wrong;
//   3. the live delegate's calls vs ReplayTrace's, one by one: published
//      on the same frame, same release time (DetectedShot.videoOffset),
//      same result, same confidence.
// Anything that differs is listed, not smoothed over.

import CoreGraphics
import Foundation
@testable import HoopTrack

struct CallPair {
    /// Row in the comparison.
    let index: Int
    /// Position among the delegate's calls / the replay's (and shot-eval's).
    let liveIndex: Int?
    let replayIndex: Int?
    let live: RecordingDelegate.Shot?
    let replay: ReplayTrace.Call?
    let problems: [String]
    var matches: Bool { live != nil && replay != nil && problems.isEmpty }
}

struct ShotEvalRun {
    struct Line { let time: Double; let result: ShotResult; let confidence: Double; let flagged: Bool }
    let command: String
    let output: String
    let calls: [Line]
}

@MainActor
struct Report {

    let options: Options
    let live: LiveRun
    let entries: [DetectionLogEntry]
    let trace: (calls: [ReplayTrace.Call], frames: [ReplayTrace.Frame])
    let replayCalls: [ShotReplay.Call]
    let pairs: [CallPair]
    /// Fed-frame index for each log entry (nil if it couldn't be matched).
    let entryFed: [Int?]
    /// Live hoop state (0 looking / 1 tracking / 2 lost) after each fed frame.
    let liveHoopKind: [Int]
    let shotEval: ShotEvalRun?
    let shotEvalNote: String?
    let labels: [ShotEvaluation.Label]?
    /// Labels outside the processed span (--start / --duration), not scored.
    let labelsOutside: Int

    init(options: Options, live: LiveRun, entries: [DetectionLogEntry]) {
        self.options = options
        self.live = live
        self.entries = entries
        trace = ReplayTrace.run(entries)
        replayCalls = ShotReplay.run(entries)

        // Log entries ↔ fed frames: the log's t is (PTS − session start),
        // computed the same way here.
        var mapping: [Int?] = []
        var k = 0
        for entry in entries {
            while k < live.fedPTS.count, live.fedPTS[k] - live.sessionStart < entry.timestampSec - 1e-9 { k += 1 }
            if k < live.fedPTS.count, abs(live.fedPTS[k] - live.sessionStart - entry.timestampSec) <= 1e-9 {
                mapping.append(k)
                k += 1
            } else {
                mapping.append(nil)
            }
        }
        entryFed = mapping

        var kinds = [Int](repeating: -1, count: live.fedPTS.count)
        var change = 0, current = -1
        for frame in kinds.indices {
            while change < live.hoopChanges.count, live.hoopChanges[change].frame <= frame {
                current = live.hoopChanges[change].kind
                change += 1
            }
            kinds[frame] = current
        }
        liveHoopKind = kinds

        pairs = Self.pair(live: live.shots, replay: trace.calls, sessionStart: live.sessionStart)

        if let url = options.labels, let text = try? String(contentsOf: url, encoding: .utf8) {
            let all = ShotEvaluation.labels(fromCSV: text)
            // Scoring part of a video against all its labels would count
            // every shot outside the part as missed.
            if options.timeRange != nil, let first = live.fedPTS.first, let last = live.fedPTS.last {
                let span = live.video(first)...live.video(last)
                labels = all.filter { span.contains($0.time) }
            } else {
                labels = all
            }
            labelsOutside = all.count - (labels?.count ?? 0)
        } else {
            labels = nil
            labelsOutside = 0
        }
        let run = Self.runShotEval(options: options, logZero: live.logZero, labels: labels,
                                   rewrite: labelsOutside > 0)
        shotEval = run.0
        shotEvalNote = run.1
    }

    // MARK: - Pairing

    /// Lines the two lists up by the frame each call was published on
    /// (both in order), so one missing call shows as one row rather than
    /// shifting every row after it. Calls settled when the session / log
    /// ended (stop()'s hand-back, the replay's final flush) come last.
    private static func pair(live: [RecordingDelegate.Shot], replay: [ReplayTrace.Call],
                             sessionStart: Double) -> [CallPair] {
        var rows: [CallPair] = []
        var i = 0, j = 0
        while i < live.count || j < replay.count {
            let l = i < live.count ? live[i] : nil
            let r = j < replay.count ? replay[j] : nil
            // Log time of the publishing frame; infinity = at the end.
            let liveKey = l.map { $0.atEnd ? Double.infinity : $0.pts - sessionStart }
            let replayKey = r.map { $0.publishedAt ?? .infinity }
            var problems: [String] = []
            if let l, let r, let a = liveKey, let b = replayKey, a == b || abs(a - b) <= 1e-6 {
                if l.shot.result != r.result {
                    problems.append("result: live \(name(l.shot.result)), replay \(name(r.result))")
                }
                if abs(l.shot.confidence - r.confidence) > 1e-9 {
                    problems.append("confidence: live \(f(l.shot.confidence, 4)), replay \(f(r.confidence, 4))")
                }
                if let offset = l.shot.videoOffset {
                    let release = r.outcome.release.time
                    if abs(offset - max(0, release)) > 1e-6 {
                        problems.append("release: live videoOffset \(f(offset, 3)) s, replay \(f(release, 3)) s")
                    }
                } else {
                    problems.append("live call has no videoOffset (recorder didn't start)")
                }
                rows.append(CallPair(index: rows.count, liveIndex: i, replayIndex: j, live: l, replay: r, problems: problems))
                i += 1
                j += 1
            } else if let l, let a = liveKey, replayKey.map({ a < $0 }) ?? true {
                problems.append(l.atEnd
                    ? "live-only: CVPipeline.stop() handed it back at the end; the replay flushed nothing"
                    : "live-only: replay published no call on that frame (\(f(a, 3)) s log time)")
                rows.append(CallPair(index: rows.count, liveIndex: i, replayIndex: nil, live: l, replay: nil, problems: problems))
                i += 1
            } else if let r {
                if r.publishedAt == nil {
                    problems.append("replay-only: held by the net check when the log ended and flushed; "
                                    + "CVPipeline.stop() handed nothing back")
                } else {
                    problems.append("replay-only: the delegate got no call on that frame (\(f(r.publishedAt ?? 0, 3)) s log time)")
                }
                rows.append(CallPair(index: rows.count, liveIndex: nil, replayIndex: j, live: nil, replay: r, problems: problems))
                j += 1
            }
        }
        return rows
    }

    // MARK: - shot-eval

    private static func runShotEval(options: Options, logZero: Double,
                                    labels: [ShotEvaluation.Label]?, rewrite: Bool) -> (ShotEvalRun?, String?) {
        let binary = options.shotEval
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("shot-eval")
        guard let binary, FileManager.default.isExecutableFile(atPath: binary.path) else {
            return (nil, "shot-eval binary not found next to cv-replay (swift build --product shot-eval)")
        }
        var arguments = [options.out.appendingPathComponent("detections.jsonl").path]
        var shifted: URL?
        if let url = options.labels, let labels {
            if abs(logZero) < 1e-9 && !rewrite {
                arguments.append(url.path)
            } else {
                // Labels are in video seconds, the log in seconds from its
                // first frame: shift them (and drop any outside the span).
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cv-replay-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("labels-in-log-time.csv")
                let text = labels.map { "\($0.time - logZero),\($0.result == .make ? "make" : "miss")" }
                    .joined(separator: "\n")
                try? text.write(to: file, atomically: true, encoding: .utf8)
                arguments.append(file.path)
                shifted = file
            }
        }
        defer { if let shifted { try? FileManager.default.removeItem(at: shifted.deletingLastPathComponent()) } }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (nil, "couldn't run shot-eval: \(error.localizedDescription)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)

        // "  1     4.03s  make  0.95  (check)"
        var calls: [ShotEvalRun.Line] = []
        for line in output.split(separator: "\n") {
            let tokens = line.split(separator: " ")
            guard tokens.count >= 4, Int(tokens[0]) != nil, tokens[1].hasSuffix("s"),
                  let time = Double(tokens[1].dropLast()),
                  tokens[2] == "make" || tokens[2] == "miss",
                  let confidence = Double(tokens[3]) else { continue }
            calls.append(.init(time: time, result: tokens[2] == "make" ? .make : .miss,
                               confidence: confidence, flagged: tokens.count > 4 && tokens[4] == "(check)"))
        }
        let command = ([binary.lastPathComponent] + arguments.map { URL(fileURLWithPath: $0).lastPathComponent })
            .joined(separator: " ")
        guard process.terminationStatus == 0 else {
            return (ShotEvalRun(command: command, output: output, calls: calls),
                    "shot-eval exited with status \(process.terminationStatus)")
        }
        return (ShotEvalRun(command: command, output: output, calls: calls), nil)
    }

    // MARK: - Verdicts

    var mirrorAgrees: Bool { trace.calls.map(\.replayCall) == replayCalls }

    /// shot-eval's printed calls vs ShotReplay.run, at shot-eval's precision.
    var shotEvalAgrees: Bool? {
        guard let shotEval else { return nil }
        guard shotEval.calls.count == replayCalls.count else { return false }
        return zip(shotEval.calls, replayCalls).allSatisfy { printed, call in
            f(printed.time, 2) == f(call.time, 2) && printed.result == call.result
                && f(printed.confidence, 2) == f(call.confidence, 2)
        }
    }

    var liveMatchesReplay: Bool { pairs.allSatisfy(\.matches) }

    var fidelityMatches: Bool { liveMatchesReplay && mirrorAgrees && (shotEvalAgrees ?? true) }

    /// Each live call's time for scoring: when the ball reached the rim
    /// (from its replay twin), in video seconds; the publish time if it has
    /// no twin.
    var liveCallsForScoring: [ShotReplay.Call] {
        pairs.compactMap { pair in
            guard let l = pair.live else { return nil }
            let time = pair.replay.map { $0.time + live.logZero } ?? live.video(l.pts)
            return ShotReplay.Call(time: time, result: l.shot.result, confidence: l.shot.confidence)
        }
    }

    // MARK: - Writing

    func write(to out: URL) throws {
        try shotsCSV().write(to: out.appendingPathComponent("shots.csv"), atomically: true, encoding: .utf8)
        try fidelityText().write(to: out.appendingPathComponent("fidelity.txt"), atomically: true, encoding: .utf8)
        if let shotEval {
            try ("$ " + shotEval.command + "\n" + shotEval.output)
                .write(to: out.appendingPathComponent("shot-eval.txt"), atomically: true, encoding: .utf8)
        }
        try summaryText().write(to: out.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
    }

    /// One row per call the delegate received, in order.
    func shotsCSV() -> String {
        var rows = ["shot,time_s,published_s,video_offset_s,result,confidence,flagged,zone,court_x,court_y,"
                    + "distance_ft,release_angle_deg,shot_speed_mph,release_s,matches_replay"]
        for pair in pairs {
            guard let l = pair.live else { continue }
            let shot = l.shot
            let rim = pair.replay.map { f($0.time + live.logZero, 3) } ?? ""
            let release = pair.replay.map { f($0.outcome.release.time + live.logZero, 3) } ?? ""
            rows.append([
                String((pair.liveIndex ?? pair.index) + 1), rim, f(live.video(l.pts), 3),
                shot.videoOffset.map { f($0, 3) } ?? "",
                name(shot.result), f(shot.confidence, 4),
                shot.confidence < HoopTrack.CV.lowConfidence ? "yes" : "no",
                shot.zone.rawValue, f(shot.courtX, 4), f(shot.courtY, 4),
                shot.distanceFt.map { f($0, 2) } ?? "",
                shot.science?.releaseAngleDeg.map { f($0, 1) } ?? "",
                shot.science?.shotSpeedMph.map { f($0, 1) } ?? "",
                release, pair.matches ? "yes" : "no",
            ].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    func fidelityText() -> String {
        var lines: [String] = []
        lines.append("Fidelity: calls the live delegate received vs shot-eval on the detections.jsonl this run wrote")
        lines.append("Times are log seconds (0 = the session video's first frame = \(f(live.logZero, 3)) s into the file)."
                     + (live.ptsOffset != 0 ? " Frames were fed with PTS = video seconds + \(f(live.ptsOffset, 3))." : ""))
        lines.append("")
        lines.append("Verdict: " + (fidelityMatches ? "MATCH" : "MISMATCH"))
        lines.append("  live delegate vs replay: \(pairs.filter(\.matches).count)/\(pairs.count) calls match "
                     + "(live \(live.shots.count), replay \(trace.calls.count))")
        if let agrees = shotEvalAgrees, let shotEval {
            lines.append("  shot-eval vs ShotReplay.run in process: " + (agrees ? "identical" : "DIFFERENT")
                         + " (\(shotEval.calls.count) vs \(replayCalls.count) calls)")
        } else {
            lines.append("  shot-eval: not run (\(shotEvalNote ?? "?"))")
        }
        if let shotEvalNote, shotEval != nil { lines.append("  shot-eval: \(shotEvalNote)") }
        lines.append("  harness replay trace vs ShotReplay.run: " + (mirrorAgrees ? "identical" : "DIFFERENT (harness bug)"))
        lines.append("")

        lines.append(" #  | live delegate: published  release  result  conf   | replay: published  release  rim     result  conf   | shot-eval: rim    result  conf | ")
        for pair in pairs {
            var row = String(format: "%2d  | ", pair.index + 1)
            if let l = pair.live {
                row += "\(pad(l.atEnd ? "end" : f(l.pts - live.sessionStart, 3), 9))  \(pad(l.shot.videoOffset.map { f($0, 3) } ?? "-", 7))  "
                    + "\(pad(name(l.shot.result), 6))  \(f(l.shot.confidence, 3))  | "
            } else {
                row += String(repeating: " ", count: 39) + "-  | "
            }
            if let r = pair.replay {
                row += "\(pad(r.publishedAt.map { f($0, 3) } ?? "end", 9))  \(pad(f(r.outcome.release.time, 3), 7))  "
                    + "\(pad(f(r.time, 3), 6))  \(pad(name(r.result), 6))  \(f(r.confidence, 3))  | "
            } else {
                row += String(repeating: " ", count: 46) + "-  | "
            }
            if let shotEval, let k = pair.replayIndex, k < shotEval.calls.count {
                let s = shotEval.calls[k]
                row += "\(pad(f(s.time, 2), 6))  \(pad(name(s.result), 6))  \(f(s.confidence, 2))  | "
            } else {
                row += "                           -  | "
            }
            row += pair.matches ? "match" : pair.problems.joined(separator: "; ")
            lines.append(row)
        }
        if pairs.isEmpty { lines.append("    (no calls on either side)") }
        lines.append("")

        // Shot starts.
        let loggedStarts = entries.filter { $0.event == "start" }.count
        let replayStarts = trace.frames.filter { if case .started? = $0.event { return true } else { return false } }.count
        let startTimesLive = live.starts.map { $0.pts - live.sessionStart }
        let startTimesReplay = trace.frames.filter { if case .started? = $0.event { return true } else { return false } }.map(\.t)
        let startsAligned = startTimesLive.count == startTimesReplay.count
            && zip(startTimesLive, startTimesReplay).allSatisfy { abs($0 - $1) <= 1e-6 }
        lines.append("Shot starts: live delegate \(live.starts.count), logged \(loggedStarts), replay \(replayStarts)"
                     + (startsAligned ? " — same frames" : " — DIFFERENT frames"))

        // Hoop state, frame by frame.
        var differing = 0
        var firstDiff: Double?
        var unmapped = 0
        for (i, frame) in trace.frames.enumerated() {
            guard i < entryFed.count, let k = entryFed[i] else { unmapped += 1; continue }
            if liveHoopKind[k] != frame.hoopKind {
                differing += 1
                if firstDiff == nil { firstDiff = frame.t }
            }
        }
        let multiHoop = live.probe.filter { $0.baskets.count >= 2 }.count
        lines.append("Hoop state (looking/tracking/lost) per frame, live vs replay: "
                     + (differing == 0 ? "identical" : "\(differing) frames differ, first at \(f(firstDiff ?? 0, 3)) s")
                     + (unmapped > 0 ? " (\(unmapped) log lines not matched to a fed frame)" : ""))
        lines.append("Frames where the detector returned 2+ hoops: \(multiHoop) "
                     + (entries.contains { $0.baskets != nil }
                        ? "(all are logged, so the replay chooses among them as the app did)"
                        : "(this log keeps only the most confident, so the replay can pick a different hoop there)"))
        let checked = entries.filter { $0.checkedEvent != nil }.count
        lines.append("Log lines with a published call (cv): \(checked) (one per frame; a frame publishing two calls logs the last)")
        lines.append("")
        lines.append("Tolerances: confidence 1e-9, publish frame and release time 1e-6 s (they come from the same frame PTS).")
        return lines.joined(separator: "\n") + "\n"
    }

    func summaryText() -> String {
        let info = live.info
        let converter = live.converter
        var lines: [String] = []
        lines.append("cv-replay — \(options.video.path)")
        lines.append("")
        lines.append("Video:     \(Int(info.naturalSize.width))x\(Int(info.naturalSize.height)) \(info.codec), "
                     + "\(info.orientation), \(f(info.nominalFPS, 2)) fps, \(f(info.duration, 1)) s")
        let content = converter.contentRect
        let fitting: String
        if converter.passesThrough {
            fitting = "passed through as decoded"
        } else if options.fit == .letterbox {
            fitting = "upright \(converter.uprightSize.width)x\(converter.uprightSize.height) scaled ×\(f(converter.scale, 3)), "
                + "picture at \(Int(content.minX)),\(Int(content.minY)) \(Int(content.width))x\(Int(content.height))"
                + (content.width < 1280 || content.height < 720 ? " (black bars)" : "")
        } else {
            fitting = "upright \(converter.uprightSize.width)x\(converter.uprightSize.height) scaled ×\(f(converter.scale, 3)) and centre-cropped"
        }
        lines.append("Frames in: 1280x720 420f (the app's capture format); \(fitting)")
        let first = live.video(live.fedPTS.first ?? 0), last = live.video(live.fedPTS.last ?? 0)
        lines.append("Range:     \(f(first, 2))–\(f(last, 2)) s of the file; "
                     + (options.stride == 1 ? "every frame" : "every \(options.stride)th frame")
                     + (live.ptsOffset != 0 ? "; fed with PTS + \(f(live.ptsOffset, 3)) s (camera-clock emulation)" : ""))
        lines.append("Pipeline:  CVPipeline + CoreMLBallDetector (\(options.model.lastPathComponent), all compute units), "
                     + "SessionRecorder + DetectionLogger; FOV \(f(options.fieldOfView, 1))°, "
                     + "\(options.court.displayName) three-point line")
        lines.append("")

        let logged = entries.count
        lines.append("Frames:    \(live.decoded) decoded, \(live.fedPTS.count) fed, \(logged) logged"
                     + (live.fedPTS.count != logged ? " — \(live.fedPTS.count - logged) NOT PROCESSED (thermal load shedding)" : ""))
        let fps = Double(live.fedPTS.count) / max(live.wallSeconds, 1e-9)
        let inference = live.probe.map(\.inferenceMs)
        lines.append("Speed:     \(f(fps, 1)) frames/s (\(f(live.wallSeconds, 1)) s wall, model load \(f(live.modelSeconds, 1)) s); "
                     + "detector \(f(mean(inference), 1)) ms mean, \(f(percentile(inference, 0.95), 1)) ms p95")
        lines.append("Thermal:   \(Thermal.name(live.thermalStart)) → \(Thermal.name(live.thermalEnd)) "
                     + "(hottest \(Thermal.name(live.thermalMax)))"
                     + (live.thermalMax.rawValue >= HoopTrack.CV.throttleAtThermalState
                        ? " — the pipeline sheds alternate frames at this level" : ""))
        lines.append("")

        let mapped = entryFed.compactMap { $0 }
        let tracked = mapped.filter { liveHoopKind[$0] == 1 }.count
        let trackedOrLost = mapped.filter { liveHoopKind[$0] >= 1 }.count
        let rawRim = entries.filter { $0.rimBox != nil }.count
        let multiHoop = live.probe.filter { $0.baskets.count >= 2 }.count
        lines.append("Hoop:      tracked in \(pct(tracked, logged)) of frames (tracked or briefly lost \(pct(trackedOrLost, logged))); "
                     + "detector rim box in \(pct(rawRim, logged)); 2+ hoops in \(multiHoop) frames")

        let ballLists = entries.map(Self.balls)
        let withBall = ballLists.filter { !$0.isEmpty }.count
        let candidates = ballLists.reduce(0) { $0 + $1.count }
        let cropped = entries.filter { $0.region != nil }.count
        lines.append("Ball:      ≥1 ball in \(pct(withBall, logged)) of frames (\(f(Double(candidates) / Double(max(logged, 1)), 2)) candidates/frame); "
                     + "detection crop on \(pct(cropped, logged)) of frames")
        let sides = ballLists.flatMap { $0 }.map { Self.pixelSides($0) }
        let shotBallSides = trace.frames.compactMap(\.shotBall).map { Self.pixelSides($0) }
        lines.append("Ball box size, px in the 1280x720 frame (shorter side / longer side):")
        lines.append("  all candidates      " + distribution(sides.map(\.short)) + "  |  longer: median \(f(percentile(sides.map(\.long), 0.5), 1))")
        lines.append("  shot ball, tracked  " + distribution(shotBallSides.map(\.short)) + "  |  longer: median \(f(percentile(shotBallSides.map(\.long), 0.5), 1))")
        lines.append("  shorter side histogram: " + histogram(sides.map(\.short)))
        if !converter.passesThrough {
            lines.append("  (source-video px = these ÷ \(f(converter.scale, 3)))")
        }
        lines.append("")

        let makes = live.shots.filter { $0.shot.result == .make }.count
        let flagged = live.shots.filter { $0.shot.confidence < HoopTrack.CV.lowConfidence }.count
        lines.append("Shots:     \(live.starts.count) started, \(live.shots.count) called "
                     + "(\(makes) make, \(live.shots.count - makes) miss, \(flagged) flagged for review)")
        if !live.shots.isEmpty {
            lines.append("    #   rim s     published s  result  conf   flag   zone            court x,y      dist ft  angle")
            for pair in pairs {
                guard let l = pair.live else { continue }
                let s = l.shot
                lines.append("   \(pad(String((pair.liveIndex ?? pair.index) + 1), 2))   \(pad(pair.replay.map { f($0.time + live.logZero, 2) } ?? "?", 7))   "
                             + "\(pad(f(live.video(l.pts), 2), 11))  \(pad(name(s.result), 6))  \(f(s.confidence, 2))   "
                             + "\(s.confidence < HoopTrack.CV.lowConfidence ? "check" : "     ")  "
                             + "\(pad(s.zone.displayName, 14, left: true))  \(f(s.courtX, 2)),\(f(s.courtY, 2))     "
                             + "\(pad(s.distanceFt.map { f($0, 1) } ?? "-", 6))   "
                             + (s.science?.releaseAngleDeg.map { f($0, 0) + "°" } ?? "-"))
            }
        }
        lines.append("")
        lines.append("Fidelity:  " + (fidelityMatches
            ? "MATCH — shot-eval on detections.jsonl makes the same \(replayCalls.count) calls the delegate received "
              + "(same frames, release times, results, confidences)"
            : "MISMATCH — live \(live.shots.count) calls, shot-eval \(shotEval?.calls.count ?? replayCalls.count); see fidelity.txt"))
        for pair in pairs where !pair.matches {
            lines.append("           row \(pair.index + 1) of fidelity.txt: " + pair.problems.joined(separator: "; "))
        }
        if let shotEvalNote { lines.append("           \(shotEvalNote)") }

        if let labels {
            lines.append("")
            lines.append("Score (\(options.labels?.lastPathComponent ?? "labels"), \(labels.count) shots"
                         + (labelsOutside > 0 ? " in the processed span, \(labelsOutside) outside it ignored" : "")
                         + "; live calls, timed at the rim):")
            let report = ShotEvaluation.score(calls: liveCallsForScoring, labels: labels)
            lines += report.summary.split(separator: "\n").map { "  " + $0 }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Helpers

    static func balls(_ entry: DetectionLogEntry) -> [CGRect] {
        if let list = entry.balls {
            return list.compactMap { $0.count >= 4 && $0[2] > 0 && $0[3] > 0
                ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        }
        if let b = entry.ballBox, b.count >= 4 { return [CGRect(x: b[0], y: b[1], width: b[2], height: b[3])] }
        return []
    }

    static func pixelSides(_ box: CGRect) -> (short: Double, long: Double) {
        let w = Double(box.width) * 1280, h = Double(box.height) * 720
        return (min(w, h), max(w, h))
    }

    private func distribution(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "(none)" }
        let p = { (q: Double) in f(percentile(values, q), 1) }
        return "n=\(values.count): min \(p(0)), p10 \(p(0.1)), p25 \(p(0.25)), median \(p(0.5)), p75 \(p(0.75)), p90 \(p(0.9)), max \(p(1))"
    }

    private func histogram(_ values: [Double]) -> String {
        let edges: [Double] = [6, 10, 14, 20, 30, 45]
        var counts = [Int](repeating: 0, count: edges.count + 1)
        for v in values { counts[edges.firstIndex { v < $0 } ?? edges.count] += 1 }
        var parts: [String] = ["<6: \(counts[0])"]
        for i in 1..<edges.count { parts.append("\(Int(edges[i - 1]))–\(Int(edges[i])): \(counts[i])") }
        parts.append("≥45: \(counts[edges.count])")
        return parts.joined(separator: "  ")
    }
}

// MARK: - Formatting

func f(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }

func pad(_ text: String, _ width: Int, left: Bool = false) -> String {
    guard text.count < width else { return text }
    let fill = String(repeating: " ", count: width - text.count)
    return left ? text + fill : fill + text
}

func pct(_ part: Int, _ whole: Int) -> String {
    whole > 0 ? f(100 * Double(part) / Double(whole), 1) + "%" : "-"
}

func name(_ result: ShotResult) -> String {
    switch result {
    case .make:    return "make"
    case .miss:    return "miss"
    case .pending: return "pending"
    }
}

func mean(_ values: [Double]) -> Double {
    values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
}

func percentile(_ values: [Double], _ q: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))]
}

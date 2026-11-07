// Options.swift — cv-replay's command line.

import Foundation
@testable import HoopTrack

struct Options {
    var video: URL
    var out: URL
    var labels: URL?
    var stride = 1
    var start: Double?
    var duration: Double?
    var fit = FitMode.letterbox
    var fieldOfView = CourtPositionEstimator.defaultHorizontalFOV
    var court = CourtType.nba
    var model: URL
    var strips = true
    var keepVideo = false
    var shotEval: URL?
    var quiet = false
    var ptsOffset = 0.0
    /// --frame-cost-ms, in seconds: late frames are dropped as on the phone.
    var frameCost: Double?
    /// --pause, video seconds.
    var pauses: [ClosedRange<Double>] = []

    static let usage = """
    usage: cv-replay <video> [options]

    Runs the app's shot-recognition pipeline (CVPipeline + CoreMLBallDetector +
    CourtCalibrationService + ShotTracker + NetWatch/NetCheck) on a video file,
    frame by frame, and writes what the app would have logged and called.

      --out DIR          output directory (default ./cv-replay-out/<clip name>)
      --labels FILE      labels.csv, `seconds,make|miss` per shot at the rim
                         (video seconds); scores the calls with ShotEvaluation
      --stride N         feed every Nth frame (default 1 = every frame)
      --start S          start S seconds into the video
      --duration S       process at most S seconds
      --fit MODE         letterbox (default) or crop: how a video that isn't
                         16:9 is fitted into the app's 1280x720 frame
      --fov DEG          camera horizontal field of view, for court position
                         (default \(CourtPositionEstimator.defaultHorizontalFOV), the app's fallback)
      --court C          nba (default), ncaa, fiba or hs: three-point distance
      --model PATH       BallDetector.mlmodel / .mlpackage / compiled .mlmodelc
                         (default: the app's ML/BallDetector.mlmodel)
      --no-strips        don't draw the annotated PNG strips
      --keep-video       keep the HEVC video SessionRecorder wrote (session.mov)
      --shot-eval PATH   shot-eval binary for the log-replay consistency check
                         (default: next to this executable)
      --pts-offset S     add S seconds to every frame's timestamp before the
                         pipeline sees it, like the camera's host-clock PTS
                         (e.g. 250000); outputs stay in video seconds
      --frame-cost-ms N  drop late frames as the phone's camera does
                         (alwaysDiscardsLateVideoFrames): a frame that arrives
                         while the previous one would still be in process()
                         — N ms each, a phone figure — is skipped and counted
      --pause A-B[,C-D]  pause the session from A to B s of the video (the
                         pause button: CVPipeline.isPaused), e.g. 30-45,90-95
      --quiet            no progress line
    """

    static func parse(_ arguments: [String]) throws -> Options {
        var args = arguments[...]
        var video: URL?
        var out: URL?
        var options = Options(video: URL(fileURLWithPath: "/"), out: URL(fileURLWithPath: "/"),
                              model: defaultModel)

        func value(_ flag: String) throws -> String {
            guard let next = args.popFirst() else { throw OptionsError("\(flag) needs a value") }
            return next
        }
        func number(_ flag: String) throws -> Double {
            let text = try value(flag)
            guard let n = Double(text), n.isFinite else { throw OptionsError("\(flag): not a number: \(text)") }
            return n
        }

        while let arg = args.popFirst() {
            switch arg {
            case "-h", "--help":
                throw OptionsError(nil)
            case "--out":        out = URL(fileURLWithPath: try value(arg))
            case "--labels":     options.labels = URL(fileURLWithPath: try value(arg))
            case "--stride":
                let n = try number(arg)
                guard n >= 1, n == n.rounded() else { throw OptionsError("--stride must be a whole number ≥ 1") }
                options.stride = Int(n)
            case "--start":      options.start = try number(arg)
            case "--duration":   options.duration = try number(arg)
            case "--fit":
                guard let fit = FitMode(rawValue: try value(arg)) else { throw OptionsError("--fit is letterbox or crop") }
                options.fit = fit
            case "--fov":
                options.fieldOfView = try number(arg)
                guard options.fieldOfView > 10, options.fieldOfView < 170 else { throw OptionsError("--fov out of range") }
            case "--court":
                switch try value(arg).lowercased() {
                case "nba":         options.court = .nba
                case "ncaa":        options.court = .ncaa
                case "fiba":        options.court = .fiba
                case "hs", "half":  options.court = .halfCourt
                default:            throw OptionsError("--court is nba, ncaa, fiba or hs")
                }
            case "--model":      options.model = URL(fileURLWithPath: try value(arg))
            case "--no-strips":  options.strips = false
            case "--keep-video": options.keepVideo = true
            case "--shot-eval":  options.shotEval = URL(fileURLWithPath: try value(arg))
            case "--quiet":      options.quiet = true
            case "--pts-offset":
                options.ptsOffset = try number(arg)
                guard options.ptsOffset >= 0 else { throw OptionsError("--pts-offset must be ≥ 0") }
            case "--frame-cost-ms":
                let ms = try number(arg)
                guard ms > 0, ms < 1000 else { throw OptionsError("--frame-cost-ms must be between 0 and 1000") }
                options.frameCost = ms / 1000
            case "--pause":
                options.pauses += try Self.pauses(try value(arg))
            default:
                guard !arg.hasPrefix("-"), video == nil else { throw OptionsError("unknown option \(arg)") }
                video = URL(fileURLWithPath: arg)
            }
        }
        guard let video else { throw OptionsError("no video given") }
        options.video = video.standardizedFileURL
        let clip = video.deletingPathExtension().lastPathComponent
        options.out = (out ?? URL(fileURLWithPath: "cv-replay-out").appendingPathComponent(clip)).standardizedFileURL
        if let start = options.start, start < 0 { throw OptionsError("--start must be ≥ 0") }
        if let duration = options.duration, duration <= 0 { throw OptionsError("--duration must be > 0") }
        return options
    }

    /// "30-45,90.5-95" → [30...45, 90.5...95].
    static func pauses(_ text: String) throws -> [ClosedRange<Double>] {
        try text.split(separator: ",").map { part in
            let ends = part.split(separator: "-", maxSplits: 1).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard ends.count == 2, let a = ends[0], let b = ends[1], a >= 0, b > a else {
                throw OptionsError("--pause wants A-B[,C-D] with 0 ≤ A < B, got \(part)")
            }
            return a...b
        }
    }

    /// The app's model, found from this source file's place in the repo:
    /// Tools/HoopTrackCore/Sources/cv-replay → HoopTrack/HoopTrack/ML.
    static var defaultModel: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // cv-replay
            .deletingLastPathComponent()      // Sources
            .deletingLastPathComponent()      // HoopTrackCore
            .deletingLastPathComponent()      // Tools
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("HoopTrack/HoopTrack/ML")
            .appendingPathComponent(HoopTrack.MLModel.bundledModelName + ".mlmodel")
    }

    /// Seconds of video asked for, as a reader time range.
    var timeRange: ClosedRange<Double>? {
        guard start != nil || duration != nil else { return nil }
        let from = start ?? 0
        return from...(duration.map { from + $0 } ?? Double(Int32.max))
    }
}

struct OptionsError: Error {
    let message: String?
    init(_ message: String?) { self.message = message }
}

// cv-replay — runs the shipped shot-recognition pipeline on a video file.
//
//   swift build && .build/debug/cv-replay clip.mp4 --labels labels.csv --out out/
//
// The pipeline is built exactly as LiveSessionViewModel.startTracking
// builds it — CVPipeline(detector:threePointDistanceFt:fieldOfView:) with
// CoreMLBallDetector on the bundled model (all compute units), a
// SessionRecorder, a DetectionLogger via attachTelemetry, then
// start(framePublisher:delegate:) — and the video's frames are pushed
// through a PassthroughSubject on a serial "session queue", one at a time,
// the way CameraService's capture delegate does. After every frame the
// session queue waits for the main queue, so the delegate's main-actor
// hops (Task { @MainActor … }) for that frame have run before the next
// frame is fed: each call can be pinned to its frame. At the end, stop()
// hands back what the delegate hasn't been given (a call still waiting for
// the net check) and it's recorded, as LiveSessionViewModel.end() does.
//
// Writes, to the output directory: detections.jsonl (the app's telemetry
// log), shots.csv, summary.txt, consistency.txt (live calls vs shot-eval on
// that log), shot-eval.txt, strips/*.png. See Tools/cv/README.md.
//
// Debug build (the default): @testable needs it, as for shot-eval. Core ML
// runs in the system frameworks, so it's at full speed regardless.

import AVFoundation
@preconcurrency import Combine
import CoreML
import Foundation
@testable import HoopTrack

@main
struct CVReplay {
    @MainActor
    static func main() async {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch let error as OptionsError {
            if let message = error.message { FileHandle.standardError.write(Data("cv-replay: \(message)\n\n".utf8)) }
            print(Options.usage)
            exit(error.message == nil ? 0 : 2)
        } catch {
            exit(2)
        }
        do {
            try await Runner(options: options).run()
        } catch {
            FileHandle.standardError.write(Data("cv-replay: \(error)\n".utf8))
            exit(1)
        }
    }
}

enum Thermal {
    static func hotter(_ a: ProcessInfo.ThermalState, _ b: ProcessInfo.ThermalState) -> ProcessInfo.ThermalState {
        a.rawValue >= b.rawValue ? a : b
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

struct RunnerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Everything the live run produced, for the reports.
struct LiveRun {
    let info: VideoInfo
    let converter: FrameConverter
    /// PTS (video seconds) of every frame fed to the pipeline, in order.
    let fedPTS: [Double]
    let decoded: Int
    let wallSeconds: Double
    let modelSeconds: Double
    /// recorder.startTime: log time 0 in video seconds.
    let sessionStart: Double
    /// --pts-offset: PTS = video seconds + this.
    let ptsOffset: Double
    let shots: [RecordingDelegate.Shot]
    let starts: [(frame: Int, pts: Double)]
    let hoopChanges: [RecordingDelegate.HoopChange]
    let probe: [DetectorProbe.FrameStat]
    let thermalStart: ProcessInfo.ThermalState
    let thermalMax: ProcessInfo.ThermalState
    let thermalEnd: ProcessInfo.ThermalState
    let recordedVideo: URL?
    /// PTS of every decoded frame (before --stride / --frame-cost-ms).
    let decodedPTS: [Double]
    /// Wall time of the whole of process() for each fed frame, ms.
    let processMs: [Double]
    /// Frames --frame-cost-ms dropped as late, and the cost it used (s).
    let lateDropped: Int
    let frameCost: Double?
    /// Fed frames the pipeline saw paused (--pause).
    let pausedFed: Int
    /// Each --pause as applied: first to last paused frame, in log seconds
    /// (what ShotReplay.run needs to model it).
    let pauses: [ClosedRange<Double>]
    let environment: RunEnvironment

    /// Video seconds of log time 0.
    var logZero: Double { sessionStart - ptsOffset }
    /// Video seconds of a PTS.
    func video(_ pts: Double) -> Double { pts - ptsOffset }
}

@MainActor
final class Runner {

    let options: Options
    private let fileManager = FileManager.default

    init(options: Options) {
        self.options = options
    }

    deinit {}

    func run() async throws {
        guard fileManager.isReadableFile(atPath: options.video.path) else {
            throw RunnerError("can't read video \(options.video.path)")
        }
        let out = options.out
        try fileManager.createDirectory(at: out, withIntermediateDirectories: true)
        for stale in ["detections.jsonl", "shots.csv", "summary.txt", "consistency.txt", "fidelity.txt",
                      "shot-eval.txt", "session.mov", "strips"] {
            try? fileManager.removeItem(at: out.appendingPathComponent(stale))
        }

        // DetectionLogger and SessionRecorder write under the user's
        // Documents folder, as on the phone. Point "home" at a scratch
        // folder in the output directory first (CoreFoundation reads
        // CFFIXED_USER_HOME when the home directory is first asked for), so
        // nothing lands in the Mac's ~/Documents; the files are moved out
        // afterwards and the scratch folder deleted.
        let scratchHome = out.appendingPathComponent(".home-\(UUID().uuidString.prefix(8))")
        try fileManager.createDirectory(at: scratchHome, withIntermediateDirectories: true)
        setenv("CFFIXED_USER_HOME", scratchHome.path, 1)
        defer { try? fileManager.removeItem(at: scratchHome) }

        let live = try await runLive(scratchHome: scratchHome)

        let logURL = out.appendingPathComponent("detections.jsonl")
        let text = try String(contentsOf: logURL, encoding: .utf8)
        let entries = ShotReplay.entries(fromJSONL: text)
        let report = Report(options: options, live: live, entries: entries)
        try report.write(to: out)
        if options.strips {
            try await StripWriter(options: options, live: live, report: report).write(to: out.appendingPathComponent("strips"))
        }
        print(try String(contentsOf: out.appendingPathComponent("summary.txt"), encoding: .utf8))
    }

    // MARK: - The live pipeline

    private func runLive(scratchHome: URL) async throws -> LiveRun {
        let modelStart = Date()
        let compiled = try await compiledModel()
        defer { if compiled.isTemporary { try? fileManager.removeItem(at: compiled.url) } }
        guard let coreML = CoreMLBallDetector(modelURL: compiled.url) else {
            throw RunnerError("CoreMLBallDetector couldn't load \(compiled.url.path)")
        }
        let modelSeconds = Date().timeIntervalSince(modelStart)
        let probe = DetectorProbe(wrapping: coreML)
        let environment = await RunEnvironment.current(model: compiled.url)

        let source = try await VideoFrames(url: options.video, fit: options.fit, timeRange: options.timeRange,
                                       ptsOffset: options.ptsOffset)
        if !options.quiet {
            let info = source.info
            log("video: \(Int(info.naturalSize.width))x\(Int(info.naturalSize.height)) \(info.codec), "
                + "\(info.orientation), \(String(format: "%.2f", info.nominalFPS)) fps, "
                + "\(String(format: "%.1f", info.duration)) s; model loaded in \(String(format: "%.1f", modelSeconds)) s")
        }

        // As LiveSessionViewModel.startTracking.
        let fov = options.fieldOfView
        let pipeline = CVPipeline(detector: probe,
                                  threePointDistanceFt: options.court.threePointDistanceFt,
                                  fieldOfView: { fov })
        let sessionID = UUID()
        let documents = scratchHome.appendingPathComponent("Documents")
        let logDirectory = documents.appendingPathComponent(HoopTrack.Telemetry.telemetryDirectoryName)
            .appendingPathComponent(sessionID.uuidString)
        // DetectionLogger and SessionRecorder create their folders with
        // FileProtectionType.complete, as on the phone. On a Mac whose screen
        // is locked (the usual case over ssh) nothing can be created inside
        // such a folder: the logger's file never appears and the recorder
        // fails. Make the folders first, unprotected; creating an existing
        // folder leaves it as it is, and the files inside then open fine.
        for folder in [logDirectory, documents.appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let recorder = SessionRecorder(sessionID: sessionID)
        pipeline.recorder = recorder
        pipeline.publishesBall = false        // the developer overlay is off by default
        pipeline.isPaused = false
        let logger = try DetectionLogger(sessionID: sessionID)
        pipeline.attachTelemetry(logger: logger)

        let logFile = logDirectory.appendingPathComponent("detections.jsonl")
        guard fileManager.fileExists(atPath: logFile.path) else {
            throw RunnerError("DetectionLogger didn't write under the scratch home (\(logFile.path)); "
                              + "was the home directory read before CFFIXED_USER_HOME was set?")
        }

        let clock = FrameClock()
        let delegate = RecordingDelegate(clock: clock)
        let frames = PassthroughSubject<CMSampleBuffer, Never>()
        pipeline.start(framePublisher: frames.eraseToAnyPublisher(), delegate: delegate)

        let stride = options.stride
        let ptsOffset = options.ptsOffset
        let quiet = options.quiet
        let frameCost = options.frameCost
        let pauses = options.pauses
        let estimate = Int(source.info.nominalFPS * min(source.info.duration, options.duration ?? .infinity))
        let sessionQueue = DispatchQueue(label: "cv-replay.session", qos: .userInitiated)
        let thermalStart = ProcessInfo.processInfo.thermalState
        let started = Date()

        struct Fed {
            var pts: [Double] = []
            var decoded = 0
            var decodedPTS: [Double] = []
            var processMs: [Double] = []
            var late = 0
            var paused = 0
            /// First and last paused PTS of each pause, by --pause index.
            var pauseRuns: [Int: (first: Double, last: Double)] = [:]
            var thermalMax = ProcessInfo.ThermalState.nominal
        }
        let fed: Fed
        do {
            fed = try await withCheckedThrowingContinuation { continuation in
                sessionQueue.async {
                    var fed = Fed()
                    var lastProgress = Date()
                    var busyUntil = -Double.infinity
                    do {
                        while let frame = try source.next() {
                            fed.decoded += 1
                            fed.decodedPTS.append(frame.seconds)
                            guard frame.index % stride == 0 else { continue }
                            // --frame-cost-ms: the phone's camera discards a frame
                            // that arrives while the previous one is still being
                            // processed (alwaysDiscardsLateVideoFrames; CVPipeline
                            // works synchronously on the delivery queue).
                            if let frameCost {
                                if frame.seconds < busyUntil { fed.late += 1; continue }
                                busyUntil = frame.seconds + frameCost
                            }
                            // --pause: the pause button sets isPaused between frames.
                            let pause = pauses.firstIndex { $0.contains(frame.seconds - ptsOffset) }
                            pipeline.isPaused = pause != nil
                            if let pause {
                                fed.paused += 1
                                fed.pauseRuns[pause] = (fed.pauseRuns[pause]?.first ?? frame.seconds, frame.seconds)
                            }
                            clock.set(index: fed.pts.count, pts: frame.seconds)
                            let begin = DispatchTime.now().uptimeNanoseconds
                            frames.send(frame.sampleBuffer)      // the whole of process(), synchronously
                            fed.processMs.append(Double(DispatchTime.now().uptimeNanoseconds - begin) / 1e6)
                            // Let this frame's main-actor hops run before the next frame.
                            DispatchQueue.main.sync {}
                            fed.pts.append(frame.seconds)
                            if fed.pts.count % 30 == 0 {
                                fed.thermalMax = Thermal.hotter(fed.thermalMax, ProcessInfo.processInfo.thermalState)
                                if !quiet, Date().timeIntervalSince(lastProgress) > 2 {
                                    lastProgress = Date()
                                    let rate = Double(fed.pts.count) / Date().timeIntervalSince(started)
                                    FileHandle.standardError.write(Data(String(
                                        format: "\r  frame %d/~%d  %.1f s  %.1f fps   ",
                                        fed.decoded, estimate, frame.seconds - ptsOffset, rate).utf8))
                                }
                            }
                        }
                        if !quiet { FileHandle.standardError.write(Data("\n".utf8)) }
                        continuation.resume(returning: fed)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            _ = await pipeline.stop()
            throw error
        }
        // As LiveSessionViewModel.end(): stop() closes the log and hands back
        // what the delegate hasn't been given (a call still waiting for the
        // net check), which the session records.
        delegate.sessionEnded(handingBack: await pipeline.stop())
        let wall = Date().timeIntervalSince(started)

        // The barrier after every frame means everything has arrived; make
        // sure anyway that the main actor has nothing left in flight.
        var settled = delegate.callCount
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if delegate.callCount == settled { break }
            settled = delegate.callCount
        }

        let video = await recorder.finish()
        var kept: URL?
        if let video {
            if options.keepVideo {
                let target = options.out.appendingPathComponent("session.mov")
                try fileManager.moveItem(at: video, to: target)
                kept = target
            } else {
                try? fileManager.removeItem(at: video)
            }
        }
        try fileManager.moveItem(at: logFile, to: options.out.appendingPathComponent("detections.jsonl"))

        guard let firstPTS = fed.pts.first else { throw RunnerError("no frames decoded from \(options.video.path)") }
        let sessionStart = recorder.startTime ?? firstPTS
        return LiveRun(info: source.info, converter: source.converter, fedPTS: fed.pts, decoded: fed.decoded,
                       wallSeconds: wall, modelSeconds: modelSeconds,
                       sessionStart: sessionStart, ptsOffset: options.ptsOffset,
                       shots: delegate.shots, starts: delegate.starts, hoopChanges: delegate.hoopChanges,
                       probe: probe.stats,
                       thermalStart: thermalStart, thermalMax: fed.thermalMax,
                       thermalEnd: ProcessInfo.processInfo.thermalState,
                       recordedVideo: kept,
                       decodedPTS: fed.decodedPTS, processMs: fed.processMs,
                       lateDropped: fed.late, frameCost: frameCost, pausedFed: fed.paused,
                       pauses: fed.pauseRuns.values.map { ($0.first - sessionStart)...($0.last - sessionStart) }
                           .sorted { $0.lowerBound < $1.lowerBound },
                       environment: environment)
    }

    /// The model compiled for this Mac. An .mlmodel / .mlpackage is
    /// compiled to a temporary .mlmodelc, as Xcode does at build time.
    private func compiledModel() async throws -> (url: URL, isTemporary: Bool) {
        let model = options.model
        guard fileManager.fileExists(atPath: model.path) else {
            throw RunnerError("model not found: \(model.path) (pass --model)")
        }
        if model.pathExtension == "mlmodelc" { return (model, false) }
        do {
            return (try await MLModel.compileModel(at: model), true)
        } catch {
            throw RunnerError("couldn't compile \(model.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

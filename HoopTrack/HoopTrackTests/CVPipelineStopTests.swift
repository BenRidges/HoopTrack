// HoopTrackTests/CVPipelineStopTests.swift
// Ending a session: CVPipeline.stop() runs after the frame in progress,
// hands back a call still waiting for the net check (ShotReplay counts one
// at the end of a log, so the app must too), and never delivers a call
// twice. App target only: it needs AVFoundation sample buffers.
import XCTest
import AVFoundation
@preconcurrency import Combine
@testable import HoopTrack

@MainActor
final class CVPipelineStopTests: XCTestCase {

    private let rim = CGRect(x: 0.45, y: 0.70, width: 0.10, height: 0.10)

    /// Returns the scripted ball for each frame (PTS × 60) and the hoop.
    nonisolated private final class ScriptedDetector: BallDetectorProtocol, @unchecked Sendable {
        let balls: [Int: CGRect]
        let hoop: CGRect
        /// When set, every frame waits for it (a slow frame).
        let gate: DispatchSemaphore?
        private let lock = NSLock()
        private var _entered = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return _entered }

        init(balls: [Int: CGRect], hoop: CGRect, gate: DispatchSemaphore? = nil) {
            self.balls = balls
            self.hoop = hoop
            self.gate = gate
        }

        func detectScene(buffer: CMSampleBuffer, region: CGRect?) -> SceneDetection? {
            lock.lock(); _entered = true; lock.unlock()
            gate?.wait()
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            let frame = Int((CMTimeGetSeconds(pts) * 60).rounded())
            let ball = balls[frame].map { [BallDetection(boundingBox: $0, confidence: 0.8, frameTimestamp: pts)] } ?? []
            return SceneDetection(balls: ball,
                                  baskets: [BallDetection(boundingBox: hoop, confidence: 0.9, frameTimestamp: pts)],
                                  frameTimestamp: pts)
        }
    }

    private final class Delegate: ShotPipelineDelegate {
        deinit {} // Keep: see "Explicit deinit" in CLAUDE.md
        private(set) var shots: [DetectedShot] = []
        func pipelineHoopChanged(_ state: CalibrationState) {}
        func pipelineBallMoved(_ box: CGRect?) {}
        func pipelineShotStarted() {}
        func pipelineShotResolved(_ shot: DetectedShot) { shots.append(shot) }
    }

    /// Half a second of hoop alone, then a lob from y 0.40 through rim height
    /// starting at frame 30, drifting `drift` per second to the right. Drift
    /// 0 drops through the net (a sure make); 0.08 crosses rim height about
    /// 0.77 rim widths off centre, a graze (an unsure miss, held for the net).
    private func lob(drift: Double) -> [Int: CGRect] {
        var balls: [Int: CGRect] = [:]
        for frame in 30...(30 + 72) {
            let t = Double(frame - 30) / 60
            let y = 0.40 + 2.0 * t - 1.6667 * t * t
            balls[frame] = CGRect(x: 0.5 + drift * t - 0.015, y: y - 0.0267, width: 0.03, height: 0.0533)
        }
        return balls
    }

    private func pipeline(_ detector: ScriptedDetector, delegate: Delegate) -> (CVPipeline, PassthroughSubject<CMSampleBuffer, Never>) {
        let pipeline = CVPipeline(detector: detector, threePointDistanceFt: 23.75, fieldOfView: { 68 })
        let frames = PassthroughSubject<CMSampleBuffer, Never>()
        pipeline.start(framePublisher: frames.eraseToAnyPublisher(), delegate: delegate)
        return (pipeline, frames)
    }

    /// One steady grey frame, so the net never seems to move.
    private let pixels: CVPixelBuffer = {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &pixels)
        let buffer = pixels!
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }()

    /// Frame `n` at 60 fps.
    private func frame(_ n: Int) -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 10, timescale: 600),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(n * 10), timescale: 600),
                                        decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &buffer)
        return buffer!
    }

    /// Lets queued main-actor deliveries run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    func test_stop_handsBackACallStillWaitingForTheNet() async {
        let delegate = Delegate()
        let (pipeline, frames) = pipeline(ScriptedDetector(balls: lob(drift: 0.08), hoop: rim), delegate: delegate)
        // The graze is called at about frame 88; End comes 0.3 s later,
        // inside the net check's 0.7 s wait.
        for n in 0...106 { frames.send(frame(n)) }
        await settle()
        XCTAssertTrue(delegate.shots.isEmpty, "the unsure call is still waiting for the net")

        let last = await pipeline.stop()
        XCTAssertEqual(last.map(\.result), [.miss], "the shot happened; ending the session mustn't lose it")
        XCTAssertLessThan(last.first?.confidence ?? 1, 0.9)

        await settle()
        XCTAssertTrue(delegate.shots.isEmpty)
        let again = await pipeline.stop()
        XCTAssertTrue(again.isEmpty, "stop() twice hands nothing back twice")
    }

    func test_stop_neverDeliversACallTwice_andIgnoresLaterFrames() async {
        let delegate = Delegate()
        let (pipeline, frames) = pipeline(ScriptedDetector(balls: lob(drift: 0), hoop: rim), delegate: delegate)
        // A sure make, published on its frame; its delivery is still queued
        // for the main actor (nothing here has yielded) when End comes.
        for n in 0...110 { frames.send(frame(n)) }
        let last = await pipeline.stop()
        frames.send(frame(111))
        await settle()

        let all = delegate.shots + last
        XCTAssertEqual(all.map(\.result), [.make], "delivered once: by its own hop or by stop(), not both")
        XCTAssertEqual(all.first?.confidence ?? 0, 0.95, accuracy: 1e-9)
    }

    func test_stop_waitsForTheFrameInProgress() async throws {
        // stop() is called on the main actor while frames are processed on
        // the camera's queue. It must not tear the tracker, net check and
        // log down under a frame that's half done.
        let gate = DispatchSemaphore(value: 0)
        let detector = ScriptedDetector(balls: [:], hoop: rim, gate: gate)
        let delegate = Delegate()
        let (pipeline, frames) = pipeline(detector, delegate: delegate)
        // Handed to one other thread and not touched here meanwhile, as the
        // camera does with its frames.
        nonisolated(unsafe) let feed = frames
        nonisolated(unsafe) let buffer = frame(0)
        let processed = expectation(description: "frame processed")
        DispatchQueue.global(qos: .userInitiated).async {
            feed.send(buffer)
            processed.fulfill()
        }
        for _ in 0..<200 where !detector.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(detector.entered)

        let stopped = Flag()
        let stopping = Task { _ = await pipeline.stop(); stopped.set() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(stopped.isSet, "stop() went ahead while a frame was being processed")

        gate.signal()
        await stopping.value
        XCTAssertTrue(stopped.isSet)
        await fulfillment(of: [processed], timeout: 2)
    }

    nonisolated private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}

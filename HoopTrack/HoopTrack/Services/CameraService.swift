// CameraService.swift
// Manages the AVCaptureSession lifecycle, permission requests, and raw frame output.
//
// Phase 1: Permission flow + session setup.
// Phase 2: Frames fan out through `framePublisher` to CVPipeline + SessionRecorder.
// Phase 4: Front camera (portrait) for dribble drills.

@preconcurrency import AVFoundation
import Combine
import UIKit

@MainActor
final class CameraService: NSObject, ObservableObject {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md


    // MARK: - Published State
    @Published var permissionStatus: AVAuthorizationStatus = .notDetermined
    @Published var isSessionRunning: Bool = false
    @Published var currentMode: CameraMode = .rear
    @Published var error: CameraError?

    // MARK: - AVFoundation
    // These are marked nonisolated(unsafe) because AVCaptureSession is thread-safe
    // and Apple recommends calling startRunning/stopRunning off the main thread.
    // Configuration is serialised on sessionQueue; published state stays on @MainActor.
    nonisolated(unsafe) let captureSession = AVCaptureSession()
    nonisolated(unsafe) private var videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.hooptrack.camera.session",
                                             qos: .userInitiated)

    // MARK: - Frame Publisher
    // Downstream subscribers (CV pipeline, preview layer) attach here.
    // Thread-safe: PassthroughSubject.send can be called from any thread.
    nonisolated(unsafe) private let frameSubject = PassthroughSubject<CMSampleBuffer, Never>()
    var framePublisher: AnyPublisher<CMSampleBuffer, Never> {
        frameSubject.eraseToAnyPublisher()
    }

    /// Horizontal field of view of the active camera format, in degrees.
    /// Written on the session queue during configuration; read by the CV
    /// pipeline to turn apparent object sizes into distances.
    nonisolated(unsafe) private(set) var horizontalFieldOfView: Double = CourtPositionEstimator.defaultHorizontalFOV

    // MARK: - Initialisation
    override init() {
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
        super.init()
    }

    // MARK: - Permission

    /// Request camera access. Callers configure the session themselves once granted.
    func requestPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        permissionStatus = granted ? .authorized : .denied
    }

    /// Re-reads the system permission (e.g. after returning from Settings).
    func refreshPermission() {
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
    }

    // MARK: - Session Configuration

    func configureSession(mode: CameraMode, orientation: CameraOrientation = .landscape) {
        currentMode = mode
        sessionQueue.async { [weak self] in
            self?.buildSession(mode: mode, orientation: orientation)
            Task { @MainActor [weak self] in
                self?.applyVideoOutputRotation(orientation: orientation)
            }
        }
    }

    /// Rotation setters on AVCaptureConnection are declared @MainActor in the SDK.
    /// Called after buildSession completes on sessionQueue so the connection exists.
    private func applyVideoOutputRotation(orientation: CameraOrientation) {
        let angle = orientation.videoRotationAngle
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    nonisolated private func buildSession(mode: CameraMode, orientation: CameraOrientation = .landscape) {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        // Remove existing inputs/outputs before reconfiguring
        captureSession.inputs.forEach  { captureSession.removeInput($0)  }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        captureSession.sessionPreset = .hd1280x720

        // MARK: Camera Input
        let position: AVCaptureDevice.Position = mode == .rear ? .back : .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: position),
              let input  = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            Task { @MainActor in self.error = .deviceUnavailable }
            return
        }
        captureSession.addInput(input)

        // 60 fps gives the shot tracker twice the samples per flight. The
        // 720p preset only offers 30 fps formats, so pick the format directly.
        selectFormat(device: device, fps: HoopTrack.Camera.targetFPS)
        let fov = Double(device.activeFormat.videoFieldOfView)
        if fov > 10 { horizontalFieldOfView = fov }

        // MARK: Video Output
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            Task { @MainActor in self.error = .outputUnavailable }
            return
        }
        captureSession.addOutput(videoOutput)

        // Rotation is applied from configureSession after the sessionQueue
        // build completes, on the main actor — see applyVideoOutputRotation.
    }

    /// Switches to a 1280×720 format that can run at `fps` and locks the
    /// frame rate there. Leaves the preset's format (usually 30 fps) alone
    /// when no such format exists. Must run after the input is added, or the
    /// preset overrides it.
    ///
    /// The old version set the max frame duration to 1/maxFrameRate, which
    /// is shorter than the min duration on 120 fps formats — AVFoundation
    /// throws on that.
    nonisolated private func selectFormat(device: AVCaptureDevice, fps: Double) {
        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dims.width == 1280 && dims.height == 720
                && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && $0.maxFrameRate >= fps }
        }
        let fullRange = candidates.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        guard let format = fullRange ?? candidates.first else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            // Non-fatal; stay on the preset's frame rate.
        }
    }

    // MARK: - Start / Stop

    // The running check happens on the queue: checking first on the main
    // actor skipped the stop when it came before startRunning had finished,
    // leaving the camera on after a quick dismiss.
    func startSession() {
        let session = captureSession
        sessionQueue.async { [weak self] in
            guard !session.isRunning else { return }
            session.startRunning()
            Task { @MainActor [weak self] in self?.isSessionRunning = true }
        }
    }

    func stopSession() {
        let session = captureSession
        sessionQueue.async { [weak self] in
            guard session.isRunning else { return }
            session.stopRunning()
            Task { @MainActor [weak self] in self?.isSessionRunning = false }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Wrap in autoreleasepool to ensure the CMSampleBuffer's backing
        // CVPixelBuffer is released promptly rather than waiting for the
        // next run loop drain. Without this, 60fps capture can hold 2-3
        // live pixel buffers (~10-15 MB) simultaneously.
        autoreleasepool {
            frameSubject.send(sampleBuffer)
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didDrop sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Dropped frames are expected under heavy CPU load; silently ignored
    }
}

// MARK: - CameraError
enum CameraError: LocalizedError {
    case permissionDenied
    case deviceUnavailable
    case outputUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:   return "Camera access is required to track your shots."
        case .deviceUnavailable:  return "No camera found on this device."
        case .outputUnavailable:  return "Failed to configure the video output."
        }
    }
}

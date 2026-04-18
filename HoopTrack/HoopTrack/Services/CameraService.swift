// CameraService.swift
// Manages the AVCaptureSession lifecycle, permission requests, and raw frame output.
//
// Phase 1: Permission flow + session setup.
// Phase 2: Hook CVPipeline.processBuffer(_:) into the sample buffer delegate.
// Phase 3: Route frames to VNDetectHumanBodyPoseRequest (Shot Science).
// Phase 4: Switch to front camera + ARKit for dribble drills.

@preconcurrency import AVFoundation
import Combine
import UIKit

@MainActor
final class CameraService: NSObject, ObservableObject {

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

    // MARK: - Initialisation
    override init() {
        permissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
        super.init()
    }

    // MARK: - Permission

    /// Request camera access. Updates `permissionStatus` on main thread.
    func requestPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        permissionStatus = granted ? .authorized : .denied
        if granted { configureSession(mode: currentMode) }
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

        captureSession.sessionPreset = .hd1280x720   // 720p @ 60fps on iPhone 14

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

        // Request 60 fps for smooth CV processing
        configureFPS(device: device, fps: 60)

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

    nonisolated private func configureFPS(device: AVCaptureDevice, fps: Double) {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges
            .first(where: { $0.maxFrameRate >= fps }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(range.maxFrameRate))
            device.unlockForConfiguration()
        } catch {
            // Non-fatal; continue at default frame rate
        }
    }

    // MARK: - Start / Stop

    func startSession() {
        guard !captureSession.isRunning else { return }
        let session = captureSession
        sessionQueue.async { [weak self] in
            session.startRunning()
            Task { @MainActor [weak self] in self?.isSessionRunning = true }
        }
    }

    func stopSession() {
        guard captureSession.isRunning else { return }
        let session = captureSession
        sessionQueue.async { [weak self] in
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

// CameraService.swift
// Manages the AVCaptureSession lifecycle, permission requests, and raw frame output.
//
// Phase 1: Permission flow + session setup.
// Phase 2: Hook CVPipeline.processBuffer(_:) into the sample buffer delegate.
// Phase 3: Route frames to VNDetectHumanBodyPoseRequest (Shot Science).
// Phase 4: Switch to front camera + ARKit for dribble drills.

import AVFoundation
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
    let captureSession = AVCaptureSession()
    private var videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.hooptrack.camera.session",
                                             qos: .userInitiated)
    // Phase 2: inject the CV pipeline as the sample buffer delegate
    // private weak var cvPipeline: CVPipelineProtocol?

    // MARK: - Frame Publisher
    // Downstream subscribers (CV pipeline, preview layer) attach here.
    private let frameSubject = PassthroughSubject<CMSampleBuffer, Never>()
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

    func configureSession(mode: CameraMode) {
        currentMode = mode
        sessionQueue.async { [weak self] in
            self?.buildSession(mode: mode)
        }
    }

    private func buildSession(mode: CameraMode) {
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
            DispatchQueue.main.async { self.error = .deviceUnavailable }
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
            DispatchQueue.main.async { self.error = .outputUnavailable }
            return
        }
        captureSession.addOutput(videoOutput)

        // Lock portrait orientation for consistent CV coordinate mapping
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }

    private func configureFPS(device: AVCaptureDevice, fps: Double) {
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
        sessionQueue.async { [weak self] in
            self?.captureSession.startRunning()
            DispatchQueue.main.async { self?.isSessionRunning = true }
        }
    }

    func stopSession() {
        guard captureSession.isRunning else { return }
        sessionQueue.async { [weak self] in
            self?.captureSession.stopRunning()
            DispatchQueue.main.async { self?.isSessionRunning = false }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Phase 2: pass to CV pipeline
        // cvPipeline?.processBuffer(sampleBuffer)
        frameSubject.send(sampleBuffer)
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didDrop sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Dropped frames are expected under heavy CPU load; log in debug builds only
        #if DEBUG
        // print("CameraService: dropped frame")
        #endif
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

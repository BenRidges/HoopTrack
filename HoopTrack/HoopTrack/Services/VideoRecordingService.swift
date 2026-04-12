// HoopTrack/Services/VideoRecordingService.swift
// Wraps AVCaptureMovieFileOutput to record a session video.
// Stores the filename in TrainingSession.videoFileName on completion.
// Phase 2: optional. Phase 3: required for Shot Science replay.

import AVFoundation
import Foundation

final class VideoRecordingService: NSObject {

    // MARK: - State
    private(set) var isRecording: Bool = false
    private var movieOutput = AVCaptureMovieFileOutput()
    private var currentSessionID: UUID?

    /// Called on the main thread when recording completes or fails.
    var onRecordingFinished: ((Result<URL, Error>) -> Void)?

    // MARK: - Setup

    /// Attach to a running AVCaptureSession before calling startRecording().
    func configure(captureSession: AVCaptureSession, orientation: CameraOrientation = .portrait) {
        guard captureSession.canAddOutput(movieOutput) else { return }
        captureSession.addOutput(movieOutput)
        let angle = orientation.videoRotationAngle
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - Recording

    func startRecording(sessionID: UUID) {
        guard !isRecording else { return }
        currentSessionID = sessionID

        let docsURL = FileManager.default.urls(for: .documentDirectory,
                                                in: .userDomainMask)[0]
        let sessionsDir = docsURL.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionsDir,
                                                  withIntermediateDirectories: true)
        let outputURL = sessionsDir.appendingPathComponent("\(sessionID.uuidString).mov")

        movieOutput.startRecording(to: outputURL, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension VideoRecordingService: AVCaptureFileOutputRecordingDelegate {

    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        isRecording = false
        if let error {
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingFinished?(.failure(error))
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingFinished?(.success(outputFileURL))
            }
        }
    }
}

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
    func configure(captureSession: AVCaptureSession) {
        guard captureSession.canAddOutput(movieOutput) else { return }
        captureSession.addOutput(movieOutput)
        if let connection = movieOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
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

    // Phase 7 — Security
    private func applyFileProtection(to url: URL) {
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: url.path
            )
        } catch {
            print("[VideoRecordingService] Failed to set file protection: \(error)")
        }
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
            applyFileProtection(to: outputFileURL)
            DispatchQueue.main.async { [weak self] in
                self?.onRecordingFinished?(.success(outputFileURL))
            }
        }
    }
}

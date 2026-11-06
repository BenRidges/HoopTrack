// SessionRecorder.swift
// Writes the camera feed to Documents/Sessions/<id>.mov with AVAssetWriter,
// fed from the same sample buffers the CV pipeline sees.
//
// Replaces VideoRecordingService (AVCaptureMovieFileOutput), which was added
// to the capture session from the main thread while the session queue was
// still rebuilding it — the rebuild removed every output, so the movie
// output never had a connection and sessions were never actually recorded.
// It also kept recording until the summary was dismissed, so the video
// filename wasn't known when the session was saved.

@preconcurrency import AVFoundation
import Foundation

nonisolated final class SessionRecorder: @unchecked Sendable {

    let url: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var finished = false
    private var failed = false

    private var firstFrameTime: Double?

    /// Presentation time (seconds) of the first written frame. Shot offsets
    /// into the video are measured from here. Safe from any thread.
    var startTime: Double? {
        lock.lock(); defer { lock.unlock() }
        return firstFrameTime
    }

    init(sessionID: UUID) {
        url = SessionRecorder.directory.appendingPathComponent("\(sessionID.uuidString).mov")
    }

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory, isDirectory: true)
    }

    /// Call for every frame, on the camera queue.
    func append(_ buffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard !finished, !failed else { return }

        if writer == nil { startWriting(with: buffer) }
        guard let writer, let input, writer.status == .writing else {
            if writer?.status == .failed { failed = true }
            return
        }
        if input.isReadyForMoreMediaData {
            input.append(buffer)
        }
    }

    /// Stops recording and waits for the file. Nil if nothing was written.
    func finish() async -> URL? {
        await withCheckedContinuation { continuation in
            finish { continuation.resume(returning: $0) }
        }
    }

    /// Stops recording. Calls back with the file URL, or nil if nothing was written.
    func finish(_ completion: @escaping @Sendable (URL?) -> Void) {
        lock.lock()
        guard !finished else { lock.unlock(); completion(nil); return }
        finished = true
        guard let writer, let input, writer.status == .writing else {
            lock.unlock()
            completion(nil)
            return
        }
        input.markAsFinished()
        lock.unlock()

        let url = self.url
        writer.finishWriting {
            guard writer.status == .completed else {
                try? FileManager.default.removeItem(at: url)
                completion(nil)
                return
            }
            // Phase 7 — Security: session videos are complete-protected.
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                   ofItemAtPath: url.path)
            completion(url)
        }
    }

    // MARK: - Private

    private func startWriting(with buffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        try? FileManager.default.createDirectory(at: SessionRecorder.directory,
                                                 withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            failed = true
            return
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            failed = true
            return
        }
        writer.add(input)
        guard writer.startWriting() else {
            failed = true
            return
        }
        let start = CMSampleBufferGetPresentationTimeStamp(buffer)
        writer.startSession(atSourceTime: start)
        firstFrameTime = CMTimeGetSeconds(start)
        self.writer = writer
        self.input = input
    }
}

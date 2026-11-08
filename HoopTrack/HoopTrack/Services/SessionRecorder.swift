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
//
// During a long break (`isHolding`, set by the session's auto-pause) frames
// aren't written, and the gap is closed so the file skips straight to the
// next shot. `fileOffset(of:)` turns a camera time into a time in the file.

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
    private var holding = false
    private var cuts = VideoCuts()

    /// Presentation time (seconds) of the first written frame. Safe from
    /// any thread.
    var startTime: Double? {
        lock.lock(); defer { lock.unlock() }
        return firstFrameTime
    }

    /// While true nothing is written, and the time is cut from the file.
    /// Safe from any thread.
    var isHolding: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holding }
        set { lock.lock(); holding = newValue; lock.unlock() }
    }

    /// Where camera time `time` (seconds, the capture clock) falls in the
    /// file, allowing for cut breaks. Nil before the first frame. Safe from
    /// any thread.
    func fileOffset(of time: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard let firstFrameTime else { return nil }
        return cuts.fileOffset(of: time, start: firstFrameTime)
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

        if holding, writer != nil {
            cuts.skipped()
            return
        }
        if writer == nil { startWriting(with: buffer) }
        guard let writer, let input, writer.status == .writing else {
            if writer?.status == .failed { failed = true }
            return
        }
        guard input.isReadyForMoreMediaData else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(buffer)
        let shift = cuts.writing(at: CMTimeGetSeconds(time), frameInterval: Self.frameInterval)
        if shift > 0, let moved = Self.retimed(buffer, back: shift) {
            input.append(moved)
        } else {
            input.append(buffer)
        }
    }

    /// A gap is closed to one frame at the capture rate.
    private static let frameInterval = 1.0 / HoopTrack.Camera.targetFPS

    /// `buffer` moved `seconds` earlier.
    private static func retimed(_ buffer: CMSampleBuffer, back seconds: Double) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr, count > 0 else { return nil }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing,
                                                     entriesNeededOut: &count) == noErr else { return nil }
        let shift = CMTime(seconds: seconds, preferredTimescale: 600_000)
        for i in timing.indices {
            timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, shift)
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, shift)
            }
        }
        var moved: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
                                                    sampleTimingEntryCount: count, sampleTimingArray: &timing,
                                                    sampleBufferOut: &moved) == noErr else { return nil }
        return moved
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
        // The callback runs once, after writing has ended; nothing else
        // touches the writer by then.
        nonisolated(unsafe) let finishingWriter = writer
        writer.finishWriting {
            guard finishingWriter.status == .completed else {
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

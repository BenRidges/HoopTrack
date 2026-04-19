// DetectionLogger.swift
// Lightweight per-frame JSONL writer. Called from CVPipeline's processBuffer
// on the camera sessionQueue. Writes to
// Documents/Telemetry/<sessionID>/detections.jsonl with
// FileProtectionType.complete. Buffered in memory; flushed every N records
// or when the session ends.

import Foundation

nonisolated final class DetectionLogger {

    private let sessionID: UUID
    private let fileURL: URL
    private let fileManager = FileManager.default
    private let flushInterval: Int

    // All mutable state is accessed only from the sessionQueue that drives
    // CVPipeline. Logger is owned by CVPipeline; single-serial-queue access
    // is the runtime contract.
    nonisolated(unsafe) private var buffer: [DetectionLogEntry] = []
    nonisolated(unsafe) private var fileHandle: FileHandle?

    /// - Parameters:
    ///   - sessionID: UUID of the session being recorded.
    ///   - flushInterval: Number of records to accumulate before writing.
    ///     Default 30 ≈ 1 second at 30fps.
    init(sessionID: UUID, flushInterval: Int = 30) throws {
        self.sessionID = sessionID
        self.flushInterval = flushInterval

        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionDir = docs
            .appendingPathComponent(HoopTrack.Telemetry.telemetryDirectoryName)
            .appendingPathComponent(sessionID.uuidString)
        try fileManager.createDirectory(
            at: sessionDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )

        self.fileURL = sessionDir.appendingPathComponent("detections.jsonl")
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(
                atPath: fileURL.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
        try self.fileHandle?.seekToEnd()
    }

    /// Append one frame's detection state. Flushes to disk when the buffer
    /// reaches `flushInterval`.
    func log(_ entry: DetectionLogEntry) {
        buffer.append(entry)
        if buffer.count >= flushInterval {
            flush()
        }
    }

    /// Force a write of pending records. Called automatically by `close()`
    /// and periodically via `log()`.
    func flush() {
        guard let handle = fileHandle, !buffer.isEmpty else { return }
        for entry in buffer {
            if let line = try? entry.jsonLine(), let data = line.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }

    /// Final flush + close. Called from CVPipeline.stop().
    func close() {
        flush()
        try? fileHandle?.close()
        fileHandle = nil
    }

    deinit {
        if fileHandle != nil { close() }
    }
}

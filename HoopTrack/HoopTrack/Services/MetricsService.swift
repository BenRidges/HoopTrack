// MetricsService.swift
// Subscribes to MetricKit's daily payload delivery.
// Writes a human-readable summary to Documents/metrics.log on each delivery.
// Developer-facing only — no UI surface. Wired at app launch in HoopTrackApp.

import MetricKit
import Foundation
import Combine // Required: Swift 6 / Xcode 26 does not re-export ObservableObject through SwiftUI for NSObject subclasses

@MainActor
final class MetricsService: NSObject, ObservableObject {

    private var isRegistered = false
    private let iso8601 = ISO8601DateFormatter()

    // MARK: - Registration

    func register() {
        guard !isRegistered else { return }
        isRegistered = true
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    // MARK: - Log Helpers

    private var logURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("metrics.log")
    }

    private func append(line: String) {
        let entry = "[\(iso8601.string(from: .now))] \(line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                handle.seekToEndOfFile()
                handle.write(data)
                try handle.close()
            } catch {
                print("[MetricsService] Failed to append log entry: \(error)")
            }
        } else {
            do {
                try data.write(to: logURL)
            } catch {
                print("[MetricsService] Failed to create log file: \(error)")
            }
        }
    }
}

// MARK: - MXMetricManagerSubscriber

extension MetricsService: MXMetricManagerSubscriber {

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let lines = summarise(payload)
            Task { @MainActor in
                lines.forEach { self.append(line: $0) }
            }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashCount = payload.crashDiagnostics?.count ?? 0
            let hangCount  = payload.hangDiagnostics?.count ?? 0
            Task { @MainActor in
                self.append(line: "DIAGNOSTIC [\(payload.timeStampEnd)]: crashes=\(crashCount) hangs=\(hangCount)")
            }
        }
    }

    private nonisolated func summarise(_ payload: MXMetricPayload) -> [String] {
        var lines: [String] = []
        lines.append("=== MetricKit Payload \(payload.timeStampBegin) – \(payload.timeStampEnd) ===")

        if let cpu = payload.cpuMetrics {
            lines.append("CPU cumulative time: \(cpu.cumulativeCPUTime)")
        }
        if let mem = payload.memoryMetrics {
            lines.append("Memory peak: \(mem.peakMemoryUsage)")
        }
        if let launch = payload.applicationLaunchMetrics {
            let bucketCount = launch.histogrammedTimeToFirstDraw.totalBucketCount
            lines.append("Time to first draw: \(bucketCount) histogram buckets")
        }
        if let hang = payload.applicationResponsivenessMetrics {
            lines.append("Hang rate histogram: \(hang.histogrammedApplicationHangTime.totalBucketCount) buckets")
        }
        return lines
    }
}

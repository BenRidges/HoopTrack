// MetricsService.swift
// Subscribes to MetricKit's daily payload delivery.
// Writes a human-readable summary to Documents/metrics.log on each delivery.
// Developer-facing only — no UI surface. Wired at app launch in HoopTrackApp.

import MetricKit
import Foundation
import Combine

@MainActor
final class MetricsService: NSObject, ObservableObject {

    // MARK: - Registration

    func register() {
        MXMetricManager.shared.add(self)
    }

    // MARK: - Convenience

    private var logURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("metrics.log")
    }

    private func append(line: String) {
        let entry = "[\(ISO8601DateFormatter().string(from: .now))] \(line)\n"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
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
            Task { @MainActor in
                self.append(line: "DIAGNOSTIC: \(payload.timeStampEnd)")
            }
        }
    }

    nonisolated private func summarise(_ payload: MXMetricPayload) -> [String] {
        var lines: [String] = []
        lines.append("=== MetricKit Payload \(payload.timeStampBegin) – \(payload.timeStampEnd) ===")

        if let cpu = payload.cpuMetrics {
            lines.append("CPU cumulative time: \(cpu.cumulativeCPUTime)")
        }
        if let mem = payload.memoryMetrics {
            lines.append("Memory peak: \(mem.peakMemoryUsage)")
        }
        if let launch = payload.applicationLaunchMetrics {
            lines.append("Time to first draw (cold): \(launch.histogrammedTimeToFirstDraw.bucketEnumerator.allObjects.first ?? "n/a")")
        }
        if let hang = payload.applicationResponsivenessMetrics {
            lines.append("Hang rate histogram: \(hang.histogrammedApplicationHangTime.totalBucketCount) buckets")
        }
        return lines
    }
}

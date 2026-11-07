// Dump.swift
// Writes a simulated recording in the files shot-eval reads, so the
// numbers can be reproduced (or a tuning change tried) with
//   swift run shot-eval <dir>/detections.jsonl <dir>/labels.csv
// truth.csv adds what really happened to each shot.

import Foundation
@testable import HoopTrack

enum Dump {

    static func labelsCSV(_ labels: [ShotEvaluation.Label]) -> String {
        "seconds,result\n" + labels.map { String(format: "%.4f", $0.time) + "," + ($0.result == .make ? "make" : "miss") }
            .joined(separator: "\n") + "\n"
    }

    static func truthCSV(_ run: SimulationRun) -> String {
        var lines = ["shot,shooter,release_s,label_s,result,kind,intended,distance_m,release_height_m,entry_deg,rim_hits,board_hits"]
        for s in run.shots {
            lines.append([String(s.index + 1), String(s.shooter), String(format: "%.4f", s.releaseTime),
                          String(format: "%.4f", s.labelTime), s.result == .make ? "make" : "miss", s.kind.rawValue,
                          s.plan.intended?.rawValue ?? "natural", String(format: "%.2f", s.distance),
                          String(format: "%.2f", s.releasePoint.y),
                          s.monitor.entryAngle.map { String(format: "%.1f", $0) } ?? "",
                          String(s.monitor.rimContactCount), String(s.monitor.boardContactCount)].joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func jsonl(_ entries: [DetectionLogEntry]) throws -> String {
        try entries.map { try $0.jsonLine() }.joined()
    }

    /// Writes `<directory>/<scenario>/{detections.jsonl, labels.csv, truth.csv}`.
    @discardableResult
    static func write(_ run: SimulationRun, to directory: String) throws -> String {
        let dir = URL(fileURLWithPath: directory).appendingPathComponent(run.scenario.name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try jsonl(run.entries).write(to: dir.appendingPathComponent("detections.jsonl"), atomically: true, encoding: .utf8)
        try labelsCSV(run.labels).write(to: dir.appendingPathComponent("labels.csv"), atomically: true, encoding: .utf8)
        try truthCSV(run).write(to: dir.appendingPathComponent("truth.csv"), atomically: true, encoding: .utf8)
        return dir.path
    }
}

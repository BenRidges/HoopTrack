// shot-eval — replay a session's detection log through ShotTracker.
//
//   swift run shot-eval detections.jsonl              list the calls
//   swift run shot-eval detections.jsonl labels.csv   …and score them
//   swift run shot-eval --no-net …                    tracker alone, no net check
//   swift run shot-eval --pause 30-45,90-95 …         the session was paused then
//                                                     (log seconds; the log can't show it)
//
// detections.jsonl is written to Documents/Telemetry/<session id>/ when
// "Help improve shot tracking" is on (pull it with Xcode → Devices →
// Download Container). labels.csv is `seconds,make|miss` per shot, timed
// to when the ball reaches the rim; seconds are from the session start,
// which matches the session video.
//
// Built in debug (the default for `swift run`), so @testable works.

import Foundation
@testable import HoopTrack

extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

var args = Array(CommandLine.arguments.dropFirst())
let useNet = !args.contains("--no-net")
args.removeAll { $0 == "--no-net" }
var pauses: [ClosedRange<Double>] = []
while let flag = args.firstIndex(of: "--pause") {
    guard flag + 1 < args.count else { print("--pause needs A-B[,C-D]"); exit(2) }
    for part in args[flag + 1].split(separator: ",") {
        let ends = part.split(separator: "-", maxSplits: 1).compactMap { Double($0) }
        guard ends.count == 2, ends[0] < ends[1] else { print("--pause wants A-B[,C-D], got \(part)"); exit(2) }
        pauses.append(ends[0]...ends[1])
    }
    args.removeSubrange(flag...(flag + 1))
}
guard let logPath = args.first else {
    print("usage: shot-eval [--no-net] [--pause A-B[,C-D]] <detections.jsonl> [labels.csv]")
    exit(2)
}

func read(_ path: String) -> String {
    do {
        return try String(contentsOfFile: path, encoding: .utf8)
    } catch {
        print("can't read \(path): \(error.localizedDescription)")
        exit(1)
    }
}

let entries = ShotReplay.entries(fromJSONL: read(logPath))
guard !entries.isEmpty else {
    print("no readable frames in \(logPath)")
    exit(1)
}
let calls = ShotReplay.run(entries, netCheck: useNet, pauses: pauses)
let span = (entries.last?.timestampSec ?? 0) - (entries.first?.timestampSec ?? 0)
print("\(entries.count) frames over \(Int(span)) s, \(calls.count) shots called\n")
for (index, call) in calls.enumerated() {
    let flag = call.confidence < HoopTrack.CV.lowConfidence ? "  (check)" : ""
    let number = String(index + 1).leftPadded(to: 3)
    let time = String(format: "%.2f", call.time).leftPadded(to: 8)
    let result = call.result == .make ? "make" : "miss"
    print("\(number)  \(time)s  \(result)  \(String(format: "%.2f", call.confidence))\(flag)")
}

if let labelsPath = args.dropFirst().first {
    let labels = ShotEvaluation.labels(fromCSV: read(labelsPath))
    print("\n" + ShotEvaluation.score(calls: calls, labels: labels).summary)
}

// shot-sim — benchmark the make/miss logic on simulated footage.
//
//   swift run shot-sim                          every scenario, 200 shots each
//   swift run shot-sim --list                   the scenarios
//   swift run shot-sim --scenario 'rimout-*,mixed-real' --shots 100 --seed 7
//   swift run shot-sim --scenario mixed-real --trace        explain each failure
//   swift run shot-sim --scenario mixed-real --dump /tmp/sim
//       then: swift run shot-eval /tmp/sim/mixed-real/detections.jsonl /tmp/sim/mixed-real/labels.csv
//
// Physics → camera → detector noise → the app's own pipeline produce a
// detections.jsonl like a phone's, scored with ShotReplay.run and
// ShotEvaluation.score (what shot-eval does). Faster in release:
//   swift run -c release -Xswiftc -enable-testing shot-sim

import Foundation
@testable import HoopTrack
@testable import ShotSimulation

var args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

let usage = """
usage: shot-sim [--scenario NAMES] [--shots N] [--seed S] [--dump DIR] [--trace] [--trace-limit N]
                [--no-net] [--kinds] [--list]
  --scenario   comma-separated names or patterns ('rimout-*', '*-harsh', all); default all
  --shots      shots per scenario (non-shot streams: N × 6 s of footage); default 200
  --seed       default 1; the same seed gives the same footage
  --dump       write <DIR>/<scenario>/detections.jsonl, labels.csv (for shot-eval) and truth.csv
  --trace      explain what the tracker did for each failure (up to --trace-limit per scenario, default 6)
  --no-net     score the tracker alone, without the net check (shot-eval --no-net)
  --kinds      per shot kind breakdown under each row
  --net-stats  net swing (NetMotionMeter) after true makes and misses, to check the net model
  --live       score the calls the app's own pipeline published while the log was written,
               instead of replaying the log (the two should agree; the last line says if not)
"""

if flag("--help") || flag("-h") {
    print(usage)
    exit(0)
}
if flag("--list") {
    for s in Scenario.all {
        print(s.name.padding(toLength: 17, withPad: " ", startingAt: 0) + s.summary)
    }
    exit(0)
}
let pattern = option("--scenario") ?? "all"
let shots = Int(option("--shots") ?? "200") ?? 200
let seed = UInt64(option("--seed") ?? "1") ?? 1
let dumpDir = option("--dump")
let traceLimit = Int(option("--trace-limit") ?? "6") ?? 6
let trace = flag("--trace")
let useNet = !flag("--no-net")
let kinds = flag("--kinds")
let netStats = flag("--net-stats")
let live = flag("--live")
guard args.isEmpty else {
    print("unknown arguments: \(args.joined(separator: " "))\n\n" + usage)
    exit(2)
}

let scenarios = Scenario.matching(pattern)
guard !scenarios.isEmpty else {
    print("no scenario matches '\(pattern)'; try --list")
    exit(2)
}

print("shot-sim: \(scenarios.count) scenario(s), \(shots) shots each, seed \(seed)\(useNet ? "" : ", no net check")\(live ? ", scoring the live app calls (not the replay)" : "")")
print("camera 1280×720, \(Int(CourtPositionEstimator.defaultHorizontalFOV))° horizontal FOV; scored with ShotReplay.run + ShotEvaluation.score\n")
print(Benchmark.header)

var traces: [String] = []
var liveDiffers: [String] = []
var totals = ShotEvaluation.Report()
var phantomMinutes = 0.0, phantomCount = 0
let started = Date()
for scenario in scenarios {
    let run = Simulator.run(scenario, shots: shots, seed: seed)
    let calls = live ? run.liveCalls : Benchmark.calls(run, netCheck: useNet)
    let score = Benchmark.score(run, calls: calls)
    print(Benchmark.row(score))
    if kinds && scenario.labelsShots { print(Benchmark.kindBreakdown(score)) }
    if netStats && scenario.labelsShots { print(Benchmark.netSummary(run)) }
    fflush(stdout)
    if useNet && !live && score.liveDisagreements > 0 { liveDiffers.append("\(scenario.name) (\(score.liveDisagreements))") }
    if scenario.labelsShots {
        totals.labelled += score.report.labelled
        totals.matched += score.report.matched
        totals.correct += score.report.correct
    } else {
        phantomMinutes += score.footageMinutes
        phantomCount += score.report.phantomShots
    }
    if let dumpDir {
        do {
            let dir = try Dump.write(run, to: dumpDir)
            traces.append("dumped \(scenario.name) → \(dir)")
        } catch {
            print("can't write \(dumpDir): \(error.localizedDescription)")
            exit(1)
        }
    }
    if trace {
        let replay = TraceReplay.run(run.entries, netCheck: useNet)
        let failures = TraceReport.failures(run, replay: replay, limit: traceLimit)
        let hoops = TraceReport.wrongHoop(run, replay: replay)
        let net = TraceReport.netOnWrongMakes(run, replay: replay)
        if !failures.isEmpty || !hoops.isEmpty || net != nil {
            traces.append("── \(scenario.name) (seed \(seed)) " + String(repeating: "─", count: max(0, 50 - scenario.name.count)))
            if let net { traces.append(net) }
            if !hoops.isEmpty { traces.append(hoops.joined(separator: "\n")) }
            traces += failures
        }
    }
}

if totals.labelled > 0 {
    let det = Double(totals.matched) / Double(totals.labelled) * 100
    let ok = Double(totals.correct) / Double(totals.labelled) * 100
    print(String(format: "\nall shot scenarios: %d shots, detected %.1f%%, right calls %.1f%% of all shots", totals.labelled, det, ok))
}
if phantomMinutes > 0 {
    print(String(format: "non-shot streams: %d phantom shots in %.0f min (%.2f/min)", phantomCount, phantomMinutes,
                 Double(phantomCount) / phantomMinutes))
}
if useNet && !live {
    // The app's own pipeline ran live while the log was written; the
    // replay should publish the same calls from the log alone.
    print(liveDiffers.isEmpty ? "live app calls = replayed calls in every scenario"
          : "live app calls differ from the replay in: " + liveDiffers.joined(separator: ", "))
}
print(String(format: "(%.0f s)\n", Date().timeIntervalSince(started)))
print(Benchmark.legend)
if !traces.isEmpty {
    print("")
    print(traces.joined(separator: "\n\n"))
}

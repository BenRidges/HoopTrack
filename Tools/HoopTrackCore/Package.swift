// swift-tools-version:6.2
// HoopTrackCore — the app's pure logic (shot tracking, geometry, stats)
// built as a plain Swift package, so it can be tested and tuned on any
// machine with a Swift toolchain, Linux included, without a simulator.
//
// Sources/HoopTrack and Tests/HoopTrackTests are symlinks into the app
// target; the only real files here are the shim, the replay/evaluation
// code and the tools. The module is called HoopTrack so the app's tests
// (`@testable import HoopTrack`) compile unchanged.
//
// ShotSimulation (package-only, real files) generates synthetic sessions —
// shot physics, a phone camera, detector noise, net motion — as
// detections.jsonl + labels, and benchmarks the tracker on them.
//
//   swift test                         run the pure-logic tests
//   swift run shot-eval <log> [labels] replay a session's detection log
//   swift run shot-sim                 benchmark make/miss on simulated shots
//   swift run cv-replay <video> …      (macOS) run the live pipeline on a video
//
// Sources/HoopTrack/Capture holds the app's camera-side files (CVPipeline,
// CoreMLBallDetector, CourtCalibrationService, DetectionLogger, …). They
// need AVFoundation, Vision and Core ML, so they and cv-replay are only
// part of the package when it's built on a Mac; on Linux the module is
// the pure logic alone, as before.

import PackageDescription

#if os(macOS)
let onMac = true
#else
let onMac = false
#endif

var targets: [Target] = [
    // Same isolation defaults as the app target.
    .target(name: "HoopTrack",
            exclude: onMac ? [] : ["Capture"],
            swiftSettings: [.swiftLanguageMode(.v5), .defaultIsolation(MainActor.self)]),
    .executableTarget(name: "shot-eval", dependencies: ["HoopTrack"],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
    // No default isolation here: XCTest's initialisers aren't main-actor.
    .testTarget(name: "HoopTrackTests", dependencies: ["HoopTrack"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
    // Synthetic footage for benchmarking the tracker (never in the app).
    .target(name: "ShotSimulation", dependencies: ["HoopTrack"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "shot-sim", dependencies: ["ShotSimulation", "HoopTrack"],
                      swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "ShotSimulationTests", dependencies: ["ShotSimulation", "HoopTrack"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
]

if onMac {
    // Decodes a video and feeds it through the shipped CVPipeline (Core ML
    // on the Mac's GPU / Neural Engine). See Tools/cv/README.md.
    targets.append(.executableTarget(name: "cv-replay", dependencies: ["HoopTrack"],
                                     swiftSettings: [.swiftLanguageMode(.v5)]))
}

let package = Package(
    name: "HoopTrackCore",
    // Matches the app's deployment target; macOS for `swift test` on a Mac.
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: targets
)

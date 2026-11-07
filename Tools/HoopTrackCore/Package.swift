// swift-tools-version:6.2
// HoopTrackCore — the app's pure logic (shot tracking, geometry, stats)
// built as a plain Swift package, so it can be tested and tuned on any
// machine with a Swift toolchain, Linux included, without a simulator.
//
// Sources/HoopTrack and Tests/HoopTrackTests are symlinks into the app
// target; the only real files there are the shim, the replay/evaluation
// code and the shot-eval tool. The module is called HoopTrack so the
// app's tests (`@testable import HoopTrack`) compile unchanged.
//
// ShotSimulation (package-only, real files) generates synthetic sessions —
// shot physics, a phone camera, detector noise, net motion — as
// detections.jsonl + labels, and benchmarks the tracker on them.
//
//   swift test                         run the pure-logic tests
//   swift run shot-eval <log> [labels] replay a session's detection log
//   swift run shot-sim                 benchmark make/miss on simulated shots

import PackageDescription

let package = Package(
    name: "HoopTrackCore",
    // Matches the app's deployment target; macOS for `swift test` on a Mac.
    platforms: [.macOS(.v14), .iOS(.v17)],
    targets: [
        // Same isolation defaults as the app target.
        .target(name: "HoopTrack",
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
)

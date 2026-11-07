// Simulator.swift
// Runs a scenario into one continuous recording: a series of sessions
// (fixed camera, ten-odd shots each) separated by a second and a half of
// the phone being picked up and re-aimed. The result is the same
// detections.jsonl a phone would have written, plus the true labels.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import HoopTrack

/// Per logged frame, what was really there (for traces).
struct FrameRecord: Sendable {
    let time: Double
    let views: [BallView]
    /// Where each logged ball box came from, in log order.
    let sources: [DetectionSource]
    /// Ball id → shot index, for balls in the air as shots.
    let shotBalls: [Int: Int]
}

struct SessionInfo: Sendable {
    let start: Double
    let end: Double
    let camera: CameraRig
    let spot: Vec3
}

struct SimulationRun: Sendable {
    let scenario: Scenario
    let seed: UInt64
    var entries: [DetectionLogEntry] = []
    var shots: [ShotTruth] = []
    var frames: [FrameRecord] = []
    var sessions: [SessionInfo] = []
    /// What the app itself would have published (live, not replayed).
    var liveCalls: [ShotReplay.Call] = []
    /// What people did when (passes, tosses, pump fakes…).
    var actions: [(time: Double, person: Int, what: String)] = []

    var labels: [ShotEvaluation.Label] {
        shots.map { ShotEvaluation.Label(time: $0.labelTime, result: $0.result) }
    }

    var footageSeconds: Double {
        guard let first = entries.first, let last = entries.last else { return 0 }
        return last.timestampSec - first.timestampSec
    }
}

enum Simulator {

    /// The world (people, balls, physics) steps at this rate; the camera
    /// captures every frame at 60 fps or every other one at 30.
    static let worldFPS = 60.0

    /// Runs `scenario` with `shots` shots (non-shot streams: shots ×
    /// `secondsPerShot` seconds of footage).
    static func run(_ scenario: Scenario, shots: Int, seed: UInt64) -> SimulationRun {
        var run = SimulationRun(scenario: scenario, seed: seed)
        var pipeline = AppPipeline()
        var lumaRng = SimRNG.stream(seed, "\(scenario.name)/luma")
        var dropRng = SimRNG.stream(seed, "\(scenario.name)/drops")
        let duration = Double(shots) * scenario.secondsPerShot
        var t = 0.0
        var frameIndex = 0          // camera frames delivered (CVPipeline.frameIndex)
        var worldFrame = 0
        // The world always runs at 60 Hz; a 30 fps camera sees every other frame.
        let stride = max(1, Int((worldFPS / scenario.captureFPS).rounded()))
        var remaining = shots
        var session = 0

        while scenario.labelsShots ? remaining > 0 : t < duration - 1 {
            var worldRng = SimRNG.stream(seed, "\(scenario.worldKey)/session\(session)")
            let quota = scenario.labelsShots ? min(scenario.shotsPerSession, remaining) : 0
            let (config, camera, secondHoop) = makeSession(scenario, shots: quota, rng: &worldRng)
            var world = World(config: config, startTime: t, firstShotIndex: run.shots.count, rng: worldRng)
            var detector = DetectorModel(noise: scenario.detector, camera: camera, secondHoop: secondHoop,
                                         rng: SimRNG.stream(seed, "\(scenario.name)/detector\(session)"))
            var renderer = NetRenderer(camera: camera, kind: scenario.net, sensor: scenario.detector.sensor)
            let sessionStart = t
            let sessionEnd = scenario.labelsShots ? Double.infinity
                : min(duration, t + Double(scenario.shotsPerSession) * scenario.secondsPerShot)
            var finishedAt: Double?
            var lastProgress = (shots: 0, time: t)

            while true {
                let snap = world.step()
                worldFrame += 1
                if scenario.labelsShots {
                    if world.isFinished {
                        if finishedAt == nil { finishedAt = snap.time }
                        if snap.time - (finishedAt ?? snap.time) > 1.0 { break }
                    }
                    if world.shots.count != lastProgress.shots { lastProgress = (world.shots.count, snap.time) }
                    if snap.time - lastProgress.time > 60 { break }   // a stuck script; never seen, but never hang
                } else if snap.time >= sessionEnd {
                    break
                }
                guard worldFrame % stride == 0 else { continue }
                frameIndex += 1
                // CVPipeline: when hot, every other camera frame is skipped.
                if scenario.thermal && frameIndex % 2 == 1 { continue }
                if dropRng.chance(scenario.detector.frameDropRate) { continue }

                let region = pipeline.region()
                let scene = detector.detect(world: snap, region: region.map { Box($0) })
                let entry = pipeline.process(time: snap.time, scene: scene, region: region) { points in
                    renderer.render(points: points, world: snap, rng: &lumaRng)
                }
                run.entries.append(entry)
                var shotBalls: [Int: Int] = [:]
                for b in snap.balls { if let s = b.shot { shotBalls[b.id] = run.shots.count + s } }
                run.frames.append(FrameRecord(time: snap.time, views: scene.views, sources: scene.balls.map(\.source),
                                              shotBalls: shotBalls))
            }
            run.shots += world.shots
            run.actions += world.actions
            run.sessions.append(SessionInfo(start: sessionStart, end: world.time, camera: camera, spot: config.spot))
            remaining -= max(1, world.mainShotsTaken)
            t = world.time
            session += 1

            // The phone is picked up and re-aimed: nothing usable for 1.5 s.
            let more = scenario.labelsShots ? remaining > 0 : t < duration - 1
            if more {
                let dt = 1.0 / worldFPS
                for _ in 0..<Int(1.5 * worldFPS) {
                    t += dt
                    worldFrame += 1
                    guard worldFrame % stride == 0 else { continue }
                    frameIndex += 1
                    if scenario.thermal && frameIndex % 2 == 1 { continue }
                    run.entries.append(pipeline.blank(time: t))
                    run.frames.append(FrameRecord(time: t, views: [], sources: [], shotBalls: [:]))
                }
            }
        }
        pipeline.finish()
        run.liveCalls = pipeline.published
        return run
    }

    /// Where the shooter, the camera and everyone else are for one session.
    static func makeSession(_ scenario: Scenario, shots: Int, rng: inout SimRNG)
        -> (SessionConfig, CameraRig, Vec3?) {
        let spotDistance = scenario.layups ? 2.6...3.6 : scenario.distance
        let angle = rng.uniform(scenario.angle) * rng.sign() * .pi / 180
        let d = rng.uniform(spotDistance)
        let spot = Vec3(d * sin(angle), 0, max(-1.0, d * cos(angle)))
        let release = (scenario.releaseHeight.lowerBound + scenario.releaseHeight.upperBound) / 2
        let standOff = rng.uniform(scenario.standOff) * rng.sign()
        let camera = scenario.placement.camera(spot: spot, releaseHeight: release, standOff: standOff, rng: &rng)

        let partnerSpot: Vec3
        if case .passOnly = scenario.choreography {
            let out = spot.horizontal.normalized
            partnerSpot = spot * rng.uniform(0.25, 0.45) + out.cross(.up) * rng.uniform(-2, 2)
        } else {
            partnerSpot = Vec3(rng.uniform(-1.3, 1.3), 0, rng.uniform(0.7, 2.0))
        }

        // Optional extras draw from their own streams, so switching one on
        // (a harsher detector brings a second hoop) leaves the shots alone.
        var copy = rng
        let extras = copy.next()

        var secondShooter: Vec3?
        if scenario.secondShooter {
            var r = SimRNG(seed: extras ^ fnv1a("second shooter"))
            let a2 = angle - r.sign() * r.uniform(20, 45) * .pi / 180
            let d2 = r.uniform(scenario.distance)
            secondShooter = Vec3(d2 * sin(a2), 0, max(-0.8, d2 * cos(a2)))
        }

        var secondHoop: Vec3?
        if scenario.detector.secondBasket {
            var r = SimRNG(seed: extras ^ fnv1a("second hoop"))
            for _ in 0..<40 {
                let yaw = CameraRig.yaw(from: camera.position, to: Court.rimCentre) + r.sign() * r.uniform(12, 30)
                let distance = r.uniform(14, 24)
                let dir = Vec3(sin(yaw * .pi / 180), 0, -cos(yaw * .pi / 180))
                let candidate = Vec3(camera.position.x + dir.x * distance, Court.rimHeight, camera.position.z + dir.z * distance)
                if let p = camera.project(candidate), p.x > 0.08, p.x < 0.92, p.y > 0.1, p.y < 0.9 {
                    secondHoop = candidate
                    break
                }
            }
        }

        var spare: Vec3?
        if scenario.spareBall {
            var r = SimRNG(seed: extras ^ fnv1a("spare ball"))
            spare = Vec3(r.sign() * r.uniform(1.5, 3), 0, r.uniform(-1.2, 0.5))
        }

        let config = SessionConfig(choreography: scenario.choreography, shots: shots, spot: spot,
                                   distance: scenario.distance, spotDistance: spotDistance,
                                   placement: scenario.placement, cameraPosition: camera.position,
                                   captureFPS: worldFPS, net: scenario.net, partner: scenario.partner,
                                   partnerSpot: partnerSpot, secondShooterSpot: secondShooter, secondHoop: secondHoop,
                                   spareBall: spare, releaseHeight: scenario.releaseHeight, layups: scenario.layups,
                                   skill: scenario.skill, mix: scenario.mix, dribbleChance: scenario.dribbleChance,
                                   pumpFakeChance: scenario.pumpFakeChance, jabChance: scenario.jabChance)
        return (config, camera, secondHoop)
    }
}

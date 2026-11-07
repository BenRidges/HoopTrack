// ShotPlanner.swift
// Turns "a rim-out from 5 m" into a release velocity, and tells what a
// release velocity actually produced. The outcome is always decided by the
// physics: the planner proposes aim points that tend to give the wanted
// kind of shot, simulates each one, and keeps the first that does.

import Foundation
@testable import HoopTrack

enum ShotKind: String, CaseIterable, Sendable {
    case swish, rimIn, rimOut, backIron, frontRim, airballShort, airballLong, bankMake, bankMiss

    var isMake: Bool { self == .swish || self == .rimIn || self == .bankMake }

    /// Name used in scenario names.
    var slug: String {
        switch self {
        case .swish: return "swish"
        case .rimIn: return "rimin"
        case .rimOut: return "rimout"
        case .backIron: return "backiron"
        case .frontRim: return "frontrim"
        case .airballShort: return "airshort"
        case .airballLong: return "airlong"
        case .bankMake: return "bankmake"
        case .bankMiss: return "bankmiss"
        }
    }
}

/// Watches one shot from release and decides what happened. Fed once per
/// frame with the ball before and after the frame and what it touched.
struct ShotMonitor: Sendable {
    let releaseTime: Double
    let releasePoint: Vec3
    /// Horizontal unit vector from the release towards the rim.
    let direction: Vec3

    private(set) var apexTime: Double?
    /// First time the ball's centre dropped through rim height after the apex.
    private(set) var rimCrossTime: Double?
    private(set) var rimCrossPoint: Vec3?
    /// Degrees below horizontal at that moment.
    private(set) var entryAngle: Double?
    /// The ball dropped through the ring into the net.
    private(set) var madeTime: Double?
    private(set) var contacts: [Contact] = []
    private(set) var finishedAt: Double?
    private(set) var closestTime: Double
    private(set) var closestDistance = Double.infinity
    private(set) var closestPoint: Vec3

    init(releaseTime: Double, releasePoint: Vec3) {
        self.releaseTime = releaseTime
        self.releasePoint = releasePoint
        direction = (Court.rimCentre - releasePoint).horizontal.normalized
        closestTime = releaseTime
        closestPoint = releasePoint
    }

    var isFinished: Bool { finishedAt != nil }
    var made: Bool { madeTime != nil }
    var result: ShotResult { made ? .make : .miss }

    /// When the ball reached the rim, as a person labelling the video would
    /// mark it: first touch of rim or board, or the drop through rim height.
    var labelTime: Double {
        let touch = contacts.first { $0.kind == .rim || $0.kind == .board }?.time ?? .infinity
        let t = min(touch, rimCrossTime ?? .infinity)
        return t.isFinite ? t : closestTime
    }

    mutating func observe(previous: SimBall, current: SimBall, from t0: Double, to t1: Double,
                          newContacts: ArraySlice<Contact>) {
        guard finishedAt == nil else { return }
        for c in newContacts where c.kind != .wall { contacts.append(c) }
        if apexTime == nil, previous.v.y >= 0, current.v.y < 0 { apexTime = t1 }
        if apexTime != nil, rimCrossTime == nil, previous.p.y > Court.rimHeight, current.p.y <= Court.rimHeight {
            let f = (previous.p.y - Court.rimHeight) / max(previous.p.y - current.p.y, 1e-9)
            rimCrossTime = t0 + f * (t1 - t0)
            rimCrossPoint = previous.p + (current.p - previous.p) * f
            let v = current.v
            entryAngle = atan2(-v.y, max(v.horizontal.length, 1e-9)) * 180 / .pi
        }
        let d = (current.p - Court.rimCentre).length
        if d < closestDistance {
            closestDistance = d
            closestTime = t1
            closestPoint = current.p
        }
        if madeTime == nil, current.inNet { madeTime = t1 }

        if let made = madeTime {
            if !current.inNet || t1 - made > 0.6 { finishedAt = t1 }
        } else if apexTime != nil, current.p.y < Court.rimHeight - Court.netLength - 0.1, current.v.y < 0 {
            finishedAt = t1
        } else if contacts.contains(where: { $0.kind == .floor }) || t1 - releaseTime > 5 {
            finishedAt = t1
        }
    }

    /// What kind of shot this turned out to be.
    var kind: ShotKind {
        let end = madeTime ?? finishedAt ?? .infinity
        let during = contacts.filter { $0.time <= end }
        let rimHits = during.filter { $0.kind == .rim }
        let first = during.first { $0.kind == .rim || $0.kind == .board }
        if made {
            if first?.kind == .board { return .bankMake }
            return rimHits.isEmpty ? .swish : .rimIn
        }
        guard let first else {
            let p = rimCrossPoint ?? closestPoint
            return (p - Court.rimCentre).horizontal.dot(direction) < 0 ? .airballShort : .airballLong
        }
        if first.kind == .board { return rimHits.isEmpty ? .airballLong : .bankMiss }
        if rimHits.count >= 3 { return .rimOut }
        let s = (first.point - Court.rimCentre).horizontal.dot(direction)
        if s > 0.12 { return .backIron }
        if s < -0.12 { return .frontRim }
        return .rimOut
    }

    var rimContactCount: Int { contacts.filter { $0.kind == .rim && $0.time <= (madeTime ?? finishedAt ?? .infinity) }.count }
    var boardContactCount: Int { contacts.filter { $0.kind == .board && $0.time <= (madeTime ?? finishedAt ?? .infinity) }.count }
}

/// Inverse ballistics: the release velocity that carries the ball from a
/// release point down through a target point at a given entry angle.
enum Aim {

    /// Closed form without air: dropping through `target` at `entryAngle`
    /// degrees below horizontal.
    static func ballistic(from p0: Vec3, to target: Vec3, entryAngle: Double, gravity g: Double) -> Vec3? {
        let d = (target - p0).horizontal
        let distance = d.length
        let rise = target.y - p0.y
        let k = rise + distance * tan(entryAngle * .pi / 180)
        guard distance > 0.05, k > 0 else { return nil }
        let t = (2 * k / g).squareRoot()
        let vh = distance / t
        let vy = rise / t + g * t / 2
        return d / distance * vh + Vec3(0, vy, 0)
    }

    /// As `ballistic`, corrected for drag and spin by re-aiming at where the
    /// ball actually lands until it lands on the target.
    static func solve(from p0: Vec3, to target: Vec3, entryAngle: Double, spin: Vec3,
                      physics: BallPhysics) -> Vec3? {
        var aimPoint = target
        guard var v = ballistic(from: p0, to: aimPoint, entryAngle: entryAngle, gravity: physics.params.gravity) else { return nil }
        for _ in 0..<5 {
            guard let crossing = crossing(from: p0, velocity: v, spin: spin, height: target.y, physics: physics) else { break }
            let error = (target - crossing).horizontal
            if error.length < 0.002 { break }
            aimPoint += error
            guard let next = ballistic(from: p0, to: aimPoint, entryAngle: entryAngle, gravity: physics.params.gravity) else { break }
            v = next
        }
        return v
    }

    /// Where a ball in open air drops through `height`, if it does.
    static func crossing(from p0: Vec3, velocity: Vec3, spin: Vec3, height: Double,
                         physics: BallPhysics) -> Vec3? {
        var b = SimBall(p: p0, v: velocity, w: spin)
        let h = 1.0 / 600
        var t = 0.0
        while t < 4 {
            let previous = b.p
            physics.advanceFree(&b, by: h)
            t += h
            if b.v.y < 0, previous.y > height, b.p.y <= height {
                let f = (previous.y - height) / (previous.y - b.p.y)
                return previous + (b.p - previous) * f
            }
            if b.p.y < 0 { return nil }
        }
        return nil
    }

    /// Backspin of `revsPerSecond` for a ball flying along `direction`
    /// (the top of the ball turns back towards the shooter).
    static func backspin(direction: Vec3, revsPerSecond: Double) -> Vec3 {
        direction.horizontal.normalized.cross(.up) * (2 * .pi * revsPerSecond)
    }
}

/// How accurately a shooter executes the aim (natural, unforced shots).
struct ShooterSkill: Sendable {
    /// Relative error in release speed, 1 SD.
    var speedError = 0.018
    /// Left/right aim error, degrees, 1 SD.
    var yawError = 1.3
    /// Release elevation error, degrees, 1 SD.
    var pitchError = 1.3
}

struct ShotPlan: Sendable {
    var release: Vec3
    var velocity: Vec3
    var spin: Vec3
    /// The kind asked for, nil for a natural shot.
    var intended: ShotKind?
    /// What the probe simulation produced (the stream reproduces it).
    var predicted: ShotKind
    var attempts: Int
}

struct ShotPlanner: Sendable {
    var physics: BallPhysics
    /// Frame interval of the stream; the probe steps the same way so its
    /// trajectory matches the stream's exactly.
    var frameInterval: Double

    /// Simulates a release until the outcome is settled.
    func probe(release: Vec3, velocity: Vec3, spin: Vec3) -> ShotMonitor {
        var ball = SimBall(p: release, v: velocity, w: spin)
        var monitor = ShotMonitor(releaseTime: 0, releasePoint: release)
        var contacts: [Contact] = []
        var t = 0.0
        while !monitor.isFinished && t < 6 {
            let before = ball
            let start = contacts.count
            physics.advance(&ball, from: t, by: frameInterval, contacts: &contacts)
            monitor.observe(previous: before, current: ball, from: t, to: t + frameInterval,
                            newContacts: contacts[start...])
            t += frameInterval
        }
        return monitor
    }

    /// A shot from `release`. With `kind` nil the shooter aims at the hoop
    /// and the skill's errors decide; otherwise aim points are drawn around
    /// the ones that give that kind until the physics agrees.
    func plan(kind: ShotKind?, release: Vec3, skill: ShooterSkill, layup: Bool,
              rng: inout SimRNG, maxTries: Int = 80) -> ShotPlan {
        let toRim = (Court.rimCentre - release).horizontal
        let forward = toRim.normalized
        let side = forward.cross(.up).normalized          // to the shooter's right
        let spin = Aim.backspin(direction: forward, revsPerSecond: layup ? rng.uniform(0.4, 1.4) : rng.uniform(1.4, 2.8))

        guard let kind else {
            // Natural shot: aim a touch long of centre, then execution error.
            let bank = layup && rng.chance(0.5) && abs(forward.x) > 0.25
            var target = Court.rimCentre + forward * 0.03
            var entry = layup ? rng.uniform(46, 60) : rng.uniform(38, 52)
            if bank {
                target = Vec3(rng.gaussian(0, 0.03), Court.rimHeight + rng.uniform(0.02, 0.14), -0.64 + rng.gaussian(0, 0.03))
                entry = rng.uniform(40, 55)
            }
            var v = Aim.solve(from: release, to: target, entryAngle: entry, spin: spin, physics: physics)
                ?? Vec3(0, 7, 0)
            v = perturb(v, skill: layup ? ShooterSkill(speedError: skill.speedError * 0.8, yawError: skill.yawError * 2,
                                                         pitchError: skill.pitchError * 2) : skill, rng: &rng)
            let outcome = probe(release: release, velocity: v, spin: spin)
            return ShotPlan(release: release, velocity: v, spin: spin, intended: nil, predicted: outcome.kind, attempts: 1)
        }

        var last: ShotPlan?
        for attempt in 1...maxTries {
            let (target, entry) = proposal(kind, forward: forward, side: side, rng: &rng)
            guard var v = Aim.solve(from: release, to: target, entryAngle: entry, spin: spin, physics: physics) else { continue }
            // A little execution noise so repeated plans aren't identical.
            v = perturb(v, skill: ShooterSkill(speedError: 0.002, yawError: 0.1, pitchError: 0.1), rng: &rng)
            let outcome = probe(release: release, velocity: v, spin: spin)
            let plan = ShotPlan(release: release, velocity: v, spin: spin, intended: kind,
                                predicted: outcome.kind, attempts: attempt)
            if outcome.kind == kind { return plan }
            last = plan
        }
        return last ?? ShotPlan(release: release, velocity: Vec3(0, 7, 0), spin: spin, intended: kind,
                                predicted: .airballShort, attempts: maxTries)
    }

    private func perturb(_ v: Vec3, skill: ShooterSkill, rng: inout SimRNG) -> Vec3 {
        let speed = v.length * (1 + rng.gaussian(0, skill.speedError))
        let horizontal = v.horizontal.length
        var pitch = atan2(v.y, horizontal) + rng.gaussian(0, skill.pitchError) * .pi / 180
        pitch = clampValue(pitch, 0.1, 1.45)
        let yawDirection = v.horizontal.normalized.rotatedAboutY(rng.gaussian(0, skill.yawError) * .pi / 180)
        return yawDirection * (speed * cos(pitch)) + Vec3(0, speed * sin(pitch), 0)
    }

    /// Target point (crossed at rim height going down) and entry angle that
    /// tend to produce `kind`. Offsets are along the shot (`forward`, + is
    /// long) and across it (`side`).
    private func proposal(_ kind: ShotKind, forward: Vec3, side: Vec3, rng: inout SimRNG) -> (Vec3, Double) {
        func around(_ s: Double, _ l: Double, height: Double = Court.rimHeight) -> Vec3 {
            Court.rimCentre + forward * s + side * l + Vec3(0, height - Court.rimHeight, 0)
        }
        switch kind {
        case .swish:
            return (around(rng.gaussian(0.02, 0.025), rng.gaussian(0, 0.025)), rng.uniform(40, 55))
        case .rimIn:
            let r = rng.uniform(0.09, 0.17), a = rng.uniform(0, 2 * .pi)
            return (around(r * cos(a), r * sin(a)), rng.uniform(35, 52))
        case .rimOut:
            let r = rng.uniform(0.11, 0.24), a = rng.uniform(0, 2 * .pi)
            return (around(r * cos(a), r * sin(a)), rng.uniform(32, 50))
        case .backIron:
            return (around(rng.uniform(0.13, 0.26), rng.gaussian(0, 0.05)), rng.uniform(30, 46))
        case .frontRim:
            return (around(rng.uniform(-0.33, -0.15), rng.gaussian(0, 0.05)), rng.uniform(34, 50))
        case .airballShort:
            return (around(rng.uniform(-1.1, -0.45), rng.gaussian(0, 0.2)), rng.uniform(35, 50))
        case .airballLong:
            return (around(rng.uniform(0.45, 0.95), rng.gaussian(0, 0.25)), rng.uniform(30, 46))
        case .bankMake:
            return (Vec3(rng.gaussian(0, 0.05), Court.rimHeight + rng.uniform(0.0, 0.2), -0.64 + rng.gaussian(0, 0.06)),
                    rng.uniform(38, 52))
        case .bankMiss:
            return (Vec3(rng.gaussian(0, 0.16), Court.rimHeight + rng.uniform(-0.1, 0.35), -0.64 + rng.gaussian(0, 0.18)),
                    rng.uniform(36, 52))
        }
    }
}

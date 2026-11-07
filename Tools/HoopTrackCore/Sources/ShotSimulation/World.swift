// World.swift
// Everything that moves in front of the camera, one frame at a time:
// players with their own scripts (dribble, hold, pump fake, shoot, chase
// the rebound, pass), the balls they handle, and the shots they take. A
// held ball follows the hands along smooth paths; a free ball is handed to
// BallPhysics. Each shot at the main hoop is watched by a ShotMonitor,
// which is where the ground-truth labels come from.

import Foundation
@testable import HoopTrack

// MARK: - Hands

/// A smooth hand path through keyframes (cubic Hermite: position and
/// velocity match at every key).
struct HandPath: Sendable {
    struct Key: Sendable {
        var t: Double
        var p: Vec3
        var v: Vec3
    }
    var keys: [Key]

    var end: Double { keys[keys.count - 1].t }

    func sample(_ t: Double) -> (p: Vec3, v: Vec3) {
        if t <= keys[0].t { return (keys[0].p, keys[0].v) }
        if t >= end { return (keys[keys.count - 1].p, keys[keys.count - 1].v) }
        var i = 0
        while i + 1 < keys.count && keys[i + 1].t < t { i += 1 }
        let a = keys[i], b = keys[i + 1]
        let span = b.t - a.t
        guard span > 1e-9 else { return (b.p, b.v) }
        let s = (t - a.t) / span, s2 = s * s, s3 = s2 * s
        let h00 = 2 * s3 - 3 * s2 + 1, h10 = s3 - 2 * s2 + s, h01 = -2 * s3 + 3 * s2, h11 = s3 - s2
        let p = a.p * h00 + a.v * (h10 * span) + b.p * h01 + b.v * (h11 * span)
        let d00 = 6 * s2 - 6 * s, d10 = 3 * s2 - 4 * s + 1, d01 = -6 * s2 + 6 * s, d11 = 3 * s2 - 2 * s
        let v = (a.p * d00 + a.v * (d10 * span) + b.p * d01 + b.v * (d11 * span)) / span
        return (p, v)
    }
}

enum Anchor: Sendable {
    case waist, chest
}

enum BallControl: Sendable {
    case free
    /// In someone's hands, moving along a path; carried at `then` afterwards.
    case path(holder: Int, path: HandPath, then: Anchor)
    case carried(holder: Int, anchor: Anchor)

    var holder: Int? {
        switch self {
        case .free: return nil
        case .path(let h, _, _), .carried(let h, _): return h
        }
    }
}

// MARK: - People

enum Role: Sendable {
    case shooter, partner, otherCourt
}

enum PassStyle: Sendable, CaseIterable {
    case chest, bounce, lob
}

enum Action: Sendable {
    case idle(Double)
    case hold(Double)
    case dribble(count: Int, crossover: Bool)
    case walk(to: Vec3, dribble: Bool, speed: Double)
    case pumpFake
    case jab
    case shoot(layup: Bool)
    case chase
    case awaitPass
    case pass(style: PassStyle)
    case slam
    case selfToss
    case glassToss
    case otherCourtShot
    case faceHoop
}

enum Activity: Sendable {
    case idle(until: Double)
    case dribbling(left: Int, crossover: Bool, side: Double, pushSpeed: Double, freeSince: Double)
    case walking(to: Vec3, speed: Double, dribble: Bool, side: Double, freeSince: Double)
    case motion(until: Double, release: PendingRelease?)
    case chasing(since: Double)
    case awaiting(since: Double)
    case waitingToCatch(until: Double)
    case done
}

struct PendingRelease: Sendable {
    var velocity: Vec3
    var spin: Vec3
    var shot: ShotPlan?
    var layup: Bool
}

struct Person: Sendable {
    let id: Int
    var role: Role
    var position: Vec3
    var height: Double
    /// +1 right-handed, −1 left-handed.
    var hand: Double
    var facing: Vec3
    var velocity: Vec3 = .zero
    /// Feet off the floor.
    var lift: Double = 0
    var jumpStart = -Double.infinity
    var jumpHeight = 0.0
    /// The ball this person plays with.
    var ball: Int?
    var queue: [Action] = []
    var activity: Activity = .idle(until: 0)
    /// Where they shoot (or pass) from now.
    var spot: Vec3
    var shotsTaken = 0
    /// Arms raised (shooting, catching a lob).
    var armsUp = false

    var side: Vec3 { facing.cross(.up).normalized * hand }
    var airTime: Double { jumpHeight > 0 ? 2 * (2 * jumpHeight / 9.81).squareRoot() : 0 }

    func anchor(_ a: Anchor, time: Double) -> Vec3 {
        let sway = Vec3(0.012 * sin(2 * .pi * 1.3 * time + Double(id)), 0.015 * sin(2 * .pi * 0.9 * time + 1), 0)
        switch a {
        case .waist:
            return position + Vec3(0, lift + 0.55 * height, 0) + facing * 0.28 + side * 0.14 + sway
        case .chest:
            return position + Vec3(0, lift + 0.71 * height, 0) + facing * 0.33 + sway
        }
    }

    func dribbleHand(side s: Double) -> Vec3 {
        position + Vec3(0, lift + 0.47 * height, 0) + facing * 0.3 + facing.cross(.up).normalized * (0.3 * s)
    }

    /// Release point for a shot released `height` metres up.
    func releasePoint(height h: Double) -> Vec3 {
        position + Vec3(0, h, 0) + facing * 0.32 + side * 0.11
    }
}

// MARK: - Truth

/// One shot at the main hoop, as it really happened.
struct ShotTruth: Sendable {
    let index: Int
    let shooter: Int
    let releaseTime: Double
    let releasePoint: Vec3
    let plan: ShotPlan
    let layup: Bool
    /// Horizontal distance from the release to the rim centre.
    let distance: Double
    var monitor: ShotMonitor
    /// The ball the shot was taken with.
    let ball: Int

    var finished: Bool { monitor.isFinished }
    var result: ShotResult { monitor.result }
    var kind: ShotKind { monitor.kind }
    var labelTime: Double { monitor.labelTime }
}

// MARK: - Snapshot

struct BallSnapshot: Sendable {
    let id: Int
    let p: Vec3
    let v: Vec3
    let w: Vec3
    let inNet: Bool
    let held: Bool
    /// Index into `World.shots` if this ball is a shot in the air.
    let shot: Int?
    /// Lying still on the floor where nobody touches it (a spare ball).
    let spare: Bool
}

struct WorldSnapshot: Sendable {
    let time: Double
    let balls: [BallSnapshot]
    let people: [Person]
    /// Bottom-of-net displacement from its rest position, metres.
    let netOffset: Vec3
    /// Net swing in progress (0 = still), for the hoop box and the net luma.
    let netEnergy: Double
}

// MARK: - World

/// What the people do in this stream.
enum Choreography: Sendable {
    /// Shooting at the main hoop; `kind` nil = natural, unforced shots.
    case shooting
    case dribbleOnly
    case passOnly
    case pumpFakesOnly
    case reboundOnly(glassTosses: Bool)

    var isShooting: Bool {
        if case .shooting = self { return true }
        return false
    }
}

struct BallSlot: Sendable {
    var ball: SimBall
    var control: BallControl
    var shot: Int?
    var spare = false
}

/// One session: a fixed camera, the people and balls, run frame by frame.
struct World {
    let config: SessionConfig
    let physics: BallPhysics
    let planner: ShotPlanner
    let dt: Double
    var rng: SimRNG
    private(set) var time: Double
    private(set) var people: [Person] = []
    private(set) var slots: [BallSlot] = []
    private(set) var shots: [ShotTruth] = []
    /// What people did and when, for explaining phantom shots.
    private(set) var actions: [(time: Double, person: Int, what: String)] = []
    private(set) var net: NetModel
    /// Shot index offset so shots are numbered across sessions.
    let firstShotIndex: Int
    /// Each person draws from their own stream (swapped into `rng` while
    /// they act), so adding someone — another court's player, a second
    /// shooter — never changes what the others do.
    private var streams: [SimRNG] = []
    private let streamBase: UInt64

    init(config: SessionConfig, startTime: Double, firstShotIndex: Int, rng: SimRNG) {
        self.config = config
        self.physics = BallPhysics()
        self.dt = 1.0 / config.captureFPS
        self.planner = ShotPlanner(physics: physics, frameInterval: dt)
        self.rng = rng
        self.time = startTime
        self.firstShotIndex = firstShotIndex
        var copy = rng
        streamBase = copy.next()
        self.net = NetModel(kind: config.net, rng: SimRNG(seed: streamBase ^ 0x0005_EED0_F00D))
        setUp()
    }

    // MARK: Set-up

    /// Adds a person with their own random stream, `key` naming it.
    private mutating func add(_ make: (inout SimRNG) -> Person, key: String) {
        var stream = SimRNG(seed: streamBase ^ fnv1a(key))
        people.append(make(&stream))
        streams.append(stream)
    }

    private mutating func setUp() {
        let towardHoop = (Court.rimCentre - config.spot).horizontal.normalized
        let config = self.config
        // The main shooter (or the ball handler in non-shot streams).
        add({ r in
            var p = Person(id: 0, role: .shooter, position: config.spot, height: r.uniform(1.72, 1.95),
                           hand: r.chance(0.85) ? 1 : -1, facing: towardHoop, spot: config.spot)
            p.ball = 0
            return p
        }, key: "shooter")
        slots.append(BallSlot(ball: SimBall(p: people[0].anchor(.waist, time: time), v: .zero),
                              control: .carried(holder: 0, anchor: .waist)))

        if config.partner {
            let spot = config.partnerSpot
            let facing = (config.spot - spot).horizontal.normalized
            add({ r in Person(id: 1, role: .partner, position: spot, height: r.uniform(1.70, 1.95),
                              hand: 1, facing: facing, spot: spot) }, key: "partner")
        }
        if let spot = config.secondShooterSpot {
            let id = people.count, ball = slots.count
            add({ r in
                var p = Person(id: id, role: .shooter, position: spot, height: r.uniform(1.70, 1.95),
                               hand: r.chance(0.85) ? 1 : -1, facing: (Court.rimCentre - spot).horizontal.normalized,
                               spot: spot)
                p.ball = ball
                // Start out of step with the main shooter.
                p.queue = [.idle(r.uniform(0.5, 4))]
                return p
            }, key: "second shooter")
            slots.append(BallSlot(ball: SimBall(p: people[id].anchor(.waist, time: time), v: .zero),
                                  control: .carried(holder: id, anchor: .waist)))
        }
        if let hoop = config.secondHoop {
            let id = people.count, ball = slots.count
            add({ r in
                let spot = hoop.horizontal + (config.cameraPosition - hoop).horizontal.normalized * r.uniform(3, 5)
                var p = Person(id: id, role: .otherCourt, position: spot, height: r.uniform(1.70, 1.95), hand: 1,
                               facing: (hoop - spot).horizontal.normalized, spot: spot)
                p.ball = ball
                p.queue = [.idle(r.uniform(1, 5))]
                return p
            }, key: "other court")
            slots.append(BallSlot(ball: SimBall(p: people[id].anchor(.waist, time: time), v: .zero),
                                  control: .carried(holder: id, anchor: .waist)))
        }
        if let spare = config.spareBall {
            var ball = SimBall(p: spare + Vec3(0, Court.ballRadius, 0), v: .zero)
            ball.onFloor = true
            slots.append(BallSlot(ball: ball, control: .free, spare: true))
        }
        if case .passOnly = config.choreography, !config.partner {
            preconditionFailure("pass-only needs a partner")
        }
    }

    var mainShotsTaken: Int { people[0].shotsTaken }

    /// True once the main shooter is done and every shot has settled.
    var isFinished: Bool {
        if case .done = people[0].activity {
            return shots.allSatisfy(\.finished)
        }
        return false
    }

    // MARK: Step

    mutating func step() -> WorldSnapshot {
        let t0 = time
        time += dt
        let t = time

        // Free balls fly.
        for i in slots.indices {
            guard case .free = slots[i].control, !slots[i].spare || !slots[i].ball.onFloor || slots[i].ball.v.length > 0 else { continue }
            let before = slots[i].ball
            var contacts: [Contact] = []
            physics.advance(&slots[i].ball, from: t0, by: dt, contacts: &contacts)
            if let s = slots[i].shot {
                shots[s].monitor.observe(previous: before, current: slots[i].ball, from: t0, to: t,
                                         newContacts: contacts[...])
                if shots[s].monitor.isFinished { slots[i].shot = nil }
            }
            for c in contacts { net.excite(by: c) }
            if slots[i].ball.inNet && !before.inNet { net.ballEntered(speed: before.v.length, at: t) }
        }

        // People act.
        for i in people.indices {
            swap(&rng, &streams[i])
            update(person: i)
            swap(&rng, &streams[i])
        }

        // Held balls follow the hands.
        for i in slots.indices {
            switch slots[i].control {
            case .free:
                break
            case .path(let h, let path, let then):
                let s = path.sample(t)
                slots[i].ball.p = s.p
                slots[i].ball.v = s.v
                if t >= path.end - 1e-9 { slots[i].control = .carried(holder: h, anchor: then) }
            case .carried(let h, let anchor):
                slots[i].ball.p = people[h].anchor(anchor, time: t)
                slots[i].ball.v = people[h].velocity
            }
        }

        // Jumps.
        for i in people.indices {
            let air = people[i].airTime
            let s = t - people[i].jumpStart
            if air > 0, s >= 0, s <= air {
                let v0 = 9.81 * air / 2
                people[i].lift = max(0, v0 * s - 4.905 * s * s)
            } else {
                people[i].lift = 0
            }
        }

        net.update(time: t, ballsInNet: slots.filter { $0.ball.inNet }.map { $0.ball.p })
        return snapshot()
    }

    func snapshot() -> WorldSnapshot {
        WorldSnapshot(time: time,
                      balls: slots.enumerated().map { i, s in
                          var held = false
                          if case .free = s.control {} else { held = true }
                          return BallSnapshot(id: i, p: s.ball.p, v: s.ball.v, w: s.ball.w, inNet: s.ball.inNet,
                                              held: held, shot: s.shot, spare: s.spare)
                      },
                      people: people,
                      netOffset: net.offset,
                      netEnergy: net.energy)
    }

    // MARK: People

    private mutating func next(_ i: Int) {
        if people[i].queue.isEmpty { plan(i) }
        guard !people[i].queue.isEmpty else {
            people[i].activity = .done
            return
        }
        let action = people[i].queue.removeFirst()
        begin(action, person: i)
    }

    private func holding(_ i: Int) -> Int? {
        guard let b = people[i].ball, slots[b].control.holder == i else { return nil }
        return b
    }

    /// Moves a held ball smoothly to an anchor.
    private mutating func carry(_ b: Int, by i: Int, to anchor: Anchor, over duration: Double = 0.22) {
        let start = (slots[b].ball.p, slots[b].ball.v)
        let target = people[i].anchor(anchor, time: time + duration)
        slots[b].control = .path(holder: i, path: HandPath(keys: [
            .init(t: time, p: start.0, v: start.1),
            .init(t: time + duration, p: target, v: people[i].velocity),
        ]), then: anchor)
    }

    private mutating func release(_ b: Int, velocity: Vec3, spin: Vec3 = .zero) {
        slots[b].ball.v = velocity
        slots[b].ball.w = spin
        slots[b].ball.inNet = false
        slots[b].ball.onFloor = false
        slots[b].control = .free
    }

    private mutating func catchBall(_ b: Int, by i: Int, anchor: Anchor = .waist) {
        slots[b].ball.inNet = false
        slots[b].ball.onFloor = false
        slots[b].ball.w = .zero
        people[i].ball = b
        carry(b, by: i, to: anchor, over: 0.18)
    }

    private mutating func begin(_ action: Action, person i: Int) {
        let t = time
        switch action {
        case .pass(let style): actions.append((t, i, "\(style) pass"))
        case .pumpFake: actions.append((t, i, "pump fake"))
        case .slam: actions.append((t, i, "slams the ball down"))
        case .selfToss: actions.append((t, i, "tosses the ball up"))
        case .glassToss: actions.append((t, i, "tosses off the glass"))
        case .otherCourtShot: actions.append((t, i, "shoots at the other hoop"))
        case .shoot(let layup): actions.append((t, i, layup ? "layup" : "shot"))
        case .dribble(let n, let crossover): actions.append((t, i, "dribbles \(n)\(crossover ? " (crossovers)" : "")"))
        case .chase: actions.append((t, i, "goes for the ball"))
        case .jab: actions.append((t, i, "jab step"))
        default: break
        }
        switch action {
        case .idle(let d):
            people[i].velocity = .zero
            people[i].activity = .idle(until: t + d)

        case .hold(let d):
            people[i].velocity = .zero
            if let b = holding(i) { carry(b, by: i, to: .chest, over: 0.25) }
            people[i].activity = .idle(until: t + d)

        case .faceHoop:
            people[i].facing = (Court.rimCentre - people[i].position).horizontal.normalized
            people[i].activity = .idle(until: t)

        case .dribble(let count, let crossover):
            guard let b = holding(i) else { return next(i) }
            people[i].velocity = .zero
            let side = people[i].hand
            let speed = rng.uniform(3.0, 4.5)
            startDribble(b, by: i, side: side, speed: speed, crossover: crossover)
            people[i].activity = .dribbling(left: count - 1, crossover: crossover, side: crossover ? -side : side,
                                            pushSpeed: speed, freeSince: t + 0.15)

        case .walk(let to, let dribble, let speed):
            var dribbling = dribble
            if dribble, let b = holding(i) {
                let direction = (to - people[i].position).horizontal.normalized
                people[i].velocity = direction * speed
                people[i].facing = direction
                startDribble(b, by: i, side: people[i].hand, speed: rng.uniform(3.0, 4.0), crossover: false)
            } else {
                dribbling = false
            }
            people[i].activity = .walking(to: to, speed: speed, dribble: dribbling, side: people[i].hand, freeSince: t + 0.15)

        case .jab:
            // A quick step at the hoop and back: the body moves, the ball barely.
            let start = people[i].position
            let out = start + people[i].facing * 0.35
            people[i].queue.insert(.walk(to: start, dribble: false, speed: 1.8), at: 0)
            people[i].activity = .walking(to: out, speed: 2.5, dribble: false, side: people[i].hand, freeSince: t)

        case .pumpFake:
            guard let b = holding(i) else { return next(i) }
            people[i].velocity = .zero
            let set = people[i].releasePoint(height: 0.95 * people[i].height + rng.uniform(0.1, 0.25))
                - people[i].facing * 0.25
            let up = rng.uniform(0.22, 0.32), pause = rng.uniform(0.05, 0.25), down = rng.uniform(0.25, 0.4)
            let chest = people[i].anchor(.chest, time: t + up + pause + down)
            slots[b].control = .path(holder: i, path: HandPath(keys: [
                .init(t: t, p: slots[b].ball.p, v: slots[b].ball.v),
                .init(t: t + up, p: set, v: .zero),
                .init(t: t + up + pause, p: set + Vec3(0, 0.02, 0), v: .zero),
                .init(t: t + up + pause + down, p: chest, v: .zero),
            ]), then: .chest)
            people[i].armsUp = true
            people[i].activity = .motion(until: t + up + pause + down, release: nil)

        case .shoot(let layup):
            guard let b = holding(i) else { return next(i) }
            beginShot(person: i, ball: b, layup: layup)

        case .chase:
            people[i].activity = .chasing(since: t)

        case .awaitPass:
            people[i].velocity = .zero
            people[i].activity = .awaiting(since: t)

        case .pass(let style):
            guard let b = holding(i), let to = passTarget(for: i) else { return next(i) }
            beginPass(person: i, ball: b, to: to, style: style)

        case .slam:
            guard let b = holding(i) else { return next(i) }
            let hand = people[i].anchor(.waist, time: t)
            let windup = 0.15
            let speed = rng.uniform(6.5, 9.0)
            slots[b].control = .path(holder: i, path: HandPath(keys: [
                .init(t: t, p: slots[b].ball.p, v: slots[b].ball.v),
                .init(t: t + windup, p: hand, v: Vec3(0, -speed, 0)),
            ]), then: .waist)
            people[i].activity = .motion(until: t + windup, release: PendingRelease(velocity: Vec3(0, -speed, 0) + people[i].facing * 0.3,
                                                                                       spin: .zero, shot: nil, layup: false))

        case .selfToss:
            guard let b = holding(i) else { return next(i) }
            let chest = people[i].anchor(.chest, time: t + 0.2)
            let v = Vec3(0, rng.uniform(3.5, 6.0), 0) + people[i].facing * rng.uniform(0, 0.3)
            slots[b].control = .path(holder: i, path: HandPath(keys: [
                .init(t: t, p: slots[b].ball.p, v: slots[b].ball.v),
                .init(t: t + 0.2, p: chest, v: v * 0.5),
            ]), then: .chest)
            people[i].activity = .motion(until: t + 0.2, release: PendingRelease(velocity: v, spin: .zero, shot: nil, layup: false))

        case .glassToss:
            guard let b = holding(i) else { return next(i) }
            people[i].facing = (Court.rimCentre - people[i].position).horizontal.normalized
            let from = people[i].releasePoint(height: rng.uniform(2.1, 2.4))
            let target = Vec3(people[i].position.x * 0.3 + rng.gaussian(0, 0.15), Court.rimHeight + rng.uniform(0.35, 0.7),
                              Court.boardZ - 0.25)
            let v = Aim.ballistic(from: from, to: target, entryAngle: rng.uniform(5, 35), gravity: 9.81) ?? Vec3(0, 6, -1)
            slots[b].control = .path(holder: i, path: HandPath(keys: [
                .init(t: t, p: slots[b].ball.p, v: slots[b].ball.v),
                .init(t: t + 0.3, p: from, v: v * 0.6),
            ]), then: .chest)
            people[i].armsUp = true
            people[i].activity = .motion(until: t + 0.3, release: PendingRelease(velocity: v, spin: .zero, shot: nil, layup: false))

        case .otherCourtShot:
            guard let b = holding(i), let hoop = config.secondHoop else { return next(i) }
            let from = people[i].releasePoint(height: rng.uniform(2.1, 2.5))
            let target = hoop + Vec3(rng.gaussian(0, 0.15), 0, rng.gaussian(0, 0.15))
            let v = Aim.ballistic(from: from, to: target, entryAngle: rng.uniform(38, 50), gravity: 9.81) ?? Vec3(0, 7, 0)
            let set = from - v.normalized * 0.4
            slots[b].control = .path(holder: i, path: HandPath(keys: [
                .init(t: t, p: slots[b].ball.p, v: slots[b].ball.v),
                .init(t: t + 0.3, p: set, v: .zero),
                .init(t: t + 0.3 + 0.8 / v.length, p: from, v: v),
            ]), then: .chest)
            people[i].activity = .motion(until: t + 0.3 + 0.8 / v.length, release: PendingRelease(velocity: v, spin: .zero, shot: nil, layup: false))
        }
    }

    /// The hands take the ball to the side and send it down for a dribble
    /// (released when the path ends, by the dribbling/walking activity).
    private mutating func startDribble(_ b: Int, by i: Int, side: Double, speed: Double, crossover: Bool) {
        let hand = people[i].dribbleHand(side: side) + people[i].velocity * 0.15
        let across = people[i].facing.cross(.up).normalized
        var v = Vec3(0, -speed, 0) + people[i].velocity
        if crossover { v += across * (-side * 1.7) }
        slots[b].control = .path(holder: i, path: HandPath(keys: [
            .init(t: time, p: slots[b].ball.p, v: slots[b].ball.v),
            .init(t: time + 0.15, p: hand - Vec3(0, 0.05, 0), v: v),
        ]), then: .waist)
    }

    /// Gather, lift to the set point, push, release — the ball's whole
    /// path through the shooting motion, ending on a frame boundary.
    private mutating func beginShot(person i: Int, ball b: Int, layup: Bool) {
        let t = time
        let p = people[i]
        let releaseHeight = layup ? rng.uniform(config.layupReleaseHeight) : rng.uniform(config.releaseHeight)
        people[i].facing = (Court.rimCentre - p.position).horizontal.normalized
        people[i].velocity = .zero
        let release = people[i].releasePoint(height: releaseHeight)
        let plan = planner.plan(kind: config.kind(for: &rng), release: release, skill: config.skill,
                                layup: layup, rng: &rng)
        let v0 = plan.velocity
        let pushLength = layup ? rng.uniform(0.25, 0.4) : rng.uniform(0.35, 0.5)
        let pushTime = 2 * pushLength / max(v0.length, 1)
        let set = release - v0.normalized * pushLength
        let gather = people[i].anchor(.waist, time: t) - Vec3(0, rng.uniform(0, 0.08), 0)
        let dip = rng.uniform(0.08, 0.16)
        let lift = rng.uniform(0.22, 0.34)
        let pause = rng.chance(0.5) ? rng.uniform(0.02, 0.12) : 0
        // Release on a frame boundary, so the stream's flight matches the planner's probe.
        let raw = dip + lift + pause + pushTime
        let frames = (raw / dt).rounded(.up)
        let stretch = frames * dt - raw
        let tSet = t + dip + lift + stretch
        let tRelease = t + frames * dt

        var keys: [HandPath.Key] = [.init(t: t, p: slots[b].ball.p, v: slots[b].ball.v),
                                    .init(t: t + dip, p: gather, v: .zero),
                                    .init(t: tSet, p: set, v: .zero)]
        if pause > 0 { keys.append(.init(t: tSet + pause, p: set, v: .zero)) }
        keys.append(.init(t: tRelease, p: release, v: v0))
        slots[b].control = .path(holder: i, path: HandPath(keys: keys), then: .chest)

        // Jump so the release comes just before the top.
        let standingReach = 1.17 * p.height
        people[i].jumpHeight = max(0, min(0.45, releaseHeight - standingReach))
        people[i].jumpStart = tRelease - people[i].airTime / 2 - 0.03
        people[i].armsUp = true
        people[i].activity = .motion(until: tRelease, release: PendingRelease(velocity: v0, spin: plan.spin, shot: plan, layup: layup))
    }

    private func passTarget(for i: Int) -> Int? {
        if people[i].role == .partner { return 0 }
        return people.firstIndex { $0.role == .partner }
    }

    private mutating func beginPass(person i: Int, ball b: Int, to j: Int, style: PassStyle) {
        let t = time
        people[i].facing = (people[j].position - people[i].position).horizontal.normalized
        people[i].velocity = .zero
        let windup = style == .lob ? 0.32 : 0.22
        let from = style == .lob
            ? people[i].position + Vec3(0, 0.98 * people[i].height + 0.15, 0) + people[i].facing * 0.15
            : people[i].anchor(.chest, time: t + windup) + people[i].facing * 0.1
        let target = people[j].anchor(.chest, time: t + 1)
        let d = (target - from).horizontal
        let distance = d.length
        let direction = d.normalized
        let g = 9.81
        var v: Vec3
        switch style {
        case .chest:
            let speed = rng.uniform(6, 8.5)
            let flight = distance / speed
            v = direction * speed + Vec3(0, (target.y - from.y + 0.5 * g * flight * flight) / flight, 0)
        case .bounce:
            let floorPoint = from.horizontal + direction * (0.62 * distance)
            let speed = rng.uniform(5.5, 7)
            let flight = (floorPoint - from.horizontal).length / speed
            v = direction * speed + Vec3(0, (Court.ballRadius - from.y + 0.5 * g * flight * flight) / flight, 0)
        case .lob:
            let apex = rng.uniform(2.9, 3.7)
            let vy = (2 * g * max(0.2, apex - from.y)).squareRoot()
            let flight = vy / g + (2 * max(0.1, apex - target.y) / g).squareRoot()
            v = direction * (distance / flight) + Vec3(0, vy, 0)
        }
        slots[b].control = .path(holder: i, path: HandPath(keys: [
            .init(t: t, p: slots[b].ball.p, v: slots[b].ball.v),
            .init(t: t + windup, p: from, v: v * 0.4),
        ]), then: .chest)
        people[i].armsUp = style == .lob
        people[i].activity = .motion(until: t + windup, release: PendingRelease(velocity: v, spin: .zero, shot: nil, layup: false))
        people[i].ball = nil
        people[j].ball = b
    }

    // MARK: Per-frame behaviour

    private mutating func update(person i: Int) {
        let t = time
        switch people[i].activity {
        case .done:
            people[i].velocity = .zero

        case .idle(let until), .waitingToCatch(let until):
            if t >= until { next(i) }

        case .motion(let until, let pending):
            guard t >= until - 1e-9 else { return }
            people[i].armsUp = false
            if let pending, let b = people[i].ball ?? slots.indices.first(where: { slots[$0].control.holder == i }) {
                // Release: the ball is at the end of its path this frame.
                if case .path(_, let path, _) = slots[b].control {
                    let end = path.sample(path.end)
                    slots[b].ball.p = end.p
                }
                release(b, velocity: pending.velocity, spin: pending.spin)
                if let plan = pending.shot {
                    let index = firstShotIndex + shots.count
                    shots.append(ShotTruth(index: index, shooter: i, releaseTime: t, releasePoint: plan.release,
                                           plan: plan, layup: pending.layup,
                                           distance: (Court.rimCentre - plan.release).horizontal.length,
                                           monitor: ShotMonitor(releaseTime: t, releasePoint: plan.release), ball: b))
                    slots[b].shot = shots.count - 1
                    people[i].shotsTaken += 1
                }
            }
            next(i)

        case .dribbling(let left, let crossover, let side, let pushSpeed, let freeSince):
            guard let b = people[i].ball else { return next(i) }
            if case .free = slots[b].control {
                let hand = people[i].dribbleHand(side: side)
                let ball = slots[b].ball
                let near = (ball.p - hand).horizontal.length < 0.55
                let atHand = (ball.v.y > 0 && ball.p.y >= hand.y - 0.08) || (ball.v.y <= 0 && ball.p.y > 0.45 && t - freeSince > 0.25)
                if near && atHand {
                    if left > 0 {
                        // Hand meets the ball and sends it down again.
                        let pushPoint = hand - Vec3(0, 0.06, 0)
                        let across = people[i].facing.cross(.up).normalized
                        var v = Vec3(0, -pushSpeed, 0) + people[i].velocity
                        if crossover { v += across * (-side * 1.7) }
                        slots[b].control = .path(holder: i, path: HandPath(keys: [
                            .init(t: t, p: ball.p, v: ball.v),
                            .init(t: t + 0.09, p: pushPoint, v: v),
                        ]), then: .waist)
                        people[i].activity = .dribbling(left: left - 1, crossover: crossover,
                                                        side: crossover ? -side : side, pushSpeed: pushSpeed, freeSince: t + 0.09)
                    } else {
                        slots[b].ball.v = ball.v * 0.3
                        catchBall(b, by: i, anchor: .waist)
                        next(i)
                    }
                } else if t - freeSince > 1.6 || (!near && ball.p.y < 0.3) {
                    // Lost it: go and get it, then come back.
                    people[i].queue.insert(.walk(to: people[i].spot, dribble: false, speed: 2.5), at: 0)
                    people[i].activity = .chasing(since: t)
                }
            } else if case .path(_, let path, _) = slots[b].control, t >= path.end - 1e-9 {
                let end = path.sample(path.end)
                slots[b].ball.p = end.p
                release(b, velocity: end.v)
            }

        case .walking(let to, let speed, let dribble, let side, let freeSince):
            let offset = (to - people[i].position).horizontal
            let arrived = offset.length < 0.08
            if !arrived {
                let step = min(offset.length, speed * dt)
                people[i].velocity = offset.normalized * speed
                people[i].position += offset.normalized * step
                people[i].facing = offset.normalized
            } else {
                people[i].velocity = .zero
            }
            if dribble, let b = people[i].ball {
                if case .free = slots[b].control {
                    let hand = people[i].dribbleHand(side: side)
                    let ball = slots[b].ball
                    let near = (ball.p - hand).horizontal.length < 0.7
                    let atHand = (ball.v.y > 0 && ball.p.y >= hand.y - 0.08) || (ball.v.y <= 0 && ball.p.y > 0.45 && t - freeSince > 0.25)
                    if arrived, (ball.p - people[i].position).horizontal.length < 1.3, ball.p.y > 0.3, t - freeSince > 0.2 {
                        // Stopped: reach out and take it.
                        slots[b].ball.v = ball.v * 0.3
                        catchBall(b, by: i, anchor: .waist)
                        people[i].facing = (Court.rimCentre - people[i].position).horizontal.normalized
                        next(i)
                        return
                    }
                    if near && atHand {
                        if arrived {
                            slots[b].ball.v = ball.v * 0.3
                            catchBall(b, by: i, anchor: .waist)
                            people[i].facing = (Court.rimCentre - people[i].position).horizontal.normalized
                            next(i)
                            return
                        }
                        let v = Vec3(0, -rng.uniform(3, 4), 0) + people[i].velocity
                        slots[b].control = .path(holder: i, path: HandPath(keys: [
                            .init(t: t, p: ball.p, v: ball.v),
                            .init(t: t + 0.09, p: hand - Vec3(0, 0.06, 0), v: v),
                        ]), then: .waist)
                        people[i].activity = .walking(to: to, speed: speed, dribble: true, side: side, freeSince: t + 0.09)
                    } else if t - freeSince > 1.6 || (!near && !arrived && ball.p.y < 0.3) {
                        people[i].queue.insert(.walk(to: to, dribble: false, speed: speed), at: 0)
                        people[i].activity = .chasing(since: t)
                    }
                } else if case .path(_, let path, _) = slots[b].control, t >= path.end - 1e-9 {
                    let end = path.sample(path.end)
                    slots[b].ball.p = end.p
                    release(b, velocity: end.v)
                }
            } else if arrived {
                people[i].facing = (Court.rimCentre - people[i].position).horizontal.normalized
                next(i)
            }

        case .chasing:
            let b = people[i].ball ?? 0
            let ball = slots[b].ball
            if let s = slots[b].shot, !shots[s].finished {
                return  // wait for the shot to settle
            }
            if slots[b].control.holder != nil && slots[b].control.holder != i {
                // Somebody else has it.
                people[i].velocity = .zero
                return next(i)
            }
            let target = ball.p.horizontal + ball.v.horizontal * 0.25
            let offset = (target - people[i].position).horizontal
            let reach = (ball.p - people[i].position).horizontal.length
            if reach < 0.6, ball.p.y < 2.3, ball.v.y <= 0.5 || ball.onFloor || ball.p.y < 1.4 {
                people[i].velocity = .zero
                catchBall(b, by: i)
                next(i)
                return
            }
            if offset.length > 0.05 {
                let speed = min(4.5, 1.5 + 2 * offset.length)
                people[i].velocity = offset.normalized * speed
                people[i].position += offset.normalized * min(offset.length, speed * dt)
                people[i].facing = offset.normalized
            }

        case .awaiting(let since):
            guard let b = people[i].ball else {
                people[i].velocity = .zero
                return
            }
            let ball = slots[b].ball
            guard case .free = slots[b].control else { return }
            let chest = people[i].anchor(.chest, time: t)
            if (ball.p - chest).length < 0.5 {
                slots[b].ball.v = .zero
                catchBall(b, by: i, anchor: .chest)
                people[i].facing = (Court.rimCentre - people[i].position).horizontal.normalized
                next(i)
                return
            }
            // Step towards a pass that's falling short or wide.
            let offset = (ball.p - people[i].position).horizontal
            let coming = -offset.normalized.dot(ball.v.horizontal) > 0.5
            if ball.p.y < 2.2, offset.length < 2.5, coming || t - since > 3 {
                let speed = 2.5
                people[i].velocity = offset.normalized * speed
                people[i].position += offset.normalized * min(offset.length, speed * dt)
            } else {
                people[i].velocity = .zero
            }
            if t - since > 6 { people[i].activity = .chasing(since: t) }
        }
    }

    // MARK: Scripts

    /// Queues the next few things this person does.
    private mutating func plan(_ i: Int) {
        let p = people[i]
        switch p.role {
        case .otherCourt:
            people[i].queue = [.idle(rng.uniform(3, 9)), .otherCourtShot, .idle(0.8), .chase,
                               .walk(to: p.spot, dribble: false, speed: 2)]
        case .partner:
            planPartner(i)
        case .shooter:
            switch config.choreography {
            case .shooting: planShooter(i)
            case .dribbleOnly: planDribbler(i)
            case .passOnly: planPasser(i)
            case .pumpFakesOnly: planFaker(i)
            case .reboundOnly(let glass): planRebounder(i, glass: glass)
            }
        }
    }

    private mutating func nextSpot(for i: Int) -> Vec3 {
        let base = people[i].role == .shooter && i != 0 ? (config.secondShooterSpot ?? config.spot) : config.spot
        let out = base.horizontal.normalized
        let across = out.cross(.up)
        for _ in 0..<20 {
            let candidate = base + out * rng.uniform(-0.45, 0.45) + across * rng.uniform(-0.25, 0.25)
            let d = candidate.horizontal.length
            guard d >= config.spotDistance.lowerBound - 0.3, d <= config.spotDistance.upperBound + 0.3, candidate.z > -1.2 else { continue }
            // Stay in front of the camera.
            let toCam = config.cameraPosition.horizontal - candidate.horizontal
            if !config.placement.facesShooter && toCam.length < 0.9 { continue }
            return candidate
        }
        return base
    }

    private mutating func planShooter(_ i: Int) {
        let quota = i == 0 ? config.shots : Int.max
        if people[0].shotsTaken >= config.shots && i != 0 {
            people[i].queue = [.idle(1000)]
            return
        }
        guard people[i].shotsTaken < quota else { return }   // empty queue → done
        var q: [Action] = []
        // Back to the spot first if a loose ball or a bad pass took them away.
        if (people[i].position - people[i].spot).horizontal.length > 0.4 {
            q.append(.walk(to: people[i].spot, dribble: rng.chance(0.4), speed: rng.uniform(1.8, 2.8)))
        }
        q.append(.faceHoop)
        let layup = config.layups
        if layup {
            // Drive from the spot and lay it in.
            let toward = (Court.rimCentre - people[i].spot).horizontal
            let stop = people[i].spot.horizontal + toward.normalized * max(0, toward.length - rng.uniform(config.distance))
            q.append(.walk(to: stop, dribble: true, speed: rng.uniform(2.5, 4)))
            q.append(.shoot(layup: true))
        } else {
            if rng.chance(config.dribbleChance) { q.append(.dribble(count: rng.int(1...4), crossover: rng.chance(0.25))) }
            q.append(.hold(rng.uniform(0.15, 1.0)))
            if rng.chance(config.pumpFakeChance) { q += [.pumpFake, .hold(rng.uniform(0.2, 0.6))] }
            if rng.chance(config.jabChance) { q.append(.jab) }
            q.append(.shoot(layup: false))
        }
        q.append(.idle(rng.uniform(0.4, 1.0)))
        let spot = nextSpot(for: i)
        people[i].spot = spot
        if config.partner && i == 0 {
            q += [.walk(to: spot, dribble: false, speed: rng.uniform(1.5, 2.5)), .awaitPass]
        } else {
            q += [.chase, .walk(to: spot, dribble: rng.chance(0.5), speed: rng.uniform(2, 3.2))]
        }
        people[i].queue = q
    }

    private mutating func planPartner(_ i: Int) {
        // Rebounds the main shooter's ball and passes it back, or (pass-only)
        // passes it back and forth with the shooter.
        switch config.choreography {
        case .passOnly:
            if people[i].ball != nil && slots[people[i].ball!].control.holder == i {
                var q: [Action] = [.hold(rng.uniform(0.3, 1.2))]
                if rng.chance(0.3) { q.append(.dribble(count: rng.int(1...3), crossover: false)) }
                q.append(.pass(style: rng.weighted([(.chest, 0.5), (.bounce, 0.3), (.lob, 0.2)])))
                q.append(.walk(to: config.partnerSpot + Vec3(rng.uniform(-0.8, 0.8), 0, rng.uniform(-0.6, 0.6)), dribble: false, speed: 1.5))
                people[i].queue = q
            } else {
                people[i].queue = [.awaitPass]
            }
        default:
            // Wait for the shooter's ball to come off the rim, fetch it, pass.
            let shooterBall = people[0].ball ?? 0
            let shotLive = slots[shooterBall].shot != nil
            let free: Bool = { if case .free = slots[shooterBall].control { return true } else { return false } }()
            if !shotLive && free && people[0].shotsTaken > 0 && { if case .awaiting = people[0].activity { return true }; if case .walking = people[0].activity { return true }; return false }() {
                people[i].ball = shooterBall
                people[i].queue = [.chase, .hold(rng.uniform(0.2, 0.7)),
                                   .pass(style: rng.weighted([(.chest, 0.55), (.bounce, 0.25), (.lob, 0.2)])),
                                   .walk(to: config.partnerSpot, dribble: false, speed: 2)]
            } else {
                people[i].queue = [.idle(0.1)]
            }
        }
    }

    private mutating func planDribbler(_ i: Int) {
        var q: [Action] = []
        let spot = nextSpot(for: i)
        q.append(.walk(to: spot, dribble: rng.chance(0.7), speed: rng.uniform(1.5, 3)))
        q.append(.dribble(count: rng.int(4...14), crossover: rng.chance(0.4)))
        if rng.chance(0.5) { q.append(.dribble(count: rng.int(2...8), crossover: rng.chance(0.5))) }
        q.append(.hold(rng.uniform(0.4, 2)))
        if rng.chance(0.12) { q += [.slam, .chase] }
        q.append(.idle(rng.uniform(0.2, 1)))
        people[i].queue = q
    }

    private mutating func planPasser(_ i: Int) {
        if let b = people[i].ball, slots[b].control.holder == i {
            var q: [Action] = [.faceHoop, .hold(rng.uniform(0.3, 1.2))]
            if rng.chance(0.3) { q.append(.dribble(count: rng.int(1...3), crossover: false)) }
            q.append(.pass(style: rng.weighted([(.chest, 0.5), (.bounce, 0.3), (.lob, 0.2)])))
            q.append(.walk(to: nextSpot(for: i), dribble: false, speed: 1.5))
            q.append(.awaitPass)
            people[i].queue = q
        } else {
            people[i].queue = [.awaitPass]
        }
    }

    private mutating func planFaker(_ i: Int) {
        var q: [Action] = [.faceHoop, .hold(rng.uniform(0.3, 1.2))]
        for _ in 0..<rng.int(1...3) {
            q.append(rng.chance(0.65) ? .pumpFake : .jab)
            q.append(.hold(rng.uniform(0.2, 0.8)))
        }
        if rng.chance(0.5) { q.append(.dribble(count: rng.int(1...4), crossover: rng.chance(0.3))) }
        q.append(.walk(to: nextSpot(for: i), dribble: rng.chance(0.5), speed: rng.uniform(1.5, 2.5)))
        people[i].queue = q
    }

    private mutating func planRebounder(_ i: Int, glass: Bool) {
        // Close to the hoop: tosses, hard bounces, loose balls.
        let spot = Vec3(rng.uniform(-1.2, 1.2), 0, rng.uniform(0.5, 2.2))
        var q: [Action] = [.walk(to: spot, dribble: rng.chance(0.5), speed: 2), .faceHoop, .hold(rng.uniform(0.3, 1.2))]
        let roll = rng.uniform()
        if glass && roll < 0.5 {
            q += [.glassToss, .chase]
        } else if roll < 0.55 {
            q += [.slam, .chase]
        } else if roll < 0.8 {
            q += [.selfToss, .chase]
        } else {
            q.append(.dribble(count: rng.int(2...8), crossover: rng.chance(0.3)))
        }
        people[i].queue = q
    }
}

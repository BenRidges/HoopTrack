// BallPhysics.swift
// A basketball in flight: gravity, air drag, Magnus lift from backspin,
// and impulse collisions with the rim (a torus), the backboard (a plane),
// the floor and the net. Real dimensions throughout, metres and seconds.
//
// It doesn't need to be a perfect physics engine. It needs to produce the
// kinds of shot the tracker has to tell apart — swish, rim in, rim out,
// back iron, front rim, air balls, banks — with believable timing and
// bounces, so the per-frame boxes look like real footage.

import Foundation

/// Regulation dimensions.
enum Court {
    static let rimHeight = 3.05
    /// Inside diameter 0.457 m.
    static let rimInnerRadius = 0.457 / 2
    /// The rim rod is ~16 mm thick.
    static let rimTubeRadius = 0.008
    static let rimRingRadius = rimInnerRadius + rimTubeRadius
    static let rimCentre = Vec3(0, rimHeight, 0)

    /// Size 7 ball: 0.239 m across, 0.62 kg, a hollow shell (I = 2/3 m r²).
    static let ballRadius = 0.239 / 2
    static let ballMass = 0.62
    static let ballInertiaFactor = 2.0 / 3.0

    /// Backboard 1.83 × 1.07 m; the rim's inner edge is 0.15 m in front of
    /// it, and its bottom edge 0.15 m below the rim.
    static let boardWidth = 1.83
    static let boardHeight = 1.07
    static let rimToBoard = 0.15
    static let boardZ = -(rimInnerRadius + rimToBoard)
    static let boardBottom = rimHeight - 0.15
    static var boardTop: Double { boardBottom + boardHeight }

    /// Nylon net: hangs 0.45 m, narrowing to ~0.30 m across at the bottom.
    static let netLength = 0.45
    static let netBottomRadius = 0.15

    static let threePointDistance = 7.24

    /// How wide the net is at `depth` metres below the rim.
    static func netRadius(depth: Double) -> Double {
        lerp(rimInnerRadius, netBottomRadius, clampValue(depth / netLength, 0, 1))
    }
}

enum ContactKind: String, Sendable {
    case rim, board, floor, net, wall
}

/// Something the ball touched. Touches of the same thing within 25 ms are
/// merged (a rolling ball keeps touching the rim every substep).
struct Contact: Sendable {
    var time: Double
    var kind: ContactKind
    /// Point of contact on the obstacle.
    var point: Vec3
    /// Speed into the obstacle just before contact, m/s.
    var speed: Double
}

struct SimBall: Sendable {
    var p: Vec3
    var v: Vec3
    /// Angular velocity, rad/s.
    var w: Vec3 = .zero
    /// Dropped through the ring and is inside the net.
    var inNet = false
    /// Sitting on the floor (rolling or still).
    var onFloor = false

    init(p: Vec3, v: Vec3, w: Vec3 = .zero) {
        self.p = p
        self.v = v
        self.w = w
    }
}

struct PhysicsParams: Sendable {
    var gravity = 9.81
    /// Quadratic drag per unit mass, ½ρ·Cd·A/m with ρ = 1.2 kg/m³, Cd ≈ 0.5,
    /// A = π·0.1195² m², m = 0.62 kg. About 14 % of g at 8 m/s.
    var drag = 0.0217
    /// Magnus lift, a = k (ω × v), with C_L ≈ 0.8·rω/v: k = 0.4·ρ·A·r/m.
    /// Backspin of 2.5 rev/s at 8 m/s lifts ~0.5 m/s².
    var magnus = 0.0042
    /// Ball on steel rim: fairly dead, and grippy.
    var rimRestitution = 0.55
    var rimFriction = 0.45
    /// Ball on glass.
    var boardRestitution = 0.68
    var boardFriction = 0.30
    /// Ball on a wooden floor: dropped from 1.8 m it comes back to ~1.15 m.
    var floorRestitution = 0.80
    var floorFriction = 0.60
    /// A ball inside the net is braked by the cords, sideways more than downwards.
    var netDampingVertical = 5.0
    var netDampingHorizontal = 14.0
    /// Integration steps: coarse in open air, fine near anything it can hit.
    var coarseStep = 1.0 / 480
    var fineStep = 1.0 / 2400
    /// Gym walls (the ball comes back rather than rolling off forever).
    var wallX = 11.0
    var wallBehindBoard = -4.0
    var wallFar = 18.0
}

struct BallPhysics: Sendable {
    var params = PhysicsParams()

    /// Advances a free ball by `dt` seconds starting at time `t`, appending
    /// whatever it touches to `contacts`.
    func advance(_ b: inout SimBall, from t: Double, by dt: Double, contacts: inout [Contact]) {
        var elapsed = 0.0
        while elapsed < dt - 1e-12 {
            let h = min(stepSize(for: b), dt - elapsed)
            elapsed += h
            step(&b, h: h, time: t + elapsed, contacts: &contacts)
        }
    }

    /// Advances the ball ignoring everything but gravity, drag and spin.
    func advanceFree(_ b: inout SimBall, by h: Double) {
        let a = acceleration(b)
        b.v += a * h
        b.p += b.v * h
    }

    private func stepSize(for b: SimBall) -> Double {
        let r = b.p - Court.rimCentre
        let horizontal = (r.x * r.x + r.z * r.z).squareRoot()
        if abs(r.y) < 0.55 && horizontal < 0.8 { return params.fineStep }
        if b.p.z < Court.boardZ + 0.45 && b.p.z > Court.boardZ - 0.25
            && abs(b.p.x) < Court.boardWidth / 2 + 0.3
            && b.p.y > Court.boardBottom - 0.3 && b.p.y < Court.boardTop + 0.3 { return params.fineStep }
        if b.p.y < 0.45 { return params.fineStep }
        return params.coarseStep
    }

    private func acceleration(_ b: SimBall) -> Vec3 {
        let speed = b.v.length
        var a = Vec3(0, -params.gravity, 0)
        a -= b.v * (params.drag * speed)
        a += b.w.cross(b.v) * params.magnus
        if b.inNet {
            a.x -= b.v.x * params.netDampingHorizontal
            a.z -= b.v.z * params.netDampingHorizontal
            if b.v.y < 0 { a.y -= b.v.y * params.netDampingVertical }
        }
        return a
    }

    private func step(_ b: inout SimBall, h: Double, time: Double, contacts: inout [Contact]) {
        if b.onFloor {
            roll(&b, h: h)
            walls(&b, time: time, contacts: &contacts)
            return
        }
        let a = acceleration(b)
        b.v += a * h
        b.p += b.v * h
        rim(&b, time: time, contacts: &contacts)
        board(&b, time: time, contacts: &contacts)
        net(&b, time: time, contacts: &contacts)
        floor(&b, time: time, contacts: &contacts)
        walls(&b, time: time, contacts: &contacts)
    }

    // MARK: Collisions

    /// Impulse response for a hollow sphere hitting a fixed surface with
    /// outward normal `n`: restitution on the normal part, Coulomb friction
    /// (capped at what stops the contact point slipping) on the tangential
    /// part, which also changes the spin. Returns the approach speed.
    @discardableResult
    func bounce(_ b: inout SimBall, normal n: Vec3, restitution e: Double, friction mu: Double) -> Double {
        let radius = Court.ballRadius
        let r = n * (-radius)                       // centre → contact point
        let vc = b.v + b.w.cross(r)                 // contact-point velocity
        let vn = vc.dot(n)
        guard vn < 0 else { return 0 }
        let jn = -(1 + e) * vn                      // normal impulse per unit mass
        var dv = n * jn
        let vt = vc - n * vn
        let slip = vt.length
        if slip > 1e-9 {
            let t = vt / slip
            let stopSlip = slip / (1 + 1 / Court.ballInertiaFactor)
            let jt = min(mu * jn, stopSlip)
            dv -= t * jt
            b.w += r.cross(t * -jt) / (Court.ballInertiaFactor * radius * radius)
        }
        b.v += dv
        return -vn
    }

    private func record(_ kind: ContactKind, point: Vec3, speed: Double, time: Double,
                        into contacts: inout [Contact]) {
        if let i = contacts.lastIndex(where: { $0.kind == kind }), time - contacts[i].time < 0.025 {
            contacts[i].speed = max(contacts[i].speed, speed)
            return
        }
        contacts.append(Contact(time: time, kind: kind, point: point, speed: speed))
    }

    private func rim(_ b: inout SimBall, time: Double, contacts: inout [Contact]) {
        let reach = Court.ballRadius + Court.rimTubeRadius
        let rel = b.p - Court.rimCentre
        guard abs(rel.y) < reach else { return }
        let hl = (rel.x * rel.x + rel.z * rel.z).squareRoot()
        guard abs(hl - Court.rimRingRadius) < reach else { return }
        let dx = hl > 1e-9 ? rel.x / hl : 1, dz = hl > 1e-9 ? rel.z / hl : 0
        let closest = Vec3(dx * Court.rimRingRadius, Court.rimHeight, dz * Court.rimRingRadius)
        let d = b.p - closest
        let dist = d.length
        guard dist < reach, dist > 1e-9 else { return }
        let n = d / dist
        b.p = closest + n * reach
        let speed = bounce(&b, normal: n, restitution: params.rimRestitution, friction: params.rimFriction)
        if speed > 0.05 { record(.rim, point: closest, speed: speed, time: time, into: &contacts) }
    }

    private func board(_ b: inout SimBall, time: Double, contacts: inout [Contact]) {
        let face = Court.boardZ
        guard b.v.z < 0, b.p.z - Court.ballRadius < face, b.p.z > face - 0.06,
              abs(b.p.x) <= Court.boardWidth / 2,
              b.p.y >= Court.boardBottom, b.p.y <= Court.boardTop else { return }
        b.p.z = face + Court.ballRadius
        let speed = bounce(&b, normal: Vec3(0, 0, 1), restitution: params.boardRestitution,
                           friction: params.boardFriction)
        if speed > 0.05 {
            record(.board, point: Vec3(b.p.x, b.p.y, face), speed: speed, time: time, into: &contacts)
        }
    }

    private func floor(_ b: inout SimBall, time: Double, contacts: inout [Contact]) {
        guard b.p.y < Court.ballRadius, b.v.y < 0 else { return }
        b.p.y = Court.ballRadius
        let speed = bounce(&b, normal: .up, restitution: params.floorRestitution, friction: params.floorFriction)
        if speed > 0.3 { record(.floor, point: Vec3(b.p.x, 0, b.p.z), speed: speed, time: time, into: &contacts) }
        if b.v.y < 0.35 {
            b.v.y = 0
            b.onFloor = true
        }
    }

    private func roll(_ b: inout SimBall, h: Double) {
        // Rolling resistance on wood: about 0.3 m/s².
        let horizontal = b.v.horizontal
        let speed = horizontal.length
        if speed > 1e-6 {
            let slowed = max(0, speed - 0.3 * h)
            b.v = horizontal * (slowed / speed)
        } else {
            b.v = .zero
        }
        b.p += b.v * h
        b.p.y = Court.ballRadius
        b.w = Vec3.up.cross(b.v) / Court.ballRadius   // rolling without slipping
    }

    private func walls(_ b: inout SimBall, time: Double, contacts: inout [Contact]) {
        if abs(b.p.x) > params.wallX, b.p.x * b.v.x > 0 {
            b.v.x = -0.5 * b.v.x
            record(.wall, point: b.p, speed: abs(b.v.x), time: time, into: &contacts)
        }
        if b.p.z < params.wallBehindBoard, b.v.z < 0 {
            b.v.z = -0.5 * b.v.z
            record(.wall, point: b.p, speed: abs(b.v.z), time: time, into: &contacts)
        }
        if b.p.z > params.wallFar, b.v.z > 0 {
            b.v.z = -0.5 * b.v.z
            record(.wall, point: b.p, speed: abs(b.v.z), time: time, into: &contacts)
        }
    }

    /// The net: a ball that drops through the ring is held in a narrowing
    /// sleeve and braked; one falling past the outside brushes it.
    private func net(_ b: inout SimBall, time: Double, contacts: inout [Contact]) {
        let rel = b.p - Court.rimCentre
        let depth = -rel.y
        let hl = (rel.x * rel.x + rel.z * rel.z).squareRoot()
        if b.inNet {
            if depth > Court.netLength + 0.5 * Court.ballRadius || depth < -Court.ballRadius {
                b.inNet = false
                return
            }
            // Keep the centre inside the sleeve (the cords give a few cm).
            let limit = max(0.02, Court.netRadius(depth: depth) - Court.ballRadius + 0.06)
            if hl > limit {
                let out = Vec3(rel.x / hl, 0, rel.z / hl)
                let radial = b.v.dot(out)
                if radial > 0 { b.v -= out * (1.6 * radial) }
                b.p = Vec3(out.x * limit, b.p.y, out.z * limit)
            }
            return
        }
        if depth > 0, depth < 0.12, hl < Court.rimInnerRadius, b.v.y < 0 {
            b.inNet = true
            record(.net, point: b.p, speed: b.v.length, time: time, into: &contacts)
            return
        }
        // Thrown up into the net from below: the cords stop it and it drops back.
        if b.v.y > 0, depth > 0.02, depth < Court.netLength, hl < Court.netRadius(depth: depth) {
            let speed = b.v.length
            b.v = Vec3(b.v.x * 0.5, -0.25 * b.v.y, b.v.z * 0.5)
            record(.net, point: b.p, speed: min(2.5, 0.3 * speed), time: time, into: &contacts)
            return
        }
        // Falling past the outside of the net.
        if depth > 0.05, depth < Court.netLength {
            let gap = hl - Court.netRadius(depth: depth)
            if gap > 0, gap < Court.ballRadius * 0.9 {
                b.v.x *= 0.995
                b.v.z *= 0.995
                record(.net, point: b.p, speed: 0.3 * b.v.length, time: time, into: &contacts)
            }
        }
    }
}

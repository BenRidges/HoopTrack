// NetModel.swift
// The net's movement and what the camera sees where the net hangs.
//
// The app doesn't log net motion directly: NetWatch samples the luma plane
// on a 12 × 10 grid under the rim and logs the mean absolute change
// between frames (NetMotion.activity). So the simulator renders luma at
// exactly those grid points — background, the net's cords (moved by the
// swing), the ball, players in front, sensor noise, light flicker — and
// runs the app's own NetWatch over it. The logged `netActivity` is then
// whatever NetWatch would have logged for that scene.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import HoopTrack

enum NetKind: String, Sendable {
    /// White nylon, swings for ~0.5 s after a make.
    case nylon
    /// Chain: thin, grey, swings briefly.
    case chain
    /// Bare rim.
    case none
}

/// Damped oscillations of the bottom of the net, excited by makes, rim hits
/// and balls brushing past.
struct NetModel: Sendable {
    let kind: NetKind

    private struct Swing: Sendable {
        var start: Double
        var amplitude: Double      // metres at the bottom of the net
        var frequency: Double      // Hz
        var decay: Double          // seconds
        var phase: Double
        var direction: Vec3        // unit, mostly horizontal
    }
    private var swings: [Swing] = []
    private var bulge: Vec3 = .zero
    private(set) var offset: Vec3 = .zero
    /// Rough swing size relative to a clean make (0 = still).
    private(set) var energy: Double = 0
    private var time: Double = 0
    /// Its own stream, so the net type can't change the shots.
    private var rng: SimRNG

    init(kind: NetKind, rng: SimRNG) {
        self.kind = kind
        self.rng = rng
    }

    private var responsiveness: Double {
        switch kind {
        case .nylon: return 1
        case .chain: return 0.35
        case .none: return 0
        }
    }

    /// The ball dropped through the ring.
    mutating func ballEntered(speed: Double, at t: Double) {
        guard kind != .none else { return }
        let a = rng.uniform(0, 2 * .pi)
        let amplitude = responsiveness * rng.uniform(0.045, 0.07) * min(1.6, max(0.5, speed / 5))
        swings.append(Swing(start: t, amplitude: amplitude, frequency: rng.uniform(2.4, 3.4),
                            decay: kind == .chain ? 0.22 : rng.uniform(0.38, 0.6), phase: 0,
                            direction: Vec3(cos(a), 0.35, sin(a)).normalized))
    }

    /// Rim hits shake the net a little; brushing past it a little more.
    mutating func excite(by contact: Contact) {
        guard kind != .none else { return }
        let amplitude: Double
        switch contact.kind {
        case .rim:
            guard (contact.point - Court.rimCentre).length < 0.5 else { return }
            amplitude = 0.0025 * contact.speed
        case .net:
            // Entry is handled by ballEntered; this is a brush on the outside.
            guard contact.speed < 3 else { return }
            amplitude = 0.012
        default:
            return
        }
        let a = rng.uniform(0, 2 * .pi)
        swings.append(Swing(start: contact.time, amplitude: responsiveness * amplitude, frequency: rng.uniform(3, 4.5),
                            decay: 0.25, phase: rng.uniform(0, 2 * .pi),
                            direction: Vec3(cos(a), 0.2, sin(a)).normalized))
    }

    mutating func update(time t: Double, ballsInNet: [Vec3]) {
        time = t
        swings.removeAll { t - $0.start > 6 * $0.decay }
        var d = Vec3.zero
        var e = 0.0
        for s in swings where t >= s.start {
            let age = t - s.start
            let envelope = s.amplitude * exp(-age / s.decay)
            d += s.direction * (envelope * sin(2 * .pi * s.frequency * age + s.phase))
            e += envelope / 0.055
        }
        // A ball inside the net drags the cords with it.
        if kind != .none, let ball = ballsInNet.first {
            let depth = Court.rimHeight - ball.y
            let push = ball.horizontal * 0.6 + Vec3(0, -min(0.12, max(0, depth) * 0.3), 0)
            bulge = push * responsiveness
        } else {
            bulge = bulge * 0.6
        }
        offset = d + bulge
        energy = e
    }
}

/// Noise and lighting for the net luma samples.
struct NetSensor: Sendable {
    /// Per-sample luma noise after the app's 2×2 averaging, in 8-bit levels.
    /// A bright gym ≈ 1; dusk outdoors or a dim gym at high ISO ≈ 3.
    var noise = 1.4
    /// Light flicker: relative amplitude of the beat between mains-powered
    /// lights and the frame rate (fluorescent/LED, 0–2 %).
    var flicker = 0.004
    var flickerHz = 20.0
}

/// Renders luma at NetWatch's grid points for one frame.
struct NetRenderer: Sendable {
    let camera: CameraRig
    let kind: NetKind
    let sensor: NetSensor
    /// Background luma per sample point, fixed for a fixed camera.
    private var background: [Double] = []
    private var backgroundKey: Double = .nan

    init(camera: CameraRig, kind: NetKind, sensor: NetSensor) {
        self.camera = camera
        self.kind = kind
        self.sensor = sensor
    }

    private static func hash01(_ x: Int, _ y: Int, _ salt: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ salt &* 83_492_791))
        h = (h ^ (h >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        h = (h ^ (h >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return Double(h >> 11) * 0x1.0p-53
    }

    /// The net's outline in the image: rim line and net bottom, and their
    /// left and right ends.
    private struct Outline {
        var topY: Double, bottomY: Double
        var topLeft: Double, topRight: Double
        var bottomLeft: Double, bottomRight: Double
        var depth: Double
    }

    private func outline(netOffset: Vec3) -> Outline? {
        guard let top = camera.project(Court.rimCentre),
              let bottom = camera.project(Court.rimCentre + netOffset - Vec3(0, Court.netLength, 0)) else { return nil }
        let across = camera.right.horizontal.normalized
        guard let tl = camera.project(Court.rimCentre - across * Court.rimInnerRadius),
              let tr = camera.project(Court.rimCentre + across * Court.rimInnerRadius),
              let bl = camera.project(Court.rimCentre + netOffset - Vec3(0, Court.netLength, 0) - across * Court.netBottomRadius),
              let br = camera.project(Court.rimCentre + netOffset - Vec3(0, Court.netLength, 0) + across * Court.netBottomRadius)
        else { return nil }
        return Outline(topY: top.y, bottomY: bottom.y, topLeft: tl.x, topRight: tr.x,
                       bottomLeft: bl.x, bottomRight: br.x, depth: top.depth)
    }

    private struct Disc {
        var x: Double, y: Double, rx: Double, ry: Double, depth: Double, inNet: Bool, spin: Double
    }

    private struct Body {
        var box: Box, depth: Double, shiftX: Double, shiftY: Double, tone: Double
    }

    /// Luma at `points` (Vision-normalised) for this frame.
    mutating func render(points: [CGPoint], world: WorldSnapshot, rng: inout SimRNG) -> [UInt8] {
        guard !points.isEmpty else { return [] }
        let key = Double(points[0].x) * 7.3 + Double(points[0].y) * 3.1 + Double(points.count)
        if background.count != points.count || key != backgroundKey {
            backgroundKey = key
            background = points.map { p in
                let px = Int(Double(p.x) * camera.pixelWidth), py = Int(Double(p.y) * camera.pixelHeight)
                // Backboard border, wall, stands: anything from dark to bright.
                return 55 + 120 * Self.hash01(px / 3, py / 3, 1) * 0.6 + 40 * Self.hash01(px / 9, py / 9, 2)
            }
        }
        let net = kind == .none ? nil : outline(netOffset: world.netOffset)
        let netLuma = kind == .chain ? 150.0 : 215.0
        let cordStrength = kind == .chain ? 0.45 : 0.9
        let cordWidth = kind == .chain ? 0.10 : 0.17
        let ripple = min(1.5, world.netEnergy) * 0.12

        var discs: [Disc] = []
        for b in world.balls {
            guard let img = camera.ball(at: b.p, velocity: b.v) else { continue }
            let r = img.diameterPx / 2
            discs.append(Disc(x: img.x, y: img.y, rx: r / camera.pixelWidth, ry: r / camera.pixelHeight,
                              depth: img.depth, inNet: b.inNet, spin: b.w.length * world.time))
        }
        var bodies: [Body] = []
        for person in world.people {
            for part in Silhouette.parts(of: person, camera: camera) {
                bodies.append(Body(box: part.box, depth: part.depth, shiftX: part.box.minX, shiftY: part.box.minY,
                                   tone: 40 + 70 * Self.hash01(person.id, 0, 3)))
            }
        }
        let flicker = 1 + sensor.flicker * sin(2 * .pi * sensor.flickerHz * world.time)

        var out = [UInt8](repeating: 0, count: points.count)
        for (k, point) in points.enumerated() {
            let x = Double(point.x), y = Double(point.y)
            var luma = background[k]
            var cover = 0.0
            if let net, y <= net.topY, y >= net.bottomY, net.topY - net.bottomY > 1e-6 {
                let v = (net.topY - y) / (net.topY - net.bottomY)
                let left = lerp(net.topLeft, net.bottomLeft, v), right = lerp(net.topRight, net.bottomRight, v)
                if right - left > 1e-6, x >= left, x <= right {
                    var u = (x - left) / (right - left)
                    u += ripple * v * sin(2 * .pi * 5.5 * world.time + 4 * v)
                    let a = 6 * u + 5 * v, b = 6 * u - 5 * v
                    func cord(_ s: Double) -> Double { max(0, 1 - abs(s - s.rounded()) / cordWidth) }
                    cover = max(cord(a), cord(b)) * cordStrength
                    luma += (netLuma - luma) * cover
                }
            }
            // People in front of the net (or behind it, seen through the cords).
            for body in bodies where body.box.contains(x: x, y: y) {
                let sx = (x - body.shiftX) * 90, sy = (y - body.shiftY) * 50
                var tone = body.tone + 35 * sin(sx) * cos(sy)
                if let net, body.depth > net.depth { tone += (netLuma - tone) * cover }
                luma = tone
            }
            // Balls: in front of the cords, inside them, or behind them.
            for d in discs {
                let dx = (x - d.x) / max(d.rx, 1e-9), dy = (y - d.y) / max(d.ry, 1e-9)
                let r2 = dx * dx + dy * dy
                guard r2 < 1 else { continue }
                var tone = 95 + 28 * sin(6 * dx + d.spin) * cos(5 * dy)
                if let net {
                    if d.inNet { tone += (netLuma - tone) * cover * 0.5 }
                    else if d.depth > net.depth - 0.15 { tone += (netLuma - tone) * cover }
                }
                luma = tone
            }
            luma = luma * flicker + rng.gaussian(0, sensor.noise)
            out[k] = UInt8(clampValue(luma.rounded(), 0, 255))
        }
        return out
    }
}

/// A person's outline as boxes in the picture, for occlusion, false
/// positives and the net luma.
enum Silhouette {
    struct Part {
        var box: Box
        var depth: Double
        var isHead: Bool
        /// How much of what's behind it the part hides (raised arms have gaps).
        var opacity: Double
    }

    static func parts(of p: Person, camera: CameraRig) -> [Part] {
        guard let depth = camera.project(p.position + Vec3(0, 1, 0))?.depth else { return [] }
        var parts: [Part] = []
        let shoulders = p.lift + p.height - 0.26
        if let torso = camera.uprightBox(base: p.position, width: 0.46, bottom: p.lift, top: shoulders) {
            parts.append(Part(box: torso, depth: depth, isHead: false, opacity: 1))
        }
        if let head = camera.uprightBox(base: p.position, width: 0.21, bottom: shoulders, top: p.lift + p.height + 0.01) {
            parts.append(Part(box: head, depth: depth, isHead: true, opacity: 1))
        }
        // Raised forearms, up to the wrists (the ball sits on the hands above).
        if p.armsUp, let arms = camera.uprightBox(base: p.position + p.facing * 0.15 + p.side * 0.08, width: 0.16,
                                                   bottom: shoulders, top: p.lift + p.height + 0.25) {
            parts.append(Part(box: arms, depth: depth - 0.05, isHead: false, opacity: 0.6))
        }
        return parts
    }
}

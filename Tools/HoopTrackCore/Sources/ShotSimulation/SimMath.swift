// SimMath.swift
// Small vector type, a seeded random number generator and a few helpers.
// Everything in the simulator is deterministic: one seed in, the same
// detections out, on any machine.

import Foundation

/// A point or direction in court space, metres. Origin on the floor under
/// the rim centre; y up; z out from the backboard towards the court (the
/// shooter usually stands at positive z); x to the right as seen by someone
/// on the court facing the basket.
struct Vec3: Equatable, Sendable, CustomStringConvertible {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    static let zero = Vec3(0, 0, 0)
    static let up = Vec3(0, 1, 0)

    static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    static func * (s: Double, a: Vec3) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }
    static func += (a: inout Vec3, b: Vec3) { a = a + b }
    static func -= (a: inout Vec3, b: Vec3) { a = a - b }

    func dot(_ b: Vec3) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: Vec3) -> Vec3 {
        Vec3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x)
    }
    var length: Double { (x * x + y * y + z * z).squareRoot() }
    var normalized: Vec3 {
        let l = length
        return l > 1e-12 ? self / l : Vec3(0, 0, 0)
    }
    /// The same vector with the vertical part removed.
    var horizontal: Vec3 { Vec3(x, 0, z) }
    /// Rotated about the vertical axis by `angle` radians (x towards -z for positive angles).
    func rotatedAboutY(_ angle: Double) -> Vec3 {
        let c = cos(angle), s = sin(angle)
        return Vec3(c * x + s * z, y, -s * x + c * z)
    }

    var description: String { String(format: "(%.2f, %.2f, %.2f)", x, y, z) }
}

/// SplitMix64: tiny, fast, good enough statistically, and identical on
/// every platform (Foundation's generators aren't seedable).
struct SimRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
        _ = next()
    }

    /// An independent stream derived from this seed and `salt`, so adding
    /// draws in one subsystem doesn't shift every other subsystem's numbers.
    static func stream(_ seed: UInt64, _ salt: String) -> SimRNG {
        SimRNG(seed: seed ^ fnv1a(salt) &* 0x9E37_79B9_7F4A_7C15)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(next() >> 11) * 0x1.0p-53 }
    mutating func uniform(_ a: Double, _ b: Double) -> Double { a + (b - a) * uniform() }
    mutating func uniform(_ range: ClosedRange<Double>) -> Double { uniform(range.lowerBound, range.upperBound) }
    mutating func chance(_ p: Double) -> Bool { uniform() < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
    mutating func sign() -> Double { chance(0.5) ? 1 : -1 }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-300), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    mutating func gaussian(_ mean: Double, _ sd: Double) -> Double { mean + sd * gaussian() }

    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }

    /// Picks a key with probability proportional to its weight.
    mutating func weighted<T>(_ items: [(T, Double)]) -> T {
        let total = items.reduce(0) { $0 + $1.1 }
        var r = uniform() * total
        for (item, w) in items {
            r -= w
            if r < 0 { return item }
        }
        return items[items.count - 1].0
    }
}

/// FNV-1a: a stable string hash (Swift's Hasher is randomised per process).
func fnv1a(_ s: String) -> UInt64 {
    var h: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in s.utf8 {
        h ^= UInt64(byte)
        h = h &* 0x0000_0100_0000_01B3
    }
    return h
}

@inline(__always) func clampValue(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    v < lo ? lo : (v > hi ? hi : v)
}

@inline(__always) func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// 0 below `edge0`, 1 above `edge1`, smooth in between.
@inline(__always) func smoothStep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clampValue((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Standard normal cumulative distribution.
@inline(__always) func normalCDF(_ x: Double) -> Double { 0.5 * erfc(-x / 2.0.squareRoot()) }

/// An axis-aligned box in Vision-normalised image coordinates (origin at the
/// bottom-left, y up), the same convention as the app's detection boxes.
struct Box: Equatable, Sendable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double

    init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }

    init(centreX: Double, centreY: Double, width: Double, height: Double) {
        self.init(minX: centreX - width / 2, minY: centreY - height / 2, width: width, height: height)
    }

    var maxX: Double { minX + width }
    var maxY: Double { minY + height }
    var midX: Double { minX + width / 2 }
    var midY: Double { minY + height / 2 }
    var area: Double { max(0, width) * max(0, height) }

    func intersection(_ o: Box) -> Box? {
        let x0 = max(minX, o.minX), y0 = max(minY, o.minY)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return Box(minX: x0, minY: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Fraction of this box's area covered by `o`.
    func coveredFraction(by o: Box) -> Double {
        guard area > 0, let i = intersection(o) else { return 0 }
        return i.area / area
    }

    func contains(x: Double, y: Double) -> Bool { x >= minX && x <= maxX && y >= minY && y <= maxY }

    func union(_ o: Box) -> Box {
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        return Box(minX: x0, minY: y0, width: max(maxX, o.maxX) - x0, height: max(maxY, o.maxY) - y0)
    }

    var array: [Double] { [minX, minY, width, height] }

    static let unit = Box(minX: 0, minY: 0, width: 1, height: 1)
}

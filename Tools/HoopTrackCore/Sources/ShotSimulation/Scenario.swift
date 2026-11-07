// Scenario.swift
// The named benchmark matrix. A scenario fixes what happens in front of
// the camera (which shots, from where, who else is around), where the
// camera is, and how good the detector is. Scenarios that differ only in
// noise share a `worldKey`, so with the same seed they contain exactly the
// same shots: the noise is the only difference.

import Foundation
@testable import HoopTrack

enum NoiseLevel: String, CaseIterable, Sendable {
    case clean, realistic, harsh

    var slug: String {
        switch self {
        case .clean: return "clean"
        case .realistic: return "real"
        case .harsh: return "harsh"
        }
    }

    var detector: DetectorNoise {
        switch self {
        case .clean: return .clean
        case .realistic: return .realistic
        case .harsh: return .harsh
        }
    }
}

enum ShotMix: Sendable {
    /// The shooter aims at the hoop; their execution error decides.
    case natural
    /// Every shot is this kind (the physics has to agree).
    case only(ShotKind)
}

struct Scenario: Sendable {
    var name: String
    var summary: String
    /// Seeds the physical world; scenarios sharing it share their shots.
    var worldKey: String
    var choreography: Choreography = .shooting
    var mix: ShotMix = .natural
    var noise: NoiseLevel = .realistic
    var detector: DetectorNoise = .realistic
    var placement: CameraPlacement = .behindShooter(back: 1...3, height: 1.2...1.5)
    /// Shooter's distance from the rim centre (for layups: where the drive starts).
    var distance: ClosedRange<Double> = 2.5...6.5
    /// Degrees off the line straight out from the basket, either side.
    var angle: ClosedRange<Double> = 0...55
    var captureFPS = 60.0
    /// Phone at `.serious` thermal state: detection on every other frame.
    var thermal = false
    var net: NetKind = .nylon
    /// Someone under the basket rebounds and passes back (or, in pass-only, the passing partner).
    var partner = false
    var secondShooter = false
    var layups = false
    var shotsPerSession = 5
    var releaseHeight: ClosedRange<Double> = 2.0...2.6
    /// How far to the side of the camera's line to the hoop the shooter
    /// stands (so they don't block it), metres.
    var standOff: ClosedRange<Double> = 0.5...1.0
    var dribbleChance = 0.5
    var pumpFakeChance = 0.08
    var jabChance = 0.1
    var skill = ShooterSkill()
    var spareBall = false
    /// Non-shot streams: footage per "shot" asked for on the command line.
    var secondsPerShot = 6.0

    init(name: String, summary: String, worldKey: String? = nil, noise: NoiseLevel = .realistic) {
        self.name = name
        self.summary = summary
        self.worldKey = worldKey ?? name
        self.noise = noise
        self.detector = noise.detector
    }

    var labelsShots: Bool { choreography.isShooting }

    // MARK: The matrix

    static let all: [Scenario] = {
        var list: [Scenario] = []

        // Every kind of shot under each noise level.
        for kind in ShotKind.allCases {
            for level in NoiseLevel.allCases {
                var s = Scenario(name: "\(kind.slug)-\(level.slug)",
                                 summary: "\(kind.rawValue) only, 2.5–6.5 m, \(level.rawValue) detector",
                                 worldKey: kind.slug, noise: level)
                s.mix = .only(kind)
                if kind == .bankMake || kind == .bankMiss {
                    s.angle = 25...60
                    s.distance = 2...5
                    s.summary = "\(kind.rawValue) only, 2–5 m at 25–60°, \(level.rawValue) detector"
                }
                list.append(s)
            }
        }

        // Natural shooting: the shooter's errors decide.
        for level in NoiseLevel.allCases {
            var s = Scenario(name: "mixed-\(level.slug)", summary: "natural shooting 2–7.2 m, \(level.rawValue) detector",
                             worldKey: "mixed", noise: level)
            s.distance = 2...7.2
            s.angle = 0...75
            list.append(s)
        }

        var layup = Scenario(name: "layup-real", summary: "drives and layups (half off the glass), released 0.6–1.6 m out")
        layup.layups = true
        layup.distance = 0.6...1.6
        layup.angle = 10...70
        list.append(layup)

        for level in [NoiseLevel.realistic, .harsh] {
            var s = Scenario(name: "three-\(level.slug)", summary: "threes 6.7–7.3 m, small ball, \(level.rawValue) detector",
                             worldKey: "three", noise: level)
            s.distance = 6.7...7.3
            s.angle = 0...80
            list.append(s)
        }

        var fps30 = Scenario(name: "fps30-real", summary: "natural shooting, camera at 30 fps (1/60 s shutter)", worldKey: "mixed")
        fps30.captureFPS = 30
        fps30.detector.exposure = 1.0 / 60
        fps30.distance = 2...7.2
        fps30.angle = 0...75
        list.append(fps30)

        var thermal = Scenario(name: "thermal-real", summary: "natural shooting, hot phone: detection on every other frame",
                               worldKey: "mixed")
        thermal.thermal = true
        thermal.distance = 2...7.2
        thermal.angle = 0...75
        list.append(thermal)

        var two = Scenario(name: "twoballs-real", summary: "two shooters, two balls, both shooting at this hoop")
        two.secondShooter = true
        list.append(two)

        var rebounder = Scenario(name: "rebounder-real", summary: "a partner rebounds and passes back (chest, bounce, lob)")
        rebounder.partner = true
        list.append(rebounder)

        for level in [NoiseLevel.realistic, .harsh] {
            var s = Scenario(name: "facing-\(level.slug)", summary: "camera behind the (glass) board facing the shooter",
                             worldKey: "facing", noise: level)
            s.placement = .facingShooter(behind: 1.5...3.5, height: 1.2...1.5)
            s.distance = 3...7
            s.angle = 0...35
            list.append(s)
        }

        var noNet = Scenario(name: "nonet-real", summary: "bare rim, no net", worldKey: "mixed")
        noNet.net = .none
        noNet.distance = 2...7.2
        noNet.angle = 0...75
        list.append(noNet)

        var chain = Scenario(name: "chain-real", summary: "chain net (barely swings)", worldKey: "mixed")
        chain.net = .chain
        chain.distance = 2...7.2
        chain.angle = 0...75
        list.append(chain)

        var rimBox = Scenario(name: "rimbox-real", summary: "basket box flips between ring-only and ring+net (mixed training labels)",
                              worldKey: "mixed")
        rimBox.detector.rimOnlyRate = 0.4
        rimBox.distance = 2...7.2
        rimBox.angle = 0...75
        list.append(rimBox)

        var second = Scenario(name: "secondhoop-real", summary: "a second basket in view, someone shooting at it")
        second.detector.secondBasket = true
        list.append(second)

        var inline = Scenario(name: "inline-real", summary: "shooter nearly in line between camera and hoop")
        inline.standOff = 0...0.3
        list.append(inline)

        // Same shots, camera further and further behind the release.
        for back in [1.0, 2.0, 3.0, 4.0] {
            var s = Scenario(name: "camback\(Int(back))-real",
                             summary: "natural shooting 3.5–6.5 m, camera \(Int(back)) m (±0.2) behind the release",
                             worldKey: "camsweep")
            s.placement = .behindShooter(back: (back - 0.2)...(back + 0.2), height: 1.2...1.5)
            s.distance = 3.5...6.5
            list.append(s)
        }

        // Streams without shots: everything the tracker calls is a phantom.
        func idle(_ name: String, _ summary: String, _ c: Choreography, partner: Bool = false,
                  noise: NoiseLevel = .realistic, key: String? = nil) -> Scenario {
            var s = Scenario(name: name, summary: summary, worldKey: key ?? name, noise: noise)
            s.choreography = c
            s.partner = partner
            s.shotsPerSession = 10
            return s
        }
        list.append(idle("dribble-real", "dribbling, walking with the ball, holding, slams (no shots)", .dribbleOnly, key: "dribble"))
        list.append(idle("dribble-harsh", "dribbling, walking with the ball, holding, slams (no shots)", .dribbleOnly,
                         noise: .harsh, key: "dribble"))
        list.append(idle("pass-real", "two players passing: chest, bounce and lob passes (no shots)", .passOnly,
                         partner: true, key: "pass"))
        list.append(idle("pass-harsh", "two players passing: chest, bounce and lob passes (no shots)", .passOnly,
                         partner: true, noise: .harsh, key: "pass"))
        list.append(idle("pumpfake-real", "jab steps and pump fakes, never shooting", .pumpFakesOnly))
        list.append(idle("rebound-real", "under the hoop: slams, self-tosses, dribbles, loose balls", .reboundOnly(glassTosses: false)))
        list.append(idle("glasstoss-real", "tosses off the glass under the hoop (rebound drill)", .reboundOnly(glassTosses: true)))
        return list
    }()

    static func named(_ name: String) -> Scenario? { all.first { $0.name == name } }

    /// Scenarios matching a comma-separated list of names or `*` patterns.
    static func matching(_ pattern: String) -> [Scenario] {
        let parts = pattern.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        return all.filter { s in parts.contains { glob($0, s.name) } }
    }

    private static func glob(_ pattern: String, _ name: String) -> Bool {
        if pattern == "all" { return true }
        guard pattern.contains("*") else { return pattern == name }
        let pieces = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = Substring(name)
        for (k, piece) in pieces.enumerated() {
            if piece.isEmpty { continue }
            if k == 0 {
                guard rest.hasPrefix(piece) else { return false }
                rest = rest.dropFirst(piece.count)
            } else if k == pieces.count - 1 {
                return rest.hasSuffix(piece)
            } else {
                guard let r = rest.range(of: piece) else { return false }
                rest = rest[r.upperBound...]
            }
        }
        return true
    }
}

/// One fixed-camera stretch of a scenario's stream.
struct SessionConfig: Sendable {
    var choreography: Choreography
    var shots: Int
    var spot: Vec3
    /// Release distance from the rim centre.
    var distance: ClosedRange<Double>
    /// Where the shooter stands between shots (a layup drive starts further out).
    var spotDistance: ClosedRange<Double>
    var placement: CameraPlacement
    var cameraPosition: Vec3
    var captureFPS: Double
    var net: NetKind
    var partner: Bool
    var partnerSpot: Vec3
    var secondShooterSpot: Vec3?
    var secondHoop: Vec3?
    var spareBall: Vec3?
    var releaseHeight: ClosedRange<Double>
    var layupReleaseHeight: ClosedRange<Double> = 2.5...2.9
    var layups: Bool
    var skill: ShooterSkill
    var mix: ShotMix
    var dribbleChance: Double
    var pumpFakeChance: Double
    var jabChance: Double

    func kind(for rng: inout SimRNG) -> ShotKind? {
        switch mix {
        case .natural: return nil
        case .only(let k): return k
        }
    }
}

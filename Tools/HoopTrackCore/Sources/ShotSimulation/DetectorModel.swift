// DetectorModel.swift
// A stand-in for CoreMLBallDetector: given what's really in front of the
// camera, the boxes a YOLO-style detector would plausibly return. Every
// way it goes wrong is an explicit knob with a default that's meant to be
// realistic for the shipped model on a phone (see `realistic`), plus a
// `clean` (perfect detector) and a `harsh` (dim gym, worse model) preset.

import Foundation
@testable import HoopTrack

struct DetectorNoise: Sendable {

    // MARK: Ball boxes

    /// Box-centre error, 1 SD per axis, as a fraction of the box size.
    /// YOLO boxes on a moving ball wobble a few per cent of their size.
    var centreJitter = 0.04
    /// Box-size error, 1 SD, relative.
    var sizeJitter = 0.06
    /// Shutter time, seconds. Motion blur stretches the box along the
    /// image velocity by speed × exposure. Indoors at 60 fps the phone runs
    /// 1/60–1/250 s; 1/120 is a reasonably lit gym.
    var exposure = 1.0 / 120

    // MARK: Ball misses

    /// Miss probability for a big, sharp, fully visible ball.
    var baseMiss = 0.03
    /// Apparent ball diameter in model-input pixels (the frame letterboxed to
    /// 640, or the crop scaled to 640) at which half the balls are missed;
    /// 0 = size never matters. Detectors trained at 1280 and run at 640
    /// struggle below ~8 px.
    var halfDetectSize = 6.0
    /// How sharply detection falls off below that size.
    var sizeSteepness = 4.0
    /// Blur penalty: detection probability × exp(−blurPenalty · max(0, streak/diameter − 0.4)).
    var blurPenalty = 0.6
    /// Visible fraction (after heads, bodies, raised arms, the net, the
    /// board and the frame edge) at which half the balls are missed.
    var halfVisible = 0.5
    /// Frame-to-frame correlation of misses (0 = independent). Real misses
    /// come in runs: the ball is behind something or blurred for a while.
    var missCorrelation = 0.6
    /// Extra miss probability through a glass backboard (glare, reflections).
    var glassPenalty = 0.1

    // MARK: Confidence

    /// Detector score for a clear ball; small, blurred or half-hidden balls
    /// score lower. Never below the app's 0.30 threshold (those are misses).
    var confidenceMean = 0.72
    var confidenceSD = 0.12

    // MARK: False positives
    // Each source flickers on and off as a Markov chain; `…Rate` is the
    // long-run fraction of frames it's reported as a ball, runs last
    // `falsePositiveFrames` frames on average.

    /// Heads (round, ball-sized, often dark).
    var headRate = 0.004
    /// Shoes (white or orange trainers).
    var shoeRate = 0.002
    /// Static clutter: a light, a sign, a ball rack in the background.
    var clutterRate = 0.003
    var clutterSpots = 1
    var falsePositiveFrames = 3.0

    // MARK: Hoop

    /// Rim box centre and size error, 1 SD, fraction of the box size.
    var hoopJitter = 0.012
    /// Per-frame chance the basket isn't found.
    var hoopMiss = 0.02
    /// Extra miss chance when the ball (or a person) covers the basket.
    var hoopMissWhenCovered = 0.25
    var hoopConfidenceMean = 0.85
    /// The current model was trained on "rim" and "hoop" boxes mixed: the
    /// long-run fraction of frames where the box is the ring alone instead
    /// of ring plus net, and how persistent that is frame to frame.
    var rimOnlyRate = 0.0
    var rimOnlyPersistence = 0.9
    /// A second basket in view (another court).
    var secondBasket = false
    var secondBasketConfidence = 0.62

    // MARK: Pipeline

    /// Frames lost to processing hiccups (never logged at all).
    var frameDropRate = 0.002
    /// Net luma noise and flicker.
    var sensor = NetSensor()

    // MARK: Presets

    /// A perfect detector: every visible ball, exact boxes, no false
    /// positives. Occlusion still applies (a ball fully behind a head can't
    /// be seen), and so does the frame edge.
    static let clean: DetectorNoise = {
        var n = DetectorNoise()
        n.centreJitter = 0.005
        n.sizeJitter = 0.005
        n.exposure = 1.0 / 1000
        n.baseMiss = 0
        n.halfDetectSize = 0
        n.blurPenalty = 0
        n.halfVisible = 0.3
        n.missCorrelation = 0
        n.glassPenalty = 0
        n.confidenceSD = 0.02
        n.headRate = 0
        n.shoeRate = 0
        n.clutterRate = 0
        n.hoopJitter = 0.002
        n.hoopMiss = 0
        n.hoopMissWhenCovered = 0
        n.frameDropRate = 0
        n.sensor = NetSensor(noise: 0.7, flicker: 0, flickerHz: 20)
        return n
    }()

    /// The shipped model on a phone in a reasonably lit gym.
    static let realistic = DetectorNoise()

    /// Dim gym or dusk outdoors, a weaker model, a second hoop in view.
    static let harsh: DetectorNoise = {
        var n = DetectorNoise()
        n.centreJitter = 0.08
        n.sizeJitter = 0.12
        n.exposure = 1.0 / 60
        n.baseMiss = 0.08
        n.halfDetectSize = 9
        n.blurPenalty = 0.9
        n.halfVisible = 0.6
        n.missCorrelation = 0.75
        n.glassPenalty = 0.2
        n.confidenceMean = 0.6
        n.confidenceSD = 0.15
        n.headRate = 0.015
        n.shoeRate = 0.008
        n.clutterRate = 0.02
        n.clutterSpots = 2
        n.falsePositiveFrames = 4
        n.hoopJitter = 0.025
        n.hoopMiss = 0.08
        n.hoopMissWhenCovered = 0.4
        n.hoopConfidenceMean = 0.75
        n.secondBasket = true
        n.frameDropRate = 0.01
        n.sensor = NetSensor(noise: 3.0, flicker: 0.012, flickerHz: 20)
        return n
    }()
}

/// Where a reported ball box came from.
enum DetectionSource: Equatable, Sendable, CustomStringConvertible {
    case ball(Int)
    case head(Int)
    case shoe(Int)
    case clutter(Int)

    var description: String {
        switch self {
        case .ball(let i): return "ball\(i)"
        case .head(let i): return "head\(i)"
        case .shoe(let i): return "shoe\(i)"
        case .clutter(let i): return "clutter\(i)"
        }
    }
}

struct Detection: Sendable {
    var box: Box
    var confidence: Double
    var source: DetectionSource
}

/// Why a ball wasn't reported (or that it was), for traces.
enum BallStatus: String, Sendable {
    case detected, offscreen, outsideCrop, hidden, small, blurred, missed
}

struct BallView: Sendable {
    let id: Int
    /// True (sharp) box, unclipped.
    let box: Box
    let diameterPx: Double
    let visible: Double
    let status: BallStatus
    /// What hid it most, when it was hidden.
    let hiddenBy: String?
    /// Where it really was, court coordinates.
    let world: Vec3
    let inNet: Bool
}

struct SceneDetections: Sendable {
    var balls: [Detection]
    var baskets: [Detection]
    var views: [BallView]
}

struct DetectorModel {
    var noise: DetectorNoise
    let camera: CameraRig
    var rng: SimRNG
    let secondHoop: Vec3?
    private var latent: [Int: Double] = [:]
    private var falsePositiveOn: [String: Bool] = [:]
    private var clutter: [(x: Double, y: Double, size: Double)] = []
    private var rimOnly = false

    init(noise: DetectorNoise, camera: CameraRig, secondHoop: Vec3?, rng: SimRNG) {
        self.noise = noise
        self.camera = camera
        self.secondHoop = secondHoop
        self.rng = rng
        for _ in 0..<(noise.clutterRate > 0 ? noise.clutterSpots : 0) {
            clutter.append((self.rng.uniform(0.05, 0.95), self.rng.uniform(0.35, 0.97), self.rng.uniform(0.012, 0.03)))
        }
    }

    /// Steps a false-positive source's on/off chain; true when it fires.
    private mutating func flicker(_ key: String, rate: Double) -> Bool {
        guard rate > 0 else { return false }
        let on = falsePositiveOn[key] ?? false
        let off = 1 / max(1, noise.falsePositiveFrames)
        let start = min(1, rate * off / max(1e-9, 1 - rate))
        let next = on ? !rng.chance(off) : rng.chance(start)
        falsePositiveOn[key] = next
        return next
    }

    /// Model-input pixels per camera pixel: the frame is letterboxed into
    /// 640 × 640 (×0.5 for 1280 wide), a crop is scaled to 640.
    private func inputScale(region: Box?) -> Double {
        guard let region else { return 640 / max(camera.pixelWidth, camera.pixelHeight) }
        return 640 / (region.width * camera.pixelWidth)
    }

    /// Fraction of `box` hidden by things nearer the camera than `depth`.
    private func occlusion(of box: Box, depth: Double, ball: BallSnapshot?, world: WorldSnapshot)
        -> (visible: Double, by: String?, glass: Bool) {
        var visible = box.coveredFraction(by: .unit)
        var worst = (0.0, nil as String?)
        if visible < 0.999 { worst = (1 - visible, "frame edge") }
        for person in world.people {
            for part in Silhouette.parts(of: person, camera: camera) where part.depth < depth - 0.15 {
                let covered = box.coveredFraction(by: part.box) * part.opacity
                if covered > 0 {
                    visible *= 1 - covered
                    if covered > worst.0 { worst = (covered, part.isHead ? "head\(person.id)" : "body\(person.id)") }
                }
            }
        }
        var glass = false
        if let ball {
            // The net: cords in front of a ball inside or behind it.
            if let netBox = camera.hoopBox(withNet: true, netOffset: world.netOffset),
               let rimDepth = camera.project(Court.rimCentre)?.depth, ball.inNet || depth > rimDepth - 0.1 {
                let ringOnly = camera.hoopBox(withNet: false) ?? netBox
                let netOnly = Box(minX: netBox.minX, minY: netBox.minY, width: netBox.width,
                                  height: max(0, ringOnly.midY - netBox.minY))
                let covered = box.coveredFraction(by: netOnly) * (ball.inNet ? 0.4 : 0.3)
                if covered > 0 {
                    visible *= 1 - covered
                    if covered > worst.0 { worst = (covered, "net") }
                }
            }
            // The backboard: is it between the lens and the ball?
            let from = camera.position, to = ball.p
            if (from.z - Court.boardZ) * (to.z - Court.boardZ) < 0 {
                let f = (Court.boardZ - from.z) / (to.z - from.z)
                let hit = from + (to - from) * f
                if abs(hit.x) < Court.boardWidth / 2, hit.y > Court.boardBottom, hit.y < Court.boardTop {
                    glass = true
                    visible *= 0.9
                }
            }
        }
        return (visible, worst.1, glass)
    }

    mutating func detect(world: WorldSnapshot, region: Box?) -> SceneDetections {
        var balls: [Detection] = []
        var views: [BallView] = []
        let scale = inputScale(region: region)
        let area = region ?? .unit

        for b in world.balls {
            guard let img = camera.ball(at: b.p, velocity: b.v) else {
                views.append(BallView(id: b.id, box: Box(minX: -1, minY: -1, width: 0, height: 0), diameterPx: 0,
                                      visible: 0, status: .offscreen, hiddenBy: "behind camera", world: b.p, inNet: b.inNet))
                continue
            }
            let streakX = abs(img.velocityX) * noise.exposure, streakY = abs(img.velocityY) * noise.exposure
            let wPx = img.diameterPx + streakX, hPx = img.diameterPx + streakY
            let trueBox = Box(centreX: img.x, centreY: img.y, width: wPx / camera.pixelWidth, height: hPx / camera.pixelHeight)
            let occ = occlusion(of: trueBox, depth: img.depth, ball: b, world: world)

            // Correlated miss process.
            let rho = noise.missCorrelation
            let z = rho * (latent[b.id] ?? rng.gaussian()) + (1 - rho * rho).squareRoot() * rng.gaussian()
            latent[b.id] = z
            let u = normalCDF(z)

            let inputSize = img.diameterPx * scale
            let pSize = noise.halfDetectSize > 0 ? 1 / (1 + pow(noise.halfDetectSize / max(inputSize, 0.1), noise.sizeSteepness)) : 1
            let streak = (streakX * streakX + streakY * streakY).squareRoot()
            let pBlur = exp(-noise.blurPenalty * max(0, streak / max(img.diameterPx, 1) - 0.4))
            let pVisible = smoothStep(noise.halfVisible - 0.2, noise.halfVisible + 0.2, occ.visible)
            let p = (1 - noise.baseMiss) * pSize * pBlur * pVisible * (occ.glass ? 1 - noise.glassPenalty : 1)

            var status = BallStatus.detected
            if trueBox.coveredFraction(by: .unit) < 0.4 || img.x < 0 || img.x > 1 || img.y < 0 || img.y > 1 {
                status = .offscreen
            } else if !area.contains(x: img.x, y: img.y) || trueBox.coveredFraction(by: area) < 0.4 {
                status = .outsideCrop
            } else if u >= p {
                if pVisible < 0.5 { status = .hidden }
                else if pSize < 0.5 { status = .small }
                else if pBlur < 0.5 { status = .blurred }
                else { status = .missed }
            }
            views.append(BallView(id: b.id, box: trueBox, diameterPx: img.diameterPx, visible: occ.visible,
                                  status: status, hiddenBy: occ.by, world: b.p, inNet: b.inNet))
            guard status == .detected else { continue }

            let size = max(wPx, hPx)
            let common = rng.gaussian(0, noise.sizeJitter * 0.8)
            let w = max(2, wPx * (1 + common + rng.gaussian(0, noise.sizeJitter * 0.6)))
            let h = max(2, hPx * (1 + common + rng.gaussian(0, noise.sizeJitter * 0.6)))
            let cx = img.x + rng.gaussian(0, noise.centreJitter * size) / camera.pixelWidth
            let cy = img.y + rng.gaussian(0, noise.centreJitter * size) / camera.pixelHeight
            var box = Box(centreX: cx, centreY: cy, width: w / camera.pixelWidth, height: h / camera.pixelHeight)
            box = box.intersection(area) ?? box
            let quality = pSize * pBlur * pVisible
            let confidence = clampValue(rng.gaussian(noise.confidenceMean, noise.confidenceSD) * (0.6 + 0.4 * quality), 0.3, 0.99)
            balls.append(Detection(box: box, confidence: confidence, source: .ball(b.id)))
        }

        // False positives.
        for person in world.people {
            let parts = Silhouette.parts(of: person, camera: camera)
            if flicker("head\(person.id)", rate: noise.headRate), let head = parts.first(where: \.isHead) {
                let side = min(head.box.width * camera.pixelWidth, head.box.height * camera.pixelHeight * 0.8)
                let box = Box(centreX: head.box.midX + rng.gaussian(0, 0.08) * head.box.width,
                              centreY: head.box.maxY - side / 2 / camera.pixelHeight,
                              width: side / camera.pixelWidth, height: side / camera.pixelHeight)
                if area.contains(x: box.midX, y: box.midY) {
                    balls.append(Detection(box: box, confidence: rng.uniform(0.3, 0.5), source: .head(person.id)))
                }
            }
            if flicker("shoe\(person.id)", rate: noise.shoeRate),
               let shoe = camera.uprightBox(base: person.position + person.facing * 0.1 + person.side * 0.12, width: 0.15,
                                            bottom: person.lift, top: person.lift + 0.13) {
                if area.contains(x: shoe.midX, y: shoe.midY), shoe.coveredFraction(by: .unit) > 0.5 {
                    balls.append(Detection(box: shoe, confidence: rng.uniform(0.3, 0.45), source: .shoe(person.id)))
                }
            }
        }
        for (k, spot) in clutter.enumerated() where flicker("clutter\(k)", rate: noise.clutterRate) {
            let box = Box(centreX: spot.x + rng.gaussian(0, 0.001), centreY: spot.y + rng.gaussian(0, 0.002),
                          width: spot.size, height: spot.size * camera.aspect)
            if area.contains(x: box.midX, y: box.midY) {
                balls.append(Detection(box: box, confidence: rng.uniform(0.3, 0.5), source: .clutter(k)))
            }
        }
        // Vision scores are Floats, compared against Float thresholds.
        for k in balls.indices {
            balls[k].confidence = Double(max(Float(balls[k].confidence), HoopTrack.CV.ballConfidence))
        }
        balls.sort { $0.confidence > $1.confidence }
        if balls.count > 4 { balls = Array(balls.prefix(4)) }

        return SceneDetections(balls: balls, baskets: detectBaskets(world: world, region: area), views: views)
    }

    private mutating func detectBaskets(world: WorldSnapshot, region: Box) -> [Detection] {
        var baskets: [Detection] = []
        if noise.rimOnlyRate > 0 {
            let stay = noise.rimOnlyPersistence
            let enter = min(1, noise.rimOnlyRate * (1 - stay) / max(1e-9, 1 - noise.rimOnlyRate))
            rimOnly = rimOnly ? rng.chance(stay) : rng.chance(enter)
        }
        if let truth = camera.hoopBox(withNet: !rimOnly, netOffset: world.netOffset) {
            // A ball or a person in front of the basket makes it harder to find.
            var covered = 0.0
            for b in world.balls {
                if let img = camera.ball(at: b.p, velocity: b.v) {
                    let d = img.diameterPx
                    let ballBox = Box(centreX: img.x, centreY: img.y, width: d / camera.pixelWidth, height: d / camera.pixelHeight)
                    covered = max(covered, truth.coveredFraction(by: ballBox))
                }
            }
            for person in world.people {
                for part in Silhouette.parts(of: person, camera: camera) {
                    covered = max(covered, truth.coveredFraction(by: part.box) * part.opacity)
                }
            }
            let miss = noise.hoopMiss + noise.hoopMissWhenCovered * min(1, covered * 2)
            if !rng.chance(miss) {
                let j = noise.hoopJitter
                let w = truth.width * (1 + rng.gaussian(0, j)), h = truth.height * (1 + rng.gaussian(0, j))
                let box = Box(centreX: truth.midX + rng.gaussian(0, j) * truth.width,
                              centreY: truth.midY + rng.gaussian(0, j) * truth.height, width: w, height: h)
                let confidence = clampValue(rng.gaussian(noise.hoopConfidenceMean, 0.06), 0.45, 0.99)
                baskets.append(Detection(box: box, confidence: confidence, source: .ball(-1)))
            }
        }
        if noise.secondBasket, let hoop = secondHoop, let truth = camera.hoopBox(centre: hoop, withNet: true),
           truth.coveredFraction(by: .unit) > 0.8, !rng.chance(0.1) {
            let confidence = rng.gaussian(noise.secondBasketConfidence, 0.1)
            if Float(confidence) >= HoopTrack.CV.hoopConfidence {
                let j = noise.hoopJitter * 1.5
                baskets.append(Detection(box: Box(centreX: truth.midX + rng.gaussian(0, j) * truth.width,
                                                  centreY: truth.midY + rng.gaussian(0, j) * truth.height,
                                                  width: truth.width, height: truth.height),
                                         confidence: min(0.99, confidence), source: .ball(-2)))
            }
        }
        _ = region
        for k in baskets.indices {
            baskets[k].confidence = Double(max(Float(baskets[k].confidence), HoopTrack.CV.hoopConfidence))
        }
        baskets.sort { $0.confidence > $1.confidence }
        return Array(baskets.prefix(3))
    }
}

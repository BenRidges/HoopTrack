// ShotTracker.swift
// Pure make/miss state machine over per-frame detections. No Vision, no
// AVFoundation — feed it boxes and timestamps, get shot events back. This
// is what CVPipeline runs on the camera queue, and what the unit tests
// drive with synthetic trajectories.
//
// Coordinates are Vision-normalised (origin bottom-left, y up). Distances
// are measured in "rim units" (the rim's apparent diameter) so thresholds
// hold whether the hoop is near or far.
//
// The model:
//   idle ──(any ball rising fast at/above rim height)──▶ inFlight
//   inFlight ──(drops through rim height inside the rim)──▶ atRim
//   inFlight ──(drops through rim height outside it)──▶ MISS
//   atRim ──(falls out the bottom of the net / vanishes in it)──▶ MAKE
//   atRim ──(pops back up)──▶ inFlight   (rim bounce — may still drop)
//   atRim ──(leaves the rim sideways)──▶ MISS
//   any  ──(timeout / lost)──▶ best guess, flagged low confidence
//
// From release on, a BallFilter (Kalman) predicts each frame's position and
// decides which detection is the shot ball.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

nonisolated struct ShotTracker: Sendable {

    // MARK: Output

    struct Release: Sendable, Equatable {
        /// Ball box at the moment of release (peak upward speed).
        let box: CGRect
        let time: Double
        /// Median apparent ball diameter just after release, in image-width units.
        let ballDiameter: Double
    }

    struct Outcome: Sendable, Equatable {
        let result: ShotResult
        /// 0–1. Below `HoopTrack.CV.lowConfidence` the summary asks the user to check it.
        let confidence: Double
        let release: Release
        /// Time the ball dropped through rim height, if seen. Used for arc.
        let rimArrivalTime: Double?
        let hoop: CGRect
        /// When the shot ball was last detected. For a lost ball, roughly
        /// when it reached the rim.
        let lastSeenTime: Double
    }

    enum Event: Sendable, Equatable {
        case started(Release)
        case resolved(Outcome)
    }

    // MARK: Tuning

    struct Tuning: Sendable {
        /// Minimum upward speed to start a shot, rim diameters per second.
        var minRiseSpeed: Double = 2.0
        /// Minimum total rise of the run before it counts, rim diameters.
        var minRise: Double = 1.5
        /// How far below the rim line the ball may be when the shot starts.
        var startBelowRimTolerance: Double = 0.75
        /// Half-width of the "through the rim" column as a fraction of rim width.
        var columnHalfWidth: Double = 0.55
        /// Shot gives up after this long without resolving.
        var flightTimeout: Double = 3.5
        /// Ball unseen this long ends the shot early.
        var lostTimeout: Double = 0.9
        /// After dropping into the rim, no bounce for this long counts as a make.
        var settleTime: Double = 0.45
        /// Ignore new shots for this long after a resolution.
        var cooldown: Double = 0.6
        /// Max jump between frames for the tracked ball, rim diameters.
        var gate: Double = 4.0
        /// A detection further than this many standard deviations from the
        /// ball filter's prediction is a different ball.
        var gateSigma: Double = 5.0
        /// Ball boxes bigger than this many rim widths are false positives.
        var maxBallToRim: Double = 1.6

        // Shot start — which boxes may start a shot (see `startable`).
        /// A box at least this much wider than tall (in pixels) that sits
        /// on the hoop is the rim, not a ball. A ball is round: blur only
        /// stretches it along its path, which near the rim is mostly
        /// vertical. On the 4 real clips (2026-11) the detector's
        /// rim-as-ball boxes run 1.6–2.2:1; real balls away from the rim
        /// median 1.15–1.3:1 (the model draws balls slightly wide).
        var rimShapedAspect: Double = 1.4
        /// …and at least this many rim widths wide. A ball at the rim's
        /// depth is about 0.49 rim widths (0.239 m ball / 0.489 m ring),
        /// about 0.6 with the model's wide boxes; the rim-as-ball boxes
        /// on the real clips are 0.75–1.0.
        var rimShapedMinWidth: Double = 0.7
        /// Between shots, ball boxes up to this many rim widths are tracked.
        /// Ball / rim box width is 0.49 × (rim distance / ball distance),
        /// so with the phone 1–2 m behind the shooter the ball at release
        /// is 1.5–2.5 rim widths: dropping it at `maxBallToRim` cut off the
        /// start of its rise, and perspective flattens the rest. 3.0 keeps
        /// a ball down to 0.16 of the rim's distance from the lens (~1.1 m
        /// for a rim 7 m away). A shot still only starts once its ball is
        /// back under `maxBallToRim`, i.e. flying away from the lens:
        /// lifting the ball to the set point or a pump fake that close
        /// rises just as far in the image but doesn't move away.
        var maxBallToRimIdle: Double = 3.0
        /// Fastest a basketball moves on court, m/s: a long three leaves the
        /// hand at ~9 m/s, a hard pass at 10–12. Between shots a track may
        /// only link boxes this speed apart (see `canLink`).
        var maxBallSpeed: Double = 13
        /// Slack per link, ball diameters: box centres jitter by a few % of
        /// the box, and blur moves the centre by up to half the streak.
        var linkSlack: Double = 0.5
        /// A rising run must rise at least this share of `minRise` outside
        /// its biggest single step, so one link between two different
        /// things (a ball lost for a frame as a false positive shows up
        /// higher) can't make the whole rise.
        var minRiseOutsideJump: Double = 0.5
    }

    var tuning = Tuning()

    // MARK: State

    private struct Sample: Sendable {
        let box: CGRect
        let time: Double
        var x: Double { Double(box.midX) }
        var y: Double { Double(box.midY) }
    }

    private enum Phase: Sendable {
        case idle
        case inFlight(Release)
        case atRim(Release, since: Double, arrival: Double)
    }

    private var phase: Phase = .idle
    private var history: [Sample] = []           // the shot ball's samples, oldest first
    /// Between shots: one short track per ball in view, so any of them can
    /// start a shot (the old "follow the highest ball" missed shots whenever
    /// another ball was higher in frame).
    private var candidates: [[Sample]] = []
    private var lastSeen: Double = -.infinity
    private var cooldownUntil: Double = -.infinity
    private var reachedApex = false
    /// Follows the ball from release until the shot resolves.
    private var filter: BallFilter?
    /// The rim box at release, used until the shot resolves.
    private var shotHoop: CGRect?

    /// Image aspect ratio (width / height). Converts width-normalised sizes
    /// into height-normalised units for vertical thresholds.
    let aspect: Double

    init(aspect: Double = 16.0 / 9.0, tuning: Tuning = Tuning()) {
        self.aspect = aspect
        self.tuning = tuning
    }

    var isTrackingShot: Bool {
        if case .idle = phase { return false }
        return true
    }

    /// The rim box held for the shot in flight, nil between shots.
    var lockedHoop: CGRect? { shotHoop }

    /// The shot ball's last box while a shot is in flight, nil between shots.
    /// CVPipeline crops detection around this and the hoop.
    var shotBallBox: CGRect? {
        isTrackingShot ? history.last?.box : nil
    }

    mutating func reset() {
        phase = .idle
        history = []
        candidates = []
        lastSeen = -.infinity
        cooldownUntil = -.infinity
        reachedApex = false
        filter = nil
        shotHoop = nil
    }

    // MARK: Per-frame update

    /// Feed one frame. `balls` are all ball candidates this frame (any order);
    /// `hoop` is the smoothed rim box, nil when no rim has been seen.
    mutating func update(balls: [CGRect], hoop liveHoop: CGRect?, time: Double) -> Event? {
        // During a shot the rim is held where it was at release: the ball
        // passing through the net makes the detected box jump about, which
        // would move the make line mid-shot. The phone is on a stand, so the
        // real rim doesn't move.
        guard let hoop = shotHoop ?? liveHoop, hoop.width > 0, hoop.height > 0 else { return nil }

        let rimUnitY = Double(hoop.width) * aspect           // rim diameter, height units
        let rimLine = Double(hoop.maxY) - 0.15 * Double(hoop.height)
        let plausible = balls.filter { Double($0.width) <= tuning.maxBallToRim * Double(hoop.width) }

        if case .idle = phase {
            associate(startable(balls, hoop: hoop), rimUnitY: rimUnitY, time: time)
        } else if let ball = pick(from: plausible, rimUnitY: rimUnitY, time: time) {
            history.append(Sample(box: ball, time: time))
            lastSeen = time
            let measured = point(ball)
            filter?.update(with: measured, at: time)
        }
        history.removeAll { time - $0.time > 1.5 }

        switch phase {
        case .idle:
            for track in candidates {
                if let event = tryStart(track: track, rimLine: rimLine, rimUnitY: rimUnitY, time: time) {
                    shotHoop = hoop
                    return event
                }
            }
            return nil

        case .inFlight(let release):
            return advanceFlight(release: release, hoop: hoop, rimLine: rimLine,
                                 rimUnitY: rimUnitY, time: time)

        case .atRim(let release, let since, let arrival):
            return advanceAtRim(release: release, since: since, arrival: arrival,
                                hoop: hoop, rimLine: rimLine, rimUnitY: rimUnitY, time: time)
        }
    }

    // MARK: Ball association

    /// Between shots: the ball boxes that could be a ball about to be shot.
    private func startable(_ balls: [CGRect], hoop: CGRect) -> [CGRect] {
        balls.filter { box in
            Double(box.width) <= tuning.maxBallToRimIdle * Double(hoop.width) && !isRimShaped(box, hoop: hoop)
        }
    }

    /// The detector sometimes labels the rim itself "ball": a box about
    /// as wide as the rim, half as tall, sitting on it. Tracked between
    /// shots it chains onto a real ball as a fast "rise" and starts a
    /// phantom shot, which then holds the tracker through the real one.
    func isRimShaped(_ box: CGRect, hoop: CGRect) -> Bool {
        guard box.width > 0, box.height > 0, hoop.width > 0 else { return false }
        // Mostly on the hoop box.
        let overlapW = min(box.maxX, hoop.maxX) - max(box.minX, hoop.minX)
        let overlapH = min(box.maxY, hoop.maxY) - max(box.minY, hoop.minY)
        guard overlapW > 0, overlapH > 0,
              Double(overlapW * overlapH) >= 0.5 * Double(box.width * box.height) else { return false }
        let pixelAspect = Double(box.width) * aspect / Double(box.height)
        return pixelAspect >= tuning.rimShapedAspect
            && Double(box.width) >= tuning.rimShapedMinWidth * Double(hoop.width)
    }

    /// Between shots: extends each track with its nearest ball (closest pairs
    /// first), starts new tracks for the rest, drops tracks that went quiet.
    private mutating func associate(_ balls: [CGRect], rimUnitY: Double, time: Double) {
        var pairs: [(track: Int, ball: Int, distance: Double)] = []
        for (t, track) in candidates.enumerated() {
            guard let last = track.last else { continue }
            let limit = tuning.gate * rimUnitY * max(1, (time - last.time) * 30)
            for (b, ball) in balls.enumerated() {
                let d = distance(from: last, to: ball)
                if d <= limit, canLink(last, to: ball, dt: time - last.time) { pairs.append((t, b, d)) }
            }
        }
        pairs.sort { $0.distance < $1.distance }
        var usedTracks = Set<Int>(), usedBalls = Set<Int>()
        for pair in pairs where !usedTracks.contains(pair.track) && !usedBalls.contains(pair.ball) {
            candidates[pair.track].append(Sample(box: balls[pair.ball], time: time))
            usedTracks.insert(pair.track)
            usedBalls.insert(pair.ball)
        }
        for (b, ball) in balls.enumerated() where !usedBalls.contains(b) {
            candidates.append([Sample(box: ball, time: time)])
        }
        if !balls.isEmpty { lastSeen = time }

        candidates = candidates
            .map { track in track.filter { time - $0.time <= 1.5 } }
            .filter { track in track.last.map { time - $0.time <= 0.25 } ?? false }
        if candidates.count > 6 {
            candidates = Array(candidates.sorted { $0.count > $1.count }.prefix(6))
        }
    }

    /// Between shots: could `box` be the ball last seen as `sample`, `dt`
    /// seconds later? Measured in the ball's own diameters, a sideways
    /// step doesn't depend on how far the ball is from the lens, so a
    /// speed limit in m/s is a limit in diameters per second. The rim
    /// gate alone allowed 4 rim widths a frame (~55 m/s at 30 fps) and
    /// grew without limit across gaps, so a ball low in the frame could
    /// link to a false positive near the rim as one fast "rise".
    /// (Box size isn't compared: the ball clipped by the frame edge
    /// changes size more than a different object does.)
    private func canLink(_ sample: Sample, to box: CGRect, dt: Double) -> Bool {
        let near = max(diameter(of: sample.box), diameter(of: box))
        guard near > 0, dt >= 0 else { return false }
        // Moving along the line of sight off-centre also shifts the image
        // (up to ~tan 34° of the depth change at the frame edge): ×1.25.
        let diametersPerSecond = 1.25 * tuning.maxBallSpeed / CourtPositionEstimator.ballDiameterM
        return distance(from: sample, to: box) <= near * (diametersPerSecond * dt + tuning.linkSlack)
    }

    /// Apparent ball diameter, height units: the shorter side, since blur
    /// stretches the box along the ball's path.
    private func diameter(of box: CGRect) -> Double {
        min(Double(box.width) * aspect, Double(box.height))
    }

    /// During a shot: the candidate the ball filter finds least surprising.
    /// Rejects implausible jumps so a second ball can't hijack the shot.
    private func pick(from balls: [CGRect], rimUnitY: Double, time: Double) -> CGRect? {
        guard !balls.isEmpty, let last = history.last else { return nil }
        // Hard cap on movement since the last sighting, whatever the filter says.
        let cap = tuning.gate * rimUnitY * max(1, (time - last.time) * 30)

        if let filter {
            let predicted = filter.predicted(at: time)
            let scored = balls.map { box -> (box: CGRect, surprise: Double, distance: Double) in
                let p = point(box)
                let dx = p.x - predicted.x, dy = p.y - predicted.y
                return (box, filter.surprise(of: p, at: time), (dx * dx + dy * dy).squareRoot())
            }
            guard let best = scored.min(by: { $0.surprise < $1.surprise }),
                  best.distance <= cap,
                  best.surprise <= tuning.gateSigma || best.distance <= 0.75 * rimUnitY else { return nil }
            return best.box
        }

        var predictedX = last.x
        var predictedY = last.y
        if history.count >= 2 {
            let prev = history[history.count - 2]
            let dt = last.time - prev.time
            if dt > 0 {
                let k = (time - last.time) / dt
                predictedX += (last.x - prev.x) * k
                predictedY += (last.y - prev.y) * k
            }
        }
        let limit = cap
        let scored = balls.map { box -> (CGRect, Double) in
            let dx = (Double(box.midX) - predictedX) * aspect
            let dy = Double(box.midY) - predictedY
            return (box, (dx * dx + dy * dy).squareRoot())
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }), best.1 <= limit else { return nil }
        return best.0
    }

    // MARK: Phases

    private mutating func tryStart(track: [Sample], rimLine: Double, rimUnitY: Double, time: Double) -> Event? {
        guard time >= cooldownUntil, let latest = track.last, latest.time == time else { return nil }

        // Walk back through the current rising run.
        var runStart = track.count - 1
        while runStart > 0 {
            let a = track[runStart - 1], b = track[runStart]
            if b.y < a.y - 0.05 * rimUnitY || b.time - a.time > 0.25 { break }
            runStart -= 1
        }
        let run = Array(track[runStart...])
        guard run.count >= 4 else { return nil }
        // Still nearer the lens than a ball in flight can be: not released
        // yet (see Tuning.maxBallToRimIdle).
        guard Double(latest.box.width) <= tuning.maxBallToRim * rimUnitY / aspect else { return nil }

        let rise = (latest.y - run[0].y) / rimUnitY
        let speed = upwardSpeed(at: run.count - 1, in: run) / rimUnitY
        let nearRimHeight = latest.y >= rimLine - tuning.startBelowRimTolerance * rimUnitY
        guard rise >= tuning.minRise, speed >= tuning.minRiseSpeed, nearRimHeight else { return nil }

        // The rise has to come from a ball moving, not from one link
        // between two things: outside its biggest step the run still rises.
        var biggestStep = 0.0
        for i in 1..<run.count { biggestStep = max(biggestStep, run[i].y - run[i - 1].y) }
        guard rise - biggestStep / rimUnitY >= tuning.minRiseOutsideJump * tuning.minRise else { return nil }

        // Release = fastest upward moment of the run (hands push until release,
        // gravity only slows it after) since the ball was last held: rising
        // slower than a shot starts, as at the set point. Close to the lens
        // the lift to the set point moves faster in the image than the
        // shot, and a release (and ball filter) taken there loses the ball.
        var firstAfterHold = 1
        for i in 1..<run.count where upwardSpeed(at: i, in: run) < tuning.minRiseSpeed * rimUnitY {
            firstAfterHold = i + 1
        }
        firstAfterHold = min(firstAfterHold, run.count - 1)
        var releaseIndex = firstAfterHold
        var fastest = -Double.infinity
        for i in firstAfterHold..<run.count {
            let v = upwardSpeed(at: i, in: run)
            if v > fastest { fastest = v; releaseIndex = i }
        }
        // The shorter side: motion blur stretches the box along the ball's
        // path (mostly upwards), which would make the ball look bigger and
        // so closer than it is.
        let afterRelease = run[releaseIndex...].prefix(5).map { sample -> Double in
            min(Double(sample.box.width), Double(sample.box.height) / aspect)
        }
        let release = Release(box: run[releaseIndex].box,
                              time: run[releaseIndex].time,
                              ballDiameter: Self.median(afterRelease))
        phase = .inFlight(release)
        reachedApex = false
        history = track
        candidates = []
        lastSeen = time
        filter = makeFilter(following: run[releaseIndex...], rimUnitY: rimUnitY)
        return .started(release)
    }

    private mutating func advanceFlight(release: Release, hoop: CGRect, rimLine: Double,
                                        rimUnitY: Double, time: Double) -> Event? {
        if time - release.time > tuning.flightTimeout {
            return finish(lostGuess(hoop: hoop, rimUnitY: rimUnitY), confidence: 0.3,
                          release: release, arrival: nil, hoop: hoop, time: time)
        }
        if time - lastSeen > tuning.lostTimeout {
            return finish(lostGuess(hoop: hoop, rimUnitY: rimUnitY), confidence: 0.35,
                          release: release, arrival: nil, hoop: hoop, time: time)
        }
        guard history.count >= 2, let cur = history.last, cur.time == time else { return nil }
        let prev = history[history.count - 2]
        guard prev.time >= release.time else { return nil }

        if cur.y < prev.y { reachedApex = true }
        guard reachedApex, prev.y > rimLine, cur.y <= rimLine else { return nil }

        // Dropped through rim height — where?
        let t = (prev.y - rimLine) / max(prev.y - cur.y, 1e-9)
        let crossX = prev.x + (cur.x - prev.x) * t
        let crossTime = prev.time + (cur.time - prev.time) * t
        let offset = abs(crossX - Double(hoop.midX)) / Double(hoop.width)

        if offset <= tuning.columnHalfWidth {
            phase = .atRim(release, since: time, arrival: crossTime)
            return nil
        }
        // Clear of the rim: an obvious miss when well outside, less sure when it grazed.
        let confidence = offset > 1.0 ? 0.9 : 0.65
        return finish(.miss, confidence: confidence, release: release,
                      arrival: crossTime, hoop: hoop, time: time)
    }

    private mutating func advanceAtRim(release: Release, since: Double, arrival: Double,
                                       hoop: CGRect, rimLine: Double, rimUnitY: Double,
                                       time: Double) -> Event? {
        let seenNow = history.last?.time == time
        if let cur = history.last, seenNow {
            let offset = abs(cur.x - Double(hoop.midX)) / Double(hoop.width)
            // Popped back up off the rim: keep watching, it may still drop.
            if cur.y > rimLine + 0.35 * rimUnitY {
                phase = .inFlight(release)
                reachedApex = false
                return nil
            }
            // Out the bottom of the net, still in the column.
            if cur.y < Double(hoop.minY), offset <= tuning.columnHalfWidth + 0.15 {
                return finish(.make, confidence: 0.95, release: release,
                              arrival: arrival, hoop: hoop, time: time)
            }
            // Kicked out sideways.
            if offset > 1.0 {
                return finish(.miss, confidence: 0.8, release: release,
                              arrival: arrival, hoop: hoop, time: time)
            }
        }
        // Nothing dramatic happened: it sat in the net (or the net hid it).
        if time - since >= tuning.settleTime {
            let confidence = seenNow ? 0.8 : 0.7
            return finish(.make, confidence: confidence, release: release,
                          arrival: arrival, hoop: hoop, time: time)
        }
        return nil
    }

    // MARK: Helpers

    /// Box centre in height units on both axes (x scaled by the aspect ratio).
    private func point(_ box: CGRect) -> BallFilter.Point {
        BallFilter.Point(x: Double(box.midX) * aspect, y: Double(box.midY))
    }

    /// A filter seeded from the release onwards. Noise scales with the rim,
    /// so it behaves the same whether the hoop is near or far.
    private func makeFilter(following samples: ArraySlice<Sample>, rimUnitY: Double) -> BallFilter? {
        guard let first = samples.first else { return nil }
        let last = samples.last ?? first
        let dt = last.time - first.time
        let velocity = dt > 0
            ? BallFilter.Point(x: (last.x - first.x) * aspect / dt, y: (last.y - first.y) / dt)
            : BallFilter.Point(x: 0, y: 0)
        var filter = BallFilter(at: point(first.box), velocity: velocity, time: first.time,
                                accelerationSD: 40 * rimUnitY,
                                measurementSD: 0.12 * rimUnitY,
                                initialVelocitySD: 30 * rimUnitY)
        for sample in samples.dropFirst() { filter.update(with: point(sample.box), at: sample.time) }
        return filter
    }

    /// Distance between a sample and a box centre, in height units.
    private func distance(from sample: Sample, to box: CGRect) -> Double {
        let dx = (Double(box.midX) - sample.x) * aspect
        let dy = Double(box.midY) - sample.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Best guess when the ball vanished: if it was last seen dropping onto
    /// the rim, assume it went in; otherwise call it a miss.
    private func lostGuess(hoop: CGRect, rimUnitY: Double) -> ShotResult {
        guard history.count >= 2 else { return .miss }
        let last = history[history.count - 1], prev = history[history.count - 2]
        let descending = last.y < prev.y
        let offset = abs(last.x - Double(hoop.midX)) / Double(hoop.width)
        let aboveRimClose = last.y >= Double(hoop.minY) && last.y <= Double(hoop.maxY) + 1.5 * rimUnitY
        return descending && offset <= tuning.columnHalfWidth && aboveRimClose ? .make : .miss
    }

    private mutating func finish(_ result: ShotResult, confidence: Double, release: Release,
                                 arrival: Double?, hoop: CGRect, time: Double) -> Event {
        phase = .idle
        reachedApex = false
        filter = nil
        shotHoop = nil
        cooldownUntil = time + tuning.cooldown
        let seen = lastSeen
        history.removeAll()
        candidates.removeAll()
        return .resolved(Outcome(result: result, confidence: confidence, release: release,
                                 rimArrivalTime: arrival, hoop: hoop, lastSeenTime: seen))
    }

    /// Upward speed (height units/s) at index `i`, smoothed over two steps.
    private func upwardSpeed(at i: Int, in run: [Sample]) -> Double {
        guard i > 0 else { return 0 }
        let j = max(0, i - 2)
        let dt = run[i].time - run[j].time
        guard dt > 0 else { return 0 }
        return (run[i].y - run[j].y) / dt
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

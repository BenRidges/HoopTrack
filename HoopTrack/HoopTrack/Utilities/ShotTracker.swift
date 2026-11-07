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
        /// What argued against the call although the picture looked clean.
        /// The net check (ShotEvidence.fuse) weighs these.
        var doubts: Doubts = []
    }

    /// Evidence against a call that the 2D picture alone would have made.
    struct Doubts: OptionSet, Sendable, Equatable {
        let rawValue: Int
        init(rawValue: Int) { self.rawValue = rawValue }

        /// At the rim the ball looked bigger than a ball at the rim's depth
        /// can: it was nearer the camera than the rim (dropping in front).
        static let tooBigForRim = Doubts(rawValue: 1 << 0)
        /// Its size stopped changing the way the flight had been changing
        /// it: it came back toward the camera (or, facing the shooter, went
        /// back out) before reaching the rim line, i.e. it bounced off the
        /// rim or board.
        static let cameBack = Doubts(rawValue: 1 << 1)

        /// Another ball was within about a rim width of the shot ball at
        /// the rim: the two can't be told apart by position, so the call
        /// may be about the other ball.
        static let secondBall = Doubts(rawValue: 1 << 2)

        /// The ball may not have been at the rim's depth at all.
        static let depth: Doubts = [.tooBigForRim, .cameBack]
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

        // Depth at the rim (the make decision). From one camera the rim's
        // column is a ray: a ball dropping in front of the rim (camera
        // behind the shooter) or beyond it (camera behind the board)
        // crosses the rim line inside the column and leaves below the net
        // box just like a make. Its apparent size is the only depth cue.

        /// Ball diameter over the rim box's width for a ball at the rim's
        /// depth: a 0.239 m ball in a 0.49 m ring (0.457 m inside plus the
        /// rod). The shipped detector measured 0.32–0.51 on the labelled
        /// real makes (2026-11 clips: its basket boxes are a little loose).
        var ballToRimAtRim: Double = 0.239 / 0.49
        /// A ball this much bigger than one at the rim's depth is in front
        /// of the rim. Box sizes jitter ~6% a frame; the median of the
        /// frames around the crossing is good to ~3%, so 10% is a ball
        /// clearly nearer the camera (0.7 m in front from 7 m away).
        var inFrontOfRim: Double = 1.10
        /// The flight has to change the ball's size by this factor (release
        /// over at the rim) before its size trend says which way it travels
        /// in depth: behind the shooter it shrinks all the way to the rim,
        /// facing the shooter it grows. Side-on there's no usable trend.
        /// 1.3 leaves the last 0.35 s of a make ≥ 2 noise widths from "no
        /// change".
        var depthTrend: Double = 1.3
        /// Size near the rim line over its size 0.2–0.5 s earlier at or
        /// past this (behind the shooter; the inverse facing it): the ball
        /// stopped moving away from the camera, so it bounced back off the
        /// rim or board.
        var cameBackGrowth: Double = 1.0
        /// A make out of the bottom of the net that the depth cues doubt.
        /// Under 0.9 so the net check sees it, over `HoopTrack.CV.lowConfidence`
        /// so it isn't flagged without the net's say.
        var doubtfulMakeConfidence: Double = 0.75

        // A second ball at the rim (two people shooting at one hoop).

        /// Another ball whose centre comes within this many rim widths of
        /// the shot ball's is close enough to be mistaken for it: two
        /// balls side by side are one ball diameter (~0.5 rim) apart.
        var secondBallRadius: Double = 1.0
        /// …while the shot ball is at the rim or in this many seconds before
        /// it drops through the rim line.
        var secondBallLookback: Double = 0.3
        /// Such a call is flagged: below `HoopTrack.CV.lowConfidence`.
        var secondBallConfidence: Double = 0.55
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
    /// Last time another ball was right next to the shot ball.
    private var secondBallTime: Double = -.infinity

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
        secondBallTime = -.infinity
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
            associate(plausible, rimUnitY: rimUnitY, time: time)
        } else if let ball = pick(from: plausible, rimUnitY: rimUnitY, time: time) {
            history.append(Sample(box: ball, time: time))
            lastSeen = time
            let measured = point(ball)
            filter?.update(with: measured, at: time)
        }
        if isTrackingShot { noteSecondBall(among: plausible, hoop: hoop, time: time) }
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

    /// Between shots: extends each track with its nearest ball (closest pairs
    /// first), starts new tracks for the rest, drops tracks that went quiet.
    private mutating func associate(_ balls: [CGRect], rimUnitY: Double, time: Double) {
        var pairs: [(track: Int, ball: Int, distance: Double)] = []
        for (t, track) in candidates.enumerated() {
            guard let last = track.last else { continue }
            let limit = tuning.gate * rimUnitY * max(1, (time - last.time) * 30)
            for (b, ball) in balls.enumerated() {
                let d = distance(from: last, to: ball)
                if d <= limit { pairs.append((t, b, d)) }
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

        let rise = (latest.y - run[0].y) / rimUnitY
        let speed = upwardSpeed(at: run.count - 1, in: run) / rimUnitY
        let nearRimHeight = latest.y >= rimLine - tuning.startBelowRimTolerance * rimUnitY
        guard rise >= tuning.minRise, speed >= tuning.minRiseSpeed, nearRimHeight else { return nil }

        // Release = fastest upward moment of the run (hands push until release,
        // gravity only slows it after).
        var releaseIndex = 0
        var fastest = -Double.infinity
        for i in 1..<run.count {
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
            // Out the bottom of the net, still in the column. Sure only if
            // the ball's size says it was at the rim's depth.
            if cur.y < Double(hoop.minY), offset <= tuning.columnHalfWidth + 0.15 {
                let doubts = depthDoubts(release: release, hoop: hoop, arrival: arrival, time: time)
                return finish(.make, confidence: doubts.isEmpty ? 0.95 : tuning.doubtfulMakeConfidence,
                              release: release, arrival: arrival, hoop: hoop, time: time, doubts: doubts)
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
            return finish(.make, confidence: confidence, release: release, arrival: arrival, hoop: hoop, time: time,
                          doubts: depthDoubts(release: release, hoop: hoop, arrival: arrival, time: time))
        }
        return nil
    }

    /// Depth cues for a ball the picture shows dropping through the rim
    /// (see Tuning, "Depth at the rim"). Box sizes are the shorter side,
    /// since motion blur stretches the box along the flight, and only boxes
    /// clear of the frame edge count: a box cut by the edge is smaller than
    /// the ball.
    private func depthDoubts(release: Release, hoop: CGRect, arrival: Double, time: Double) -> Doubts {
        let whole = history.filter { Self.isInsideFrame($0.box) }
        func size(from start: Double, to end: Double, atLeast count: Int) -> Double? {
            let sizes = whole.filter { $0.time >= start && $0.time <= end }.map { sample in
                min(Double(sample.box.width), Double(sample.box.height) / aspect)
            }
            return sizes.count >= count ? Self.median(sizes) : nil
        }
        // From just before the crossing through the net.
        guard let atRim = size(from: arrival - 0.15, to: time, atLeast: 1), atRim > 0 else { return [] }
        var doubts: Doubts = []
        if atRim > tuning.ballToRimAtRim * tuning.inFrontOfRim * Double(hoop.width) {
            doubts.insert(.tooBigForRim)
        }
        // How the size was changing just before the crossing, against the
        // way the whole flight changed it.
        let trend = release.ballDiameter / atRim
        if let near = size(from: arrival - 0.15, to: arrival + 0.05, atLeast: 2),
           let earlier = size(from: arrival - 0.5, to: arrival - 0.2, atLeast: 2) {
            let growth = near / earlier
            let awayFromCamera = trend >= tuning.depthTrend          // camera behind the shooter
            let towardCamera = trend <= 1 / tuning.depthTrend        // camera behind the board
            if (awayFromCamera && growth >= tuning.cameBackGrowth)
                || (towardCamera && growth <= 1 / tuning.cameBackGrowth) {
                doubts.insert(.cameBack)
            }
        }
        return doubts
    }

    /// During a shot: remembers when another ball was right next to the
    /// shot ball (see Tuning, "A second ball at the rim"). Boxes overlapping
    /// the shot ball are the same ball boxed twice; boxes much wider than
    /// tall are the rim taken for a ball (2026-11 clips: ~1.9:1, a ball's
    /// box is ~1:1 or taller with blur); a ball of a very different size is
    /// at a different depth. Only frames where the shot ball itself was
    /// picked count: otherwise a box near its last sighting is most likely
    /// the shot ball, moved on and turned down by the filter.
    private mutating func noteSecondBall(among balls: [CGRect], hoop: CGRect, time: Double) {
        func ballShaped(_ box: CGRect) -> Bool { Double(box.width) * aspect <= 1.4 * Double(box.height) }
        guard let shot = history.last, shot.time == time, ballShaped(shot.box) else { return }
        let shotSize = min(Double(shot.box.width), Double(shot.box.height) / aspect)
        guard shotSize > 0 else { return }
        for box in balls where box != shot.box && !box.intersects(shot.box) {
            let size = min(Double(box.width), Double(box.height) / aspect)
            guard ballShaped(box), size >= shotSize / 1.5, size <= shotSize * 1.5 else { continue }
            let dx = Double(box.midX) - shot.x, dy = (Double(box.midY) - shot.y) / aspect
            if (dx * dx + dy * dy).squareRoot() <= tuning.secondBallRadius * Double(hoop.width) {
                secondBallTime = time
                return
            }
        }
    }

    private static func isInsideFrame(_ box: CGRect) -> Bool {
        box.minX > 0.005 && box.maxX < 0.995 && box.minY > 0.005 && box.maxY < 0.995
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
                                 arrival: Double?, hoop: CGRect, time: Double, doubts: Doubts = []) -> Event {
        phase = .idle
        reachedApex = false
        filter = nil
        shotHoop = nil
        cooldownUntil = time + tuning.cooldown
        let seen = lastSeen
        history.removeAll()
        candidates.removeAll()
        // Another ball next to it at the rim: the call may be about that one.
        var doubts = doubts, confidence = confidence
        if secondBallTime >= (arrival ?? seen) - tuning.secondBallLookback {
            doubts.insert(.secondBall)
            confidence = min(confidence, tuning.secondBallConfidence)
        }
        secondBallTime = -.infinity
        return .resolved(Outcome(result: result, confidence: confidence, release: release,
                                 rimArrivalTime: arrival, hoop: hoop, lastSeenTime: seen, doubts: doubts))
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

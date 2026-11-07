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
        /// ball filter's prediction is a different ball. Over both axes, the
        /// shot ball lands beyond 4 SD once in ~3000 frames; with gravity
        /// modelled, 5 let the rim boxed as a ball through after the shot
        /// had been above the frame for 0.4 s (somorin-dusk-cam2 170.87).
        var gateSigma: Double = 4.0
        /// Ball boxes bigger than this many rim widths are false positives.
        var maxBallToRim: Double = 1.6

        // The ball in flight (BallFilter: gravity and perspective from the
        // ball's apparent size). In rim diameters R, so it behaves the same
        // near or far; 1 R ≈ 0.47 m at the rim's depth, where gravity is
        // ≈ 21 R/s².
        /// SD of a detected ball's centre, rim diameters. The ball's box is
        /// ~0.5 R; its centre wobbles a few % of that, more with blur or a
        /// hand or the net over part of it.
        var flightMeasurementSD: Double = 0.08
        /// White acceleration noise, R²/s³: what neither gravity nor
        /// perspective explains frame to frame (drag is ~2 R/s²).
        var flightAccelerationNoise: Double = 4
        /// How fast the filter's residual acceleration may wander, R²/s⁵.
        /// Camera tilt and drag change it by a few R/s² over a flight.
        var flightResidualDrift: Double = 25
        /// SD of that residual at release, R/s²: camera tilt, drag and
        /// boxes that aren't exactly the ball's size, ~30% of gravity.
        var flightInitialResidualSD: Double = 6
        /// Near the rim and board the ball may bounce: a velocity kick with
        /// this SD as a fraction of its speed. A hit at restitution 0.55
        /// (rim) to 0.68 (glass) changes it by at most ~1.7× the speed,
        /// which this puts at the gate (`gateSigma`)…
        var bounceKick: Double = 0.42
        /// …plus this, R/s, for a ball dropping slowly onto the rim.
        var bounceKickFloor: Double = 1
        /// For this long after a shot starts (s) the ball may still be in
        /// the hands: the start rule fires on the lift, and the set point and
        /// push take up to ~0.3 s more. A ball the flight model can't explain
        /// then is left to the loose filter. A ball that goes out of the top
        /// of the frame isn't back near the rim this soon.
        var handsTime: Double = 0.4
        /// White acceleration noise of the loose filter, R²/s³: a hand pushes
        /// at up to ~5 g (≈ 100 R/s²) for ~0.15 s.
        var looseAccelerationNoise: Double = 400
        /// A detection within this many SDs of the flight model's prediction
        /// fits free flight; one further out (but inside `gateSigma`) during
        /// `handsTime` restarts the flight model from the loose filter.
        var freeFlightSigma: Double = 3
        /// A box this close to the frame's edge (fraction of the frame, ~3 px
        /// at 720p) and clearly shorter across it than along it is a ball
        /// cut off by the edge.
        var frameEdge: Double = 0.004
        /// A box longer than this many times the followed ball's apparent
        /// diameter, plus its motion blur, isn't that ball: detector size
        /// jitter is ~10%, and the ball's size drifts a little between
        /// sightings. The rim taken for a ball is ~2× the ball.
        var maxBallStretch: Double = 1.5
        /// Longest exposure assumed for motion blur, s. Phone video exposes
        /// for at most the frame time; outdoors, far less.
        var maxExposure: Double = 1.0 / 60
        /// While the filter has the ball out of the frame, it can only be
        /// seen within this many diameters of the edge it went out by: it
        /// comes back through it, and the filter's return time is good to
        /// a frame or two (~7 R/s × 2/30 s ≈ 1 diameter).
        var reentryDepth: Double = 1.5
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
    /// Follows the ball from release until the shot resolves: free flight
    /// under gravity, seen through the camera.
    private var filter: BallFilter?
    /// A plain constant-velocity filter with generous noise that follows the
    /// ball whatever moves it. Until the ball has left the hands, or just
    /// after something touched it, the flight model is wrong and this isn't.
    private var looseFilter: BallFilter?
    /// The flight filter as it was at the previous sighting, so a rim
    /// crossing between two sightings can follow the ball's arc.
    private var filterAtPrevious: BallFilter?
    /// When the shot in flight started.
    private var shotStart: Double = -.infinity
    /// Last frame the flight filter had the ball above the top of the frame
    /// (and didn't see it). It's coming back down, so it isn't lost yet.
    private var aboveFrameAt: Double = -.infinity
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
        looseFilter = nil
        filterAtPrevious = nil
        aboveFrameAt = -.infinity
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
            associate(plausible, rimUnitY: rimUnitY, time: time)
        } else {
            let bounce = filter.map { bounceSD($0, at: time, hoop: hoop, rimUnitY: rimUnitY) } ?? 0
            if let picked = pick(from: plausible, bounceSD: bounce, rimUnitY: rimUnitY, time: time) {
                history.append(Sample(box: picked.box, time: time))
                lastSeen = time
                let m = measurement(picked.box, rimUnitY: rimUnitY)
                filterAtPrevious = filter
                looseFilter?.update(with: m.point, at: time)
                if picked.restart, let loose = looseFilter {
                    // Gravity didn't put the ball here, so it wasn't flying
                    // freely: start the flight model again from this sighting.
                    filter = makeFilter(at: m, velocity: loose.velocity, time: time, rimUnitY: rimUnitY)
                } else {
                    filter?.update(with: m.point, diameter: m.diameter, at: time,
                                   measurementSD: m.sd, bounceSD: bounce)
                }
            } else if let filter, let size = filter.diameter(at: time),
                      filter.predicted(at: time).y - size / 2 > 1 {
                aboveFrameAt = time
            }
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
    /// `restart` when only the loose filter accepts it.
    private func pick(from balls: [CGRect], bounceSD: Double, rimUnitY: Double,
                      time: Double) -> (box: CGRect, restart: Bool)? {
        guard !balls.isEmpty, let last = history.last else { return nil }
        // Hard cap on movement since the last sighting, whatever the filter says.
        let cap = tuning.gate * rimUnitY * max(1, (time - last.time) * 30)

        if let filter {
            let balls = balls.filter {
                couldBeShotBall($0, filter: filter, time: time) && couldBeBackInFrame($0, filter: filter, time: time)
            }
            func best(_ f: BallFilter, bounceSD: Double) -> (box: CGRect, surprise: Double)? {
                let predicted = f.predicted(at: time)
                let scored = balls.map { box -> (box: CGRect, surprise: Double, distance: Double) in
                    let m = measurement(box, rimUnitY: rimUnitY)
                    let dx = m.point.x - predicted.x, dy = m.point.y - predicted.y
                    let surprise = f.surprise(of: m.point, at: time, measurementSD: m.sd, bounceSD: bounceSD)
                    return (box, surprise, (dx * dx + dy * dy).squareRoot())
                }
                guard let best = scored.min(by: { $0.surprise < $1.surprise }),
                      best.distance <= cap,
                      best.surprise <= tuning.gateSigma else { return nil }
                return (best.box, best.surprise)
            }
            let flight = best(filter, bounceSD: bounceSD)
            if let flight, flight.surprise <= tuning.freeFlightSigma { return (flight.box, false) }
            // Not quite where gravity would have it. Just after the start the
            // hands may still have been on it: if the loose filter takes it,
            // start the flight model again rather than bend it to fit.
            if let looseFilter, time - shotStart <= tuning.handsTime,
               let loose = best(looseFilter, bounceSD: 0) {
                return (loose.box, true)
            }
            return flight.map { ($0.box, false) }
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
        return (best.0, false)
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
        (filter, looseFilter) = makeFilters(following: run[releaseIndex...], rimUnitY: rimUnitY)
        shotStart = time
        return .started(release)
    }

    private mutating func advanceFlight(release: Release, hoop: CGRect, rimLine: Double,
                                        rimUnitY: Double, time: Double) -> Event? {
        if time - release.time > tuning.flightTimeout {
            return finish(lostGuess(hoop: hoop, rimUnitY: rimUnitY), confidence: 0.3,
                          release: release, arrival: nil, hoop: hoop, time: time)
        }
        if time - max(lastSeen, aboveFrameAt) > tuning.lostTimeout {
            return finish(lostGuess(hoop: hoop, rimUnitY: rimUnitY), confidence: 0.35,
                          release: release, arrival: nil, hoop: hoop, time: time)
        }
        guard history.count >= 2, let cur = history.last, cur.time == time else { return nil }
        let prev = history[history.count - 2]
        guard prev.time >= release.time else { return nil }

        if cur.y < prev.y { reachedApex = true }
        guard reachedApex, prev.y > rimLine, cur.y <= rimLine else { return nil }

        // Dropped through rim height — where?
        let (crossX, crossTime) = rimCrossing(from: prev, to: cur, rimLine: rimLine, rimUnitY: rimUnitY)
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

    /// Where (image x) and when the ball dropped through the rim line
    /// between the last two sightings: along the flight filter's arc,
    /// shifted to pass through both. Across a gap (the ball out of the top
    /// of the frame, hidden by a hand or the net) a straight line from the
    /// earlier sighting puts the crossing too early and too far back
    /// towards where the ball was last seen; between frames the two agree.
    private func rimCrossing(from prev: Sample, to cur: Sample, rimLine: Double,
                             rimUnitY: Double) -> (x: Double, time: Double) {
        let k = (prev.y - rimLine) / max(prev.y - cur.y, 1e-9)
        let straight = (x: prev.x + (cur.x - prev.x) * k, time: prev.time + (cur.time - prev.time) * k)
        let span = cur.time - prev.time
        guard let arc = filterAtPrevious, span > 0, abs(arc.time - prev.time) < 1e-9 else { return straight }
        let path = arc.path(to: cur.time, every: min(1.0 / 240, span / 4))
        guard let first = path.first, let last = path.last else { return straight }
        let start = measurement(prev.box, rimUnitY: rimUnitY).point
        let end = measurement(cur.box, rimUnitY: rimUnitY).point
        let shift0 = (x: start.x - first.point.x, y: start.y - first.point.y)
        let shift1 = (x: end.x - last.point.x, y: end.y - last.point.y)
        var above: (t: Double, x: Double, y: Double)?
        for step in path {
            let u = (step.time - prev.time) / span
            let x = step.point.x + shift0.x * (1 - u) + shift1.x * u
            let y = step.point.y + shift0.y * (1 - u) + shift1.y * u
            if let a = above, a.y > rimLine, y <= rimLine {
                let f = (a.y - rimLine) / max(a.y - y, 1e-12)
                return ((a.x + (x - a.x) * f) / aspect, a.t + (step.time - a.t) * f)
            }
            above = (step.time, x, y)
        }
        return straight
    }

    /// Box centre in height units on both axes (x scaled by the aspect ratio).
    private func point(_ box: CGRect) -> BallFilter.Point {
        BallFilter.Point(x: Double(box.midX) * aspect, y: Double(box.midY))
    }

    /// The flight and loose filters, seeded from the release onwards. Noise
    /// scales with the rim, so they behave the same whether the hoop is near
    /// or far.
    private func makeFilters(following samples: ArraySlice<Sample>,
                             rimUnitY: Double) -> (BallFilter?, BallFilter?) {
        guard let first = samples.first else { return (nil, nil) }
        let last = samples.last ?? first
        let dt = last.time - first.time
        let velocity = dt > 0
            ? BallFilter.Point(x: (last.x - first.x) * aspect / dt, y: (last.y - first.y) / dt)
            : BallFilter.Point(x: 0, y: 0)
        let start = measurement(first.box, rimUnitY: rimUnitY)
        var flight = makeFilter(at: start, velocity: velocity, time: first.time, rimUnitY: rimUnitY)
        let r = rimUnitY
        var loose = BallFilter(at: start.point, velocity: velocity, time: first.time,
                               noise: .init(measurementSD: 0.12 * r,
                                            acceleration: tuning.looseAccelerationNoise * r * r,
                                            initialVelocitySD: 30 * r))
        for sample in samples.dropFirst() {
            let m = measurement(sample.box, rimUnitY: rimUnitY)
            flight.update(with: m.point, diameter: m.diameter, at: sample.time, measurementSD: m.sd)
            loose.update(with: m.point, at: sample.time)
        }
        return (flight, loose)
    }

    /// A flight filter starting at one sighting.
    private func makeFilter(at start: (point: BallFilter.Point, diameter: Double?, sd: Double?),
                            velocity: BallFilter.Point, time: Double, rimUnitY: Double) -> BallFilter {
        let r = rimUnitY
        let noise = BallFilter.Noise(measurementSD: tuning.flightMeasurementSD * r,
                                     acceleration: tuning.flightAccelerationNoise * r * r,
                                     residualDrift: tuning.flightResidualDrift * r * r,
                                     initialResidualSD: tuning.flightInitialResidualSD * r,
                                     initialVelocitySD: 30 * r)
        return BallFilter(at: start.point, diameter: start.diameter, velocity: velocity,
                          time: time, noise: noise)
    }

    /// What a ball box tells the filter: its centre (height units, x scaled
    /// by the aspect ratio), its apparent diameter (the shorter side, since
    /// motion blur stretches the box along the ball's path) and how far to
    /// trust the centre (nil: as usual).
    ///
    /// A ball going out of the frame is cut off by the edge: its box
    /// shrinks towards the edge, so its centre lags the ball's and its
    /// shorter side is no longer its size. The ball is round, so the side
    /// along the edge still gives its size, and its centre is half that
    /// in from the box's inner side; that's less certain (the side along the
    /// edge carries any blur), and says nothing about depth.
    private func measurement(_ box: CGRect, rimUnitY: Double) -> (point: BallFilter.Point, diameter: Double?, sd: Double?) {
        let width = Double(box.width) * aspect, height = Double(box.height)
        let edge = tuning.frameEdge
        let cutVertically = height < 0.9 * width
            && (Double(box.maxY) >= 1 - edge || Double(box.minY) <= edge)
        let cutSideways = width < 0.9 * height
            && (Double(box.minX) <= edge || Double(box.maxX) >= 1 - edge)
        guard cutVertically || cutSideways else {
            let diameter = min(width, height)
            return (point(box), diameter > 0 ? diameter : nil, nil)
        }
        let size = max(width, height)
        var centre = point(box)
        if cutVertically {
            centre.y = Double(box.maxY) >= 1 - edge ? Double(box.minY) + size / 2 : Double(box.maxY) - size / 2
        }
        if cutSideways {
            centre.x = Double(box.minX) <= edge ? Double(box.maxX) * aspect - size / 2
                                                : Double(box.minX) * aspect + size / 2
        }
        let usual = tuning.flightMeasurementSD * rimUnitY, extra = 0.25 * size
        return (centre, nil, (usual * usual + extra * extra).squareRoot())
    }

    /// Whether a box could be the ball being followed. A ball's box is about
    /// its apparent diameter across, stretched along its path by motion
    /// blur at most; a box much longer than that (the rim taken for a ball,
    /// two balls in one box) isn't it.
    private func couldBeShotBall(_ box: CGRect, filter: BallFilter, time: Double) -> Bool {
        guard let diameter = filter.diameter(at: time) else { return true }
        let v = filter.velocity
        let blur = (v.x * v.x + v.y * v.y).squareRoot() * tuning.maxExposure
        let long = max(Double(box.width) * aspect, Double(box.height))
        return long <= tuning.maxBallStretch * diameter + blur
    }

    /// Whether a box is somewhere the ball could be if the filter has it out
    /// of the frame (its centre beyond an edge). A ball that went out of the
    /// top (or a side) comes back through that edge, so it's seen at the
    /// edge first; a box deeper in is something else, however unsure the
    /// filter is after the gap (on the real clips, the rim taken for a ball
    /// while the shot is above the frame).
    private func couldBeBackInFrame(_ box: CGRect, filter: BallFilter, time: Double) -> Bool {
        guard let size = filter.diameter(at: time) else { return true }
        let p = filter.predicted(at: time)
        let depth = tuning.reentryDepth * size
        if p.y > 1, Double(box.maxY) < 1 - depth { return false }
        if p.y < 0, Double(box.minY) > depth { return false }
        if p.x > aspect, Double(box.maxX) * aspect < aspect - depth { return false }
        if p.x < 0, Double(box.minX) * aspect > depth { return false }
        return true
    }

    /// Velocity kick SD (height units/s) for a ball that may have hit the
    /// rim or board since the filter last saw it: when it should now be
    /// within the board's reach of the rim. The board is 1.83 m wide and
    /// rises ~0.9 m above the rim (≈ 1.95 R each way) and the ball's radius
    /// adds 0.25 R; the hoop box takes in the net below.
    private func bounceSD(_ filter: BallFilter, at time: Double, hoop: CGRect, rimUnitY: Double) -> Double {
        let p = filter.predicted(at: time)
        let reach = 2.2 * rimUnitY
        let nearHoop = abs(p.x - Double(hoop.midX) * aspect) <= reach
            && p.y >= Double(hoop.minY) - 0.25 * rimUnitY
            && p.y <= Double(hoop.maxY) + reach
        guard nearHoop else { return 0 }
        let v = filter.velocity
        let speed = (v.x * v.x + v.y * v.y).squareRoot()
        return tuning.bounceKick * speed + tuning.bounceKickFloor * rimUnitY
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
        looseFilter = nil
        filterAtPrevious = nil
        aboveFrameAt = -.infinity
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

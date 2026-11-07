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
//   inFlight ──(comes back at the lens before reaching the rim)──▶ idle, no call
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
        /// Ignore new shots for this long after a resolution (counted from
        /// when the shot ball was last seen).
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
        /// A shot flies to the hoop, so its ball's size heads for that of a
        /// ball at the rim's depth, about 0.5 rim widths (0.239 m ball /
        /// 0.46–0.49 m rim box): from behind the shooter it shrinks. A
        /// pass or lob back from under the hoop comes at the lens and
        /// keeps growing. Until the ball first reaches the rim, one that
        /// started nearer the lens than the rim (over 0.5 rim widths) and
        /// has since grown by this factor…
        var towardLensGrowth: Double = 1.25
        /// …to at least this many rim widths (1.2 × a ball at the rim) is
        /// no shot: the track is dropped without a call. In shot-sim this
        /// catches 68 of 96 rebounder lobs and 2 of 6,901 real shots from
        /// behind. With the camera behind the hoop the shooter's ball
        /// starts smaller than at the rim's depth, so it doesn't apply.
        var towardLensMinSize: Double = 0.6

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
    /// The ball's apparent diameter when the shot started (height units,
    /// at `shotStart`), and whether it has reached the rim since; see
    /// `comingAtTheLens`.
    private var startDiameter: Double = 0
    private var reachedRim = false
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
        looseFilter = nil
        filterAtPrevious = nil
        aboveFrameAt = -.infinity
        shotHoop = nil
        reachedRim = false
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
            associate(startable(balls, hoop: hoop), rimUnitY: rimUnitY, time: time)
        } else {
            let bounce = filter.flatMap { self.bounce($0, by: time, hoop: hoop, rimUnitY: rimUnitY) }
            if let picked = pick(from: plausible, bounce: bounce, rimUnitY: rimUnitY, time: time) {
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
                                   measurementSD: m.sd, bounce: bounce)
                }
            } else if let filter, let size = filter.diameter(at: time),
                      filter.predicted(at: time).y - size / 2 > 1 {
                aboveFrameAt = time
            }
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
            if comingAtTheLens(rimUnitY: rimUnitY, time: time) {
                dropShot()
                return nil
            }
            return advanceFlight(release: release, hoop: hoop, rimLine: rimLine,
                                 rimUnitY: rimUnitY, time: time)

        case .atRim(let release, let since, let arrival):
            reachedRim = true
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
    /// `restart` when only the loose filter accepts it.
    private func pick(from balls: [CGRect], bounce: BallFilter.Bounce?, rimUnitY: Double,
                      time: Double) -> (box: CGRect, restart: Bool)? {
        guard !balls.isEmpty, let last = history.last else { return nil }
        // Hard cap on movement since the last sighting, whatever the filter says.
        let cap = tuning.gate * rimUnitY * max(1, (time - last.time) * 30)

        if let filter {
            let balls = balls.filter {
                couldBeShotBall($0, filter: filter, time: time) && couldBeBackInFrame($0, filter: filter, time: time)
            }
            func best(_ f: BallFilter, bounce: BallFilter.Bounce?) -> (box: CGRect, surprise: Double)? {
                let predicted = f.predicted(at: time)
                let scored = balls.map { box -> (box: CGRect, surprise: Double, distance: Double) in
                    let m = measurement(box, rimUnitY: rimUnitY)
                    let dx = m.point.x - predicted.x, dy = m.point.y - predicted.y
                    let surprise = f.surprise(of: m.point, at: time, measurementSD: m.sd, bounce: bounce)
                    return (box, surprise, (dx * dx + dy * dy).squareRoot())
                }
                guard let best = scored.min(by: { $0.surprise < $1.surprise }),
                      best.distance <= cap,
                      best.surprise <= tuning.gateSigma else { return nil }
                return (best.box, best.surprise)
            }
            let flight = best(filter, bounce: bounce)
            if let flight, flight.surprise <= tuning.freeFlightSigma { return (flight.box, false) }
            // Not quite where gravity would have it. Just after the start the
            // hands may still have been on it: if the loose filter takes it,
            // start the flight model again rather than bend it to fit.
            if let looseFilter, time - shotStart <= tuning.handsTime,
               let loose = best(looseFilter, bounce: nil) {
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
        startDiameter = Self.median(run.suffix(3).map { diameter(of: $0.box) })
        reachedRim = false
        (filter, looseFilter) = makeFilters(following: run[releaseIndex...], rimUnitY: rimUnitY)
        shotStart = time
        return .started(release)
    }

    /// Before it first reaches the rim: is the "shot" ball coming at the
    /// lens from nearer than the rim (a pass or lob back to the shooter),
    /// growing instead of heading for its size at the rim? See
    /// Tuning.towardLensGrowth.
    private func comingAtTheLens(rimUnitY: Double, time: Double) -> Bool {
        guard !reachedRim, startDiameter >= 0.5 * rimUnitY,
              let last = history.last, last.time == time else { return false }
        let since = history.reversed().prefix { $0.time > shotStart }
        guard since.count >= 5 else { return false }
        let now = Self.median(since.prefix(5).map { diameter(of: $0.box) })
        return now >= tuning.towardLensGrowth * startDiameter
            && now >= tuning.towardLensMinSize * rimUnitY
    }

    /// Lets go of a start that turned out not to be a shot: no call, no
    /// cooldown (the shooter may shoot that ball straight back). The live
    /// view's "in flight" marker clears on its own timeout.
    private mutating func dropShot() {
        phase = .idle
        reachedApex = false
        filter = nil
        looseFilter = nil
        filterAtPrevious = nil
        aboveFrameAt = -.infinity
        shotHoop = nil
        reachedRim = false
        secondBallTime = -.infinity
        history.removeAll()
        candidates.removeAll()
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

    /// The rim or board contact a ball may have had since the filter last
    /// saw it: from when its predicted path first came within the board's
    /// reach of the rim. The board is 1.83 m wide and rises ~0.9 m above the
    /// rim (≈ 1.95 R each way) and the ball's radius adds 0.25 R; the hoop
    /// box takes in the net below.
    private func bounce(_ filter: BallFilter, by time: Double, hoop: CGRect,
                        rimUnitY: Double) -> BallFilter.Bounce? {
        let reach = 2.2 * rimUnitY
        func nearHoop(_ p: BallFilter.Point) -> Bool {
            abs(p.x - Double(hoop.midX) * aspect) <= reach
                && p.y >= Double(hoop.minY) - 0.25 * rimUnitY
                && p.y <= Double(hoop.maxY) + reach
        }
        guard let entry = filter.path(to: time, every: 1.0 / 120).first(where: { nearHoop($0.point) }) else {
            return nil
        }
        let v = filter.velocity
        let speed = (v.x * v.x + v.y * v.y).squareRoot()
        return BallFilter.Bounce(sd: tuning.bounceKick * speed + tuning.bounceKickFloor * rimUnitY,
                                 at: entry.time)
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
        looseFilter = nil
        filterAtPrevious = nil
        aboveFrameAt = -.infinity
        shotHoop = nil
        // The cooldown keeps the ball just called from starting another
        // shot, so it runs from when that ball was last seen: after a
        // lost-ball call it has been gone 0.9 s already, and a cooldown
        // from the call swallowed a real shot released meanwhile.
        cooldownUntil = min(time, lastSeen) + tuning.cooldown
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

// PhysicsTests.swift (package-only)
// The simulator's physics and camera against things we know.

import XCTest
@testable import HoopTrack
@testable import ShotSimulation

final class PhysicsTests: XCTestCase {

    private let physics = BallPhysics()

    func test_droppedBall_bouncesToAboutRestitutionSquaredHeight() {
        var ball = SimBall(p: Vec3(0, 1.8, 5), v: .zero)
        var contacts: [Contact] = []
        var apex = 0.0, t = 0.0, bounced = false
        while t < 2 {
            physics.advance(&ball, from: t, by: 1.0 / 60, contacts: &contacts)
            t += 1.0 / 60
            if !contacts.isEmpty { bounced = true }
            if bounced { apex = max(apex, ball.p.y) }
        }
        // Centre height above the floor: (1.8 − r) · e² + r, a little less for drag.
        let expected = (1.8 - Court.ballRadius) * 0.64 + Court.ballRadius
        XCTAssertEqual(apex, expected, accuracy: 0.08)
    }

    func test_aim_landsOnTheTarget() {
        let release = Vec3(0.4, 2.3, 5.5)
        let target = Court.rimCentre
        let spin = Aim.backspin(direction: (target - release).horizontal, revsPerSecond: 2)
        let v = Aim.solve(from: release, to: target, entryAngle: 45, spin: spin, physics: physics)!
        let crossing = Aim.crossing(from: release, velocity: v, spin: spin, height: target.y, physics: physics)!
        XCTAssertLessThan((crossing - target).horizontal.length, 0.01)
    }

    func test_centredShot_isASwish() {
        let release = Vec3(0, 2.3, 4.6)
        let spin = Aim.backspin(direction: Vec3(0, 0, -1), revsPerSecond: 2)
        let v = Aim.solve(from: release, to: Court.rimCentre + Vec3(0, 0, -0.02), entryAngle: 47, spin: spin, physics: physics)!
        let planner = ShotPlanner(physics: physics, frameInterval: 1.0 / 60)
        let outcome = planner.probe(release: release, velocity: v, spin: spin)
        XCTAssertEqual(outcome.kind, .swish)
        XCTAssertTrue(outcome.made)
    }

    func test_shortShot_hitsTheFrontRim() {
        let release = Vec3(0, 2.3, 4.6)
        let spin = Aim.backspin(direction: Vec3(0, 0, -1), revsPerSecond: 2)
        let v = Aim.solve(from: release, to: Court.rimCentre + Vec3(0, 0, 0.24), entryAngle: 42, spin: spin, physics: physics)!
        let outcome = ShotPlanner(physics: physics, frameInterval: 1.0 / 60).probe(release: release, velocity: v, spin: spin)
        XCTAssertFalse(outcome.made)
        XCTAssertGreaterThan(outcome.rimContactCount, 0)
    }

    func test_projection_higherIsUp_andFurtherIsSmaller() {
        let camera = CameraRig(position: Vec3(0, 1.3, 8), yaw: 0, pitch: 12)
        let low = camera.project(Vec3(0, 2.0, 3))!, high = camera.project(Vec3(0, 3.0, 3))!
        XCTAssertGreaterThan(high.y, low.y, "Vision boxes have y up")
        let near = camera.ball(at: Vec3(0.5, 2, 6), velocity: .zero)!, far = camera.ball(at: Vec3(0.5, 2, 1), velocity: .zero)!
        XCTAssertGreaterThan(near.diameterPx, far.diameterPx)
        XCTAssertGreaterThan(near.x, 0.5, "+x is to the right from behind the shooter")
    }

    /// The app's distance estimate should recover the simulated geometry.
    func test_projection_matchesTheAppsDistanceEstimate() {
        let camera = CameraRig(position: Vec3(0.5, 1.35, 7.0), yaw: CameraRig.yaw(from: Vec3(0.5, 1.35, 7.0), to: Court.rimCentre),
                               pitch: 14)
        let ballCentre = Vec3(0.6, 2.4, 5.0)
        let ball = camera.ball(at: ballCentre, velocity: .zero)!
        let ballBox = Box(centreX: ball.x, centreY: ball.y, width: ball.diameterPx / 1280, height: ball.diameterPx / 720)
        let rim = camera.hoopBox(withNet: false)!
        // The ring's box is the rim's outer width; the estimator wants the inner diameter.
        let scaled = Box(centreX: rim.midX, centreY: rim.midY, width: rim.width * 0.457 / (2 * (Court.rimRingRadius + Court.rimTubeRadius)),
                         height: rim.height)
        let estimate = CourtPositionEstimator.estimate(ballBox: ballBox.cgRect, ballDiameter: ballBox.width,
                                                       rimBox: scaled.cgRect)!
        XCTAssertEqual(estimate.depthM, 5.0, accuracy: 0.5)
    }
}

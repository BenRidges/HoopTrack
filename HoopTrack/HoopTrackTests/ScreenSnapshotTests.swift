// HoopTrackTests/ScreenSnapshotTests.swift
// Renders the main screens with realistic data to PNGs so the UI can be
// looked at without a Mac: CI sets SNAPSHOT_DIR (TEST_RUNNER_SNAPSHOT_DIR
// for xcodebuild) and uploads the folder as the "screens" artifact.
// Without SNAPSHOT_DIR every test here is skipped.
//
// These are pictures, not pixel comparisons: they fail only if a screen
// can't be built or drawn.

import XCTest
import SwiftUI
import SwiftData
import UIKit
@testable import HoopTrack

@MainActor
final class ScreenSnapshotTests: XCTestCase {

    private var services: AppServices!
    private var auth: AuthViewModel!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] != nil else {
            throw XCTSkip("SNAPSHOT_DIR not set")
        }
        services = AppServices(container: try HoopTrackStore.makeInMemoryContainer())
        auth = AuthViewModel(provider: MockAuthProvider())
    }

    override func tearDown() async throws {
        services = nil
        auth = nil
    }

    // MARK: - Screens

    func test_train_firstRun() throws {
        try snapshot("01-train-first-run") { NavigationStack { TrainTabView() } }
    }

    func test_train_withHistoryAndPlayoffs() throws {
        try seedHistory()
        try seedPlayoffRun()
        try snapshot("02-train") { NavigationStack { TrainTabView() } }
    }

    func test_progress() throws {
        try seedHistory()
        try seedPlayoffRun()
        try snapshot("03-progress") { NavigationStack { ProgressTabView() } }
        try snapshot("04-progress-lower", scrolledBy: 900) { NavigationStack { ProgressTabView() } }
    }

    func test_profile() throws {
        try seedHistory()
        try seedPlayoffRun()
        try snapshot("05-profile") { NavigationStack { ProfileTabView() } }
    }

    func test_sessionSummaryAndDetail() throws {
        let session = try seedHistory()
        try snapshot("06-summary") {
            SessionSummaryView(result: SessionResult(session: session, badgeChanges: [
                BadgeTierChange(badgeID: .deadeye, previousRank: BadgeRank(mmr: 560), newRank: BadgeRank(mmr: 640)),
            ]))
        }
        try snapshot("07-session-detail") { NavigationStack { SessionDetailView(session: session) } }
    }

    func test_onboarding() throws {
        try snapshot("08-onboarding") { OnboardingView {} }
    }

    func test_playoffSetup() throws {
        try snapshot("09-playoff-setup") { PlayoffSetupSheet { _ in } }
    }

    func test_playoffHUD() throws {
        // The live session's playoff layer over a stand-in for the camera.
        var run = PlayoffRun(spot: .threes)
        for result in [ShotResult.make, .make, .make, .make,          // game 1 won
                       .miss, .make, .miss, .make, .make, .miss, .make,  // game 2 won
                       .make, .miss, .make] {                        // game 3 under way
            run.record(result)
        }
        let finished = PlayoffGame(round: 1, number: 2, makes: 4, misses: 3, won: true,
                                   seriesWins: 2, seriesLosses: 0)
        let landscape = CGSize(width: 874, height: 402)
        try snapshot("10-playoff-hud", size: landscape) {
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.08)], startPoint: .top, endPoint: .bottom)
                PlayoffScoreboard(run: run, comebackZone: nil)
                    .padding(24)
                PlayoffMomentCard(moment: PlayoffMoment(event: .gameWon(finished), id: 1), run: run,
                                  comebackZone: nil, onDismiss: {}, onFinish: {})
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        try snapshot("11-playoff-eliminated", size: landscape) {
            ZStack {
                Color(white: 0.12)
                PlayoffMomentCard(
                    moment: PlayoffMoment(event: .eliminated(round: 2, game: PlayoffGame(
                        round: 2, number: 6, makes: 2, misses: 6, won: false, seriesWins: 2, seriesLosses: 4)), id: 2),
                    run: run, comebackZone: .cornerThree, onDismiss: {}, onFinish: {})
            }
        }
    }

    func test_rootWithNotice() throws {
        // The whole app shell (tab bar included) with the note shown when a
        // session ends with nothing recorded.
        try seedHistory()
        let key = AppPreferences.Key.hasCompletedOnboarding
        let before = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(before, forKey: key) }
        services.appState.notice = AppState.discardedNotice
        try snapshot("12-notice") { RootView() }
    }

    // MARK: - Data

    /// Two weeks of shooting, with shots placed around the court, ratings,
    /// badges and a goal. Returns the latest session.
    @discardableResult
    private func seedHistory() throws -> TrainingSession {
        let data = services.dataService
        let profile = try data.fetchOrCreateProfile()
        data.setPlayerName("Ben")
        let spots: [(CourtZone, Double, Double)] = [
            (.paint, 0.5, 0.12), (.midRange, 0.3, 0.3), (.midRange, 0.7, 0.32),
            (.cornerThree, 0.06, 0.08), (.aboveBreakThree, 0.5, 0.62), (.freeThrow, 0.5, 0.36),
            (.aboveBreakThree, 0.22, 0.55), (.cornerThree, 0.94, 0.1),
        ]
        var latest: TrainingSession?
        for day in stride(from: 13, through: 0, by: -2) {
            let session = try data.startSession(drillType: .freeShoot,
                                                namedDrill: day == 0 ? .aroundTheArc : nil)
            for i in 0..<(24 + day) {
                let spot = spots[i % spots.count]
                let make = (i * 7 + day) % 10 < 4 + (13 - day) / 4
                try data.addShot(to: session, result: make ? .make : .miss, zone: spot.0,
                                 shotType: .unknown, courtX: spot.1 + Double(i % 3) * 0.02,
                                 courtY: spot.2, science: ShotScienceMetrics(releaseAngleDeg: 46 + Double(i % 5),
                                                                             shotSpeedMph: 19))
            }
            try data.finaliseSession(session, activeDuration: Double(18 + day) * 60)
            let start = Calendar.current.date(byAdding: .day, value: -day, to: .now)!
            session.startedAt = start.addingTimeInterval(-1500)
            session.endedAt = start
            latest = session
        }
        if let first = latest?.orderedShots.first { first.needsReview = true }

        profile.ratingShooting = 64
        profile.ratingBallHandling = 41
        profile.ratingAthleticism = 52
        profile.ratingConsistency = 58
        profile.ratingVolume = 70
        profile.ratingOverall = 58
        for (badge, mmr) in [(BadgeID.deadeye, 640.0), (.hotHand, 980), (.gymRat, 1260), (.workhorse, 330)] {
            services.container.mainContext.insert(EarnedBadge(badgeID: badge, initialMMR: mmr, profile: profile))
        }
        try data.addGoal(GoalRecord(title: "Shoot 45% from three", skill: .shooting, metric: .threePointPercent,
                                    targetValue: 45, baselineValue: 31), to: profile)
        try services.container.mainContext.save()
        try data.recomputeCareerStats()
        return try XCTUnwrap(latest)
    }

    private func seedPlayoffRun() throws {
        let data = services.dataService
        let series = try data.startPlayoffSeries(spot: .threes)
        let session = try data.startSession(drillType: .freeShoot, playoffSeriesID: series.id)
        // Round 1 won 4–1, then round 2 game 1 won and game 2 lost.
        let pattern = "oooo" + "oooo" + "xxxxxxx" + "oooo" + "oooo" + "ooooo" + "xxxxxx"
        for c in pattern {
            try data.addShot(to: session, result: c == "o" ? .make : .miss, zone: .aboveBreakThree,
                             shotType: .unknown, courtX: 0.5, courtY: 0.62)
        }
        try data.finaliseSession(session, activeDuration: 900)
        data.refreshPlayoff(series)
    }

    // MARK: - Rendering

    private func snapshot<Content: View>(_ name: String,
                                         size: CGSize = CGSize(width: 402, height: 874),
                                         scrolledBy offset: CGFloat = 0,
                                         @ViewBuilder _ content: () -> Content) throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content().appEnvironment(services, auth: auth))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // Let onAppear loads, layout and animations finish.
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if offset > 0, let scroll = Self.firstScrollView(in: host.view) {
            scroll.setContentOffset(CGPoint(x: 0, y: min(offset, max(0, scroll.contentSize.height - size.height))),
                                    animated: false)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }

        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let png = try XCTUnwrap(image.pngData())
        try png.write(to: directory.appendingPathComponent("\(name).png"))
        add(XCTAttachment(image: image))
    }

    private static func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }
}

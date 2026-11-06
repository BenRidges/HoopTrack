// HoopTrackTests/PersistedKeysTests.swift
// Enum raw values are storage keys: SwiftData saves enums by raw value and
// the Supabase rows hold the same strings. Renaming one makes existing data
// unreadable on the phone and mismatched in the cloud. If a test here
// fails, change `displayName` instead; if a key really must change, it
// needs a SwiftData migration and a database migration first.

import XCTest
@testable import HoopTrack

final class PersistedKeysTests: XCTestCase {

    private func keys<T: CaseIterable & RawRepresentable>(_ type: T.Type) -> [T.RawValue] {
        T.allCases.map(\.rawValue)
    }

    func test_sessionKeys() {
        XCTAssertEqual(keys(DrillType.self), ["Free Shoot", "Dribble", "Agility", "Full Workout"])
        XCTAssertEqual(keys(NamedDrill.self), [
            "Around the Arc", "Free Throw Challenge", "Mid-Side-Mid", "5-Min Endurance Shoot",
            "Mikan Drill", "Crossover Series", "Two-Ball Dribble", "Shuttle Run", "Lane Agility",
            "Vertical Jump Test",
        ])
        XCTAssertEqual(keys(CourtType.self), ["NBA", "NCAA", "FIBA", "Half-Court (Casual)"])
    }

    func test_shotKeys() {
        XCTAssertEqual(keys(CourtZone.self),
                       ["Paint", "Mid-Range", "Corner 3", "Above-Break 3", "Free Throw", "Unknown"])
        XCTAssertEqual(keys(ShotType.self),
                       ["Catch & Shoot", "Off Dribble", "Pull-Up", "Free Throw", "Layup", "Floater", "Unknown"])
        XCTAssertEqual([ShotResult.make, .miss, .pending].map(\.rawValue), ["Make", "Miss", "Pending"])
    }

    func test_progressKeys() {
        XCTAssertEqual(keys(SkillDimension.self),
                       ["Shooting", "Ball Handling", "Athleticism", "Consistency", "Volume"])
        XCTAssertEqual(keys(GoalMetric.self), [
            "FG %", "3PT %", "FT %", "Vertical Jump (cm)", "Dribble Speed (dribbles/sec)",
            "Shuttle Run (seconds)", "Overall Rating", "Shooting Rating", "Sessions / Week",
        ])
        XCTAssertEqual(keys(BadgeID.self), [
            "deadeye", "sniper", "quickTrigger", "beyondTheArc", "charityStripe", "threeLevelScorer", "hotHand",
            "handles", "ambidextrous", "comboKing", "floorGeneral", "ballWizard",
            "posterizer", "lightning", "explosive", "highFlyer",
            "automatic", "metronome", "iceVeins", "reliable",
            "ironMan", "gymRat", "workhorse", "specialist", "completePlayer",
        ])
    }

    func test_gameAndPlayoffKeys() {
        XCTAssertEqual(keys(GameType.self), ["Pickup", "BO7 Playoff"])
        XCTAssertEqual([GameState.registering, .inProgress, .completed].map(\.rawValue),
                       ["registering", "inProgress", "completed"])
        XCTAssertEqual(keys(TeamAssignment.self), ["Team A", "Team B"])
        XCTAssertEqual([GameShotType.twoPoint, .threePoint].map(\.rawValue), ["2PT", "3PT"])
        XCTAssertEqual(keys(GameFormat.self), [1, 2, 3])
        XCTAssertEqual(keys(PlayoffSpot.self), ["threes", "midRange", "freeThrows"])
        XCTAssertEqual([PlayoffStatus.playing, .comeback, .champion, .retired].map(\.rawValue),
                       ["playing", "comeback", "champion", "retired"])
    }

    func test_telemetryKeys() {
        XCTAssertEqual([UploadState.pending, .uploading, .uploaded, .failed, .abandoned].map(\.rawValue),
                       ["pending", "uploading", "uploaded", "failed", "abandoned"])
        XCTAssertEqual([SessionKind.training, .game].map(\.rawValue), ["training", "game"])
    }
}

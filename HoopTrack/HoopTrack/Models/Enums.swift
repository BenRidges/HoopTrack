// Enums.swift
// All shared domain enumerations used across models, view-models, and views.
// Adding a new variant here is the single-source change needed for the whole app.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Drill / Session Types

/// Top-level drill categories that appear in the Drill Picker.
nonisolated enum DrillType: String, Codable, CaseIterable, Identifiable {
    case freeShoot      = "Free Shoot"
    case dribble        = "Dribble"
    case agility        = "Agility"
    case fullWorkout    = "Full Workout"

    var id: String { rawValue }

    /// UI label. `rawValue` is a persistence/sync key and must not change.
    var displayName: String {
        switch self {
        case .freeShoot:    return "Shooting"
        case .dribble:      return "Ball handling"
        case .agility:      return "Agility"
        case .fullWorkout:  return "Workout"
        }
    }

    var systemImage: String {
        switch self {
        case .freeShoot:    return "basketball.fill"
        case .dribble:      return "hand.raised.fill"
        case .agility:      return "figure.run"
        case .fullWorkout:  return "bolt.fill"
        }
    }
}

/// Specific named drills from the Drill Library (Section 4 of spec).
nonisolated enum NamedDrill: String, Codable, CaseIterable, Identifiable {
    case aroundTheArc        = "Around the Arc"
    case freethrowChallenge  = "Free Throw Challenge"
    case midSideMid          = "Mid-Side-Mid"
    case fiveMinEndurance    = "5-Min Endurance Shoot"
    case mikanDrill          = "Mikan Drill"
    case crossoverSeries     = "Crossover Series"
    case twoBallDribble      = "Two-Ball Dribble"
    case shuttleRun          = "Shuttle Run"
    case laneAgility         = "Lane Agility"
    case verticalJumpTest    = "Vertical Jump Test"

    var id: String { rawValue }

    /// Drills offered in the library. The vertical jump test needs a jump
    /// measurement the app doesn't do yet; old sessions keep the case.
    static var library: [NamedDrill] { allCases.filter { $0 != .verticalJumpTest } }

    /// One-line explainer shown under the drill name.
    var summary: String {
        switch self {
        case .aroundTheArc:       return "Five spots around the line, five shots each."
        case .freethrowChallenge: return "Sets of ten from the line."
        case .midSideMid:         return "Elbow, baseline, elbow. Pull-up range."
        case .fiveMinEndurance:   return "As many makes as you can in five minutes."
        case .mikanDrill:         return "Alternating hook layups under the rim."
        case .crossoverSeries:    return "Crossovers between your hands, as fast as you can."
        case .twoBallDribble:     return "Two balls at once. Keep both hands even."
        case .shuttleRun:         return "Sprint out and back. Best of three."
        case .laneAgility:        return "Slide the lane box. Timed."
        case .verticalJumpTest:   return "Three attempts, best height counts."
        }
    }

    /// Fixed length for timed drills, nil for open-ended ones.
    var timeLimitSec: Double? {
        self == .fiveMinEndurance ? 300 : nil
    }

    var drillType: DrillType {
        switch self {
        case .aroundTheArc, .freethrowChallenge, .midSideMid, .fiveMinEndurance:
            return .freeShoot
        case .mikanDrill:
            return .freeShoot
        case .crossoverSeries, .twoBallDribble:
            return .dribble
        case .shuttleRun, .laneAgility, .verticalJumpTest:
            return .agility
        }
    }
}

// MARK: - Shot Classification

/// Broad court zone for shot mapping and heat map rendering.
nonisolated enum CourtZone: String, Codable, CaseIterable {
    case paint          = "Paint"
    case midRange       = "Mid-Range"
    case cornerThree    = "Corner 3"
    case aboveBreakThree = "Above-Break 3"
    case freeThrow      = "Free Throw"
    case unknown        = "Unknown"

    /// UI label (rawValue is a persistence/sync key).
    var displayName: String {
        switch self {
        case .paint:           return "Paint"
        case .midRange:        return "Mid-range"
        case .cornerThree:     return "Corner 3"
        case .aboveBreakThree: return "Above the break 3"
        case .freeThrow:       return "Free throw"
        case .unknown:         return "Unplaced"
        }
    }

    var isThree: Bool { self == .cornerThree || self == .aboveBreakThree }

    /// Stable camelCase key used in JSON exports (e.g. "midRange", "cornerThree").
    /// Distinct from `rawValue` (human-readable label) so UI labels can change
    /// without breaking existing export files.
    var exportKey: String {
        switch self {
        case .paint:           return "paint"
        case .midRange:        return "midRange"
        case .cornerThree:     return "cornerThree"
        case .aboveBreakThree: return "aboveBreakThree"
        case .freeThrow:       return "freeThrow"
        case .unknown:         return "unknown"
        }
    }
}

/// How the shot was generated (influences difficulty weighting in skill rating).
nonisolated enum ShotType: String, Codable, CaseIterable {
    case catchAndShoot   = "Catch & Shoot"
    case offDribble      = "Off Dribble"
    case pullUp          = "Pull-Up"
    case freeThrow       = "Free Throw"
    case layup           = "Layup"
    case floater         = "Floater"
    case unknown         = "Unknown"
}

/// Make or miss result, plus a pending state used before CV confirms the call.
nonisolated enum ShotResult: String, Codable {
    case make    = "Make"
    case miss    = "Miss"
    case pending = "Pending"  // CV not yet confirmed
}

// MARK: - Court Type (affects 3-pt line distance)

nonisolated enum CourtType: String, Codable, CaseIterable, Identifiable {
    case nba        = "NBA"
    case ncaa       = "NCAA"
    case fiba       = "FIBA"
    case halfCourt  = "Half-Court (Casual)"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nba:       return "NBA"
        case .ncaa:      return "College"
        case .fiba:      return "FIBA"
        case .halfCourt: return "High school"
        }
    }
    /// Three-point distance in feet from the basket.
    var threePointDistanceFt: Double {
        switch self {
        case .nba:       return 23.75
        case .ncaa:      return 22.15
        case .fiba:      return 22.15
        case .halfCourt: return 19.75  // high-school / recreational
        }
    }
}

// MARK: - Skill Dimensions (radar chart axes)

nonisolated enum SkillDimension: String, Codable, CaseIterable, Identifiable {
    case shooting     = "Shooting"
    case ballHandling = "Ball Handling"
    case athleticism  = "Athleticism"
    case consistency  = "Consistency"
    case volume       = "Volume"

    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .shooting:     return "basketball"
        case .ballHandling: return "hand.raised"
        case .athleticism:  return "figure.basketball"
        case .consistency:  return "target"
        case .volume:       return "calendar.badge.clock"
        }
    }
}

// MARK: - Camera Mode

nonisolated enum CameraMode: Sendable {
    case rear    // Shot tracking (default)
    case front   // Dribble drills (front camera, phone on floor)
}

// MARK: - Camera Orientation

/// Orientation mode for the camera output.
/// Portrait = 90° rotation (device upright). Landscape = 0° (device sideways).
nonisolated enum CameraOrientation: Sendable {
    case portrait
    case portraitUpsideDown
    case landscape          // sensor-native for rear camera (matches UIDeviceOrientation.landscapeLeft)
    case landscapeRight     // 180° rotated — opposite landscape hold

    var videoRotationAngle: CGFloat {
        switch self {
        case .portrait:           return 90
        case .portraitUpsideDown: return 270
        case .landscape:          return 0
        case .landscapeRight:     return 180
        }
    }

}

// MARK: - Game Mode (SP1)

/// What kind of game session this is. Pickup = casual 2v2/3v3.
/// `bo7Playoff` is the solo BO7 mode added in SP3.
nonisolated enum GameType: String, Codable, CaseIterable, Identifiable {
    case pickup     = "Pickup"
    case bo7Playoff = "BO7 Playoff"
    var id: String { rawValue }
}

/// Lifecycle of a GameSession.
nonisolated enum GameState: String, Codable {
    case registering
    case inProgress
    case completed
}

/// Which team a GamePlayer belongs to within their GameSession.
nonisolated enum TeamAssignment: String, Codable, CaseIterable, Identifiable {
    case teamA = "Team A"
    case teamB = "Team B"
    var id: String { rawValue }
}

/// Point value of a shot in Game Mode — 2PT vs 3PT, derived from court position.
/// Named GameShotType to avoid colliding with the existing ShotType enum
/// (catch-and-shoot / pull-up / etc) used by solo training sessions.
nonisolated enum GameShotType: String, Codable {
    case twoPoint   = "2PT"
    case threePoint = "3PT"
}

/// Players per team.
nonisolated enum GameFormat: Int, Codable, CaseIterable, Identifiable {
    case oneOnOne     = 1
    case twoOnTwo     = 2
    case threeOnThree = 3
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .oneOnOne:     return "1v1"
        case .twoOnTwo:     return "2v2"
        case .threeOnThree: return "3v3"
        }
    }
    var totalPlayers: Int { rawValue * 2 }
}

// MARK: - Telemetry (CV-A)

/// Lifecycle of a telemetry upload for one session. Used by `TelemetryUpload.state`.
nonisolated enum UploadState: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
    case abandoned
}

/// Which session model the telemetry row refers to. Avoids a table split
/// when looking back at the original session.
nonisolated enum SessionKind: String, Codable {
    case training
    case game
}

// MARK: - Playoffs

/// Where a playoff run is shot from. Easier spots need more makes a game.
nonisolated enum PlayoffSpot: String, Codable, CaseIterable, Identifiable {
    case threes     = "Threes"
    case midRange   = "Mid-range"
    case freeThrows = "Free throws"

    var id: String { rawValue }

    /// Makes needed to win a 10-shot game in rounds 1 to 4.
    var makesToWin: [Int] {
        switch self {
        case .threes:     return [4, 5, 6, 7]
        case .midRange:   return [5, 6, 7, 8]
        case .freeThrows: return [6, 7, 8, 9]
        }
    }

    var systemImage: String {
        switch self {
        case .threes:     return "3.circle.fill"
        case .midRange:   return "2.circle.fill"
        case .freeThrows: return "1.circle.fill"
        }
    }

    var detail: String {
        switch self {
        case .threes:     return "Anywhere behind the arc."
        case .midRange:   return "Inside the arc, outside the paint."
        case .freeThrows: return "From the line."
        }
    }
}

/// Where a playoff run stands.
nonisolated enum PlayoffStatus: String, Codable {
    /// Playing a series.
    case playing
    /// Knocked out; making shots to earn the round back.
    case comeback
    case champion
    /// Ended by the player.
    case retired
}

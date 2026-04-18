// Enums.swift
// All shared domain enumerations used across models, view-models, and views.
// Adding a new variant here is the single-source change needed for the whole app.

import Foundation

// MARK: - Drill / Session Types

/// Top-level drill categories that appear in the Drill Picker.
enum DrillType: String, Codable, CaseIterable, Identifiable {
    case freeShoot      = "Free Shoot"
    case dribble        = "Dribble"
    case agility        = "Agility"
    case fullWorkout    = "Full Workout"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .freeShoot:    return "basketball.fill"
        case .dribble:      return "hand.point.up.fill"
        case .agility:      return "figure.run"
        case .fullWorkout:  return "bolt.fill"
        }
    }

    var description: String {
        switch self {
        case .freeShoot:    return "Open-court shooting with automatic make/miss detection."
        case .dribble:      return "Ball-handling drills with AR targets and combo tracking."
        case .agility:      return "Shuttle runs, lane agility, and sprint-speed tests."
        case .fullWorkout:  return "Combined shooting, dribbling, and agility session."
        }
    }
}

/// Specific named drills from the Drill Library (Section 4 of spec).
enum NamedDrill: String, Codable, CaseIterable, Identifiable {
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
enum CourtZone: String, Codable, CaseIterable {
    case paint          = "Paint"
    case midRange       = "Mid-Range"
    case cornerThree    = "Corner 3"
    case aboveBreakThree = "Above-Break 3"
    case freeThrow      = "Free Throw"
    case unknown        = "Unknown"

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
enum ShotType: String, Codable, CaseIterable {
    case catchAndShoot   = "Catch & Shoot"
    case offDribble      = "Off Dribble"
    case pullUp          = "Pull-Up"
    case freeThrow       = "Free Throw"
    case layup           = "Layup"
    case floater         = "Floater"
    case unknown         = "Unknown"
}

/// Make or miss result, plus a pending state used before CV confirms the call.
enum ShotResult: String, Codable {
    case make    = "Make"
    case miss    = "Miss"
    case pending = "Pending"  // CV not yet confirmed
}

extension ShotResult {
    /// Semantic colour name for the recent-shots HUD dot.
    var dotColorName: String {
        switch self {
        case .make:    return "shotDotGreen"
        case .miss:    return "shotDotRed"
        case .pending: return "shotDotGray"
        }
    }
}

// MARK: - Court Type (affects 3-pt line distance)

enum CourtType: String, Codable, CaseIterable, Identifiable {
    case nba        = "NBA"
    case ncaa       = "NCAA"
    case fiba       = "FIBA"
    case halfCourt  = "Half-Court (Casual)"

    var id: String { rawValue }
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

enum SkillDimension: String, Codable, CaseIterable, Identifiable {
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

enum CameraMode {
    case rear    // Shot tracking (default)
    case front   // Dribble drills (front camera, phone on floor)
}

// MARK: - Camera Orientation

/// Orientation mode for the camera output.
/// Portrait = 90° rotation (device upright). Landscape = 0° (device sideways).
enum CameraOrientation {
    case portrait
    case landscape

    var videoRotationAngle: CGFloat {
        switch self {
        case .portrait:  return 90
        case .landscape: return 0
        }
    }
}

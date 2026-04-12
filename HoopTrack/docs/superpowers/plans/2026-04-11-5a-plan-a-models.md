# Phase 5A — Plan A: Model Layer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add all new model types and field additions needed by Phase 5A services, plus the SwiftData schema migration.

**Architecture:** Three new value-type files (BadgeTier/BadgeRank, BadgeID, EarnedBadge @Model) plus targeted additions to four existing models. Schema upgraded from V1→V2 via lightweight SwiftData migration.

**Tech Stack:** SwiftData, Foundation, Swift 6 strict concurrency (@MainActor default)

**Prerequisite:** Branch `feat/phase5-goals-ratings-notifications`, Xcode project at `HoopTrack/HoopTrack.xcodeproj`

**Build command (run from worktree root):**
```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

### Task 1: Create `BadgeTier.swift` (BadgeTier enum + BadgeRank struct)

**Files:**
- Create: `HoopTrack/HoopTrack/Models/BadgeTier.swift`

- [ ] **Step 1: Create the file**

```swift
// BadgeTier.swift
import Foundation

enum BadgeTier: Int, Comparable, Codable, CaseIterable {
    case bronze = 1, silver = 2, gold = 3, platinum = 4, diamond = 5, champion = 6

    static func < (lhs: BadgeTier, rhs: BadgeTier) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .bronze:   return "Bronze"
        case .silver:   return "Silver"
        case .gold:     return "Gold"
        case .platinum: return "Platinum"
        case .diamond:  return "Diamond"
        case .champion: return "Champion"
        }
    }
}

struct BadgeRank: Equatable {
    let tier: BadgeTier
    let division: Int?  // 1, 2, 3 for Bronze–Diamond; nil for Champion
    let mmr: Double     // 0–1800

    init(mmr: Double) {
        let clamped = max(0, min(1800, mmr))
        self.mmr = clamped
        switch clamped {
        case 1500...:     self.tier = .champion; self.division = nil
        case 1200..<1500: self.tier = .diamond;  self.division = BadgeRank.div(base: 1200, mmr: clamped)
        case 900..<1200:  self.tier = .platinum; self.division = BadgeRank.div(base: 900,  mmr: clamped)
        case 600..<900:   self.tier = .gold;     self.division = BadgeRank.div(base: 600,  mmr: clamped)
        case 300..<600:   self.tier = .silver;   self.division = BadgeRank.div(base: 300,  mmr: clamped)
        default:          self.tier = .bronze;   self.division = BadgeRank.div(base: 0,    mmr: clamped)
        }
    }

    // Returns 1, 2, or 3 based on position within the 300-point tier band.
    private static func div(base: Double, mmr: Double) -> Int {
        min(3, Int((mmr - base) / 100) + 1)
    }

    var displayName: String {
        guard let d = division else { return tier.label }
        return "\(tier.label) \(["I","II","III"][d - 1])"
    }
}
```

- [ ] **Step 2: Build to verify no compile errors**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/BadgeTier.swift
git commit -m "feat: add BadgeTier enum and BadgeRank struct"
```

---

### Task 2: Create `BadgeID.swift`

**Files:**
- Create: `HoopTrack/HoopTrack/Models/BadgeID.swift`

- [ ] **Step 1: Create the file**

```swift
// BadgeID.swift
import Foundation

enum BadgeID: String, CaseIterable, Codable {
    // Shooting (7)
    case deadeye, sniper, quickTrigger, beyondTheArc, charityStripe, threeLevelScorer, hotHand
    // Ball Handling (5)
    case handles, ambidextrous, comboKing, floorGeneral, ballWizard
    // Athleticism (4)
    case posterizer, lightning, explosive, highFlyer
    // Consistency (4)
    case automatic, metronome, iceVeins, reliable
    // Volume & Grind (5)
    case ironMan, gymRat, workhorse, specialist, completePlayer

    var displayName: String {
        switch self {
        case .deadeye:          return "Deadeye"
        case .sniper:           return "Sniper"
        case .quickTrigger:     return "Quick Trigger"
        case .beyondTheArc:     return "Beyond the Arc"
        case .charityStripe:    return "Charity Stripe"
        case .threeLevelScorer: return "Three-Level Scorer"
        case .hotHand:          return "Hot Hand"
        case .handles:          return "Handles"
        case .ambidextrous:     return "Ambidextrous"
        case .comboKing:        return "Combo King"
        case .floorGeneral:     return "Floor General"
        case .ballWizard:       return "Ball Wizard"
        case .posterizer:       return "Posterizer"
        case .lightning:        return "Lightning"
        case .explosive:        return "Explosive"
        case .highFlyer:        return "High Flyer"
        case .automatic:        return "Automatic"
        case .metronome:        return "Metronome"
        case .iceVeins:         return "Ice Veins"
        case .reliable:         return "Reliable"
        case .ironMan:          return "Iron Man"
        case .gymRat:           return "Gym Rat"
        case .workhorse:        return "Workhorse"
        case .specialist:       return "Specialist"
        case .completePlayer:   return "Complete Player"
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/BadgeID.swift
git commit -m "feat: add BadgeID enum (25 badges across 5 categories)"
```

---

### Task 3: Create `EarnedBadge.swift` (@Model)

**Files:**
- Create: `HoopTrack/HoopTrack/Models/EarnedBadge.swift`

- [ ] **Step 1: Create the file**

```swift
// EarnedBadge.swift
import Foundation
import SwiftData

@Model final class EarnedBadge {
    var id: UUID
    var badgeID: BadgeID
    var mmr: Double          // 0–1800 continuous; tier derived via BadgeRank(mmr:)
    var earnedAt: Date       // set on first earn (cold-start)
    var lastUpdatedAt: Date  // updated each time MMR changes
    var profile: PlayerProfile?

    init(badgeID: BadgeID, initialMMR: Double, profile: PlayerProfile? = nil) {
        self.id            = UUID()
        self.badgeID       = badgeID
        self.mmr           = initialMMR
        self.earnedAt      = .now
        self.lastUpdatedAt = .now
        self.profile       = profile
    }

    /// Derived rank — never stored, always computed from current mmr.
    var rank: BadgeRank { BadgeRank(mmr: mmr) }
}
```

- [ ] **Step 2: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/EarnedBadge.swift
git commit -m "feat: add EarnedBadge SwiftData model with MMR and cold-start init"
```

---

### Task 4: Extend `TrainingSession.swift`

**Files:**
- Modify: `HoopTrack/HoopTrack/Models/TrainingSession.swift`

- [ ] **Step 1: Add four stored Phase 5A fields after the dribble aggregates block**

Find the comment `// MARK: - Relationships` and insert before it:

```swift
    // MARK: - Phase 5A Agility & Consistency Fields
    var bestShuttleRunSeconds: Double?   // best result this session
    var bestLaneAgilitySeconds: Double?  // best result this session
    var longestMakeStreak: Int           // longest consecutive makes; computed in recalculateStats()
    var shotSpeedStdDev: Double?         // std dev of shotSpeedMph; computed in recalculateStats()
```

- [ ] **Step 2: Initialise the four new fields in `init()`**

Find the line `self.shots = []` and insert before it:

```swift
        self.bestShuttleRunSeconds  = nil
        self.bestLaneAgilitySeconds = nil
        self.longestMakeStreak      = 0
        self.shotSpeedStdDev        = nil
```

- [ ] **Step 3: Add two computed vars after `var isComplete`**

```swift
    var threePointPercentage: Double? {
        let shots3 = shots.filter {
            ($0.zone == .cornerThree || $0.zone == .aboveBreakThree) && $0.result != .pending
        }
        guard !shots3.isEmpty else { return nil }
        return Double(shots3.filter { $0.result == .make }.count) / Double(shots3.count) * 100
    }

    var freeThrowPercentage: Double? {
        let ftShots = shots.filter { $0.zone == .freeThrow && $0.result != .pending }
        guard !ftShots.isEmpty else { return nil }
        return Double(ftShots.filter { $0.result == .make }.count) / Double(ftShots.count) * 100
    }
```

- [ ] **Step 4: Extend `recalculateStats()` — add streak and std dev calculations**

After the line `consistencyScore = ShotScienceCalculator.consistencyScore(releaseAngles: angles)` append:

```swift
        // Longest consecutive makes streak
        var maxStreak = 0, streak = 0
        for shot in completedShots {
            streak = shot.result == .make ? streak + 1 : 0
            maxStreak = max(maxStreak, streak)
        }
        longestMakeStreak = maxStreak

        // Shot speed population std dev
        let speeds = completedShots.compactMap { $0.shotSpeedMph }
        if speeds.count > 1 {
            let mean     = speeds.reduce(0, +) / Double(speeds.count)
            let variance = speeds.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(speeds.count)
            shotSpeedStdDev = sqrt(variance)
        } else {
            shotSpeedStdDev = nil
        }
```

- [ ] **Step 5: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrack/Models/TrainingSession.swift
git commit -m "feat: add agility fields, threePoint/FT computed vars, and streak/stddev to TrainingSession"
```

---

### Task 5: Extend `GoalRecord.swift` and `PlayerProfile.swift`

**Files:**
- Modify: `HoopTrack/HoopTrack/Models/GoalRecord.swift`
- Modify: `HoopTrack/HoopTrack/Models/PlayerProfile.swift`

- [ ] **Step 1: Add `lastMilestoneNotified` to GoalRecord**

In `GoalRecord.swift`, find `var profile: PlayerProfile?` and insert after it:

```swift
    var lastMilestoneNotified: Int = 0   // 0, 50, 75, or 100 — tracks highest fired threshold
```

No init change needed; SwiftData handles the default for migration.

- [ ] **Step 2: Add `earnedBadges` relationship and computed helpers to PlayerProfile**

In `PlayerProfile.swift`, find `@Relationship(deleteRule: .cascade) var goals: [GoalRecord]` and insert after it:

```swift
    @Relationship(deleteRule: .cascade) var earnedBadges: [EarnedBadge]
```

In the `init()`, find `self.goals = []` and add after it:

```swift
        self.earnedBadges = []
```

After the closing `}` of `var skillRatings`, add:

```swift
    var weakestSkillDimension: SkillDimension {
        skillRatings.min { $0.value < $1.value }?.key ?? .volume
    }

    var strongestSkillDimension: SkillDimension {
        skillRatings.max { $0.value < $1.value }?.key ?? .shooting
    }
```

- [ ] **Step 3: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Models/GoalRecord.swift HoopTrack/HoopTrack/Models/PlayerProfile.swift
git commit -m "feat: add lastMilestoneNotified to GoalRecord; earnedBadges and skill helpers to PlayerProfile"
```

---

### Task 6: Add normalization constants to `Constants.swift`

**Files:**
- Modify: `HoopTrack/HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Append constants inside the `SkillRating` enum**

Find the closing `}` of `enum SkillRating` (after `static let emaAlpha`) and insert before it:

```swift
        // MARK: Release angle
        static let releaseAngleOptimalMin:  Double = 43    // degrees — optimal band start
        static let releaseAngleOptimalMax:  Double = 57    // degrees — optimal band end
        static let releaseAngleFalloffMin:  Double = 30    // degrees — score = 0 below this
        static let releaseAngleFalloffMax:  Double = 70    // degrees — score = 0 above this
        static let releaseTimeEliteMs:      Double = 300   // ms — fastest expected release
        static let releaseTimeSlowMs:       Double = 800   // ms — slowest (score = 0)
        static let releaseAngleStdDevMax:   Double = 10    // degrees — worst accepted std dev

        // MARK: Shot speed
        static let shotSpeedOptimalMin:     Double = 18    // mph — optimal range start
        static let shotSpeedOptimalMax:     Double = 22    // mph — optimal range end
        static let shotSpeedStdDevMax:      Double = 5     // mph — worst accepted std dev

        // MARK: Ball handling
        static let bpsAvgMin:               Double = 2.0
        static let bpsAvgMax:               Double = 8.0
        static let bpsMaxMin:               Double = 3.0
        static let bpsMaxMax:               Double = 10.0
        static let bpsSustainedMin:         Double = 0.4   // avg/max ratio — low end
        static let bpsSustainedMax:         Double = 0.9   // avg/max ratio — elite end
        static let comboRateMax:            Double = 0.3   // combos / total dribbles cap

        // MARK: Athleticism
        static let verticalJumpMinCm:       Double = 20
        static let verticalJumpMaxCm:       Double = 90
        static let shuttleRunBestSec:       Double = 5.5   // elite shuttle run time
        static let shuttleRunWorstSec:      Double = 10.0  // slowest (score = 0)
        static let laneAgilityBestSec:      Double = 8.5
        static let laneAgilityWorstSec:     Double = 14.0

        // MARK: Consistency
        static let fgPctSessionStdDevMax:   Double = 30    // % — worst cross-session variance
        static let crossSessionMinCount:    Int    = 3     // min sessions for cross-session score

        // MARK: Volume
        static let sessionsPerWeekCap:      Double = 5
        static let shotsPerSessionMax:      Double = 200
        static let weeklyMinutesMax:        Double = 300
```

- [ ] **Step 2: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/Constants.swift
git commit -m "feat: add Phase 5A normalization constants to HoopTrack.SkillRating"
```

---

### Task 7: SwiftData schema migration and ModelContainer update

**Files:**
- Create: `HoopTrack/HoopTrack/Models/Migrations/HoopTrackSchemaV1.swift`
- Create: `HoopTrack/HoopTrack/Models/Migrations/HoopTrackMigrationPlan.swift`
- Modify: `HoopTrack/HoopTrack/HoopTrackApp.swift`

- [ ] **Step 1: Create the Migrations group directory**

```bash
mkdir -p HoopTrack/HoopTrack/Models/Migrations
```

- [ ] **Step 2: Create `HoopTrackSchemaV1.swift`**

```swift
// HoopTrackSchemaV1.swift
// Captures the original schema (before Phase 5A) for migration bookkeeping.

import SwiftData

enum HoopTrackSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self]
    }
}

enum HoopTrackSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self, EarnedBadge.self]
    }
}
```

- [ ] **Step 3: Create `HoopTrackMigrationPlan.swift`**

```swift
// HoopTrackMigrationPlan.swift
// Lightweight migration: new optional/default fields require no custom mapping.

import SwiftData

enum HoopTrackMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [HoopTrackSchemaV1.self, HoopTrackSchemaV2.self]
    }

    static var stages: [MigrationStage] { [migrateV1toV2] }

    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: HoopTrackSchemaV1.self,
        toVersion: HoopTrackSchemaV2.self
    )
}
```

- [ ] **Step 4: Update `HoopTrackApp.swift` — replace the `modelContainer` computed property**

Replace the existing `let modelContainer: ModelContainer = { ... }()` with:

```swift
    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: PlayerProfile.self, TrainingSession.self,
                     ShotRecord.self, GoalRecord.self, EarnedBadge.self,
                migrationPlan: HoopTrackMigrationPlan.self
            )
        } catch {
            fatalError("HoopTrack: Failed to create ModelContainer — \(error)")
        }
    }()
```

- [ ] **Step 5: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrack/Models/Migrations/ HoopTrack/HoopTrack/HoopTrackApp.swift
git commit -m "feat: add SwiftData V1→V2 migration plan and include EarnedBadge in ModelContainer"
```

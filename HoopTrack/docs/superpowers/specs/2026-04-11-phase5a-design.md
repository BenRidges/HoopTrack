# Phase 5A — Backend & Plumbing Design

**Date:** 2026-04-11
**Branch:** feat/phase5-goals-ratings-notifications
**Status:** Approved for implementation

---

## Goal

Deliver all backend logic for Phase 5: session finalisation orchestration, comprehensive skill ratings, a Rocket League–style badge MMR system, goal tracking, HealthKit workout logging, and notification milestone firing. No new UI views — those ship in Phase 5B.

## Architecture Overview

`SessionFinalizationCoordinator` replaces direct `DataService` calls in ViewModels. It sequences five downstream services after every session ends. All services depend on **protocols**, not concrete types (Dependency Inversion Principle), making each independently testable and swappable.

Pure calculators (`SkillRatingCalculator`, `BadgeScoreCalculator`) are `enum` namespaces of static functions with no side effects — testable without SwiftData, HealthKit, or any framework. Stateful services own EMA updates and persistence.

**Design principles applied throughout:**
- SOLID — each type has one responsibility; coordinator orchestrates, services compute
- DIP — coordinator holds protocol references, not concrete classes
- Open/Closed — add a new badge by adding a `BadgeID` case + scoring logic; zero changes elsewhere
- No magic numbers — every threshold lives in `Constants.swift` or the badge definition
- Strong types — `BadgeRank`, `SessionResult`, `BadgeTierChange` over raw primitives
- Value types for data transfer — `SessionResult`, `BadgeTierChange`, `AgilityAttempts` are structs

---

## Section 1 — Model Layer

### 1.1 `TrainingSession` additions

**Stored fields** (added to `@Model`):
```swift
var bestShuttleRunSeconds: Double?    // best shuttle run result this session
var bestLaneAgilitySeconds: Double?   // best lane agility result this session
```

**Computed vars** (derived from `shots` array, not stored):
```swift
var threePointPercentage: Double? {
    // shots in .cornerThree or .aboveBreakThree zones
}
var freeThrowPercentage: Double? {
    // shots in .freeThrow zone
}
```

**Additions to `recalculateStats()`:**
```swift
// Longest consecutive makes streak
var longestMakeStreak: Int   // stored — computed from shots sequence in recalculateStats()

// Shot speed std dev — feeds consistency rating
var shotSpeedStdDev: Double? // stored — computed from shots in recalculateStats()
```

### 1.2 `GoalRecord` addition

```swift
var lastMilestoneNotified: Int = 0   // tracks last milestone % fired: 0, 50, 75, or 100
```

### 1.3 New: `BadgeTier`

```swift
enum BadgeTier: Int, Comparable, Codable, CaseIterable {
    case bronze = 1, silver = 2, gold = 3, platinum = 4, diamond = 5, champion = 6
}
```

### 1.4 New: `BadgeRank`

```swift
struct BadgeRank: Equatable {
    let tier: BadgeTier
    let division: Int?      // 1, 2, or 3 for Bronze–Diamond; nil for Champion
    let mmr: Double         // raw 0–1800

    // Derived from mmr:
    // Bronze   I/II/III : 0–299    (each division = 100 pts)
    // Silver   I/II/III : 300–599
    // Gold     I/II/III : 600–899
    // Platinum I/II/III : 900–1199
    // Diamond  I/II/III : 1200–1499
    // Champion           : 1500+   (no divisions)
}
```

### 1.5 New: `BadgeID`

```swift
enum BadgeID: String, CaseIterable, Codable {
    // Shooting
    case deadeye, sniper, quickTrigger, beyondTheArc, charityStripe,
         threeLevelScorer, hotHand
    // Ball Handling
    case handles, ambidextrous, comboKing, floorGeneral, ballWizard
    // Athleticism
    case posterizer, lightning, explosive, highFlyer
    // Consistency
    case automatic, metronome, iceVeins, reliable
    // Volume & Grind
    case ironMan, gymRat, workhorse, specialist, completePlayer
}
```

### 1.6 New: `EarnedBadge` (`@Model`)

```swift
@Model final class EarnedBadge {
    var id: UUID
    var badgeID: BadgeID
    var mmr: Double          // 0–1800 continuous score; tier derived from this
    var earnedAt: Date       // first crossed Bronze threshold
    var lastUpdatedAt: Date  // most recent MMR change
    var profile: PlayerProfile?

    init(badgeID: BadgeID, initialMMR: Double, profile: PlayerProfile? = nil) {
        self.id = UUID()
        self.badgeID = badgeID
        self.mmr = initialMMR
        self.earnedAt = .now
        self.lastUpdatedAt = .now
        self.profile = profile
    }
}
```

Tier and division are not stored — always computed from `mmr` via `BadgeRank`.

### 1.7 `PlayerProfile` additions

```swift
@Relationship(deleteRule: .cascade) var earnedBadges: [EarnedBadge]

// Computed helpers
var weakestSkillDimension: SkillDimension { /* min of skillRatings */ }
var strongestSkillDimension: SkillDimension { /* max of skillRatings */ }
```

### 1.8 `Constants.swift` additions

All normalization reference ranges added to `HoopTrack.SkillRating`:

```swift
enum SkillRating {
    // ...existing constants...

    // Release
    static let releaseAngleOptimalMin:   Double = 43    // degrees
    static let releaseAngleOptimalMax:   Double = 57
    static let releaseAngleFalloffMin:   Double = 30
    static let releaseAngleFalloffMax:   Double = 70
    static let releaseTimeEliteMs:       Double = 300
    static let releaseTimeSlowMs:        Double = 800
    static let releaseAngleStdDevMax:    Double = 10    // degrees

    // Shot speed
    static let shotSpeedOptimalMin:      Double = 18   // mph
    static let shotSpeedOptimalMax:      Double = 22
    static let shotSpeedStdDevMax:       Double = 5

    // Ball handling
    static let bpsAvgMin:                Double = 2.0
    static let bpsAvgMax:                Double = 8.0
    static let bpsMaxMin:                Double = 3.0
    static let bpsMaxMax:                Double = 10.0
    static let bpsSustainedMin:          Double = 0.4
    static let bpsSustainedMax:          Double = 0.9
    static let comboRateMax:             Double = 0.3

    // Athleticism
    static let verticalJumpMinCm:        Double = 20
    static let verticalJumpMaxCm:        Double = 90
    static let shuttleRunBestSec:        Double = 5.5
    static let shuttleRunWorstSec:       Double = 10.0
    static let laneAgilityBestSec:       Double = 8.5
    static let laneAgilityWorstSec:      Double = 14.0

    // Consistency
    static let fgPctSessionStdDevMax:    Double = 30   // percent
    static let crossSessionMinCount:     Int    = 3    // min sessions for cross-session variance

    // Volume
    static let sessionsPerWeekCap:       Double = 5
    static let shotsPerSessionMax:       Double = 200
    static let weeklyMinutesMax:         Double = 300
}
```

### 1.9 SwiftData schema migration

Adding `EarnedBadge` (new `@Model`) and new stored properties to existing models requires a `VersionedSchema` + `SchemaMigrationPlan`.

**Steps:**
1. Define `SchemaV2` wrapping all models including `EarnedBadge`
2. Add a lightweight migration stage `V1toV2` — new optional/defaulted properties require no manual migration; SwiftData handles them automatically
3. Update `ModelContainer` in `HoopTrackApp` to include `EarnedBadge` and reference `MigrationPlan.self`

```swift
// HoopTrackApp.swift (updated container)
ModelContainer(
    for: PlayerProfile.self, TrainingSession.self,
         ShotRecord.self, GoalRecord.self, EarnedBadge.self,
    migrationPlan: HoopTrackMigrationPlan.self
)
```

New non-optional stored fields (`longestMakeStreak: Int`) must have a default value in the migration (default `0`). New optional fields (`bestShuttleRunSeconds`, etc.) are automatically `nil`.

---

## Section 2 — Badge Catalogue

25 badges across 5 categories. Each `BadgeID` declares which `DrillType`s can affect its MMR — only relevant badges are evaluated at session end.

### Session → badge mapping

| Session Type | Affected Badges |
|---|---|
| Shooting | Deadeye, Sniper, Quick Trigger, Beyond the Arc, Charity Stripe, Three-Level Scorer, Hot Hand, Automatic, Metronome, Ice Veins, Reliable, Workhorse |
| Dribble | Handles, Ambidextrous, Combo King, Floor General, Ball Wizard |
| Agility | Lightning, Posterizer, Explosive, High Flyer |
| Any | Iron Man, Gym Rat, Specialist, Complete Player |

### Scoring & MMR

Each badge has a `score(session:profile:) -> Double?` pure function returning 0–1 (nil = not applicable). The score is converted to a **target MMR** (`score × 1800`) and EMA-blended into `EarnedBadge.mmr` (`alpha = 0.3`). A badge is "earned" (first `EarnedBadge` created) on the **first session that returns a non-nil score** — i.e. any relevant session type completes with measurable data. `earnedAt` is set at that point. The visible rank (Bronze I through Champion) is derived from `mmr`.

**EMA cold-start rule:** On the very first session for a badge, there is no prior MMR to blend. Set `mmr = targetMMR` directly (skip the EMA formula). Subsequent sessions apply `mmr = mmr + alpha * (targetMMR - mmr)` as normal. This prevents a cold-start bias where the first session always drags MMR toward zero.

### Shooting Badges

| Badge | Metric | Score formula |
|---|---|---|
| **Deadeye** | FG% in session (min 20 shots) | `normalize(fgPct, 0, 100)` |
| **Sniper** | Release angle std dev (min 20 shots) | `normalize(stdDevMax - stdDev, 0, stdDevMax)` |
| **Quick Trigger** | Avg release time (min 20 shots) | `normalize(slowMs - avgMs, 0, slowMs - eliteMs)` |
| **Beyond the Arc** | 3PT% in session (min 10 attempts) | `normalize(threePct, 0, 100)` |
| **Charity Stripe** | FT% in session (min 10 attempts) | `normalize(ftPct, 0, 100)` |
| **Three-Level Scorer** | Makes from paint + mid + 3PT zones in one session | Avg of zone FG% scores (each zone min 3 attempts, 0 if zone absent) |
| **Hot Hand** | Longest consecutive makes streak | `normalize(streak, 0, 15)` |

### Ball Handling Badges

| Badge | Metric | Score formula |
|---|---|---|
| **Handles** | Avg BPS in session | `normalize(avgBPS, bpsAvgMin, bpsAvgMax)` |
| **Ambidextrous** | Hand balance (min 100 dribbles) | `1 - abs(balance - 0.5) * 2` |
| **Combo King** | Combos detected (min 100 dribbles) | `normalize(combos, 0, 50)` |
| **Floor General** | Sustained BPS ratio avg/max (min 60s, avgBPS ≥ 3) | `normalize(ratio, bpsSustainedMin, bpsSustainedMax)` |
| **Ball Wizard** | Career total dribbles | `normalize(total, 0, 50_000)` |

### Athleticism Badges

| Badge | Metric | Score formula |
|---|---|---|
| **Posterizer** | Avg vertical jump in session | `normalize(jumpCm, verticalJumpMinCm, verticalJumpMaxCm)` |
| **Lightning** | Best shuttle run in session | `normalize(shuttleWorst - seconds, 0, shuttleWorst - shuttleBest)` |
| **Explosive** | Athleticism dimension rating | `normalize(ratingAthleticism, 0, 100)` — reads `profile.ratingAthleticism` which must be updated by `SkillRatingService` (coordinator step 4) **before** `BadgeEvaluationService` runs (step 5); the coordinator sequence guarantees this ordering |
| **High Flyer** | Career best vertical (`prVerticalJumpCm`) | `normalize(prJumpCm, verticalJumpMinCm, verticalJumpMaxCm)` |

### Consistency Badges

| Badge | Metric | Score formula |
|---|---|---|
| **Automatic** | Cross-session FG% std dev (last 10, min 3) | `normalize(stdDevMax - stdDev, 0, stdDevMax)` |
| **Metronome** | Career avg release angle std dev (min 10 sessions) | `normalize(stdDevMax - careerAvgStdDev, 0, stdDevMax)` |
| **Ice Veins** | Career FT% (min 50 FT attempts) | `normalize(careerFTPct, 0, 100)` |
| **Reliable** | Consecutive sessions with FG% ≥ 40% | `normalize(streak, 0, 12)` — streak computed by iterating `profile.sessions` sorted by `startedAt` descending, counting leading shooting sessions where `fgPercent ≥ 40%`, stopping at first miss or non-shooting session |

### Volume & Grind Badges

| Badge | Metric | Score formula |
|---|---|---|
| **Iron Man** | Longest training streak (`longestStreakDays`) | `normalize(days, 0, 60)` |
| **Gym Rat** | Sessions in rolling 7-day window | `normalize(count, 0, sessionsPerWeekCap)` |
| **Workhorse** | Career total shots attempted | `normalize(total, 0, 15_000)` |
| **Specialist** | Max sessions of any single drill type (career) | `normalize(max, 0, 100)` |
| **Complete Player** | Min of all 5 skill dimension ratings | `normalize(minRating, 0, 100)` |

### Badge downgrade behaviour

MMR decays naturally via EMA — a weak session pulls the score toward a lower target. Career-accumulation badges (Ball Wizard, Workhorse, Iron Man) use monotonically increasing inputs and therefore only ever gain MMR. Session-performance badges can lose MMR through underperformance.

---

## Section 3 — Service Layer

### 3.1 Service protocols (Dependency Inversion)

```swift
@MainActor protocol GoalUpdateServiceProtocol {
    func update(after session: TrainingSession, profile: PlayerProfile) throws
}

@MainActor protocol SkillRatingServiceProtocol {
    func recalculate(for profile: PlayerProfile, session: TrainingSession) throws
}

@MainActor protocol BadgeEvaluationServiceProtocol {
    func evaluate(session: TrainingSession,
                  profile: PlayerProfile) throws -> [BadgeTierChange]
}

@MainActor protocol HealthKitServiceProtocol {
    func requestPermission() async
    func writeWorkout(for session: TrainingSession) async throws
}
```

All concrete services are `@MainActor final class` conforming to their protocol. `SessionFinalizationCoordinator` holds protocol references only. `@MainActor` on the protocols ensures the coordinator (also `@MainActor`) can call protocol requirements without additional `await` — required for Swift 6 strict concurrency correctness.

> **Note:** `NotificationService` is not wrapped in a protocol here because it is already an `ObservableObject` environment object shared across the app — extracting a protocol adds complexity without a concrete test-isolation benefit (notification side effects are not unit-tested). If a future phase requires a mock notification service, extract `NotificationServiceProtocol` at that point.

### 3.2 `SkillRatingCalculator` — pure functions

```swift
enum SkillRatingCalculator {
    static func normalize(_ value: Double, min: Double, max: Double) -> Double

    static func shootingScore(
        fgPct: Double, threePct: Double?, ftPct: Double?,
        releaseAngleDeg: Double?, releaseAngleStdDev: Double?,
        releaseTimeMs: Double?, shotSpeedMph: Double?,
        shotSpeedStdDev: Double?, threeAttemptFraction: Double?
    ) -> Double?

    static func ballHandlingScore(
        avgBPS: Double?, maxBPS: Double?,
        handBalance: Double?, combos: Int, totalDribbles: Int
    ) -> Double?

    static func athleticismScore(
        verticalJumpCm: Double?, shuttleRunSec: Double?
    ) -> Double?

    static func consistencyScore(
        releaseAngleStdDev: Double?, fgPctHistory: [Double],
        ftPct: Double?, shotSpeedStdDev: Double?
    ) -> Double?

    static func volumeScore(
        sessionsLast4Weeks: Int, avgShotsPerSession: Double,
        weeklyTrainingMinutes: Double, drillVarietyLast14Days: Double
    ) -> Double

    static func overallScore(
        shooting: Double?, handling: Double?,
        athleticism: Double?, consistency: Double?, volume: Double
    ) -> Double
}
```

> **Value-type boundary:** `SkillRatingService` is responsible for extracting all primitive values from `TrainingSession` and `PlayerProfile` before calling into `SkillRatingCalculator`. The calculator itself has zero SwiftData dependencies — its functions are pure over Swift primitives and are directly unit-testable without a `ModelContainer`.

**Shooting score sub-factors** (nil-skip, weights redistribute proportionally):
- FG% normalized — weight 0.25
- 3PT% — weight 0.20 *(nil-skip)*
- FT% — weight 0.15 *(nil-skip)*
- Release angle quality (100 in 43–57°, linear falloff to 0 at 30°/70°) — weight 0.15 *(nil-skip)*
- Release time quality (`normalize(slowMs - avgMs, 0, slowMs - eliteMs)`) — weight 0.10 *(nil-skip)*
- Shot speed quality (100 at 18–22 mph, falloff outside) — weight 0.10 *(nil-skip)*
- Zone difficulty (% attempts from 3PT zones, normalized 0–60%) — weight 0.05 *(nil-skip)*

**Ball handling score sub-factors:**
- Avg BPS — weight 0.30
- Max BPS — weight 0.15
- Sustained ratio (avg/max) — weight 0.15
- Hand balance (`1 - abs(balance - 0.5) * 2`) — weight 0.25
- Combo rate (combos / max(totalDribbles,1)) — weight 0.15

**Athleticism score sub-factors** (nil-skip; weights shift to vertical when shuttle absent):
- Vertical jump — weight 0.60 (1.0 when shuttle nil)
- Shuttle run (inverted) — weight 0.40 *(nil-skip)*
- Lane agility (inverted) — weight 0.00 *(Phase 5B — nil-skip placeholder)*
- Strength — TODO (backlog)

**Consistency score sub-factors:**
- Release angle std dev (inverted) — weight 0.35 *(nil-skip)*
- Cross-session FG% std dev (inverted, last 10 sessions, min 3) — weight 0.30
- FT% as mechanics baseline — weight 0.20 *(nil-skip)*
- Shot speed std dev (inverted) — weight 0.15 *(nil-skip)*
- Cross-session minimum: defaults to 0.5 (neutral) when fewer than `crossSessionMinCount` sessions exist

**Volume score sub-factors:**
- Sessions/week last 4 weeks (capped at 5) — weight 0.35
- Avg shots/session — weight 0.25
- Weekly training minutes — weight 0.20
- Drill variety (distinct DrillTypes last 14 days / 4) — weight 0.20

**Overall:** uses existing `HoopTrack.SkillRating` weight constants.

### 3.3 `SkillRatingService` — EMA updates

```swift
@MainActor final class SkillRatingService: SkillRatingServiceProtocol {
    func recalculate(for profile: PlayerProfile, session: TrainingSession) throws
}
```

Calls `SkillRatingCalculator` for each dimension. Applies EMA (`alpha = 0.3`) to each non-nil score. Nil dimensions are left unchanged. Removes `updateBallHandlingRating` from `DataService` (logic migrated here).

### 3.4 `BadgeScoreCalculator` — pure functions

```swift
enum BadgeScoreCalculator {
    static func score(for badgeID: BadgeID,
                      session: TrainingSession,
                      profile: PlayerProfile) -> Double?

    static func affectedDrillTypes(for badgeID: BadgeID) -> Set<DrillType>
}
```

`score` returns 0–1, or `nil` if the session's drill type doesn't affect this badge. Internally routes to per-badge private functions — one function per badge. Each private function takes **only primitive value types** (e.g. `fgPct: Double`, `streak: Int`) extracted from the models by the public entry point. This keeps all 25 per-badge functions directly unit-testable without a `ModelContainer`, while the public `score(for:session:profile:)` entry point handles SwiftData model access in one place.

### 3.5 `BadgeEvaluationService` — MMR delta

```swift
@MainActor final class BadgeEvaluationService: BadgeEvaluationServiceProtocol {
    func evaluate(session: TrainingSession,
                  profile: PlayerProfile) throws -> [BadgeTierChange]
}

struct BadgeTierChange: Equatable {
    let badgeID: BadgeID
    let previousRank: BadgeRank?   // nil = first earn
    let newRank: BadgeRank
}
```

For each `BadgeID`:
1. Check `affectedDrillTypes` — skip if session type not relevant
2. Call `BadgeScoreCalculator.score` — skip if nil
3. Convert score to target MMR: `targetMMR = score * 1800`
4. Apply EMA to `EarnedBadge.mmr` (create `EarnedBadge` on first earn, using cold-start rule)
5. Derive new `BadgeRank` from updated mmr
6. Record `BadgeTierChange` if rank changed

**Error handling:** Individual badge evaluation errors (e.g. unexpected nil, out-of-range data) are **non-fatal and silently swallowed per badge** — a failure on one badge must not block the others or the overall finalisation flow. The coordinator calls `evaluate` with `try?` rather than propagating badge errors upward. Errors that indicate data corruption (e.g. SwiftData write failure) are allowed to propagate from the `throws` signature so the coordinator can surface them.

### 3.6 `GoalUpdateService`

```swift
@MainActor final class GoalUpdateService: GoalUpdateServiceProtocol {
    func update(after session: TrainingSession, profile: PlayerProfile) throws
}
```

**GoalMetric → source mapping:**

| GoalMetric | Source |
|---|---|
| `fgPercent` | `session.fgPercent` |
| `threePointPercent` | `session.threePointPercentage` |
| `freeThrowPercent` | `session.freeThrowPercentage` |
| `verticalJumpCm` | `session.avgVerticalJumpCm` |
| `dribbleSpeedHz` | `session.avgDribblesPerSec` |
| `shuttleRunSeconds` | `session.bestShuttleRunSeconds` |
| `overallRating` | `profile.ratingOverall` |
| `shootingRating` | `profile.ratingShooting` |
| `sessionsPerWeek` | count of `profile.sessions` with `startedAt` in last 7 days |

Sets `goal.isAchieved = true` and `goal.achievedAt = .now` when `currentValue >= targetValue`.

### 3.7 `HealthKitService`

```swift
@MainActor final class HealthKitService: HealthKitServiceProtocol {
    func requestPermission() async
    func writeWorkout(for session: TrainingSession) async throws
}
```

Writes `HKWorkout` of type `.basketball` using `session.startedAt`, `session.endedAt`, and `session.durationSeconds`. Checks `HKHealthStore.authorizationStatus` before writing — never throws on permission denial (silent failure; coordinator swallows HealthKit errors). Never reads HealthKit data.

### 3.8 `NotificationService` additions

```swift
// Training reminder (separate identifier from streak reminder)
func scheduleTrainingReminder(hour: Int)
func cancelTrainingReminder()

// Milestone alerts — fires immediate notification when goal crosses 50/75/100% for first time
func checkMilestones(for goals: [GoalRecord])
```

`checkMilestones` compares `goal.progressPercent` to `goal.lastMilestoneNotified`. Fires a `UNTimeIntervalNotificationTrigger(timeInterval: 1)` alert for each newly crossed threshold, then updates `goal.lastMilestoneNotified`.

---

## Section 4 — `SessionFinalizationCoordinator`

### Interface

```swift
@MainActor final class SessionFinalizationCoordinator {

    init(
        dataService: DataService,
        goalUpdateService: GoalUpdateServiceProtocol,
        healthKitService: HealthKitServiceProtocol,
        skillRatingService: SkillRatingServiceProtocol,
        badgeEvaluationService: BadgeEvaluationServiceProtocol,
        notificationService: NotificationService
    )

    func finaliseSession(_ session: TrainingSession) async throws -> SessionResult
    func finaliseDribbleSession(_ session: TrainingSession,
                                metrics: DribbleLiveMetrics) async throws -> SessionResult
    func finaliseAgilitySession(_ session: TrainingSession,
                                attempts: AgilityAttempts) async throws -> SessionResult
}

struct AgilityAttempts {
    var bestShuttleRunSeconds: Double?
    var bestLaneAgilitySeconds: Double?
}

struct SessionResult {
    let session: TrainingSession
    let badgeChanges: [BadgeTierChange]
}
```

### Execution sequence

```
1. DataService.finalise*Session(...)              — stamp endedAt, recalculate stats, persist
2. GoalUpdateService.update(after:profile:)        — update goal currentValues + isAchieved
3. try? HealthKitService.writeWorkout(for:)        — async; errors silently swallowed
4. SkillRatingService.recalculate(for:session:)   — EMA all 5 skill dimensions
5. BadgeEvaluationService.evaluate(session:profile:) — MMR delta for relevant badges
6. NotificationService.checkMilestones(for:)      — fire milestone alerts
7. return SessionResult(session, badgeChanges)
```

Steps 1–2 are strictly sequential. Step 3 is `async` but non-blocking — failure is silent. Steps 4–5 are sequential (`Complete Player` badge reads freshly updated ratings). Step 6 fires last so milestone notifications see post-update goal state.

### ViewModel changes

- `LiveSessionViewModel.endSession()` — replaces `dataService.finaliseSession` with `await coordinator.finaliseSession`; stores `SessionResult` as `@Published var sessionResult: SessionResult?`
- `DribbleSessionViewModel.endSession()` — same pattern with `finaliseDribbleSession`
- `DataService.updateBallHandlingRating` — **removed** (migrated to `SkillRatingService`)

### App-level injection (`HoopTrackApp`)

All services constructed once as `@StateObject`. `SessionFinalizationCoordinator` injected as an environment object alongside `DataService`, `NotificationService`, etc.

---

## Testing

Pure calculators are the primary test targets — no SwiftData, no frameworks required.

| Test file | Covers |
|---|---|
| `SkillRatingCalculatorTests.swift` | `normalize`, all five dimension score functions, nil-skip weight redistribution, `overallScore` |
| `BadgeScoreCalculatorTests.swift` | All 25 badge score functions, `affectedDrillTypes` mapping, nil returns for wrong session type |
| `GoalUpdateServiceTests.swift` | All 9 GoalMetric mappings, `isAchieved` flag, `sessionsPerWeek` count |

No mocks, no SwiftData in tests — calculators are pure functions over value types.

---

## Files changed

**New (11):**
- `HoopTrack/Services/SessionFinalizationCoordinator.swift`
- `HoopTrack/Services/GoalUpdateService.swift`
- `HoopTrack/Services/SkillRatingService.swift`
- `HoopTrack/Services/BadgeEvaluationService.swift`
- `HoopTrack/Services/HealthKitService.swift`
- `HoopTrack/Utilities/SkillRatingCalculator.swift`
- `HoopTrack/Utilities/BadgeScoreCalculator.swift`
- `HoopTrack/Models/EarnedBadge.swift`
- `HoopTrack/Models/BadgeID.swift`
- `HoopTrack/Models/BadgeTier+BadgeRank.swift`
- `HoopTrack/docs/superpowers/backlog.md`

**Modified (9):**
- `HoopTrack/Models/TrainingSession.swift`
- `HoopTrack/Models/GoalRecord.swift`
- `HoopTrack/Models/PlayerProfile.swift`
- `HoopTrack/Utilities/Constants.swift`
- `HoopTrack/Services/DataService.swift`
- `HoopTrack/Services/NotificationService.swift`
- `HoopTrack/HoopTrackApp.swift` — update `ModelContainer` to include `EarnedBadge.self` and reference `HoopTrackMigrationPlan.self` (see §1.9)
- `HoopTrack/ViewModels/LiveSessionViewModel.swift`
- `HoopTrack/ViewModels/DribbleSessionViewModel.swift`

**New migration files (2):**
- `HoopTrack/Models/Migrations/HoopTrackSchemaV1.swift` — `VersionedSchema` wrapping all V1 models
- `HoopTrack/Models/Migrations/HoopTrackMigrationPlan.swift` — `SchemaMigrationPlan` with `V1toV2` lightweight migration stage

**New test files (3):**
- `HoopTrackTests/SkillRatingCalculatorTests.swift`
- `HoopTrackTests/BadgeScoreCalculatorTests.swift`
- `HoopTrackTests/GoalUpdateServiceTests.swift`

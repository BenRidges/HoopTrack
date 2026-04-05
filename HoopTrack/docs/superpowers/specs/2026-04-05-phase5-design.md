# Phase 5: Goals, Notifications, Agility, HealthKit, Skill Ratings — Design Spec

## Goal

Complete the five remaining subsystems in HoopTrack Phase 5: Goal Management, Notifications, Agility Drills, HealthKit integration, and full Skill Rating computation across all dimensions.

---

## Architecture

### SessionFinalizationCoordinator

A new `@MainActor final class SessionFinalizationCoordinator` is called by each ViewModel after a session ends. It sequences all post-session work in order:

1. `DataService.finalise*Session(...)` — persists the session record
2. `GoalUpdateService.update(after:)` — maps session metrics to goal `currentValue`s
3. `HealthKitService.writeWorkout(for:)` — logs Basketball workout + estimated calories
4. `SkillRatingService.recalculate(for:)` — recomputes all 4 skill rating dimensions via EMA
5. `NotificationService.checkMilestones(for:)` — fires goal milestone alerts if thresholds crossed

Each service is a `@MainActor final class`, injected into `SessionFinalizationCoordinator` via its initializer so each is independently testable.

### New Files

- `HoopTrack/Services/SessionFinalizationCoordinator.swift`
- `HoopTrack/Services/GoalUpdateService.swift`
- `HoopTrack/Services/HealthKitService.swift`
- `HoopTrack/Services/SkillRatingService.swift`
- `HoopTrack/Views/Train/AgilityDrillView.swift`
- `HoopTrack/Views/Train/AgilitySessionSummaryView.swift`
- `HoopTrack/ViewModels/AgilitySessionViewModel.swift`

### Modified Files

- `HoopTrack/Models/TrainingSession.swift` — add 3 agility fields
- `HoopTrack/Models/GoalRecord.swift` — add `lastMilestoneNotified: Int` field
- `HoopTrack/Services/DataService.swift` — remove inline goal/rating update logic, delegate to coordinator
- `HoopTrack/Services/NotificationService.swift` — implement real UNUserNotificationCenter scheduling
- `HoopTrack/Utilities/Constants.swift` — add `HoopTrack.SkillRating` reference ranges
- `HoopTrack/Views/Train/TrainTabView.swift` — add `.agility` fullScreenCover branch
- `HoopTrack/Views/Progress/ProgressTabView.swift` — replace `GoalListView` stub
- `HoopTrack/Views/Profile/ProfileTabView.swift` — wire `NotificationSettingsView`

---

## Subsystem 1: Goal Management

### GoalListView

Replaces the `"Goal management — coming in Phase 5"` stub in `ProgressTabView`. Displays active goals as a list with progress bars. A "+" toolbar button opens a create/edit sheet.

**Create/Edit sheet fields:**
- `GoalMetric` picker (enum cases listed below)
- Target value input (numeric)
- Optional deadline `DatePicker`

`GoalRecord` already has all required fields: `metric`, `targetValue`, `currentValue`, `deadline`, `isCompleted`.

### GoalUpdateService

`GoalUpdateService.update(after session: TrainingSession)` fetches all incomplete goals and updates `currentValue` to the latest session value for the matching metric. Goals track "current level" — `currentValue` is always the most recent session value, not a running average.

A goal is marked `isCompleted = true` when `currentValue >= targetValue`.

**Metric → Session field mapping:**

| GoalMetric | TrainingSession field |
|---|---|
| `fgPercent` | `fieldGoalPercentage` |
| `threePointPercent` | `threePointPercentage` |
| `freeThrowPercent` | `freeThrowPercentage` |
| `verticalJumpCm` | `avgVerticalJumpCm` |
| `dribbleSpeedHz` | `avgDribbleBPS` |
| `shuttleRunSeconds` | `bestShuttleRunSeconds` |
| `overallRating` | `ratingOverall` |
| `shootingRating` | `ratingShooting` |
| `sessionsPerWeek` | computed: count of sessions in last 7 days |

---

## Subsystem 2: Notifications

### NotificationService

Wraps `UNUserNotificationCenter` with three notification types.

**Streak reminders**
Scheduled daily at the user's chosen training reminder time. When `SessionFinalizationCoordinator` completes successfully, `NotificationService` cancels any pending streak reminder and reschedules it for the following day — ensuring the user is never reminded on a day they've already trained.

**Training reminders**
A separate daily repeating `UNNotificationRequest` at a user-configured time (default 6 PM). Toggled on/off and time-configured in `NotificationSettingsView`.

**Goal milestone alerts**
Fired immediately (not scheduled) by `NotificationService.checkMilestones(for goals: [GoalRecord])` when a goal's `currentValue` crosses 50%, 75%, or 100% of `targetValue` for the first time. Tracked via `lastMilestoneNotified: Int` on `GoalRecord` (stores last milestone % notified, e.g. 75). Prevents duplicate alerts across sessions.

### NotificationSettingsView Changes

- Replace all `.constant(true)` toggles with real `@AppStorage` booleans
- Add `DatePicker` for training reminder time (stored as `@AppStorage` `TimeInterval` since midnight)
- Authorization requested lazily on first toggle-on via `UNUserNotificationCenter.current().requestAuthorization`

---

## Subsystem 3: Agility Drills

### Routing

`TrainTabView` gains an `else if drill.drillType == .agility` branch alongside the existing `.dribble` branch, presenting `AgilityDrillView` as a `fullScreenCover`.

### AgilityDrillView

Shared view for all three agility drill types (`shuttleRun`, `laneAgility`, `verticalJumpTest`). Displays:
- Drill name + instructions text
- Countdown duration picker (3s / 5s / 10s)
- Large countdown display during countdown phase
- Live elapsed timer during running phase
- "Stop" button to record result

### AgilitySessionViewModel

`@MainActor final class` managing four states:

```swift
enum AgilityState {
    case idle
    case countdown(remaining: Int)
    case running(elapsed: TimeInterval)
    case finished(result: AgilityAttempt)
}
```

Uses `Timer.publish(every: 1, on: .main, in: .common)` for countdown and `Timer.publish(every: 0.01, ...)` for elapsed time precision.

After stopping, the user sees their result with "Try Again" (resets to `.idle`) and "Finish Session" (saves and navigates to `AgilitySessionSummaryView`) buttons.

### AgilityAttempt

A simple value type used within the ViewModel session, not persisted directly — session aggregates are written to `TrainingSession`.

```swift
struct AgilityAttempt {
    let drillType: DrillType
    let value: Double  // seconds for timed drills, cm for vertical jump
}
```

### TrainingSession New Fields

```swift
var bestShuttleRunSeconds: Double?    // Shuttle Run — best attempt in session
var bestLaneAgilitySeconds: Double?   // Lane Agility — best attempt in session
var avgVerticalJumpCm: Double?        // Vertical Jump — average of attempts
```

### AgilitySessionSummaryView

Shows final result(s) for the session, best time or height, and a "Done" button that dismisses back to `TrainTabView`.

---

## Subsystem 4: HealthKit

### HealthKitService

`@MainActor final class` with two responsibilities: authorization and writing workouts.

**Authorization**
Requests read/write for `HKWorkoutType` and write for `HKQuantityType.activeEnergyBurned`. Requested lazily on first `writeWorkout` call. If denied or unavailable, silently skips — HealthKit writes are best-effort and produce no user-facing error.

**Workout Write**
After each session finalizes:
- `workoutActivityType: .basketball`
- `startDate`: `session.startedAt`
- `endDate`: `session.endedAt`
- Estimated active calories: `session.durationSeconds * 0.13` kcal/sec (~8 kcal/min)

No UI changes required. HealthKit writes happen silently for all sessions if authorization is granted.

---

## Subsystem 5: Skill Rating

### SkillRatingService

`SkillRatingService.recalculate(for player: PlayerProfile)` recomputes all 4 skill rating dimensions using EMA (α = `HoopTrack.SkillRating.emaAlpha` = 0.3) after each session. Pulls from all `TrainingSession` history attached to `PlayerProfile`.

**Shooting** (`ratingShooting`)
Inputs from ShotScience sessions:
- `fieldGoalPercentage` (weight: 0.35)
- `threePointPercentage` (weight: 0.25)
- `freeThrowPercentage` (weight: 0.20)
- `avgReleaseAngle` — scored against optimal range 45°–55° (weight: 0.10)
- `releaseAngleConsistency` — stdDev inverted, lower = better (weight: 0.10)

Each input normalized to 0–100 using reference ranges in `Constants.swift`. Weighted average → EMA into `ratingShooting`.

**Consistency** (`ratingConsistency`)
Inputs from last 10 sessions:
- stdDev of `avgReleaseAngle` across sessions (inverted — lower variance = higher score, weight: 0.35)
- stdDev of `avgDribbleBPS` across sessions (inverted, weight: 0.35)
- Session frequency: count of sessions in last 14 days normalized against a 14-session ideal (weight: 0.30)

Weighted average → EMA into `ratingConsistency`.

**Athleticism** (`ratingAthleticism`)
Inputs:
- `bestShuttleRunSeconds` — inverted against reference range (weight: 0.30)
- `bestLaneAgilitySeconds` — inverted against reference range (weight: 0.30)
- `avgVerticalJumpCm` — normalized against reference range (weight: 0.25)
- `maxDribbleBPS` — normalized against reference range (weight: 0.15)

Weighted average → EMA into `ratingAthleticism`.

**Overall** (`ratingOverall`)
Weighted average of all four skill ratings:
- `ratingShooting`: 30%
- `ratingConsistency`: 25%
- `ratingAthleticism`: 25%
- `ratingBallHandling`: 20%

EMA into `ratingOverall`.

### Constants.swift Additions

New constants in `HoopTrack.SkillRating` namespace:

```swift
// Reference ranges for normalization
static let optimalReleaseAngleMin: Double = 45.0
static let optimalReleaseAngleMax: Double = 55.0
static let maxReleaseAngleStdDev: Double = 15.0   // stdDev above this = 0 score
static let maxBPSStdDev: Double = 2.0
static let idealSessionsPerTwoWeeks: Int = 14
static let shuttleRunRefSeconds: Double = 5.0     // elite reference
static let shuttleRunMaxSeconds: Double = 9.0     // beginner reference
static let laneAgilityRefSeconds: Double = 10.0
static let laneAgilityMaxSeconds: Double = 16.0
static let verticalJumpRefCm: Double = 70.0       // elite reference
static let verticalJumpMinCm: Double = 20.0
static let maxDribbleBPSRef: Double = 8.0
```

---

## Testing Strategy

Each new service has a unit test file:
- `GoalUpdateServiceTests.swift` — verify metric mapping, isCompleted flag, sessionsPerWeek computation
- `HealthKitServiceTests.swift` — mock HKHealthStore, verify workout parameters
- `SkillRatingServiceTests.swift` — verify each dimension formula, EMA application, nil handling when sessions missing
- `NotificationServiceTests.swift` — mock UNUserNotificationCenter, verify scheduling and milestone thresholds
- `SessionFinalizationCoordinatorTests.swift` — verify call order and that each service receives correct inputs

Agility drill logic tested via `AgilitySessionViewModelTests.swift` — state transitions, attempt aggregation.

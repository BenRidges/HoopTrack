# Phase 5B — UI Layer Design

**Date:** 2026-04-12
**Branch:** claude/zealous-blackburn
**Status:** Approved for implementation

---

## Goal

Deliver all user-facing surfaces that make Phase 5A's backend visible and useful: agility drill recording, post-session badge feedback, a full badge browser, real goal management, and a training reminder setting. No new SwiftData models are needed — all data types ship in Phase 5A.

---

## Design Principles

The same principles that governed Phase 5A apply here:

- **SOLID** — each type has one responsibility; view models own state and business logic, views own layout only
- **DIP** — `AgilitySessionViewModel` depends on `AgilityDetectionServiceProtocol`, never the concrete implementation; swapping clap detection in later is a one-line change
- **Open/Closed** — `BadgeID.skillDimension` is the single source for badge-to-category grouping; no switch in the view layer
- **MVVM** — views are layout-only; all derived data lives in view models
- **Swift 6 strict concurrency** — all view models and services are `@MainActor final class`; no `nonisolated(unsafe)` hacks
- **Value types at boundaries** — `[BadgeTierChange]`, `AgilityAttempts` flow through views as plain structs, never as model objects

---

## Section 1 — Agility Drill

### 1.1 Detection protocol

```swift
// AgilityDetectionServiceProtocol.swift
@MainActor protocol AgilityDetectionServiceProtocol: AnyObject {
    /// Called on the main actor each time the user signals start/stop.
    var onTrigger: (() -> Void)? { get set }
    func startListening()
    func stopListening()
}
```

The protocol is the **only** type `AgilitySessionViewModel` references. This boundary is what makes clap detection a future drop-in.

### 1.2 `VolumeButtonAgilityDetectionService`

Monitors `AVAudioSession.outputVolume` via KVO. Immediately resets to 0.5 after each press to prevent the system volume from drifting. Requires an active `AVAudioSession` (`.ambient` category) started in `startListening()` and stopped in `stopListening()`.

```swift
@MainActor final class VolumeButtonAgilityDetectionService: AgilityDetectionServiceProtocol {
    var onTrigger: (() -> Void)?
    private var observation: NSKeyValueObservation?

    func startListening() {
        // Activate audio session, observe outputVolume KVO, reset to 0.5 on change
    }
    func stopListening() {
        observation?.invalidate()
        observation = nil
        // Deactivate audio session
    }
}
```

> **Future swap:** `ClapAgilityDetectionService` conforms to the same protocol using `AVAudioEngine` PCM tap + transient threshold detection. Zero changes to `AgilitySessionViewModel` required.

### 1.3 `AgilitySessionViewModel`

```swift
@MainActor final class AgilitySessionViewModel: ObservableObject {

    enum TimerState { case idle, running, recorded }
    enum AgilityMetric { case shuttleRun, laneAgility }

    // Published state
    @Published var timerState: TimerState = .idle
    @Published var selectedMetric: AgilityMetric = .shuttleRun
    @Published var elapsedSeconds: Double = 0
    @Published var shuttleAttempts: [Double] = []
    @Published var laneAttempts:    [Double] = []
    @Published var isFinished: Bool = false
    @Published var isSaving: Bool = false
    @Published var errorMessage: String?
    @Published var sessionResult: SessionResult?

    // Computed
    var bestShuttleSeconds: Double? { shuttleAttempts.min() }
    var bestLaneSeconds:    Double? { laneAttempts.min() }
    var currentAttempts:    [Double] {
        selectedMetric == .shuttleRun ? shuttleAttempts : laneAttempts
    }

    // Dependencies — injected via configure()
    private var detectionService: AgilityDetectionServiceProtocol!
    private var coordinator: SessionFinalizationCoordinator!
    private var dataService: DataService!
    private var session: TrainingSession?
    private var timerCancellable: AnyCancellable?
}
```

**State machine** — each Vol+ press advances:

```
idle ──(trigger)──► running ──(trigger)──► recorded
 ▲                                             │
 └────────────(auto after 1.5s)────────────────┘
```

In `running`, a Combine timer publishes every 0.01s to `elapsedSeconds`. On transition to `recorded`, the elapsed time is appended to the correct attempts array and `elapsedSeconds` resets to 0.

**Lifecycle:**
```swift
func configure(dataService: DataService,
               coordinator: SessionFinalizationCoordinator,
               detectionService: AgilityDetectionServiceProtocol) { ... }

func start(namedDrill: NamedDrill?) throws   // creates TrainingSession
func endSession() async                       // calls coordinator.finaliseAgilitySession
```

`endSession()` builds `AgilityAttempts(bestShuttleRunSeconds: bestShuttleSeconds, bestLaneAgilitySeconds: bestLaneSeconds)` and calls `coordinator.finaliseAgilitySession(_:attempts:)`.

### 1.4 `AgilitySessionView`

Full-screen view (`.statusBarHidden(true)`, same pattern as `LiveSessionView`).

**Layout (top → bottom):**
1. **Metric selector** — segmented `Picker` (Shuttle Run / Lane Agility) at top
2. **Timer display** — large monospaced countdown `MM:SS.hh`, orange when running, white when idle
3. **Trigger cue** — pulsing ring with label: "Vol+ to start" (idle) or "Vol+ to stop" (running)
4. **Attempt history** — last 3 attempts in descending order; best highlighted in orange with `trophy.fill` icon; empty state: "No attempts yet"
5. **Best time banner** — persistent strip showing current best for each metric; hidden until at least one attempt recorded
6. **End session** — long-press button (same 1.5s gesture as `LiveSessionView`)

**Wiring in `.task`:**
```swift
viewModel.configure(
    dataService:      DataService(modelContext: modelContext),
    coordinator:      coordinator,
    detectionService: VolumeButtonAgilityDetectionService()
)
try? viewModel.start(namedDrill: namedDrill)
```

Detection service is instantiated here (not in the view model) so a test or future caller can inject any conforming type.

**`.fullScreenCover`** on `isFinished` → `AgilitySessionSummaryView`.

### 1.5 `AgilitySessionSummaryView`

Mirrors `DribbleSessionSummaryView` structure:
- Hero stats: best shuttle time, best lane agility time, total attempts, session duration
- Attempt log: each attempt listed with delta vs best
- Badges Updated section (same component as §2 below)
- Done button → `onFinish()`

### 1.6 `TrainTabView` routing

Add `.agility` to the `fullScreenCover` routing switch:

```swift
} else if drill.drillType == .agility {
    AgilitySessionView(namedDrill: drill) {
        isShowingLiveSession = false
        drillToLaunch        = nil
    }
}
```

---

## Section 2 — Post-Session Badge Feedback

### 2.1 `BadgesUpdatedSection`

A standalone SwiftUI `View` component:

```swift
struct BadgesUpdatedSection: View {
    let changes: [BadgeTierChange]   // empty → view renders nothing (no `if` in caller)
    var body: some View { ... }
}
```

Hidden entirely when `changes.isEmpty` — callers pass `badgeChanges` unconditionally; the component owns the empty-state guard. This keeps the call sites clean.

**Each row:**
- Left: `Image(systemName: badgeID.skillDimension.systemImage)` — reuses the existing `SkillDimension` icons
- Center: badge `displayName`
- Right: rank change label
  - First earn: `"Earned · Bronze I"` (orange)
  - Tier promoted: `"Silver II → Gold I"` (green)
  - Division promoted within tier: `"Bronze I → Bronze II"` (blue)
  - MMR moved but rank unchanged: row **not shown** (rank equality check filters it out before reaching the component)

### 2.2 Updates to existing summary views

**`SessionSummaryView`:**
```swift
// Before
init(session: TrainingSession, onDone: () -> Void)

// After
init(session: TrainingSession,
     badgeChanges: [BadgeTierChange] = [],
     onDone: () -> Void)
```

`BadgesUpdatedSection(changes: badgeChanges)` appended after the shot-list section.

The call site in `LiveSessionView`'s `fullScreenCover`:
```swift
SessionSummaryView(
    session:      session,
    badgeChanges: viewModel.sessionResult?.badgeChanges ?? [],
    onDone:       { ... }
)
```

**`DribbleSessionSummaryView`:** identical change — `badgeChanges` param with default `[]`, same component appended at bottom.

**`AgilitySessionSummaryView`:** built with `badgeChanges` from the start (no retrofit needed).

---

## Section 3 — Badge Browser

### 3.1 `BadgeID` extension (model layer addition)

```swift
extension BadgeID {
    var skillDimension: SkillDimension {
        switch self {
        case .deadeye, .sniper, .quickTrigger, .beyondTheArc,
             .charityStripe, .threeLevelScorer, .hotHand:      return .shooting
        case .handles, .ambidextrous, .comboKing,
             .floorGeneral, .ballWizard:                        return .ballHandling
        case .posterizer, .lightning, .explosive, .highFlyer:  return .athleticism
        case .automatic, .metronome, .iceVeins, .reliable:     return .consistency
        case .ironMan, .gymRat, .workhorse,
             .specialist, .completePlayer:                      return .volume
        }
    }
}
```

This is the **single source of truth** for badge grouping. The browser and any future views derive grouping from this — no parallel switch anywhere else.

### 3.2 `BadgeBrowserViewModel`

```swift
@MainActor final class BadgeBrowserViewModel: ObservableObject {

    struct BadgeRowItem: Identifiable {
        let id: BadgeID
        let rank: BadgeRank?     // nil = not yet earned
    }

    private let profile: PlayerProfile

    init(profile: PlayerProfile) { self.profile = profile }

    var earnedCount: Int { profile.earnedBadges.count }

    func rows(for dimension: SkillDimension) -> [BadgeRowItem] {
        BadgeID.allCases
            .filter { $0.skillDimension == dimension }
            .map { badgeID in
                let earned = profile.earnedBadges.first { $0.badgeID == badgeID }
                return BadgeRowItem(
                    id:   badgeID,
                    rank: earned.map { BadgeRank(mmr: $0.mmr) }
                )
            }
    }
}
```

`PlayerProfile` is a SwiftData `@Model` — SwiftUI's observation machinery propagates changes automatically when the view is live. No `@Published` needed for the profile reference itself.

### 3.3 `BadgeBrowserView`

Navigation destination pushed from `ProfileTabView`.

- Title: `"Badges  ·  \(viewModel.earnedCount) / 25"`
- `List` with one `Section` per `SkillDimension.allCases`
- Section header: dimension name + `systemImage`
- Each row: `BadgeRowView(item:)`
  - **Earned**: name, `BadgeRankPill(rank:)` on the right (tier colour)
  - **Unearned**: name dimmed (`.secondary` foreground), gray lock icon — visible, not hidden, so the user knows what to work toward
- Tapping any row → sheet: `BadgeDetailSheet(badgeID:earnedBadge:)`

### 3.4 `BadgeDetailSheet`

Presented as `.presentationDetents([.medium])`.

- Badge name + category icon (large)
- If earned:
  - Current rank: `BadgeRankPill` (large)
  - Progress bar: MMR within current tier division (0–100 pts within the 100-pt band)
  - "Next rank" label below the bar
  - MMR numeric value in caption
- If not earned:
  - "Not yet earned" header
  - One-line description of what the badge measures (a `var scoringDescription: String` computed on `BadgeID`)
- Dismiss button

### 3.5 `BadgeRankPill`

Reusable component used in both the list and the detail sheet:

```swift
struct BadgeRankPill: View {
    let rank: BadgeRank
    // Renders tier colour background + rank.displayName label
}
```

Tier colours:
```swift
extension BadgeTier {
    var color: Color {
        switch self {
        case .bronze:   return Color(red: 0.80, green: 0.50, blue: 0.20)
        case .silver:   return .gray
        case .gold:     return .yellow
        case .platinum: return Color(red: 0.60, green: 0.80, blue: 0.90)
        case .diamond:  return Color(red: 0.40, green: 0.60, blue: 1.00)
        case .champion: return .orange
        }
    }
}
```

### 3.6 `ProfileTabView` — Badges section

Add before the "Settings" section:

```swift
Section("Badges") {
    if let profile = viewModel.profile {
        NavigationLink {
            BadgeBrowserView(viewModel: BadgeBrowserViewModel(profile: profile))
        } label: {
            LabeledContent("Earned", value: "\(viewModel.badgeCount) / 25")
        }
    }
}
```

> `ProfileViewModel.profile` is `PlayerProfile?` — the `if let` guard ensures `BadgeBrowserViewModel` always receives a non-optional value, and the row is simply absent before a profile is loaded.

`viewModel.badgeCount` added to `ProfileViewModel`: `profile?.earnedBadges.count ?? 0`.

---

## Section 4 — Goal Management

### 4.1 `GoalListViewModel`

```swift
@MainActor final class GoalListViewModel: ObservableObject {

    @Published var showingAddGoal = false
    @Published var showAchieved  = false

    private let modelContext: ModelContext
    private let profile: PlayerProfile

    init(modelContext: ModelContext, profile: PlayerProfile) { ... }

    var activeGoals:   [GoalRecord] { profile.goals.filter { !$0.isAchieved } }
    var achievedGoals: [GoalRecord] { profile.goals.filter {  $0.isAchieved } }

    func delete(_ goal: GoalRecord) throws {
        modelContext.delete(goal)
        try modelContext.save()
    }

    func add(title: String, skill: SkillDimension, metric: GoalMetric,
             target: Double, baseline: Double, targetDate: Date?) throws {
        let goal = GoalRecord(title: title, skill: skill, metric: metric,
                              targetValue: target, baselineValue: baseline,
                              targetDate: targetDate)
        goal.profile = profile
        profile.goals.append(goal)
        modelContext.insert(goal)
        try modelContext.save()
    }

    /// Returns the profile's current value for a given metric — used to prefill baseline.
    func currentValue(for metric: GoalMetric) -> Double {
        switch metric {
        case .fgPercent:            return profile.sessions.last?.fgPercent ?? 0
        case .threePointPercent:    return profile.sessions.last?.threePointPercentage ?? 0
        case .freeThrowPercent:     return profile.sessions.last?.freeThrowPercentage ?? 0
        case .verticalJumpCm:       return profile.prVerticalJumpCm
        case .dribbleSpeedHz:       return profile.sessions.last?.avgDribblesPerSec ?? 0
        case .shuttleRunSeconds:    return profile.sessions.compactMap { $0.bestShuttleRunSeconds }.min() ?? 0
        case .overallRating:        return profile.ratingOverall
        case .shootingRating:       return profile.ratingShooting
        case .sessionsPerWeek:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            return Double(profile.sessions.filter { $0.startedAt >= cutoff }.count)
        }
    }
}
```

`activeGoals` and `achievedGoals` are computed properties over `profile.goals` (SwiftData relationship), so they stay live via the model's observation machinery without manual refresh.

### 4.2 `GoalListView` (replaces stub)

```swift
struct GoalListView: View {
    @StateObject private var viewModel: GoalListViewModel  // built by ProgressTabView

    var body: some View {
        List {
            // Active goals
            ForEach(viewModel.activeGoals) { goal in
                GoalProgressRow(goal: goal)
            }
            .onDelete { ... }

            // Achieved goals — collapsible
            if !viewModel.achievedGoals.isEmpty {
                Section {
                    DisclosureGroup("Achieved (\(viewModel.achievedGoals.count))",
                                    isExpanded: $viewModel.showAchieved) {
                        ForEach(viewModel.achievedGoals) { goal in
                            AchievedGoalRow(goal: goal)
                        }
                    }
                }
            }

            // Empty state
            if viewModel.activeGoals.isEmpty && viewModel.achievedGoals.isEmpty {
                ContentUnavailableView("No Goals Yet",
                    systemImage: "target",
                    description: Text("Tap + to set your first goal."))
            }
        }
        .navigationTitle("Goals")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { viewModel.showingAddGoal = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showingAddGoal) {
            AddGoalSheet(viewModel: viewModel)
        }
    }
}
```

### 4.3 `AddGoalSheet`

`.presentationDetents([.large])` form.

**Fields:**
1. **Title** — `TextField`
2. **Skill** — `Picker` over `SkillDimension.allCases`
3. **Metric** — `Picker` showing `selectedSkill.suggestedMetrics` (see extension below); updates when skill changes
4. **Target** — `TextField` (numeric), labelled with `metric.unit`
5. **Baseline** — `TextField` (numeric), pre-filled via `viewModel.currentValue(for: metric)`; user-editable
6. **Target Date** — `Toggle` to enable, then `DatePicker` (`.date` style, `in: Date.now...`)

On Save: calls `viewModel.add(...)`, dismisses. Inline validation: target must be > 0 and title non-empty.

**`SkillDimension.suggestedMetrics` extension (UI layer only):**
```swift
extension SkillDimension {
    var suggestedMetrics: [GoalMetric] {
        switch self {
        case .shooting:     return [.fgPercent, .threePointPercent, .freeThrowPercent, .shootingRating]
        case .ballHandling: return [.dribbleSpeedHz]
        case .athleticism:  return [.verticalJumpCm, .shuttleRunSeconds]
        case .consistency:  return [.fgPercent, .overallRating]
        case .volume:       return [.sessionsPerWeek, .overallRating]
        }
    }
}
```

`overallRating` is available under both `.consistency` and `.volume` as a reasonable catch-all.

---

## Section 5 — Training Reminder Setting

Two `UserDefaults` keys:
```swift
private enum ReminderKey {
    static let enabled = "trainingReminderEnabled"
    static let hour    = "trainingReminderHour"
}
```

Added to the `"Settings"` section of `ProfileTabView`:

```swift
Section("Settings") {
    // ... existing rows ...

    Toggle("Daily Training Reminder", isOn: $reminderEnabled)
        .onChange(of: reminderEnabled) { _, on in
            if on { notificationService.scheduleTrainingReminder(hour: reminderHour) }
            else  { notificationService.cancelTrainingReminder() }
            UserDefaults.standard.set(on, forKey: ReminderKey.enabled)
        }

    if reminderEnabled {
        DatePicker("Reminder Time",
                   selection: reminderTimeBinding,
                   displayedComponents: .hourAndMinute)
            .onChange(of: reminderHour) { _, hour in
                notificationService.scheduleTrainingReminder(hour: hour)
                UserDefaults.standard.set(hour, forKey: ReminderKey.hour)
            }
    }
}
```

`reminderEnabled` and `reminderHour` are `@State` vars initialised from `UserDefaults` in `.onAppear`. `reminderTimeBinding` converts `reminderHour: Int` ↔ `Date` for the `DatePicker`.

Permission is not re-requested here — it was requested on first app launch via `NotificationService.requestPermission()` (already wired). If denied, the toggle silently schedules but no notification fires — correct behaviour, matches iOS convention.

---

## Section 6 — Files

### New

| File | Purpose |
|---|---|
| `Services/AgilityDetectionServiceProtocol.swift` | Protocol + `VolumeButtonAgilityDetectionService` |
| `ViewModels/AgilitySessionViewModel.swift` | Agility session state machine |
| `Views/Train/AgilitySessionView.swift` | Full-screen agility drill UI |
| `Views/Train/AgilitySessionSummaryView.swift` | Post-agility summary |
| `Views/Components/BadgesUpdatedSection.swift` | Inline badge change list |
| `Views/Components/BadgeRankPill.swift` | Reusable rank pill + `BadgeTier.color` extension |
| `Views/Profile/BadgeBrowserView.swift` | Badge browser + `BadgeDetailSheet` |
| `ViewModels/BadgeBrowserViewModel.swift` | Badge grouping + earned lookup |
| `Views/Progress/GoalListView.swift` | Real goal list (replaces stub) |
| `Views/Progress/AddGoalSheet.swift` | Goal creation form |
| `ViewModels/GoalListViewModel.swift` | Goal CRUD |

### Modified

| File | Change |
|---|---|
| `Views/Train/SessionSummaryView.swift` | Add `badgeChanges: [BadgeTierChange] = []`, append `BadgesUpdatedSection` |
| `Views/Train/DribbleSessionSummaryView.swift` | Same |
| `Views/Train/TrainTabView.swift` | Add `.agility` routing to `AgilitySessionView` |
| `Views/Profile/ProfileTabView.swift` | Add Badges section + training reminder setting |
| `ViewModels/ProfileViewModel.swift` | Add `badgeCount` computed var |
| `Models/BadgeID.swift` | Add `skillDimension: SkillDimension` computed var |
| `Models/BadgeTier+UI.swift` | Add `color: Color` extension (UI layer — keep in a `+UI.swift` file to avoid SwiftUI imports in the model layer) |
| `Views/Progress/ProgressTabView.swift` | Wire `GoalListView` with real `GoalListViewModel` |

---

## Testing

No new unit test targets are introduced in Phase 5B. All business logic tested in Phase 5A (calculators, services). Phase 5B is UI + one thin service.

The one testable piece:
- **`VolumeButtonAgilityDetectionService`** — integration test is impractical (requires hardware volume). Document it as untested and test via the protocol seam: `AgilitySessionViewModel` tests can inject a mock `AgilityDetectionServiceProtocol` that fires `onTrigger` programmatically to exercise the state machine.

---

## Dependency Notes

- `BadgeEvaluationService.evaluate` only appends a `BadgeTierChange` when the rank actually changes — `BadgesUpdatedSection` receives only genuine rank changes and is responsible solely for the empty-collection guard (empty → renders nothing)
- `BadgeBrowserViewModel` reads `profile.earnedBadges` directly — no `DataService` indirection needed (read-only, SwiftData observation handles updates)
- `GoalListViewModel.currentValue(for:)` reads from `PlayerProfile` properties for pre-filling baseline — no session access needed
- `AgilitySessionView` creates `VolumeButtonAgilityDetectionService` at the call site (not inside the view model) — this is the correct DI seam for future swap to clap detection

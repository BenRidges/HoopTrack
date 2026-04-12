# Phase 5A — Plan E: Coordinator & Wiring

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire all Phase 5A services together through `SessionFinalizationCoordinator`, remove the now-migrated `updateBallHandlingRating` from `DataService`, update both session ViewModels to use the coordinator, and inject everything into the app.

**Architecture:** `SessionFinalizationCoordinator` holds protocol references to all services. ViewModels gain an `endSession() async` method and a `@Published var sessionResult: SessionResult?`. Services are constructed from a helper view that has access to `@Environment(\.modelContext)`, then injected as environment objects.

**Tech Stack:** SwiftData, SwiftUI, Combine

**Prerequisite:** Plans A–D complete (all models, calculators, and services)

**Build command:**
```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

### Task 1: `SessionFinalizationCoordinator`

**Files:**
- Create: `HoopTrack/HoopTrack/Services/SessionFinalizationCoordinator.swift`

- [ ] **Step 1: Create the coordinator**

```swift
// SessionFinalizationCoordinator.swift
// Sequences the 7-step finalisation pipeline after every session ends.
// Holds protocol references only — concrete types injected at app startup.

import Foundation

@MainActor final class SessionFinalizationCoordinator: ObservableObject {

    private let dataService:            DataService
    private let goalUpdateService:      GoalUpdateServiceProtocol
    private let healthKitService:       HealthKitServiceProtocol
    private let skillRatingService:     SkillRatingServiceProtocol
    private let badgeEvaluationService: BadgeEvaluationServiceProtocol
    private let notificationService:    NotificationService

    init(
        dataService:            DataService,
        goalUpdateService:      GoalUpdateServiceProtocol,
        healthKitService:       HealthKitServiceProtocol,
        skillRatingService:     SkillRatingServiceProtocol,
        badgeEvaluationService: BadgeEvaluationServiceProtocol,
        notificationService:    NotificationService
    ) {
        self.dataService            = dataService
        self.goalUpdateService      = goalUpdateService
        self.healthKitService       = healthKitService
        self.skillRatingService     = skillRatingService
        self.badgeEvaluationService = badgeEvaluationService
        self.notificationService    = notificationService
    }

    // MARK: - Finalisation entry points

    /// Standard shooting session.
    func finaliseSession(_ session: TrainingSession) async throws -> SessionResult {
        let profile = try dataService.fetchOrCreateProfile()
        // 1. Stamp endedAt, recalculate stats, persist
        try dataService.finaliseSession(session)
        // 2. Update goal currentValues + isAchieved
        try goalUpdateService.update(after: session, profile: profile)
        // 3. Write HealthKit workout (async, silent failure)
        try? await healthKitService.writeWorkout(for: session)
        // 4. EMA-update all 5 skill dimension ratings
        try skillRatingService.recalculate(for: profile, session: session)
        // 5. Badge MMR delta (non-fatal: coordinator swallows errors)
        let badgeChanges = (try? badgeEvaluationService.evaluate(session: session, profile: profile)) ?? []
        // 6. Fire milestone notifications for newly crossed thresholds
        notificationService.checkMilestones(for: profile.goals)
        // 7. Return result for ViewModel to display
        return SessionResult(session: session, badgeChanges: badgeChanges)
    }

    /// Dribble drill session.
    func finaliseDribbleSession(_ session: TrainingSession,
                                 metrics: DribbleLiveMetrics) async throws -> SessionResult {
        let profile = try dataService.fetchOrCreateProfile()
        try dataService.finaliseDribbleSession(session, metrics: metrics)
        try goalUpdateService.update(after: session, profile: profile)
        try? await healthKitService.writeWorkout(for: session)
        try skillRatingService.recalculate(for: profile, session: session)
        let badgeChanges = (try? badgeEvaluationService.evaluate(session: session, profile: profile)) ?? []
        notificationService.checkMilestones(for: profile.goals)
        return SessionResult(session: session, badgeChanges: badgeChanges)
    }

    /// Agility session — caller provides best times measured during the session.
    func finaliseAgilitySession(_ session: TrainingSession,
                                 attempts: AgilityAttempts) async throws -> SessionResult {
        session.bestShuttleRunSeconds  = attempts.bestShuttleRunSeconds
        session.bestLaneAgilitySeconds = attempts.bestLaneAgilitySeconds
        let profile = try dataService.fetchOrCreateProfile()
        try dataService.finaliseSession(session)
        try goalUpdateService.update(after: session, profile: profile)
        try? await healthKitService.writeWorkout(for: session)
        try skillRatingService.recalculate(for: profile, session: session)
        let badgeChanges = (try? badgeEvaluationService.evaluate(session: session, profile: profile)) ?? []
        notificationService.checkMilestones(for: profile.goals)
        return SessionResult(session: session, badgeChanges: badgeChanges)
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
git add HoopTrack/HoopTrack/Services/SessionFinalizationCoordinator.swift
git commit -m "feat: SessionFinalizationCoordinator — 7-step session finalisation pipeline"
```

---

### Task 2: Remove `updateBallHandlingRating` from `DataService`

The ball-handling EMA logic has been migrated to `SkillRatingService`. Remove the dead code.

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/DataService.swift`

- [ ] **Step 1: Remove `updateBallHandlingRating` call from `finaliseDribbleSession`**

In `DataService.finaliseDribbleSession`, find:
```swift
        updateProfileStats(profile, with: session)
        updateBallHandlingRating(profile, from: session)
        try modelContext.save()
```
Replace with:
```swift
        updateProfileStats(profile, with: session)
        try modelContext.save()
```

- [ ] **Step 2: Delete the `updateBallHandlingRating` private method entirely**

Remove the entire method:
```swift
    private func updateBallHandlingRating(_ profile: PlayerProfile,
                                          from session: TrainingSession) {
        // ... (entire method body) ...
    }
```

- [ ] **Step 3: Build to verify no orphaned references**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Services/DataService.swift
git commit -m "refactor: remove updateBallHandlingRating from DataService (migrated to SkillRatingService)"
```

---

### Task 3: Update `LiveSessionViewModel`

**Files:**
- Modify: `HoopTrack/HoopTrack/ViewModels/LiveSessionViewModel.swift`

- [ ] **Step 1: Add coordinator dependency and `sessionResult` published property**

Find the `// MARK: - Dependencies` section and add:
```swift
    @Published var sessionResult: SessionResult?

    private var coordinator: SessionFinalizationCoordinator!
```

- [ ] **Step 2: Add coordinator to the `configure()` method**

Replace:
```swift
    func configure(dataService: DataService, hapticService: HapticService) {
        self.dataService   = dataService
        self.hapticService = hapticService
    }
```
With:
```swift
    func configure(dataService: DataService,
                   hapticService: HapticService,
                   coordinator: SessionFinalizationCoordinator) {
        self.dataService   = dataService
        self.hapticService = hapticService
        self.coordinator   = coordinator
    }
```

- [ ] **Step 3: Replace `endSession()` with an async version that uses the coordinator**

Replace the existing `endSession()`:
```swift
    func endSession() {
        guard let session else { return }
        isSaving = true
        timerCancellable?.cancel()

        do {
            try dataService.finaliseSession(session)
            isFinished = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
```
With:
```swift
    func endSession() async {
        guard let session else { return }
        isSaving = true
        timerCancellable?.cancel()
        do {
            sessionResult = try await coordinator.finaliseSession(session)
            isFinished    = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
```

- [ ] **Step 4: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

If there are call-site errors in views (calling `endSession()` without `await`), update each call site from:
```swift
viewModel.endSession()
```
To:
```swift
Task { await viewModel.endSession() }
```

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/LiveSessionViewModel.swift
git commit -m "feat: LiveSessionViewModel uses SessionFinalizationCoordinator; endSession() is now async"
```

---

### Task 4: Update `DribbleSessionViewModel`

**Files:**
- Modify: `HoopTrack/HoopTrack/ViewModels/DribbleSessionViewModel.swift`

- [ ] **Step 1: Add coordinator and `sessionResult`**

Find `// MARK: - Dependencies` and add:
```swift
    @Published var sessionResult: SessionResult?

    private var coordinator: SessionFinalizationCoordinator!
```

- [ ] **Step 2: Add coordinator to `configure()`**

Replace:
```swift
    func configure(dataService: DataService) {
        self.dataService = dataService
    }
```
With:
```swift
    func configure(dataService: DataService,
                   coordinator: SessionFinalizationCoordinator) {
        self.dataService = dataService
        self.coordinator = coordinator
    }
```

- [ ] **Step 3: Replace `endSession()` with async coordinator version**

Replace:
```swift
    func endSession() {
        guard let session else { return }
        isSaving = true
        timerCancellable?.cancel()
        do {
            try dataService.finaliseDribbleSession(session, metrics: liveMetrics)
            isFinished = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
```
With:
```swift
    func endSession() async {
        guard let session else { return }
        isSaving = true
        timerCancellable?.cancel()
        do {
            sessionResult = try await coordinator.finaliseDribbleSession(session, metrics: liveMetrics)
            isFinished    = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
```

- [ ] **Step 4: Build to verify — fix any call-site `endSession()` in dribble views**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

For any view calling `viewModel.endSession()` without await, wrap: `Task { await viewModel.endSession() }`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/DribbleSessionViewModel.swift
git commit -m "feat: DribbleSessionViewModel uses SessionFinalizationCoordinator; endSession() is now async"
```

---

### Task 5: App-level injection

Build the coordinator and inject it as an environment object into the view hierarchy. Because `SessionFinalizationCoordinator` needs `ModelContext` (available only inside the view tree), a thin wrapper view `CoordinatorHost` creates the coordinator on first appearance.

**Files:**
- Create: `HoopTrack/HoopTrack/CoordinatorHost.swift`
- Modify: `HoopTrack/HoopTrack/HoopTrackApp.swift`

- [ ] **Step 1: Create `CoordinatorHost.swift`**

```swift
// CoordinatorHost.swift
// Builds SessionFinalizationCoordinator once ModelContext is available,
// then injects it as an environment object for all child views.

import SwiftUI
import SwiftData

struct CoordinatorHost: View {
    @Environment(\.modelContext)    private var modelContext
    @EnvironmentObject private var notificationService: NotificationService

    @StateObject private var coordinator = CoordinatorBox()

    var body: some View {
        ContentView()
            .environmentObject(coordinator.value!)
            .task {
                coordinator.build(modelContext: modelContext,
                                  notificationService: notificationService)
            }
    }
}

/// Holds the coordinator as an optional, constructed lazily after ModelContext is available.
@MainActor final class CoordinatorBox: ObservableObject {
    private(set) var value: SessionFinalizationCoordinator?

    func build(modelContext: ModelContext, notificationService: NotificationService) {
        guard value == nil else { return }
        value = SessionFinalizationCoordinator(
            dataService:            DataService(modelContext: modelContext),
            goalUpdateService:      GoalUpdateService(modelContext: modelContext),
            healthKitService:       HealthKitService(),
            skillRatingService:     SkillRatingService(modelContext: modelContext),
            badgeEvaluationService: BadgeEvaluationService(modelContext: modelContext),
            notificationService:    notificationService
        )
    }
}
```

> **Note:** The `coordinator.value!` force-unwrap is safe because `.task` runs before any user interaction reaches a child view. If this assumption becomes fragile in future, replace `CoordinatorBox` with a `@StateObject` built from the full `init` parameter set at the scene level.

- [ ] **Step 2: Update `HoopTrackApp.swift` — replace `ContentView()` with `CoordinatorHost()`**

In `HoopTrackApp.body`, replace:
```swift
            ContentView()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
```
With:
```swift
            CoordinatorHost()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
```

- [ ] **Step 3: Update view `configure()` call sites to pass the coordinator**

Search for every place that calls `viewModel.configure(dataService:hapticService:)` (LiveSessionViewModel) or `viewModel.configure(dataService:)` (DribbleSessionViewModel) and add the coordinator:

```swift
// Example — LiveSessionView (or wherever configure is called):
.onAppear {
    viewModel.configure(
        dataService:  DataService(modelContext: modelContext),
        hapticService: hapticService,
        coordinator:   coordinator          // @EnvironmentObject SessionFinalizationCoordinator
    )
}
```

```swift
// Example — DribbleDrillView (or wherever configure is called):
.onAppear {
    viewModel.configure(
        dataService: DataService(modelContext: modelContext),
        coordinator: coordinator
    )
}
```

Add `@EnvironmentObject private var coordinator: SessionFinalizationCoordinator` to each of those views.

- [ ] **Step 4: Request HealthKit permission on launch**

In `CoordinatorBox.build()`, after constructing the coordinator, request HealthKit permission:

```swift
        Task { await value?.healthKitService().requestPermission() }
```

Because `HealthKitService` is private to the coordinator, add a helper method to `SessionFinalizationCoordinator`:

```swift
    func requestHealthKitPermission() async {
        await healthKitService.requestPermission()
    }
```

Then in `CoordinatorHost.body`:
```swift
            .task {
                coordinator.build(modelContext: modelContext,
                                  notificationService: notificationService)
                await coordinator.value?.requestHealthKitPermission()
            }
```

- [ ] **Step 5: Build to verify the full app compiles**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Run the full test suite to confirm no regressions**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|error:)"
```
Expected: all test suites passed

- [ ] **Step 7: Commit**

```bash
git add HoopTrack/HoopTrack/CoordinatorHost.swift HoopTrack/HoopTrack/HoopTrackApp.swift
git commit -m "feat: inject SessionFinalizationCoordinator via CoordinatorHost environment object"
```

---

### Done

Phase 5A backend is complete. Every session now runs through the 7-step coordinator pipeline:
1. DataService finalises the session
2. Goals updated
3. HealthKit workout written (silent failure)
4. All 5 skill ratings EMA-updated
5. Badge MMRs updated
6. Milestone notifications fired
7. `SessionResult` returned to ViewModel

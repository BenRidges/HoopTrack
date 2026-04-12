# HoopTrack Codebase Refactor Report

**Date:** 2026-04-12  
**Scope:** Phase 6B analysis — pre-refactor findings

---

## Summary

| # | Severity | Finding | File |
|---|---|---|---|
| 1 | Critical | `ProfileTabView` constructs a second `ModelContainer` in a `@StateObject` initialiser, bypassing the app-wide SwiftData store | `ProfileTabView.swift:13–15` |
| 2 | Critical | `DispatchQueue.main.async` used inside `@MainActor` context for error propagation in `CameraService` | `CameraService.swift:78, 94, 126, 134` |
| 3 | Important | Long-press end-session button pattern duplicated verbatim across three views (~60 lines each) | `LiveSessionView.swift:323–363`, `DribbleDrillView.swift:134–172`, `AgilitySessionView.swift:186–225` |
| 4 | Important | Three views each call `DataService(modelContext: modelContext)` directly in `.task`, bypassing the injected environment service | `LiveSessionView.swift:73`, `DribbleDrillView.swift:46`, `AgilitySessionView.swift:68` |
| 5 | Important | `ProgressViewModel.load()` is synchronous (not `async`) despite executing SwiftData fetches that can throw, silently eating errors | `ProgressViewModel.swift:36–50` |
| 6 | Important | `LiveSessionViewModel` uses implicitly-unwrapped optionals for injected dependencies, creating a crash surface if `configure()` is not called before `start()` | `LiveSessionViewModel.swift:44–46` |
| 7 | Minor | `DispatchQueue.main.async` used inside `DribbleARViewContainer.makeUIView` to write SwiftUI state; should use `Task { @MainActor in }` | `DribbleDrillView.swift:199` |
| 8 | Minor | `NotificationSettingsView` toggles are hardcoded `.constant(true)` — stub UI never wired to `NotificationService` state | `ProfileTabView.swift:302, 308` |
| 9 | Minor | `updateCalibrationState(isCalibrated:)` sets both `self.isCalibrated` and `self.calibrationIsActive` to the same value — `calibrationIsActive` is redundant | `LiveSessionViewModel.swift:186–189` |
| 10 | Minor | Commented-out `cvPipeline` injection block and debug `print` are dead code that adds noise | `CameraService.swift:27–28, 155–157` |

---

## Findings

### 1. `ProfileTabView` constructs a second `ModelContainer`
**Severity:** Critical  
**File:** `HoopTrack/HoopTrack/Views/Profile/ProfileTabView.swift:13–15`  
**Description:**  
The `@StateObject` initialiser for `ProfileViewModel` force-unwraps a brand-new `ModelContainer` using `try!`. This creates a second, independent SwiftData store that is completely disconnected from the container created at app startup. Any sessions, profiles, or goals written through the main container will be invisible to `ProfileViewModel`, and vice versa. The `try!` also crashes on any schema mismatch.

```swift
// Current — broken
@StateObject private var viewModel: ProfileViewModel = {
    ProfileViewModel(dataService: DataService(modelContext: ModelContext(try! ModelContainer(for: PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self))))
}()
```

**Suggested fix:**  
Remove the inline `@StateObject` initialiser. Inject `DataService` from the SwiftUI environment the same way `LiveSessionView` and `DribbleDrillView` do it (pass via `.task` after reading `@Environment(\.modelContext)`):

```swift
// After
@Environment(\.modelContext) private var modelContext
@StateObject private var viewModel = ProfileViewModel()   // no-arg init

.task { viewModel.configure(dataService: DataService(modelContext: modelContext)) }
```

---

### 2. `DispatchQueue.main.async` inside `@MainActor` class `CameraService`
**Severity:** Critical  
**File:** `HoopTrack/HoopTrack/Services/CameraService.swift:78, 94, 126, 134`  
**Description:**  
`CameraService` is annotated `@MainActor`, so all of its methods already run on the main actor. When `buildSession(mode:)` and `startSession()` / `stopSession()` use `DispatchQueue.main.async { self.error = … }`, the captures of `self` are unprotected — the closure runs outside the actor's concurrency domain and writes actor-isolated state (`error`, `isSessionRunning`) from a non-isolated closure. Swift's strict concurrency checking (Swift 6) will flag these as data races.

```swift
// Current — line 78, data race in Swift 6 strict mode
DispatchQueue.main.async { self.error = .deviceUnavailable }
```

**Suggested fix:**  
Replace each `DispatchQueue.main.async` with `Task { @MainActor in }` so the capture is actor-safe:

```swift
// After
Task { @MainActor in self.error = .deviceUnavailable }
```

Do the same at lines 94, 126, and 134.

---

### 3. Long-press end-session button duplicated across three views
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift:323–363`, `DribbleDrillView.swift:134–172`, `AgilitySessionView.swift:186–225`  
**Description:**  
All three session views implement their own long-press end-session button using `@State var isLongPressingEnd`, `@State var endLongPressProgress`, `@State var endSessionTask`, and a `DragGesture` block. The gesture logic is nearly identical (~40 lines of gesture + animation + `Task.sleep`). Any bug fix or UX tweak (e.g., changing the hold duration from 1.5 s) must be applied to all three files independently. The two implementations already differ in minor ways: `AgilitySessionView` manually increments progress in 50 ms steps while the other two use a single `withAnimation(.linear(duration: 1.5))`, meaning the feel is subtly inconsistent.

**Suggested fix:**  
Extract a reusable `HoldToEndButton` view that owns the three `@State` properties and accepts an `onConfirm: () async -> Void` closure:

```swift
struct HoldToEndButton: View {
    let label: String
    let onConfirm: () async -> Void

    @State private var isHolding = false
    @State private var progress: Double = 0
    @State private var task: Task<Void, Never>?

    var body: some View { /* single implementation */ }
}

// Usage in each view
HoldToEndButton(label: "End Session") {
    await viewModel.endSession()
}
```

---

### 4. Views construct `DataService` directly from `modelContext` instead of using an injected service
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift:73`, `DribbleDrillView.swift:46`, `AgilitySessionView.swift:68`  
**Description:**  
Each of these views calls `DataService(modelContext: modelContext)` inside `.task` to configure their respective view models. This defeats the dependency-injection pattern `DataService` is designed for: tests cannot swap the data layer, and if a future `DataService` gains init-time side effects (e.g., schema migration), every view becomes a separately-constructed instance. The design intent of the codebase (per `DataService.swift:1–6`) is that ViewModels interact with a single shared service.

**Suggested fix:**  
Inject a single `DataService` instance through the SwiftUI environment (e.g., `.environmentObject(dataService)` at app root) and read it with `@EnvironmentObject private var dataService: DataService` in each view. Remove the inline `DataService(modelContext:)` construction from all three `.task` blocks.

---

### 5. `ProgressViewModel.load()` is synchronous on `@MainActor`, blocking the main thread
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift:36–50`  
**Description:**  
`load()` performs multiple SwiftData fetches synchronously on the main actor. For a player with many sessions, the `fetchSessions()` call and the subsequent `computeFGTrend()` (iterating all shots) block the main thread, causing frame drops on the Progress tab. The method is also triggered by the `$selectedTimeRange` Combine sink (line 29), so every picker change redoes all fetches synchronously. Additionally, errors from the `do/catch` block set `errorMessage` but `isLoading` is still reset to `false`, which is the only correct handling — but the missing `defer` makes the pattern fragile.

**Suggested fix:**  
Make `load()` `async` and offload the heavy fetch to a background actor:

```swift
func load() {
    Task {
        await MainActor.run { isLoading = true }
        do {
            let fetched = try await Task.detached(priority: .userInitiated) {
                try dataService.fetchSessions()
            }.value
            // … assign on main actor
        } catch { … }
        await MainActor.run { isLoading = false }
    }
}
```

Also, use `defer { isLoading = false }` to guarantee the flag is cleared regardless of throw path.

---

### 6. `LiveSessionViewModel` implicitly-unwrapped optionals for injected dependencies
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/ViewModels/LiveSessionViewModel.swift:44–46`  
**Description:**  
`dataService` and `coordinator` are declared as `DataService!` and `SessionFinalizationCoordinator!`. If `configure(dataService:hapticService:coordinator:)` is not called before `start()` or `endSession()` — for example, during a unit test that uses the no-arg `init()` without follow-up configuration — the app crashes with a nil dereference rather than a meaningful error. The doc comment on the no-arg `init` says callers must call `configure` before `start`, but this is not enforced by the type system.

```swift
// Current — lines 44–46
private var dataService: DataService!
private var coordinator: SessionFinalizationCoordinator!
```

**Suggested fix:**  
Use a typed enum to model the dependency state, or make the ViewModel's two init paths mutually exclusive by removing the no-arg init and instead using a factory that supplies a placeholder `DataService` backed by an in-memory container for previews:

```swift
// After — explicit optional with a guard in start()
private var dataService: DataService?
private var coordinator: SessionFinalizationCoordinator?

func start(...) {
    guard let dataService else {
        errorMessage = "Session not configured. Call configure() first."; return
    }
    ...
}
```

---

### 7. `DispatchQueue.main.async` in `DribbleARViewContainer.makeUIView` to write SwiftUI state
**Severity:** Minor  
**File:** `HoopTrack/HoopTrack/Views/Train/DribbleDrillView.swift:199`  
**Description:**  
`makeUIView` runs on the main thread, yet it defers the `coordinator` binding assignment to `DispatchQueue.main.async`. The comment at line 57–58 acknowledges this is intentional (to avoid a race with `.task`), but `DispatchQueue.main.async` is not actor-aware and creates an implicit hop outside `@MainActor` isolation. The Swift 6 compiler may warn here because `self.coordinator` (a `@Binding`) is mutated from a non-isolated closure.

**Suggested fix:**  
Replace with `Task { @MainActor in self.coordinator = c }`, which preserves the async deferral while remaining actor-safe.

---

### 8. `NotificationSettingsView` toggle stubs never connected to real state
**Severity:** Minor  
**File:** `HoopTrack/HoopTrack/Views/Profile/ProfileTabView.swift:302, 308`  
**Description:**  
Both toggles in `NotificationSettingsView` use `.constant(true)`, making them permanently enabled and non-interactive. The view reads `notificationService.authorizationStatus` for the disabled state but never reads or writes the actual user preference for whether streak reminders or goal-achieved notifications are on. This is dead UI — a user cannot meaningfully toggle these settings.

**Suggested fix:**  
Wire to `UserDefaults`-backed `@AppStorage` bindings and call the appropriate `NotificationService` methods on change. If this section is intentionally deferred to a later phase, add a `// TODO(Phase N):` comment to avoid confusion.

---

### 9. Redundant `calibrationIsActive` published property in `LiveSessionViewModel`
**Severity:** Minor  
**File:** `HoopTrack/HoopTrack/ViewModels/LiveSessionViewModel.swift:186–189`  
**Description:**  
`updateCalibrationState(isCalibrated:)` sets both `self.isCalibrated` and `self.calibrationIsActive` to the same incoming value on every call. There is no code path where they differ. `calibrationIsActive` is `@Published` (line 28) but appears to be unused by any view — `LiveSessionView` gates on `viewModel.isCalibrated` (line 65). The property is dead.

**Suggested fix:**  
Delete `calibrationIsActive` and its `@Published` declaration. If "calibration is in progress" needs to be distinguished from "calibration is complete" in a future phase, introduce a dedicated `CalibrationState` enum.

---

### 10. Commented-out code left as dead weight in `CameraService`
**Severity:** Minor  
**File:** `HoopTrack/HoopTrack/Services/CameraService.swift:27–28, 146, 155–157`  
**Description:**  
Three commented-out blocks remain in `CameraService`:
- Line 27–28: `private weak var cvPipeline: CVPipelineProtocol?` — Phase 2 placeholder.
- Line 146: `// cvPipeline?.processBuffer(sampleBuffer)` — Phase 2 hook.
- Lines 155–157: A `#if DEBUG` block containing a commented-out `print` inside a block that already serves no purpose.

These do not affect behaviour, but they inflate the file and create ambiguity about whether Phase 2 integration lives here or in `CVPipeline.swift`.

**Suggested fix:**  
Remove the commented-out lines. The Phase 2 integration point is documented in the header comment (lines 5–6); the code can be recovered from git history if needed. If the `#if DEBUG` dropped-frame logging is genuinely wanted for Phase 2 debugging, uncomment the `print` and leave the `#if DEBUG` guard active.

---

## Follow-up Tasks

| Finding | Severity | Suggested Action |
|---|---|---|
| 1. Duplicate `ModelContainer` in `ProfileTabView` | Critical | Refactor `ProfileViewModel` to accept a no-arg init; inject `DataService` via `.task` using the environment `modelContext` |
| 2. `DispatchQueue.main.async` in `@MainActor` class | Critical | Replace all four sites in `CameraService` with `Task { @MainActor in … }` |
| 3. Long-press button duplication | Important | Extract `HoldToEndButton` reusable view; replace in all three session views |
| 4. Inline `DataService` construction in views | Important | Inject `DataService` as a single `@EnvironmentObject` from app root |
| 5. Synchronous `ProgressViewModel.load()` | Important | Make `load()` async; use `defer` for `isLoading`; consider background actor for fetches |
| 6. Implicitly-unwrapped dependencies in `LiveSessionViewModel` | Important | Replace `!` optionals with explicit optionals + guard, or remove no-arg init |
| 7. `DispatchQueue.main.async` in `DribbleARViewContainer` | Minor | Replace with `Task { @MainActor in … }` |
| 8. Stub toggles in `NotificationSettingsView` | Minor | Wire to real state or add `TODO(Phase N)` comment to flag as intentionally deferred |
| 9. Redundant `calibrationIsActive` property | Minor | Delete `@Published var calibrationIsActive`; update `updateCalibrationState` |
| 10. Commented-out code in `CameraService` | Minor | Delete dead comment blocks; leave only the header-level phase notes |

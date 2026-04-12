# Phase 5B — Plan E: Goal Management UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `GoalListView` stub in `ProgressTabView` with a full goal management UI: a live goal list with delete support, an achieved-goals collapsible section, an add-goal form, and proper `GoalListViewModel` wiring.

**Architecture:** `GoalListViewModel` owns goal CRUD and the `currentValue(for:)` baseline prefill logic. `GoalListView` takes `@StateObject var viewModel: GoalListViewModel` — it is a navigation destination, so `@StateObject` is correct here (re-created per push). `AddGoalSheet` is a separate view pushed via `.sheet`. `ProgressTabView` gains a `profile: PlayerProfile?` property on its `ProgressViewModel` and constructs `GoalListViewModel` when navigating.

**Tech Stack:** SwiftUI, SwiftData, Foundation

**Prerequisite:** Plan A complete (`SkillDimension.suggestedMetrics` available); Phase 5A models (`GoalRecord`, `GoalMetric`, `SkillDimension`) available.

**Build command (run from worktree root):**
```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

### Task 1: Expose `profile` on `ProgressViewModel`

**Files:**
- Modify: `HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift`

The `load()` method already fetches a profile via `dataService.fetchOrCreateProfile()`. We just need to store it as a published property so `ProgressTabView` can pass it to `GoalListViewModel`.

- [ ] **Step 1: Add `@Published var profile: PlayerProfile?` to the published properties**

Find the block:
```swift
    @Published var sessions: [TrainingSession] = []
    @Published var goals: [GoalRecord] = []
```

Insert after `@Published var goals: [GoalRecord] = []`:
```swift
    @Published var profile: PlayerProfile?
```

- [ ] **Step 2: Store the fetched profile in `load()`**

In `load()`, find:
```swift
            let profile  = try dataService.fetchOrCreateProfile()
            goals        = profile.goals
```

Replace with:
```swift
            let fetched  = try dataService.fetchOrCreateProfile()
            profile      = fetched
            goals        = fetched.goals
```

- [ ] **Step 3: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift
git commit -m "feat: expose profile on ProgressViewModel for GoalListViewModel construction"
```

---

### Task 2: Create `GoalListViewModel`

**Files:**
- Create: `HoopTrack/HoopTrack/ViewModels/GoalListViewModel.swift`

- [ ] **Step 1: Create the file**

```swift
// GoalListViewModel.swift
import Foundation
import SwiftData

@MainActor final class GoalListViewModel: ObservableObject {

    @Published var showingAddGoal = false
    @Published var showAchieved  = false

    private let modelContext: ModelContext
    let profile: PlayerProfile   // internal so AddGoalSheet can read it

    init(modelContext: ModelContext, profile: PlayerProfile) {
        self.modelContext = modelContext
        self.profile      = profile
    }

    var activeGoals:   [GoalRecord] { profile.goals.filter { !$0.isAchieved } }
    var achievedGoals: [GoalRecord] { profile.goals.filter {  $0.isAchieved } }

    func delete(_ goal: GoalRecord) {
        modelContext.delete(goal)
        try? modelContext.save()
    }

    func add(title: String, skill: SkillDimension, metric: GoalMetric,
             target: Double, baseline: Double, targetDate: Date?) {
        let goal = GoalRecord(title: title, skill: skill, metric: metric,
                              targetValue: target, baselineValue: baseline,
                              targetDate: targetDate)
        goal.profile = profile
        profile.goals.append(goal)
        modelContext.insert(goal)
        try? modelContext.save()
    }

    /// Returns the profile's current value for a metric — used to pre-fill baseline in AddGoalSheet.
    func currentValue(for metric: GoalMetric) -> Double {
        switch metric {
        case .fgPercent:
            return profile.sessions.last?.fgPercent ?? 0
        case .threePointPercent:
            return profile.sessions.last?.threePointPercentage ?? 0
        case .freeThrowPercent:
            return profile.sessions.last?.freeThrowPercentage ?? 0
        case .verticalJumpCm:
            return profile.prVerticalJumpCm
        case .dribbleSpeedHz:
            return profile.sessions.last?.avgDribblesPerSec ?? 0
        case .shuttleRunSeconds:
            return profile.sessions.compactMap { $0.bestShuttleRunSeconds }.min() ?? 0
        case .overallRating:
            return profile.ratingOverall
        case .shootingRating:
            return profile.ratingShooting
        case .sessionsPerWeek:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            return Double(profile.sessions.filter { $0.startedAt >= cutoff }.count)
        }
    }
}
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/GoalListViewModel.swift
git commit -m "feat: add GoalListViewModel with CRUD and baseline prefill"
```

---

### Task 3: Create `GoalListView`

This replaces the stub currently defined at the bottom of `ProgressTabView.swift`. Delete the stub and create a proper dedicated file.

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Progress/GoalListView.swift`
- Modify: `HoopTrack/HoopTrack/Views/Progress/ProgressTabView.swift` (remove stub)

- [ ] **Step 1: Delete the stub from `ProgressTabView.swift`**

Find and remove the entire stub block at the bottom of the file:
```swift
// MARK: - GoalListView (stub — Phase 5 full implementation)
struct GoalListView: View {
    var body: some View {
        Text("Goal management — coming in Phase 5")
            .foregroundStyle(.secondary)
            .navigationTitle("Goals")
    }
}
```

- [ ] **Step 2: Create `GoalListView.swift`**

```swift
// GoalListView.swift
// Full goal management list — replaces Phase 5 stub.
import SwiftUI

struct GoalListView: View {
    @StateObject var viewModel: GoalListViewModel

    var body: some View {
        List {
            // MARK: Active Goals
            if !viewModel.activeGoals.isEmpty {
                Section("Active") {
                    ForEach(viewModel.activeGoals) { goal in
                        GoalProgressRow(goal: goal)
                    }
                    .onDelete { indexSet in
                        indexSet.map { viewModel.activeGoals[$0] }.forEach { viewModel.delete($0) }
                    }
                }
            }

            // MARK: Achieved Goals (collapsible)
            if !viewModel.achievedGoals.isEmpty {
                Section {
                    DisclosureGroup(
                        "Achieved (\(viewModel.achievedGoals.count))",
                        isExpanded: $viewModel.showAchieved
                    ) {
                        ForEach(viewModel.achievedGoals) { goal in
                            AchievedGoalRow(goal: goal)
                        }
                    }
                }
            }

            // MARK: Empty State
            if viewModel.activeGoals.isEmpty && viewModel.achievedGoals.isEmpty {
                ContentUnavailableView(
                    "No Goals Yet",
                    systemImage: "target",
                    description: Text("Tap + to set your first goal.")
                )
            }
        }
        .navigationTitle("Goals")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.showingAddGoal = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $viewModel.showingAddGoal) {
            AddGoalSheet(viewModel: viewModel)
        }
    }
}

// MARK: - AchievedGoalRow

private struct AchievedGoalRow: View {
    let goal: GoalRecord

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let date = goal.achievedAt {
                    Text("Achieved \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}
```

- [ ] **Step 3: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Progress/GoalListView.swift HoopTrack/HoopTrack/Views/Progress/ProgressTabView.swift
git commit -m "feat: add GoalListView with active/achieved sections; remove stub"
```

---

### Task 4: Create `AddGoalSheet`

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Progress/AddGoalSheet.swift`

- [ ] **Step 1: Create the file**

```swift
// AddGoalSheet.swift
// Form for creating a new GoalRecord.
import SwiftUI

struct AddGoalSheet: View {

    @ObservedObject var viewModel: GoalListViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var title:          String         = ""
    @State private var selectedSkill:  SkillDimension = .shooting
    @State private var selectedMetric: GoalMetric     = SkillDimension.shooting.suggestedMetrics.first ?? .fgPercent
    @State private var targetText:     String         = ""
    @State private var baselineText:   String         = ""
    @State private var hasTargetDate:  Bool           = false
    @State private var targetDate:     Date           = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Goal Details") {
                    TextField("Title (e.g. Shoot 50% FG)", text: $title)

                    Picker("Skill", selection: $selectedSkill) {
                        ForEach(SkillDimension.allCases) { dim in
                            Text(dim.rawValue).tag(dim)
                        }
                    }
                    .onChange(of: selectedSkill) { _, newSkill in
                        selectedMetric = newSkill.suggestedMetrics.first ?? .fgPercent
                        prefillBaseline()
                    }

                    Picker("Metric", selection: $selectedMetric) {
                        ForEach(selectedSkill.suggestedMetrics) { metric in
                            Text(metric.rawValue).tag(metric)
                        }
                    }
                    .onChange(of: selectedMetric) { _, _ in prefillBaseline() }
                }

                Section("Values (\(selectedMetric.unit))") {
                    TextField("Target", text: $targetText)
                        .keyboardType(.decimalPad)
                    TextField("Baseline (current)", text: $baselineText)
                        .keyboardType(.decimalPad)
                }

                Section("Target Date (optional)") {
                    Toggle("Set a deadline", isOn: $hasTargetDate)
                        .tint(.orange)
                    if hasTargetDate {
                        DatePicker("Deadline",
                                   selection: $targetDate,
                                   in: Date.now...,
                                   displayedComponents: .date)
                    }
                }

                if let error = validationError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section {
                    Button("Save Goal") { save() }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .bold()
                        .foregroundStyle(.orange)
                        .disabled(!isValid)
                }
            }
            .navigationTitle("New Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .onAppear { prefillBaseline() }
    }

    // MARK: - Validation

    private var isValid: Bool {
        !title.isEmpty &&
        (Double(targetText) ?? 0) > 0
    }

    // MARK: - Actions

    private func prefillBaseline() {
        let current = viewModel.currentValue(for: selectedMetric)
        if current > 0 {
            baselineText = String(format: "%.1f", current)
        }
    }

    private func save() {
        guard let target = Double(targetText), target > 0 else {
            validationError = "Target must be a positive number."
            return
        }
        let baseline = Double(baselineText) ?? 0
        viewModel.add(
            title:      title,
            skill:      selectedSkill,
            metric:     selectedMetric,
            target:     target,
            baseline:   baseline,
            targetDate: hasTargetDate ? targetDate : nil
        )
        dismiss()
    }
}

// MARK: - GoalMetric: Identifiable
extension GoalMetric: Identifiable {
    public var id: String { rawValue }
}
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Progress/AddGoalSheet.swift
git commit -m "feat: add AddGoalSheet goal creation form"
```

---

### Task 5: Wire `ProgressTabView` goalSection to real `GoalListViewModel`

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Progress/ProgressTabView.swift`

- [ ] **Step 1: Add `@Environment(\.modelContext)` to `ProgressTabView`**

The view currently initialises `ProgressViewModel` with a manually constructed `ModelContainer` (workaround). Add the environment model context so we can pass it to `GoalListViewModel`.

The struct currently has no `@Environment(\.modelContext)` line. Add it after the `@StateObject private var viewModel` line:

```swift
    @Environment(\.modelContext) private var modelContext
```

- [ ] **Step 2: Update `goalSection` — replace the NavigationLink destination**

Find:
```swift
                NavigationLink {
                    GoalListView()
                } label: {
                    Label("Manage", systemImage: "plus")
                        .font(.subheadline)
                        .tint(.orange)
                }
```

Replace with:
```swift
                if let profile = viewModel.profile {
                    NavigationLink {
                        GoalListView(
                            viewModel: GoalListViewModel(
                                modelContext: modelContext,
                                profile:      profile
                            )
                        )
                    } label: {
                        Label("Manage", systemImage: "plus")
                            .font(.subheadline)
                            .tint(.orange)
                    }
                }
```

- [ ] **Step 3: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Run the full test suite to confirm no regressions**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(Test Suite.*passed|Test Suite.*failed|error:)"
```
Expected: all test suites passed

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Progress/ProgressTabView.swift
git commit -m "feat: wire ProgressTabView goalSection to real GoalListViewModel"
```

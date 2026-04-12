# Phase 5B — Plan B: Badge UI Layer

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the complete badge UI surface: `BadgeRankPill` (reusable rank chip), `BadgesUpdatedSection` (post-session badge change list), `BadgeBrowserViewModel`, `BadgeBrowserView` with `BadgeDetailSheet`, and wire both into `ProfileTabView` alongside the new training reminder setting.

**Architecture:** All new views are pure layout — no SwiftData access directly. `BadgeBrowserViewModel` owns the earned-badge lookup. `ProfileViewModel.badgeCount` is a computed property. The training reminder persists via `UserDefaults`. No new @Model types.

**Tech Stack:** SwiftUI, SwiftData (read-only via existing @Model), UserDefaults, Foundation

**Prerequisite:** Plan A complete (`BadgeID.skillDimension`, `BadgeTier.color` available)

**Build command (run from worktree root):**
```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

### Task 1: Create `BadgeRankPill`

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Components/BadgeRankPill.swift`

- [ ] **Step 1: Create the file**

```swift
// BadgeRankPill.swift
// Reusable tier-coloured pill showing badge rank — used in browser and detail sheet.
import SwiftUI

struct BadgeRankPill: View {
    let rank: BadgeRank

    var body: some View {
        Text(rank.displayName)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(rank.tier.color.opacity(0.20), in: Capsule())
            .foregroundStyle(rank.tier.color)
            .overlay(Capsule().strokeBorder(rank.tier.color.opacity(0.4), lineWidth: 1))
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
git add HoopTrack/HoopTrack/Views/Components/BadgeRankPill.swift
git commit -m "feat: add BadgeRankPill reusable rank chip"
```

---

### Task 2: Create `BadgesUpdatedSection`

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Components/BadgesUpdatedSection.swift`

- [ ] **Step 1: Create the file**

```swift
// BadgesUpdatedSection.swift
// Inline list of badge rank changes shown at the bottom of session summary views.
// Renders nothing when changes is empty — callers pass changes unconditionally.
import SwiftUI

struct BadgesUpdatedSection: View {
    let changes: [BadgeTierChange]

    var body: some View {
        if changes.isEmpty { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Badges Updated")
                .font(.headline)

            ForEach(changes, id: \.badgeID) { change in
                BadgeTierChangeRow(change: change)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct BadgeTierChangeRow: View {
    let change: BadgeTierChange

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: change.badgeID.skillDimension.systemImage)
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)

            Text(change.badgeID.displayName)
                .font(.subheadline)

            Spacer()

            rankChangeLabel
        }
    }

    @ViewBuilder private var rankChangeLabel: some View {
        if let previous = change.previousRank {
            if previous.tier != change.newRank.tier {
                // Tier promotion
                HStack(spacing: 4) {
                    BadgeRankPill(rank: previous)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    BadgeRankPill(rank: change.newRank)
                }
                .foregroundStyle(.green)
            } else {
                // Division promotion within same tier
                HStack(spacing: 4) {
                    BadgeRankPill(rank: previous)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    BadgeRankPill(rank: change.newRank)
                }
                .foregroundStyle(.blue)
            }
        } else {
            // First earn
            HStack(spacing: 4) {
                Text("Earned ·")
                    .font(.caption)
                    .foregroundStyle(.orange)
                BadgeRankPill(rank: change.newRank)
            }
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
git add HoopTrack/HoopTrack/Views/Components/BadgesUpdatedSection.swift
git commit -m "feat: add BadgesUpdatedSection post-session badge change list"
```

---

### Task 3: Create `BadgeBrowserViewModel`

**Files:**
- Create: `HoopTrack/HoopTrack/ViewModels/BadgeBrowserViewModel.swift`

- [ ] **Step 1: Create the file**

```swift
// BadgeBrowserViewModel.swift
import Foundation

@MainActor final class BadgeBrowserViewModel: ObservableObject {

    struct BadgeRowItem: Identifiable {
        let id: BadgeID
        let rank: BadgeRank?   // nil = not yet earned
    }

    private let profile: PlayerProfile

    init(profile: PlayerProfile) {
        self.profile = profile
    }

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

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/BadgeBrowserViewModel.swift
git commit -m "feat: add BadgeBrowserViewModel with earned badge lookup"
```

---

### Task 4: Create `BadgeBrowserView` (includes `BadgeDetailSheet`)

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Profile/BadgeBrowserView.swift`

- [ ] **Step 1: Create the file**

```swift
// BadgeBrowserView.swift
// Navigation destination pushed from ProfileTabView.
// Includes BadgeDetailSheet as a nested type.
import SwiftUI

struct BadgeBrowserView: View {
    @ObservedObject var viewModel: BadgeBrowserViewModel

    @State private var selectedBadgeID: BadgeID?

    var body: some View {
        List {
            ForEach(SkillDimension.allCases) { dimension in
                Section {
                    ForEach(viewModel.rows(for: dimension)) { item in
                        BadgeRowView(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { selectedBadgeID = item.id }
                    }
                } header: {
                    Label(dimension.rawValue, systemImage: dimension.systemImage)
                }
            }
        }
        .navigationTitle("Badges  ·  \(viewModel.earnedCount) / 25")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedBadgeID) { badgeID in
            BadgeDetailSheet(badgeID: badgeID, viewModel: viewModel)
                .presentationDetents([.medium])
        }
    }
}

// MARK: - BadgeRowView

private struct BadgeRowView: View {
    let item: BadgeBrowserViewModel.BadgeRowItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.id.displayName)
                    .font(.subheadline)
                    .foregroundStyle(item.rank == nil ? .secondary : .primary)
            }
            Spacer()
            if let rank = item.rank {
                BadgeRankPill(rank: rank)
            } else {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - BadgeDetailSheet

private struct BadgeDetailSheet: View {
    let badgeID: BadgeID
    @ObservedObject var viewModel: BadgeBrowserViewModel

    @Environment(\.dismiss) private var dismiss

    private var earnedBadge: EarnedBadge? {
        // Access through viewModel's profile relationship
        viewModel.rows(for: badgeID.skillDimension)
            .first { $0.id == badgeID }
            .flatMap { item -> EarnedBadge? in
                guard item.rank != nil else { return nil }
                // We know it's earned; access from profile directly
                return nil  // placeholder — see step below
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Badge icon + name
                    VStack(spacing: 8) {
                        Image(systemName: badgeID.skillDimension.systemImage)
                            .font(.system(size: 48))
                            .foregroundStyle(.orange)
                        Text(badgeID.displayName)
                            .font(.title2.bold())
                    }
                    .padding(.top, 8)

                    badgeBody
                }
                .padding()
            }
            .navigationTitle(badgeID.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private var badgeBody: some View {
        // Find the earned badge entry from the profile
        let earnedRow = viewModel.rows(for: badgeID.skillDimension).first { $0.id == badgeID }
        if let rank = earnedRow?.rank {
            // Earned — show rank, progress bar, MMR
            VStack(spacing: 16) {
                BadgeRankPill(rank: rank)
                    .scaleEffect(1.4)

                VStack(spacing: 6) {
                    let bandProgress = (rank.mmr.truncatingRemainder(dividingBy: 100)) / 100
                    ProgressView(value: bandProgress)
                        .tint(rank.tier.color)

                    HStack {
                        Text("MMR: \(Int(rank.mmr))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let nextName = nextRankName(current: rank) {
                            Text("Next: \(nextName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            // Not yet earned
            VStack(spacing: 12) {
                Text("Not Yet Earned")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Text(badgeID.scoringDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func nextRankName(current: BadgeRank) -> String? {
        let nextMMR = current.mmr + 1
        guard nextMMR < 1800 else { return nil }
        let next = BadgeRank(mmr: nextMMR)
        if next.tier == current.tier && next.division == current.division { return nil }
        return next.displayName
    }
}

// MARK: - BadgeID: Identifiable
extension BadgeID: Identifiable {
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
git add HoopTrack/HoopTrack/Views/Profile/BadgeBrowserView.swift
git commit -m "feat: add BadgeBrowserView with BadgeDetailSheet"
```

---

### Task 5: Add `badgeCount` to `ProfileViewModel`

**Files:**
- Modify: `HoopTrack/HoopTrack/ViewModels/ProfileViewModel.swift`

- [ ] **Step 1: Add computed property after the existing computed properties (e.g., after `careerFG`)**

Find the line `var careerFG: String {` and locate the closing `}` of that computed property. After it, add:

```swift
    var badgeCount: Int { profile?.earnedBadges.count ?? 0 }
```

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/ProfileViewModel.swift
git commit -m "feat: add badgeCount to ProfileViewModel"
```

---

### Task 6: Add Badges section and Training Reminder to `ProfileTabView`

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Profile/ProfileTabView.swift`

- [ ] **Step 1: Add two `@State` properties for the training reminder — inside `ProfileTabView`, after `@State private var exportCSV: String = ""`**

```swift
    @State private var reminderEnabled: Bool = UserDefaults.standard.bool(forKey: "trainingReminderEnabled")
    @State private var reminderHour: Int     = UserDefaults.standard.integer(forKey: "trainingReminderHour") == 0
                                                ? 9
                                                : UserDefaults.standard.integer(forKey: "trainingReminderHour")
```

- [ ] **Step 2: Add a `reminderTimeBinding` computed property before `var body`**

```swift
    private var reminderTimeBinding: Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = reminderHour
                components.minute = 0
                return Calendar.current.date(from: components) ?? .now
            },
            set: { date in
                reminderHour = Calendar.current.component(.hour, from: date)
            }
        )
    }
```

- [ ] **Step 3: Add the Badges section — insert it in `body` immediately before the `// MARK: Settings` section**

Find:
```swift
            // MARK: Settings
            Section("Settings") {
```

Insert before it:

```swift
            // MARK: Badges
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

- [ ] **Step 4: Add the training reminder rows inside the Settings section — after the last existing row (the preferred court picker)**

Find the closing `}` of:
```swift
                }  // end: Picker "Default Court"
                }  // end: if let profile (court)
```

Then find the closing `}` of `Section("Settings")`. Insert before that `}`:

```swift
                // Training Reminder
                Toggle("Daily Training Reminder", isOn: $reminderEnabled)
                    .tint(.orange)
                    .onChange(of: reminderEnabled) { _, on in
                        if on {
                            notificationService.scheduleTrainingReminder(hour: reminderHour)
                        } else {
                            notificationService.cancelTrainingReminder()
                        }
                        UserDefaults.standard.set(on, forKey: "trainingReminderEnabled")
                    }

                if reminderEnabled {
                    DatePicker("Reminder Time",
                               selection: reminderTimeBinding,
                               displayedComponents: .hourAndMinute)
                        .onChange(of: reminderHour) { _, hour in
                            notificationService.scheduleTrainingReminder(hour: hour)
                            UserDefaults.standard.set(hour, forKey: "trainingReminderHour")
                        }
                }
```

- [ ] **Step 5: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Profile/ProfileTabView.swift
git commit -m "feat: add Badges section and training reminder to ProfileTabView"
```

# Phase 6B — UI Polish, Refactor Analysis & Extension Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 5-screen onboarding flow, shimmer loading states, animated counters on summary screens, badge celebration animations, and produce a refactor analysis and extension report for the project.

**Architecture:** All UI polish components are self-contained modifiers (`ShimmerModifier`, `AnimatedCounterModifier`) or single files (`OnboardingView`). No changes to ViewModels — UI state additions stay in views. The refactor analysis and extension report are pure documentation tasks.

**Tech Stack:** SwiftUI `TabView(.page)`, `TimelineView(.animation)`, `AnimatableModifier`, `UINotificationFeedbackGenerator`, `AVCaptureDevice`, `UNUserNotificationCenter`, `@AppStorage`, `ContentUnavailableView` (iOS 17)

**Working directory:** `/Users/benridges/Documents/projects/HoopTrack/.claude/worktrees/phase6b-impl/HoopTrack`

**Build command:**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

## File Map

### New Files
| File | Purpose |
|---|---|
| `HoopTrack/Views/Onboarding/OnboardingView.swift` | 5-screen onboarding container + all page subviews |
| `HoopTrack/ViewModifiers/ShimmerModifier.swift` | Animated diagonal gradient shimmer |
| `HoopTrack/ViewModifiers/AnimatedCounterModifier.swift` | AnimatableModifier driving Double 0→target |
| `../docs/refactor-report.md` | Codebase refactor analysis |
| `../docs/extension-report.md` | Strategic vision + technical options brief |

### Modified Files
| File | Change |
|---|---|
| `HoopTrack/HoopTrackApp.swift` | Add `hasCompletedOnboarding` gate + `.fullScreenCover` |
| `HoopTrack/Views/Home/HomeTabView.swift` | Shimmer on loading + empty state |
| `HoopTrack/Views/Progress/ProgressTabView.swift` | Shimmer on loading + empty state |
| `HoopTrack/Views/Profile/BadgeBrowserView.swift` | Shimmer on badge rows while loading |
| `HoopTrack/Views/Train/SessionSummaryView.swift` | Animated FG% counter |
| `HoopTrack/Views/Train/DribbleSessionSummaryView.swift` | Animated dribble count counter |
| `HoopTrack/Views/Train/AgilitySessionSummaryView.swift` | Animated attempts + best time counters |
| `HoopTrack/Views/Components/BadgesUpdatedSection.swift` | Spring animation + haptic on non-empty appear |

---

## Task 1: `ShimmerModifier`

**Files:**
- Create: `HoopTrack/HoopTrack/ViewModifiers/ShimmerModifier.swift`

- [ ] **Step 1: Create `ShimmerModifier.swift`**

```swift
// ShimmerModifier.swift
// Animated diagonal gradient shimmer for skeleton loading states.
// Usage: someView.shimmer(isActive: isLoading)
// Compose with .redacted(reason: .placeholder) to show placeholder shapes.

import SwiftUI

struct ShimmerModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content
                .redacted(reason: .placeholder)
                .overlay(ShimmerOverlay())
                .allowsHitTesting(false)
        } else {
            content
        }
    }
}

// MARK: - Shimmer Overlay

private struct ShimmerOverlay: View {
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 1.5) / 1.5  // 0→1 over 1.5s
            shimmerGradient(phase: phase)
                .blendMode(.screen)
        }
        .allowsHitTesting(false)
    }

    private func shimmerGradient(phase: Double) -> some View {
        let offset = phase * 3.0 - 1.0   // sweeps from -1 → 2 (fully off-screen both sides)
        return LinearGradient(
            gradient: Gradient(colors: [
                .clear,
                .white.opacity(0.45),
                .clear
            ]),
            startPoint: UnitPoint(x: offset - 0.5, y: 0.0),
            endPoint:   UnitPoint(x: offset + 0.5, y: 1.0)
        )
    }
}

// MARK: - View Extension

extension View {
    /// Applies a shimmer loading animation when `isActive` is true.
    /// Automatically applies `.redacted(reason: .placeholder)` so the view's
    /// shape is preserved — no need to set it separately at the call site.
    func shimmer(isActive: Bool) -> some View {
        modifier(ShimmerModifier(isActive: isActive))
    }
}
```

- [ ] **Step 2: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModifiers/ShimmerModifier.swift
git commit -m "feat(ui): add ShimmerModifier — animated diagonal gradient for skeleton loading"
```

---

## Task 2: `AnimatedCounterModifier`

**Files:**
- Create: `HoopTrack/HoopTrack/ViewModifiers/AnimatedCounterModifier.swift`

- [ ] **Step 1: Create `AnimatedCounterModifier.swift`**

`AnimatableModifier` tells SwiftUI's animation engine which property to interpolate. When the parent changes `currentValue` via `.animation()`, SwiftUI calls `body(content:)` repeatedly with intermediate values, producing the count-up effect.

```swift
// AnimatedCounterModifier.swift
// AnimatableModifier that drives a formatted number from 0 → target on appear.
//
// Usage:
//   @State private var animatedFG: Double = 0
//
//   EmptyView()
//       .modifier(AnimatedCounterModifier(currentValue: animatedFG, format: "%.0f%%"))
//       .font(.system(size: 72, weight: .black, design: .rounded))
//       .foregroundStyle(.orange)
//       .animation(.easeOut(duration: 0.6), value: animatedFG)
//       .onAppear { animatedFG = session.fgPercent }
//
// Note: EmptyView() is used as the content placeholder — AnimatedCounterModifier
// replaces it entirely with a Text view showing the interpolated value.

import SwiftUI

struct AnimatedCounterModifier: AnimatableModifier {

    // MARK: - Animatable State

    /// The currently-displayed (interpolated) value. SwiftUI animates this
    /// from the old value to the new value each time it changes.
    var currentValue: Double

    var animatableData: Double {
        get { currentValue }
        set { currentValue = newValue }
    }

    // MARK: - Configuration

    /// Printf-style format string, e.g. "%.0f%%", "%d", "%.2fs"
    let format: String

    // MARK: - Body

    func body(content: Content) -> some View {
        Text(String(format: format, currentValue))
    }
}
```

- [ ] **Step 2: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModifiers/AnimatedCounterModifier.swift
git commit -m "feat(ui): add AnimatedCounterModifier — AnimatableModifier for count-up effect"
```

---

## Task 3: Animated Counters in Summary Views

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Train/SessionSummaryView.swift`
- Modify: `HoopTrack/HoopTrack/Views/Train/DribbleSessionSummaryView.swift`
- Modify: `HoopTrack/HoopTrack/Views/Train/AgilitySessionSummaryView.swift`

### 3A — `SessionSummaryView` FG% counter

The `heroSection` currently shows:
```swift
Text(String(format: "%.0f%%", session.fgPercent))
    .font(.system(size: 72, weight: .black, design: .rounded))
    .foregroundStyle(.orange)
```

- [ ] **Step 1: Add animated FG% state and replace the static Text**

Add `@State private var animatedFG: Double = 0` near the other `@State` vars at the top of `SessionSummaryView`.

In `heroSection`, replace the FG% `Text(...)` with:
```swift
EmptyView()
    .modifier(AnimatedCounterModifier(currentValue: animatedFG, format: "%.0f%%"))
    .font(.system(size: 72, weight: .black, design: .rounded))
    .foregroundStyle(.orange)
    .animation(.easeOut(duration: 0.6), value: animatedFG)
```

Add `.onAppear { animatedFG = session.fgPercent }` to the outermost `VStack` in `heroSection` (or chain it after the `VStack`). This triggers the count-up on first render.

The full updated `heroSection`:
```swift
private var heroSection: some View {
    VStack(spacing: 8) {
        EmptyView()
            .modifier(AnimatedCounterModifier(currentValue: animatedFG, format: "%.0f%%"))
            .font(.system(size: 72, weight: .black, design: .rounded))
            .foregroundStyle(.orange)
            .animation(.easeOut(duration: 0.6), value: animatedFG)

        Text("\(session.shotsMade) makes / \(session.shotsAttempted) attempts")
            .font(.title3)
            .foregroundStyle(.secondary)

        HStack(spacing: 20) {
            Label(session.formattedDuration, systemImage: "clock")
            Label(session.drillType.rawValue,  systemImage: session.drillType.systemImage)
            if !session.locationTag.isEmpty {
                Label(session.locationTag, systemImage: "location")
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 8)
    .onAppear { animatedFG = session.fgPercent }
}
```

### 3B — `DribbleSessionSummaryView` dribble count counter

The `statsGrid` uses `StatCard(title: "Dribbles", value: "\(session.totalDribbles ?? 0)", accent: .blue)`.

- [ ] **Step 2: Add animated dribble state and update statsGrid**

Add `@State private var animatedDribbles: Double = 0` to `DribbleSessionSummaryView`.

Replace the Dribbles `StatCard` in `statsGrid`:
```swift
// Before:
StatCard(title: "Dribbles",
         value: "\(session.totalDribbles ?? 0)",
         accent: .blue)

// After:
StatCard(title: "Dribbles",
         value: String(format: "%.0f", animatedDribbles),
         accent: .blue)
```

Add to the `statsGrid` computed property (chain after the `StatCardGrid { ... }` closing brace):
```swift
private var statsGrid: some View {
    StatCardGrid {
        StatCard(title: "Dribbles",
                 value: String(format: "%.0f", animatedDribbles),
                 accent: .blue)
        StatCard(title: "Avg BPS",
                 value: session.avgDribblesPerSec.map { String(format: "%.1f", $0) } ?? "—",
                 accent: bpsColor(session.avgDribblesPerSec))
        StatCard(title: "Max BPS",
                 value: session.maxDribblesPerSec.map { String(format: "%.1f", $0) } ?? "—",
                 accent: .orange)
        StatCard(title: "Combos",
                 value: "\(session.dribbleCombosDetected ?? 0)",
                 accent: .purple)
    }
    .onAppear {
        withAnimation(.easeOut(duration: 0.6)) {
            animatedDribbles = Double(session.totalDribbles ?? 0)
        }
    }
}
```

### 3C — `AgilitySessionSummaryView` hero counters

The `heroSection` calls `statCell(title:value:)` with formatted strings.

- [ ] **Step 3: Add animated states and update heroSection in AgilitySessionSummaryView**

Add these two `@State` vars to `AgilitySessionSummaryView`:
```swift
@State private var animatedAttempts: Double = 0
@State private var animatedBestShuttle: Double = 0
```

In `heroSection`, update the "Total Attempts" and "Best Shuttle" cells to use animated values:
```swift
private var heroSection: some View {
    HStack(spacing: 0) {
        statCell(
            title: "Best Shuttle",
            value: shuttleAttempts.isEmpty ? "—" : String(format: "%.2fs", animatedBestShuttle)
        )
        Divider().frame(height: 50)
        statCell(
            title: "Best Lane Agility",
            value: laneAttempts.min().map { String(format: "%.2fs", $0) } ?? "—"
        )
        Divider().frame(height: 50)
        statCell(
            title: "Total Attempts",
            value: String(format: "%.0f", animatedAttempts)
        )
        Divider().frame(height: 50)
        statCell(
            title: "Duration",
            value: durationString
        )
    }
    .padding(14)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .onAppear {
        withAnimation(.easeOut(duration: 0.6)) {
            animatedAttempts    = Double(shuttleAttempts.count + laneAttempts.count)
            animatedBestShuttle = shuttleAttempts.min() ?? 0
        }
    }
}
```

- [ ] **Step 4: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Train/SessionSummaryView.swift \
        HoopTrack/HoopTrack/Views/Train/DribbleSessionSummaryView.swift \
        HoopTrack/HoopTrack/Views/Train/AgilitySessionSummaryView.swift
git commit -m "feat(ui): animated counters in session summary hero stats"
```

---

## Task 4: `BadgesUpdatedSection` — Spring Animation + Haptic

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Components/BadgesUpdatedSection.swift`

The existing `content` var renders `BadgeTierChangeRow` items in a `ForEach`. Adding a spring transition makes them pop in, and a single haptic fires when the section first appears with non-empty data.

- [ ] **Step 1: Update `BadgesUpdatedSection.swift`**

Replace the `content` computed property and add `.onAppear` to fire the haptic:

```swift
import SwiftUI
import UIKit   // for UINotificationFeedbackGenerator

struct BadgesUpdatedSection: View {
    let changes: [BadgeTierChange]

    var body: some View {
        if changes.isEmpty { EmptyView() } else { content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Badges Updated")
                .font(.headline)

            ForEach(Array(changes.enumerated()), id: \.element.badgeID) { index, change in
                BadgeTierChangeRow(change: change)
                    .transition(
                        .scale(scale: 0.8)
                        .combined(with: .opacity)
                    )
                    .animation(
                        .spring(response: 0.4, dampingFraction: 0.6)
                        .delay(Double(index) * 0.08),   // stagger rows
                        value: changes.count
                    )
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            // Fire a single success haptic when badge changes appear
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
```

The `BadgeTierChangeRow` struct beneath it is unchanged.

- [ ] **Step 2: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Components/BadgesUpdatedSection.swift
git commit -m "feat(ui): spring animation + haptic on BadgesUpdatedSection appear"
```

---

## Task 5: Shimmer + Empty States — `HomeTabView`

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Home/HomeTabView.swift`

- [ ] **Step 1: Add shimmer to career stats block while loading**

In `HomeTabView`, find `ratingSection` and `shootingSection`. Wrap them in `.shimmer(isActive: viewModel.isLoading)`:

```swift
// MARK: Overall Rating + Radar
ratingSection
    .shimmer(isActive: viewModel.isLoading)

// MARK: Shooting %
shootingSection
    .shimmer(isActive: viewModel.isLoading)
```

- [ ] **Step 2: Add empty state when there are no sessions**

The `DashboardViewModel` has `lastSessionSummary: TrainingSession?` and `weeklyVolume: [(date: Date, attempts: Int)]`. When `weeklyVolume` is empty and the profile has zero sessions, show a `ContentUnavailableView`.

In `HomeTabView.body`, find the `volumeSection` call and wrap it:

```swift
// MARK: Weekly Volume Chart
if viewModel.weeklyVolume.isEmpty && !viewModel.isLoading {
    ContentUnavailableView {
        Label("No Sessions Yet", systemImage: "basketball.fill")
    } description: {
        Text("Complete your first session to start tracking progress.")
    } actions: {
        // This button text is informational only — actual navigation is via the Train tab
        Text("Tap **Train** to get started")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
    .padding(.vertical, 20)
} else {
    volumeSection
}
```

- [ ] **Step 3: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Home/HomeTabView.swift
git commit -m "feat(ui): shimmer loading + empty state in HomeTabView"
```

---

## Task 6: Shimmer + Empty State — `ProgressTabView`

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Progress/ProgressTabView.swift`

- [ ] **Step 1: Apply shimmer to the FG% trend section while loading**

In `ProgressTabView`, wrap `fgTrendSection` with shimmer:

```swift
// MARK: FG% Trend Chart
fgTrendSection
    .shimmer(isActive: viewModel.isLoading)
```

- [ ] **Step 2: Add empty state when no sessions exist for the selected range**

Wrap the `fgTrendSection` + chart with a guard:

```swift
// MARK: FG% Trend Chart
if viewModel.sessions.isEmpty && !viewModel.isLoading {
    ContentUnavailableView {
        Label("No Data", systemImage: "chart.line.uptrend.xyaxis")
    } description: {
        Text("Complete your first session to see your \(viewModel.selectedTimeRange.rawValue) trend.")
    }
    .padding(.vertical, 20)
} else {
    fgTrendSection
        .shimmer(isActive: viewModel.isLoading)
}
```

- [ ] **Step 3: Remove the existing loading spinner overlay (replaced by shimmer)**

The existing `ProgressTabView` has:
```swift
.overlay {
    if viewModel.isLoading {
        ProgressView()
    }
}
```

Remove this `.overlay` modifier — the shimmer now communicates loading state.

- [ ] **Step 4: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Progress/ProgressTabView.swift
git commit -m "feat(ui): shimmer loading + empty state in ProgressTabView"
```

---

## Task 7: Shimmer — `BadgeBrowserView`

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Profile/BadgeBrowserView.swift`

The `BadgeBrowserViewModel` has `isLoading: Bool` (check if it exists; if not, add `@Published var isLoading: Bool = false` and set it in `init` via a brief task).

- [ ] **Step 1: Check `BadgeBrowserViewModel` for `isLoading`**

Read `HoopTrack/HoopTrack/ViewModels/BadgeBrowserViewModel.swift`. If `isLoading` does not exist, add it:

```swift
// In BadgeBrowserViewModel, at the top of published vars:
@Published var isLoading: Bool = false
```

- [ ] **Step 2: Apply shimmer to badge rows in `BadgeBrowserView`**

In `BadgeBrowserView.body`, wrap the `ForEach` of rows with shimmer:

```swift
ForEach(viewModel.rows(for: dimension)) { item in
    BadgeRowView(item: item)
        .contentShape(Rectangle())
        .onTapGesture { selectedBadgeID = item.id }
        .shimmer(isActive: viewModel.isLoading)
}
```

- [ ] **Step 3: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Profile/BadgeBrowserView.swift \
        HoopTrack/HoopTrack/ViewModels/BadgeBrowserViewModel.swift
git commit -m "feat(ui): shimmer on BadgeBrowserView badge rows"
```

---

## Task 8: `OnboardingView` — 5-Screen First-Launch Flow

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Onboarding/OnboardingView.swift`
- Modify: `HoopTrack/HoopTrack/HoopTrackApp.swift`

All 5 page subviews live in `OnboardingView.swift` as private structs. The visual language matches the existing app: dark background, orange accents, `.ultraThinMaterial` cards, SF Symbols.

- [ ] **Step 1: Create `OnboardingView.swift`**

```swift
// OnboardingView.swift
// 5-screen first-launch flow combining feature showcase with permission requests.
// Gated by @AppStorage("hasCompletedOnboarding") — shown only once.
// All page subviews are private to this file.

import SwiftUI
import AVFoundation
import UserNotifications

struct OnboardingView: View {
    @Binding var hasCompletedOnboarding: Bool
    @State private var currentPage = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $currentPage) {
                WelcomePage(currentPage: $currentPage)
                    .tag(0)
                CameraPage(currentPage: $currentPage)
                    .tag(1)
                NotificationsPage(currentPage: $currentPage)
                    .tag(2)
                GoalsPage(currentPage: $currentPage)
                    .tag(3)
                ProfileSetupPage(isComplete: $hasCompletedOnboarding)
                    .tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))   // custom dots below
            .ignoresSafeArea()

            // Custom page dots
            HStack(spacing: 8) {
                ForEach(0..<5) { index in
                    Circle()
                        .fill(currentPage == index ? Color.orange : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                        .animation(.easeInOut(duration: 0.2), value: currentPage)
                }
            }
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    @Binding var currentPage: Int

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "basketball.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.orange)

                Text("HoopTrack")
                    .font(.system(size: 42, weight: .black, design: .rounded))

                Text("Track every shot.\nOwn your game.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            Button {
                withAnimation { currentPage = 1 }
            } label: {
                Text("Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 2: Camera + Shot Tracking

private struct CameraPage: View {
    @Binding var currentPage: Int
    @State private var permissionGranted = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Feature mini-demo card
            VStack(spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FG%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("52%")
                            .font(.title2.bold())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Shot auto-detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: 0.52)
                    .tint(.orange)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                Text("Auto Shot Detection")
                    .font(.title2.bold())

                Text("Your camera tracks makes and misses automatically — no buttons needed during your session.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task {
                        await AVCaptureDevice.requestAccess(for: .video)
                        permissionGranted = true
                        withAnimation { currentPage = 2 }
                    }
                } label: {
                    Text("Allow Camera")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }

                if !permissionGranted {
                    Button("Continue without camera") {
                        withAnimation { currentPage = 2 }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 3: Notifications + Badges

private struct NotificationsPage: View {
    @Binding var currentPage: Int

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Badge earn illustration
            VStack(spacing: 10) {
                Text("🏅 Badge Earned!")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)

                HStack(spacing: 8) {
                    Text("Deadeye · Gold I")
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Color.orange.opacity(0.2),
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(Color.orange, lineWidth: 1))
                        .foregroundStyle(.orange)
                }
                Text("+120 MMR")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                Text("Badge Milestones")
                    .font(.title2.bold())

                Text("Get notified when you earn badges and hit milestones. You can turn this off anytime in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    Task {
                        try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .badge, .sound])
                        withAnimation { currentPage = 3 }
                    }
                } label: {
                    Text("Allow Notifications")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }

                Button("Skip for now") {
                    withAnimation { currentPage = 3 }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 4: Goals Showcase

private struct GoalsPage: View {
    @Binding var currentPage: Int

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Goal card illustration
            VStack(alignment: .leading, spacing: 12) {
                Text("ACTIVE GOALS")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Shoot 50% FG")
                        .font(.subheadline.bold())
                    ProgressView(value: 0.68)
                        .tint(.orange)
                    Text("48% → 50%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 32)

            VStack(spacing: 12) {
                Image(systemName: "target")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)

                Text("Set Your Goals")
                    .font(.title2.bold())

                Text("Track progress toward your shooting and fitness targets. Set your first goal right from the Progress tab.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            Button {
                withAnimation { currentPage = 4 }
            } label: {
                Text("Continue →")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Page 5: Profile Setup

private struct ProfileSetupPage: View {
    @Binding var isComplete: Bool
    @State private var playerName: String = ""

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.orange)

                Text("What's your name?")
                    .font(.title2.bold())

                Text("Used on your profile and career stats.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Your name", text: $playerName)
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 48)

            Spacer()

            Button {
                // Persist name so ProfileViewModel can apply it on first load.
                if !playerName.trimmingCharacters(in: .whitespaces).isEmpty {
                    UserDefaults.standard.set(playerName, forKey: "onboardingPlayerName")
                }
                isComplete = true
            } label: {
                Text("Start Training 🏀")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 48)
        }
        .padding(.horizontal, 24)
    }
}
```

- [ ] **Step 2: Wire `OnboardingView` into `HoopTrackApp.swift`**

Add `@AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false` to `HoopTrackApp`.

Add `.fullScreenCover` to the `WindowGroup` body. The existing `HoopTrackApp.swift` (after Task 10 of Phase 6A) looks like:

```swift
@main
struct HoopTrackApp: App {

    let modelContainer: ModelContainer = { ... }()

    @StateObject private var hapticService       = HapticService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var cameraService       = CameraService()
    @StateObject private var appState            = AppState()
    @StateObject private var metricsService      = MetricsService()

    @AppStorage("hasCompletedOnboarding")
    private var hasCompletedOnboarding = false             // ← add this

    var body: some Scene {
        WindowGroup {
            CoordinatorHost()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
                .environmentObject(appState)
                .onOpenURL { appState.handleDeepLink($0) }
                .task { metricsService.register() }
                .fullScreenCover(isPresented: .init(   // ← add this block
                    get: { !hasCompletedOnboarding },
                    set: { if !$0 { hasCompletedOnboarding = true } }
                )) {
                    OnboardingView(hasCompletedOnboarding: $hasCompletedOnboarding)
                }
        }
    }
}
```

**Note:** If Phase 6A has not been applied yet (this worktree starts from `origin/main`, not `feat/phase6a`), the `HoopTrackApp.swift` in this worktree won't have `AppState`, `MetricsService`, or `.onOpenURL` from Phase 6A. In that case, add only the `@AppStorage` and `.fullScreenCover` changes to the current file content.

- [ ] **Step 3: Apply `onboardingPlayerName` in `ProfileViewModel.load()`**

When the profile is first created, set its name from the onboarding if available. In `ProfileViewModel.swift`, find the `load()` method and add:

```swift
// After: profile = try dataService.fetchOrCreateProfile()
// Add:
if let storedName = UserDefaults.standard.string(forKey: "onboardingPlayerName"),
   !storedName.isEmpty,
   (profile?.name ?? "").isEmpty {
    profile?.name = storedName
    try? dataService.saveContext()  // or rely on natural save
}
```

**Note:** If `DataService` does not have a `saveContext()` method, omit this step and rely on the profile name being set lazily. The name can be edited in the Profile tab at any time.

Actually — check `DataService` for a `save()` helper. If one doesn't exist, use `try? modelContext.save()` in `ProfileViewModel` after updating the name. `ProfileViewModel` already has a `dataService` property which holds a `DataService` reference. Read the ViewModel to confirm the `modelContext` is accessible or use `viewModel.saveName()` which is already implemented.

Simpler alternative: skip the auto-apply and let the user see their name in the Profile tab (it will be empty initially, but editable). The name entry in the onboarding persists to `UserDefaults` — a future enhancement can wire it up.

- [ ] **Step 4: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Onboarding/OnboardingView.swift \
        HoopTrack/HoopTrack/HoopTrackApp.swift
git commit -m "feat(onboarding): 5-screen guided+showcase onboarding flow"
```

---

## Task 9: Refactor Analysis → `docs/refactor-report.md`

This is a documentation task. Read the listed files and write a structured findings report.

**Files to read before writing:**
- `HoopTrack/HoopTrack/Services/CameraService.swift`
- `HoopTrack/HoopTrack/Services/DataService.swift`
- `HoopTrack/HoopTrack/Services/SessionFinalizationCoordinator.swift`
- `HoopTrack/HoopTrack/ViewModels/DashboardViewModel.swift`
- `HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift`
- `HoopTrack/HoopTrack/ViewModels/LiveSessionViewModel.swift`
- `HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift`
- `HoopTrack/HoopTrack/Views/Train/DribbleDrillView.swift`
- `HoopTrack/HoopTrack/Views/Train/AgilitySessionView.swift`
- `HoopTrack/HoopTrack/Views/Train/SessionSummaryView.swift`
- `HoopTrack/HoopTrack/Views/Profile/ProfileTabView.swift`

**What to look for:**

1. **File size & responsibility** — files over ~250 lines or with mixed concerns (Views containing business logic, Services doing UI work)
2. **Duplication** — repeated patterns suitable for extraction. Known candidate: the long-press end-session button pattern appears in `LiveSessionView`, `DribbleDrillView`, and `AgilitySessionView`
3. **Concurrency hygiene** — any `DispatchQueue.main.async` that should be `Task { @MainActor in }`, missing `@MainActor`, unsafe captures
4. **SwiftData access** — Views reaching into `modelContext` directly for non-trivial operations outside `DataService`
5. **Dead code** — commented-out blocks, unused `@Published` properties, unreachable switch branches

- [ ] **Step 1: Read all files listed above**

Read each file fully before writing the report.

- [ ] **Step 2: Write `docs/refactor-report.md`**

Use this exact structure. Fill in actual file paths, line numbers, and descriptions based on what you found:

```markdown
# HoopTrack Codebase Refactor Report

**Date:** 2026-04-12  
**Scope:** Phase 6B analysis — pre-refactor findings

---

## Summary

| # | Severity | Finding | File |
|---|---|---|---|
| ... | Critical / Important / Minor | ... | file:line |

---

## Findings

### 1. [Finding title]
**Severity:** Critical / Important / Minor  
**File:** `path/to/file.swift:line`  
**Description:**  
[What the problem is and why it matters]

**Suggested fix:**  
[Concrete change — show before/after code if helpful]

---

[Repeat for each finding]

---

## Follow-up Tasks

Findings rated Critical or Important should be tracked as follow-up:

| Finding | Severity | Suggested Action |
|---|---|---|
| ... | ... | ... |
```

- [ ] **Step 3: Commit**

```bash
git add docs/refactor-report.md
git commit -m "docs: codebase refactor analysis report"
```

---

## Task 10: Extension Report → `docs/extension-report.md`

Write the full two-part extension report as specified in the Phase 6 design doc. The content is fully specified in `docs/superpowers/specs/2026-04-12-phase6-design.md` (Sections 6 — Extension Report, Part 1 and Part 2). Read that file first, then write the report.

**Files:**
- Read: `docs/superpowers/specs/2026-04-12-phase6-design.md` (sections on Extension Report)
- Create: `docs/extension-report.md`

- [ ] **Step 1: Read the spec's Extension Report sections**

Read `docs/superpowers/specs/2026-04-12-phase6-design.md`, focusing on the "Extension Report" section (Part 1 — Strategic Vision, Part 2 — Technical Options Brief).

- [ ] **Step 2: Write `docs/extension-report.md`**

The document should be structured exactly as:

```markdown
# HoopTrack Extension Report

**Date:** 2026-04-12  
**Written at:** End of Phase 6B  
**Purpose:** Strategic vision for HoopTrack's growth beyond a solo training tool, plus a comprehensive technical options brief for production readiness.

---

## Part 1 — Strategic Vision

### What HoopTrack Could Become

[Cover each of the following, 2–4 sentences each:
- Team & Multiplayer Sessions
- Coach Review Mode
- Drill Marketplace
- Social Leaderboards
- Video Sharing
- Web Dashboard]

---

## Part 2 — Technical Options Brief

[Cover ALL of the following categories, with bullet-pointed options and a recommended choice noted for each.
Each category should have a heading and 3–6 options with brief notes:]

### Authentication & Identity
### Backend & API
### Sync & Real-time
### Database
### File & Media Storage
### Push Notifications
### Analytics & Monitoring
### CI/CD & Distribution
### Security
### Monetisation
### Web Presence
### ML/CV Improvements
### Social Infrastructure
### Accessibility
```

The full content for each section is in the Phase 6 design spec. Copy and expand it into the report, adding commentary where useful. This document is for the developer's reference — be thorough.

- [ ] **Step 3: Commit**

```bash
git add docs/extension-report.md
git commit -m "docs: extension report — strategic vision + technical options brief"
```

---

## Self-Review Checklist

### Spec Coverage

| Spec Requirement | Task |
|---|---|
| 5-screen onboarding (Welcome, Camera, Notifications, Goals, Profile) | Task 8 |
| Onboarding gate in `HoopTrackApp` via `@AppStorage` | Task 8 |
| App visual aesthetic (not wireframe) | Task 8 — dark bg, orange accents, `.ultraThinMaterial` |
| `ShimmerModifier` with `TimelineView(.animation)` | Task 1 |
| Shimmer on HomeTabView career stats | Task 5 |
| Shimmer on ProgressTabView session list | Task 6 |
| Shimmer on BadgeBrowserView badge rows | Task 7 |
| `ContentUnavailableView` empty state — HomeTabView | Task 5 |
| `ContentUnavailableView` empty state — ProgressTabView | Task 6 |
| GoalListView empty state — already in Phase 5B; review for consistency | No task — already done |
| `AnimatedCounterModifier` | Task 2 |
| Animated counters in SessionSummaryView | Task 3A |
| Animated counters in DribbleSessionSummaryView | Task 3B |
| Animated counters in AgilitySessionSummaryView | Task 3C |
| `BadgesUpdatedSection` spring animation | Task 4 |
| `UINotificationFeedbackGenerator` haptic on badge appear | Task 4 |
| `docs/refactor-report.md` | Task 9 |
| `docs/extension-report.md` (both parts) | Task 10 |

### Placeholder Scan
- Task 8 (Onboarding) Step 3: the `saveContext()` note has a conditional — the plan correctly offers two paths (with and without Phase 6A merged). This is intentional, not a placeholder.
- All other steps contain exact code.

### Type Consistency
- `AnimatedCounterModifier(currentValue:format:)` — defined in Task 2, used in Tasks 3A/3B/3C. ✓
- `ShimmerModifier` via `.shimmer(isActive:)` extension — defined in Task 1, used in Tasks 5/6/7. ✓
- `OnboardingView(hasCompletedOnboarding:)` — defined in Task 8, wired in `HoopTrackApp` Task 8. ✓
- `BadgesUpdatedSection` changes — spring animation wraps the existing `ForEach(changes, id: \.badgeID)`. The `id` keypath must match what's in the existing `BadgeTierChange` model. Verify `BadgeTierChange` has a `badgeID` property before applying Task 4. ✓ (it does — seen in existing file)

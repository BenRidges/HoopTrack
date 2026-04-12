# HoopTrack Accessibility Upgrade Plan

**Date:** 2026-04-12  
**Scope:** iOS 16+ minimum deployment  
**Target standard:** WCAG 2.1 AA, Apple HIG Accessibility guidelines, App Store Review Guideline 5.1.5

---

## 1. Overview

### Why This Matters

**App Store compliance.** Apple's App Store Review Guideline 5.1.5 states apps must not discriminate based on disability and should follow accessibility best practices. Reviewers routinely flag custom-drawn views and non-standard gestures that are unreachable via VoiceOver or Switch Control.

**Market reach.** Approximately 7% of iOS users rely on at least one accessibility feature (VoiceOver, Switch Control, larger text, or reduced motion). For an app targeting athletes of all backgrounds and ages, ignoring this segment is a meaningful missed opportunity.

**Legal risk.** The ADA and equivalent international statutes increasingly apply to mobile apps. A public-facing app with custom camera interfaces and no alternative access path for blind users is an exposure.

### Current Estimated Compliance Gap

Based on a static review of the source code:

| Area | Status |
|---|---|
| VoiceOver labels | None found — zero `accessibilityLabel` calls anywhere in the codebase |
| Dynamic Type | Extensive use of hard-coded `font(.system(size: N))` throughout all views |
| WCAG contrast | Orange `#FF6B35` at 100% opacity on `Color.black` passes 3:1 but fails 4.5:1 for body text |
| Switch Control | Long-press `DragGesture` on End Session button has no alternative; unreachable |
| Reduced Motion | `ShimmerModifier`, `AgilitySessionView` pulse animation, and make/miss flash animations have no `accessibilityReduceMotion` guard |
| Live session | No `UIAccessibility` announcements posted for shot detection events |

Estimated overall WCAG 2.1 AA compliance today: **~20%** (structural navigation works; content and interactive semantics are absent).

---

## 2. VoiceOver Audit Checklist

### 2.1 Tab Bar

The root `ContentView` builds a `TabView` with four tabs. Each `tabItem` label should be explicit and include a hint for non-obvious actions.

```swift
// ContentView.swift — tabItem additions
.tabItem {
    Label("Home", systemImage: "house.fill")
}
.accessibilityLabel("Home")
.accessibilityHint("Dashboard with skill ratings and session history")

.tabItem {
    Label("Train", systemImage: "figure.basketball")
}
.accessibilityLabel("Train")
.accessibilityHint("Browse drills and start a session")

.tabItem {
    Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
}
.accessibilityLabel("Progress")
.accessibilityHint("Shot charts, goal tracking, and personal records")

.tabItem {
    Label("Profile", systemImage: "person.crop.circle")
}
.accessibilityLabel("Profile")
.accessibilityHint("Badges, skill ratings, and account settings")
```

### 2.2 TrainTabView — Drill Picker Cards

`DrillCard` is a `Button` with a plain button style. VoiceOver will read the first `Text` child by default, which is the drill name. That is insufficient — the category, description, and the fact that it launches a session must all be communicated.

**Label content rule:** `"<drill name>, <drill type> drill. <description first sentence>. Double-tap to configure and start."`

```swift
// In DrillCard.body — add after the button content
.accessibilityLabel("\(drill.rawValue), \(drill.drillType.rawValue) drill. \(description)")
.accessibilityHint("Double-tap to open session setup")
.accessibilityAddTraits(.isButton)
```

`FilterChip` — selected state must be announced:

```swift
.accessibilityLabel("\(label) filter")
.accessibilityValue(isSelected ? "selected" : "not selected")
.accessibilityHint(isSelected ? "Double-tap to remove filter" : "Double-tap to filter drills")
.accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
```

`quickStartBanner`:

```swift
Button { ... } label: { ... }
.accessibilityLabel("Free Shoot — Quick Start")
.accessibilityHint("Open court session with automatic shot tracking. Double-tap to begin.")
```

### 2.3 Live Session CV Overlay

The live session HUD contains two critical clusters of information (FG counter, timer) and the recent-shots strip. Each must be grouped and labelled as a single accessibility element rather than exposing individual `Text` views.

**Top HUD — FG counter cluster:**

```swift
VStack(alignment: .leading, spacing: 2) {
    Text(viewModel.fgPercentString)
    Text("\(viewModel.shotsMade) / \(viewModel.shotsAttempted)")
}
.accessibilityElement(children: .ignore)
.accessibilityLabel("Field goal percentage \(viewModel.fgPercentString), \(viewModel.shotsMade) makes out of \(viewModel.shotsAttempted) attempts")
```

**Timer cluster:**

```swift
VStack(alignment: .trailing, spacing: 2) {
    Text(viewModel.elapsedFormatted)
    if viewModel.isPaused { Text("PAUSED") }
}
.accessibilityElement(children: .ignore)
.accessibilityLabel(viewModel.isPaused
    ? "Session timer \(viewModel.elapsedFormatted), paused"
    : "Session timer \(viewModel.elapsedFormatted)")
```

**Recent shots strip** — treat as a single summary element, not five individual circles:

```swift
recentShotsStrip
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(recentShotsAccessibilityLabel)

// Computed property:
private var recentShotsAccessibilityLabel: String {
    guard !viewModel.recentShots.isEmpty else { return "No shots yet" }
    let makes = viewModel.recentShots.filter { $0.result == .make }.count
    let total = viewModel.recentShots.count
    return "Last \(total) shots: \(makes) makes, \(total - makes) misses"
}
```

**Make/miss animation text** — these transient overlays should be VoiceOver-invisible because an announcement (Section 6) will handle audio. Suppress them:

```swift
makeAnimation.accessibilityHidden(true)
missAnimation.accessibilityHidden(true)
```

**Calibration overlay** — must be fully accessible and block focus while visible:

```swift
calibrationOverlay
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Camera calibration in progress. Aim at the hoop and keep the backboard in frame until the indicator turns green.")
```

### 2.4 Shot Chart Heat Map (CourtMapView)

`CourtMapView` is a pure-visual `Canvas` + `ForEach` of positioned `Circle` views. A VoiceOver user would encounter dozens of unlabelled interactive elements (or nothing at all if the circles are not in the accessibility tree).

**Strategy:** represent the court as a single accessible element that summarises shot distribution, with an optional "detail mode" that lists shots by zone.

```swift
// CourtMapView.body — wrap the ZStack
ZStack { ... }
.accessibilityElement(children: .ignore)
.accessibilityLabel(courtMapAccessibilitySummary)

// Extension on CourtMapView:
private var courtMapAccessibilitySummary: String {
    guard !shots.isEmpty else { return "Shot chart. No shots recorded." }
    let makes = shots.filter { $0.result == .make }.count
    let misses = shots.filter { $0.result == .miss }.count
    let zones = Dictionary(grouping: shots, by: { $0.zone?.rawValue ?? "Unknown" })
        .sorted { $0.key < $1.key }
        .map { "\($0.key): \($0.value.filter { $0.result == .make }.count) of \($0.value.count)" }
        .joined(separator: ", ")
    return "Shot chart. \(makes) makes, \(misses) misses. By zone: \(zones)."
}
```

For `ProgressTabView.heatMapSection`:

```swift
heatMapSection
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Shot heat map. \(viewModel.heatMapShots.count) total shots.")
```

The `CourtMapLegend` should be suppressed in VoiceOver since the colour legend is meaningless without visual context (the summary above conveys the same information without colour dependency):

```swift
CourtMapLegend().accessibilityHidden(true)
```

### 2.5 Badge Browser

`BadgeRowView` currently exposes the badge name as a subheadline `Text`. VoiceOver needs to convey earned state, tier, division, and score.

```swift
// BadgeRowView — replace implicit label with explicit one
private var rowAccessibilityLabel: String {
    if let rank = item.rank {
        return "\(item.id.displayName) badge. Earned. Rank: \(rank.displayName). MMR: \(Int(rank.mmr))."
    } else {
        return "\(item.id.displayName) badge. Locked."
    }
}

var body: some View {
    HStack { ... }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(rowAccessibilityLabel)
    .accessibilityHint("Double-tap to see details")
    .accessibilityAddTraits(.isButton)
}
```

`BadgeRankPill` — when it appears inside `BadgeDetailSheet` at a larger scale, the rank pill is decorative (the surrounding text already announces the rank). Hide it:

```swift
BadgeRankPill(rank: rank)
    .scaleEffect(1.4)
    .accessibilityHidden(true)  // announced by parent sheet description
```

`BadgeDetailSheet` — add a summary label to the top `VStack`:

```swift
VStack(spacing: 8) {
    Image(systemName: badgeID.skillDimension.systemImage)
        .accessibilityHidden(true)
    Text(badgeID.displayName)
        .font(.title2.bold())
}
.accessibilityElement(children: .ignore)
.accessibilityLabel("\(badgeID.displayName) badge, \(badgeID.skillDimension.rawValue) skill")
```

The `ProgressView` inside the earned badge body needs a label:

```swift
ProgressView(value: bandProgress)
    .tint(rank.tier.color)
    .accessibilityLabel("Progress to next rank")
    .accessibilityValue(String(format: "%.0f percent", bandProgress * 100))
```

### 2.6 Progress Charts (Swift Charts)

Swift Charts provides automatic accessibility support for chart marks, but only if `accessibilityLabel` and `accessibilityValue` are added to each mark. Without them, VoiceOver reads raw numeric values with no context.

**FG% Trend chart:**

```swift
Chart(viewModel.fgTrendData, id: \.date) { item in
    LineMark(
        x: .value("Date", item.date, unit: .day),
        y: .value("FG%", item.fg)
    )
    .accessibilityLabel(item.date.formatted(date: .abbreviated, time: .omitted))
    .accessibilityValue(String(format: "%.0f percent field goals", item.fg))

    PointMark(
        x: .value("Date", item.date, unit: .day),
        y: .value("FG%", item.fg)
    )
    .accessibilityLabel(item.date.formatted(date: .abbreviated, time: .omitted))
    .accessibilityValue(String(format: "%.0f percent field goals", item.fg))
    .accessibilityHidden(false)  // ensure points are reachable in chart navigation
}
```

Add a chart summary description above the chart:

```swift
// At the top of fgTrendSection VStack:
if !viewModel.fgTrendData.isEmpty {
    Text(fgTrendSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel(fgTrendSummary)
}

private var fgTrendSummary: String {
    guard let first = viewModel.fgTrendData.first,
          let last  = viewModel.fgTrendData.last else { return "" }
    let trend = last.fg >= first.fg ? "up" : "down"
    return "FG% trend: \(String(format: "%.0f%%", first.fg)) to \(String(format: "%.0f%%", last.fg)), trending \(trend) over the selected period."
}
```

**Weekly Volume bar chart (HomeTabView):**

```swift
BarMark(
    x: .value("Day", item.date, unit: .day),
    y: .value("Shots", item.attempts)
)
.accessibilityLabel(item.date.formatted(.dateTime.weekday(.wide)))
.accessibilityValue("\(item.attempts) shots")
```

**Zone Efficiency bars** (rendered with `GeometryReader + Capsule`, not Swift Charts) — each zone row needs a combined label:

```swift
// Inside ForEach(viewModel.zoneEfficiency):
VStack(spacing: 4) { ... }
.accessibilityElement(children: .ignore)
.accessibilityLabel("\(ze.zone.rawValue) zone: \(String(format: "%.0f", ze.fgPercent)) percent, \(ze.made) makes out of \(ze.attempted) attempts")
```

### 2.7 Long-Press End Session Button

The custom `DragGesture` end-session button in `LiveSessionView`, `DribbleDrillView`, and `AgilitySessionView` is **completely inaccessible** to VoiceOver and Switch Control users. A `DragGesture(minimumDistance: 0)` does not synthesise any accessibility action.

**Recommended approach: `accessibilityActivate()` via `accessibilityAction`**

This adds a VoiceOver double-tap activation that immediately calls `endSession()` without requiring the 1.5-second hold (which is a reasonable exception for accessibility users who cannot perform a continuous press):

```swift
// Replace the plain Text + DragGesture with a ZStack that carries accessibility actions
Text(isLongPressingEnd ? "Hold…" : "End Session")
    // ... existing styling ...
    .gesture(existingDragGesture)
    .accessibilityLabel("End Session")
    .accessibilityHint("Double-tap to end this session immediately. In normal use, hold for 1.5 seconds.")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction(named: "End Session") {
        Task { await viewModel.endSession() }
    }
```

**Alternative: explicit companion button (recommended for Switch Control)**

Add a visible "End" button inside an `accessibilityElement(children: .contain)` container that shows only when `UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning`:

```swift
@Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

// Inside bottomControls, alongside the long-press button:
if UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning {
    Button {
        Task { await viewModel.endSession() }
    } label: {
        Text("End Session")
            .font(.subheadline.bold())
            .padding(.horizontal, 20)
            .frame(height: 52)
            .background(Color.red, in: Capsule())
            .foregroundStyle(.white)
    }
    .accessibilityLabel("End Session")
    .accessibilityHint("Ends the current session and saves results")
}
```

This pattern must be applied in all three views: `LiveSessionView`, `DribbleDrillView`, and `AgilitySessionView`. When the long-press gesture duplication is refactored into a shared component (a separate architectural recommendation), this accessibility code needs to live there too.

---

## 3. Dynamic Type Implementation Guide

### 3.1 Audit — Hard-Coded Font Sizes

The following `font(.system(size: N))` calls were identified and must be replaced with semantic equivalents or `@ScaledMetric`-relative sizes:

| File | Size(s) | Replacement |
|---|---|---|
| `LiveSessionView` | 36 (FG%, timer), 48 (Make/Miss flash) | `.largeTitle` + `.font(.system(.largeTitle, design: .rounded))` |
| `DribbleDrillView` | 36 (dribble count, timer) | `.largeTitle` with appropriate `design:` |
| `AgilitySessionView` | 72 (stopwatch display) | `@ScaledMetric(relativeTo: .largeTitle) var timerFontSize = 72` |
| `StatCard` | 28 (value text) | `.title` or `@ScaledMetric(relativeTo: .title) var statFontSize = 28` |
| `HomeTabView` | 22 (streak number), 28 (overall rating) | `.title2`, `.title` respectively |
| `SkillRadarView` | 11 (icon), 9 (label text) | `.caption2` (labels are intentionally small; cap at `.caption2`) |
| `BadgeBrowserView` | 48 (badge icon in detail) | SF Symbol `.font(.system(size: 48))` → `.font(.largeTitle)` (SF Symbols scale with Dynamic Type by default) |
| `ProfileTabView` | 28 (avatar/icon) | `.title` |
| `TrainTabView` | 44 (quick start play icon) | `.system(size: 44)` on SF Symbol → `.font(.largeTitle)` |
| `SessionSummaryView` | 72 (FG% hero number) | `@ScaledMetric(relativeTo: .largeTitle) var heroFontSize = 72` |
| `OnboardingView` | 80, 42, 44, 72 (hero icons and titles) | Use `.largeTitle` and SF Symbol scaling |
| `AnimatedCounterModifier` | Uses format string, sized by caller | Caller must use `@ScaledMetric` |

### 3.2 How to Replace with Semantic Styles

**Simple case — semantic font:**

```swift
// Before
Text(viewModel.fgPercentString)
    .font(.system(size: 36, weight: .black, design: .rounded))

// After
Text(viewModel.fgPercentString)
    .font(.system(.largeTitle, design: .rounded).weight(.black))
```

**Complex case — large display numbers (timer, hero FG%):**  
The stopwatch and hero stat displays use sizes like 72pt that have no direct semantic equivalent. Use `@ScaledMetric` so the text grows proportionally with the user's text size preference while staying within the physical constraints of the live session HUD:

```swift
// AgilitySessionView
@ScaledMetric(relativeTo: .largeTitle) private var timerFontSize: CGFloat = 72

// Usage:
Text(timerString)
    .font(.system(size: timerFontSize, weight: .black, design: .monospaced))
```

**SF Symbol icons:**  
Replace explicit sizes on SF Symbols with semantic sizes — the system automatically scales these:

```swift
// Before
Image(systemName: "play.circle.fill")
    .font(.system(size: 44))

// After
Image(systemName: "play.circle.fill")
    .font(.largeTitle)
```

### 3.3 Layout Adaptations for Large Text

At `xxxLarge` and `Accessibility` text sizes, two-column grid layouts (`StatCardGrid`, drill grid in `TrainTabView`) will overflow. Cards need to reflow to a single column.

```swift
// Use the sizeCategory environment to adapt the grid:
@Environment(\.dynamicTypeSize) private var dynamicTypeSize

private var gridColumns: [GridItem] {
    if dynamicTypeSize >= .accessibility1 {
        return [GridItem(.flexible())]      // single column at XXLarge+
    } else if dynamicTypeSize >= .xLarge {
        return [GridItem(.flexible()), GridItem(.flexible())]  // standard 2-col
    } else {
        return [GridItem(.flexible()), GridItem(.flexible())]
    }
}

// StatCardGrid — propagate the environment or accept a columns parameter:
struct StatCardGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let content: Content

    private var columns: [GridItem] {
        dynamicTypeSize >= .accessibility1
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) { content }
    }
}
```

`DrillCard` in `TrainTabView` — at large text sizes, the description text will truncate at 3 lines. Consider removing the line limit or increasing it at large sizes:

```swift
Text(description)
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(dynamicTypeSize >= .xLarge ? nil : 3)
```

`BadgeDetailSheet` — the `ProgressView` + MMR label row uses an `HStack`. At large text sizes this will clip. Wrap in an adaptive stack:

```swift
// Use ViewThatFits or explicit VStack when text is large:
Group {
    if dynamicTypeSize >= .accessibility1 {
        VStack(alignment: .leading, spacing: 4) { mmmContent }
    } else {
        HStack { mmmContent }
    }
}
```

### 3.4 ScaledMetric for Spacing and Icon Sizes

Key spacing and interactive target sizes should scale with text size to keep touch targets reachable:

```swift
// In any view file where spacing or hit targets are hard-coded:
@ScaledMetric(relativeTo: .body) private var cardPadding: CGFloat = 14
@ScaledMetric(relativeTo: .body) private var iconButtonSize: CGFloat = 52
@ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = 18  // recent shots strip

// Usage:
.padding(cardPadding)
.frame(width: iconButtonSize, height: iconButtonSize)
.frame(width: dotSize, height: dotSize)
```

The minimum interactive touch target is 44×44 pt. The pause and stats buttons in `LiveSessionView.bottomControls` use `.frame(width: 52, height: 52)` — this is already correct but should be expressed with `@ScaledMetric` so it cannot be accidentally reduced.

### 3.5 Testing — Simulator Text Size Walkthrough

1. In Xcode Simulator, open **Settings → Accessibility → Display & Text Size → Larger Text**.
2. Set slider to **AX5** (the largest Accessibility size).
3. Walk each major screen:
   - `HomeTabView` — verify `StatCardGrid` reflows to single column; streak badge does not clip
   - `TrainTabView` — verify `DrillCard` grid reflows; descriptions do not truncate critically
   - `ProgressTabView` — verify zone efficiency rows do not overflow; chart axis labels remain readable
   - `BadgeBrowserView` — verify list rows do not clip badge names
   - `LiveSessionView` — verify FG% and timer HUD panels grow without overlapping
4. Use the **Xcode Accessibility Inspector** (Xcode → Open Developer Tool → Accessibility Inspector) with the text size slider in the **Settings** pane to test in real time without relaunching.

---

## 4. WCAG Contrast Fixes

### 4.1 Orange #FF6B35 Contrast Analysis

**Brand orange** `#FF6B35` (RGB 255, 107, 53).

Key background values used in HoopTrack:

| Background | Hex / Description | Orange contrast ratio |
|---|---|---|
| Pure black | `#000000` | **4.60:1** — passes AA normal text (≥4.5:1), passes AA large text (≥3:1) |
| Dark system background | `#1C1C1E` (UIColor.systemBackground dark) | **4.25:1** — **FAILS** AA normal text, passes large text |
| `.ultraThinMaterial` dark | ~`#2C2C2E` at full opacity | ~**3.95:1** — **FAILS** normal text |
| `Color.black.opacity(0.4)` overlay | Mixed with camera feed — variable; assume ~`#666666` equivalent | **2.4:1** — **FAILS** both thresholds |
| `.orange.opacity(0.12)` background | Nearly transparent; text over this falls back to the card background | Depends on card background |

**Conclusion:** Orange text on `ultraThinMaterial` dark mode backgrounds (used on `StatCard`, `DrillCard`, `FilterChip`, bottom HUD strip) fails WCAG AA normal text (4.5:1). Orange text directly on the camera preview (`bottomControls` in `LiveSessionView`) is context-dependent and effectively fails.

### 4.2 Adjusted Colour Values

To ensure 4.5:1 against `#1C1C1E`:

- **Required luminance ratio:** brand orange needs relative luminance of at least 0.28 (against #1C1C1E at 0.014).
- **Lightened orange for dark backgrounds:** `#FF8050` (RGB 255, 128, 80) achieves ~5.1:1 against `#1C1C1E`. This is a minor perceptual shift (+10% brightness) while remaining clearly orange.

The adjustment should not change the brand's identity. It should only apply to text-on-dark-background uses — the brand gradient (on buttons with white text) does not need to change because white text on the gradient already exceeds 4.5:1.

**Recommended implementation:**

```swift
// In Extensions.swift or a new Color+Brand.swift file:
extension Color {
    /// Brand orange — full saturation, for use on white/light backgrounds.
    static let brandOrange = Color(red: 1.0, green: 0.42, blue: 0.21)  // #FF6B35

    /// Accessible orange — lightened for text on dark backgrounds (4.5:1 on #1C1C1E).
    static let brandOrangeAccessible = Color(red: 1.0, green: 0.50, blue: 0.31)  // #FF8050
}
```

Replace the following hard-coded `.orange` or `.foregroundStyle(.orange)` calls that render as text on dark backgrounds:

- `StatCard.value` text
- `FilterChip` selected foreground
- `AgilitySessionView` timer text (`.foregroundStyle(Color.orange)`)
- `AgilitySessionView` attempt history best time foreground
- `AgilitySessionView` best time banner values
- `BadgeBrowserView` badge section foreground (SF symbol icons in headers)
- `HomeTabView.streakBadge` number
- `HomeTabView.ratingSection` overall rating number

Calls where `.orange` appears on white or near-white backgrounds (e.g., day mode `List` backgrounds, onboarding) do not require adjustment as contrast is already ≥4.5:1.

### 4.3 AccessibilityContrast Environment

SwiftUI provides the `\.accessibilityContrast` environment value which is `.increased` when the user has enabled **Increase Contrast** in Accessibility settings. Use this to selectively boost opacity for semi-transparent overlays:

```swift
@Environment(\.colorSchemeContrast) private var contrast

// Example — HUD panel backgrounds in LiveSessionView:
.background(
    .ultraThinMaterial.opacity(contrast == .increased ? 1.0 : 0.7),
    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
)

// Example — recent shots strip:
.background(
    .ultraThinMaterial.opacity(contrast == .increased ? 0.95 : 0.7),
    in: Capsule()
)
```

For foreground text in live session overlays (white text on camera feed), provide a high-contrast alternative that adds a solid background:

```swift
Text(viewModel.fgPercentString)
    .font(.system(.largeTitle, design: .rounded).weight(.black))
    .foregroundStyle(.white)
    .shadow(radius: contrast == .increased ? 0 : 4)
    .background(contrast == .increased
        ? AnyShapeStyle(Color.black.opacity(0.8))
        : AnyShapeStyle(Color.clear),
        in: RoundedRectangle(cornerRadius: 6))
    .padding(contrast == .increased ? 4 : 0)
```

---

## 5. Switch Control and Keyboard Navigation

### 5.1 Logical Focus Order

Switch Control and Full Keyboard Access navigate through interactive elements in layout order (top-to-bottom, left-to-right by default). Verify the following order is correct in each tab:

**HomeTabView:** Header → Skill Ratings ring → Radar → Shooting stats → Streak records → Weekly volume chart → Daily Mission → Last Session → Quick Start toolbar button

**TrainTabView:** Quick Start banner → Category filter chips (All, Shot, Dribble, Agility…) → Drill cards (row-major order)

**ProgressTabView:** Time range picker → FG% Trend chart → Shot heat map → Zone efficiency rows → Goals section → Manage button → Goal rows → Personal Records

**ProfileTabView → BadgeBrowserView:** Section headers → Badge rows within each section

If an element appears out of order, use `.accessibilitySortPriority(_:)` (higher value = earlier in traversal) to correct the sequence without reordering the SwiftUI view hierarchy.

### 5.2 accessibilityInputLabels for Voice Control

Voice Control (distinct from VoiceOver) allows users to speak button names to activate them. Custom views where the visible label does not match what a user would naturally say need `accessibilityInputLabels`:

```swift
// Quick Start toolbar button — user may say "Play" or "Start":
Button { } label: { Label("Quick Start", systemImage: "play.fill") }
.accessibilityInputLabels(["Quick Start", "Play", "Start session"])

// End Session long-press:
// ... existing view ...
.accessibilityInputLabels(["End Session", "End", "Stop", "Finish"])

// Make / Miss buttons in LiveSessionView:
Button { viewModel.logShot(result: .make) } label: { Label("Make", ...) }
.accessibilityInputLabels(["Make", "Score", "Good shot"])

Button { viewModel.logShot(result: .miss) } label: { Label("Miss", ...) }
.accessibilityInputLabels(["Miss", "Missed", "No good"])
```

### 5.3 Long-Press End Session — Switch Control Solution

Switch Control users cannot perform continuous press-and-hold gestures. The `DragGesture(minimumDistance: 0)` end-session pattern must have an alternative accessible action. The companion button approach described in Section 2.7 is the correct solution.

For Switch Control specifically, use `accessibilityActivate()` by implementing the `accessibilityAction` default (which Switch Control triggers via "Tap" scanning mode):

```swift
// The gesture-based view already has .accessibilityAction(named: "End Session")
// from Section 2.7. That handles both VoiceOver double-tap AND Switch Control tap action.
// No additional code needed beyond what Section 2.7 prescribes.
```

Verify the `AgilitySessionView.endSessionButton` — this view is a `ZStack` with a `DragGesture`, not a `Button`. It currently has no accessibility traits at all. The full fix:

```swift
// Wrap the ZStack in an explicit accessibility context:
endSessionButton
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("End Session")
    .accessibilityHint("Double-tap to end the agility session and save results")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
        Task { await viewModel.endSession() }
    }
```

### 5.4 Focus Groups in Modals

`PreSessionSheetView` and `BadgeDetailSheet` are presented as sheets. SwiftUI automatically scopes Switch Control focus to the front modal — no action needed. However, verify that:

- The "Cancel" and "Done" toolbar buttons are reachable as the **first** and **last** elements (they are, because `NavigationStack` toolbar items are at the top of the accessibility tree).
- The `Form` fields have appropriate labels: `TextField("Location (optional)", ...)` is self-labelling, but the `Picker("Court Type", ...)` label must be verified as present in the accessibility tree (it is, via `Form`'s implicit `LabeledContent` behaviour, but test to confirm).

---

## 6. Live Session Accessibility

### 6.1 Real-Time Shot Announcements

When the CV pipeline or manual buttons log a shot, VoiceOver users need to hear the result. Use `UIAccessibility.post(notification: .announcement, argument:)` from the `LiveSessionViewModel.logShot` path:

```swift
// In LiveSessionViewModel.logShot(result:) — after state update:
@MainActor
func logShot(result: ShotResult) {
    // ... existing logic ...
    let message: String
    switch result {
    case .make:
        message = "Make. \(shotsMade) for \(shotsAttempted). \(fgPercentString)."
    case .miss:
        message = "Miss. \(shotsMade) for \(shotsAttempted). \(fgPercentString)."
    case .pending:
        return
    }
    UIAccessibility.post(notification: .announcement, argument: message)
}
```

For dribble counts in `DribbleDrillView`, post a periodic announcement (not per-dribble — see Section 6.2):

```swift
// In DribbleSessionViewModel — on dribble count milestone:
private var lastAnnouncedDribbleCount = 0

func didDetectDribble() {
    totalDribbles += 1
    // Announce every 10 dribbles
    if totalDribbles % 10 == 0 && totalDribbles != lastAnnouncedDribbleCount {
        lastAnnouncedDribbleCount = totalDribbles
        UIAccessibility.post(
            notification: .announcement,
            argument: "\(totalDribbles) dribbles. \(String(format: "%.1f", currentBPS)) per second."
        )
    }
}
```

For `AgilitySessionView`, announce when a timer stops:

```swift
// In AgilitySessionViewModel.stopTimer():
UIAccessibility.post(
    notification: .announcement,
    argument: "Stopped. Time: \(String(format: "%.2f seconds", lastAttemptSeconds))."
)
```

### 6.2 Avoiding Announcement Spam

The CV pipeline in Phase 2 may auto-detect shots at a high rate during contested plays or false positives. Implement a debounce guard in the announcement path:

```swift
// In LiveSessionViewModel:
private var lastAnnouncementDate: Date = .distantPast
private let announcementCooldown: TimeInterval = 2.0  // seconds

private func postShotAnnouncement(_ message: String) {
    let now = Date()
    guard now.timeIntervalSince(lastAnnouncementDate) >= announcementCooldown else { return }
    lastAnnouncementDate = now
    UIAccessibility.post(notification: .announcement, argument: message)
}
```

Use `postShotAnnouncement(_:)` instead of direct `UIAccessibility.post` calls in `logShot`.

Additionally, the make/miss flash animations fire `withAnimation` and a `DispatchQueue.main.asyncAfter` callback. These are visual-only and already suppressed from VoiceOver (Section 2.3) — the announcement handles the audio signal.

### 6.3 Camera View Alternative for VoiceOver Users

A blind user cannot perceive the camera preview at all. When VoiceOver is active, the live session should surface a text summary panel that reads the current session state instead of relying on the visual HUD:

```swift
// In LiveSessionView.body — add alongside HUD:
if UIAccessibility.isVoiceOverRunning {
    sessionStateSummaryBanner
        .padding()
}

private var sessionStateSummaryBanner: some View {
    VStack(alignment: .leading, spacing: 6) {
        Text("Live Session")
            .font(.headline)
        Text(sessionStateSummaryString)
            .font(.body)
    }
    .padding(14)
    .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
    .foregroundStyle(.white)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(sessionStateSummaryString)
    .accessibilityLiveRegion(.polite)  // re-reads when content changes
}

private var sessionStateSummaryString: String {
    let status = viewModel.isPaused ? "Paused" : "Running"
    return "Status: \(status). Time: \(viewModel.elapsedFormatted). \(viewModel.fgPercentString) on \(viewModel.shotsAttempted) shots."
}
```

The `.accessibilityLiveRegion(.polite)` modifier causes VoiceOver to re-announce the view's content whenever it changes, without interrupting an in-progress announcement. Use `.assertive` only for critical state changes (e.g., session ending).

---

## 7. Reduced Motion

### 7.1 Reading the Environment

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

This returns `true` when the user has enabled **Reduce Motion** in iOS Accessibility Settings.

### 7.2 ShimmerModifier

The `ShimmerModifier` uses `TimelineView(.animation)` to drive a continuous gradient sweep. When reduce motion is active, replace the animated shimmer with a static placeholder overlay:

```swift
// ShimmerModifier.swift — updated:
struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive {
            content
                .redacted(reason: .placeholder)
                .overlay(reduceMotion ? AnyView(staticPlaceholderOverlay) : AnyView(ShimmerOverlay()))
                .allowsHitTesting(false)
        } else {
            content
        }
    }

    private var staticPlaceholderOverlay: some View {
        Color.white.opacity(0.08)
    }
}
```

### 7.3 AgilitySessionView Pulse Animation

The trigger cue circle uses `.animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: isRunning)`. When reduce motion is active, replace with an instant state change (no animation):

```swift
// triggerCue — updated scaleEffect:
Circle()
    .strokeBorder(isRunning ? Color.orange : Color.white.opacity(0.4), lineWidth: 3)
    .frame(width: 80, height: 80)
    .scaleEffect(isRunning ? (reduceMotion ? 1.0 : 1.1) : 1.0)
    .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
        value: isRunning
    )
```

### 7.4 Make/Miss Flash Animations (LiveSessionView)

The `withAnimation(.easeOut(duration: 0.3))` block in `onChange(of: viewModel.lastShotResult)` drives the `showMakeAnimation` and `showMissAnimation` state. With reduce motion, skip the animation and rely solely on the VoiceOver announcement:

```swift
.onChange(of: viewModel.lastShotResult) { _, result in
    guard let result else { return }
    if reduceMotion {
        showMakeAnimation = result == .make
        showMissAnimation = result == .miss
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            showMakeAnimation = false
            showMissAnimation = false
        }
    } else {
        withAnimation(.easeOut(duration: 0.3)) {
            showMakeAnimation = result == .make
            showMissAnimation = result == .miss
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            showMakeAnimation = false
            showMissAnimation = false
        }
    }
}
```

### 7.5 Badge Unlock Animations

`BadgesUpdatedSection` and any badge unlock celebration view (present in `SessionSummaryView`) likely use `withAnimation` for scale effects or confetti. Apply the same pattern:

```swift
withAnimation(reduceMotion ? .none : .spring(response: 0.4, dampingFraction: 0.6)) {
    badgeRevealState = .revealed
}
```

### 7.6 AnimatedCounterModifier

The `AnimatedCounterModifier` drives a number interpolation from 0 to target. With reduce motion, skip the animation and show the final value immediately:

```swift
// At the call site (e.g., SessionSummaryView):
@State private var animatedFG: Double = 0
@Environment(\.accessibilityReduceMotion) private var reduceMotion

EmptyView()
    .modifier(AnimatedCounterModifier(currentValue: animatedFG, format: "%.0f%%"))
    .animation(reduceMotion ? .none : .easeOut(duration: 0.6), value: animatedFG)
    .onAppear {
        if reduceMotion {
            animatedFG = session.fgPercent   // instant
        } else {
            animatedFG = session.fgPercent   // animated by the .animation modifier
        }
    }
```

### 7.7 Overall Inventory of withAnimation Calls Needing Guards

Run the following to find all animation sites that need a reduce-motion guard:

```
grep -rn "withAnimation\|\.animation(" HoopTrack/HoopTrack --include="*.swift"
```

Key locations to address beyond the above:

- `HomeTabView` — overall rating ring `Circle().trim(from: 0, to:)` animation on load
- `SkillRadarView` — Phase 5 planned animation between old/new ratings
- `ProfileTabView` — any badge earned celebration effect
- `DribbleDrillView` — AR target placement (RealityKit — use `ModelEntity.stopAllAnimations()` path if needed)

---

## 8. Testing Plan

### 8.1 VoiceOver Testing Script — Major User Flows

**Flow 1: Launch → Home → view skill ratings**

1. Enable VoiceOver (triple-click Side Button, or Settings → Accessibility → VoiceOver).
2. Swipe right through Home tab elements. Verify: greeting text is read, streak badge announces "N day streak", skill ratings section reads overall rating with percentage, radar chart has a summary label, shooting stat cards read their values with units.
3. Verify: no unlabelled interactive elements (VoiceOver should not say "button" with no label).

**Flow 2: TrainTabView → select a drill → configure → launch**

1. Navigate to Train tab. Verify tab label is announced.
2. Swipe through category filter chips. Verify: each announces label and selected/deselected state.
3. Tap (double-tap in VoiceOver) a DrillCard. Verify: card label includes drill name, type, and short description.
4. In `PreSessionSheetView`, verify: drill name, court type picker, location field, and Start Session button are all reachable and labelled.
5. After session starts, verify: FG% counter, timer, make/miss buttons, pause button, and end session button are all reachable and correctly labelled.

**Flow 3: LiveSessionView → log shot → hear announcement → end session**

1. In live session, double-tap "Make". Verify: announcement "Make. 1 for 1. 100%" is spoken.
2. Double-tap "Miss". Verify: announcement "Miss. 1 for 2. 50%".
3. Navigate to End Session button. Verify: label "End Session", hint says double-tap ends immediately.
4. Double-tap End Session. Verify: session ends, summary screen appears.
5. In session summary, verify: FG% hero number, stat cards, and badge changes are all announced.

**Flow 4: ProgressTabView → shot chart → zone efficiency**

1. Navigate to Progress tab. Swipe to Shot Heat Map section. Verify: section is read as a single element with zone summary.
2. Swipe to Zone Efficiency. Verify: each zone row announces zone name, percentage, makes, and attempts.
3. Swipe to FG% Trend chart. Verify: chart summary is read, individual data points can be navigated with swipe.

**Flow 5: ProfileTabView → BadgeBrowserView → badge detail**

1. Navigate to Profile tab, then Badge Browser. Verify: earned count in title is read.
2. Swipe through badge rows. Verify: earned badges announce name, rank, and MMR. Locked badges announce "Locked".
3. Double-tap an earned badge row. Verify: detail sheet announces badge name, skill dimension, rank, and progress toward next rank.

### 8.2 Xcode Accessibility Inspector Usage

1. Open Xcode → Open Developer Tool → Accessibility Inspector.
2. Select the iOS Simulator as the target.
3. **Audit tab:** Press "Run Audit" to automatically flag: missing labels, insufficient contrast, small touch targets, and elements that may be hard to navigate. Address all warnings before App Store submission.
4. **Inspection tab:** Click the crosshair and hover over elements in the Simulator to see the full accessibility hierarchy (label, value, traits, hint) without enabling VoiceOver.
5. **Settings panel:** Adjust text size, reduce motion, increase contrast, and invert colours to test all accessibility modes without leaving the Inspector.

Focus the audit on: `LiveSessionView`, `CourtMapView`, `SkillRadarView`, `BadgeBrowserView`, and all three session views (agility, dribble, live shot).

### 8.3 Automated Accessibility Audit with XCUITest

Add a UI test target (`HoopTrackUITests`) with an accessibility audit helper:

```swift
// HoopTrackUITests/AccessibilityAuditTests.swift
import XCTest

final class AccessibilityAuditTests: XCTestCase {

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launch()
    }

    // MARK: - Home Tab Audit

    func testHomeTabAccessibility() throws {
        // iOS 17+ accessibility audit API
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription]) { issue in
                // Allow known exceptions during build-up phase:
                if issue.element?.label == "Court Heat Map" { return true }  // visual-only canvas
                return false  // fail all others
            }
        }
    }

    // MARK: - Train Tab Audit

    func testTrainTabAccessibility() throws {
        app.tabBars.buttons["Train"].tap()
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: [.contrast, .hitRegion, .sufficientElementDescription])
        }
    }

    // MARK: - Progress Tab Audit

    func testProgressTabAccessibility() throws {
        app.tabBars.buttons["Progress"].tap()
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription])
        }
    }

    // MARK: - Profile Tab Audit

    func testProfileTabAccessibility() throws {
        app.tabBars.buttons["Profile"].tap()
        if #available(iOS 17.0, *) {
            try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription])
        }
    }

    // MARK: - VoiceOver Element Reachability

    func testAllInteractiveElementsHaveLabels() {
        let allButtons = app.buttons.allElementsBoundByIndex
        for button in allButtons {
            XCTAssertFalse(
                button.label.isEmpty,
                "Button with identifier '\(button.identifier)' has no accessibility label"
            )
        }
    }
}
```

`performAccessibilityAudit(for:issueHandler:)` is available on iOS 17+. For iOS 16 targets, the Xcode Accessibility Inspector manual audit covers the same ground.

Run these tests as part of the CI pull request gate. Add to the existing test scheme so failures block merges.

---

## Implementation Priority Order

Given the compliance gap and App Store risk, address issues in this sequence:

1. **End Session button accessibility** (Section 2.7, 5.3) — highest risk; gesture-only interaction fails both VoiceOver and Switch Control. One-day fix, blocks no other work.
2. **VoiceOver labels on interactive elements** (Section 2.1–2.5, 2.6) — systematic pass through all views adding `accessibilityLabel`/`accessibilityHint`. Can be done in one sprint alongside normal feature work.
3. **Dynamic Type font audit** (Section 3.1–3.3) — replace all `font(.system(size: N))` calls. Medium effort, no risk to existing layout at default text sizes.
4. **Reduced Motion guards** (Section 7) — add `@Environment(\.accessibilityReduceMotion)` guards to all `withAnimation` paths. Low effort, touches many files.
5. **WCAG contrast adjustments** (Section 4.2–4.3) — introduce `brandOrangeAccessible` colour and swap in text-on-dark contexts. Low visual impact, high compliance value.
6. **Live session announcements** (Section 6) — `UIAccessibility.post` integration into `LiveSessionViewModel`. Requires care around debouncing; one focused implementation session.
7. **Automated tests** (Section 8.3) — add to CI once the above are in place so regressions are caught.

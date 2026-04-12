# Phase 5B — Plan C: Session Summary Badge Integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thread `[BadgeTierChange]` from `SessionResult` through to the session summary views so users see which badges changed rank after each session.

**Architecture:** `SessionSummaryView` and `DribbleSessionSummaryView` gain a `badgeChanges: [BadgeTierChange] = []` parameter with a default empty value — existing call sites (history navigation) work unchanged. The live session views pass `viewModel.sessionResult?.badgeChanges ?? []` at the `fullScreenCover` call site. `BadgesUpdatedSection` (from Plan B) is appended at the bottom of each summary view's scroll content.

**Tech Stack:** SwiftUI

**Prerequisite:** Plan B complete (`BadgesUpdatedSection` exists)

**Build command (run from worktree root):**
```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

### Task 1: Update `SessionSummaryView` — add `badgeChanges` parameter

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Train/SessionSummaryView.swift`

- [ ] **Step 1: Add the parameter to the struct**

Find:
```swift
struct SessionSummaryView: View {

    let session: TrainingSession
    let onDone: () -> Void
```

Replace with:
```swift
struct SessionSummaryView: View {

    let session: TrainingSession
    var badgeChanges: [BadgeTierChange] = []
    let onDone: () -> Void
```

- [ ] **Step 2: Append `BadgesUpdatedSection` inside the ScrollView's VStack, after `shotListSection`**

Find the line:
```swift
                    // MARK: Shot-by-shot review
                    shotListSection
```

Immediately after the `shotListSection` usage (before the closing `}` of the VStack), add:

```swift
                    // MARK: Badges Updated (Phase 5B)
                    BadgesUpdatedSection(changes: badgeChanges)
```

- [ ] **Step 3: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Train/SessionSummaryView.swift
git commit -m "feat: add badgeChanges param to SessionSummaryView"
```

---

### Task 2: Update `LiveSessionView` — pass badge changes to summary

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift`

- [ ] **Step 1: Update the `fullScreenCover` call to pass `sessionResult?.badgeChanges`**

Find:
```swift
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let session = viewModel.session {
                SessionSummaryView(session: session) {
                    viewModel.isFinished = false
                    onFinish()
                }
            }
        }
```

Replace with:
```swift
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let session = viewModel.session {
                SessionSummaryView(
                    session:      session,
                    badgeChanges: viewModel.sessionResult?.badgeChanges ?? []
                ) {
                    viewModel.isFinished = false
                    onFinish()
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
git add HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift
git commit -m "feat: pass sessionResult.badgeChanges to SessionSummaryView"
```

---

### Task 3: Update `DribbleSessionSummaryView` — add `badgeChanges` parameter

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Train/DribbleSessionSummaryView.swift`

- [ ] **Step 1: Add the parameter to the struct**

Find:
```swift
struct DribbleSessionSummaryView: View {

    let session: TrainingSession
    let onDismiss: () -> Void
```

Replace with:
```swift
struct DribbleSessionSummaryView: View {

    let session: TrainingSession
    var badgeChanges: [BadgeTierChange] = []
    let onDismiss: () -> Void
```

- [ ] **Step 2: Append `BadgesUpdatedSection` inside the ScrollView's VStack, after `handBalanceBar`**

Find:
```swift
                    drillHeader
                    statsGrid
                    handBalanceBar
```

After `handBalanceBar`, add:

```swift
                    // MARK: Badges Updated (Phase 5B)
                    BadgesUpdatedSection(changes: badgeChanges)
```

- [ ] **Step 3: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Train/DribbleSessionSummaryView.swift
git commit -m "feat: add badgeChanges param to DribbleSessionSummaryView"
```

---

### Task 4: Update `DribbleDrillView` — pass badge changes to dribble summary

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Train/DribbleDrillView.swift`

- [ ] **Step 1: Update the `fullScreenCover` call to pass `sessionResult?.badgeChanges`**

Find:
```swift
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let session = viewModel.session {
                DribbleSessionSummaryView(session: session) {
                    viewModel.isFinished = false
                    onFinish()
                }
            }
        }
```

Replace with:
```swift
        .fullScreenCover(isPresented: $viewModel.isFinished) {
            if let session = viewModel.session {
                DribbleSessionSummaryView(
                    session:      session,
                    badgeChanges: viewModel.sessionResult?.badgeChanges ?? []
                ) {
                    viewModel.isFinished = false
                    onFinish()
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
git add HoopTrack/HoopTrack/Views/Train/DribbleDrillView.swift
git commit -m "feat: pass sessionResult.badgeChanges to DribbleSessionSummaryView"
```

# Phase 5B — Plan A: Model & UI Extensions

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the three small extensions that all other Phase 5B plans depend on: `BadgeID.skillDimension` + `BadgeID.scoringDescription`, `BadgeTier.color`, and `SkillDimension.suggestedMetrics`.

**Architecture:** `BadgeID` and `BadgeTier` model extensions are in the Models group. `SkillDimension.suggestedMetrics` is UI-only (imports SwiftUI indirectly through GoalMetric) so it lives in a UI extensions file in Views/Components. All three are pure computed properties with no side effects.

**Tech Stack:** Swift, SwiftUI, Foundation

**Prerequisite:** Phase 5A complete (branch `feat/phase5b-ui-layer`)

**Build command (run from worktree root):**
```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

---

### Task 1: Add `skillDimension` and `scoringDescription` to `BadgeID`

**Files:**
- Modify: `HoopTrack/HoopTrack/Models/BadgeID.swift`

- [ ] **Step 1: Add the two computed vars at the bottom of the file, after the `displayName` computed property**

The full enum already exists. Append this extension at the bottom of `BadgeID.swift`:

```swift
extension BadgeID {
    /// The skill dimension this badge belongs to — single source of truth for badge grouping.
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

    /// One-line description of what this badge measures — shown when badge is not yet earned.
    var scoringDescription: String {
        switch self {
        case .deadeye:          return "Score high based on your field goal percentage."
        case .sniper:           return "Reward low release-angle standard deviation — consistency wins."
        case .quickTrigger:     return "Measures how fast you release the ball after catching."
        case .beyondTheArc:     return "Track your effectiveness from beyond the three-point line."
        case .charityStripe:    return "Convert free throws at a high rate (10+ attempts required)."
        case .threeLevelScorer: return "Demonstrate scoring from paint, mid-range, and three-point range."
        case .hotHand:          return "Captures your longest consecutive make streak in a session."
        case .handles:          return "Average dribbles per second across your drill session."
        case .ambidextrous:     return "How evenly you distribute dribbles between both hands."
        case .comboKing:        return "Ratio of dribble combo moves to total dribbles."
        case .floorGeneral:     return "Sustained dribble speed — how close avg BPS is to your peak."
        case .ballWizard:       return "Career total dribbles accumulated across all sessions."
        case .posterizer:       return "Your average vertical jump height per agility session."
        case .lightning:        return "Your best shuttle run time — lower is better."
        case .explosive:        return "Overall athleticism rating combining jump and agility scores."
        case .highFlyer:        return "Your all-time personal record vertical jump height."
        case .automatic:        return "How consistent your FG% is across recent sessions."
        case .metronome:        return "How consistent your release angle is across 10+ sessions."
        case .iceVeins:         return "Career free throw percentage with at least 50 attempts."
        case .reliable:         return "Consecutive sessions where you shot at least 40% from the field."
        case .ironMan:          return "Your longest consecutive daily training streak."
        case .gymRat:           return "Sessions completed in the last 7 days."
        case .workhorse:        return "Career total shots attempted across all sessions."
        case .specialist:       return "Most sessions completed in any single drill type."
        case .completePlayer:   return "Your weakest skill dimension score — build everything up."
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
git add HoopTrack/HoopTrack/Models/BadgeID.swift
git commit -m "feat: add skillDimension and scoringDescription to BadgeID"
```

---

### Task 2: Create `BadgeTier+UI.swift`

**Files:**
- Create: `HoopTrack/HoopTrack/Models/BadgeTier+UI.swift`

- [ ] **Step 1: Create the file**

```swift
// BadgeTier+UI.swift
// UI extension kept separate to avoid importing SwiftUI in the core model layer.
import SwiftUI

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

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/BadgeTier+UI.swift
git commit -m "feat: add BadgeTier.color extension for badge UI"
```

---

### Task 3: Create `SkillDimensionExtensions.swift`

**Files:**
- Create: `HoopTrack/HoopTrack/Views/Components/SkillDimensionExtensions.swift`

- [ ] **Step 1: Create the file**

```swift
// SkillDimensionExtensions.swift
// UI-only extension — maps SkillDimension to GoalMetric suggestions.
import Foundation

extension SkillDimension {
    /// Ordered list of GoalMetric values suggested when creating a goal for this dimension.
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

- [ ] **Step 2: Build to verify**

```
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 17 Pro' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Components/SkillDimensionExtensions.swift
git commit -m "feat: add SkillDimension.suggestedMetrics for goal creation"
```

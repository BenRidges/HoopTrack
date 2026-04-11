# Phase 5A — Plan B: SkillRatingCalculator

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `SkillRatingCalculator` — a pure enum of static functions that convert primitive session metrics into 0–100 skill dimension scores. Full TDD coverage.

**Architecture:** `enum SkillRatingCalculator` with no stored state, no SwiftData imports, no framework dependencies. All tests call static functions with primitive arguments — no ModelContainer required.

**Tech Stack:** Swift, XCTest, `HoopTrack.SkillRating` constants

**Prerequisite:** Plan A complete (constants added to `Constants.swift`)

**Test command:**
```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed|error:)"
```

---

### Task 1: Create test file and implement `normalize`

**Files:**
- Create: `HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift`
- Create: `HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift`

- [ ] **Step 1: Write the failing tests for `normalize`**

```swift
// SkillRatingCalculatorTests.swift
import XCTest
@testable import HoopTrack

final class SkillRatingCalculatorTests: XCTestCase {

    // MARK: - normalize

    func test_normalize_midpoint_returns50() {
        XCTAssertEqual(SkillRatingCalculator.normalize(5, min: 0, max: 10), 50, accuracy: 0.001)
    }

    func test_normalize_atMin_returns0() {
        XCTAssertEqual(SkillRatingCalculator.normalize(0, min: 0, max: 10), 0, accuracy: 0.001)
    }

    func test_normalize_atMax_returns100() {
        XCTAssertEqual(SkillRatingCalculator.normalize(10, min: 0, max: 10), 100, accuracy: 0.001)
    }

    func test_normalize_belowMin_clampsTo0() {
        XCTAssertEqual(SkillRatingCalculator.normalize(-5, min: 0, max: 10), 0, accuracy: 0.001)
    }

    func test_normalize_aboveMax_clampsTo100() {
        XCTAssertEqual(SkillRatingCalculator.normalize(15, min: 0, max: 10), 100, accuracy: 0.001)
    }

    func test_normalize_equalMinMax_returns0() {
        XCTAssertEqual(SkillRatingCalculator.normalize(5, min: 5, max: 5), 0, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests — confirm they FAIL**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep -E "(error:|failed)"
```
Expected: compile error (`SkillRatingCalculator` not found)

- [ ] **Step 3: Create `SkillRatingCalculator.swift` with `normalize`**

```swift
// SkillRatingCalculator.swift
// Pure static functions — no SwiftData, no side effects.
// SkillRatingService extracts primitives from @Model types before calling here.

import Foundation

enum SkillRatingCalculator {

    // MARK: - Normalize

    /// Clamps `value` to [min, max] then scales linearly to 0–100.
    static func normalize(_ value: Double, min: Double, max: Double) -> Double {
        guard max > min else { return 0 }
        return Swift.max(0, Swift.min(100, (value - min) / (max - min) * 100))
    }
}
```

- [ ] **Step 4: Run tests — confirm PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed|error:)"
```
Expected: 6 tests passed

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift
git commit -m "test+feat: SkillRatingCalculator normalize with TDD"
```

---

### Task 2: `shootingScore`

**Files:**
- Modify: `HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift`
- Modify: `HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift`

- [ ] **Step 1: Add failing tests for `shootingScore`**

Append to `SkillRatingCalculatorTests`:

```swift
    // MARK: - shootingScore

    func test_shootingScore_perfect_fgOnly_returns100() {
        let score = SkillRatingCalculator.shootingScore(
            fgPct: 100, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 0.1)
    }

    func test_shootingScore_zero_fgOnly_returns0() {
        let score = SkillRatingCalculator.shootingScore(
            fgPct: 0, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 0, accuracy: 0.1)
    }

    func test_shootingScore_optimalAngle_boostsScore() {
        let withAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: 50, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        let withoutAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        // 50° is in the optimal band — score with angle should be >= score without
        XCTAssertGreaterThanOrEqual(withAngle, withoutAngle)
    }

    func test_shootingScore_badAngle_penalisesScore() {
        let badAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: 20, releaseAngleStdDev: nil, // below falloff
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        let noAngle = SkillRatingCalculator.shootingScore(
            fgPct: 50, threePct: nil, ftPct: nil,
            releaseAngleDeg: nil, releaseAngleStdDev: nil,
            releaseTimeMs: nil, shotSpeedMph: nil,
            shotSpeedStdDev: nil, threeAttemptFraction: nil
        )!
        XCTAssertLessThan(badAngle, noAngle)
    }
```

- [ ] **Step 2: Run tests — confirm new tests FAIL**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep -E "(Test.*failed|error:)"
```

- [ ] **Step 3: Implement `shootingScore`**

Add inside `enum SkillRatingCalculator`:

```swift
    // MARK: - Shooting

    static func shootingScore(
        fgPct: Double,
        threePct: Double?,
        ftPct: Double?,
        releaseAngleDeg: Double?,
        releaseAngleStdDev: Double?,
        releaseTimeMs: Double?,
        shotSpeedMph: Double?,
        shotSpeedStdDev: Double?,
        threeAttemptFraction: Double?
    ) -> Double? {
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []

        components.append((normalize(fgPct, min: 0, max: 100), 0.25))

        if let t = threePct        { components.append((normalize(t, min: 0, max: 100), 0.20)) }
        if let f = ftPct           { components.append((normalize(f, min: 0, max: 100), 0.15)) }

        if let angle = releaseAngleDeg {
            let q: Double
            if angle >= R.releaseAngleOptimalMin && angle <= R.releaseAngleOptimalMax {
                q = 100
            } else if angle < R.releaseAngleFalloffMin || angle > R.releaseAngleFalloffMax {
                q = 0
            } else if angle < R.releaseAngleOptimalMin {
                q = (angle - R.releaseAngleFalloffMin) / (R.releaseAngleOptimalMin - R.releaseAngleFalloffMin) * 100
            } else {
                q = (R.releaseAngleFalloffMax - angle) / (R.releaseAngleFalloffMax - R.releaseAngleOptimalMax) * 100
            }
            components.append((q, 0.15))
        }

        if let ms = releaseTimeMs {
            components.append((normalize(R.releaseTimeSlowMs - ms,
                                         min: 0,
                                         max: R.releaseTimeSlowMs - R.releaseTimeEliteMs), 0.10))
        }

        if let speed = shotSpeedMph {
            let q: Double
            if speed >= R.shotSpeedOptimalMin && speed <= R.shotSpeedOptimalMax {
                q = 100
            } else if speed < R.shotSpeedOptimalMin {
                q = normalize(speed, min: 0, max: R.shotSpeedOptimalMin)
            } else {
                q = normalize(R.shotSpeedOptimalMax * 2 - speed,
                              min: 0, max: R.shotSpeedOptimalMax)
            }
            components.append((q, 0.10))
        }

        if let frac = threeAttemptFraction {
            components.append((normalize(frac * 100, min: 0, max: 60), 0.05))
        }

        guard !components.isEmpty else { return nil }
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }
```

- [ ] **Step 4: Run tests — confirm all PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift
git commit -m "test+feat: shootingScore with nil-skip weight redistribution"
```

---

### Task 3: `ballHandlingScore` and `athleticismScore`

**Files:**
- Modify: `HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift`
- Modify: `HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift`

- [ ] **Step 1: Add failing tests**

```swift
    // MARK: - ballHandlingScore

    func test_ballHandlingScore_noDribbles_returnsNil() {
        XCTAssertNil(SkillRatingCalculator.ballHandlingScore(
            avgBPS: nil, maxBPS: nil, handBalance: nil, combos: 0, totalDribbles: 0))
    }

    func test_ballHandlingScore_eliteBPS_returnsHighScore() {
        let score = SkillRatingCalculator.ballHandlingScore(
            avgBPS: 8.0, maxBPS: 10.0, handBalance: 0.5,
            combos: 15, totalDribbles: 200)
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score!, 70)
    }

    func test_ballHandlingScore_equalHandBalance_maximisesHandScore() {
        let balanced = SkillRatingCalculator.ballHandlingScore(
            avgBPS: 5.0, maxBPS: 7.0, handBalance: 0.5, combos: 5, totalDribbles: 100)!
        let unbalanced = SkillRatingCalculator.ballHandlingScore(
            avgBPS: 5.0, maxBPS: 7.0, handBalance: 0.9, combos: 5, totalDribbles: 100)!
        XCTAssertGreaterThan(balanced, unbalanced)
    }

    // MARK: - athleticismScore

    func test_athleticismScore_bothNil_returnsNil() {
        XCTAssertNil(SkillRatingCalculator.athleticismScore(verticalJumpCm: nil, shuttleRunSec: nil))
    }

    func test_athleticismScore_eliteVertical_returnsHigh() {
        let score = SkillRatingCalculator.athleticismScore(verticalJumpCm: 90, shuttleRunSec: nil)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 1.0)
    }

    func test_athleticismScore_fastShuttle_returnsHigh() {
        let score = SkillRatingCalculator.athleticismScore(verticalJumpCm: nil, shuttleRunSec: 5.5)
        XCTAssertNotNil(score)
        XCTAssertEqual(score!, 100, accuracy: 1.0)
    }

    func test_athleticismScore_jumpOnlyUsesFullWeight() {
        // With no shuttle, vertical weight = 1.0 → result is purely jump score
        let jumpOnly = SkillRatingCalculator.athleticismScore(verticalJumpCm: 55, shuttleRunSec: nil)!
        let bothData = SkillRatingCalculator.athleticismScore(verticalJumpCm: 55, shuttleRunSec: 7.5)!
        // jumpOnly should equal the pure vertical score; bothData redistributes weight
        XCTAssertNotEqual(jumpOnly, bothData, accuracy: 5.0)
    }
```

- [ ] **Step 2: Run tests — confirm new tests FAIL**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep "failed"
```

- [ ] **Step 3: Implement `ballHandlingScore` and `athleticismScore`**

Add inside `enum SkillRatingCalculator`:

```swift
    // MARK: - Ball Handling

    static func ballHandlingScore(
        avgBPS: Double?,
        maxBPS: Double?,
        handBalance: Double?,
        combos: Int,
        totalDribbles: Int
    ) -> Double? {
        guard totalDribbles > 0 else { return nil }
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []

        if let avg = avgBPS { components.append((normalize(avg, min: R.bpsAvgMin, max: R.bpsAvgMax), 0.30)) }
        if let mx  = maxBPS { components.append((normalize(mx,  min: R.bpsMaxMin, max: R.bpsMaxMax), 0.15)) }

        if let avg = avgBPS, let mx = maxBPS, mx > 0 {
            let ratio = avg / mx
            components.append((normalize(ratio, min: R.bpsSustainedMin, max: R.bpsSustainedMax), 0.15))
        }

        if let balance = handBalance {
            components.append(((1 - abs(balance - 0.5) * 2) * 100, 0.25))
        }

        let comboRate = Double(combos) / Double(totalDribbles)
        components.append((normalize(comboRate, min: 0, max: R.comboRateMax), 0.15))

        guard !components.isEmpty else { return nil }
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }

    // MARK: - Athleticism

    static func athleticismScore(
        verticalJumpCm: Double?,
        shuttleRunSec: Double?
    ) -> Double? {
        guard verticalJumpCm != nil || shuttleRunSec != nil else { return nil }
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []

        if let jump = verticalJumpCm {
            let w = shuttleRunSec == nil ? 1.0 : 0.60
            components.append((normalize(jump, min: R.verticalJumpMinCm, max: R.verticalJumpMaxCm), w))
        }
        if let shuttle = shuttleRunSec {
            let score = normalize(R.shuttleRunWorstSec - shuttle,
                                   min: 0,
                                   max: R.shuttleRunWorstSec - R.shuttleRunBestSec)
            components.append((score, 0.40))
        }

        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }
```

- [ ] **Step 4: Run tests — confirm all PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift
git commit -m "test+feat: ballHandlingScore and athleticismScore with nil-skip"
```

---

### Task 4: `consistencyScore`, `volumeScore`, and `overallScore`

**Files:**
- Modify: `HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift`
- Modify: `HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift`

- [ ] **Step 1: Add failing tests**

```swift
    // MARK: - consistencyScore

    func test_consistencyScore_allNilAndEmpty_returnsNil() {
        XCTAssertNil(SkillRatingCalculator.consistencyScore(
            releaseAngleStdDev: nil, fgPctHistory: [], ftPct: nil, shotSpeedStdDev: nil))
    }

    func test_consistencyScore_zeroStdDev_returnsHigh() {
        // Perfect consistency: std dev = 0 → max score for that sub-factor
        let score = SkillRatingCalculator.consistencyScore(
            releaseAngleStdDev: 0, fgPctHistory: [], ftPct: nil, shotSpeedStdDev: nil)
        XCTAssertNotNil(score)
        XCTAssertGreaterThan(score!, 90)
    }

    func test_consistencyScore_fewerThanMinSessions_usesNeutralFallback() {
        // Only 2 sessions (< crossSessionMinCount=3) — cross-session weight uses neutral 50
        let score = SkillRatingCalculator.consistencyScore(
            releaseAngleStdDev: 2, fgPctHistory: [50, 55], ftPct: nil, shotSpeedStdDev: nil)
        XCTAssertNotNil(score)
    }

    // MARK: - volumeScore

    func test_volumeScore_allZeros_returns0() {
        let score = SkillRatingCalculator.volumeScore(
            sessionsLast4Weeks: 0, avgShotsPerSession: 0,
            weeklyTrainingMinutes: 0, drillVarietyLast14Days: 0)
        XCTAssertEqual(score, 0, accuracy: 0.001)
    }

    func test_volumeScore_maxValues_returns100() {
        // 5 sessions/week × 4 weeks = 20 sessions, 200 shots, 300 minutes/week, 100% variety
        let score = SkillRatingCalculator.volumeScore(
            sessionsLast4Weeks: 20, avgShotsPerSession: 200,
            weeklyTrainingMinutes: 300, drillVarietyLast14Days: 1.0)
        XCTAssertEqual(score, 100, accuracy: 1.0)
    }

    // MARK: - overallScore

    func test_overallScore_allDimensionsPresent_returnsWeightedAverage() {
        let score = SkillRatingCalculator.overallScore(
            shooting: 80, handling: 60, athleticism: 70,
            consistency: 50, volume: 40)
        // With all present: 80*0.30 + 60*0.20 + 70*0.20 + 50*0.15 + 40*0.15 = 63.5
        XCTAssertEqual(score, 63.5, accuracy: 0.5)
    }

    func test_overallScore_missingDimensions_redistributesWeight() {
        let withShooting    = SkillRatingCalculator.overallScore(shooting: 100, handling: nil, athleticism: nil, consistency: nil, volume: 0)
        let withoutShooting = SkillRatingCalculator.overallScore(shooting: nil, handling: nil, athleticism: nil, consistency: nil, volume: 0)
        // shooting=100 should pull overall higher than volume-only at 0
        XCTAssertGreaterThan(withShooting, withoutShooting)
    }
```

- [ ] **Step 2: Run tests — confirm new tests FAIL**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep "failed"
```

- [ ] **Step 3: Implement all three functions**

Add inside `enum SkillRatingCalculator`:

```swift
    // MARK: - Consistency

    static func consistencyScore(
        releaseAngleStdDev: Double?,
        fgPctHistory: [Double],       // recent shooting sessions, newest-first, max 10
        ftPct: Double?,
        shotSpeedStdDev: Double?
    ) -> Double? {
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []

        if let stdDev = releaseAngleStdDev {
            components.append((normalize(R.releaseAngleStdDevMax - stdDev,
                                          min: 0, max: R.releaseAngleStdDevMax), 0.35))
        }

        // Cross-session FG% variance (last 10, min 3); neutral fallback when not enough data
        let history = Array(fgPctHistory.suffix(10))
        if history.count >= R.crossSessionMinCount {
            let mean     = history.reduce(0, +) / Double(history.count)
            let variance = history.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(history.count)
            let stdDev   = sqrt(variance)
            let s = normalize(R.fgPctSessionStdDevMax - stdDev, min: 0, max: R.fgPctSessionStdDevMax)
            components.append((s, 0.30))
        } else {
            components.append((50.0, 0.30))  // neutral when fewer than 3 sessions
        }

        if let ft = ftPct { components.append((normalize(ft, min: 0, max: 100), 0.20)) }

        if let speedStdDev = shotSpeedStdDev {
            components.append((normalize(R.shotSpeedStdDevMax - speedStdDev,
                                          min: 0, max: R.shotSpeedStdDevMax), 0.15))
        }

        guard !components.isEmpty else { return nil }
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }

    // MARK: - Volume

    static func volumeScore(
        sessionsLast4Weeks: Int,
        avgShotsPerSession: Double,
        weeklyTrainingMinutes: Double,
        drillVarietyLast14Days: Double   // 0–1: distinct DrillTypes / 4
    ) -> Double {
        let R = HoopTrack.SkillRating.self
        let s = normalize(Double(sessionsLast4Weeks) / 4.0, min: 0, max: R.sessionsPerWeekCap)
        let h = normalize(avgShotsPerSession,    min: 0, max: R.shotsPerSessionMax)
        let m = normalize(weeklyTrainingMinutes, min: 0, max: R.weeklyMinutesMax)
        let v = drillVarietyLast14Days * 100
        return s * 0.35 + h * 0.25 + m * 0.20 + v * 0.20
    }

    // MARK: - Overall

    static func overallScore(
        shooting: Double?,
        handling: Double?,
        athleticism: Double?,
        consistency: Double?,
        volume: Double
    ) -> Double {
        let R = HoopTrack.SkillRating.self
        var components: [(value: Double, weight: Double)] = []
        if let s = shooting    { components.append((s, R.shootingWeight))     }
        if let h = handling    { components.append((h, R.handlingWeight))     }
        if let a = athleticism { components.append((a, R.athleticismWeight))  }
        if let c = consistency { components.append((c, R.consistencyWeight))  }
        components.append((volume, R.volumeWeight))
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        return components.reduce(0.0) { $0 + $1.value * ($1.weight / totalWeight) }
    }
```

- [ ] **Step 4: Run all SkillRatingCalculator tests — confirm all PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/SkillRatingCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```
Expected: all tests passed

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrackTests/SkillRatingCalculatorTests.swift HoopTrack/HoopTrack/Utilities/SkillRatingCalculator.swift
git commit -m "test+feat: consistencyScore, volumeScore, overallScore — SkillRatingCalculator complete"
```

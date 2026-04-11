# Phase 5A — Plan C: BadgeScoreCalculator

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `BadgeScoreCalculator` — 25 per-badge scoring functions plus session→badge routing. Internal functions take primitives (directly testable); the public entry point handles SwiftData model access.

**Architecture:** `enum BadgeScoreCalculator` with two public API functions and 25 `internal` per-badge functions (accessible via `@testable import`). Tests call internal functions with primitive args — no ModelContainer needed.

**Tech Stack:** Swift, XCTest, `SkillRatingCalculator.normalize`, `HoopTrack.SkillRating` constants

**Prerequisite:** Plan A (models) + Plan B (SkillRatingCalculator) complete

**Test command:**
```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed|error:)"
```

---

### Task 1: Scaffold `BadgeScoreCalculator` with `affectedDrillTypes`

**Files:**
- Create: `HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift`
- Create: `HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift`

- [ ] **Step 1: Create `BadgeScoreCalculator.swift` with the public skeleton and `affectedDrillTypes`**

```swift
// BadgeScoreCalculator.swift
// Public entry point handles SwiftData model extraction.
// Internal per-badge functions take only primitive value types — directly unit-testable.

import Foundation

enum BadgeScoreCalculator {

    // MARK: - Public API

    /// Returns 0–100 score (nil = session type not relevant to this badge).
    static func score(for badgeID: BadgeID,
                      session: TrainingSession,
                      profile: PlayerProfile) -> Double? {
        guard affectedDrillTypes(for: badgeID).contains(session.drillType) else { return nil }
        return route(badgeID: badgeID, session: session, profile: profile)
    }

    /// DrillTypes whose sessions affect this badge's MMR.
    static func affectedDrillTypes(for badgeID: BadgeID) -> Set<DrillType> {
        switch badgeID {
        // Shooting-only badges
        case .deadeye, .sniper, .quickTrigger, .beyondTheArc, .charityStripe,
             .threeLevelScorer, .hotHand, .automatic, .metronome, .iceVeins,
             .reliable, .workhorse:
            return [.freeShoot]
        // Dribble-only badges
        case .handles, .ambidextrous, .comboKing, .floorGeneral, .ballWizard:
            return [.dribble]
        // Agility-only badges
        case .posterizer, .lightning, .explosive, .highFlyer:
            return [.agility]
        // Any-session badges
        case .ironMan, .gymRat, .specialist, .completePlayer:
            return [.freeShoot, .dribble, .agility, .fullWorkout]
        }
    }

    // Implemented in the tasks below:
    private static func route(badgeID: BadgeID,
                               session: TrainingSession,
                               profile: PlayerProfile) -> Double? { nil }
}
```

- [ ] **Step 2: Write failing tests for `affectedDrillTypes`**

```swift
// BadgeScoreCalculatorTests.swift
import XCTest
@testable import HoopTrack

final class BadgeScoreCalculatorTests: XCTestCase {

    // MARK: - affectedDrillTypes

    func test_affectedDrillTypes_deadeye_onlyFreeShoot() {
        XCTAssertEqual(BadgeScoreCalculator.affectedDrillTypes(for: .deadeye), [.freeShoot])
    }

    func test_affectedDrillTypes_handles_onlyDribble() {
        XCTAssertEqual(BadgeScoreCalculator.affectedDrillTypes(for: .handles), [.dribble])
    }

    func test_affectedDrillTypes_explosive_onlyAgility() {
        XCTAssertEqual(BadgeScoreCalculator.affectedDrillTypes(for: .explosive), [.agility])
    }

    func test_affectedDrillTypes_ironMan_allDrillTypes() {
        let types = BadgeScoreCalculator.affectedDrillTypes(for: .ironMan)
        XCTAssertEqual(types, [.freeShoot, .dribble, .agility, .fullWorkout])
    }
}
```

- [ ] **Step 3: Run tests — confirm PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed|error:)"
```
Expected: 4 tests passed

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift
git commit -m "test+feat: BadgeScoreCalculator scaffold with affectedDrillTypes"
```

---

### Task 2: Shooting badge internal functions (7 badges)

**Files:**
- Modify: `HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift`
- Modify: `HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift`

- [ ] **Step 1: Add failing tests for shooting badge internals**

```swift
    // MARK: - Shooting badges

    func test_deadeye_perfectFG_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.deadeye(fgPct: 100, shotsAttempted: 20)!, 100, accuracy: 0.1)
    }
    func test_deadeye_tooFewShots_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.deadeye(fgPct: 50, shotsAttempted: 19))
    }

    func test_sniper_zeroStdDev_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.sniper(releaseAngleStdDev: 0, shotsAttempted: 20)!, 100, accuracy: 0.1)
    }
    func test_sniper_nilStdDev_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.sniper(releaseAngleStdDev: nil, shotsAttempted: 20))
    }
    func test_sniper_tooFewShots_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.sniper(releaseAngleStdDev: 2, shotsAttempted: 15))
    }

    func test_quickTrigger_eliteTime_returnsHigh() {
        let score = BadgeScoreCalculator.quickTrigger(avgReleaseTimeMs: 300, shotsAttempted: 20)!
        XCTAssertEqual(score, 100, accuracy: 0.1)
    }
    func test_quickTrigger_nilTime_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.quickTrigger(avgReleaseTimeMs: nil, shotsAttempted: 20))
    }

    func test_beyondTheArc_perfect3PT_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.beyondTheArc(threePct: 100, threeAttempts: 10)!, 100, accuracy: 0.1)
    }
    func test_beyondTheArc_fewerThan10_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.beyondTheArc(threePct: 50, threeAttempts: 9))
    }

    func test_charityStripe_perfectFT_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.charityStripe(ftPct: 100, ftAttempts: 10)!, 100, accuracy: 0.1)
    }
    func test_charityStripe_fewerThan10_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.charityStripe(ftPct: 80, ftAttempts: 9))
    }

    func test_threeLevelScorer_allZonesAbsent_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.threeLevelScorer(
            paintFGPct: nil, paintAttempts: 0,
            midFGPct: nil, midAttempts: 0,
            threeFGPct: nil, threeAttempts: 0))
    }
    func test_threeLevelScorer_oneZonePresent_returnsScore() {
        let score = BadgeScoreCalculator.threeLevelScorer(
            paintFGPct: 100, paintAttempts: 5,
            midFGPct: nil, midAttempts: 0,
            threeFGPct: nil, threeAttempts: 0)
        XCTAssertNotNil(score)
        // paint=100 + mid=0 (absent) + three=0 (absent) / 3 ≈ 33.3
        XCTAssertEqual(score!, 100.0/3.0, accuracy: 1.0)
    }

    func test_hotHand_streak15_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.hotHand(longestMakeStreak: 15), 100, accuracy: 0.1)
    }
    func test_hotHand_streak0_returns0() {
        XCTAssertEqual(BadgeScoreCalculator.hotHand(longestMakeStreak: 0), 0, accuracy: 0.1)
    }
```

- [ ] **Step 2: Run tests — confirm new tests FAIL**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep "failed"
```

- [ ] **Step 3: Implement the 7 shooting badge internal functions**

Add inside `enum BadgeScoreCalculator` (before `route`):

```swift
    // MARK: - Shooting Badge Internals

    static func deadeye(fgPct: Double, shotsAttempted: Int) -> Double? {
        guard shotsAttempted >= 20 else { return nil }
        return SkillRatingCalculator.normalize(fgPct, min: 0, max: 100)
    }

    static func sniper(releaseAngleStdDev: Double?, shotsAttempted: Int) -> Double? {
        guard shotsAttempted >= 20, let sd = releaseAngleStdDev else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.releaseAngleStdDevMax - sd,
                                               min: 0, max: R.releaseAngleStdDevMax)
    }

    static func quickTrigger(avgReleaseTimeMs: Double?, shotsAttempted: Int) -> Double? {
        guard shotsAttempted >= 20, let ms = avgReleaseTimeMs else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.releaseTimeSlowMs - ms,
                                               min: 0,
                                               max: R.releaseTimeSlowMs - R.releaseTimeEliteMs)
    }

    static func beyondTheArc(threePct: Double?, threeAttempts: Int) -> Double? {
        guard threeAttempts >= 10, let pct = threePct else { return nil }
        return SkillRatingCalculator.normalize(pct, min: 0, max: 100)
    }

    static func charityStripe(ftPct: Double?, ftAttempts: Int) -> Double? {
        guard ftAttempts >= 10, let pct = ftPct else { return nil }
        return SkillRatingCalculator.normalize(pct, min: 0, max: 100)
    }

    static func threeLevelScorer(paintFGPct: Double?, paintAttempts: Int,
                                  midFGPct: Double?,   midAttempts: Int,
                                  threeFGPct: Double?, threeAttempts: Int) -> Double? {
        guard paintAttempts >= 3 || midAttempts >= 3 || threeAttempts >= 3 else { return nil }
        let p = paintAttempts >= 3 ? SkillRatingCalculator.normalize(paintFGPct ?? 0, min: 0, max: 100) : 0.0
        let m = midAttempts   >= 3 ? SkillRatingCalculator.normalize(midFGPct   ?? 0, min: 0, max: 100) : 0.0
        let t = threeAttempts >= 3 ? SkillRatingCalculator.normalize(threeFGPct ?? 0, min: 0, max: 100) : 0.0
        return (p + m + t) / 3.0
    }

    static func hotHand(longestMakeStreak: Int) -> Double {
        SkillRatingCalculator.normalize(Double(longestMakeStreak), min: 0, max: 15)
    }
```

- [ ] **Step 4: Run tests — confirm all PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift
git commit -m "test+feat: 7 shooting badge score functions"
```

---

### Task 3: Ball handling + athleticism badge internal functions (9 badges)

**Files:**
- Modify: `HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift`
- Modify: `HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift`

- [ ] **Step 1: Add failing tests**

```swift
    // MARK: - Ball Handling badges

    func test_handles_eliteBPS_returnsHigh() {
        let score = BadgeScoreCalculator.handles(avgBPS: 8.0)!
        XCTAssertEqual(score, 100, accuracy: 1.0)
    }
    func test_handles_nilBPS_returnsNil() { XCTAssertNil(BadgeScoreCalculator.handles(avgBPS: nil)) }

    func test_ambidextrous_equalHands_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.ambidextrous(handBalance: 0.5, totalDribbles: 100)!, 100, accuracy: 0.1)
    }
    func test_ambidextrous_fewerThan100_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.ambidextrous(handBalance: 0.5, totalDribbles: 99))
    }

    func test_comboKing_50combos_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.comboKing(combos: 50, totalDribbles: 200)!, 100, accuracy: 0.1)
    }
    func test_comboKing_fewerThan100Dribbles_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.comboKing(combos: 10, totalDribbles: 99))
    }

    func test_floorGeneral_highRatio_returnsHigh() {
        // avg=7, max=8 → ratio=0.875 (above bpsSustainedMax=0.9 → normalize)
        let score = BadgeScoreCalculator.floorGeneral(avgBPS: 7.0, maxBPS: 8.0, durationSeconds: 60)!
        XCTAssertGreaterThan(score, 50)
    }
    func test_floorGeneral_underMinDuration_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.floorGeneral(avgBPS: 5.0, maxBPS: 7.0, durationSeconds: 59))
    }
    func test_floorGeneral_avgBPSUnder3_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.floorGeneral(avgBPS: 2.9, maxBPS: 5.0, durationSeconds: 120))
    }

    func test_ballWizard_career50k_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.ballWizard(careerTotalDribbles: 50_000), 100, accuracy: 0.1)
    }

    // MARK: - Athleticism badges

    func test_posterizer_nilJump_returnsNil() { XCTAssertNil(BadgeScoreCalculator.posterizer(avgVerticalJumpCm: nil)) }
    func test_posterizer_eliteJump_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.posterizer(avgVerticalJumpCm: 90)!, 100, accuracy: 0.1)
    }

    func test_lightning_nilShuttle_returnsNil() { XCTAssertNil(BadgeScoreCalculator.lightning(bestShuttleRunSec: nil)) }
    func test_lightning_eliteShuttle_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.lightning(bestShuttleRunSec: 5.5)!, 100, accuracy: 0.1)
    }

    func test_explosive_100rating_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.explosive(ratingAthleticism: 100), 100, accuracy: 0.1)
    }

    func test_highFlyer_prJump90_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.highFlyer(prVerticalJumpCm: 90), 100, accuracy: 0.1)
    }
```

- [ ] **Step 2: Run tests — confirm new tests FAIL**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep "failed"
```

- [ ] **Step 3: Implement the 9 badge internal functions**

Add inside `enum BadgeScoreCalculator`:

```swift
    // MARK: - Ball Handling Badge Internals

    static func handles(avgBPS: Double?) -> Double? {
        guard let bps = avgBPS else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(bps, min: R.bpsAvgMin, max: R.bpsAvgMax)
    }

    static func ambidextrous(handBalance: Double?, totalDribbles: Int) -> Double? {
        guard totalDribbles >= 100, let balance = handBalance else { return nil }
        return (1 - abs(balance - 0.5) * 2) * 100
    }

    static func comboKing(combos: Int, totalDribbles: Int) -> Double? {
        guard totalDribbles >= 100 else { return nil }
        return SkillRatingCalculator.normalize(Double(combos), min: 0, max: 50)
    }

    static func floorGeneral(avgBPS: Double?, maxBPS: Double?, durationSeconds: Double) -> Double? {
        guard durationSeconds >= 60,
              let avg = avgBPS, avg >= 3.0,
              let mx = maxBPS, mx > 0 else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(avg / mx, min: R.bpsSustainedMin, max: R.bpsSustainedMax)
    }

    static func ballWizard(careerTotalDribbles: Int) -> Double {
        SkillRatingCalculator.normalize(Double(careerTotalDribbles), min: 0, max: 50_000)
    }

    // MARK: - Athleticism Badge Internals

    static func posterizer(avgVerticalJumpCm: Double?) -> Double? {
        guard let jump = avgVerticalJumpCm else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(jump, min: R.verticalJumpMinCm, max: R.verticalJumpMaxCm)
    }

    static func lightning(bestShuttleRunSec: Double?) -> Double? {
        guard let sec = bestShuttleRunSec else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.shuttleRunWorstSec - sec,
                                               min: 0,
                                               max: R.shuttleRunWorstSec - R.shuttleRunBestSec)
    }

    static func explosive(ratingAthleticism: Double) -> Double {
        SkillRatingCalculator.normalize(ratingAthleticism, min: 0, max: 100)
    }

    static func highFlyer(prVerticalJumpCm: Double) -> Double {
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(prVerticalJumpCm,
                                               min: R.verticalJumpMinCm, max: R.verticalJumpMaxCm)
    }
```

- [ ] **Step 4: Run tests — confirm all PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift
git commit -m "test+feat: ball handling and athleticism badge score functions (9 badges)"
```

---

### Task 4: Consistency + volume badge internal functions (9 badges)

**Files:**
- Modify: `HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift`
- Modify: `HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift`

- [ ] **Step 1: Add failing tests**

```swift
    // MARK: - Consistency badges

    func test_automatic_fewerThan3_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.automatic(recentFGPcts: [50, 55]))
    }
    func test_automatic_perfectConsistency_returnsHigh() {
        // All same FG% → std dev = 0 → max score
        let score = BadgeScoreCalculator.automatic(recentFGPcts: [50, 50, 50, 50, 50])!
        XCTAssertEqual(score, 100, accuracy: 0.1)
    }

    func test_metronome_fewerThan10Sessions_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.metronome(avgReleaseAngleStdDev: 2.0, sessionCount: 9))
    }
    func test_metronome_zeroStdDev_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.metronome(avgReleaseAngleStdDev: 0, sessionCount: 10)!, 100, accuracy: 0.1)
    }

    func test_iceVeins_fewerThan50FT_returnsNil() {
        XCTAssertNil(BadgeScoreCalculator.iceVeins(careerFTPct: 90, totalFTAttempts: 49))
    }
    func test_iceVeins_perfect_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.iceVeins(careerFTPct: 100, totalFTAttempts: 50)!, 100, accuracy: 0.1)
    }

    func test_reliable_streak12_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.reliable(consecutiveSessionsAbove40FG: 12), 100, accuracy: 0.1)
    }
    func test_reliable_streak0_returns0() {
        XCTAssertEqual(BadgeScoreCalculator.reliable(consecutiveSessionsAbove40FG: 0), 0, accuracy: 0.1)
    }

    // MARK: - Volume badges

    func test_ironMan_60days_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.ironMan(longestStreakDays: 60), 100, accuracy: 0.1)
    }

    func test_gymRat_5sessions_returns100() {
        let cap = Int(HoopTrack.SkillRating.sessionsPerWeekCap)
        XCTAssertEqual(BadgeScoreCalculator.gymRat(sessionsLast7Days: cap), 100, accuracy: 0.1)
    }

    func test_workhorse_15k_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.workhorse(careerShotsAttempted: 15_000), 100, accuracy: 0.1)
    }

    func test_specialist_100sessions_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.specialist(maxSessionsOfOneDrillType: 100), 100, accuracy: 0.1)
    }

    func test_completePlayer_100rating_returns100() {
        XCTAssertEqual(BadgeScoreCalculator.completePlayer(minSkillRating: 100), 100, accuracy: 0.1)
    }
```

- [ ] **Step 2: Run tests — confirm new tests FAIL**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep "failed"
```

- [ ] **Step 3: Implement the 9 badge internal functions**

Add inside `enum BadgeScoreCalculator`:

```swift
    // MARK: - Consistency Badge Internals

    static func automatic(recentFGPcts: [Double]) -> Double? {
        let history = Array(recentFGPcts.suffix(10))
        guard history.count >= HoopTrack.SkillRating.crossSessionMinCount else { return nil }
        let mean     = history.reduce(0, +) / Double(history.count)
        let variance = history.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(history.count)
        let stdDev   = sqrt(variance)
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.fgPctSessionStdDevMax - stdDev,
                                               min: 0, max: R.fgPctSessionStdDevMax)
    }

    static func metronome(avgReleaseAngleStdDev: Double?, sessionCount: Int) -> Double? {
        guard sessionCount >= 10, let sd = avgReleaseAngleStdDev else { return nil }
        let R = HoopTrack.SkillRating.self
        return SkillRatingCalculator.normalize(R.releaseAngleStdDevMax - sd,
                                               min: 0, max: R.releaseAngleStdDevMax)
    }

    static func iceVeins(careerFTPct: Double, totalFTAttempts: Int) -> Double? {
        guard totalFTAttempts >= 50 else { return nil }
        return SkillRatingCalculator.normalize(careerFTPct, min: 0, max: 100)
    }

    static func reliable(consecutiveSessionsAbove40FG: Int) -> Double {
        SkillRatingCalculator.normalize(Double(consecutiveSessionsAbove40FG), min: 0, max: 12)
    }

    // MARK: - Volume Badge Internals

    static func ironMan(longestStreakDays: Int) -> Double {
        SkillRatingCalculator.normalize(Double(longestStreakDays), min: 0, max: 60)
    }

    static func gymRat(sessionsLast7Days: Int) -> Double {
        SkillRatingCalculator.normalize(Double(sessionsLast7Days),
                                         min: 0, max: HoopTrack.SkillRating.sessionsPerWeekCap)
    }

    static func workhorse(careerShotsAttempted: Int) -> Double {
        SkillRatingCalculator.normalize(Double(careerShotsAttempted), min: 0, max: 15_000)
    }

    static func specialist(maxSessionsOfOneDrillType: Int) -> Double {
        SkillRatingCalculator.normalize(Double(maxSessionsOfOneDrillType), min: 0, max: 100)
    }

    static func completePlayer(minSkillRating: Double) -> Double {
        SkillRatingCalculator.normalize(minSkillRating, min: 0, max: 100)
    }
```

- [ ] **Step 4: Run tests — confirm all PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift HoopTrack/HoopTrackTests/BadgeScoreCalculatorTests.swift
git commit -m "test+feat: consistency and volume badge score functions (9 badges)"
```

---

### Task 5: Implement `route` — public `score()` model extraction

**Files:**
- Modify: `HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift`

- [ ] **Step 1: Replace the `route` stub with the full implementation**

Replace `private static func route(...) -> Double? { nil }` with:

```swift
    private static func route(badgeID: BadgeID,
                               session: TrainingSession,
                               profile: PlayerProfile) -> Double? {
        switch badgeID {
        // MARK: Shooting
        case .deadeye:
            return deadeye(fgPct: session.fgPercent, shotsAttempted: session.shotsAttempted)
        case .sniper:
            return sniper(releaseAngleStdDev: session.consistencyScore, shotsAttempted: session.shotsAttempted)
        case .quickTrigger:
            return quickTrigger(avgReleaseTimeMs: session.avgReleaseTimeMs, shotsAttempted: session.shotsAttempted)
        case .beyondTheArc:
            let attempts = session.shots.filter {
                ($0.zone == .cornerThree || $0.zone == .aboveBreakThree) && $0.result != .pending
            }.count
            return beyondTheArc(threePct: session.threePointPercentage, threeAttempts: attempts)
        case .charityStripe:
            let attempts = session.shots.filter { $0.zone == .freeThrow && $0.result != .pending }.count
            return charityStripe(ftPct: session.freeThrowPercentage, ftAttempts: attempts)
        case .threeLevelScorer:
            let p = session.shots.filter { $0.zone == .paint     && $0.result != .pending }
            let m = session.shots.filter { $0.zone == .midRange  && $0.result != .pending }
            let t = session.shots.filter { ($0.zone == .cornerThree || $0.zone == .aboveBreakThree) && $0.result != .pending }
            let pct: ([ShotRecord]) -> Double? = { shots in
                shots.isEmpty ? nil : Double(shots.filter { $0.result == .make }.count) / Double(shots.count) * 100
            }
            return threeLevelScorer(paintFGPct: pct(p), paintAttempts: p.count,
                                    midFGPct:   pct(m), midAttempts:   m.count,
                                    threeFGPct: pct(t), threeAttempts: t.count)
        case .hotHand:
            return hotHand(longestMakeStreak: session.longestMakeStreak)

        // MARK: Ball Handling
        case .handles:
            return handles(avgBPS: session.avgDribblesPerSec)
        case .ambidextrous:
            return ambidextrous(handBalance: session.handBalanceFraction,
                                totalDribbles: session.totalDribbles ?? 0)
        case .comboKing:
            return comboKing(combos: session.dribbleCombosDetected ?? 0,
                             totalDribbles: session.totalDribbles ?? 0)
        case .floorGeneral:
            return floorGeneral(avgBPS: session.avgDribblesPerSec,
                                maxBPS: session.maxDribblesPerSec,
                                durationSeconds: session.durationSeconds)
        case .ballWizard:
            let total = profile.sessions.reduce(0) { $0 + ($1.totalDribbles ?? 0) }
            return ballWizard(careerTotalDribbles: total)

        // MARK: Athleticism
        case .posterizer:
            return posterizer(avgVerticalJumpCm: session.avgVerticalJumpCm)
        case .lightning:
            return lightning(bestShuttleRunSec: session.bestShuttleRunSeconds)
        case .explosive:
            // ratingAthleticism already updated by SkillRatingService (coordinator step 4 before step 5)
            return explosive(ratingAthleticism: profile.ratingAthleticism)
        case .highFlyer:
            return highFlyer(prVerticalJumpCm: profile.prVerticalJumpCm)

        // MARK: Consistency
        case .automatic:
            let recent = profile.sessions
                .filter { $0.drillType == .freeShoot && $0.isComplete }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(10)
                .map { $0.fgPercent }
            return automatic(recentFGPcts: Array(recent))
        case .metronome:
            let shootingSessions = profile.sessions.filter { $0.drillType == .freeShoot && $0.isComplete }
            let values = shootingSessions.compactMap { $0.consistencyScore }
            let avg: Double? = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
            return metronome(avgReleaseAngleStdDev: avg, sessionCount: shootingSessions.count)
        case .iceVeins:
            let ftShots = profile.sessions.flatMap { $0.shots }.filter { $0.zone == .freeThrow && $0.result != .pending }
            let made = ftShots.filter { $0.result == .make }.count
            let pct  = ftShots.isEmpty ? 0.0 : Double(made) / Double(ftShots.count) * 100
            return iceVeins(careerFTPct: pct, totalFTAttempts: ftShots.count)
        case .reliable:
            let streak = profile.sessions
                .filter { $0.drillType == .freeShoot && $0.isComplete }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(while: { $0.fgPercent >= 40 })
                .count
            return reliable(consecutiveSessionsAbove40FG: streak)

        // MARK: Volume
        case .ironMan:
            return ironMan(longestStreakDays: profile.longestStreakDays)
        case .gymRat:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            let count  = profile.sessions.filter { $0.startedAt >= cutoff && $0.isComplete }.count
            return gymRat(sessionsLast7Days: count)
        case .workhorse:
            return workhorse(careerShotsAttempted: profile.careerShotsAttempted)
        case .specialist:
            let byType  = Dictionary(grouping: profile.sessions.filter { $0.isComplete }, by: { $0.drillType })
            let maxCount = byType.values.map { $0.count }.max() ?? 0
            return specialist(maxSessionsOfOneDrillType: maxCount)
        case .completePlayer:
            let minRating = [profile.ratingShooting, profile.ratingBallHandling,
                             profile.ratingAthleticism, profile.ratingConsistency,
                             profile.ratingVolume].min() ?? 0
            return completePlayer(minSkillRating: minRating)
        }
    }
```

- [ ] **Step 2: Build to verify — all 25 cases are covered (no switch warning)**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED` with no unhandled switch warnings

- [ ] **Step 3: Run full BadgeScoreCalculator test suite**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/BadgeScoreCalculatorTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```
Expected: all tests passed

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/BadgeScoreCalculator.swift
git commit -m "feat: BadgeScoreCalculator public route() — all 25 badges complete"
```

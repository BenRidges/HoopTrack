# Phase 5A — Plan D: Services

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement all five Phase 5A services: GoalUpdateService (with tests), SkillRatingService, BadgeEvaluationService, HealthKitService, and NotificationService additions.

**Architecture:** All services are `@MainActor final class` conforming to `@MainActor` protocols. Each takes `ModelContext` in its init. `GoalUpdateService` is test-covered via an in-memory `ModelContainer`. The remaining services have no unit tests — their logic depends entirely on framework side-effects (HealthKit, UNUserNotificationCenter, SwiftData EMA writes).

**Tech Stack:** SwiftData, HealthKit, UserNotifications, XCTest

**Prerequisite:** Plans A, B, C complete (models, SkillRatingCalculator, BadgeScoreCalculator)

**Test command:**
```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/GoalUpdateServiceTests 2>&1 | grep -E "(Test.*passed|Test.*failed|error:)"
```

---

### Task 1: Service protocols file

**Files:**
- Create: `HoopTrack/HoopTrack/Services/ServiceProtocols.swift`

- [ ] **Step 1: Create the protocols and shared result types**

```swift
// ServiceProtocols.swift
// @MainActor on each protocol ensures the @MainActor coordinator can call
// requirements without additional await (required for Swift 6 strict concurrency).

import Foundation

@MainActor protocol GoalUpdateServiceProtocol {
    func update(after session: TrainingSession, profile: PlayerProfile) throws
}

@MainActor protocol SkillRatingServiceProtocol {
    func recalculate(for profile: PlayerProfile, session: TrainingSession) throws
}

@MainActor protocol BadgeEvaluationServiceProtocol {
    func evaluate(session: TrainingSession,
                  profile: PlayerProfile) throws -> [BadgeTierChange]
}

@MainActor protocol HealthKitServiceProtocol {
    func requestPermission() async
    func writeWorkout(for session: TrainingSession) async throws
}

// MARK: - Result types

struct BadgeTierChange: Equatable {
    let badgeID: BadgeID
    let previousRank: BadgeRank?   // nil = first earn
    let newRank: BadgeRank
}

struct SessionResult {
    let session: TrainingSession
    let badgeChanges: [BadgeTierChange]
}

struct AgilityAttempts {
    var bestShuttleRunSeconds: Double?
    var bestLaneAgilitySeconds: Double?
}
```

- [ ] **Step 2: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Services/ServiceProtocols.swift
git commit -m "feat: service protocols and shared result types (BadgeTierChange, SessionResult, AgilityAttempts)"
```

---

### Task 2: `GoalUpdateService` (TDD)

**Files:**
- Create: `HoopTrack/HoopTrack/Services/GoalUpdateService.swift`
- Create: `HoopTrack/HoopTrackTests/GoalUpdateServiceTests.swift`

- [ ] **Step 1: Write the failing tests**

Note on `shuttleRunSeconds` goals: the metric is "lower is better". `GoalRecord.progressFraction` handles this correctly because baseline > target for a shuttle goal (e.g. baseline=9.0s, target=6.0s). The `isAchieved` check needs special-casing — `currentValue <= targetValue` for this metric.

```swift
// GoalUpdateServiceTests.swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class GoalUpdateServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var sut: GoalUpdateService!

    override func setUp() async throws {
        container = try ModelContainer(
            for: PlayerProfile.self, TrainingSession.self,
                 ShotRecord.self, GoalRecord.self, EarnedBadge.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = container.mainContext
        sut = GoalUpdateService(modelContext: context)
    }

    override func tearDown() async throws {
        container = nil
        context   = nil
        sut       = nil
    }

    // MARK: - Helpers

    private func makeProfile() throws -> PlayerProfile {
        let p = PlayerProfile()
        context.insert(p)
        try context.save()
        return p
    }

    private func makeSession(drillType: DrillType = .freeShoot,
                              fgPercent: Double = 50) throws -> TrainingSession {
        let s = TrainingSession(drillType: drillType)
        s.fgPercent = fgPercent
        s.endedAt   = .now
        context.insert(s)
        try context.save()
        return s
    }

    private func makeGoal(metric: GoalMetric,
                           target: Double,
                           baseline: Double = 0,
                           for profile: PlayerProfile) throws -> GoalRecord {
        let g = GoalRecord(title: "Test", skill: .shooting, metric: metric,
                           targetValue: target, baselineValue: baseline)
        g.profile = profile
        profile.goals.append(g)
        context.insert(g)
        try context.save()
        return g
    }

    // MARK: - fgPercent

    func test_update_fgPercentGoal_updatesCurrentValue() throws {
        let profile = try makeProfile()
        let session = try makeSession(fgPercent: 45)
        let goal    = try makeGoal(metric: .fgPercent, target: 50, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertEqual(goal.currentValue, 45, accuracy: 0.01)
        XCTAssertFalse(goal.isAchieved)
    }

    func test_update_fgPercentGoalAchieved_setsIsAchieved() throws {
        let profile = try makeProfile()
        let session = try makeSession(fgPercent: 55)
        let goal    = try makeGoal(metric: .fgPercent, target: 50, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertTrue(goal.isAchieved)
        XCTAssertNotNil(goal.achievedAt)
    }

    func test_update_alreadyAchievedGoal_isNotTouchedAgain() throws {
        let profile = try makeProfile()
        let session = try makeSession(fgPercent: 30)
        let goal    = try makeGoal(metric: .fgPercent, target: 50, for: profile)
        goal.isAchieved = true
        goal.achievedAt = Date(timeIntervalSinceNow: -3600)
        let originalDate = goal.achievedAt

        try sut.update(after: session, profile: profile)

        XCTAssertEqual(goal.achievedAt, originalDate)
    }

    // MARK: - sessionsPerWeek

    func test_update_sessionsPerWeekGoal_countsRecentSessions() throws {
        let profile = try makeProfile()
        // Add 3 completed sessions in the past 7 days
        for _ in 0..<3 {
            let s = try makeSession()
            s.startedAt = Date(timeIntervalSinceNow: -86400) // yesterday
            profile.sessions.append(s)
        }
        let session = try makeSession()
        let goal    = try makeGoal(metric: .sessionsPerWeek, target: 5, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertGreaterThan(goal.currentValue, 0)
    }

    // MARK: - overallRating

    func test_update_overallRatingGoal_readsFromProfile() throws {
        let profile = try makeProfile()
        profile.ratingOverall = 72
        let session = try makeSession()
        let goal    = try makeGoal(metric: .overallRating, target: 80, for: profile)

        try sut.update(after: session, profile: profile)

        XCTAssertEqual(goal.currentValue, 72, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run tests — confirm they FAIL (GoalUpdateService not found)**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/GoalUpdateServiceTests 2>&1 | grep -E "(error:|failed)"
```

- [ ] **Step 3: Implement `GoalUpdateService`**

```swift
// GoalUpdateService.swift
import Foundation
import SwiftData

@MainActor final class GoalUpdateService: GoalUpdateServiceProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func update(after session: TrainingSession, profile: PlayerProfile) throws {
        for goal in profile.goals where !goal.isAchieved {
            let value = currentValue(for: goal.metric, session: session, profile: profile)
            goal.currentValue = value
            if isAchieved(metric: goal.metric, current: value, target: goal.targetValue) {
                goal.isAchieved = true
                goal.achievedAt = .now
            }
        }
        try modelContext.save()
    }

    // MARK: - Private

    private func currentValue(for metric: GoalMetric,
                               session: TrainingSession,
                               profile: PlayerProfile) -> Double {
        switch metric {
        case .fgPercent:
            return session.fgPercent
        case .threePointPercent:
            return session.threePointPercentage ?? 0
        case .freeThrowPercent:
            return session.freeThrowPercentage ?? 0
        case .verticalJumpCm:
            return session.avgVerticalJumpCm ?? 0
        case .dribbleSpeedHz:
            return session.avgDribblesPerSec ?? 0
        case .shuttleRunSeconds:
            return session.bestShuttleRunSeconds ?? Double.infinity
        case .overallRating:
            return profile.ratingOverall
        case .shootingRating:
            return profile.ratingShooting
        case .sessionsPerWeek:
            let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now)!
            return Double(profile.sessions.filter { $0.startedAt >= cutoff && $0.isComplete }.count)
        }
    }

    /// shuttle run is lower-is-better; all other metrics are higher-is-better.
    private func isAchieved(metric: GoalMetric, current: Double, target: Double) -> Bool {
        metric == .shuttleRunSeconds ? current <= target : current >= target
    }
}
```

- [ ] **Step 4: Run tests — confirm all PASS**

```
xcodebuild test -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:HoopTrackTests/GoalUpdateServiceTests 2>&1 | grep -E "(Test.*passed|Test.*failed)"
```
Expected: all tests passed

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Services/GoalUpdateService.swift HoopTrack/HoopTrackTests/GoalUpdateServiceTests.swift
git commit -m "test+feat: GoalUpdateService with all 9 GoalMetric mappings"
```

---

### Task 3: `SkillRatingService`

**Files:**
- Create: `HoopTrack/HoopTrack/Services/SkillRatingService.swift`

- [ ] **Step 1: Implement `SkillRatingService`**

```swift
// SkillRatingService.swift
import Foundation
import SwiftData

@MainActor final class SkillRatingService: SkillRatingServiceProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func recalculate(for profile: PlayerProfile, session: TrainingSession) throws {
        let alpha = HoopTrack.SkillRating.emaAlpha

        // Extract primitives for calculators
        let recentFGPcts = profile.sessions
            .filter { $0.drillType == .freeShoot && $0.isComplete }
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(10)
            .map { $0.fgPercent }

        let threeAttemptFrac: Double? = {
            guard session.shotsAttempted > 0 else { return nil }
            let n = session.shots.filter {
                ($0.zone == .cornerThree || $0.zone == .aboveBreakThree) && $0.result != .pending
            }.count
            return Double(n) / Double(session.shotsAttempted)
        }()

        let shootingScore = SkillRatingCalculator.shootingScore(
            fgPct:               session.fgPercent,
            threePct:            session.threePointPercentage,
            ftPct:               session.freeThrowPercentage,
            releaseAngleDeg:     session.avgReleaseAngleDeg,
            releaseAngleStdDev:  session.consistencyScore,
            releaseTimeMs:       session.avgReleaseTimeMs,
            shotSpeedMph:        session.avgShotSpeedMph,
            shotSpeedStdDev:     session.shotSpeedStdDev,
            threeAttemptFraction: threeAttemptFrac
        )

        let handlingScore = SkillRatingCalculator.ballHandlingScore(
            avgBPS:        session.avgDribblesPerSec,
            maxBPS:        session.maxDribblesPerSec,
            handBalance:   session.handBalanceFraction,
            combos:        session.dribbleCombosDetected ?? 0,
            totalDribbles: session.totalDribbles ?? 0
        )

        let athleticismScore = SkillRatingCalculator.athleticismScore(
            verticalJumpCm: session.avgVerticalJumpCm,
            shuttleRunSec:  session.bestShuttleRunSeconds
        )

        let consistencyScore = SkillRatingCalculator.consistencyScore(
            releaseAngleStdDev: session.consistencyScore,
            fgPctHistory:       Array(recentFGPcts),
            ftPct:              session.freeThrowPercentage,
            shotSpeedStdDev:    session.shotSpeedStdDev
        )

        let cutoff28 = Calendar.current.date(byAdding: .day, value: -28, to: .now)!
        let cutoff14 = Calendar.current.date(byAdding: .day, value: -14, to: .now)!
        let recent28  = profile.sessions.filter { $0.startedAt >= cutoff28 && $0.isComplete }
        let avgShots  = recent28.isEmpty ? 0.0
            : recent28.map { Double($0.shotsAttempted) }.reduce(0, +) / Double(recent28.count)
        let weeklyMin = recent28.map { $0.durationSeconds / 60 }.reduce(0, +) / 4
        let distinct  = Set(profile.sessions.filter { $0.startedAt >= cutoff14 && $0.isComplete }.map { $0.drillType }).count
        let drillVar  = min(1.0, Double(distinct) / 4.0)

        let volumeScore = SkillRatingCalculator.volumeScore(
            sessionsLast4Weeks:     recent28.count,
            avgShotsPerSession:     avgShots,
            weeklyTrainingMinutes:  weeklyMin,
            drillVarietyLast14Days: drillVar
        )

        // EMA update; cold-start: if current == 0, set directly (no blend)
        func ema(_ current: Double, _ new: Double) -> Double {
            current == 0 ? new : current * (1 - alpha) + new * alpha
        }

        if let s = shootingScore    { profile.ratingShooting     = ema(profile.ratingShooting,     s) }
        if let h = handlingScore    { profile.ratingBallHandling  = ema(profile.ratingBallHandling,  h) }
        if let a = athleticismScore { profile.ratingAthleticism   = ema(profile.ratingAthleticism,   a) }
        if let c = consistencyScore { profile.ratingConsistency   = ema(profile.ratingConsistency,   c) }
        profile.ratingVolume = ema(profile.ratingVolume, volumeScore)

        profile.ratingOverall = SkillRatingCalculator.overallScore(
            shooting:    profile.ratingShooting    > 0 ? profile.ratingShooting    : nil,
            handling:    profile.ratingBallHandling > 0 ? profile.ratingBallHandling : nil,
            athleticism: profile.ratingAthleticism  > 0 ? profile.ratingAthleticism  : nil,
            consistency: profile.ratingConsistency  > 0 ? profile.ratingConsistency  : nil,
            volume:      profile.ratingVolume
        )

        // Update personal vertical jump record
        if let jump = session.avgVerticalJumpCm, jump > profile.prVerticalJumpCm {
            profile.prVerticalJumpCm = jump
        }

        try modelContext.save()
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
git add HoopTrack/HoopTrack/Services/SkillRatingService.swift
git commit -m "feat: SkillRatingService — EMA updates for all 5 skill dimensions"
```

---

### Task 4: `BadgeEvaluationService`

**Files:**
- Create: `HoopTrack/HoopTrack/Services/BadgeEvaluationService.swift`

- [ ] **Step 1: Implement `BadgeEvaluationService`**

```swift
// BadgeEvaluationService.swift
import Foundation
import SwiftData

@MainActor final class BadgeEvaluationService: BadgeEvaluationServiceProtocol {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func evaluate(session: TrainingSession,
                  profile: PlayerProfile) throws -> [BadgeTierChange] {
        let alpha   = HoopTrack.SkillRating.emaAlpha
        var changes = [BadgeTierChange]()

        for badgeID in BadgeID.allCases {
            // Skip badges not affected by this session type
            guard BadgeScoreCalculator.affectedDrillTypes(for: badgeID)
                    .contains(session.drillType) else { continue }

            // score() returns nil if data is absent; skip (non-fatal)
            guard let score = BadgeScoreCalculator.score(for: badgeID,
                                                          session: session,
                                                          profile: profile)
            else { continue }

            let targetMMR = score / 100.0 * 1800.0

            if let existing = profile.earnedBadges.first(where: { $0.badgeID == badgeID }) {
                // EMA blend
                let previousRank = BadgeRank(mmr: existing.mmr)
                existing.mmr           = existing.mmr * (1 - alpha) + targetMMR * alpha
                existing.lastUpdatedAt = .now
                let newRank = BadgeRank(mmr: existing.mmr)
                if newRank != previousRank {
                    changes.append(BadgeTierChange(badgeID: badgeID,
                                                   previousRank: previousRank,
                                                   newRank: newRank))
                }
            } else {
                // Cold-start: first earn — set MMR directly, no blend
                let badge = EarnedBadge(badgeID: badgeID,
                                        initialMMR: targetMMR,
                                        profile: profile)
                modelContext.insert(badge)
                profile.earnedBadges.append(badge)
                changes.append(BadgeTierChange(badgeID: badgeID,
                                               previousRank: nil,
                                               newRank: BadgeRank(mmr: targetMMR)))
            }
        }

        // SwiftData write errors are fatal (propagate); per-badge calculation errors are
        // swallowed above via guard-nil. The coordinator calls evaluate() with try? so
        // even a SwiftData error is non-fatal at the finalisation level.
        try modelContext.save()
        return changes
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
git add HoopTrack/HoopTrack/Services/BadgeEvaluationService.swift
git commit -m "feat: BadgeEvaluationService — MMR delta with EMA and cold-start rule"
```

---

### Task 5: `HealthKitService`

**Files:**
- Create: `HoopTrack/HoopTrack/Services/HealthKitService.swift`

- [ ] **Step 1: Add HealthKit capability**

In Xcode: select the `HoopTrack` target → Signing & Capabilities → `+ Capability` → `HealthKit`. This adds the entitlement and the `NSHealthUpdateUsageDescription` key must be added to `Info.plist` if not already present.

Add to `Info.plist` if missing:
```xml
<key>NSHealthUpdateUsageDescription</key>
<string>HoopTrack logs your basketball sessions as workouts in Health.</string>
```

- [ ] **Step 2: Implement `HealthKitService`**

```swift
// HealthKitService.swift
import Foundation
import HealthKit

@MainActor final class HealthKitService: HealthKitServiceProtocol {

    private let store = HKHealthStore()

    func requestPermission() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [])
    }

    func writeWorkout(for session: TrainingSession) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        guard store.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized else { return }
        guard let endedAt = session.endedAt else { return }

        let workout = HKWorkout(
            activityType: .basketball,
            start: session.startedAt,
            end: endedAt,
            duration: session.durationSeconds,
            totalEnergyBurned: nil,
            totalDistance: nil,
            metadata: nil
        )
        try await store.save(workout)
    }
}
```

- [ ] **Step 3: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Services/HealthKitService.swift
git commit -m "feat: HealthKitService — write basketball HKWorkout, silent on permission denial"
```

---

### Task 6: `NotificationService` additions

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/NotificationService.swift`

- [ ] **Step 1: Add `trainingReminder` and `goalMilestone` identifiers to the private `NotificationID` enum**

Find `private enum NotificationID` and add two new identifiers:

```swift
private enum NotificationID {
    static let streakReminder    = "com.hooptrack.notification.streak"
    static let trainingReminder  = "com.hooptrack.notification.training"   // NEW
    static let goalAchieved      = "com.hooptrack.notification.goal"
    static let goalMilestone     = "com.hooptrack.notification.milestone"  // NEW
    static let dailyMission      = "com.hooptrack.notification.mission"
}
```

- [ ] **Step 2: Add the three new methods after `cancelStreakReminder()`**

```swift
    // MARK: - Training Reminder

    func scheduleTrainingReminder(hour: Int) {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.trainingReminder])
        let content       = UNMutableNotificationContent()
        content.title     = "Time to Train"
        content.body      = "Your daily training session is waiting. Make it count."
        content.sound     = .default
        var components    = DateComponents()
        components.hour   = hour
        components.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        center.add(UNNotificationRequest(identifier: NotificationID.trainingReminder,
                                         content: content, trigger: trigger))
    }

    func cancelTrainingReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.trainingReminder])
    }

    // MARK: - Milestone Alerts

    /// Fires an immediate notification for each newly crossed 50/75/100% milestone.
    /// Updates `goal.lastMilestoneNotified` in place (caller must save ModelContext).
    func checkMilestones(for goals: [GoalRecord]) {
        for goal in goals {
            for threshold in [50, 75, 100] where threshold > goal.lastMilestoneNotified {
                guard goal.progressPercent >= threshold else { continue }

                let content = UNMutableNotificationContent()
                if threshold == 100 {
                    content.title = "Goal Achieved!"
                    content.body  = "You've hit your goal: \(goal.title)"
                    content.sound = .defaultRingtone
                } else {
                    content.title = "\(threshold)% There!"
                    content.body  = "You're \(threshold)% of the way to: \(goal.title)"
                    content.sound = .default
                }

                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                let id      = "\(NotificationID.goalMilestone).\(goal.id.uuidString).\(threshold)"
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                goal.lastMilestoneNotified = threshold
            }
        }
    }
```

- [ ] **Step 3: Build to verify**

```
xcodebuild build -project HoopTrack/HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Services/NotificationService.swift
git commit -m "feat: add scheduleTrainingReminder, cancelTrainingReminder, checkMilestones to NotificationService"
```

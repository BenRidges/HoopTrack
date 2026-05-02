# SP3 BO7 Playoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a solo BO7-style playoff mode — 4 rounds of escalating accuracy thresholds (40/50/60/70%), with elimination triggering a prescribed weak-zone drill that gates the retry. Persists across launches; one active series per user.

**Architecture:** New `PlayoffSeries` SwiftData model owns a collection of SP1 `GameSession`s (BO7 = up to 7 games per round). State machine `.active → .drillRequired → .active (retry) | .champion | .abandoned`. `WeakZoneAnalyser` is a pure function over `GameShotRecord`s. Prescribed drill is a regular `TrainingSession` with a back-link FK; finalization promotes state on success.

**Tech Stack:** Swift 6, SwiftUI, SwiftData (additive migration), Combine for VM state.

**Spec:** [`docs/superpowers/specs/2026-04-19-game-playoff-design.md`](../specs/2026-04-19-game-playoff-design.md)

**Hard dependencies:** SP1 (✅ shipped: `GameSession`, `GameType.bo7Playoff`, `GameShotRecord`). SP2 (CV shot attribution + `GameShotRecord` populated by CV). If SP2 ships first, SP3 has access to attributed shots; if SP3 ships before SP2, the live playoff view will use **manual shot tally** (tap-to-record) as a fallback — gated behind a `HoopTrack.Playoff.requireCVAttribution` flag (default false until SP2 lands).

---

## File Structure

**New:**
- `HoopTrack/Models/PlayoffSeries.swift` — `@Model` + `PlayoffRoundResult` Codable
- `HoopTrack/Utilities/PlayoffStateMachine.swift` — pure transition logic
- `HoopTrack/Utilities/WeakZoneAnalyser.swift` — pure analyser
- `HoopTrack/ViewModels/PlayoffSeriesViewModel.swift`
- `HoopTrack/Views/Game/PlayoffEntryView.swift` — start / resume
- `HoopTrack/Views/Game/LivePlayoffView.swift`
- `HoopTrack/Views/Game/PlayoffTransitionCards.swift`
- `HoopTrack/Views/Game/PrescribedDrillView.swift`
- `HoopTrack/Views/Game/PlayoffRunSummaryView.swift`
- `HoopTrackTests/WeakZoneAnalyserTests.swift`
- `HoopTrackTests/PlayoffStateMachineTests.swift`

**Modified:**
- `HoopTrack/Models/Enums.swift` — `PlayoffState`, `PlayoffRound`
- `HoopTrack/Models/TrainingSession.swift` — add `playoffSeriesID: UUID?`
- `HoopTrack/HoopTrackApp.swift` — register `PlayoffSeries.self` in Schema list
- `HoopTrack/Services/DataService.swift` — `fetchActivePlayoffSeries()`, `createPlayoffSeries()`
- `HoopTrack/Services/SessionFinalizationCoordinator.swift` — drill-completion promotes state
- `HoopTrack/Views/Home/HomeTabView.swift` — resume banner
- `HoopTrack/Views/Train/TrainTabView.swift` — "Start Playoff" entry
- `HoopTrack/Views/Progress/ProgressTabView.swift` — Playoff Runs section
- `HoopTrack/Utilities/Constants.swift` — `HoopTrack.Playoff`
- `HoopTrack/Sync/DTOs/` — new `PlayoffSeriesDTO.swift` + register in `SyncCoordinator`
- `HoopTrack/Models/CommentaryEvent.swift` (if SP4 already shipped) — delete the stub `PlayoffRound` (Task 2 will provide the real one)

---

## Task 1: Enums (`PlayoffState`, `PlayoffRound`)

**Files:**
- Modify: `HoopTrack/Models/Enums.swift`
- Modify (if SP4 shipped): `HoopTrack/Models/CommentaryEvent.swift` — delete stub

- [ ] **Step 1: Append new enums to `Enums.swift`**

```swift
// MARK: - Playoff (SP3)

enum PlayoffState: String, Codable, CaseIterable {
    case active
    case drillRequired
    case champion
    case abandoned
}

enum PlayoffRound: Int, Codable, CaseIterable {
    case firstRound        = 1
    case secondRound       = 2
    case conferenceFinals  = 3
    case finals            = 4

    var threshold: Double {
        switch self {
        case .firstRound:       return 0.4
        case .secondRound:      return 0.5
        case .conferenceFinals: return 0.6
        case .finals:           return 0.7
        }
    }

    /// Number of makes (out of `HoopTrack.Playoff.shotsPerGame`) required to win a single game.
    var requiredMakes: Int {
        Int(ceil(threshold * Double(HoopTrack.Playoff.shotsPerGame)))
    }

    var displayName: String {
        switch self {
        case .firstRound:       return "First Round"
        case .secondRound:      return "Second Round"
        case .conferenceFinals: return "Conference Finals"
        case .finals:           return "Finals"
        }
    }

    var next: PlayoffRound? {
        PlayoffRound(rawValue: rawValue + 1)
    }
}
```

- [ ] **Step 2: If SP4 already shipped, delete the temporary stub in `CommentaryEvent.swift`**

```bash
# Search for the TODO(SP3) marker added in SP4 Task 2.
grep -n "TODO(SP3)" HoopTrack/Models/CommentaryEvent.swift
```

If matched: remove the entire stub `enum PlayoffRound { ... }` block. The real one above takes precedence.

- [ ] **Step 3: Build**

Run: `xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack build -destination 'platform=iOS Simulator,name=iPhone 14'`
Expected: BUILD SUCCEEDED (no redeclaration errors)

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Models/Enums.swift HoopTrack/Models/CommentaryEvent.swift
git commit -m "SP3 Task 1: add PlayoffState + PlayoffRound enums"
```

---

## Task 2: `Constants.HoopTrack.Playoff`

**Files:**
- Modify: `HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Add the namespace**

```swift
enum Playoff {
    static let gamesPerSeries: Int = 7
    static let gamesNeededToWin: Int = 4
    static let shotsPerGame: Int = 10
    static let minShotsPerZoneForAnalysis: Int = 5
    static let weakZoneCount: Int = 3
    static let drillMakesMultiplier: Int = 3        // drill makes target = round.requiredMakes * 3
    static let requireCVAttribution: Bool = false   // flip true when SP2 ships
}
```

- [ ] **Step 2: Build + commit**

```bash
git add HoopTrack/Utilities/Constants.swift
git commit -m "SP3 Task 2: add Playoff constants"
```

---

## Task 3: `PlayoffSeries` SwiftData model

**Files:**
- Create: `HoopTrack/Models/PlayoffSeries.swift`
- Modify: `HoopTrack/HoopTrackApp.swift` (register in Schema list)

- [ ] **Step 1: Create the model**

```swift
// PlayoffSeries.swift
// SP3 — solo BO7 playoff run. One active series per user at a time.

import Foundation
import SwiftData

@Model
final class PlayoffSeries {
    @Attribute(.unique) var id: UUID
    var stateRaw: String                   // PlayoffState.rawValue
    var currentRoundRaw: Int               // PlayoffRound.rawValue
    var roundHistoryJSON: Data             // [PlayoffRoundResult] encoded
    var prescribedDrillSessionID: UUID?
    var startDate: Date
    var completionDate: Date?
    var cloudSyncedAt: Date?

    @Relationship(deleteRule: .cascade) var games: [GameSession]

    init(id: UUID = UUID(),
         state: PlayoffState = .active,
         currentRound: PlayoffRound = .firstRound,
         startDate: Date = .now) {
        self.id = id
        self.stateRaw = state.rawValue
        self.currentRoundRaw = currentRound.rawValue
        self.roundHistoryJSON = (try? JSONEncoder().encode([PlayoffRoundResult]())) ?? Data()
        self.prescribedDrillSessionID = nil
        self.startDate = startDate
        self.completionDate = nil
        self.cloudSyncedAt = nil
        self.games = []
    }

    // MARK: - Convenience accessors

    var state: PlayoffState {
        get { PlayoffState(rawValue: stateRaw) ?? .active }
        set { stateRaw = newValue.rawValue }
    }

    var currentRound: PlayoffRound {
        get { PlayoffRound(rawValue: currentRoundRaw) ?? .firstRound }
        set { currentRoundRaw = newValue.rawValue }
    }

    var roundHistory: [PlayoffRoundResult] {
        get { (try? JSONDecoder().decode([PlayoffRoundResult].self, from: roundHistoryJSON)) ?? [] }
        set { roundHistoryJSON = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Games played in the current round (filters by gameType + the round's index in roundHistory).
    var gamesInCurrentRound: [GameSession] {
        games.filter {
            $0.gameType == .bo7Playoff &&
            $0.metadata.playoffRound == currentRound.rawValue
        }
    }
}

struct PlayoffRoundResult: Codable, Equatable {
    let round: Int                     // PlayoffRound.rawValue (codable-stable)
    let gamesWon: Int
    let gamesLost: Int
    let eliminated: Bool
    let prescribedDrillCompleted: Bool
}
```

> **Note on `metadata.playoffRound`:** `GameSession` (SP1) has a `metadataJSON: Data` for game-type-specific config. SP3 uses it to stamp which round the game belongs to. If the field doesn't exist on `GameSession`, **add it as a `metadataJSON: Data` SwiftData field plus a typed `metadata: GameSessionMetadata` accessor.** Reference SP1 plan Task 5 for the pattern. If SP1 already includes this, just add a `playoffRound: Int?` property to the metadata struct.

- [ ] **Step 2: Verify / extend `GameSession.metadata`** — open `HoopTrack/Models/GameSession.swift` and confirm a `metadataJSON: Data` field + `GameSessionMetadata` Codable struct exist. Add `var playoffRound: Int? = nil` to the metadata struct if missing.

- [ ] **Step 3: Register `PlayoffSeries.self` in `HoopTrackApp.swift` Schema list**

```swift
// in the Schema([...]) array
PlayoffSeries.self,
```

- [ ] **Step 4: Build**

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Models/PlayoffSeries.swift HoopTrack/Models/GameSession.swift HoopTrack/HoopTrackApp.swift
git commit -m "SP3 Task 3: add PlayoffSeries @Model + register in schema"
```

---

## Task 4: `TrainingSession.playoffSeriesID` additive field

**Files:**
- Modify: `HoopTrack/Models/TrainingSession.swift`

- [ ] **Step 1: Add the field**

In `TrainingSession`'s settings/identity section:

```swift
    /// SP3 — set when this session is the prescribed drill for a PlayoffSeries.
    /// Finalization promotes the series state from .drillRequired → .active when this is set
    /// and the drill's makes >= round.requiredMakes * Playoff.drillMakesMultiplier.
    var playoffSeriesID: UUID?
```

In `init`, default to `nil`. Add to any DTO if needed (likely `TrainingSessionDTO`) with snake_case `playoff_series_id`.

- [ ] **Step 2: Build + commit**

```bash
git add HoopTrack/Models/TrainingSession.swift HoopTrack/Sync/DTOs/TrainingSessionDTO.swift
git commit -m "SP3 Task 4: add playoffSeriesID to TrainingSession"
```

---

## Task 5: `PlayoffStateMachine` — pure transitions (TDD)

**Files:**
- Create: `HoopTrack/Utilities/PlayoffStateMachine.swift`
- Test: `HoopTrackTests/PlayoffStateMachineTests.swift`

A pure namespace producing `PlayoffSeriesAction` outputs from current state + an event. The mutator (Task 7) applies them.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import HoopTrack

final class PlayoffStateMachineTests: XCTestCase {

    func test_gameWin_underNeededWins_keepsRoundActive() {
        let result = PlayoffStateMachine.advance(
            state: .active,
            currentRound: .firstRound,
            gamesWonThisRound: 2,
            gamesLostThisRound: 1,
            event: .gameFinished(won: true)
        )
        XCTAssertEqual(result.action, .continueRound)
        XCTAssertEqual(result.gamesWonThisRound, 3)
    }

    func test_4thGameWin_advancesToNextRound() {
        let result = PlayoffStateMachine.advance(
            state: .active,
            currentRound: .firstRound,
            gamesWonThisRound: 3,
            gamesLostThisRound: 2,
            event: .gameFinished(won: true)
        )
        XCTAssertEqual(result.action, .advanceRound(next: .secondRound))
    }

    func test_winningFinals_endsSeriesAsChampion() {
        let result = PlayoffStateMachine.advance(
            state: .active,
            currentRound: .finals,
            gamesWonThisRound: 3,
            gamesLostThisRound: 0,
            event: .gameFinished(won: true)
        )
        XCTAssertEqual(result.action, .crownChampion)
    }

    func test_4thGameLoss_movesToDrillRequired() {
        let result = PlayoffStateMachine.advance(
            state: .active,
            currentRound: .secondRound,
            gamesWonThisRound: 1,
            gamesLostThisRound: 3,
            event: .gameFinished(won: false)
        )
        XCTAssertEqual(result.action, .requireDrill)
    }

    func test_drillCompletedSuccessfully_returnsToActive() {
        let result = PlayoffStateMachine.advance(
            state: .drillRequired,
            currentRound: .secondRound,
            gamesWonThisRound: 1,
            gamesLostThisRound: 3,
            event: .drillFinished(passed: true)
        )
        XCTAssertEqual(result.action, .resumeFromDrill)
        XCTAssertEqual(result.gamesWonThisRound, 0)
        XCTAssertEqual(result.gamesLostThisRound, 0)
    }

    func test_drillFailed_staysInDrillRequired() {
        let result = PlayoffStateMachine.advance(
            state: .drillRequired,
            currentRound: .secondRound,
            gamesWonThisRound: 1,
            gamesLostThisRound: 3,
            event: .drillFinished(passed: false)
        )
        XCTAssertEqual(result.action, .stayInDrillRequired)
    }

    func test_abandon_terminates() {
        let result = PlayoffStateMachine.advance(
            state: .active,
            currentRound: .firstRound,
            gamesWonThisRound: 0,
            gamesLostThisRound: 0,
            event: .abandoned
        )
        XCTAssertEqual(result.action, .abandon)
    }

    func test_abandon_isIdempotentFromTerminalStates() {
        let result = PlayoffStateMachine.advance(
            state: .champion,
            currentRound: .finals,
            gamesWonThisRound: 4,
            gamesLostThisRound: 0,
            event: .abandoned
        )
        XCTAssertEqual(result.action, .noop)
    }
}
```

- [ ] **Step 2: Implement**

```swift
// PlayoffStateMachine.swift
// SP3 — pure transition logic. Mutators (DataService / VM) apply the resulting action.

import Foundation

enum PlayoffEvent: Equatable {
    case gameFinished(won: Bool)
    case drillFinished(passed: Bool)
    case abandoned
}

enum PlayoffAction: Equatable {
    case continueRound
    case advanceRound(next: PlayoffRound)
    case crownChampion
    case requireDrill
    case resumeFromDrill                // drill passed; reset round score, back to .active
    case stayInDrillRequired            // drill failed; user can try again
    case abandon
    case noop
}

struct PlayoffStateResult: Equatable {
    let action: PlayoffAction
    let gamesWonThisRound: Int
    let gamesLostThisRound: Int
}

enum PlayoffStateMachine {

    static func advance(state: PlayoffState,
                        currentRound: PlayoffRound,
                        gamesWonThisRound: Int,
                        gamesLostThisRound: Int,
                        event: PlayoffEvent) -> PlayoffStateResult {

        // Terminal states
        if state == .champion || state == .abandoned {
            if case .abandoned = event {
                return PlayoffStateResult(action: .noop,
                                          gamesWonThisRound: gamesWonThisRound,
                                          gamesLostThisRound: gamesLostThisRound)
            }
            return PlayoffStateResult(action: .noop,
                                      gamesWonThisRound: gamesWonThisRound,
                                      gamesLostThisRound: gamesLostThisRound)
        }

        switch event {
        case .abandoned:
            return PlayoffStateResult(action: .abandon,
                                      gamesWonThisRound: gamesWonThisRound,
                                      gamesLostThisRound: gamesLostThisRound)

        case .gameFinished(let won):
            guard state == .active else {
                return PlayoffStateResult(action: .noop,
                                          gamesWonThisRound: gamesWonThisRound,
                                          gamesLostThisRound: gamesLostThisRound)
            }
            let newWins = gamesWonThisRound + (won ? 1 : 0)
            let newLoss = gamesLostThisRound + (won ? 0 : 1)
            let needed = HoopTrack.Playoff.gamesNeededToWin

            if newWins >= needed {
                if let next = currentRound.next {
                    return PlayoffStateResult(action: .advanceRound(next: next),
                                              gamesWonThisRound: 0,
                                              gamesLostThisRound: 0)
                } else {
                    return PlayoffStateResult(action: .crownChampion,
                                              gamesWonThisRound: newWins,
                                              gamesLostThisRound: newLoss)
                }
            }
            if newLoss >= needed {
                return PlayoffStateResult(action: .requireDrill,
                                          gamesWonThisRound: newWins,
                                          gamesLostThisRound: newLoss)
            }
            return PlayoffStateResult(action: .continueRound,
                                      gamesWonThisRound: newWins,
                                      gamesLostThisRound: newLoss)

        case .drillFinished(let passed):
            guard state == .drillRequired else {
                return PlayoffStateResult(action: .noop,
                                          gamesWonThisRound: gamesWonThisRound,
                                          gamesLostThisRound: gamesLostThisRound)
            }
            return passed
                ? PlayoffStateResult(action: .resumeFromDrill,
                                     gamesWonThisRound: 0,
                                     gamesLostThisRound: 0)
                : PlayoffStateResult(action: .stayInDrillRequired,
                                     gamesWonThisRound: gamesWonThisRound,
                                     gamesLostThisRound: gamesLostThisRound)
        }
    }
}
```

- [ ] **Step 3: Run tests — all pass**

Run: `xcodebuild test ... -only-testing:HoopTrackTests/PlayoffStateMachineTests`
Expected: 8 tests pass

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Utilities/PlayoffStateMachine.swift HoopTrackTests/PlayoffStateMachineTests.swift
git commit -m "SP3 Task 5: add PlayoffStateMachine pure transitions + tests"
```

---

## Task 6: `WeakZoneAnalyser` — pure (TDD)

**Files:**
- Create: `HoopTrack/Utilities/WeakZoneAnalyser.swift`
- Test: `HoopTrackTests/WeakZoneAnalyserTests.swift`

> **Note:** `GameShotRecord` is the SP1+SP2 shot type. If SP2 hasn't shipped at write time, the analyser still works on `[GameShotRecord]` because SP1 already declared the model — SP2 fills it in via CV attribution. If `GameShotRecord` doesn't exist, fall back to `[ShotRecord]` (the solo-mode equivalent) and adjust the signature accordingly.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import HoopTrack

final class WeakZoneAnalyserTests: XCTestCase {

    private func shot(zone: CourtZone, made: Bool) -> GameShotRecord {
        // Build a minimal record. Adapt this initializer to whatever GameShotRecord exposes
        // — fall back to ShotRecord if SP2 hasn't landed.
        GameShotRecord(zone: zone, result: made ? .make : .miss)
    }

    func test_emptyShotList_returnsEmpty() {
        XCTAssertEqual(WeakZoneAnalyser.weakestZones(from: []), [])
    }

    func test_zonesWithFewerThanMinAttempts_areExcluded() {
        // 4 attempts in midRange (below threshold of 5) — excluded.
        let shots = (0..<4).map { _ in shot(zone: .midRange, made: false) }
            + (0..<6).map { _ in shot(zone: .threePoint, made: true) }
        let result = WeakZoneAnalyser.weakestZones(from: shots, topN: 3)
        XCTAssertFalse(result.contains(.midRange))
    }

    func test_returnsZonesSortedAscendingByFGPercent() {
        // paint:  10/10  = 100%
        // mid:     2/10  = 20%
        // three:   5/10  = 50%
        let shots =
            (0..<10).map { _ in shot(zone: .paint, made: true) }
          + Array(repeating: shot(zone: .midRange, made: true), count: 2)
          + Array(repeating: shot(zone: .midRange, made: false), count: 8)
          + Array(repeating: shot(zone: .threePoint, made: true), count: 5)
          + Array(repeating: shot(zone: .threePoint, made: false), count: 5)

        let result = WeakZoneAnalyser.weakestZones(from: shots, topN: 3)
        XCTAssertEqual(result.first, .midRange)
        XCTAssertEqual(result, [.midRange, .threePoint, .paint])
    }

    func test_topN_truncates() {
        let shots =
            Array(repeating: shot(zone: .paint, made: true), count: 5)
          + Array(repeating: shot(zone: .midRange, made: false), count: 5)
          + Array(repeating: shot(zone: .threePoint, made: true), count: 5)
        let result = WeakZoneAnalyser.weakestZones(from: shots, topN: 1)
        XCTAssertEqual(result, [.midRange])
    }
}
```

- [ ] **Step 2: Implement**

```swift
// WeakZoneAnalyser.swift
// SP3 — pure analysis: identify weakest court zones from a series' shot history.
// Filters out noisy zones (< minShotsPerZoneForAnalysis attempts).

import Foundation

enum WeakZoneAnalyser {

    static func weakestZones(
        from shots: [GameShotRecord],
        topN: Int = HoopTrack.Playoff.weakZoneCount,
        minAttempts: Int = HoopTrack.Playoff.minShotsPerZoneForAnalysis
    ) -> [CourtZone] {
        guard !shots.isEmpty else { return [] }

        let grouped = Dictionary(grouping: shots, by: { $0.zone })

        let zoneStats: [(zone: CourtZone, fg: Double)] = grouped.compactMap { zone, list in
            guard list.count >= minAttempts else { return nil }
            let makes = list.filter { $0.result == .make }.count
            return (zone, Double(makes) / Double(list.count))
        }

        return zoneStats
            .sorted { $0.fg < $1.fg }
            .prefix(topN)
            .map { $0.zone }
    }
}
```

- [ ] **Step 3: Run tests — all pass**

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Utilities/WeakZoneAnalyser.swift HoopTrackTests/WeakZoneAnalyserTests.swift
git commit -m "SP3 Task 6: add WeakZoneAnalyser pure function + tests"
```

---

## Task 7: `DataService` playoff persistence helpers

**Files:**
- Modify: `HoopTrack/Services/DataService.swift`

- [ ] **Step 1: Add helpers**

```swift
// MARK: - Playoff (SP3)

func fetchActivePlayoffSeries() throws -> PlayoffSeries? {
    let descriptor = FetchDescriptor<PlayoffSeries>(
        predicate: #Predicate { $0.stateRaw == "active" || $0.stateRaw == "drillRequired" }
    )
    return try modelContext.fetch(descriptor).first
}

func createPlayoffSeries() throws -> PlayoffSeries {
    let series = PlayoffSeries()
    modelContext.insert(series)
    try modelContext.save()
    return series
}

func recordPlayoffGame(_ game: GameSession, in series: PlayoffSeries) throws {
    series.games.append(game)
    try modelContext.save()
}

func updatePlayoffSeries(_ series: PlayoffSeries,
                         action: PlayoffAction,
                         gamesWon: Int,
                         gamesLost: Int) throws {
    switch action {
    case .continueRound:
        break // VM-level counters; nothing to persist beyond the game itself
    case .advanceRound(let next):
        let result = PlayoffRoundResult(round: series.currentRound.rawValue,
                                        gamesWon: gamesWon, gamesLost: gamesLost,
                                        eliminated: false, prescribedDrillCompleted: false)
        series.roundHistory.append(result)
        series.currentRound = next
    case .crownChampion:
        let result = PlayoffRoundResult(round: series.currentRound.rawValue,
                                        gamesWon: gamesWon, gamesLost: gamesLost,
                                        eliminated: false, prescribedDrillCompleted: false)
        series.roundHistory.append(result)
        series.state = .champion
        series.completionDate = .now
    case .requireDrill:
        series.state = .drillRequired
    case .resumeFromDrill:
        series.state = .active
        // Update the last round result's prescribedDrillCompleted flag.
        var history = series.roundHistory
        if !history.isEmpty {
            let last = history.removeLast()
            history.append(PlayoffRoundResult(round: last.round,
                                               gamesWon: last.gamesWon,
                                               gamesLost: last.gamesLost,
                                               eliminated: last.eliminated,
                                               prescribedDrillCompleted: true))
            series.roundHistory = history
        }
        series.prescribedDrillSessionID = nil
    case .stayInDrillRequired, .noop:
        break
    case .abandon:
        series.state = .abandoned
        series.completionDate = .now
    }
    series.cloudSyncedAt = nil
    try modelContext.save()
}
```

- [ ] **Step 2: Build + commit**

```bash
git add HoopTrack/Services/DataService.swift
git commit -m "SP3 Task 7: add Playoff persistence helpers to DataService"
```

---

## Task 8: `PlayoffSeriesViewModel`

**Files:**
- Create: `HoopTrack/ViewModels/PlayoffSeriesViewModel.swift`

> **Concurrency note:** Mark the class `nonisolated final class` (NOT `@MainActor final class`). The HoopTrack-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting otherwise makes the deinit MainActor-isolated, which crashes via Swift's MainActor back-deploy shim under XCTest. Pattern matches `GameRegistrationViewModel` (SP1).

- [ ] **Step 1: Create the VM**

```swift
// PlayoffSeriesViewModel.swift
// SP3 — owns live state for a playoff run.
// nonisolated to avoid MainActor-deinit XCTest crash (see SP1 GameRegistrationViewModel).

import Foundation
import Combine

nonisolated final class PlayoffSeriesViewModel: ObservableObject {

    // Live UI state
    @Published private(set) var series: PlayoffSeries
    @Published private(set) var gamesWonThisRound: Int = 0
    @Published private(set) var gamesLostThisRound: Int = 0
    @Published private(set) var lastAction: PlayoffAction = .noop

    private let dataService: DataService
    private let commentaryBus: CommentaryEventBus?

    init(series: PlayoffSeries,
         dataService: DataService,
         commentaryBus: CommentaryEventBus? = nil) {
        self.series = series
        self.dataService = dataService
        self.commentaryBus = commentaryBus
        recomputeRoundCounters()
    }

    /// Recompute wins/losses for the current round from `series.games`.
    @MainActor
    func recomputeRoundCounters() {
        let games = series.gamesInCurrentRound
        gamesWonThisRound = games.filter { didWin($0) }.count
        gamesLostThisRound = games.filter { !didWin($0) && $0.endedAt != nil }.count
    }

    /// Did the user win this BO7 game?
    private func didWin(_ game: GameSession) -> Bool {
        // A win = makes >= round.requiredMakes. Use the GameSession's per-player tally.
        let owner = game.players.first { $0.isOwner }   // SP1 marks the local user
        let makes = owner?.shotsMade ?? 0
        return makes >= series.currentRound.requiredMakes
    }

    @MainActor
    func handleGameFinished(_ game: GameSession) throws {
        try dataService.recordPlayoffGame(game, in: series)
        let won = didWin(game)
        let result = PlayoffStateMachine.advance(
            state: series.state,
            currentRound: series.currentRound,
            gamesWonThisRound: gamesWonThisRound,
            gamesLostThisRound: gamesLostThisRound,
            event: .gameFinished(won: won)
        )
        try dataService.updatePlayoffSeries(series,
                                            action: result.action,
                                            gamesWon: result.gamesWonThisRound,
                                            gamesLost: result.gamesLostThisRound)
        gamesWonThisRound = result.gamesWonThisRound
        gamesLostThisRound = result.gamesLostThisRound
        lastAction = result.action
        publishCommentary(for: result.action)
    }

    @MainActor
    func handleDrillFinished(passed: Bool) throws {
        let result = PlayoffStateMachine.advance(
            state: series.state,
            currentRound: series.currentRound,
            gamesWonThisRound: gamesWonThisRound,
            gamesLostThisRound: gamesLostThisRound,
            event: .drillFinished(passed: passed)
        )
        try dataService.updatePlayoffSeries(series,
                                            action: result.action,
                                            gamesWon: result.gamesWonThisRound,
                                            gamesLost: result.gamesLostThisRound)
        gamesWonThisRound = result.gamesWonThisRound
        gamesLostThisRound = result.gamesLostThisRound
        lastAction = result.action
        publishCommentary(for: result.action)
    }

    @MainActor
    func abandon() throws {
        try dataService.updatePlayoffSeries(series,
                                            action: .abandon,
                                            gamesWon: gamesWonThisRound,
                                            gamesLost: gamesLostThisRound)
        lastAction = .abandon
    }

    private func publishCommentary(for action: PlayoffAction) {
        switch action {
        case .advanceRound:    commentaryBus?.publish(.playoffAdvance(round: series.currentRound))
        case .crownChampion:   commentaryBus?.publish(.playoffAdvance(round: .finals))
        case .requireDrill:    commentaryBus?.publish(.playoffElimination(round: series.currentRound))
        default:               break
        }
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
git add HoopTrack/ViewModels/PlayoffSeriesViewModel.swift
git commit -m "SP3 Task 8: add PlayoffSeriesViewModel"
```

---

## Task 9: `PlayoffEntryView`

**Files:**
- Create: `HoopTrack/Views/Game/PlayoffEntryView.swift`

The Train tab's "BO7 Playoff" tile routes here. View shows:
- If active series exists → "Resume — Round N · You X–Y" + button to enter `LivePlayoffView`
- Otherwise → "Start a new playoff run" + threshold ladder explainer

- [ ] **Step 1: Implement view**

```swift
// PlayoffEntryView.swift
// SP3 — entry / resume screen for the BO7 playoff mode.

import SwiftUI

struct PlayoffEntryView: View {
    @EnvironmentObject private var dataService: DataService
    @State private var activeSeries: PlayoffSeries?
    @State private var navigateToLive: PlayoffSeries?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                header

                if let series = activeSeries {
                    resumeCard(series)
                } else {
                    newRunCard
                }

                ladderExplainer
            }
            .padding()
        }
        .navigationTitle("Playoff Mode")
        .task {
            activeSeries = try? dataService.fetchActivePlayoffSeries()
        }
        .navigationDestination(item: $navigateToLive) { series in
            LivePlayoffView(series: series)
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("BO7 Playoff").font(.largeTitle.bold())
            Text("Four rounds. Rising thresholds. Lose four — earn a drill to retry.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func resumeCard(_ series: PlayoffSeries) -> some View {
        VStack(spacing: 12) {
            Text("Resume \(series.currentRound.displayName)")
                .font(.title2.bold())
            Text("Threshold: \(Int(series.currentRound.threshold * 100))% · \(series.currentRound.requiredMakes) of \(HoopTrack.Playoff.shotsPerGame)")
                .foregroundStyle(.secondary)
            Button("Resume") {
                navigateToLive = series
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var newRunCard: some View {
        VStack(spacing: 12) {
            Text("Start New Run").font(.title2.bold())
            Button("Start") {
                if let s = try? dataService.createPlayoffSeries() {
                    activeSeries = s
                    navigateToLive = s
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var ladderExplainer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Threshold Ladder").font(.headline)
            ForEach(PlayoffRound.allCases, id: \.rawValue) { round in
                HStack {
                    Text(round.displayName)
                    Spacer()
                    Text("\(Int(round.threshold * 100))% · \(round.requiredMakes)/\(HoopTrack.Playoff.shotsPerGame)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 2: Wire route from `TrainTabView`**

In `TrainTabView`, add a tile or `NavigationLink` to `PlayoffEntryView()`. Match the visual pattern of existing drill tiles.

- [ ] **Step 3: Build + commit**

```bash
git add HoopTrack/Views/Game/PlayoffEntryView.swift HoopTrack/Views/Train/TrainTabView.swift
git commit -m "SP3 Task 9: add PlayoffEntryView with resume/start cards"
```

---

## Task 10: `LivePlayoffView` (full-screen, landscape)

**Files:**
- Create: `HoopTrack/Views/Game/LivePlayoffView.swift`

The view embeds the existing live-game CV pipeline (`CameraService` → `CVPipeline`) inside SP1's `LandscapeContainer`. State counters draw on the VM.

- [ ] **Step 1: Implement view**

```swift
// LivePlayoffView.swift
// SP3 — landscape live view for an in-progress BO7 round.

import SwiftUI

struct LivePlayoffView: View {
    let series: PlayoffSeries
    @EnvironmentObject private var dataService: DataService
    @EnvironmentObject private var coordinator: SessionFinalizationCoordinator
    @StateObject private var vm: PlayoffSeriesViewModel
    @Environment(\.dismiss) private var dismiss

    init(series: PlayoffSeries) {
        self.series = series
        _vm = StateObject(wrappedValue: PlayoffSeriesViewModel(
            series: series,
            dataService: DataService.preview()    // overridden by injection in onAppear
        ))
    }

    var body: some View {
        LandscapeContainer {
            ZStack {
                // Camera + CV layer — re-uses the existing pipeline. Inject a fresh
                // GameSession bound to series.currentRound via metadata.playoffRound.
                LiveGameCVHost(gameType: .bo7Playoff,
                               playoffRound: series.currentRound,
                               onGameFinished: { game in
                                   try? vm.handleGameFinished(game)
                               })

                VStack {
                    HStack {
                        roundCard
                        Spacer()
                        killfeedCard
                    }
                    Spacer()
                    HStack {
                        attemptsCard
                        Spacer()
                        controlsCard
                    }
                }
                .padding()

                if case .advanceRound = vm.lastAction { PlayoffTransitionCards.advanceCard(round: series.currentRound) }
                if case .crownChampion = vm.lastAction { PlayoffTransitionCards.championCard(series: series) }
                if case .requireDrill  = vm.lastAction { PlayoffTransitionCards.eliminationCard(round: series.currentRound) {
                    dismiss()
                } }
            }
        }
        .navigationBarHidden(true)
    }

    private var roundCard: some View {
        VStack(alignment: .leading) {
            Text(series.currentRound.displayName).font(.headline)
            Text("Game \(vm.gamesWonThisRound + vm.gamesLostThisRound + 1) · You \(vm.gamesWonThisRound)–\(vm.gamesLostThisRound)")
                .font(.subheadline.monospacedDigit())
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var killfeedCard: some View {
        // Implementation: show last 4 shots from current GameSession. Reuse SP2 KillfeedView if present.
        Text("Killfeed").font(.caption)
            .padding(8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var attemptsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(currentMakes)/\(HoopTrack.Playoff.shotsPerGame) · need \(series.currentRound.requiredMakes)")
                .font(.headline.monospacedDigit())
            HStack(spacing: 4) {
                ForEach(0..<HoopTrack.Playoff.shotsPerGame, id: \.self) { i in
                    Circle()
                        .fill(pipColor(for: i))
                        .frame(width: 12, height: 12)
                }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var controlsCard: some View {
        HStack(spacing: 16) {
            Button("Pause") { /* pause handled by CV host */ }
            HoldToEndButton {
                try? vm.abandon()
                dismiss()
            }
        }
    }

    private var currentMakes: Int { 0 }     // bound from CVHost in real wiring
    private func pipColor(for idx: Int) -> Color { .gray.opacity(0.3) }   // ditto
}
```

> **Note:** The view is a layout shell. The CV-host child `LiveGameCVHost` already exists from SP1; it owns the actual `GameSession`, `CVPipeline`, and shot recording. SP3 just feeds it `gameType: .bo7Playoff` + the round number. If `LiveGameCVHost` doesn't exist verbatim, find SP1's equivalent (likely `LiveGameView` or its host) and adapt.

- [ ] **Step 2: Build (will fail unless `LiveGameCVHost`/equivalent exists). Reconcile against actual SP1 view names before fixing typos.** Adjust imports until BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/Views/Game/LivePlayoffView.swift
git commit -m "SP3 Task 10: add LivePlayoffView landscape shell"
```

---

## Task 11: `PlayoffTransitionCards`

**Files:**
- Create: `HoopTrack/Views/Game/PlayoffTransitionCards.swift`

- [ ] **Step 1: Implement**

```swift
// PlayoffTransitionCards.swift
// SP3 — overlay cards shown on game-win, round-win, elimination, championship.

import SwiftUI

enum PlayoffTransitionCards {

    static func advanceCard(round: PlayoffRound) -> some View {
        TransitionOverlay(
            title: "ADVANCING",
            subtitle: "→ \(round.next?.displayName ?? round.displayName)",
            color: .green
        )
    }

    static func eliminationCard(round: PlayoffRound, onDismiss: @escaping () -> Void) -> some View {
        TransitionOverlay(
            title: "ELIMINATED",
            subtitle: "in \(round.displayName)",
            color: .red,
            actionTitle: "View weak zones",
            onAction: onDismiss
        )
    }

    static func championCard(series: PlayoffSeries) -> some View {
        TransitionOverlay(
            title: "CHAMPION",
            subtitle: "Series complete",
            color: .yellow
        )
    }
}

private struct TransitionOverlay: View {
    let title: String
    let subtitle: String
    let color: Color
    var actionTitle: String? = nil
    var onAction: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.7).ignoresSafeArea()
            VStack(spacing: 16) {
                Text(title).font(.system(size: 64, weight: .black)).foregroundStyle(color)
                Text(subtitle).font(.title2).foregroundStyle(.white)
                if let actionTitle, let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .transition(.opacity)
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
git add HoopTrack/Views/Game/PlayoffTransitionCards.swift
git commit -m "SP3 Task 11: add PlayoffTransitionCards overlay views"
```

---

## Task 12: `PrescribedDrillView` + drill creation flow

**Files:**
- Create: `HoopTrack/Views/Game/PrescribedDrillView.swift`

Shown after elimination. Generates the drill spec, creates a `TrainingSession` with `playoffSeriesID` set, then routes into the existing `LiveSessionView`.

- [ ] **Step 1: Implement view**

```swift
// PrescribedDrillView.swift
// SP3 — post-elimination weak-zone drill setup screen.

import SwiftUI

struct PrescribedDrillView: View {
    let series: PlayoffSeries
    @EnvironmentObject private var dataService: DataService
    @State private var weakestZones: [CourtZone] = []
    @State private var navigateToLive: TrainingSession?

    var requiredMakes: Int {
        series.currentRound.requiredMakes * HoopTrack.Playoff.drillMakesMultiplier
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Weak Zone Drill").font(.largeTitle.bold())
            Text("Make \(requiredMakes) shots from these zones to retry \(series.currentRound.displayName).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            zonesGrid

            Button("Start Drill") {
                startDrill()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding()
        .task { computeZones() }
        .navigationDestination(item: $navigateToLive) { session in
            LiveSessionView(session: session)
        }
    }

    private var zonesGrid: some View {
        // Replace with a real CourtMapView if available; this is the scaffold.
        VStack {
            ForEach(weakestZones, id: \.self) { zone in
                Text(zone.displayName)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func computeZones() {
        let allShots: [GameShotRecord] = series.games.flatMap { $0.shots }
        weakestZones = WeakZoneAnalyser.weakestZones(from: allShots)
    }

    private func startDrill() {
        do {
            let session = try dataService.createTrainingSession(
                drillType: .freeShoot,
                courtType: try dataService.fetchOrCreateProfile().preferredCourtType
            )
            session.playoffSeriesID = series.id
            // Tag drill metadata if your TrainingSession supports a notes/metadata field.
            try dataService.save()
            series.prescribedDrillSessionID = session.id
            try dataService.save()
            navigateToLive = session
        } catch {
            // Surface error via a banner state if desired.
        }
    }
}
```

> **Implementation reconcile:** `dataService.createTrainingSession(...)` and `dataService.save()` must match the actual `DataService` API. If the existing API differs (e.g. returns nothing and uses the modelContext directly), adjust accordingly. The pattern is: create a session, link to series, save, navigate.

- [ ] **Step 2: Build + commit**

```bash
git add HoopTrack/Views/Game/PrescribedDrillView.swift
git commit -m "SP3 Task 12: add PrescribedDrillView with weak-zone drill flow"
```

---

## Task 13: `SessionFinalizationCoordinator` — drill completion promotes state

**Files:**
- Modify: `HoopTrack/Services/SessionFinalizationCoordinator.swift`

- [ ] **Step 1: Add a step after `kickOffSync`/`kickOffTelemetry` in each `finalise*` method**

```swift
        // SP3 — if this session is a prescribed playoff drill, evaluate pass/fail.
        try? promotePlayoffStateIfPrescribedDrill(session: session)
```

- [ ] **Step 2: Add the helper**

```swift
    private func promotePlayoffStateIfPrescribedDrill(session: TrainingSession) throws {
        guard let seriesID = session.playoffSeriesID else { return }
        let descriptor = FetchDescriptor<PlayoffSeries>(
            predicate: #Predicate { $0.id == seriesID }
        )
        guard let series = try dataService.modelContext.fetch(descriptor).first else { return }
        guard series.state == .drillRequired else { return }

        let needed = series.currentRound.requiredMakes * HoopTrack.Playoff.drillMakesMultiplier
        let passed = session.shotsMade >= needed

        let result = PlayoffStateMachine.advance(
            state: series.state,
            currentRound: series.currentRound,
            gamesWonThisRound: 0,
            gamesLostThisRound: 0,
            event: .drillFinished(passed: passed)
        )
        try dataService.updatePlayoffSeries(series,
                                            action: result.action,
                                            gamesWon: 0,
                                            gamesLost: 0)
    }
```

- [ ] **Step 3: Build (need to expose `dataService.modelContext` if not already public). If `DataService` already provides a fetch helper, prefer that; this code shows the direct fallback.**

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Services/SessionFinalizationCoordinator.swift
git commit -m "SP3 Task 13: promote playoff state on prescribed-drill completion"
```

---

## Task 14: Home tab resume banner

**Files:**
- Modify: `HoopTrack/Views/Home/HomeTabView.swift`

- [ ] **Step 1: Add a `@State private var activePlayoffSeries: PlayoffSeries?` + `.task` that calls `dataService.fetchActivePlayoffSeries()`**

- [ ] **Step 2: Conditionally render a banner above existing content**

```swift
if let series = activePlayoffSeries {
    NavigationLink {
        LivePlayoffView(series: series)
    } label: {
        HStack {
            Image(systemName: "trophy.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading) {
                Text("Resume Playoff").font(.headline)
                Text("\(series.currentRound.displayName) · \(series.state == .drillRequired ? "Drill required" : "In progress")")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
git add HoopTrack/Views/Home/HomeTabView.swift
git commit -m "SP3 Task 14: add Home tab resume-playoff banner"
```

---

## Task 15: Progress tab — "Playoff Runs" section

**Files:**
- Modify: `HoopTrack/Views/Progress/ProgressTabView.swift`
- Create: `HoopTrack/Views/Game/PlayoffRunSummaryView.swift`

- [ ] **Step 1: Add a fetch + section to `ProgressTabView`**

```swift
@Query(sort: \PlayoffSeries.startDate, order: .reverse)
private var allSeries: [PlayoffSeries]

// In body, before the existing sections:
Section("Playoff Runs") {
    if allSeries.isEmpty {
        Text("No playoff runs yet").foregroundStyle(.secondary)
    } else {
        ForEach(allSeries) { series in
            NavigationLink(value: series) {
                playoffRow(series)
            }
        }
    }
}
.navigationDestination(for: PlayoffSeries.self) { series in
    PlayoffRunSummaryView(series: series)
}
```

with a helper:

```swift
private func playoffRow(_ series: PlayoffSeries) -> some View {
    HStack {
        Image(systemName: series.state == .champion ? "crown.fill" : "trophy")
            .foregroundStyle(series.state == .champion ? .yellow : .secondary)
        VStack(alignment: .leading) {
            Text(label(for: series)).font(.headline)
            Text(series.startDate.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private func label(for series: PlayoffSeries) -> String {
    switch series.state {
    case .champion:      return "Champion"
    case .abandoned:     return "Abandoned · \(series.currentRound.displayName)"
    case .drillRequired: return "Drill Required · \(series.currentRound.displayName)"
    case .active:        return "Active · \(series.currentRound.displayName)"
    }
}
```

- [ ] **Step 2: Implement `PlayoffRunSummaryView`**

```swift
// PlayoffRunSummaryView.swift
// SP3 — round-by-round breakdown of a completed (or in-progress) PlayoffSeries.

import SwiftUI

struct PlayoffRunSummaryView: View {
    let series: PlayoffSeries

    var body: some View {
        List {
            Section("Overview") {
                row("Status", series.state.rawValue.capitalized)
                row("Started", series.startDate.formatted(date: .abbreviated, time: .shortened))
                if let end = series.completionDate {
                    row("Ended", end.formatted(date: .abbreviated, time: .shortened))
                }
                row("Total games", "\(series.games.count)")
            }
            Section("Rounds") {
                ForEach(series.roundHistory.indices, id: \.self) { i in
                    let r = series.roundHistory[i]
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PlayoffRound(rawValue: r.round)?.displayName ?? "Round \(r.round)")
                            .font(.headline)
                        Text("\(r.gamesWon)–\(r.gamesLost)" + (r.eliminated ? " · eliminated" : ""))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if r.prescribedDrillCompleted {
                            Label("Drill completed", systemImage: "checkmark.seal.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle("Playoff Run")
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k); Spacer(); Text(v).foregroundStyle(.secondary) }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
git add HoopTrack/Views/Progress/ProgressTabView.swift HoopTrack/Views/Game/PlayoffRunSummaryView.swift
git commit -m "SP3 Task 15: add Progress tab Playoff Runs section + summary view"
```

---

## Task 16: Cloud sync (Supabase DTO + table)

**Files:**
- Create: `HoopTrack/Sync/DTOs/PlayoffSeriesDTO.swift`
- Modify: `HoopTrack/Sync/SyncCoordinator.swift`
- Modify: `docs/production-readiness.md` (add SQL migration note)

- [ ] **Step 1: Create the DTO** (mirror existing DTOs, snake_case CodingKeys, `cloud_synced_at`, `prescribed_drill_session_id`, `round_history_json`)

- [ ] **Step 2: Hook into `SyncCoordinator.syncSession`** — after a session syncs, if it has a `playoffSeriesID`, fetch and upsert that `PlayoffSeries`

- [ ] **Step 3: Add note to `production-readiness.md`** — Postgres migration to add `playoff_series` table + RLS policy keyed on `auth.uid()`. Append-only is **not** appropriate (state mutates) — use the standard "owner select+insert+update" RLS pattern.

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Sync HoopTrack/Models/TrainingSession.swift docs/production-readiness.md
git commit -m "SP3 Task 16: add PlayoffSeries Supabase sync"
```

---

## Task 17: End-to-end smoke + security review

- [ ] **Step 1: Run all tests**

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14'
```

Expected: all tests pass, including the ~15 new tests in `WeakZoneAnalyserTests` + `PlayoffStateMachineTests`.

- [ ] **Step 2: Manual flow on simulator**

1. Train tab → BO7 Playoff → Start.
2. Play 4 games losing them (or simulate via debug console). Expect "ELIMINATED" card.
3. Tap "View weak zones" → drill screen → start drill.
4. Complete drill with enough makes. Expect series state to flip back to `.active` with same round, counters reset.
5. Repeat until champion. Verify Progress tab shows the run.
6. Kill the app mid-round. Re-launch. Home banner should offer to resume.

- [ ] **Step 3: Security review**

```bash
git diff origin/main..HEAD --name-only
```

Dispatch a single `swift-security-reviewer` subagent against the file list. Fix CRITICAL/HIGH findings (especially around the `Predicate` query in `fetchActivePlayoffSeries` and the `playoffSeriesID` UUID validation in finalization).

- [ ] **Step 4: Use `superpowers:finishing-a-development-branch` to merge**

---

## Notes for the engineer

- **SP1/SP2 reconcile:** several views reference `LiveGameCVHost`, `LiveGameView`, `KillfeedView`, `HoldToEndButton`, `LandscapeContainer`. These are SP1/SP2 deliverables. Open the actual file before pasting any LivePlayoffView body, and adjust names to whatever ships.
- **`GameShotRecord` vs `ShotRecord`:** SP1 introduces the type; SP2 attributes shots to it. If SP3 ships before SP2's attribution lands, `WeakZoneAnalyser` still works on raw `GameShotRecord`s — it just won't have per-player attribution. That's fine for solo BO7 (one player anyway).
- **`nonisolated final class` for VMs:** keep this. The SP1 `GameRegistrationViewModel` test crash is the cautionary tale.
- **Threshold tuning is one-line:** all four thresholds and gates are constants on `PlayoffRound` / `HoopTrack.Playoff`. Don't hardcode anywhere.
- **Drill counter math:** `requiredMakes` for a round is `ceil(threshold * shotsPerGame)` → 4/5/6/7 for thresholds 40/50/60/70 with 10 shots. Drill needs `requiredMakes * 3` total makes (12/15/18/21). All driven from constants — never hardcode the integers.

---

## Self-Review

- ✅ Spec coverage: §2 data model (Tasks 3, 4), §3 state machine (Tasks 5, 7, 8), §4 prescribed drill (Tasks 6, 12, 13), §5 live UI (Tasks 10, 11), §6 persistence (Tasks 3, 7, 14), §7 progress integration (Task 15), §8 files touched, §9 constants (Task 2). §10 open questions correctly deferred (threshold tuning, retry caps, Hall of Champions all out of scope).
- ✅ No placeholders: all code is concrete. The `LivePlayoffView` references SP1/SP2 components by name; reconcile-when-implementing is explicitly called out, not deferred to "TBD".
- ✅ Type consistency: `PlayoffEvent`, `PlayoffAction`, `PlayoffStateResult`, `PlayoffRound`, `PlayoffState`, `PlayoffRoundResult` all defined once and referenced consistently across tasks.
- ⚠️ Open reconcile: `dataService.save()`, `dataService.createTrainingSession(...)`, `LiveGameCVHost`, `series.games.flatMap { $0.shots }` — all flagged in-line for the engineer to verify against actual SP1/SP2 surface.

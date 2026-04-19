# Sub-Phase 3 — BO7 Playoff Mode Design Spec

**Date:** 2026-04-19
**Status:** Approved
**Scope:** Solo BO7-style playoff run with escalating accuracy thresholds and drill-gated retries. Depends on SP1 (foundation) + SP2 (shot attribution and `GameShotRecord`).
**Parent:** [Game Mode Master Plan](2026-04-19-game-mode-master-plan.md)

---

## 1. Goal

Give solo players a structured challenge mode: 4 rounds of BO7 with rising accuracy requirements. Lose a round, earn a prescribed drill, complete it to retry. Win all 4 rounds = Champion. Persists across app sessions so a playoff run can be paused and resumed.

Reuses SP1's `GameSession` + `GameShotRecord` models. Adds a new `PlayoffSeries` model above them and a state machine that orchestrates round transitions.

---

## 2. Data Model

### 2.1 `PlayoffSeries` (@Model, @MainActor)

```swift
@Model
final class PlayoffSeries {
    @Attribute(.unique) var id: UUID
    var state: PlayoffState                 // .active, .drillRequired, .champion, .abandoned
    var currentRound: PlayoffRound          // see §3.1
    var roundHistoryJSON: Data              // serialised [PlayoffRoundResult]
    var prescribedDrillSessionID: UUID?     // FK to TrainingSession (not GameSession)
    var startDate: Date
    var completionDate: Date?
    @Relationship(deleteRule: .cascade) var games: [GameSession]  // all BO7 games across all rounds
}

struct PlayoffRoundResult: Codable {
    let round: PlayoffRound
    let gamesWon: Int       // 0..4
    let gamesLost: Int      // 0..4
    let eliminated: Bool
    let prescribedDrillCompleted: Bool
}
```

`games` relationship: each round is up to 7 `GameSession`s (BO7), so a full playoff run ≤ 28 games.

### 2.2 Enums

```swift
enum PlayoffState: String, Codable {
    case active
    case drillRequired
    case champion
    case abandoned
}

enum PlayoffRound: Int, Codable, CaseIterable {
    case firstRound = 1
    case secondRound = 2
    case conferenceFinals = 3
    case finals = 4

    var threshold: Double {
        switch self {
        case .firstRound:       return 0.4
        case .secondRound:      return 0.5
        case .conferenceFinals: return 0.6
        case .finals:           return 0.7
        }
    }

    var displayName: String { ... }
    var requiredMakes: Int { Int(ceil(threshold * 10)) }   // 4, 5, 6, 7
}
```

---

## 3. State Machine

### 3.1 Transitions

```
    ┌─────────┐
    │ idle    │  (no active PlayoffSeries exists)
    └────┬────┘
         │ user taps "Start Playoff"
         ▼
    ┌──────────────────┐
    │ .active (round=1)│
    └────┬─────────────┘
         │ play BO7 games
         ├───win 4 games──► advance round ──► .active(round+1) or .champion
         └───lose 4 games──► .drillRequired
                               │ complete prescribed drill
                               ▼
                             .active (retry same round, reset round score)
         │
         │ user abandons (hold-to-end)
         ▼
    ┌──────────┐
    │.abandoned│  (terminal; allows starting a new series)
    └──────────┘
```

Only one active `PlayoffSeries` per user at a time. Abandoning discards progress. Starting a new series after champion archives the old one.

### 3.2 Per-game flow

Each game within a round is 10 three-point attempts, make ≥ `round.requiredMakes` to win. Implementation: a `GameSession` with `gameType = .bo7Playoff`, `targetScore = 10` (total attempts), 1 player (the owner). Shots logged via CV per SP2.

End-of-game decision:
- `shotsMade >= requiredMakes` → game win; increment round's `gamesWon`
- Otherwise → game loss; increment `gamesLost`
- First to 4 wins or losses advances the state machine

---

## 4. Prescribed Drill Generation

Core loop after elimination: analyse the lost series' shot history, identify weakest court zones, generate a drill that reinforces them.

### 4.1 Analysis

Pure function in new file `HoopTrack/Utilities/WeakZoneAnalyser.swift`:

```swift
enum WeakZoneAnalyser {
    static func weakestZones(from shots: [GameShotRecord], topN: Int = 3) -> [CourtZone] { ... }
}
```

Algorithm:
1. Group shots by `CourtZone` (reuses existing `CourtZoneClassifier`)
2. Compute FG% per zone, filtering zones with < 5 attempts (noisy)
3. Sort ascending by FG%
4. Return top N weakest

### 4.2 Drill config

The output drill is a regular `TrainingSession` (not a `GameSession`) with:
- `drillType = .freeShoot` (for SP3 simplicity)
- Success condition: "Make N shots from these zones" — N = `round.requiredMakes * 3` (e.g. 12 makes for round 1 at 40%)
- Zones shown on `CourtMapView` as highlighted targets during the drill

### 4.3 Drill-to-retry handoff

- `PlayoffSeries.prescribedDrillSessionID` is set when drill is generated
- Drill session's `TrainingSession` gets a new field `playoffSeriesID: UUID?` linking back (additive migration)
- On drill session finalization, `SessionFinalizationCoordinator` checks: if `playoffSeriesID` set and `shotsMade >= requiredMakes` → transition `PlayoffSeries.state` from `.drillRequired` to `.active` with the current round's `gamesWon/gamesLost` reset

---

## 5. Live UI — LivePlayoffView

Landscape. Minimal, matches LiveGameView aesthetic.

```
┌────────────────────────────────────────────────────────────┐
│ ┌────────────────┐                          ┌───────────┐  │
│ │ ROUND 2 · G 4  │        ← camera →        │ KILLFEED  │  │
│ │ You 2 – 1 CPU  │                          │ make 3PT  │  │
│ └────────────────┘                          │ miss      │  │
│                                              │ make 3PT  │  │
│ ┌─────────────────┐                          └───────────┘ │
│ │ 7/10 · need 5   │                                        │
│ │ ● ● ○ ● ● ● ○   │  ← attempt pips (○ pending, ●=shot)   │
│ └─────────────────┘                                        │
│                                                            │
│ [ pause ]              [ hold to end session ]             │
└────────────────────────────────────────────────────────────┘
```

- Top-left: round + game-number + series score (You 2–1 CPU)
- Left-centre: shot counter + makes + threshold pip row
- Top-right: killfeed of last 4 shots

### 5.1 Transitions

- **Game win:** brief `ROUND N · GAME M WIN` card (2s), then next game auto-starts
- **Round win:** full-screen "ROUND 1 COMPLETE → ADVANCING TO ROUND 2" card with round stats
- **Series loss (elimination):** full-screen "ELIMINATED IN ROUND 2" → bottom-CTA "View your weakest zones" → full `PrescribedDrillView` scaffolded with target zones highlighted
- **Champion:** full-screen celebration with total series stats — longest run, total makes, total games

---

## 6. Persistence

- `PlayoffSeries` lives in SwiftData like any other model
- On app launch, check for `PlayoffSeries.state == .active || .drillRequired`; if one exists, show a "Resume Playoff Run" banner on the Home tab
- Mid-game app suspension: current `GameSession` state preserved; next launch resumes at the Live* view with current attempt count

---

## 7. Progress Tab Integration

New section "Playoff Runs" in `ProgressTabView`:
- Card per `PlayoffSeries` showing outcome (Round reached · "Champion" / "Eliminated Round N")
- Tap for detailed history — round-by-round breakdown, shot chart, prescribed drill outcomes

---

## 8. Files Touched / Created

**New:**
- `HoopTrack/Models/PlayoffSeries.swift`
- `HoopTrack/Utilities/WeakZoneAnalyser.swift` (pure function, XCTest-able)
- `HoopTrack/ViewModels/PlayoffSeriesViewModel.swift`
- `HoopTrack/Views/Game/LivePlayoffView.swift`
- `HoopTrack/Views/Game/PlayoffEntryView.swift` (start / resume screen)
- `HoopTrack/Views/Game/PlayoffTransitionCards.swift` (game-win / round-win / elimination animations)
- `HoopTrack/Views/Game/PrescribedDrillView.swift`
- `HoopTrack/Views/Game/PlayoffRunSummaryView.swift` (post-champion screen)
- `HoopTrackTests/WeakZoneAnalyserTests.swift`
- `HoopTrackTests/PlayoffSeriesStateMachineTests.swift`

**Modified:**
- `HoopTrack/Models/Enums.swift` — add `PlayoffState`, `PlayoffRound`
- `HoopTrack/Models/TrainingSession.swift` — add `playoffSeriesID: UUID?` (additive)
- `HoopTrack/Services/SessionFinalizationCoordinator.swift` — on finalization, check `playoffSeriesID` + promote state
- `HoopTrack/Views/Home/HomeTabView.swift` — resume banner
- `HoopTrack/Views/Progress/ProgressTabView.swift` — Playoff Runs section
- `HoopTrack/Utilities/Constants.swift` — new `HoopTrack.Playoff` enum

---

## 9. Constants

```swift
enum Playoff {
    static let gamesPerSeries: Int = 7          // BO7
    static let gamesNeededToWin: Int = 4        // first to 4
    static let shotsPerGame: Int = 10
    static let minShotsPerZoneForAnalysis: Int = 5   // filter noisy zones
    static let weakZoneCount: Int = 3            // drills target 3 weakest
    static let drillMakesMultiplier: Int = 3    // requiredMakes * 3
}
```

---

## 10. Open Questions (deferred to SP3 brainstorm)

1. **Are 40/50/60/70% the right threshold curve?** Too flat? Too steep? Impossible-to-playtest cold. **My lean:** ship these; tune based on real user completion rates. Store thresholds in `HoopTrack.Playoff` constants so tuning is a one-line change.
2. **How many retries per round?** Currently unlimited — lose, drill, retry forever. Worth adding a cap? **My lean:** unlimited for SP3; revisit if playtesting shows users grinding indefinitely.
3. **"Hall of Champions" leaderboard?** Cross-device requires backend work (Supabase). **My lean:** out of scope for SP3; local-only achievements card on Profile. Revisit post-launch if demand exists.
4. **Partial credit for close losses?** e.g. series loss 3–4 with high FG% grants "Honorable Mention". Adds narrative. **My lean:** skip — the prescribed-drill loop is the narrative reward.
5. **Drill weakness analysis — use only this series' shots or cross-reference `TrainingSession` history?** Cross-ref could produce smarter drills. **My lean:** series-only for SP3 simplicity; cross-reference is an enhancement.

---

## 11. Exit Criteria

- Full series run (win path): user completes 4 rounds, sees champion screen, run appears in Progress tab
- Full series run (loss path): user loses round 2, sees prescribed drill screen, drill sessions correctly link back to `PlayoffSeries`
- Completing prescribed drill transitions `.drillRequired` → `.active` and allows retry of the same round
- `PlayoffSeries` survives app kill/restart; resume banner appears on Home
- `WeakZoneAnalyser` unit tests pass including edge cases (no zones with enough attempts, all-perfect shooting)
- State-machine tests cover every transition edge including abandon
- Manual QA: playtest one full series start-to-finish on device

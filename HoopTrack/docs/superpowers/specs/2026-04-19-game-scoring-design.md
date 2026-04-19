# Sub-Phase 2 — Scoring & Box Score Design Spec

**Date:** 2026-04-19
**Status:** Approved
**Scope:** CV-powered player attribution, live scoreboard UI, post-game box score. Depends on SP1 data models.
**Parent:** [Game Mode Master Plan](2026-04-19-game-mode-master-plan.md)

---

## 1. Goal

Turn the manual-scoring game shell from SP1 into a live camera-driven experience: detected shots get attributed to the right player automatically, a minimal landscape UI shows the running score, and a post-game box score lands after the final whistle. The heavy lift is the new `PlayerTracker` CV subsystem — everything else is SwiftUI plumbing.

**Non-goals:** BO7 structure (SP3), commentary (SP4), remote play, crowd/5v5 modes.

---

## 2. Architecture Overview

```
                        CameraService.framePublisher
                        /              |              \
                       ▼               ▼               ▼
              CVPipeline       PlayerTracker    PoseEstimationService
              (ball state)    (player state)    (shot science, SP3 reuse)
                       \              |              /
                        ▼             ▼             ▼
                            GameScoringCoordinator
                            (attribution + GameShotRecord writes)
                                      │
                                      ▼
                              GameSessionViewModel
                                (publishes to UI)
                                      │
                                      ▼
                                LiveGameView
```

Key design principle: `PlayerTracker` is a **sibling service**, not a CVPipeline extension. Shares the frame source, owns its own state machine, runs on the same `sessionQueue`.

New orchestrator `GameScoringCoordinator` is the `@MainActor` glue: subscribes to both pipelines' outputs, applies attribution rules, writes `GameShotRecord` rows.

---

## 3. PlayerTracker Service

### 3.1 Purpose

Maintain a table of `(GamePlayer, lastSeenBoundingBox, lastSeenTimestamp, confidence)` that updates every frame. Feeds identity + position into `GameScoringCoordinator` when a shot event fires.

### 3.2 Skeleton

```swift
@MainActor
final class PlayerTracker {
    struct TrackedPlayer {
        let player: GamePlayer
        var lastBox: CGRect           // normalised frame coords
        var lastSeen: CMTime
        var matchConfidence: Double   // 0..1, EMA-smoothed
    }

    @Published private(set) var tracked: [UUID: TrackedPlayer] = [:]

    func configure(with registered: [GamePlayer]) { ... }
    func ingest(sampleBuffer: CMSampleBuffer, timestamp: CMTime) async { ... }
    func reset() { ... }
}
```

### 3.3 Per-frame work

1. Run `VNDetectHumanBodyPoseRequest` on the buffer (max detections = 6)
2. For each detection, compute a live `AppearanceDescriptor` on the torso region
3. **Match**: each live descriptor → best matching registered `GamePlayer` via distance score (see §3.4). Enforce one-to-one assignment using greedy match (live descriptor → player with lowest distance, below threshold)
4. For matched pairs: update `TrackedPlayer.lastBox`, `lastSeen`, EMA-smooth `matchConfidence`
5. For unmatched registered players: retain stale `lastSeen` — they're considered still-tracked for a grace window (see §3.5)
6. Publish updated `tracked` dict

### 3.4 Matching distance

Weighted sum of component distances:
- Torso hue histogram: chi-squared distance × 0.5
- Torso value histogram: chi-squared distance × 0.2
- Height ratio: absolute difference × 0.2
- Aspect ratio: absolute difference × 0.1

Total distance clamped 0..1. Matches below `HoopTrack.Game.matchAcceptThreshold = 0.35` accepted; above rejected (player marked unmatched this frame).

### 3.5 Grace window + re-ID

If a registered player isn't matched for > `HoopTrack.Game.playerLostTimeoutSec = 2.0` they're marked lost. When a new body appears, it's matched against *all* registered players, including lost ones — this is the re-ID path (player reappears after occlusion).

### 3.6 Performance

Run at ~15 fps independent of camera's 30 fps (every second frame). Vision body pose on iPhone 14 Pro runs in ~15-20 ms; histogram math negligible. Keeps PlayerTracker under ~25 ms/frame budget.

Profile on iPhone SE 2 before merging.

---

## 4. Shot Attribution

`GameScoringCoordinator` subscribes to `CVPipeline` shot events (existing `.resolved` state). On shot resolve:

```swift
func attributeShot(to shotEvent: ShotEvent) async {
    // 1. Grab latest PlayerTracker snapshot
    let tracked = playerTracker.tracked.values

    // 2. Find player nearest the release point
    guard let nearest = tracked.min(by: {
        distance($0.lastBox.center, shotEvent.releasePoint) <
        distance($1.lastBox.center, shotEvent.releasePoint)
    }) else {
        flagUnattributed(shotEvent); return
    }

    // 3. Threshold gate
    let releaseDistance = distance(nearest.lastBox.center, shotEvent.releasePoint)
    let timeSinceSeen = shotEvent.timestamp - nearest.lastSeen
    guard releaseDistance < 0.2,                      // within 20% of frame
          timeSinceSeen.seconds < 0.5 else {
        flagUnattributed(shotEvent); return
    }

    // 4. Compose attribution confidence (from tracker + distance + recency)
    let confidence = computeAttributionConfidence(
        matchConfidence: nearest.matchConfidence,
        distanceFromRelease: releaseDistance,
        timeSinceSeen: timeSinceSeen
    )

    // 5. Write GameShotRecord
    try await dataService.addGameShot(
        shotEvent, shooter: nearest.player, confidence: confidence
    )
}
```

Fallback: if unattributed, write a `GameShotRecord` with `shooter = nil` and flag for post-game manual resolution.

---

## 5. Live UI

### 5.1 LiveGameView layout (landscape)

```
┌────────────────────────────────────────────────────────────┐
│ ┌────────┐                                   ┌──────────┐  │
│ │ TEAM A │      ← camera preview →            │ KILLFEED │  │
│ │   24   │                                   │ Ben 3PT  │  │
│ │ TEAM B │                                   │ Jake 2PT │  │
│ │   21   │                                   │ Ben 3PT  │  │
│ └────────┘                                   │ Sam miss │  │
│                                              └──────────┘  │
│           [player name overlays on bodies]                 │
│                                                            │
│ [ pause ]              [ hold to end session ]             │
└────────────────────────────────────────────────────────────┘
```

- Top-left: team scoreboard. Animated count-up on change
- Top-right: killfeed (4 entries, newest on top, 3-second fade-out tail)
- Camera feed: full background. Player name chip anchored to each tracked body
- Bottom: existing `HoldToEndButton` for consistency with `LiveSessionView`

### 5.2 Killfeed entry format

`<Player name> — <2PT/3PT> <make/miss>`, color-coded by team assignment. Example: "Ben — 3PT make" in Team A orange.

### 5.3 Player indicators

Only shown when `matchConfidence > 0.6`. Below that, the overlay hides (avoids flickering labels). A subtle dotted outline in team colour confirms tracking without cluttering the view.

### 5.4 Game clock

Optional toggle in settings. Default off — pickup games rarely use one. When enabled, shown centre-top, counting down (if `targetScore != nil` this is replaced by "first to X").

---

## 6. Post-Game Box Score

`GameSummaryView` (upgraded from SP1's stub), portrait.

### 6.1 Sections

1. **Hero:** Final score, game duration, MVP callout (player with highest points or best FG%)
2. **Team totals:** FG / FGA / FG%, 3PM / 3PA / 3P%, for each team
3. **Player table:** Rows per player — Pts, FGA, FGM, FG%, 3PA, 3PM, 3P%, attribution confidence average
4. **Shot chart:** Existing `CourtMapView`, color-coded per player (default) with toggle for per-team mode
5. **Unresolved shots:** If any `shooter == nil`, a dedicated card with one tap-to-assign per shot

### 6.2 Unresolved-shots resolution flow

```
┌──────────────────────────────────┐
│ 3 shots need your help           │
│ ┌──────┐ ┌──────┐ ┌──────┐      │
│ │ [pic]│ │ [pic]│ │ [pic]│       │
│ │ Make │ │ Miss │ │ Make │       │
│ │ [Assign ▾][Assign ▾][Assign ▾]│
│ └──────┘ └──────┘ └──────┘       │
└──────────────────────────────────┘
```

Each card shows a single video frame around the shot event + quick-select from the registered player list. Assigning updates the `GameShotRecord.shooter` and re-computes totals live.

---

## 7. Files Touched / Created

**New:**
- `HoopTrack/Services/PlayerTracker.swift`
- `HoopTrack/Services/GameScoringCoordinator.swift`
- `HoopTrack/Services/AppearanceMatcher.swift` — distance math, pure-function testable
- `HoopTrack/ViewModels/GameSessionViewModel.swift`
- `HoopTrack/Views/Game/Components/TeamScoreboard.swift`
- `HoopTrack/Views/Game/Components/KillfeedView.swift`
- `HoopTrack/Views/Game/Components/PlayerOverlay.swift`
- `HoopTrack/Views/Game/BoxScoreView.swift`
- `HoopTrack/Views/Game/UnresolvedShotsView.swift`
- `HoopTrackTests/AppearanceMatcherTests.swift` — distance math
- `HoopTrackTests/GameAttributionTests.swift` — attribution gating (release distance, recency)
- `HoopTrackTests/Fixtures/GameAttribution/` — 2-3 short clips with hand-labeled attribution for eval

**Modified:**
- `HoopTrack/Views/Game/LiveGameView.swift` — full implementation
- `HoopTrack/Views/Game/GameSummaryView.swift` — full implementation
- `HoopTrack/Services/DataService.swift` — `addGameShot()` method
- `HoopTrack/Utilities/Constants.swift` — `HoopTrack.Game` extensions

---

## 8. Constants

Added to `HoopTrack.Game`:

```swift
static let matchAcceptThreshold: Double       = 0.35
static let playerLostTimeoutSec: Double       = 2.0
static let playerConfidenceEMAAlpha: Double   = 0.35
static let attributionReleaseDistMax: Double  = 0.2     // 20% of frame
static let attributionTimeSinceSeenMax: Double = 0.5    // seconds
static let playerOverlayMinConfidence: Double = 0.6
static let killfeedMaxEntries: Int            = 4
static let killfeedFadeOutSec: Double         = 3.0
static let trackerFrameStride: Int            = 2        // every 2nd frame (15fps)
```

---

## 9. Testing Strategy

### 9.1 Unit tests (XCTest)
- `AppearanceMatcher` distance math — chi-squared, weighting, edge cases (empty histograms, identical descriptors)
- `GameScoringCoordinator` attribution gating — release distance threshold, time-since-seen threshold, unattributed fallback
- Pure functions in `PlayerTracker` (greedy assignment logic)

### 9.2 Fixture-based eval (new pattern)
- 2–3 short `.mov` clips shot in real conditions with known player identities
- `.json` sidecar with ground-truth attribution (timestamp → player UUID)
- New target `HoopTrackEvalTests` — runs on demand, measures attribution accuracy %
- Not run on every CI build (too slow); gated behind `ENABLE_CV_EVAL=1` env var

### 9.3 Manual QA checklist
- 2v2 real game, similar-colored shirts — does re-ID hold after screens/occlusion?
- 3v3 with one player in bright distinctive colour — does confidence stay high?
- iPhone SE 2 — does frame rate hold at 30 fps?

---

## 10. Open Questions (deferred to SP2 brainstorm)

1. **Appearance embedding algorithm.** Histogram-based (this spec) is simple and interpretable. Alternative: small trained CNN that produces a 64-dim embedding ([`UIImage → MLMultiArray`] via Vision feature extraction). CNN wins at occlusion robustness, loses at size and transparency. **My lean:** ship histogram in SP2; revisit if attribution accuracy < 85% on eval set.
2. **Can `PlayerTracker` share the `VNDetectHumanBodyPoseRequest` with `PoseEstimationService`?** Would save ~15 ms/frame. Requires careful sequencing. **My lean:** ship separate first; merge in a follow-up.
3. **Multi-camera mode** (court corner + over-the-shoulder)? Would dramatically improve attribution. Out of scope for SP2; flag for future.
4. **What happens if a player leaves and a new one joins mid-game?** "Substitution." Not covered by the master spec. **My lean:** don't support in SP2; user ends current game + starts a new one.
5. **Attribution confidence display?** Should the per-player box score show avg attribution confidence? Useful for trust-building but also visual noise. **My lean:** show it but collapse by default.

---

## 11. Exit Criteria

- PlayerTracker achieves ≥ 85% attribution accuracy on the eval fixture set
- iPhone SE 2 holds 30 fps with Game Mode active
- LiveGameView looks polished: scoreboard updates are smooth, killfeed fades cleanly, no player overlay flicker
- Box score produces correct totals including from manual unresolved-shots resolution
- No crashes on a 20-minute real 2v2 session
- All XCTest cases pass; eval tests passing at threshold

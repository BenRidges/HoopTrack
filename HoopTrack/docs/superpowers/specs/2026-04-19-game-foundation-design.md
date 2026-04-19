# Sub-Phase 1 — Game Foundation Design Spec

**Date:** 2026-04-19
**Status:** Approved
**Scope:** Data models + player registration + navigation glue. No CV scoring yet (SP2), no playoff (SP3), no commentary (SP4).
**Parent:** [Game Mode Master Plan](2026-04-19-game-mode-master-plan.md)

---

## 1. Goal

Land the foundational layer that later sub-phases build on: three new `@Model` types, a registration flow that captures player appearance profiles, team assignment UX, and hooks into the existing Train / Progress tabs. The output of SP1 is a runnable "game mode" flow that creates a `GameSession` with registered players — even though no shots are scored automatically yet (manual make/miss buttons reused from `LiveSessionView`).

---

## 2. Data Models

All new models live in `HoopTrack/Models/`. No `cloudSyncedAt` field — GameSessions are intentionally local-only (see master plan §6.2).

### 2.1 `GamePlayer` (@Model, @MainActor)

```swift
@Model
final class GamePlayer {
    @Attribute(.unique) var id: UUID
    var name: String
    var appearanceEmbedding: Data          // serialised AppearanceDescriptor
    var teamAssignment: TeamAssignment     // enum
    var gameSession: GameSession?          // inverse
    var linkedProfile: PlayerProfile?      // nil unless this player is the app's owner
    var registeredAt: Date
}
```

`appearanceEmbedding` is an opaque `Data` blob for schema stability — internal format is an `AppearanceDescriptor` (see §3.2), encoded with `JSONEncoder`. Not persisted beyond the parent `GameSession`.

### 2.2 `GameSession` (@Model, @MainActor)

```swift
@Model
final class GameSession {
    @Attribute(.unique) var id: UUID
    var gameType: GameType                 // .pickup, .bo7Playoff
    @Relationship(deleteRule: .cascade) var players: [GamePlayer]
    var teamAScore: Int
    var teamBScore: Int
    var startTimestamp: Date
    var endTimestamp: Date?
    var gameState: GameState
    @Relationship(deleteRule: .cascade) var shots: [GameShotRecord]
    var targetScore: Int?                  // "first to X" optional
    var videoFileName: String?             // matches TrainingSession pattern
    var videoPinnedByUser: Bool = false    // same retention behaviour
}
```

Sibling to `TrainingSession`, not a subclass. Shares the video-retention mechanism (SP1 must ensure `GameSession` videos also get filtered by `DataService.purgeOldVideos`).

### 2.3 `GameShotRecord` (@Model, @MainActor)

```swift
@Model
final class GameShotRecord {
    @Attribute(.unique) var id: UUID
    var shooter: GamePlayer
    var result: ShotResult                 // reuse existing .make / .miss
    var courtX: Double                     // 0..1 normalised half-court
    var courtY: Double
    var timestamp: Date
    var shotType: ShotType                 // .twoPoint / .threePoint
    var attributionConfidence: Double      // 0..1; 1.0 for manually logged shots in SP1
    var gameSession: GameSession?
}
```

In SP1, all shots are logged manually (tap make/miss button) so `attributionConfidence = 1.0`. SP2 lowers confidence as CV attribution kicks in.

### 2.4 Enums (added to `HoopTrack/Models/Enums.swift`)

```swift
enum GameType: String, Codable { case pickup, bo7Playoff }
enum GameState: String, Codable { case registering, inProgress, completed }
enum TeamAssignment: String, Codable { case teamA, teamB }
enum ShotType: String, Codable { case twoPoint = "2PT", threePoint = "3PT" }
```

Raw values kept as display strings to match the existing `DrillType` / `ShotResult` convention (see `CLAUDE.md` Sync layer note about `exportKey`s).

### 2.5 SwiftData migration

Additive only — three new `@Model` types. No changes to existing models. No migration plan needed for this additive stage (per SwiftData's lightweight migration behaviour; same approach as Phase 9 additions).

---

## 3. Appearance Descriptor

### 3.1 Purpose

A per-player profile captured at registration, used in SP2 to attribute shots to bodies detected on-camera. Must be small (embedded in SwiftData as `Data`), fast to compare (SP2 will compare each detected body against each registered descriptor every few frames), and stable under light pose/orientation changes.

### 3.2 `AppearanceDescriptor` struct

```swift
struct AppearanceDescriptor: Codable, Sendable {
    /// 8-bin hue histogram of upper-body pixels, normalised to sum to 1.0.
    let torsoHueHistogram: [Float]       // length 8

    /// 4-bin brightness histogram of the same region.
    let torsoValueHistogram: [Float]     // length 4

    /// Body height as fraction of frame height (0..1).
    let heightRatio: Float

    /// Upper-body aspect ratio (width / height).
    let upperBodyAspect: Float

    /// Schema version for future upgrades.
    let schemaVersion: Int               // starts at 1
}
```

Footprint: ~60 bytes encoded. Dozens of players in a session remains trivial.

### 3.3 Capture procedure (SP1 scope: the capture itself, not the matching)

On the registration screen:
1. Player stands 6–8 ft from camera for ~3 seconds
2. Vision's `VNDetectHumanBodyPoseRequest` runs each frame on the preview buffer
3. A valid frame (body fully in frame, confidence > 0.7 on both shoulder and hip keypoints) triggers capture
4. Upper-body region extracted as the bounding quad around shoulders→hips
5. Histogram computed on that region; height ratio and aspect computed from keypoints
6. Descriptor encoded to JSON `Data`, stored on the `GamePlayer`

Matching is SP2's problem — this spec only defines capture + storage.

### 3.4 Privacy (see master plan §6.3)

- Descriptor is **session-scoped** — deleted with the `GameSession` when it reaches `.completed`
- Registration screen shows a consent card before the camera preview activates
- Privacy manifest declares "Biometric-adjacent data captured locally, not transmitted"

---

## 4. User Flow

Happy path, landscape throughout (reuses `LandscapeHostingController` pattern).

1. **Train tab → "Game" drill card** (new). Portrait. Lists `GameType` options + "2v2 / 3v3" format picker.
2. **Consent screen.** Portrait. Explains appearance capture + session-scoped retention. "I understand" button.
3. **Registration.** Landscape. Large camera preview. Banner: "Player 1 — step in front of the camera." Auto-advances when a valid body lock is obtained for 3 consecutive seconds. Tap to confirm + name entry sheet.
4. Repeat for each registered player (2v2 = 4 players, 3v3 = 6).
5. **Team assignment.** Portrait. Drag-and-drop player chips into "Team A" / "Team B" zones.
6. **Game begins.** Landscape. `LiveGameView` shell with manual make/miss buttons (SP1) — the scoreboard + killfeed structure is stubbed so SP2 can fill it in without re-plumbing.
7. **End of game.** Tap-and-hold to stop. `GameSummaryView` stub — just shows final score, player list, session duration. Full box score is SP2.

---

## 5. Navigation Integration

- `TrainTabView` — new "Game" drill card alongside shoot/dribble/agility. Uses new `DrillType.game` enum case? No — `GameType` is separate from `DrillType`; game mode lives at the top of `TrainTabView`'s layout as a distinct entry, not mixed into the drill grid. This matches the spec's "Game entry in the drill picker grid" wording but cleaner.
- `AppRoute` — new cases: `.gameRegistration(format: GameFormat)`, `.liveGame(sessionID: UUID)`, `.gameSummary(sessionID: UUID)`
- `ProgressTabView` — game sessions appear in the session history list with a distinct card style (team score vs solo stats)

---

## 6. Files Touched / Created

**New files:**
- `HoopTrack/Models/GamePlayer.swift`
- `HoopTrack/Models/GameSession.swift`
- `HoopTrack/Models/GameShotRecord.swift`
- `HoopTrack/Models/AppearanceDescriptor.swift`
- `HoopTrack/Services/AppearanceCaptureService.swift` — wraps body-pose detection + histogram computation
- `HoopTrack/Views/Game/GameRegistrationView.swift`
- `HoopTrack/Views/Game/GameConsentView.swift`
- `HoopTrack/Views/Game/TeamAssignmentView.swift`
- `HoopTrack/Views/Game/LiveGameView.swift` — shell only, full impl in SP2
- `HoopTrack/Views/Game/GameSummaryView.swift` — stub only
- `HoopTrack/ViewModels/GameRegistrationViewModel.swift`
- `HoopTrackTests/AppearanceDescriptorTests.swift` — histogram math, edge cases

**Modified:**
- `HoopTrack/Models/Enums.swift` — add `GameType`, `GameState`, `TeamAssignment`, `ShotType`
- `HoopTrack/Views/Train/TrainTabView.swift` — new "Game" entry
- `HoopTrack/AppState.swift` — new `AppRoute` cases
- `HoopTrack/Services/DataService.swift` — extend `purgeOldVideos` to include `GameSession`
- `HoopTrack/Views/Progress/ProgressTabView.swift` — merge `GameSession` into history list
- `HoopTrack/PrivacyInfo.xcprivacy` — declare appearance capture

---

## 7. Constants (new)

Added to `HoopTrack/Utilities/Constants.swift` under `HoopTrack.Game`:

```swift
enum Game {
    static let registrationLockDurationSec: Double = 3.0
    static let registrationMinBodyConfidence: Float = 0.7
    static let registrationMinDistanceFeet: Double = 6.0
    static let registrationMaxDistanceFeet: Double = 8.0
    static let maxPlayersPerTeam: Int = 3
    static let histogramHueBins: Int = 8
    static let histogramValueBins: Int = 4
}
```

---

## 8. Open Questions (deferred to brainstorming when SP1 actually starts)

1. **Link `GamePlayer` → `PlayerProfile`?** Spec says "optionally." Decision needed: auto-link if the signed-in user registers themselves, or always treat `GamePlayer` as ephemeral? My lean: auto-link for the app owner (by matching the registration selfie against the `PlayerProfile` name, or by an explicit "This is me" toggle), leave everyone else ephemeral.
2. **Retention after `GameSession.completed`?** Session video follows existing retention rules, but `GamePlayer` rows? My lean: cascade-delete when the `GameSession` is purged. Embeddings don't survive their session, full stop.
3. **Re-registration between games?** If a player plays 3 games back-to-back, do they re-register each time? My lean: yes, for SP1 simplicity. "Recent players" quick-pick is a v2 feature.
4. **Landscape lock during registration?** Registration is landscape (matches camera preview) but consent + team assignment are portrait. Orientation transitions might be jarring. Consider either (a) whole flow landscape, (b) whole flow portrait with a smaller preview window.

---

## 9. Exit Criteria

SP1 is done when:
- All four data models exist and compile; additive migration does not break existing app
- User can complete the full registration flow and reach a `LiveGameView` with all registered players
- Manual make/miss buttons create `GameShotRecord` with correct team/score updates
- "End game" button returns a stub `GameSummaryView` showing final team scores
- Privacy consent screen appears before any camera activation
- `DataService.purgeOldVideos` correctly handles `GameSession` videos
- Unit tests for `AppearanceDescriptor` math pass
- Manual QA: one full 2v2 registration + end-to-end game on device

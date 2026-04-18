# Game Mode Features — Design Spec

**Date:** 2026-04-13
**Status:** Approved
**Scope:** Scoring tracker, box score analysis, BO7 Playoff mode, live commentary

---

## Overview

Four new features that extend HoopTrack from a solo training app into a game-capable platform. Delivered sequentially in four sub-phases, each building on the previous.

### Sub-Phases

1. **Game Mode Foundation** — Player registration, team assignment, game session model
2. **Scoring & Box Score** — CV-powered player-attributed scoring, live scoreboard, post-game breakdown
3. **BO7 Playoff Mode** — Solo challenge mode with escalating thresholds and drill-gated retries
4. **Live Commentary** — Event-driven pre-recorded audio commentary with configurable personalities

---

## Sub-Phase 1: Game Mode Foundation

### Data Models

**`GamePlayer`** (`@Model`)
- `id: UUID`
- `name: String`
- `appearanceEmbedding: Data` — serialised appearance descriptor (color histogram, height ratio, upper body pattern)
- `teamAssignment: TeamAssignment` — enum: `.teamA`, `.teamB`
- `gameSession: GameSession` — inverse relationship

Not persisted long-term. Exists for the duration of a game. Optionally links to a `PlayerProfile` if the player has a HoopTrack account.

**`GameSession`** (`@Model`)
- `id: UUID`
- `gameType: GameType` — enum: `.pickup`, `.bo7Playoff`
- `players: [GamePlayer]`
- `teamAScore: Int`
- `teamBScore: Int`
- `startTimestamp: Date`
- `endTimestamp: Date?`
- `gameState: GameState` — enum: `.registering`, `.inProgress`, `.completed`
- `shots: [GameShotRecord]`
- `targetScore: Int?` — optional, for "first to X" games
- `videoPath: String?`

Sibling to `TrainingSession`, not a subclass. Different data shapes (team structure, per-player attribution) warrant separation.

**`GameShotRecord`** (`@Model`)
- `id: UUID`
- `shooter: GamePlayer`
- `result: ShotResult` — enum: `.make`, `.miss`
- `courtLocation: CourtCoordinate` — normalised 0-1 half-court position
- `timestamp: Date`
- `shotType: ShotType` — enum: `.twoPoint`, `.threePoint` (derived from court position)
- `attributionConfidence: Double` — 0-1, how confident the CV pipeline was in player attribution
- `gameSession: GameSession` — inverse relationship

**`PlayoffSeries`** (`@Model`)
- `id: UUID`
- `currentRound: Int` — 1-4
- `roundSeriesScores: Data` — serialised dictionary of round → (playerWins, opponentWins)
- `state: PlayoffState` — enum: `.active`, `.drillRequired`, `.champion`, `.abandoned`
- `prescribedDrillId: UUID?` — link to the training session generated as a retry drill
- `startDate: Date`
- `completionDate: Date?`
- `shotHistory: [GameShotRecord]` — all shots across the entire playoff run (reuses `GameShotRecord` with shooter always being the solo player)

**Enums** (added to `Models/Enums.swift`):
- `GameType`: `.pickup`, `.bo7Playoff`
- `GameState`: `.registering`, `.inProgress`, `.completed`
- `TeamAssignment`: `.teamA`, `.teamB`
- `ShotType`: `.twoPoint`, `.threePoint`
- `PlayoffState`: `.active`, `.drillRequired`, `.champion`, `.abandoned`
- `PlayoffRound`: `.firstRound(threshold: 0.4)`, `.secondRound(threshold: 0.5)`, `.conferenceFinals(threshold: 0.6)`, `.finals(threshold: 0.7)`

### Player Registration Flow (Lineup Scan)

1. User starts a new game from Train tab -> selects "Game" mode -> chooses format (2v2, 3v3)
2. Registration screen: camera is live. Prompt: "Player 1, step in front of the camera."
3. Player stands ~6-8 feet away for ~3 seconds. App captures:
   - **Torso color histogram** — dominant clothing colors from upper body bounding box (Vision body detection)
   - **Relative height ratio** — body height as proportion of frame
   - **Upper body pattern descriptor** — coarse texture features to distinguish similar-colored shirts
4. User taps to confirm + enters a name (or picks from recent players). Repeat for all players.
5. Team assignment screen: drag players into Team A / Team B.
6. Game begins.

### Navigation Integration

- Train tab gets a new "Game" entry in the drill picker grid alongside existing shot/dribble/agility options
- Game history appears in the Progress tab alongside training sessions with a distinct card style
- `AppRoute` gets new cases for game flows

---

## Sub-Phase 2: Scoring & Box Score

### CV Pipeline Extension — PlayerTracker

New **`PlayerTracker`** service that runs in parallel with `CVPipeline`:

- On each frame, runs Vision body detection to get bounding boxes for all visible people
- Maintains tracked identity for each body using appearance matching against registered embeddings + spatial continuity
- When `CVPipeline` fires a shot detection event, `PlayerTracker` identifies which tracked body was nearest the release point -> attributes the shot to that `GamePlayer`

**Re-identification after occlusion:** Uses appearance embeddings (not just position) to re-ID players after they reappear from behind other players. With only 4-6 players in 2v2/3v3, this is tractable.

**Fallback:** If attribution confidence is below threshold, the shot is logged as "unattributed" and flagged for post-game manual resolution.

### Live Scoreboard UI (LiveGameView)

Landscape layout, extending the existing `LiveSessionView` pattern:

- **Top bar:** Team A score vs Team B score, large and prominent. Real-time updates.
- **Killfeed (top-right):** 4 most recent events stacked vertically, newest on top, older entries fade out. Minimal design — "Ben — 3PT make", "Jake — 2PT miss". Color-coded by team.
- **Player indicators:** Subtle name overlays near tracked players on the camera feed. Confirms tracking is working without obstructing the view.
- **Game clock:** Optional toggle. Most pickup games don't use one.

Design principle: **minimal UI**. The camera feed is the primary content. Overlays are small, semi-transparent, and unobtrusive.

### Post-Game Box Score (GameSummaryView)

Displayed when the game ends (manual stop or target score reached):

- **Team summary:** Final score, team FG%, team 3PT%
- **Per-player stats table:** Points, FGA, FGM, FG%, 3PA, 3PM, 3PT%
- **Shot chart:** Existing court heatmap, color-coded per player or per team (togglable)
- **MVP highlight:** Player with highest points or best FG% gets a callout
- **Unresolved shots:** Quick resolution flow for any unattributed shots — tap to assign to a player

---

## Sub-Phase 3: BO7 Playoff Mode

### Series Structure

- **Round 1 (First Round):** BO7 at 40% — each game is 10 three-point attempts, make 4+ to win. Need 4 game wins to advance.
- **Round 2 (Second Round):** BO7 at 50% — need 5+ makes per game
- **Round 3 (Conference Finals):** BO7 at 60% — need 6+ makes per game
- **Round 4 (Finals):** BO7 at 70% — need 7+ makes per game
- **Win all 4 rounds:** Champion

### Series State Machine

```
idle -> round_1(40%) -> round_2(50%) -> round_3(60%) -> finals(70%) -> champion
           |                |                |                |
        defeated         defeated         defeated         defeated
           |                |                |                |
     drill_required -> (complete drill) -> retry same round
```

### In-Game UI (LivePlayoffView)

Same minimal landscape layout as game mode:

- **Series scoreboard (small):** "Round 1 — Game 3" with series score (You 2 - 1 Opponent)
- **Shot counter:** "7/10 shots — 4 makes" with threshold shown (need 4)
- **Killfeed:** Same style as game mode, just your makes/misses

### Round Win/Loss Flow

- **Win a game:** Brief celebration animation, series score updates, next game begins
- **Win a round:** Bigger celebration — "ROUND 1 COMPLETE — ADVANCING TO ROUND 2", threshold increases
- **Win the Finals:** Champion screen with full run stats
- **Lose a series:** Elimination screen — "ELIMINATED IN ROUND 2" — shows stats, then presents the prescribed drill

### Prescribed Drill After Elimination

- App analyses shot data from the lost series — identifies weakest spots (e.g., "You went 1/8 from the left wing")
- Generates a focused training session: "Make 15 threes from your 3 weakest zones to earn a retry"
- Drill tracked as a regular `TrainingSession` linked back to the `PlayoffSeries`
- Completing the drill unlocks retry of the round that was lost

### Persistence

`PlayoffSeries` saves progress across app sessions. Can close the app mid-series and resume later. Progress tab shows active/completed playoff runs.

---

## Sub-Phase 4: Live Commentary

### Architecture — Event-Driven Audio Engine

**`CommentaryService`** — `@MainActor final class` that subscribes to game/session events and plays contextually appropriate pre-recorded audio clips.

### Event Taxonomy

| Event | Description |
|---|---|
| `shotMade` | Regular make |
| `shotMissed` | Regular miss |
| `streak(n)` | 3+ makes in a row, escalating hype |
| `coldStreak(n)` | 3+ misses in a row |
| `clutchMake` | Late-game make when score is close |
| `gameWinner` | The shot that wins the game |
| `playoffAdvance` | Win a BO7 round |
| `playoffElimination` | Lose a BO7 series |
| `hotPlayer(name)` | A player hits 3+ in a row in game mode |
| `leadChange` | Score lead swaps teams |
| `blowout` | Score differential exceeds threshold |

### Clip Selection Engine

- Each personality has a library of clips tagged by: event type, intensity level (1-5), uniqueness ID
- On event, engine queries clips matching event + current intensity context (early game = low, close game = high, streak = escalating)
- **Anti-repetition:** Tracks recently played clip IDs, never repeats within a window of last 15-20 clips
- **Pacing:** Minimum ~2-3 second gap between lines. Queues events, drops low-priority ones if they stack up.

### Commentator Personalities (ship with 2-3)

- **"Hype Man"** — High energy, trash talk, celebratory
- **"Broadcast"** — NBA play-by-play style, more measured
- **"Analyst"** — Stat-heavy, references session history ("That's your best percentage from the wing this month")

### Asset Generation & Management

- AI-generated voice packs (ElevenLabs or similar) — hundreds of clips per personality generated during development
- Bundled as `.m4a` files organised by `personality/event_type/`
- ~200-400 clips per personality for sufficient variety
- Analyst personality uses template slots filled by on-device `AVSpeechSynthesizer` for dynamic stats (e.g., "That's [number] in a row")

### Settings

- Toggle commentary on/off
- Pick personality
- Volume slider independent of game sounds

### Compatibility

Commentary works with:
- Game mode (2v2/3v3 pickup games)
- BO7 Playoff mode
- Regular solo training sessions (subset of events)

---

## Constants

All new magic numbers go in `Utilities/Constants.swift` under new nested enums:

- `HoopTrack.Game` — player registration timing, attribution confidence threshold, killfeed display count (4), target score defaults
- `HoopTrack.Playoff` — round thresholds, games per round (10 shots), series win target (4), drill generation parameters
- `HoopTrack.Commentary` — min gap between clips (2-3s), anti-repetition window (15-20), intensity thresholds, pacing queue max

---

## Out of Scope

- 5v5 support (too many players for single-camera tracking)
- Online multiplayer / remote play
- Referee/foul tracking
- Rebound/assist/block detection (future CV enhancement)
- Custom playoff threshold configuration (hardcoded for now, configurable later)

# Sub-Phase 4 — Live Commentary Design Spec

**Date:** 2026-04-19
**Status:** Approved
**Scope:** Event-driven pre-recorded audio commentary with configurable personalities. Compatible with solo training sessions, game mode (SP1–SP2), and BO7 Playoff (SP3).
**Parent:** [Game Mode Master Plan](2026-04-19-game-mode-master-plan.md)

---

## 1. Goal

Add an ambient "commentary track" that reacts to in-session events. Plays short pre-recorded audio clips (and occasional dynamic slots filled by `AVSpeechSynthesizer`) at appropriate moments — makes, misses, streaks, clutch moments, game outcomes.

**Delivery order note:** SP4 is parallel-shippable with SP2 because it touches no CV or scoring code. "Lite" mode (subset of events, no game-mode triggers) can even ship before SP1. See [master plan §4](2026-04-19-game-mode-master-plan.md).

---

## 2. Architecture Overview

```
 SessionFinalizationCoordinator, CVPipeline, GameScoringCoordinator, etc.
                         │
                         │  emit EventBus.publish(.shotMade(context))
                         ▼
                    CommentaryEventBus            (Combine subject, domain events)
                         │
                         ▼
                    CommentaryService             (@MainActor, owns AVAudioPlayer pool)
                    ├─ ClipSelector               (picks a file; anti-repetition state)
                    ├─ PacingQueue                (queues, drops low-pri on backpressure)
                    └─ PersonalityLibrary         (current personality's clip manifest)
                         │
                         ▼
                   AVAudioEngine mixer → device speakers
```

Design principles:
- `CommentaryEventBus` is a single `PassthroughSubject<CommentaryEvent, Never>` — producers publish, `CommentaryService` subscribes. Keeps commentary decoupled from every subsystem
- `CommentaryService` is the only thing that touches `AVAudioEngine` / `AVAudioPlayer`
- Zero effect on performance when commentary is off — service early-returns on all events

---

## 3. Event Taxonomy

```swift
enum CommentaryEvent {
    case shotMade(context: ShotContext)
    case shotMissed(context: ShotContext)
    case streak(count: Int, playerName: String?)
    case coldStreak(count: Int, playerName: String?)
    case clutchMake(context: ShotContext)
    case gameWinner(playerName: String?, teamScore: Int)
    case playoffAdvance(round: PlayoffRound)
    case playoffElimination(round: PlayoffRound)
    case hotPlayer(name: String, makesInRow: Int)
    case leadChange(newLeader: TeamAssignment, score: (Int, Int))
    case blowout(leader: TeamAssignment, differential: Int)

    // Session-level (solo training + game + playoff)
    case sessionStart(drillType: DrillType?)
    case sessionEnd(summary: SessionSummary)
    case personalBest(stat: String, value: String)
}

struct ShotContext {
    let result: ShotResult
    let zone: CourtZone
    let isThreePoint: Bool
    let intensity: Int        // 1..5, computed from game state (see §5)
}
```

### 3.1 "Lite" mode event subset

If game mode (SP1+) isn't installed or hasn't shipped yet, commentary works with solo training by subscribing to just:
- `sessionStart`, `sessionEnd`
- `shotMade`, `shotMissed`
- `streak`, `coldStreak`
- `personalBest`

This is what ships if SP4 delivers before SP2.

---

## 4. Personality System

### 4.1 Ship list (launch)

- **"Hype Man"** — high energy, celebratory, light trash talk
- **"Broadcast"** — NBA play-by-play style, measured tone
- **"Analyst"** — stat-heavy, references session history, uses dynamic slots

**My lean:** ship 2 (Hype Man + Broadcast) at SP4 launch. Analyst adds asset-generation cost + dynamic-slot complexity. Add in a follow-up once clip-selection engine is stable.

### 4.2 Asset layout

```
HoopTrack/Audio/Commentary/
├── hype_man/
│   ├── manifest.json       # see §4.3
│   ├── shot_made/
│   │   ├── 001_boom.m4a
│   │   ├── 002_money.m4a
│   │   └── ...
│   ├── shot_missed/
│   └── streak_3/
├── broadcast/
│   ├── manifest.json
│   └── ...
└── analyst/                # later
```

Each personality has ~200-300 clips at launch. All m4a mono 64 kbps (≈ 20 KB/sec, so a 2-second clip is ~40 KB). Total asset budget: ~20 MB per personality bundled.

### 4.3 Clip manifest (generated at build time, JSON in each personality dir)

```json
{
  "personality": "hype_man",
  "version": 1,
  "clips": [
    {
      "id": "hype_001",
      "file": "shot_made/001_boom.m4a",
      "event": "shotMade",
      "intensity": 3,
      "duration": 1.8,
      "tags": ["make", "3pt", "hype"],
      "transcript": "BOOM! That's what I'm talking about!"
    },
    ...
  ]
}
```

Manifest is loaded on personality switch and kept in memory (tiny — a few KB).

---

## 5. Clip Selection Engine

### 5.1 Intensity model

Each event carries an `intensity: Int` 1–5 computed from game state:
- Solo session, early in workout: 1-2
- Solo session, hitting makes: 2-3
- Game mode, close game or playoff: 3-4
- Clutch / tied in final attempts / gameWinner: 5

Clips are tagged with their suitable intensity range. Selection filters clips by event type AND intensity window.

### 5.2 Anti-repetition

`ClipSelector` tracks recently played clip IDs in a fixed-size queue (last `HoopTrack.Commentary.antiRepetitionWindow = 15` clips). New selection picks randomly from (matching clips) − (recently played). If the filter empties, relax: drop the anti-repetition requirement.

### 5.3 Pacing queue

Events arrive faster than clips can play. `PacingQueue`:
- Enforces minimum `minGapBetweenClipsSec = 2.0` between any two clips
- Queue length capped at 3 events
- On queue overflow, **drop low-priority events**: priority order is `gameWinner > playoffAdvance > clutchMake > streak > shotMade > shotMissed > sessionStart`
- Events older than `maxQueueAgeSec = 5.0` get dropped (stale commentary is worse than silence)

### 5.4 Example selection flow

User hits a 3-pointer to tie the game. Pipeline:
1. Event `shotMade(context: ShotContext(zone: .threePoint, intensity: 4))` published
2. `CommentaryService` receives → pushes to `PacingQueue`
3. Queue empty + > 2s since last clip → pop immediately
4. `ClipSelector`: filter manifest to `event == shotMade`, `intensity ∈ [3, 5]`, tags include "3pt"
5. Remaining clips: 8. Filter out last-15 anti-repetition: 5 remaining
6. Random pick, play via `AVAudioPlayer`, push ID to recently-played queue

---

## 6. Dynamic Slots (Analyst only, deferred)

"Analyst" personality uses pre-recorded sentence fragments with slots filled by `AVSpeechSynthesizer`:

- Clip: `"That's his {N} in a row"` → `AVSpeechSynthesizer` synthesises `"fourth"` on device
- Clip: `"Best {STAT} this month — {VALUE}"` → both slots dynamic

Pros: every session can reference that session's actual stats — feels alive. Cons: voice blending between human clip + synthesised slot is noticeable unless you cut clean.

**Implementation:** `AVSpeechSynthesizer` renders the slot text to audio data offline (cached for reuse), then concatenated with the human clip via `AVMutableComposition`. Pre-warm common values ("first" through "tenth", percentages in 5% increments) at app launch.

---

## 7. Settings UI

Added to Profile tab under a new "Commentary" section:

```
Commentary
├─ Enable                 [toggle: default ON]
├─ Personality            [picker: Hype Man, Broadcast]
├─ Volume                 [slider: 0–100, independent of session audio]
└─ Sample                 [button plays a test clip]
```

Stored in `PlayerProfile` (additive fields):
- `commentaryEnabled: Bool` (default true)
- `commentaryPersonality: String` (default "hype_man")
- `commentaryVolume: Double` (default 0.7)

---

## 8. Files Touched / Created

**New:**
- `HoopTrack/Services/CommentaryService.swift` — @MainActor, owns audio engine
- `HoopTrack/Services/CommentaryEventBus.swift` — Combine subject
- `HoopTrack/Utilities/ClipSelector.swift` — pure function over manifest (XCTest-able)
- `HoopTrack/Utilities/PacingQueue.swift` — pure state machine (XCTest-able)
- `HoopTrack/Models/CommentaryEvent.swift`
- `HoopTrack/Models/CommentaryClipManifest.swift`
- `HoopTrack/Views/Profile/CommentarySettingsView.swift`
- `HoopTrack/Audio/Commentary/` — asset bundle structure
- `HoopTrackTests/ClipSelectorTests.swift`
- `HoopTrackTests/PacingQueueTests.swift`
- `HoopTrackTests/CommentaryEventBusTests.swift`

**Modified:**
- `HoopTrack/Models/PlayerProfile.swift` — add 3 commentary fields (additive migration)
- `HoopTrack/Services/SessionFinalizationCoordinator.swift` — publish `sessionEnd`, `personalBest` events
- `HoopTrack/ViewModels/LiveSessionViewModel.swift` — publish `shotMade`, `shotMissed`, `streak` events
- `HoopTrack/ViewModels/GameSessionViewModel.swift` (SP2) — publish game-mode events
- `HoopTrack/ViewModels/PlayoffSeriesViewModel.swift` (SP3) — publish playoff events
- `HoopTrack/Utilities/Constants.swift` — new `HoopTrack.Commentary` enum
- `HoopTrack/Views/Profile/ProfileTabView.swift` — "Commentary" section
- `HoopTrack/Sync/DTOs/PlayerProfileDTO.swift` — sync the 3 new fields

---

## 9. Constants

```swift
enum Commentary {
    static let minGapBetweenClipsSec: Double = 2.0
    static let antiRepetitionWindow: Int = 15
    static let pacingQueueMax: Int = 3
    static let maxQueueAgeSec: Double = 5.0
    static let defaultVolume: Double = 0.7
    static let clipCooldownSec: Double = 30.0       // same-clip cooldown after playing
}
```

---

## 10. Voice-Pack Generation (content pipeline)

Asset generation happens outside the iOS app — a separate Python script in `hooptrack-ball-detection/` or a new sibling repo (likely a new repo: `hooptrack-audio/`). Rough pipeline:

1. Script generates N prompt lines per event category (e.g. 30 "shot_made" variants)
2. Feeds each to a voice-generation API (ElevenLabs v2, OpenAI TTS, Play.ht) with personality-specific voice ID
3. Output `.wav` files post-processed in ffmpeg: trim silence, normalise loudness (-16 LUFS integrated), encode m4a mono 64kbps
4. Generates `manifest.json` alongside clips
5. Commits result to `HoopTrack/Audio/Commentary/<personality>/`

**Tooling is a separate deliverable from SP4 code work.** Can parallelize: while engineers build `CommentaryService`, audio pipeline produces initial asset library.

---

## 11. Open Questions (deferred to SP4 brainstorm)

1. **Voice generation provider.** ElevenLabs has nice quality but commercial license terms are murky for "clone a voice → ship in a shipping iOS app." OpenAI TTS is straightforward licensing, less unique. Play.ht sits between. **Action required:** legal review BEFORE generating 400+ clips. Budget ~$200-400 for API credits per full personality library.
2. **Launch with 1, 2, or 3 personalities?** Trade-off: asset work for each. **My lean:** ship 2 at launch (Hype Man + Broadcast), add Analyst in a follow-up.
3. **Lite mode — ship before SP2 or as part of SP4 proper?** Depends on actual sequencing. **My lean:** architect for lite mode always being available (event subscription is lazy); actual rollout depends on work pace.
4. **Ducking vs ambient play alongside game sounds?** Shot-detection haptic/beep already exists. Commentary should duck (attenuate) other HoopTrack audio while speaking. AVAudioSession category config needed.
5. **User-customisable clip quiz?** Could let users rate clips thumbs-up/down to influence selection. Big feature creep — defer.
6. **Localisation?** All commentary in English for launch. Multi-language = multi-library × N — massive asset work. Flag as out-of-scope for SP4.

---

## 12. Exit Criteria

- `CommentaryService` plays a clip in response to a publicly fired `shotMade` event
- Settings toggle turns commentary on/off cleanly; no audio leaks when off
- Switching personality loads new manifest without glitches
- Anti-repetition verifiably prevents the same clip playing twice within 15 selections
- Pacing queue drops low-priority events when overloaded (unit-tested)
- Both shipped personalities have ≥ 200 clips covering every event type
- Volume slider independent of session audio (shot detection beep, haptics)
- Manual QA: 10-minute solo session + a 2v2 game + a playoff round, commentary sounds natural
- No audio-session conflicts with CV pipeline, HealthKit, background audio apps

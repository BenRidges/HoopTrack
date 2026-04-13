# HoopTrack — Backlog

Features not yet scheduled for implementation. Ready to spec and plan when prioritised.

---

## Phase 6 Deferrals

| Feature | Description | Effort estimate |
|---|---|---|
| **Haptics** | Tactile feedback: medium impact on shot log, success notification on badge earn, selection feedback on agility trigger, rhythm cues during dribble drills | Small (1–2 days) |
| **Watch Companion** | WatchKit app with glanceable today stats (shots, FG%, streak), session start/stop trigger from wrist, `CLKComplication` for daily goal progress | Medium (1–2 weeks) |

---

## Game Mode Features (Specced)

See `docs/superpowers/specs/2026-04-13-game-mode-features-design.md` for full design.

| Sub-Phase | Feature | Description | Effort estimate |
|---|---|---|---|
| 1 | **Game Mode Foundation** | Player registration (lineup scan), team assignment, GameSession/GamePlayer/GameShotRecord models, navigation integration | Large (1-2 weeks) |
| 2 | **Scoring & Box Score** | PlayerTracker CV service, player-attributed shot detection, live scoreboard with killfeed, post-game box score with per-player stats | Large (2-3 weeks) |
| 3 | **BO7 Playoff Mode** | Solo challenge mode — 4 rounds with escalating 3PT thresholds (40-70%), BO7 series per round, drill-gated retries after elimination | Medium (1-2 weeks) |
| 4 | **Live Commentary** | Event-driven pre-recorded audio commentary, 2-3 AI-generated voice personalities (Hype Man, Broadcast, Analyst), anti-repetition clip engine | Medium (1-2 weeks) |

---

## Future Phases

See `docs/extension-report.md` (written at end of Phase 6B) for a full strategic and technical breakdown of longer-term extensions including: social features, coach review mode, drill marketplace, backend/auth options, web dashboard, and CV model improvements.

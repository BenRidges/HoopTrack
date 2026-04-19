# Game Mode — Master Implementation Plan

**Date:** 2026-04-19
**Status:** Approved
**Scope:** Meta-planning doc for the 4-sub-phase Game Mode track. Sequences work, names dependencies, and lists cross-cutting concerns.

---

## 1. Overview

This doc structures the *delivery* of the Game Mode features defined in [2026-04-13-game-mode-features-design.md](2026-04-13-game-mode-features-design.md). That earlier spec defines **what** is being built (4 sub-phases: Foundation, Scoring, Playoff, Commentary). This one defines **how** — sequencing, dependency graph, risk register, and cross-cutting concerns that live above any one sub-phase.

Each sub-phase also has its own design doc (`2026-04-19-game-{foundation,scoring,playoff,commentary}-design.md`) covering architectural decisions at that level, with open questions explicitly flagged for later brainstorming when the sub-phase actually starts.

---

## 2. Roadmap Placement

Game Mode becomes a **new parallel track** on [docs/ROADMAP.md](../../../../docs/ROADMAP.md), matching the pattern CV Detection v2 established. New track entry:

| Track | Name | Status |
|---|---|---|
| Game | Game Mode Features (4 sub-phases) | 🔜 Ready to start (SP1) |

The existing placeholder "Phase 13 — Multiplayer Sessions 🔮 Future" is obsoleted by this track.

---

## 3. Dependency Graph

```
SP1 Foundation ──┬──► SP2 Scoring ──► SP3 Playoff
                 │
                 └──► SP4 Commentary (compatible with solo training too —
                                       can ship lite mode before SP1 if desired)
```

**Hard dependencies:**
- SP2 requires `GamePlayer`, `GameSession`, `GameShotRecord` from SP1
- SP3 reuses `GameShotRecord` + attribution from SP2

**Soft dependencies (strong recommend, not strict):**
- SP2's PlayerTracker benefits significantly from **CV-C (Kalman tracking layer)** landing first — otherwise Game Mode inherits the same ball-detection flicker that current solo sessions have, but now with player attribution layered on top, multiplying the failure surface
- SP4 works without SP1–3 in "solo training" subset mode (subset of events)

---

## 4. Recommended Sequence

1. **SP1 Foundation** (blocking everything else)
2. **SP2 Scoring** and **SP4 Commentary** in parallel (no overlap in code — SP2 is CV + UI, SP4 is audio engine + settings)
3. **SP3 Playoff** after SP2

**Rationale:** SP4 is independent and delivers user-facing value the day it ships (commentary works in existing solo sessions). Putting it behind SP2/SP3 would be arbitrary gatekeeping. Running SP2 and SP4 in parallel is safe because they touch entirely different subsystems.

---

## 5. CV Track Coordination

SP2's PlayerTracker is a **new CV subsystem** that runs alongside the existing `CVPipeline`. It's not an extension of `CVPipeline`; it's a sibling service subscribing to the same `framePublisher`.

**Coordination requirements:**
- Depends on Vision body-pose detection (already used by `PoseEstimationService` for Shot Science) — can share the `VNDetectHumanBodyPoseRequest` handler if we're careful, or run its own
- Does NOT depend on the yolo11m retrain currently running (ball detection is orthogonal to player tracking)
- Benefits from CV-C tracking layer — strongly recommend CV-C land before SP2 begins, but not a hard block

**What Game Mode does NOT do for CV:**
- Doesn't extend `BallDetector.mlmodel` (no new classes trained in)
- Doesn't produce training data for CV-A telemetry (appearance embeddings are game-scoped, not persisted for retraining)

---

## 6. Cross-Cutting Concerns

### 6.1 Shared data models

Three models (`GamePlayer`, `GameSession`, `GameShotRecord`) are defined in SP1 and consumed by SP2/SP3. To avoid accidental divergence, all three live in `HoopTrack/Models/` from SP1 with full final shape, even though some fields (e.g. `attributionConfidence`) aren't written until SP2.

### 6.2 Sync to Supabase

**Recommended: defer.** Game sessions are ephemeral (minutes, not weeks) and appearance embeddings have privacy implications (see 6.3). Leave `GameSession` local-only through all four sub-phases. Revisit post-SP3 once we know if users actually want game history in the cloud.

If deferred, mark the 3 new models as deliberately **not** adding `cloudSyncedAt`. This avoids the trap of "we'll sync it later" becoming "we accidentally ship biometric data to Supabase."

### 6.3 Privacy + consent on appearance embeddings

**This is the biggest non-technical risk on the track.** SP1's player registration captures an *appearance descriptor* of each participant — torso color histogram, height ratio, upper body pattern. This is not a photograph, but it *is* biometric-adjacent data.

Requirements:
- Appearance embeddings are **session-scoped only** — deleted when `GameSession` ends (`.completed` state)
- Registration UI must show a clear, plain-language consent screen before camera capture — "We're going to capture a short appearance profile so the app can track who shoots what. This is stored only until the game ends and never leaves your phone."
- Add to `PrivacyInfo.xcprivacy` manifest in SP1
- Add to `docs/production-readiness.md` as a P0 legal review item before App Store submission

Defer to privacy policy review before shipping SP1. Out of scope to resolve in this track.

### 6.4 UI consistency

All in-game views (`LiveGameView`, `LivePlayoffView`) use the **landscape hosting** pattern established by `LiveSessionView` / `LandscapeHostingController`. Post-game views (`GameSummaryView`) revert to portrait.

### 6.5 Testing strategy

- **Pure logic:** follow the existing XCTest convention — calculators, state machines, zone analysis functions get unit tests
- **PlayerTracker:** cannot be tested with XCTest alone. Needs fixture-based evaluation — short `.mov` clips with hand-labeled player-shot attribution used to measure attribution accuracy on CI or pre-merge. Pattern exists in `docs/upgrade-cv-detection.md` ("BallDetectorEvalTests", "MakeMissPipelineEvalTests") — reuse it
- **Commentary:** event-emission logic unit-tested; clip selection + audio playback manually QA'd

---

## 7. Risk Register

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| CV attribution accuracy below usable threshold in SP2 | High | Medium | Fixture-based eval set before UI polish; fallback to manual-assignment UI for unattributed shots |
| Appearance embedding triggers privacy regulator scrutiny | High | Low (dev-stage) → Medium (shipped) | Session-scoped only; plain-language consent; privacy manifest; legal review before SP1 ships |
| ElevenLabs commercial license terms for voice cloning | Medium | Medium | Evaluate alternatives (OpenAI TTS, Play.ht, self-hosted XTTS); confirm license before generating 400+ clips per personality |
| Voice-clip asset size bloats app binary | Medium | High | Compress aggressively (m4a 64kbps mono); bundle only selected personality on first launch, download others on demand |
| Scope creep into referees/rebounds/assists | Medium | High | Original spec flags these as out-of-scope; master plan restates it; reject during per-sub-phase brainstorming |
| Multi-player CV pipeline too slow for 30fps on older iPhones | Medium | Medium | Run PlayerTracker at reduced cadence (15fps) independent of ball detection; profile on iPhone SE 2 before SP2 merge |
| SP3 playoff thresholds (40/50/60/70%) feel punishing or trivial in playtesting | Low | Medium | Keep thresholds in `HoopTrack.Playoff` constants; easy to tune post-SP3 based on user feedback |

---

## 8. Open Questions Carried Forward

Intentionally deferred to per-sub-phase brainstorming (see each sub-phase spec for the full list):

- **SP1:** Sync to Supabase? Link to PlayerProfile? Retention after game ends?
- **SP2:** Appearance embedding algorithm — hand-rolled, VisionKit, or a dedicated ML model? Multi-camera support?
- **SP3:** Are 40/50/60/70% the right threshold curve? How many retries allowed per round? "Hall of champions"?
- **SP4:** ElevenLabs vs alternatives? Launch with how many personalities? "Lite" mode for existing solo training sessions?

---

## 9. Rough Sizing

| Sub-Phase | Rough estimate | Notes |
|---|---|---|
| SP1 Foundation | ~1 week | Data models, registration UI, privacy consent screen, navigation glue |
| SP2 Scoring | ~3–4 weeks | PlayerTracker is the hardest piece; LiveGameView + box score substantial |
| SP3 Playoff | ~2 weeks | State machine + drill generation + UI; reuses a lot of SP2 infra |
| SP4 Commentary | ~2 weeks of *code* | Excludes voice-pack generation time (could be 1–2 weeks of asset work on its own, done in parallel during SP2) |

Total: roughly 8–10 weeks wall-clock if SP2 + SP4 run in parallel. Longer if sequential.

---

## 10. Post-SP3 Evaluation

Before starting any "future" features (referee, 5v5, online multiplayer), pause for a **Game Mode retrospective**:
- Did attribution work in real game conditions?
- Do users actually play multiple playoff rounds, or one-and-done?
- Did commentary enhance or annoy?
- What's the App Store support volume for game-mode-specific bugs?

These answers shape whether Game Mode gets deeper investment or sits as-is.

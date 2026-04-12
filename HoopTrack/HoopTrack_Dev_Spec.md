# HoopTrack
## Personal Basketball Progress Tracker — Project Summary

| | |
|---|---|
| **Platform** | iOS 16+ (iPhone 14 primary target) |
| **Stack** | Swift 5.9+, SwiftUI, SwiftData, Combine, MVVM |
| **Architecture** | `@MainActor final class` ViewModels, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` project-wide |
| **Current Status** | Phase 6B complete — production-ready local app |
| **Next Phase** | Phase 7 — Security & Privacy (see `docs/ROADMAP.md`) |

---

## What Was Built

### App Foundation
- Tab-bar navigation: **Home**, **Train**, **Progress**, **Profile**
- SwiftData persistence via `DataService` abstraction (`PlayerProfile`, `TrainingSession`, `ShotRecord`, `GoalRecord`)
- `HoopTrackMigrationPlan` with versioned schema migrations (V1 → V2)
- `CoordinatorHost` + `AppState` for navigation and `hooptrack://` deep link routing
- `NotificationService` for streak reminders and goal milestones
- JSON data export via `ExportService` with `SessionExportRecord` + `ShotExportRecord`
- `MetricsService` (MetricKit subscriber) wired at launch for on-device performance monitoring

### Computer Vision Pipeline
- `CameraService` — AVCaptureSession at 60fps, rear/front camera switching, session recording to `Documents/Sessions/<uuid>.mov`
- `CVPipeline` — shot detection state machine: `idle → tracking → release_detected → resolved`
- `CourtCalibrationService` — hoop detection and court position normalisation to 0–1 half-court coordinate space; shot detection gated on `isCalibrated`
- `PoseEstimationService` — Vision body pose (`VNDetectHumanBodyPoseRequest`) for rear camera; derives release angle, jump height, leg angle, consistency score
- `DribblePipeline` — front-camera hand tracking for dribble drills with AR overlays (`DribbleARViewContainer`)
- `CourtZoneClassifier` — classifies shots into `paint`, `freeThrow`, `midRange`, `cornerThree`, `aboveBreakThree`
- `BallDetector.mlpackage` — Core ML ball detection model; `build_basketball_model.py` for training via Roboflow + coremltools

### Training & Session Types
- **Free Shoot** — live shot tracking with real-time FG% HUD, zone detection, make/miss confirmation
- **Dribble Drills** — front-camera dribble speed, hand balance, combo detection, AR floor targets
- **Agility Drills** — shuttle run, lane agility, vertical jump; `AgilityAttempt` in-session only (not persisted); aggregates written to `TrainingSession`
- `SessionFinalizationCoordinator` — 7-step post-session pipeline: HealthKit, goal updates, skill ratings, badge evaluation, streak tracking

### Analytics & Progress
- `SkillRatingService` + `SkillRatingCalculator` — multi-dimensional ratings: FG%, dribble speed, agility, Shot Science, consistency, volume
- `BadgeEvaluationService` + `BadgeScoreCalculator` — badge tiers and earned badge history
- `GoalUpdateService` — progress tracking against user-defined numeric goals
- Swift Charts integration for trend lines, FG% history, weekly volume, zone breakdown
- Shot chart heat map via SwiftUI Canvas (custom court renderer)

### System Integrations
- **HealthKit** — writes `HKWorkoutType.basketball` sessions
- **Siri Shortcuts** — `StartFreeShootSessionIntent`, `ShowMyStatsIntent`, `ShotsTodayIntent` via App Intents; `HoopTrackShortcuts` provider
- **URL scheme** — `hooptrack://train`, `hooptrack://progress`, etc. routed via `AppState`
- **iCloud** — optional CloudKit sync toggle in Profile settings

---

## Performance Targets (validated on iPhone 14 / A15 Bionic)

| Metric | Target |
|---|---|
| CV frame processing | < 20ms per frame |
| Shot detection latency | < 0.5s from release |
| App launch to camera ready | < 3s cold start |
| Battery (60 min session) | < 20% drain |
| Storage per session | < 300MB per 30 min |
| Make/miss accuracy | > 92% indoor lighting |
| Release angle error margin | < 3 degrees |

---

## Design Principles

- **Solo-player first** — single iPhone on a stand, no accessories required
- **Offline-capable** — all core tracking works without internet
- **No third-party dependencies** — all CV, charts, AR, and data use Apple-native frameworks only
- **Progress-centric** — every feature serves measurable personal improvement
- **Portrait-only** — locked to portrait; landscape breaks CV coordinate mapping

---

## What's Next

See [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full phase plan.  
Immediate next step: **Phase 7 — Security & Privacy** (Keychain, PrivacyInfo.xcprivacy, ATS, file protection) before any backend work begins.

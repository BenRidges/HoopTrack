# HoopTrack — Implementation Roadmap

**Last updated:** 2026-04-19  
**Status:** Phases 1–12 complete. Game Mode parallel track opened — SP1 Foundation shipped (data models, appearance capture, registration flow, manual-scoring live game). CV Detection v2 parallel track still open; Phase CV-A ready to start.

---

## Overview

| Phase | Name | Status |
|---|---|---|
| 1 | Foundation | ✅ Complete |
| 2 | CV Pipeline | ✅ Complete |
| 3 | Shot Science | ✅ Complete |
| 4 | Dribble Drills | ✅ Complete |
| 5A | Goals, Skill Ratings & Badges | ✅ Complete |
| 5B | Badge UI & Agility Drills | ✅ Complete |
| 6A | Siri Shortcuts, Data Export & Performance | ✅ Complete |
| 6B | UI Polish, Refactor & Extension Report | ✅ Complete |
| 7 | Security & Privacy | ✅ Complete |
| 8 | Authentication & Identity | ✅ Complete |
| 9 | Backend & Database | ✅ Complete |
| 10 | File & Media Storage (local-only) | ✅ Complete |
| 11 | Accessibility | ✅ Complete |
| 12 | Web Presence | ✅ Complete |
| CV | CV Detection v2 (parallel track) | 🔜 Ready to start (Phase A) |
| Game | Game Mode Features (parallel track — 4 sub-phases) | 🟡 In progress (SP1 ✅, SP2–SP4 planned) |
| 13 | Multiplayer Sessions (superseded by Game track) | 🗄️ Deprecated |
| 14 | Web Dashboard | 🔮 Future |
| 15 | Coach Review Mode | 🔮 Future |
| 16 | Teams & Organisations | 🔮 Future |

---

## Completed Phases

### Phase 1 — Foundation
Core app scaffolding: SwiftUI + SwiftData MVVM architecture, `PlayerProfile` / `TrainingSession` / `ShotRecord` / `GoalRecord` models, tab navigation (`Home`, `Train`, `Progress`, `Profile`), `DataService` persistence abstraction, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` project-wide.

### Phase 2 — CV Pipeline
`CameraService` (AVCaptureSession lifecycle), `CVPipeline` shot detection state machine (`idle → tracking → release_detected → resolved`), `CourtCalibrationService` (hoop detection + court position normalisation to 0–1 half-court space). Shot detection gated on `isCalibrated`.

### Phase 3 — Shot Science
`PoseEstimationService` using Vision body pose (`VNDetectHumanBodyPoseRequest`) for rear camera. Metrics: release angle, elbow alignment, shot arc, follow-through consistency. `TrainingSession.recalculateStats()` caches aggregate Shot Science averages and consistency score.

### Phase 4 — Dribble Drills
`DribblePipeline` with front-camera hand tracking for dribble drills. `DribbleDrillView` with AR overlay (`DribbleARViewContainer`). Dribble session metrics tracked separately from shot sessions via `DataService.finaliseDribbleSession()`.

### Phase 5A — Goals, Skill Ratings & Badges (Data Layer)
`SkillRatingService` + `SkillRatingCalculator` (multi-dimensional: FG%, dribble speed, agility, Shot Science). `BadgeEvaluationService` + `BadgeScoreCalculator`. `GoalUpdateService`. `SessionFinalizationCoordinator` orchestrating all post-session steps. SwiftData migration plan with `HoopTrackSchemaV1` → V2.

### Phase 5B — Badge UI & Agility Drills
`BadgeBrowserView`, `BadgeRankPill`, `BadgesUpdatedSection` summary card. `AgilitySessionView` + `AgilitySessionViewModel` (shuttle run + lane agility + vertical jump). `AgilityAttempt` in-session only (not persisted); aggregates written to `TrainingSession`.

### Phase 6A — Siri Shortcuts, Data Export & Performance
**Siri Shortcuts:** `StartFreeShootSessionIntent`, `ShowMyStatsIntent`, `ShotsTodayIntent` via App Intents; `HoopTrackShortcuts` provider. `hooptrack://` URL scheme registered; `AppState` + `onOpenURL` deep link routing.  
**Data Export:** `ExportService` with `SessionExportRecord` + `ShotExportRecord` Codable structs; JSON export replaces CSV in `ProfileTabView`; `ExportServiceTests` coverage.  
**Performance:** `MetricsService` (MetricKit subscriber); `fetchSessions(since:limit:)` on `DataService`; `autoreleasepool` in `captureOutput`; `ProgressViewModel.load()` force-unwrap removed.

### Phase 6B — UI Polish, Refactor & Extension Report
Onboarding flow (`OnboardingView`), loading/empty states, animations. Refactor analysis report identifying 10 issues (2 critical: duplicate `ModelContainer` in `ProfileTabView`, `DispatchQueue.main.async` in `@MainActor` class). Extension report capturing strategic vision and technical options brief for future growth.

### Phase 7 — Security & Privacy
Full security hardening before backend introduction. **Subagent-driven development** (7 tasks) followed by a **4-domain parallel security review** across the full codebase.

**New files:**
- `Utilities/KeychainService.swift` — `@MainActor final class`; `Security.framework` wrapper; `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; biometric-protected storage; `deleteAll()` for GDPR wipe
- `Utilities/InputValidator.swift` — pure `enum`; validates release angle (0–90°), jump height (0–120 cm), court coordinates (0–1), profile name sanitisation
- `Utilities/PinningURLSessionDelegate.swift` — SPKI SHA-256 cert pinning; EC P-256 header prepend; placeholder hash for Phase 9
- `PrivacyInfo.xcprivacy` — App Store privacy manifest; FileTimestamp (C617.1), UserDefaults (CA92.1) reason codes; Health + VideoAndSoundData declared
- `HoopTrack.KeychainKey` constants added to `Constants.swift`

**Modified files:**
- `DataService` — `deleteAllUserData()` (GDPR: SwiftData, files, Keychain, UserDefaults); input validation in `addShot/updateShot/resolveShot`; `locationTag` sanitisation; `ExportService` file protection gap fixed
- `VideoRecordingService` — `FileProtectionType.complete` on session videos; `Task { @MainActor }` pattern
- `HoopTrackApp` — `configureSessionsDirectoryProtection()` applies protection at launch
- `CameraService`, `CVPipeline`, `CourtCalibrationService`, `DribblePipeline` — all `DispatchQueue.main.async` → `Task { @MainActor [weak self] in }`
- `LiveSessionViewModel` — court coordinate validation before `ShotRecord` write
- `ProfileViewModel` — `sanitisedProfileName()` before persisting; `deleteAllData()` entry point
- `OnboardingView` — name sanitised before UserDefaults write
- `ProfileTabView` — "Delete All My Data" destructive button + HealthKit disclosure
- `NotificationService` — `DispatchQueue.main.async` → `Task { @MainActor }`
- `CourtZoneClassifier` — defence-in-depth NaN/Inf guard via `InputValidator`
- `ExportService` — `FileProtectionType.complete` on exported JSON

**Tests added:** `KeychainServiceTests` (5), `InputValidatorTests` (10), `DataServiceDeleteTests` (4), `CourtZoneClassifierTests` (4 new cases). Full suite: 151 tests, 0 failures.

### Phase 8 — Authentication & Identity
Supabase email + password auth with biometric re-lock. **Sign in with Apple deliberately skipped** — not required for App Store compliance when no other social providers are offered; can be added later as an additional `AuthProviding` implementation without touching the view model. No Apple Developer membership required for this phase.

**New files:**
- `HoopTrack/Auth/AuthState.swift` — state enum: `unauthenticated / authenticating / authenticated(user) / locked(user) / error(AuthError)`
- `HoopTrack/Auth/AuthError.swift` — localized error enum with 12 cases
- `HoopTrack/Auth/AuthUser.swift` — `Sendable, Codable, Equatable` identity value type
- `HoopTrack/Auth/AuthProviding.swift` — protocol isolating the Supabase SDK from the view model + tests
- `HoopTrack/Auth/AuthViewModel.swift` — `@MainActor` state machine (12 TDD tests)
- `HoopTrack/Auth/SupabaseAuthProvider.swift` — production `AuthProviding` impl wrapping `supabase-swift`'s `Auth` product
- `HoopTrack/Auth/SupabaseClient+Shared.swift` — `AuthClient` singleton + `KeychainAuthStorage` adapter (session tokens into the keychain)
- `HoopTrack/Auth/BiometricService.swift` — `LAContext` wrapper for Face ID / Touch ID unlock
- `HoopTrack/Auth/BackendSecrets.swift.example` — template for the gitignored `BackendSecrets.swift`
- `HoopTrack/Views/Auth/AuthGate.swift` — top-level router reading `AuthState`
- `HoopTrack/Views/Auth/SignInView.swift` — email + password sign-in form
- `HoopTrack/Views/Auth/SignUpView.swift` — sign-up form with password-match validation
- `HoopTrack/Views/Auth/VerifyEmailView.swift` — "check your inbox" screen with refresh/resend/sign-out
- `HoopTrack/Views/Auth/LockedView.swift` — biometric unlock after background timeout
- `HoopTrackTests/Mocks/MockAuthProvider.swift` — in-memory stub with scripted responses
- `HoopTrackTests/AuthViewModelTests.swift` — 12 tests covering every state-machine transition
- `HoopTrackTests/AuthErrorTests.swift` — 4 tests for error description / equatability

**Modified files:**
- `HoopTrack/HoopTrackApp.swift` — `WindowGroup` wraps `CoordinatorHost` in `AuthGate`; scene-phase observer triggers `authViewModel.lock()` after 60s of backgrounding
- `HoopTrack/CoordinatorHost.swift` — watches `AuthViewModel.state` and calls `DataService.linkSupabaseUser(id:)` on authenticate
- `HoopTrack/Services/DataService.swift` — new `linkSupabaseUser(id:)` method
- `HoopTrack/Models/PlayerProfile.swift` — adds `supabaseUserID: String?` (Phase 9 RLS will key on this)
- `HoopTrack/Models/Migrations/HoopTrackSchemaV1.swift` — adds `HoopTrackSchemaV3` for future explicit-migration use
- `HoopTrack/Models/Migrations/HoopTrackMigrationPlan.swift` — adds V2→V3 lightweight stage
- `HoopTrack/Utilities/Constants.swift` — `HoopTrack.Backend` (URL + anon key proxies) + `HoopTrack.Auth.backgroundLockTimeoutSec` + `HoopTrack.Auth.minPasswordLength`
- `HoopTrack/Views/Profile/ProfileTabView.swift` — Account section with email + sign-out
- `HoopTrack/Info.plist` — adds `NSFaceIDUsageDescription`
- `.gitignore` — `**/BackendSecrets.swift`

**External dependencies added:** `supabase-swift` (SPM) — products `Auth`, `Functions`, `PostgREST`, `Realtime`, `Storage`. Phase 8 only consumes `Auth`.

**Tests added:** `AuthViewModelTests` (12), `AuthErrorTests` (4). Full suite: **184 tests**, 1 skipped, 0 failures, 0 warnings.

**Deferred to a later phase:**
- Sign in with Apple as an additional `AuthProviding` impl.
- Sign in with Google (same pattern).
- Formal lightweight SwiftData migration plan (V2→V3 is additive and handled automatically; `HoopTrackMigrationPlan` stays in place for the first non-additive change).

**Notes for Phase 9:**
- `PlayerProfile.supabaseUserID` is set on every successful sign-in and is the canonical key for RLS `auth.uid()` matching.
- `SupabaseContainer.auth` is a standalone `AuthClient` — Phase 9 will compose it with `PostgREST` and `Storage` into a richer wrapper.
- `PinningURLSessionDelegate.pinnedHashes` still holds a placeholder SPKI SHA-256; must be replaced with the real Supabase hash before Phase 9 ships.

### Phase 9 — Backend & Database
Cloud sync turned on. Every session, shot, goal, and badge mirrors into Supabase Postgres after local save. Row Level Security per-table on `auth.uid()`. Fire-and-forget pattern so network failure never blocks local UX.

**Schema + RLS shipped to main Supabase project (`nfzhqcgofuohsjhtxvqa`):**
- `player_profiles` — 22 cols, PK on `user_id`. R/W own row.
- `training_sessions` — 28 cols, R/W/D own rows. `video_file_name` deliberately omitted (device-local path, meaningless server-side).
- `shot_records` — **append-only** (RLS has select + insert policies only; no update/delete). Indexed on `(user_id, timestamp)` and `(session_id)`.
- `goal_records` — full CRUD on own rows.
- `earned_badges` — unique constraint `(user_id, badge_id)`; full CRUD except delete.
- 16 RLS policies total, all keyed on `auth.uid()`.
- Shared `handle_updated_at` trigger maintains `updated_at` on the 4 mutable tables.

**New files:**
- `HoopTrack/Models/` — added `cloudSyncedAt: Date?` to PlayerProfile, TrainingSession, ShotRecord, GoalRecord, EarnedBadge
- `HoopTrack/Sync/SupabaseDataServiceProtocol.swift` — write-only CRUD protocol
- `HoopTrack/Sync/SupabaseDataService.swift` — PostgREST implementation
- `HoopTrack/Sync/SyncCoordinator.swift` — orchestrates uploads, stamps `cloudSyncedAt` on success
- `HoopTrack/Sync/DTOs/` — 5 Codable row mirrors (PlayerProfileDTO, TrainingSessionDTO, ShotRecordDTO, GoalRecordDTO, EarnedBadgeDTO) with snake_case CodingKeys
- `HoopTrackTests/Mocks/MockSupabaseDataService.swift` — in-memory stub with call recorders
- `HoopTrackTests/Sync/SupabaseDataServiceDTOTests.swift` — 7 DTO round-trip tests
- `HoopTrackTests/Sync/SyncCoordinatorTests.swift` — 8 orchestration tests

**Modified files:**
- `HoopTrack/Auth/SupabaseClient+Shared.swift` — added `SupabaseContainer.postgrest()` that builds a fresh PostgrestClient per call with the current JWT
- `HoopTrack/Services/SessionFinalizationCoordinator.swift` — step 8 `kickOffSync(session:profile:)` fires after every shooting/dribble/agility finalize. Skips if no coordinator injected, no signed-in user, `endedAt == nil`, or `durationSeconds < 30`.
- `HoopTrack/CoordinatorHost.swift` — builds and injects `SyncCoordinator` into the finalization coordinator
- `HoopTrack/Utilities/PinningURLSessionDelegate.swift` — replaced placeholder SPKI hash with live Supabase values (Google Trust Services WE1 intermediate + supabase.co leaf, both EC P-256)

**External dependencies:** `supabase-swift` `PostgREST` product (added in Phase 8, consumed here for the first time).

**Tests added:** 7 DTO + 8 SyncCoordinator = 15 new. Full suite: **199 tests**, 1 skipped, 0 failures, 0 warnings.

**Deferred to Phase 9.5:**
- `InitialSyncCoordinator` — batch-upload existing local history for users upgrading from pre-Phase-9 builds (current sync starts from the NEXT session).
- Cross-device restore path — fetch rows back down from Supabase on a fresh device.
- Hasura GraphQL, Supabase Edge Functions, Realtime.
- Wiring `PinningURLSessionDelegate` into the supabase-swift URLSession (currently the delegate has real hashes but isn't routed to; flagged P0 in production-readiness).
- Stable enum export keys — DTOs today use display-string `rawValue`s (e.g. "Free Shoot"); a renumber of those labels would break old rows.

**Notes for Phase 10:**
- Video file columns are intentionally absent from `training_sessions` — Phase 10 will introduce Supabase Storage URLs for pinned sessions only.

---

## Deferred Items (Not Yet Scheduled)

| Feature | Effort | Notes |
|---|---|---|
| **Haptics** | Small (1–2 days) | Shot make/miss, badge earn, agility trigger, dribble rhythm cues |
| **Watch Companion** | Medium (1–2 weeks) | Glanceable today stats, session start/stop from wrist, `CLKComplication` |
| **OpenAI Vision post-session** | Small–Medium | Send key frames for shot form feedback |

---

## Upcoming Phases

---

### Phase 8 — Authentication & Identity ⭐ NEXT
**Prerequisite:** Phase 7 ✅ (`KeychainService`, `PinningURLSessionDelegate`, `PrivacyInfo.xcprivacy` all in place).  
**Note:** Replace `PinningURLSessionDelegate.pinnedHashes` placeholder with real Supabase SPKI SHA-256 before Phase 9 ships.  
**Reference:** [upgrade-authentication-identity.md](upgrade-authentication-identity.md)

| Task | Detail |
|---|---|
| Sign in with Apple | `AuthenticationServices` framework; `ASAuthorizationController`; first-time vs returning user flow |
| Supabase Auth | `supabase-swift` SPM dependency; `AuthLocalStorage` backed by `KeychainService`; session persistence |
| `AuthViewModel` | States: `unauthenticated / authenticating / authenticated / error`; `SignInWithAppleCoordinator` as delegate |
| App entry flow | `HoopTrackApp.swift` routes to `AuthView` or `CoordinatorHost` based on auth state |
| `PlayerProfile.supabaseUserID` | Add `supabaseUserID: String?` optional field; SwiftData `SchemaV3` lightweight migration |
| Biometric re-auth | `BiometricService` using `LAContext`; scene-phase-based timeout (default 60s) |
| Sign-out | Keep local SwiftData by default; destructive clear-all requires explicit confirmation |

**Key files to create:**
- `HoopTrack/HoopTrack/Services/Auth/AuthViewModel.swift`
- `HoopTrack/HoopTrack/Services/Auth/SignInWithAppleCoordinator.swift`
- `HoopTrack/HoopTrack/Services/Auth/BiometricService.swift`
- `HoopTrack/HoopTrack/Views/Auth/AuthView.swift`

---

### Phase 9 — Backend & Database
**Prerequisite:** Phase 8 complete (auth + user IDs must exist before syncing data).  
**Reference:** `docs/upgrade-backend-api.md`, `docs/upgrade-postgresql-supabase.md`

| Task | Detail |
|---|---|
| Supabase project | Create project; configure region; `Config.xcconfig` for anon key (out of source control) |
| Postgres schema | DDL for `player_profiles`, `training_sessions`, `shot_records`, `goal_records`; indexes; foreign keys; RLS policies |
| Row Level Security | Per-table policies using `auth.uid()`; `shot_records` has no DELETE policy (append-only enforced at DB) |
| `supabase-swift` SDK | SPM dependency; `SupabaseClient.shared` singleton in `HoopTrackApp.swift` |
| `SupabaseDataService` | `async/await` service parallel to `DataService`; CRUD + batch upsert; `SyncError` enum |
| SwiftData migration | `SchemaV2` adds `cloudSyncedAt: Date?` to all four models; `InitialSyncCoordinator` batch-upserts existing records |
| Sync hook | New step 8 in `SessionFinalizationCoordinator.finaliseSession(_:)` — fire-and-forget `Task`; non-fatal |
| Conflict resolution | Last-write-wins for scalar fields (via `updatedAt`); set-union for `shot_records` (no shots ever dropped) |
| Hasura GraphQL | Connect Hasura Cloud to Supabase Postgres; lightweight `GraphQLClient` over `URLSession` (no Apollo) |
| Supabase Edge Functions | Leaderboard aggregation, export triggers |

**Key files to create:**
- `HoopTrack/HoopTrack/Services/SupabaseDataService.swift`
- `HoopTrack/HoopTrack/Services/APIService.swift`
- `HoopTrack/HoopTrack/Services/InitialSyncCoordinator.swift`
- `supabase/migrations/001_initial_schema.sql`

---

### Phase 10 — File & Media Storage (local-only) ✅
Scoped-down from the original cloud-upload plan. Videos stay on-device; the user decides what to keep.

**Changes:**
- `PlayerProfile.videosAutoDeleteDays` default 60 → 7 (new accounts only; existing users keep their current setting)
- Profile settings picker options: **7 / 14 / 30 days / Never** (was 30/60/90/Never)
- `SessionSummaryView` — "Save video" toggle flips `session.videoPinnedByUser`; caption shows expiry ("Auto-deletes in N days" vs "Kept on this device until you unpin")
- `CoordinatorHost.CoordinatorBox.build` — calls `DataService.purgeOldVideos(olderThanDays:)` on launch using the profile's retention value (skipped when set to Never)
- `HoopTrack.Storage.defaultVideoRetainDays = 7`, new `allowedVideoRetainDays = [7, 14, 30]`

**Deferred to a future phase (when cross-device playback is actually needed):**
- Supabase Storage bucket + `VideoUploadService` background upload
- Signed-URL playback + coach share links
- `AVMutableComposition` highlight export with stats overlay
- Cloudflare R2 egress migration path

See original task breakdown in git history if the cloud track is revived. Flag in `docs/production-readiness.md` if App Store submission requires server-side video.

---

### Phase 11 — Accessibility ✅
WCAG 2.1 AA pass across shipped views. Merged in commit `697fce0`.

**Changes:**
- `Color+Brand.swift` — `brandOrangeAccessible` (lightened for 4.5:1 on dark backgrounds); used across Home, Agility, Live session
- VoiceOver labels + hints on `HomeTabView`, `ProgressTabView`, `TrainTabView`, `BadgeBrowserView`, `CourtMapView`, `LiveSessionView`, `AgilitySessionView`, `DribbleDrillView`
- `ShimmerModifier` + agility pulse + dribble end-session press gated on `accessibilityReduceMotion`
- Dynamic-type migration: 27 hard-coded `.system(size: N)` → semantic styles (`.title2`, `.largeTitle`, etc.) + `@ScaledMetric` for agility timer
- `LiveSessionViewModel.postShotAnnouncement` — `UIAccessibility.post(.announcement, ...)` on make/miss, throttled to 2s
- `accessibilityInputLabels` on make/miss buttons and quick-start for Voice Control

---

### Phase CV — CV Detection v2 (parallel track)
**Can run in parallel with Phases 8–12 — no infrastructure dependency for Phase A. High priority: shipped v1 BallDetector.mlmodel (mAP50 0.988 on public data) is a baseline, not the ceiling. Real accuracy gains require real HoopTrack footage, which requires telemetry first.**  
**Reference:** [upgrade-cv-detection.md](upgrade-cv-detection.md)

Six sub-phases. Phase A is the only one with zero upstream dependency and gates everything downstream.

| Sub-phase | Name | Depends on | Status |
|---|---|---|---|
| CV-A | Telemetry Foundation | none (uses existing `CVPipeline`, `DataService`) | 🔜 Ready to start |
| CV-B | Detector v2 (multi-class retrain) | CV-A (≥ 2k labeled frames from real sessions) | Blocked on CV-A data |
| CV-C | Tracking Layer (Kalman) | none — can run in parallel with CV-B | Independent |
| CV-D | Make/Miss v2 (homography + net-motion) | CV-B + CV-C | Blocked on CV-B, CV-C |
| CV-E | Audio Classifier | CV-A (audio data) | Parallel with CV-D |
| CV-F | ML Re-ranker (ambiguous cases only) | CV-D + CV-E | Only if error rate still > 2% |

#### Phase CV-A — Telemetry Foundation ⭐ START HERE

Captures per-shot ball track, rim/backboard boxes, short video + audio clips, and pipeline confidence. Surfaces a user-review sheet in `SessionSummaryView` so users label ambiguous shots — double-duty as a UX win and a labeled-data generator.

| Task | Detail |
|---|---|
| `ShotTelemetry` SwiftData model | One per `ShotRecord`, linked by `shotID`; includes ball track JSON, confidence, geometric verdict, audio/video clip paths |
| `TelemetryService` | `@MainActor final class`; persist telemetry; enforce retention (`HoopTrack.Storage.telemetryRetainDays`); `FileProtectionType.complete` on clip files |
| `CVPipeline` extension | Ring-buffer last ~150 frames of detections; emit `ShotTelemetry` on `resolved` transition |
| `CameraService` audio | Synchronized mic capture for shot-window audio clips (3s) |
| `ShotReviewSheet` | End-of-session review for shots with `predictedConfidence < 0.7`; user correction updates `ShotRecord.wasMade` and triggers `recalculateStats()` |
| Privacy settings | "Help improve shot detection" toggle (default OFF); `PrivacyInfo.xcprivacy` telemetry category |
| `TelemetryUploadService` stub | Queue interface only; wires to Supabase Storage in Phase 9 |
| Eval fixture | `HoopTrackTests/Fixtures/ShotEvalSet/` + `BallDetectorEvalTests`, `MakeMissPipelineEvalTests` |
| `DataService.deleteAllUserData()` | Extend to purge `ShotTelemetry` + `Documents/Telemetry/` |

**Integrates with existing Phase 7 security layer:** `KeychainService` not needed (telemetry is not auth data), but `FileProtectionType.complete` on all clip files follows the same pattern as `Documents/Sessions/`. All validation uses `InputValidator`.

**Dependency on Phase 9:** `TelemetryUploadService` only goes live once Supabase is in place. Everything else works offline from day one.

#### Phase CV-B through CV-F

See [upgrade-cv-detection.md](upgrade-cv-detection.md) for full task breakdowns. Summary:

- **CV-B**: Retrain on 2–3k HoopTrack-native labeled frames; unify ball + rim + backboard into one model; swap `CourtCalibrationService` rim detection to consume it.
- **CV-C**: `Services/BallTracker.swift` with constant-velocity Kalman filter; `CVPipeline` state machine becomes velocity-driven.
- **CV-D**: `Services/MakeMissClassifier.swift` with rim-plane homography (45.7 cm rim as scale reference); net-motion confirmation via ROI pixel diff; 800 ms rebound window.
- **CV-E**: `AudioShotClassifier.mlpackage`; MFCC + small CNN; fused with visual verdict in `MakeMissClassifier`.
- **CV-F**: Only if CV-D + CV-E leave > 2% silent errors. Small 3D CNN re-ranker; runs only on ambiguous shots.

**Success criteria:** see the success-criteria table in [upgrade-cv-detection.md](upgrade-cv-detection.md) — mAP50 ≥ 0.90 on real HoopTrack footage, make recall ≥ 97%, miss precision ≥ 95%, < 1 user correction per 50 shots.

---

### Phase 12 — Web Presence
**Prerequisite Phase A:** None — marketing site is standalone.  
**Prerequisite Phase B:** Phase 9 complete (iOS must be writing to Supabase).  
**Reference:** `docs/upgrade-web-presence.md`

#### Phase 12A — Marketing Site
| Task | Detail |
|---|---|
| Next.js project | `npx create-next-app@latest hooptrack-web`; App Router; Tailwind with `#FF6B35` brand |
| Pages | `/` hero + App Store CTA, `/features`, `/privacy`, `/support` |
| SEO | `metadata` exports, Open Graph, `sitemap.ts` |
| Analytics | PostHog with `persistence: "memory"` until cookie consent |
| Deploy | Vercel + custom domain; GitHub Actions typecheck on PRs |

#### Phase 12B — Web Dashboard
| Task | Detail |
|---|---|
| Auth | `@supabase/ssr` Next.js middleware; Sign in with Apple web OAuth flow; HTTP-only session cookies |
| Routes | `/dashboard`, `/dashboard/sessions`, `/dashboard/sessions/[id]`, `/dashboard/progress`, `/dashboard/goals` |
| Shot chart | SVG half-court diagram; dots at normalised `court_x`/`court_y`; zone heat map; hover tooltips |
| Progress charts | Recharts `LineChart` for FG% trend + skill ratings; weekly volume bar chart; zone doughnut |
| Real-time | `useRealtimeShots` hook via Supabase Realtime for live session monitoring |
| Performance | Server Components for initial render; virtual scrolling for shot timelines; weekly bucketing for long-range trend charts |

---

## Game Mode Track (parallel)

### Game Track — Overview

A 4-sub-phase track replacing the original Phase 13 "Multiplayer Sessions" placeholder. Scope and sequencing defined in:

- [Master Plan](../HoopTrack/docs/superpowers/specs/2026-04-19-game-mode-master-plan.md) — cross-cutting concerns, dependency graph, risk register
- [SP1 Foundation Design](../HoopTrack/docs/superpowers/specs/2026-04-19-game-foundation-design.md)
- [SP2 Scoring & Box Score Design](../HoopTrack/docs/superpowers/specs/2026-04-19-game-scoring-design.md)
- [SP3 BO7 Playoff Design](../HoopTrack/docs/superpowers/specs/2026-04-19-game-playoff-design.md)
- [SP4 Live Commentary Design](../HoopTrack/docs/superpowers/specs/2026-04-19-game-commentary-design.md)

Recommended sequence: **SP1 → (SP2 ∥ SP4) → SP3**. SP4 has no hard dep on SP1 and can ship "lite" mode for solo training sessions.

### Game — SP1 Foundation ✅
Data-model layer + registration flow + manual-scoring live game. Landed 2026-04-19.

**New models (SwiftData, all local-only, no Supabase sync):**
- `GamePlayer` — session-scoped; carries a JSON-encoded `AppearanceDescriptor`; cascade-deleted with parent
- `GameSession` — sibling to `TrainingSession`; stores team scores, player roster, shot list, optional video
- `GameShotRecord` — sibling to `ShotRecord`; carries `shooter: GamePlayer?` + `attributionConfidence`

**New services / VMs:**
- `AppearanceExtraction` — pure helpers (chi-squared histogram, upper-body box, height ratio). TDD'd.
- `AppearanceCaptureService` — ingests camera frames via Vision `VNDetectHumanBodyPoseRequest`, emits `AppearanceDescriptor` after 3s high-confidence body lock
- `GameRegistrationViewModel` — `nonisolated` state machine tracking registration progress (avoids a Swift `__deallocating_deinit` back-deploy crash that hits `@MainActor` VMs under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`)
- `GameSessionViewModel` — SP1 shell; exposes `logShot()` + `endSession()`. SP2 replaces manual path with CV attribution.

**New views (`HoopTrack/Views/Game/`):**
- `GameConsentView` — plain-language consent before camera activates (biometric-adjacent data notice)
- `GameRegistrationView` — landscape camera + lock-progress ring + name-entry sheet
- `TeamAssignmentView` — tap-toggle chips, auto-alternates on entry
- `LiveGameView` — SP1 shell with scoreboard + player picker + manual Miss/2PT/3PT buttons
- `GameSummaryView` — SP1 stub: final scores, player list, duration (full box score in SP2)
- `GameFlowContainer` — orchestrates consent → registration → team → live → summary steps
- `GameEntryCard` — top-of-Train-tab entry point with 2v2/3v3 picker

**Modified:**
- `Models/Enums.swift` — added `GameType`, `GameState`, `TeamAssignment`, `GameShotType`, `GameFormat`
- `HoopTrackApp.swift` — 3 new `@Model` types registered with the `ModelContainer`
- `Services/DataService.swift` — `addGameShot()` with team-score credit; `purgeOldVideos` extended to `GameSession`; `modelContext` exposed internally
- `Views/Train/TrainTabView.swift` — new `GameEntryCard` above drill grid + `fullScreenCover` for the game flow
- `Views/Progress/ProgressTabView.swift` — new `RecentGamesSection` at the bottom showing last 5 games
- `Utilities/Constants.swift` — added `HoopTrack.Game` block (lock duration, body-confidence threshold, histogram bins, etc.)
- `PrivacyInfo.xcprivacy` — declared appearance-descriptor capture as `OtherDiagnosticData` (session-scoped, on-device only, never transmitted)

**Tests added:** `AppearanceDescriptorTests` (4), `AppearanceExtractionTests` (4), `GameRegistrationViewModelTests` (5), `GameModelTests` (3 — SwiftData insert / cascade / descriptor round-trip). Full suite: 209 tests, 0 failures.

**Notable deviations from original spec:**
- No `AppRoute` enum added — codebase routes via local `fullScreenCover` + state, not a centralised enum
- `ProgressTabView` got a dedicated `RecentGamesSection` at the bottom instead of inline merging with training history (the file is an analytics dashboard, not a history list)
- Renamed `ShotType` → `GameShotType` to avoid colliding with the existing `ShotType` enum (catch-and-shoot / pull-up / etc)

### Game — SP2 Scoring & Box Score 🔜 Planned
See [SP2 design spec](../HoopTrack/docs/superpowers/specs/2026-04-19-game-scoring-design.md). Builds `PlayerTracker` (appearance-matching re-ID), `GameScoringCoordinator`, full `LiveGameView` with killfeed + player overlays, post-game box score + unresolved-shots flow.

### Game — SP3 BO7 Playoff 🔜 Planned (after SP2)
See [SP3 design spec](../HoopTrack/docs/superpowers/specs/2026-04-19-game-playoff-design.md). `PlayoffSeries` state machine, round thresholds (40/50/60/70%), `WeakZoneAnalyser`, prescribed-drill generation, mid-series resume.

### Game — SP4 Live Commentary 🔜 Planned (can run parallel to SP2)
See [SP4 design spec](../HoopTrack/docs/superpowers/specs/2026-04-19-game-commentary-design.md). `CommentaryEventBus`, clip-selection engine (intensity + anti-rep + pacing), 2 personalities at launch. Works with solo training in "lite" mode.

---

## Future Extension Phases

---

### Phase 13 — Multiplayer Sessions (deprecated — see Game Mode track above)
**Prerequisite:** Phase 9 (Supabase Realtime).  
**Reference:** `docs/extension-multiplayer-sessions.md`

Two modes: **coach-hosted drill session** and **peer-to-peer free session**.

| Component | Detail |
|---|---|
| DB schema | `multiplayer_sessions` (host, state, session_code), `multiplayer_participants`, `multiplayer_shot_events` staging table |
| Real-time | Supabase Realtime Broadcast for shot hot path (sub-200ms); Postgres Changes for session state transitions |
| `MultiplayerSessionService` | `@MainActor final class`; `@Published var participants`, `liveFeed`, `leaderboard`; `publishShot(_:)` hook |
| CV pipeline integration | One two-line addition to `LiveSessionViewModel` — each device runs its own pipeline independently |
| Lobby UI | `MultiplayerLobbyView`: QR code/share sheet; real-time join list; host-only Start button |
| Live leaderboard | `MultiplayerLeaderboardView`; ranked by shots made/FG%/drill score; up to 8 players |
| Finalization | Host triggers `finalising`; all devices run `SessionFinalizationCoordinator` locally; Edge Function aggregates leaderboard |
| Safety | pg_cron auto-finalizes orphaned sessions after 5 minutes with no host Presence |

---

### Phase 14 — Web Dashboard (Extended)
**Prerequisite:** Phase 12B (base dashboard live).  
**Reference:** `docs/extension-web-dashboard.md`

Extends the Phase 12B dashboard with deeper analytics and coach access preview.

| Component | Detail |
|---|---|
| Session detail | Full shot chart + zone heat map + Shot Science panel; click-to-seek video timeline |
| `skill_rating_snapshots` | New table tracking rating history over time; `supabase gen types` for TypeScript |
| Virtual scrolling | `@tanstack/react-virtual` for shot timelines with thousands of records |
| Coach access preview | Route group restructuring for `/athletes/[id]`; `coach_athlete_links` RLS policies |

---

### Phase 15 — Coach Review Mode
**Prerequisite:** Phase 10 (video URLs), Phase 12B (web dashboard for coach interface).  
**Reference:** `docs/extension-coach-review-mode.md`

Async model: coach reviews session recording and leaves timestamped annotations; athlete sees feedback on session timeline.

| Component | Detail |
|---|---|
| DB schema | `session_shares` (per-share revocation, expiry, token); `session_annotations` (timestamp_seconds, JSONB content, optional shot_record_id) |
| Share flow | `SessionSharingService`; `create-session-share` Edge Function signs JWT; system share sheet delivers `hooptrack://` deep link |
| Coach web interface | `/dashboard/review/[session_id]`; video player synced with shot chart; click-to-seek; annotation sidebar |
| Annotation types | `text` (with emphasis), `draw` (SVG paths in normalised coords), `zone_highlight` |
| iOS feedback | `SessionAnnotationsView`; `AnnotationTimelineScrubber`; unread badge count |
| Push | DB Webhook → `notify-athlete-annotation` Edge Function → OneSignal → device |
| Privacy | Athlete can revoke coach access; 30-day default expiry; coaches cannot see raw health data |

---

### Phase 16 — Teams & Organisations
**Prerequisite:** Phase 15 (coach-athlete relationship model).  
**Reference:** `docs/extension-teams-organisations.md`

Three-tier hierarchy: Organisation → Team → Member. Four roles: `org_admin`, `head_coach`, `assistant_coach`, `player`.

| Component | Detail |
|---|---|
| DB schema | `organisations`, `teams`, `team_members`, `team_invites`, `team_training_goals`, `org_members`; RLS via `is_team_coach()` helper functions |
| Invite flow | 64-char hex token; Supabase Edge Function validates atomically; audit trail preserved |
| iOS | `TeamContext` drives tab bar injection; `TeamViewModel` fans out 4 parallel queries on load |
| Team leaderboard | Materialized view refreshed hourly via pg_cron; players see ranks only (not teammates' raw session data) |
| Team goals | Coach sets aggregate goal (e.g. team FG% > 45%); individual contributions tracked |
| Web org portal | `/dashboard/team/[id]`; roster table; org admin portal (web-only initially) |
| Subscription | Free: solo + 1 team (≤5 members); Pro Team: unlimited; Org: multiple teams + admin portal; RevenueCat |
| Migration | Existing coach-athlete pairs opt-in to Teams; `coach_athletes` table retained and RLS remains live |

---

## Technical Debt (from Refactor Report)

Issues identified at end of Phase 6B. Address during relevant upcoming phases.

| # | Severity | Finding | Phase to fix |
|---|---|---|---|
| 1 | Critical | `ProfileTabView` constructs a second `ModelContainer` in `@StateObject` initialiser | Phase 9 (Backend) |
| 2 | Critical | `DispatchQueue.main.async` in `@MainActor` `CameraService` (Swift 6 data race) | ✅ Fixed Phase 7 |
| 3 | Important | Long-press end-session button duplicated across 3 views (~40 lines each) | Phase 11 (Accessibility) |
| 4 | Important | Views construct `DataService` directly from `modelContext` in `.task` | Phase 9 (Backend) |
| 5 | Important | `ProgressViewModel.load()` is synchronous; blocks main thread on large datasets | Phase 9 (Backend) |
| 6 | Important | `LiveSessionViewModel` uses implicitly-unwrapped optionals for injected deps | Phase 8 (Auth refactor) |
| 7 | Minor | `DispatchQueue.main.async` in `DribblePipeline` and `NotificationService` | ✅ Fixed Phase 7 |
| 8 | Minor | `NotificationSettingsView` toggles are hardcoded `.constant(true)` | Phase 8 (Auth/profile) |
| 9 | Minor | Redundant `calibrationIsActive` published property in `LiveSessionViewModel` | Phase 8 (Auth refactor) |
| 10 | Minor | Commented-out code in `CameraService` | Phase 8 (cleanup) |

---

## Reference Documents

| Document | Contents |
|---|---|
| `docs/upgrade-authentication-identity.md` | Auth integration plan (Phase 8) |
| `docs/upgrade-backend-api.md` | Hasura + GraphQL backend plan (Phase 9) |
| `docs/upgrade-postgresql-supabase.md` | Postgres schema, RLS, sync (Phase 9) |
| `docs/upgrade-file-media-storage.md` | VideoUploadService, Supabase Storage (Phase 10) |
| `docs/upgrade-accessibility.md` | VoiceOver audit, Dynamic Type, WCAG (Phase 11) |
| `docs/upgrade-web-presence.md` | Next.js marketing + dashboard (Phase 12) |
| `docs/upgrade-cv-detection.md` | CV detection + make/miss roadmap (telemetry foundation, detector v2, tracking, make/miss v2, audio, re-ranker) |
| `docs/extension-multiplayer-sessions.md` | Multiplayer architecture (Phase 13) |
| `docs/extension-web-dashboard.md` | Extended dashboard + coach access (Phase 14) |
| `docs/extension-coach-review-mode.md` | Async coach review system (Phase 15) |
| `docs/extension-teams-organisations.md` | Teams + org hierarchy (Phase 16) |
| `docs/refactor-report.md` | Phase 6B technical debt findings (8 items still open) |
| `docs/backlog/upgrade-security.md` | ✅ Implemented — full security plan (Phase 7) |
| `docs/backlog/performance-report.md` | ✅ Implemented — Phase 6A performance audit findings |

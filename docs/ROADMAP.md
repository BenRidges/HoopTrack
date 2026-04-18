# HoopTrack — Implementation Roadmap

**Last updated:** 2026-04-12  
**Status:** End of Phase 7 (security & privacy hardened; ready for authentication work)

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
| 8 | Authentication & Identity | 🔜 Next |
| 9 | Backend & Database | 🔜 Planned |
| 10 | File & Media Storage | 🔜 Planned |
| 11 | Accessibility | 🔜 Planned |
| 12 | Web Presence | 🔜 Planned |
| 13 | Multiplayer Sessions | 🔮 Future |
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

---

## Deferred Items (Not Yet Scheduled)

| Feature | Effort | Notes |
|---|---|---|
| **Haptics** | Small (1–2 days) | Shot make/miss, badge earn, agility trigger, dribble rhythm cues |
| **Watch Companion** | Medium (1–2 weeks) | Glanceable today stats, session start/stop from wrist, `CLKComplication` |
| **YOLOv8 Core ML** | Medium | Replace `BallDetectorStub`; train on Roboflow basketball dataset |
| **OpenAI Vision post-session** | Small–Medium | Send key frames for shot form feedback |

---

## Upcoming Phases

---

### Phase 8 — Authentication & Identity ⭐ NEXT
**Prerequisite:** Phase 7 ✅ (`KeychainService`, `PinningURLSessionDelegate`, `PrivacyInfo.xcprivacy` all in place).  
**Note:** Replace `PinningURLSessionDelegate.pinnedHashes` placeholder with real Supabase SPKI SHA-256 before Phase 9 ships.  
**Reference:** `docs/upgrade-authentication-identity.md`

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

### Phase 10 — File & Media Storage
**Prerequisite:** Phase 9 complete (Supabase Auth + Storage in same project).  
**Reference:** `docs/upgrade-file-media-storage.md`

| Task | Detail |
|---|---|
| Supabase Storage bucket | `session-videos` private bucket; RLS policy keyed on `auth.uid()`; path: `{user_id}/{session_id}.mov` |
| `VideoUploadService` | `@MainActor final class`; background `URLSession` (survives app suspension); `@Published var uploadProgress: [UUID: Double]` |
| Session finalization hook | Step 9 in `SessionFinalizationCoordinator` — non-fatal; failure does not roll back session |
| SwiftData migration | `SchemaV3` adds `cloudUploaded: Bool` + `cloudUploadedAt: Date?` to `TrainingSession` |
| Local file cleanup | Delete local `.mov` only after `cloudUploaded == true` confirmed |
| Signed URL playback | 1-hour expiry for `AVPlayer`; 7-day for coach share links; generated on-demand, not cached |
| Highlight export | `AVMutableComposition` trim + `AVVideoCompositionCoreAnimationTool` stats overlay; output MP4 to `temporaryDirectory` |
| **Migration path (future)** | Cloudflare R2 (zero egress) when Supabase Storage egress exceeds ~$20/month (~2,000 MAU) |

**Key files to create:**
- `HoopTrack/HoopTrack/Services/VideoUploadService.swift`

---

### Phase 11 — Accessibility
**Can be worked in parallel with Phases 8–10 (no infrastructure dependency).**  
**Reference:** `docs/upgrade-accessibility.md`

| Task | Detail |
|---|---|
| VoiceOver audit | Add `accessibilityLabel` / `accessibilityValue` / `accessibilityHint` to all custom views (currently zero labels exist) |
| End-session button | Highest-priority: replace inaccessible `DragGesture` long-press with `HoldToEndButton` that has an accessible alternative activation |
| Dynamic Type | Replace 27 hard-coded `font(.system(size: N))` calls with semantic styles; `scaledMetric` for spacing/icons |
| WCAG contrast | `#FF6B35` on `ultraThinMaterial` dark fails 4.5:1 — adjust opacity or provide `accessibilityContrast` variant |
| Reduced motion | Guard `ShimmerModifier`, badge animations, animated counters with `@Environment(\.accessibilityReduceMotion)` |
| Canvas views | `CourtMapView` + `SkillRadarView` need single-element accessibility summary labels |
| Switch Control | `accessibilityInputLabels` for voice control; logical focus order audit per tab |
| Live announcements | `UIAccessibility.post(notification: .announcement, ...)` for shot detection; throttle to avoid spam |

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

## Future Extension Phases

---

### Phase 13 — Multiplayer Sessions
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
| `docs/upgrade-security.md` | Full security implementation plan (Phase 7) |
| `docs/upgrade-authentication-identity.md` | Auth integration plan (Phase 8) |
| `docs/upgrade-backend-api.md` | Hasura + GraphQL backend plan (Phase 9) |
| `docs/upgrade-postgresql-supabase.md` | Postgres schema, RLS, sync (Phase 9) |
| `docs/upgrade-file-media-storage.md` | VideoUploadService, Supabase Storage (Phase 10) |
| `docs/upgrade-accessibility.md` | VoiceOver audit, Dynamic Type, WCAG (Phase 11) |
| `docs/upgrade-web-presence.md` | Next.js marketing + dashboard (Phase 12) |
| `docs/extension-multiplayer-sessions.md` | Multiplayer architecture (Phase 13) |
| `docs/extension-web-dashboard.md` | Extended dashboard + coach access (Phase 14) |
| `docs/extension-coach-review-mode.md` | Async coach review system (Phase 15) |
| `docs/extension-teams-organisations.md` | Teams + org hierarchy (Phase 16) |
| `docs/refactor-report.md` | Phase 6B technical debt findings |
| `docs/performance-report.md` | Phase 6A performance audit findings |
| `docs/extension-report.md` | Original strategic vision + technical options brief |

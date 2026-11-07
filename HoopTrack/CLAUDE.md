# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

Build and run tests via Xcode (⌘B / ⌘U) or `xcodebuild`. The CLI tool requires full Xcode selected as the developer directory — not just Command Line Tools.

```bash
# Run all tests (iPhone 14 is known-present on this Mac; verify with `xcrun simctl list devices available | grep iPhone` if it fails)
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14'

# Run a single test class
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  -only-testing:HoopTrackTests/ShotScienceCalculatorTests
```

Minimum deployment target: **iOS 17.0** (SwiftData, `onChange(of:_:)` two-parameter form, `ContentUnavailableView`).

### Pure logic without a simulator

`Tools/HoopTrackCore` (repo root) is a Swift package built from symlinks to the app's Foundation-only sources (`ShotTracker`, `BallFilter`, `DetectionRegion`, `ShotGeometry`, `CourtZoneClassifier`, `StreakCalculator`, `BoxScore`, `DribbleCalculator`, `HoopRectSmoother`, `InputValidator`, `SkillRatingCalculator`, `Constants`, `Models/Enums`, …) and their tests. It works on macOS or Linux:

```bash
cd ../Tools/HoopTrackCore
swift test                                        # pure-logic tests, seconds
swift run shot-eval detections.jsonl labels.csv   # replay a session log through ShotTracker and score it
swift run shot-sim --scenario 'mixed-*' --trace  # benchmark make/miss on simulated footage (Sources/ShotSimulation)
```

When adding pure logic, keep the file free of SwiftUI/UIKit/CoreGraphics imports, mark its types `nonisolated`, and add a symlink for it (and its test) in the package so it's covered there too.

## Architecture

**MVVM + SwiftData + Combine.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide, so view models and services are main-actor by default. Pure value types and anything that runs on the camera queue must be marked `nonisolated` (all enums in `Models/Enums.swift` are).

### App shell

- **`HoopTrackApp`** builds one **`AppServices`** (every long-lived service, created from `HoopTrackStore.shared`) and injects it with `.appEnvironment(services, auth:)`. UIKit-hosted content (the landscape session) needs `.appEnvironment` applied again.
- **`RootView`** — onboarding, then three tabs: **Train**, **Progress**, **Profile**. Every training session is presented full screen from here by setting `AppState.activeLaunch`; the summary sheet appears after the cover has dismissed (`AppState.finishSession` → `sessionCoverDismissed`).
- **`HoopTrackStore`** is the only place a `ModelContainer` is built (app, intents, tests via `makeInMemoryContainer()`). Never open a container with a partial schema.
- **`AppPreferences`** holds the `@AppStorage` keys and static readers for services. All opt-ins (app lock, Apple Health, telemetry sharing, reminder) default to off.

### Data layer

- **`Models/`** — SwiftData `@Model` classes: `PlayerProfile`, `TrainingSession`, `ShotRecord`, `GoalRecord`, `EarnedBadge`, `GameSession`, `GamePlayer`, `GameShotRecord`, `TelemetryUpload`, `PlayoffSeries`. All enums live in `Models/Enums.swift`.
- **`Services/DataService.swift`** — all persistence goes through here. It bumps a published `revision` on every save; tabs reload on `onChange(of: dataService.revision)`.
- **`SessionFinalizationCoordinator`** — every session type ends through one pipeline: goals → Health (if enabled) → skill ratings → badges → reminders → sync → telemetry (if enabled).
- **`TrainingSession.recalculateStats()`** — call after modifying `shots`.

### Shot tracking

All per-frame work runs on the camera's session queue; results reach the main actor through `@MainActor` delegate protocols. See `docs/cv-review-2026-11.md` at the repo root for the design and the improvement plan.

- **`CameraService`** — `AVCaptureSession`, 720p at 60 fps where available, `framePublisher`. Live shooting is landscape-right only (capture is fixed at 0°).
- **`CVPipeline`** — frame → `SessionRecorder` (HEVC video) → detector → `CourtCalibrationService` (smoothed hoop) → `ShotTracker` → `NetCheck` → `CourtPositionEstimator` + `ShotPhysics` → `ShotPipelineDelegate`.
- **`ShotTracker`** (`Utilities/`) — pure make/miss state machine, unit tested. Tracks every ball between shots; from release a `BallFilter` (Kalman) picks the shot ball each frame. Tune via `ShotTracker.Tuning`, measured with `shot-eval`.
- **`NetMotion`** (`NetWatch`, `NetCheck`, `ShotEvidence`) — samples the net's brightness every frame; calls the tracker wasn't sure of (confidence < 0.9) wait ≤ 0.7 s and are confirmed, flagged or rescued by whether the net swung. `ShotReplay` runs the same `NetCheck`, so `shot-eval` scores what the app publishes.
- **`DetectionRegion`** — while a shot is in flight the detector runs on a crop around hoop + ball (`HoopTrack.CV.focusDuringShots`).
- **Telemetry** (opt-in) — `detections.jsonl` per frame, then `TelemetryManifest` (sampled frames with their boxes + every shot's outcome). `Tools/dataset/build_dataset.py` turns those into a YOLO dataset; `Tools/training/train_detector.py` trains, gates against the shipped model and exports. See `docs/training-review-2026-11.md`.
- **`ShotGeometry`** — distance from apparent ball/rim size and the camera FOV; launch angle from flight time.
- **`DribblePipeline`** — body-pose wrists + `WristBounceDetector` (front camera, portrait).
- Manual Make / Miss / Undo are always available; low-confidence calls are stored with `needsReview` and flagged in the summary. `ShotRecord.detectionConfidence` is nil for hand-logged shots.
- `BallDetectorStub` exists in DEBUG builds only.

### Constants

All magic numbers live in `HoopTrack/Utilities/Constants.swift` as nested enums: `HoopTrack.Camera`, `HoopTrack.CV`, `HoopTrack.ShotScience`, `HoopTrack.Dribble`, `HoopTrack.SkillRating`, etc. Court dimensions (feet) are in `CourtGeometry` (`Utilities/CourtZoneClassifier.swift`).

### Design system

`Design/Theme.swift` — dark "gym at night" palette (`Color.court`, `.panel`, `.leather`, `.make`, `.miss`), `Font.score(_:)` for numbers, `Panel`, `SectionLabel`, `StatValue`, button styles `.primary` / `.secondary` / `.pressable`, and `courtBackground()` / `courtList()`. Use these instead of ad-hoc colours and cards; keep screens to one clear primary action.

### Navigation

- **Train** — start shooting (hero), playoff run in progress, this week, drill library (`NamedDrill.library`), playoffs, pickup game, last session.
- **Playoffs** — best of seven, four rounds, solo. `PlayoffRun` (`Utilities/PlayoffEngine.swift`, pure) is replayed from the shots of every `TrainingSession` tagged with the run's `playoffSeriesID`, so undo and corrections just work; `PlayoffSeries` only caches the result (`DataService.refreshPlayoff`). Sittings are ordinary shooting sessions (`TrainingLaunch.playoff(id)`) with a playoff HUD, so they count toward every stat.
- **Progress** — FG% for a range with trend, shot chart, zones, skills, goals, badges, history, games.
- **Profile** — career numbers and every setting (training, cloud backup, privacy, developer).
- Sessions: `LiveSessionView` (landscape, via `LandscapeContainer`), `DribbleDrillView`, `AgilitySessionView`, `GameFlowView`. Each ends with `onFinish(SessionResult?)`; nil means nothing worth keeping (empty sessions are discarded).

### App Intents & Deep Links

- **`AppIntents/`** — Siri Shortcuts: `StartFreeShootSessionIntent`, `ShowMyStatsIntent`, `ShotsTodayIntent`. `HoopTrackShortcuts` is the single registration point — adding a new shortcut requires only a new file + one line there.
- **`AppState.handleDeepLink`** — `hooptrack://shoot` starts a session; `train` / `progress` / `profile` select a tab. `hooptrack://auth/...` goes to `AuthViewModel` instead.

### Services (added Phase 6A)

- **`ExportService`** — JSON export of full session history via system share sheet. Entry point: `exportJSON(for:)`. Exported files get `FileProtectionType.complete`.
- **`MetricsService`** — MetricKit subscriber wired at launch. Collects on-device performance diagnostics; do not duplicate with manual logging.

### Security layer (added Phase 7)

- **`Utilities/KeychainService.swift`** — `@MainActor final class`. All auth tokens and sensitive values go here — never `UserDefaults`. Key constants in `HoopTrack.KeychainKey`. Call `deleteAll()` during account deletion.
- **`Utilities/InputValidator.swift`** — Pure `enum` with static validators. Call before persisting any sensor value or user string: `isValidReleaseAngle`, `isValidJumpHeight`, `isValidCourtCoordinate`, `sanitisedProfileName`.
- **`Utilities/PinningURLSessionDelegate.swift`** — SPKI SHA-256 pinning, checked against every certificate in the chain. **Deliberately not wired in**: Supabase is served through Cloudflare, which rotates certificates and CAs without notice, so pins would eventually lock users out. Reasoning in the class doc and `docs/production-readiness.md`.
- **`PrivacyInfo.xcprivacy`** — App Store privacy manifest. Auto-discovered by Xcode 26. No pbxproj edits needed.
- **`DataService.deleteAllUserData()`** — GDPR right-to-delete. Deletes every SwiftData record (all ten models), session videos, telemetry files, exports, the Keychain, and every key in `AppPreferences.allKeys`.

### Auth layer (added Phase 8)

- **Accounts are optional.** The app works fully offline; signing in (Profile → Cloud backup → `AccountSheet`) only adds Supabase sync.
- **`Auth/`** — Supabase email+password. `AuthViewModel` (state: `unauthenticated / authenticating / authenticated / error`), `AuthProviding` protocol (`SupabaseAuthProvider`, `MockAuthProvider` in tests), `SupabaseContainer`, `BackendSecrets.swift` (gitignored; copy from `BackendSecrets.swift.example` and fill in Supabase URL + anon key).
- **`AppLock`** — optional Face ID / passcode lock, independent of signing in. Re-locks after `HoopTrack.Auth.backgroundLockTimeoutSec` in the background; `LockedView` overlays `RootView`.
- **`PlayerProfile.supabaseUserID`** — linked in `HoopTrackApp` when a verified user is restored, unlinked only on explicit sign-out; canonical key for RLS `auth.uid()` matching.
- **Sign in with Apple is intentionally skipped.** Email-only is App Store compliant when no other social provider is offered.
- **Password reset** — `hooptrack://auth/reset` (`HoopTrack.Auth.passwordResetURL`); the link signs the user in and `AuthViewModel.isSettingNewPassword` shows `SetNewPasswordView` as a layer over `RootView`.
- **Account deletion** — `AuthViewModel.deleteAccount()` → `delete-account` Edge Function (`supabase/functions/`, deployed by hand). "Delete all my data" deletes the account first and aborts if that fails.
- **`BackendSecrets.swift`** — Debug builds use the development project, Release the production one (`#if DEBUG` in the file).

### Sync layer (added Phase 9)

- **`Sync/`** — `SupabaseDataService` (PostgREST wrapper, `nonisolated init`), `SupabaseDataServiceProtocol`, `SyncCoordinator` (orchestrates uploads, stamps `cloudSyncedAt`), 5 Codable DTOs (`PlayerProfileDTO`, `TrainingSessionDTO`, `ShotRecordDTO`, `GoalRecordDTO`, `EarnedBadgeDTO`) with snake_case CodingKeys.
- **`SessionFinalizationCoordinator` step 8** — `kickOffSync(session:profile:)` fires a fire-and-forget Supabase upload after every shooting / dribble / agility session. Skips if no coordinator injected, no signed-in user, `endedAt == nil`, or `durationSeconds < 30`.
- **`cloudSyncedAt: Date?`** on the 5 syncable models — nil means never-synced or dirty. Stamped by `SyncCoordinator` after a successful upsert; corrections and deletions clear the session's stamp.
- **Whole-store passes** — `AppServices.syncCloudBackup` (after every sign-in and launch while signed in) restores onto a phone with no history (`SyncCoordinator.restore`, by id, local always wins), then `backUpEverything` uploads what isn't up. Profile → Restore from backup merges on demand. No delete sync yet.
- **`shot_records` is insert-only** on the server; uploads use ignore-duplicates. `HoopTrack.Backend.shotRowsUpdatable` turns on updates once `supabase/migrations/20261107000000_shot_record_updates.sql` is applied.
- **Postgres schema + RLS** live on Supabase project `nfzhqcgofuohsjhtxvqa`. 5 tables, 16 RLS policies keyed on `auth.uid()`. `shot_records` is append-only by policy (select + insert only).
- **Enum raw values are storage keys** — SwiftData and the Postgres rows both hold them ("Free Shoot", "Mid-Range", "Make"). Never change one; UI text comes from `displayName`. `PersistedKeysTests` fails on any change.

## Testing conventions

Tests live in `HoopTrackTests/`. Most cover **pure functions** — calculators, classifiers, the `ShotTracker` state machine (synthetic trajectories). `DataService` tests use `HoopTrackStore.makeInMemoryContainer()`; don't build containers with a partial schema. Tests are `XCTestCase` subclasses using `@testable import HoopTrack`.

When adding new pure logic (calculators, services that take value-type inputs), write a corresponding test file following the same pattern as `ShotScienceCalculatorTests.swift`.

## Repository layout

- **Git root:** `/Users/benridges/Documents/projects/` — contains `HoopTrack/`, `docs/`, sibling experiments (`dog-cam/`, `hooptrack-ball-detection/`), and a top-level `.gitignore`.
- **Xcode project root:** `/Users/benridges/Documents/projects/HoopTrack/` — `.xcodeproj`, `Info.plist`, sources, tests, plus an **additional** `docs/` folder.
- **Two `docs/` folders exist.** `docs/ROADMAP.md`, `docs/production-readiness.md`, and `docs/upgrade-*.md` live at the **repo root**. `HoopTrack/docs/` holds `backlog.md`, `config/`, and `superpowers/` (plans and specs).
- **Filesystem-synchronized Xcode groups** — `.swift` files under `HoopTrack/` auto-compile on drop-in. Non-Swift resources (`.mlpackage`, `.mlmodel`, assets, `.xcconfig`) still need explicit Target Membership set via Xcode → File Inspector → Targets. Adding CoreML models via CLI is fragile; drag-and-drop in Xcode is reliable.

## Key conventions

- **Apple-native for UI/CV/AR/data.** One SPM dependency: `supabase-swift` (added Phase 8; products `Auth`, `PostgREST`, `Storage`, `Realtime`, `Functions`). No other third-party packages.
- **Normalised court coordinates.** Shot positions are stored as 0–1 fractions of half-court space, not screen pixels.
- **`AgilityAttempt` is in-session only** — not persisted. Aggregates (`bestShuttleRunSeconds`, `bestLaneAgilitySeconds`, `avgVerticalJumpCm`) go on `TrainingSession`.
- **Phase gating in comments.** Code sections are annotated `// Phase N —` to indicate when they were introduced. Don't remove these.
- **Portrait by default.** The app is portrait-locked except for `LiveSessionView`, which forces landscape-right via `LandscapeHostingController`. The `OrientationLock.mode` flag in `HoopTrackApp.swift` gates which orientations the AppDelegate allows. Capture uses `CameraOrientation.landscape` (videoRotationAngle = 0°), so the other landscape would turn the picture — and the tracker's "up" — upside down.
- **Video storage.** `SessionRecorder` writes session videos to `Documents/Sessions/<uuid>.mov`. Auto-deleted after the profile's retention setting (default `HoopTrack.Storage.defaultVideoRetainDays`) unless `videoPinnedByUser = true`.
- **Explicit deinit.** Every class that isn't `nonisolated` needs a `deinit` of its own, even an empty `deinit {}`. Without one, the compiler routes its release through Swift's back-deployed "deinit on the main actor" shim (we target iOS 17), and on iOS 26 that shim aborts with "pointer being freed was not allocated". CI runs `Tools/ci/check-isolated-deinit.sh` on the built app and names any class that's missing one. For the same reason Core ML class generation is off (`COREML_CODEGEN_LANGUAGE = None`); models are loaded by URL.
- **Swift 6 async pattern.** Never use `DispatchQueue.main.async` inside `@MainActor` classes — use `Task { @MainActor in }` instead. The project targets strict concurrency compliance.
- **Sensitive data in Keychain only.** Auth tokens, user IDs, and API keys go in `KeychainService`. `UserDefaults` and `@AppStorage` are for non-sensitive UI preferences only.
- **Validate before persisting.** All sensor values (release angle, jump height, court coordinates) and user-provided strings must pass `InputValidator` checks before writing to SwiftData or sending to any API.
- **File protection on sensitive files.** Session videos (`Documents/Sessions/`) and exported JSON must have `FileProtectionType.complete`. `HoopTrackApp` re-applies this at launch.
- **Detection boxes are a developer toggle** (Profile → Developer → Show detection boxes); the hoop bracket is always shown.
- **Phase plan.** See `docs/ROADMAP.md` (at the **repo root**, not `HoopTrack/docs/`) for the full implementation roadmap. `docs/production-readiness.md` tracks what must land before App Store submission.

## Parallel Agent Dispatch

Use parallel agents when tasks are **independent** — no shared state, no sequential dependencies. Dispatch all agents in a single message to run them concurrently.

### When to dispatch parallel agents

| Scenario | Example |
|---|---|
| Multiple independent plan docs to write | Writing upgrade plans for Auth, Backend, Security simultaneously |
| Investigating unrelated bugs | 3 failing test files with different root causes |
| Cross-cutting research across subsystems | Auditing services, models, and views independently |
| Implementation plan has parallel tracks | Two features that don't touch shared files |

### When NOT to dispatch parallel agents

- Tasks share state or write to the same files
- Task B depends on the output of Task A
- Exploratory work where you don't know the shape yet (investigate first, then dispatch)

### Agent prompt checklist

Each agent prompt must be **self-contained** — agents have no memory of the current session. Include:

1. **App context** — architecture summary, relevant file paths, key types
2. **Specific scope** — exactly what this agent should do (one domain only)
3. **Constraints** — what files/areas to avoid, what conventions to follow
4. **Output format** — what to produce and where to write it

### HoopTrack-specific agent contexts to include

Copy the relevant block into agent prompts:

```
# iOS app context
SwiftUI + SwiftData + Combine, iOS 17+, MVVM, @MainActor final class ViewModels,
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor.
Key services: DataService, SessionFinalizationCoordinator, CameraService, CVPipeline,
SyncCoordinator, AuthViewModel.
Models: PlayerProfile, TrainingSession, ShotRecord, GoalRecord, EarnedBadge.
Auth: Supabase email+password (Phase 8, complete). Backend: Supabase Postgres + RLS
(Phase 9, complete). SIWA and Hasura intentionally deferred.
One SPM dep: supabase-swift. Repo root is one level above HoopTrack/ and hosts a
second docs/ folder with ROADMAP.md + production-readiness.md.
See docs/ROADMAP.md (repo root) for full phase plan.
```

### Collecting results

After all agents complete, review each output before committing. Check for:
- Conflicting decisions across agents (e.g. two agents chose different table names)
- Files that need cross-referencing (e.g. a schema change that affects an iOS model)
- Merge conflicts if agents wrote to overlapping paths

---

## Available Skills Reference

Skills are invoked via the `Skill` tool (or `/skill-name` shorthand). Use the right skill at the right moment — they enforce discipline that prevents common mistakes.

### Development workflow

| Skill | When to use |
|---|---|
| `superpowers:brainstorming` | **Before** starting any new feature or phase — clarifies intent before touching code |
| `superpowers:writing-plans` | After brainstorming; produces a structured plan doc before implementation begins |
| `superpowers:executing-plans` | When resuming an existing written plan in a fresh session |
| `superpowers:subagent-driven-development` | When a plan has parallel independent tasks — coordinates agents against a spec |
| `superpowers:dispatching-parallel-agents` | When dispatching 2+ independent agents concurrently |
| `superpowers:using-git-worktrees` | Before feature work — creates isolated worktrees; use via `/phase-start` for HoopTrack phases |

### Implementation quality

| Skill | When to use |
|---|---|
| `superpowers:test-driven-development` | **Before writing any implementation code** — write failing tests first |
| `superpowers:systematic-debugging` | When hitting a bug or test failure — prevents premature fixes without root cause |
| `superpowers:verification-before-completion` | **Before claiming anything is done** — run commands and confirm output before asserting success |

### Code review

| Skill | When to use |
|---|---|
| `superpowers:requesting-code-review` | After completing a feature or phase — validates work before merging |
| `superpowers:receiving-code-review` | When review feedback arrives — prevents blind implementation of unclear suggestions |
| `superpowers:finishing-a-development-branch` | When implementation is complete and tests pass — guides merge/PR/cleanup |

### Phase completion checklist

Before merging any phase branch, run a security review using the `.claude/agents/swift-security-reviewer.md` agent:

```
# Lightweight end-of-phase security scan
# Dispatch a single swift-security-reviewer subagent covering all files changed in the phase.
# Fix all CRITICAL and HIGH issues before merging.
# Full 4-domain parallel sweep (like Phase 7) is reserved for security-focused phases.
```

Steps:
1. `git diff origin/main..HEAD --name-only` — get the list of changed files
2. Dispatch one `swift-security-reviewer` subagent with all changed files in scope
3. Fix any CRITICAL/HIGH findings; note MEDIUM/LOW for future phases
4. Then use `superpowers:finishing-a-development-branch` to merge

### Project maintenance

| Skill | When to use |
|---|---|
| `claude-md-management:claude-md-improver` | Periodically audit and improve this file |
| `claude-code-setup:claude-automation-recommender` | When adding new tools or frameworks — surfaces new automation opportunities |
| `remember:remember` | At end of session — saves state for clean continuation next session |

### HoopTrack-local skills

| Skill | When to use |
|---|---|
| `xcode-test` | Run tests: `/xcode-test` (all) or `/xcode-test ClassName` (single class) |
| `phase-start` | Begin any new implementation phase — worktree, plan doc, ROADMAP check |

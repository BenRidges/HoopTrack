# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test

Build and run tests via Xcode (⌘B / ⌘U) or `xcodebuild`. The CLI tool requires full Xcode selected as the developer directory — not just Command Line Tools.

```bash
# Run all tests
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16'

# Run a single test class
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoopTrackTests/ShotScienceCalculatorTests
```

Minimum deployment target: **iOS 16.0**. SwiftData is iOS 17+; the app uses a Core Data fallback for iOS 16.

## Architecture

**MVVM + SwiftData + Combine.** All ViewModels and services are `@MainActor final class` with `@Published` properties. `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide.

### Data layer

- **`Models/`** — SwiftData `@Model` classes: `PlayerProfile`, `TrainingSession`, `ShotRecord`, `GoalRecord`. All enums live in `Models/Enums.swift`.
- **`Services/DataService.swift`** — Single SwiftData abstraction. All persistence goes through here. Has `finaliseSession()` / `finaliseDribbleSession()` entry points; post-session work (goal updates, skill rating recalc) is delegated to `SessionFinalizationCoordinator` (Phase 5).
- **`TrainingSession.recalculateStats()`** — Call after modifying `shots`; caches aggregate FG%, Shot Science averages, consistency score.

### CV pipeline

The computer vision stack runs on a background `sessionQueue`. Results are dispatched to main actor for UI/model updates.

- **`CameraService`** — AVCaptureSession lifecycle, `framePublisher: AnyPublisher<CMSampleBuffer, Never>`
- **`CVPipeline`** — Shot detection state machine: `idle → tracking → release_detected → resolved`. Subscribes to `framePublisher`.
- **`CourtCalibrationService`** — Hoop detection; court position normalisation to 0–1 half-court space. Shot detection is blocked until `isCalibrated`.
- **`PoseEstimationService`** — Vision body pose for Shot Science metrics (Phase 3, rear camera)
- **`DribblePipeline`** — Hand tracking for dribble drills (Phase 4, front camera)

### Constants

All magic numbers live in `HoopTrack/Utilities/Constants.swift` as nested enums: `HoopTrack.Camera`, `HoopTrack.CourtGeometry`, `HoopTrack.ShotScience`, `HoopTrack.Dribble`, `HoopTrack.SkillRating`, etc.

### Navigation

`HoopTrackApp` → `CoordinatorHost` → `TabView` with 4 `NavigationStack` tabs: **Home**, **Train**, **Progress**, **Profile**.

The Train tab hosts the main live session flow:
1. `TrainTabView` — drill picker grid, routes to `LiveSessionView` (shot/dribble) or `AgilityDrillView` (agility) via `fullScreenCover`
2. Live session ends → `DataService.finalise*()` → `SessionFinalizationCoordinator` → `SessionSummaryView`

### App Intents & Deep Links

- **`AppIntents/`** — Siri Shortcuts: `StartFreeShootSessionIntent`, `ShowMyStatsIntent`, `ShotsTodayIntent`. `HoopTrackShortcuts` is the single registration point — adding a new shortcut requires only a new file + one line there.
- **`AppState`** — handles `hooptrack://` URL scheme routing via `.onOpenURL` in `HoopTrackApp`. Add new routes as `AppRoute` enum cases.

### Services (added Phase 6A)

- **`ExportService`** — JSON export of full session history via system share sheet. Entry point: `exportJSON(for:)`. Exported files get `FileProtectionType.complete`.
- **`MetricsService`** — MetricKit subscriber wired at launch. Collects on-device performance diagnostics; do not duplicate with manual logging.

### Security layer (added Phase 7)

- **`Utilities/KeychainService.swift`** — `@MainActor final class`. All auth tokens and sensitive values go here — never `UserDefaults`. Key constants in `HoopTrack.KeychainKey`. Call `deleteAll()` during account deletion.
- **`Utilities/InputValidator.swift`** — Pure `enum` with static validators. Call before persisting any sensor value or user string: `isValidReleaseAngle`, `isValidJumpHeight`, `isValidCourtCoordinate`, `sanitisedProfileName`.
- **`Utilities/PinningURLSessionDelegate.swift`** — SPKI SHA-256 cert pinning for Phase 9. **Replace the placeholder hash with real Supabase SPKI before Phase 9 ships.**
- **`PrivacyInfo.xcprivacy`** — App Store privacy manifest. Auto-discovered by Xcode 26. No pbxproj edits needed.
- **`DataService.deleteAllUserData()`** — GDPR right-to-delete. Clears SwiftData records, `Documents/Sessions/` files, Keychain, and all known UserDefaults keys.

## Testing conventions

Tests live in `HoopTrackTests/`. All existing tests cover **pure functions only** — calculators, classifiers, state machines. No mocks of services or SwiftData. Tests are `XCTestCase` subclasses using `@testable import HoopTrack`.

When adding new pure logic (calculators, services that take value-type inputs), write a corresponding test file following the same pattern as `ShotScienceCalculatorTests.swift`.

## Key conventions

- **No third-party dependencies.** All CV, charts, AR, and data use Apple-native frameworks only.
- **Normalised court coordinates.** Shot positions are stored as 0–1 fractions of half-court space, not screen pixels.
- **`AgilityAttempt` is in-session only** — not persisted. Aggregates (`bestShuttleRunSeconds`, `bestLaneAgilitySeconds`, `avgVerticalJumpCm`) go on `TrainingSession`.
- **Phase gating in comments.** Code sections are annotated `// Phase N —` to indicate when they were introduced. Don't remove these.
- **Portrait-only.** The app is locked to portrait; landscape breaks CV coordinate mapping.
- **Video storage.** Session videos go to `Documents/Sessions/<uuid>.mov`. Auto-deleted after `HoopTrack.Storage.defaultVideoRetainDays` (60) days unless `videoPinnedByUser = true`.
- **Swift 6 async pattern.** Never use `DispatchQueue.main.async` inside `@MainActor` classes — use `Task { @MainActor in }` instead. The project targets strict concurrency compliance.
- **Sensitive data in Keychain only.** Auth tokens, user IDs, and API keys go in `KeychainService`. `UserDefaults` and `@AppStorage` are for non-sensitive UI preferences only.
- **Validate before persisting.** All sensor values (release angle, jump height, court coordinates) and user-provided strings must pass `InputValidator` checks before writing to SwiftData or sending to any API.
- **File protection on sensitive files.** Session videos (`Documents/Sessions/`) and exported JSON must have `FileProtectionType.complete`. `HoopTrackApp` re-applies this at launch.
- **Phase plan.** See `docs/ROADMAP.md` for the full implementation roadmap and upcoming phases.

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
SwiftUI + SwiftData + Combine, iOS 16+, MVVM, @MainActor final class ViewModels,
SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, no third-party dependencies.
Key services: DataService, SessionFinalizationCoordinator, CameraService, CVPipeline.
Models: PlayerProfile, TrainingSession, ShotRecord, GoalRecord.
Upcoming stack: Supabase (Phase 9), Hasura GraphQL, Sign in with Apple.
See docs/ROADMAP.md for full phase plan.
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

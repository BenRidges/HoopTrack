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

`ContentView` → `TabView` with 4 `NavigationStack` tabs: **Home**, **Train**, **Progress**, **Profile**.

The Train tab hosts the main live session flow:
1. `TrainTabView` — drill picker grid, routes to `LiveSessionView` (shot/dribble) or `AgilityDrillView` (agility) via `fullScreenCover`
2. Live session ends → `DataService.finalise*()` → `SessionFinalizationCoordinator` → `SessionSummaryView`

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

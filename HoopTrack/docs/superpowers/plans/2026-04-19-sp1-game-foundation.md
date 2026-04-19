# SP1 Game Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the foundational data-model layer and registration flow for Game Mode so subsequent sub-phases (SP2 scoring, SP3 playoff, SP4 commentary) can build on it.

**Architecture:** Three new `@Model` SwiftData types (`GamePlayer`, `GameSession`, `GameShotRecord`) plus a serialisable `AppearanceDescriptor` value type. A new `AppearanceCaptureService` wraps Vision's `VNDetectHumanBodyPoseRequest` + CoreImage histogram extraction into a `@MainActor` service that emits descriptors once a body lock is held for 3 seconds. Registration UX uses landscape for camera screens, portrait for consent/team-assignment. No CV attribution yet — in-game shots are logged via manual make/miss buttons that write `GameShotRecord(attributionConfidence: 1.0)`.

**Tech Stack:** Swift, SwiftUI, SwiftData, Combine, Vision, CoreImage, XCTest. No new SPM deps.

---

## File Structure

**New files:**
- `HoopTrack/Models/AppearanceDescriptor.swift` — pure `Codable` struct
- `HoopTrack/Models/GamePlayer.swift` — `@Model`
- `HoopTrack/Models/GameSession.swift` — `@Model`
- `HoopTrack/Models/GameShotRecord.swift` — `@Model`
- `HoopTrack/Services/AppearanceExtraction.swift` — pure helper functions (testable)
- `HoopTrack/Services/AppearanceCaptureService.swift` — service wrapper
- `HoopTrack/ViewModels/GameRegistrationViewModel.swift` — state machine
- `HoopTrack/ViewModels/GameSessionViewModel.swift` — shell (full impl in SP2)
- `HoopTrack/Views/Game/GameConsentView.swift`
- `HoopTrack/Views/Game/GameRegistrationView.swift`
- `HoopTrack/Views/Game/TeamAssignmentView.swift`
- `HoopTrack/Views/Game/LiveGameView.swift` — shell
- `HoopTrack/Views/Game/GameSummaryView.swift` — stub
- `HoopTrack/Views/Game/GameEntryCard.swift` — component for TrainTabView
- `HoopTrackTests/AppearanceDescriptorTests.swift`
- `HoopTrackTests/AppearanceExtractionTests.swift`
- `HoopTrackTests/GameRegistrationViewModelTests.swift`
- `HoopTrackTests/GameModelTests.swift`

**Modified:**
- `HoopTrack/Models/Enums.swift` — add 4 enums
- `HoopTrack/Utilities/Constants.swift` — add `HoopTrack.Game`
- `HoopTrack/Services/DataService.swift` — add `addGameShot()`, extend `purgeOldVideos`
- `HoopTrack/AppState.swift` — add `AppRoute` cases
- `HoopTrack/Views/Train/TrainTabView.swift` — add Game entry
- `HoopTrack/Views/Progress/ProgressTabView.swift` — render `GameSession` in history
- `HoopTrack/PrivacyInfo.xcprivacy` — declare appearance capture
- `HoopTrack/HoopTrackApp.swift` — add new `@Model` types to the `modelContainer`

---

### Task 1: Enums

**Files:**
- Modify: `HoopTrack/Models/Enums.swift` (append at end of file)

- [ ] **Step 1: Append the 4 new enums to Enums.swift**

```swift
// MARK: - Game Mode (SP1)

/// What kind of game session this is. Pickup = casual 2v2/3v3.
/// `bo7Playoff` is the solo BO7 mode added in SP3.
enum GameType: String, Codable, CaseIterable, Identifiable {
    case pickup     = "Pickup"
    case bo7Playoff = "BO7 Playoff"
    var id: String { rawValue }
}

/// Lifecycle of a GameSession.
enum GameState: String, Codable {
    case registering
    case inProgress
    case completed
}

/// Which team a GamePlayer belongs to within their GameSession.
enum TeamAssignment: String, Codable, CaseIterable, Identifiable {
    case teamA = "Team A"
    case teamB = "Team B"
    var id: String { rawValue }
}

/// 2PT vs 3PT, derived from court position.
enum ShotType: String, Codable {
    case twoPoint   = "2PT"
    case threePoint = "3PT"
}

/// Number of players per team for registration. 2v2 or 3v3.
enum GameFormat: Int, Codable, CaseIterable, Identifiable {
    case twoOnTwo   = 2
    case threeOnThree = 3
    var id: Int { rawValue }
    var displayName: String {
        switch self {
        case .twoOnTwo:     return "2v2"
        case .threeOnThree: return "3v3"
        }
    }
    var totalPlayers: Int { rawValue * 2 }
}
```

- [ ] **Step 2: Build to confirm nothing breaks**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/Enums.swift
git commit -m "feat(game): add GameType/GameState/TeamAssignment/ShotType/GameFormat enums"
```

---

### Task 2: Constants — HoopTrack.Game

**Files:**
- Modify: `HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Add a new nested enum inside `HoopTrack`**

Locate the existing `enum Storage { … }` nested enum and add a new sibling enum below it:

```swift
// MARK: - Game Mode (SP1)
enum Game {
    /// How long a valid body lock must hold before registration auto-advances.
    static let registrationLockDurationSec: Double = 3.0

    /// Minimum Vision body-pose keypoint confidence (shoulders + hips) to count as "valid lock".
    static let registrationMinBodyConfidence: Float = 0.7

    /// Display hints for the user during registration (informational only).
    static let registrationMinDistanceFeet: Double = 6.0
    static let registrationMaxDistanceFeet: Double = 8.0

    /// Hard cap on team size — matches max `GameFormat` (3v3).
    static let maxPlayersPerTeam: Int = 3

    /// AppearanceDescriptor histogram dimensions.
    static let histogramHueBins: Int = 8
    static let histogramValueBins: Int = 4

    /// AppearanceDescriptor schema version — bump on breaking field changes.
    static let appearanceDescriptorSchemaVersion: Int = 1
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/Constants.swift
git commit -m "feat(game): add HoopTrack.Game constants block"
```

---

### Task 3: AppearanceDescriptor — test-first

**Files:**
- Create: `HoopTrackTests/AppearanceDescriptorTests.swift`
- Create: `HoopTrack/Models/AppearanceDescriptor.swift`

- [ ] **Step 1: Write the failing tests**

Write `HoopTrackTests/AppearanceDescriptorTests.swift`:

```swift
import XCTest
@testable import HoopTrack

final class AppearanceDescriptorTests: XCTestCase {

    func test_roundTripJSONEncoding_preservesAllFields() throws {
        let original = AppearanceDescriptor(
            torsoHueHistogram: [0.1, 0.2, 0.1, 0.05, 0.05, 0.2, 0.15, 0.15],
            torsoValueHistogram: [0.25, 0.25, 0.25, 0.25],
            heightRatio: 0.42,
            upperBodyAspect: 0.6,
            schemaVersion: 1
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppearanceDescriptor.self, from: data)

        XCTAssertEqual(decoded.torsoHueHistogram, original.torsoHueHistogram)
        XCTAssertEqual(decoded.torsoValueHistogram, original.torsoValueHistogram)
        XCTAssertEqual(decoded.heightRatio, original.heightRatio, accuracy: 1e-6)
        XCTAssertEqual(decoded.upperBodyAspect, original.upperBodyAspect, accuracy: 1e-6)
        XCTAssertEqual(decoded.schemaVersion, original.schemaVersion)
    }

    func test_isWellFormed_trueForValidDescriptor() {
        let valid = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.65,
            schemaVersion: 1
        )
        XCTAssertTrue(valid.isWellFormed)
    }

    func test_isWellFormed_falseForWrongHueBinCount() {
        let bad = AppearanceDescriptor(
            torsoHueHistogram: [0.5, 0.5],                    // should be 8
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.65,
            schemaVersion: 1
        )
        XCTAssertFalse(bad.isWellFormed)
    }

    func test_isWellFormed_falseForUnnormalisedHistogram() {
        let bad = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 1.0, count: 8),   // sums to 8.0
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.65,
            schemaVersion: 1
        )
        XCTAssertFalse(bad.isWellFormed)
    }
}
```

- [ ] **Step 2: Run — expect failure (type doesn't exist yet)**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/AppearanceDescriptorTests -quiet 2>&1 | tail -10`
Expected: `error: cannot find 'AppearanceDescriptor' in scope`

- [ ] **Step 3: Create AppearanceDescriptor**

Write `HoopTrack/Models/AppearanceDescriptor.swift`:

```swift
// AppearanceDescriptor.swift
// A small serialisable profile captured during Game Mode registration.
// Session-scoped — never written outside the GamePlayer that owns it,
// never uploaded. See docs/superpowers/specs/2026-04-19-game-foundation-design.md §3.

import Foundation

struct AppearanceDescriptor: Codable, Sendable, Equatable {
    /// 8-bin hue histogram of upper-body pixels, normalised so bins sum to 1.0.
    let torsoHueHistogram: [Float]

    /// 4-bin value/brightness histogram of the same region, also normalised.
    let torsoValueHistogram: [Float]

    /// Body height as a fraction of frame height (0..1).
    let heightRatio: Float

    /// Upper-body bounding-box aspect ratio (width / height).
    let upperBodyAspect: Float

    /// Schema version for future descriptor upgrades.
    let schemaVersion: Int

    /// True when the descriptor matches the expected schema — used in tests
    /// and defensively by the matcher in SP2.
    var isWellFormed: Bool {
        guard torsoHueHistogram.count == HoopTrack.Game.histogramHueBins,
              torsoValueHistogram.count == HoopTrack.Game.histogramValueBins,
              heightRatio >= 0, heightRatio <= 1,
              upperBodyAspect > 0
        else { return false }
        let hueSum = torsoHueHistogram.reduce(0, +)
        let valueSum = torsoValueHistogram.reduce(0, +)
        let tolerance: Float = 0.02
        return abs(hueSum - 1.0) < tolerance && abs(valueSum - 1.0) < tolerance
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/AppearanceDescriptorTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'AppearanceDescriptorTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Models/AppearanceDescriptor.swift HoopTrack/HoopTrackTests/AppearanceDescriptorTests.swift
git commit -m "feat(game): add AppearanceDescriptor value type with roundtrip tests"
```

---

### Task 4: GamePlayer model

**Files:**
- Create: `HoopTrack/Models/GamePlayer.swift`

- [ ] **Step 1: Create the @Model type**

```swift
// GamePlayer.swift
// A player registered to a specific GameSession. Ephemeral — cascade-deleted
// with the parent GameSession. `appearanceEmbedding` carries a JSON-encoded
// AppearanceDescriptor.

import Foundation
import SwiftData

@Model
final class GamePlayer {
    @Attribute(.unique) var id: UUID
    var name: String
    var appearanceEmbedding: Data
    var teamAssignmentRaw: String   // TeamAssignment.rawValue — SwiftData enums need a bit of ceremony
    var gameSession: GameSession?
    var linkedProfile: PlayerProfile?
    var registeredAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        appearanceEmbedding: Data,
        teamAssignment: TeamAssignment,
        linkedProfile: PlayerProfile? = nil
    ) {
        self.id = id
        self.name = name
        self.appearanceEmbedding = appearanceEmbedding
        self.teamAssignmentRaw = teamAssignment.rawValue
        self.gameSession = nil
        self.linkedProfile = linkedProfile
        self.registeredAt = .now
    }

    /// Typed view on the raw-string-backed team assignment. Keeps call sites clean.
    var teamAssignment: TeamAssignment {
        get { TeamAssignment(rawValue: teamAssignmentRaw) ?? .teamA }
        set { teamAssignmentRaw = newValue.rawValue }
    }

    /// Decoded descriptor. Returns nil if the blob is malformed — caller
    /// must guard (SP2 attribution will).
    var appearanceDescriptor: AppearanceDescriptor? {
        try? JSONDecoder().decode(AppearanceDescriptor.self, from: appearanceEmbedding)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/GamePlayer.swift
git commit -m "feat(game): add GamePlayer @Model"
```

---

### Task 5: GameShotRecord model

**Files:**
- Create: `HoopTrack/Models/GameShotRecord.swift`

- [ ] **Step 1: Create the @Model type**

```swift
// GameShotRecord.swift
// One shot attempt within a GameSession. Sibling to ShotRecord (used in solo
// TrainingSession) — intentionally separate because player attribution and
// shotType differ. attributionConfidence is 1.0 in SP1 (manual logging) and
// gets lowered once SP2's PlayerTracker attributes shots automatically.

import Foundation
import SwiftData

@Model
final class GameShotRecord {
    @Attribute(.unique) var id: UUID

    /// Nullable — unattributed shots (SP2 fallback) are kept here with
    /// shooter = nil until the user resolves them in the box score.
    var shooter: GamePlayer?

    var resultRaw: String            // ShotResult.rawValue
    var courtX: Double               // 0..1 normalised half-court
    var courtY: Double
    var timestamp: Date
    var shotTypeRaw: String          // ShotType.rawValue
    var attributionConfidence: Double
    var gameSession: GameSession?

    init(
        id: UUID = UUID(),
        shooter: GamePlayer?,
        result: ShotResult,
        courtX: Double,
        courtY: Double,
        timestamp: Date = .now,
        shotType: ShotType,
        attributionConfidence: Double = 1.0
    ) {
        self.id = id
        self.shooter = shooter
        self.resultRaw = result.rawValue
        self.courtX = courtX
        self.courtY = courtY
        self.timestamp = timestamp
        self.shotTypeRaw = shotType.rawValue
        self.attributionConfidence = attributionConfidence
    }

    var result: ShotResult {
        get { ShotResult(rawValue: resultRaw) ?? .miss }
        set { resultRaw = newValue.rawValue }
    }

    var shotType: ShotType {
        get { ShotType(rawValue: shotTypeRaw) ?? .twoPoint }
        set { shotTypeRaw = newValue.rawValue }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/GameShotRecord.swift
git commit -m "feat(game): add GameShotRecord @Model"
```

---

### Task 6: GameSession model

**Files:**
- Create: `HoopTrack/Models/GameSession.swift`

- [ ] **Step 1: Create the @Model type**

```swift
// GameSession.swift
// One multi-player game (pickup or BO7 playoff). Sibling to TrainingSession,
// not a subclass — team structure + per-player shots warrant separation.
// Videos follow the same local-retention rules as TrainingSession (see
// DataService.purgeOldVideos).

import Foundation
import SwiftData

@Model
final class GameSession {
    @Attribute(.unique) var id: UUID
    var gameTypeRaw: String       // GameType.rawValue
    var gameFormatRaw: Int        // GameFormat.rawValue
    @Relationship(deleteRule: .cascade, inverse: \GamePlayer.gameSession)
    var players: [GamePlayer]
    var teamAScore: Int
    var teamBScore: Int
    var startTimestamp: Date
    var endTimestamp: Date?
    var gameStateRaw: String      // GameState.rawValue
    @Relationship(deleteRule: .cascade, inverse: \GameShotRecord.gameSession)
    var shots: [GameShotRecord]
    var targetScore: Int?
    var videoFileName: String?
    var videoPinnedByUser: Bool

    init(
        id: UUID = UUID(),
        gameType: GameType,
        gameFormat: GameFormat,
        targetScore: Int? = nil
    ) {
        self.id = id
        self.gameTypeRaw = gameType.rawValue
        self.gameFormatRaw = gameFormat.rawValue
        self.players = []
        self.teamAScore = 0
        self.teamBScore = 0
        self.startTimestamp = .now
        self.endTimestamp = nil
        self.gameStateRaw = GameState.registering.rawValue
        self.shots = []
        self.targetScore = targetScore
        self.videoFileName = nil
        self.videoPinnedByUser = false
    }

    var gameType: GameType {
        get { GameType(rawValue: gameTypeRaw) ?? .pickup }
        set { gameTypeRaw = newValue.rawValue }
    }

    var gameFormat: GameFormat {
        get { GameFormat(rawValue: gameFormatRaw) ?? .twoOnTwo }
        set { gameFormatRaw = newValue.rawValue }
    }

    var gameState: GameState {
        get { GameState(rawValue: gameStateRaw) ?? .registering }
        set { gameStateRaw = newValue.rawValue }
    }

    /// Duration in seconds. Falls back to elapsed-since-start if still running.
    var durationSeconds: TimeInterval {
        (endTimestamp ?? .now).timeIntervalSince(startTimestamp)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Models/GameSession.swift
git commit -m "feat(game): add GameSession @Model with cascade-delete relationships"
```

---

### Task 7: Register models with the SwiftData container

**Files:**
- Modify: `HoopTrack/HoopTrackApp.swift`

- [ ] **Step 1: Locate the `.modelContainer(for:)` call**

Open `HoopTrack/HoopTrackApp.swift` and find the `modelContainer(for:)` modifier. It currently lists the existing `@Model` types (PlayerProfile, TrainingSession, etc.).

- [ ] **Step 2: Add the 3 new model types to the container**

Append `GamePlayer.self, GameSession.self, GameShotRecord.self` to the list passed to `.modelContainer(for:)`. Example before/after:

```swift
// Before
.modelContainer(for: [
    PlayerProfile.self,
    TrainingSession.self,
    ShotRecord.self,
    GoalRecord.self,
    EarnedBadge.self,
])

// After
.modelContainer(for: [
    PlayerProfile.self,
    TrainingSession.self,
    ShotRecord.self,
    GoalRecord.self,
    EarnedBadge.self,
    GamePlayer.self,
    GameSession.self,
    GameShotRecord.self,
])
```

- [ ] **Step 3: Build and launch the app once in the simulator to verify additive migration works**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

Then open the simulator manually and confirm the app launches (SwiftData schema migration for additive stores is lightweight; failures manifest as a startup crash).

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/HoopTrackApp.swift
git commit -m "feat(game): register Game models with SwiftData container"
```

---

### Task 8: GameModelTests — SwiftData smoke test

**Files:**
- Create: `HoopTrackTests/GameModelTests.swift`

- [ ] **Step 1: Write smoke tests**

```swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class GameModelTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(
            for: GamePlayer.self, GameSession.self, GameShotRecord.self,
            configurations: config
        )
    }

    private func makeDescriptorBlob() throws -> Data {
        let desc = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5,
            upperBodyAspect: 0.6,
            schemaVersion: 1
        )
        return try JSONEncoder().encode(desc)
    }

    func test_insertingGameSession_persistsPlayersAndShots() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let blob = try makeDescriptorBlob()
        let session = GameSession(gameType: .pickup, gameFormat: .twoOnTwo)
        let player = GamePlayer(
            name: "Ben",
            appearanceEmbedding: blob,
            teamAssignment: .teamA
        )
        session.players.append(player)

        let shot = GameShotRecord(
            shooter: player,
            result: .make,
            courtX: 0.5, courtY: 0.6,
            shotType: .threePoint
        )
        session.shots.append(shot)

        ctx.insert(session)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<GameSession>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.players.count, 1)
        XCTAssertEqual(fetched.first?.shots.count, 1)
        XCTAssertEqual(fetched.first?.shots.first?.shooter?.name, "Ben")
    }

    func test_deletingSession_cascadesToPlayersAndShots() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let blob = try makeDescriptorBlob()
        let session = GameSession(gameType: .pickup, gameFormat: .twoOnTwo)
        session.players.append(
            GamePlayer(name: "A", appearanceEmbedding: blob, teamAssignment: .teamA)
        )
        session.shots.append(
            GameShotRecord(shooter: nil, result: .miss, courtX: 0, courtY: 0, shotType: .twoPoint)
        )
        ctx.insert(session)
        try ctx.save()

        ctx.delete(session)
        try ctx.save()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<GameSession>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<GamePlayer>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<GameShotRecord>()).count, 0)
    }

    func test_appearanceDescriptor_roundTripsThroughGamePlayer() throws {
        let container = try makeContainer()
        let ctx = container.mainContext

        let desc = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.42,
            upperBodyAspect: 0.6,
            schemaVersion: 1
        )
        let blob = try JSONEncoder().encode(desc)
        let player = GamePlayer(name: "X", appearanceEmbedding: blob, teamAssignment: .teamA)
        ctx.insert(player)
        try ctx.save()

        let decoded = player.appearanceDescriptor
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.heightRatio, 0.42, accuracy: 1e-6)
    }
}
```

- [ ] **Step 2: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/GameModelTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'GameModelTests' passed`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrackTests/GameModelTests.swift
git commit -m "test(game): smoke tests for Game model container + cascade delete"
```

---

### Task 9: AppearanceExtraction — pure helpers, test-first

**Files:**
- Create: `HoopTrackTests/AppearanceExtractionTests.swift`
- Create: `HoopTrack/Services/AppearanceExtraction.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
import CoreGraphics
@testable import HoopTrack

final class AppearanceExtractionTests: XCTestCase {

    // MARK: - normalizedHistogram

    func test_normalizedHistogram_sumsToOne() {
        let raw: [Float] = [10, 20, 30, 40]
        let out = AppearanceExtraction.normalizedHistogram(raw)
        XCTAssertEqual(out.reduce(0, +), 1.0, accuracy: 1e-5)
        XCTAssertEqual(out[0], 0.1, accuracy: 1e-5)
        XCTAssertEqual(out[3], 0.4, accuracy: 1e-5)
    }

    func test_normalizedHistogram_allZeros_returnsUniform() {
        let out = AppearanceExtraction.normalizedHistogram([0, 0, 0, 0])
        XCTAssertEqual(out.reduce(0, +), 1.0, accuracy: 1e-5)
        XCTAssertEqual(out[0], out[1])
        XCTAssertEqual(out[1], out[2])
    }

    // MARK: - upperBodyBox

    func test_upperBodyBox_fromStandardKeypoints() {
        // Mock: shoulders at y=0.3, hips at y=0.55, both roughly centered.
        let leftShoulder  = CGPoint(x: 0.45, y: 0.30)
        let rightShoulder = CGPoint(x: 0.55, y: 0.30)
        let leftHip       = CGPoint(x: 0.46, y: 0.55)
        let rightHip      = CGPoint(x: 0.54, y: 0.55)

        let box = AppearanceExtraction.upperBodyBox(
            leftShoulder: leftShoulder,
            rightShoulder: rightShoulder,
            leftHip: leftHip,
            rightHip: rightHip
        )

        // X spans 0.45..0.55 (width 0.1), Y spans 0.30..0.55 (height 0.25).
        XCTAssertEqual(box.minX, 0.45, accuracy: 1e-5)
        XCTAssertEqual(box.width, 0.10, accuracy: 1e-5)
        XCTAssertEqual(box.minY, 0.30, accuracy: 1e-5)
        XCTAssertEqual(box.height, 0.25, accuracy: 1e-5)
    }

    // MARK: - heightRatio

    func test_heightRatio_fromNoseToAnkles() {
        let nose   = CGPoint(x: 0.5, y: 0.15)
        let lAnkle = CGPoint(x: 0.48, y: 0.90)
        let rAnkle = CGPoint(x: 0.52, y: 0.88)
        let ratio = AppearanceExtraction.heightRatio(
            nose: nose, leftAnkle: lAnkle, rightAnkle: rAnkle
        )
        // y span: 0.90 - 0.15 = 0.75
        XCTAssertEqual(ratio, 0.75, accuracy: 1e-5)
    }
}
```

- [ ] **Step 2: Run — expect failure (type doesn't exist)**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/AppearanceExtractionTests -quiet 2>&1 | tail -5`
Expected: `error: cannot find 'AppearanceExtraction' in scope`

- [ ] **Step 3: Create the extraction module**

```swift
// AppearanceExtraction.swift
// Pure static helpers used by AppearanceCaptureService. Kept separate so the
// math is unit-testable without Vision / CoreImage dependencies.

import Foundation
import CoreGraphics
import CoreImage

enum AppearanceExtraction {

    /// Normalises counts so the bins sum to 1.0. Returns a uniform distribution
    /// when the input is all-zero (pathological but safe fallback).
    static func normalizedHistogram(_ counts: [Float]) -> [Float] {
        let total = counts.reduce(0, +)
        guard total > 0 else {
            let uniform = Float(1.0) / Float(max(counts.count, 1))
            return Array(repeating: uniform, count: counts.count)
        }
        return counts.map { $0 / total }
    }

    /// Axis-aligned bounding rect covering shoulder-to-hip keypoints in
    /// the shared normalised coordinate space (0..1 on both axes).
    static func upperBodyBox(
        leftShoulder: CGPoint, rightShoulder: CGPoint,
        leftHip: CGPoint, rightHip: CGPoint
    ) -> CGRect {
        let minX = min(leftShoulder.x, rightShoulder.x, leftHip.x, rightHip.x)
        let maxX = max(leftShoulder.x, rightShoulder.x, leftHip.x, rightHip.x)
        let minY = min(leftShoulder.y, rightShoulder.y)
        let maxY = max(leftHip.y, rightHip.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Body height as fraction of frame height. Uses nose → ankle span.
    static func heightRatio(
        nose: CGPoint, leftAnkle: CGPoint, rightAnkle: CGPoint
    ) -> Float {
        let ankleY = max(leftAnkle.y, rightAnkle.y)
        return Float(ankleY - nose.y)
    }

    /// Build an 8-bin hue histogram + 4-bin value histogram from a rect of
    /// `image`. Coordinates in `rect` are in `image` pixel-space.
    /// Returns (hue8, value4) as normalised [Float] arrays. Caller owns the CIImage.
    static func histograms(
        from image: CIImage,
        rect: CGRect,
        hueBins: Int = HoopTrack.Game.histogramHueBins,
        valueBins: Int = HoopTrack.Game.histogramValueBins
    ) -> (hue: [Float], value: [Float]) {
        var hueCounts = [Float](repeating: 0, count: hueBins)
        var valueCounts = [Float](repeating: 0, count: valueBins)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        let clamped = image.cropped(to: rect)
        guard let cg = context.createCGImage(clamped, from: clamped.extent) else {
            return (normalizedHistogram(hueCounts), normalizedHistogram(valueCounts))
        }

        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else {
            return (normalizedHistogram(hueCounts), normalizedHistogram(valueCounts))
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Sub-sample every 4th pixel for speed — perceptually indistinguishable.
        let step = 4
        for y in stride(from: 0, to: height, by: step) {
            for x in stride(from: 0, to: width, by: step) {
                let i = (y * bytesPerRow) + (x * bytesPerPixel)
                let r = Float(pixels[i])     / 255.0
                let g = Float(pixels[i + 1]) / 255.0
                let b = Float(pixels[i + 2]) / 255.0

                let maxC = max(r, g, b)
                let minC = min(r, g, b)
                let v = maxC
                let delta = maxC - minC

                // Hue in 0..6; convert to 0..1 then bin.
                var h: Float = 0
                if delta > 0 {
                    if maxC == r      { h = (g - b) / delta }
                    else if maxC == g { h = 2 + (b - r) / delta }
                    else              { h = 4 + (r - g) / delta }
                }
                h = h / 6
                if h < 0 { h += 1 }

                let hueBin = min(Int(h * Float(hueBins)), hueBins - 1)
                let valueBin = min(Int(v * Float(valueBins)), valueBins - 1)
                hueCounts[hueBin] += 1
                valueCounts[valueBin] += 1
            }
        }

        return (normalizedHistogram(hueCounts), normalizedHistogram(valueCounts))
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/AppearanceExtractionTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'AppearanceExtractionTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Services/AppearanceExtraction.swift HoopTrack/HoopTrackTests/AppearanceExtractionTests.swift
git commit -m "feat(game): AppearanceExtraction pure helpers (histogram math, body-box, height)"
```

---

### Task 10: AppearanceCaptureService

**Files:**
- Create: `HoopTrack/Services/AppearanceCaptureService.swift`

- [ ] **Step 1: Create the service**

```swift
// AppearanceCaptureService.swift
// Ingests CMSampleBuffers, runs Vision body-pose detection, and emits an
// AppearanceDescriptor once a high-confidence lock has held for
// HoopTrack.Game.registrationLockDurationSec seconds.
//
// Public surface:
//   - @Published lockProgress: Double  (0..1 — how close to a valid capture)
//   - @Published captured: AppearanceDescriptor?  (fires once on success)
//   - func ingest(sampleBuffer:) — called by camera pipeline
//   - func reset() — call between players

import Foundation
import Combine
import Vision
import CoreImage
import AVFoundation

@MainActor
final class AppearanceCaptureService: ObservableObject {

    @Published private(set) var lockProgress: Double = 0   // 0..1
    @Published private(set) var captured: AppearanceDescriptor?
    @Published private(set) var statusMessage: String = "Step in front of the camera."

    private var lockStart: Date?
    private let minConfidence: Float = HoopTrack.Game.registrationMinBodyConfidence
    private let requiredDurationSec: Double = HoopTrack.Game.registrationLockDurationSec

    func reset() {
        lockStart = nil
        lockProgress = 0
        captured = nil
        statusMessage = "Step in front of the camera."
    }

    func ingest(sampleBuffer: CMSampleBuffer) {
        guard captured == nil,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectHumanBodyPoseRequest()

        do {
            try handler.perform([request])
        } catch {
            return
        }

        guard let observation = (request.results as? [VNHumanBodyPoseObservation])?.first,
              let points = try? observation.recognizedPoints(.all) else {
            breakLock(reason: "No person detected. Stand ~6-8 feet from the camera.")
            return
        }

        // Require high-confidence shoulder + hip keypoints.
        let required: [VNHumanBodyPoseObservation.JointName] =
            [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        for joint in required {
            guard let p = points[joint], p.confidence >= minConfidence else {
                breakLock(reason: "Stand facing the camera, whole torso visible.")
                return
            }
        }

        // Lock acquired — advance progress
        if lockStart == nil { lockStart = .now; statusMessage = "Hold still…" }
        let elapsed = Date.now.timeIntervalSince(lockStart!)
        lockProgress = min(elapsed / requiredDurationSec, 1.0)

        if elapsed >= requiredDurationSec {
            capture(points: points, pixelBuffer: pixelBuffer)
        }
    }

    // MARK: - Private

    private func breakLock(reason: String) {
        lockStart = nil
        lockProgress = 0
        statusMessage = reason
    }

    private func capture(
        points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        pixelBuffer: CVPixelBuffer
    ) {
        guard let ls = points[.leftShoulder]?.location,
              let rs = points[.rightShoulder]?.location,
              let lh = points[.leftHip]?.location,
              let rh = points[.rightHip]?.location,
              let nose = points[.nose]?.location,
              let la = points[.leftAnkle]?.location,
              let ra = points[.rightAnkle]?.location
        else {
            breakLock(reason: "Couldn't see full body. Step back and try again.")
            return
        }

        let imageWidth  = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let normalizedBox = AppearanceExtraction.upperBodyBox(
            leftShoulder: ls, rightShoulder: rs, leftHip: lh, rightHip: rh
        )
        let pixelBox = CGRect(
            x: normalizedBox.minX * imageWidth,
            y: (1 - normalizedBox.maxY) * imageHeight,   // Vision Y is bottom-up
            width: normalizedBox.width * imageWidth,
            height: normalizedBox.height * imageHeight
        )

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let (hue, value) = AppearanceExtraction.histograms(from: ciImage, rect: pixelBox)

        let descriptor = AppearanceDescriptor(
            torsoHueHistogram: hue,
            torsoValueHistogram: value,
            heightRatio: AppearanceExtraction.heightRatio(nose: nose, leftAnkle: la, rightAnkle: ra),
            upperBodyAspect: Float(normalizedBox.width / max(normalizedBox.height, 0.001)),
            schemaVersion: HoopTrack.Game.appearanceDescriptorSchemaVersion
        )

        self.captured = descriptor
        self.lockProgress = 1.0
        self.statusMessage = "Captured!"
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Services/AppearanceCaptureService.swift
git commit -m "feat(game): AppearanceCaptureService — ingests frames, emits descriptor on 3s lock"
```

---

### Task 11: GameRegistrationViewModel — state machine, test-first

**Files:**
- Create: `HoopTrackTests/GameRegistrationViewModelTests.swift`
- Create: `HoopTrack/ViewModels/GameRegistrationViewModel.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import HoopTrack

@MainActor
final class GameRegistrationViewModelTests: XCTestCase {

    private func sampleBlob() throws -> Data {
        let desc = AppearanceDescriptor(
            torsoHueHistogram: Array(repeating: 0.125, count: 8),
            torsoValueHistogram: Array(repeating: 0.25, count: 4),
            heightRatio: 0.5, upperBodyAspect: 0.6, schemaVersion: 1
        )
        return try JSONEncoder().encode(desc)
    }

    func test_initialState_hasCurrentPlayerIndexZero() {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        XCTAssertEqual(vm.currentPlayerIndex, 0)
        XCTAssertEqual(vm.totalPlayers, 4)
        XCTAssertFalse(vm.isComplete)
        XCTAssertEqual(vm.pendingPlayers.count, 0)
    }

    func test_confirmPlayer_advancesIndex() throws {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        let blob = try sampleBlob()
        vm.confirmPlayer(name: "Ben", descriptor: blob)
        XCTAssertEqual(vm.currentPlayerIndex, 1)
        XCTAssertEqual(vm.pendingPlayers.count, 1)
        XCTAssertEqual(vm.pendingPlayers.first?.name, "Ben")
    }

    func test_confirmingAllPlayers_setsIsCompleteTrue() throws {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        let blob = try sampleBlob()
        for i in 0..<vm.totalPlayers {
            vm.confirmPlayer(name: "P\(i)", descriptor: blob)
        }
        XCTAssertTrue(vm.isComplete)
        XCTAssertEqual(vm.pendingPlayers.count, 4)
    }

    func test_restart_resetsState() throws {
        let vm = GameRegistrationViewModel(format: .twoOnTwo)
        let blob = try sampleBlob()
        vm.confirmPlayer(name: "A", descriptor: blob)
        vm.restart()
        XCTAssertEqual(vm.currentPlayerIndex, 0)
        XCTAssertEqual(vm.pendingPlayers.count, 0)
        XCTAssertFalse(vm.isComplete)
    }

    func test_threeOnThree_requiresSixPlayers() {
        let vm = GameRegistrationViewModel(format: .threeOnThree)
        XCTAssertEqual(vm.totalPlayers, 6)
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/GameRegistrationViewModelTests -quiet 2>&1 | tail -5`
Expected: `error: cannot find 'GameRegistrationViewModel' in scope`

- [ ] **Step 3: Implement the view model**

```swift
// GameRegistrationViewModel.swift
// State machine for the multi-player registration flow. UI observes
// `currentPlayerIndex`, `pendingPlayers`, and `isComplete`. The view is
// responsible for wiring up AppearanceCaptureService; the view model
// just tracks who's been confirmed.

import Foundation
import Combine

@MainActor
final class GameRegistrationViewModel: ObservableObject {

    struct PendingPlayer: Identifiable, Equatable {
        let id = UUID()
        let name: String
        /// JSON-encoded AppearanceDescriptor. Persisted into GamePlayer.appearanceEmbedding later.
        let descriptorBlob: Data
    }

    let format: GameFormat
    @Published private(set) var currentPlayerIndex: Int = 0
    @Published private(set) var pendingPlayers: [PendingPlayer] = []

    init(format: GameFormat) {
        self.format = format
    }

    var totalPlayers: Int { format.totalPlayers }

    var isComplete: Bool { pendingPlayers.count >= totalPlayers }

    /// Banner text for the registration screen.
    var prompt: String {
        "Player \(currentPlayerIndex + 1) of \(totalPlayers) — step in front of the camera."
    }

    func confirmPlayer(name: String, descriptor: Data) {
        guard !isComplete else { return }
        pendingPlayers.append(PendingPlayer(name: name, descriptorBlob: descriptor))
        currentPlayerIndex = min(currentPlayerIndex + 1, totalPlayers)
    }

    func restart() {
        pendingPlayers.removeAll()
        currentPlayerIndex = 0
    }
}
```

- [ ] **Step 4: Run — expect pass**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/GameRegistrationViewModelTests -quiet 2>&1 | tail -5`
Expected: `Test Suite 'GameRegistrationViewModelTests' passed`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/ViewModels/GameRegistrationViewModel.swift HoopTrack/HoopTrackTests/GameRegistrationViewModelTests.swift
git commit -m "feat(game): GameRegistrationViewModel state machine with TDD tests"
```

---

### Task 12: DataService extensions — addGameShot + purge

**Files:**
- Modify: `HoopTrack/Services/DataService.swift`

- [ ] **Step 1: Add `addGameShot`**

Inside the `DataService` class, add the following method near the other `add*` methods:

```swift
// MARK: - Game Mode (SP1)

/// Append a shot to an existing game session and update the team score.
/// In SP1 this is called from the manual make/miss buttons in LiveGameView.
/// SP2 upgrades to CV-attributed shots via GameScoringCoordinator.
func addGameShot(
    to session: GameSession,
    shooter: GamePlayer?,
    result: ShotResult,
    courtX: Double,
    courtY: Double,
    shotType: ShotType,
    attributionConfidence: Double = 1.0
) throws {
    // Defensive: keep court coords sane (defence in depth vs InputValidator).
    guard InputValidator.isValidCourtCoordinate(x: courtX, y: courtY) else {
        throw DataServiceError.invalidCourtCoordinate
    }
    let shot = GameShotRecord(
        shooter: shooter,
        result: result,
        courtX: courtX, courtY: courtY,
        shotType: shotType,
        attributionConfidence: attributionConfidence
    )
    session.shots.append(shot)
    if result == .make {
        let points = (shotType == .threePoint) ? 3 : 2
        switch shooter?.teamAssignment {
        case .teamA: session.teamAScore += points
        case .teamB: session.teamBScore += points
        case .none:  break   // unattributed — no team to credit
        }
    }
    try modelContext.save()
}
```

- [ ] **Step 2: Extend `purgeOldVideos` to cover GameSession**

Locate the existing `purgeOldVideos(olderThanDays:)` method. It currently fetches `TrainingSession` rows. Duplicate the existing block for `GameSession`. Replace the method body with:

```swift
func purgeOldVideos(olderThanDays days: Int) throws {
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now)!
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let sessionsDir = docs.appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)

    // Training sessions
    let trainingPred = #Predicate<TrainingSession> {
        $0.startedAt < cutoff && !$0.videoPinnedByUser
    }
    let staleTraining = try modelContext.fetch(FetchDescriptor(predicate: trainingPred))
    for session in staleTraining {
        guard let filename = session.videoFileName else { continue }
        try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(filename))
        session.videoFileName = nil
    }

    // Game sessions
    let gamePred = #Predicate<GameSession> {
        $0.startTimestamp < cutoff && !$0.videoPinnedByUser
    }
    let staleGame = try modelContext.fetch(FetchDescriptor(predicate: gamePred))
    for session in staleGame {
        guard let filename = session.videoFileName else { continue }
        try? FileManager.default.removeItem(at: sessionsDir.appendingPathComponent(filename))
        session.videoFileName = nil
    }

    try modelContext.save()
}
```

Note: If `DataServiceError.invalidCourtCoordinate` doesn't already exist in the enum, add it now (check the top of `DataService.swift` for the existing error type).

- [ ] **Step 3: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Services/DataService.swift
git commit -m "feat(game): DataService.addGameShot + purgeOldVideos for GameSession"
```

---

### Task 13: AppRoute cases + GameSessionViewModel shell

**Files:**
- Modify: `HoopTrack/AppState.swift` (add new AppRoute cases)
- Create: `HoopTrack/ViewModels/GameSessionViewModel.swift`

- [ ] **Step 1: Add AppRoute cases for the new game flows**

Find the `AppRoute` enum in `AppState.swift`. Add the following cases:

```swift
// MARK: - Game Mode (SP1)
case gameConsent(format: GameFormat, gameType: GameType)
case gameRegistration(format: GameFormat, gameType: GameType)
case gameTeamAssignment(format: GameFormat, gameType: GameType)
case liveGame(sessionID: UUID)
case gameSummary(sessionID: UUID)
```

- [ ] **Step 2: Create the shell view model**

Write `HoopTrack/ViewModels/GameSessionViewModel.swift`:

```swift
// GameSessionViewModel.swift
// SP1: shell that owns the current GameSession row and exposes manual
// make/miss helpers for LiveGameView. SP2 replaces the manual path with
// CV attribution via GameScoringCoordinator.

import Foundation
import Combine
import SwiftData

@MainActor
final class GameSessionViewModel: ObservableObject {
    @Published private(set) var session: GameSession
    private let dataService: DataService

    init(session: GameSession, dataService: DataService) {
        self.session = session
        self.dataService = dataService
    }

    /// Manual make/miss for SP1. SP2 replaces with CV-driven entries.
    func logShot(
        shooter: GamePlayer,
        result: ShotResult,
        courtX: Double,
        courtY: Double,
        shotType: ShotType
    ) {
        try? dataService.addGameShot(
            to: session,
            shooter: shooter,
            result: result,
            courtX: courtX, courtY: courtY,
            shotType: shotType
        )
    }

    func endSession() {
        session.gameState = .completed
        session.endTimestamp = .now
        try? dataService.modelContext.save()
    }
}
```

Note: The init assumes `DataService.modelContext` is exposed. Check the existing file — if it isn't, either expose it (`public let modelContext: ModelContext`) or add a matching save helper on `DataService` and call that instead.

- [ ] **Step 3: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/AppState.swift HoopTrack/HoopTrack/ViewModels/GameSessionViewModel.swift
git commit -m "feat(game): AppRoute cases + GameSessionViewModel shell"
```

---

### Task 14: GameConsentView

**Files:**
- Create: `HoopTrack/Views/Game/GameConsentView.swift`

- [ ] **Step 1: Create the view**

```swift
// GameConsentView.swift
// Plain-language consent before appearance capture. Required before any
// camera activation for Game Mode registration — see master plan §6.3.

import SwiftUI

struct GameConsentView: View {
    let format: GameFormat
    let gameType: GameType
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "person.2.wave.2.fill")
                .font(.system(size: 60))
                .foregroundStyle(.orange.gradient)
                .padding(.top, 40)

            Text("Quick heads-up")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 16) {
                bullet(
                    systemImage: "camera",
                    title: "We'll capture an appearance profile",
                    body: "For each player, HoopTrack records a short clothing-colour profile so the camera can tell who's shooting."
                )
                bullet(
                    systemImage: "lock.shield",
                    title: "It stays on this phone",
                    body: "Profiles are stored only for this game and deleted automatically when the game ends. Nothing is uploaded."
                )
                bullet(
                    systemImage: "person.crop.circle.badge.checkmark",
                    title: "Consent from everyone",
                    body: "Only register players who've agreed to being on camera."
                )
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text("I understand — continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(.orange, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                Button("Cancel", action: onCancel)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .accessibilityElement(children: .contain)
    }

    private func bullet(systemImage: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(body).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Game/GameConsentView.swift
git commit -m "feat(game): GameConsentView — plain-language appearance-capture consent"
```

---

### Task 15: GameRegistrationView

**Files:**
- Create: `HoopTrack/Views/Game/GameRegistrationView.swift`

- [ ] **Step 1: Create the view**

```swift
// GameRegistrationView.swift
// Landscape camera preview + lock progress ring + post-capture name-entry sheet.
// Wires CameraService.framePublisher → AppearanceCaptureService and forwards
// confirmed descriptors into GameRegistrationViewModel.

import SwiftUI
import Combine

struct GameRegistrationView: View {
    @StateObject private var captureService = AppearanceCaptureService()
    @StateObject private var cameraService = CameraService()
    @ObservedObject var viewModel: GameRegistrationViewModel

    let onComplete: ([GameRegistrationViewModel.PendingPlayer]) -> Void
    let onCancel: () -> Void

    @State private var pendingName: String = ""
    @State private var pendingDescriptorBlob: Data?
    @State private var showNameSheet = false

    var body: some View {
        ZStack {
            CameraPreviewView(
                session: cameraService.session,
                isSessionRunning: cameraService.isSessionRunning
            )
            .ignoresSafeArea()

            // Top banner
            VStack {
                Text(viewModel.prompt)
                    .font(.headline)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 20)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                Spacer()
                HStack {
                    Button("Cancel", action: onCancel)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                    Spacer()
                    Text(captureService.statusMessage)
                        .foregroundStyle(.white)
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.black.opacity(0.5), in: Capsule())
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            // Lock progress ring, centred
            Circle()
                .stroke(.white.opacity(0.4), lineWidth: 4)
                .frame(width: 120, height: 120)
                .overlay(
                    Circle()
                        .trim(from: 0, to: captureService.lockProgress)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                )
                .animation(.linear(duration: 0.1), value: captureService.lockProgress)
        }
        .task {
            await cameraService.start()
        }
        .onReceive(cameraService.framePublisher) { sampleBuffer in
            captureService.ingest(sampleBuffer: sampleBuffer)
        }
        .onChange(of: captureService.captured) { _, new in
            guard let descriptor = new else { return }
            do {
                pendingDescriptorBlob = try JSONEncoder().encode(descriptor)
                showNameSheet = true
            } catch {
                captureService.reset()
            }
        }
        .sheet(isPresented: $showNameSheet) {
            NavigationStack {
                Form {
                    Section("Name") {
                        TextField("Player name", text: $pendingName)
                            .textInputAutocapitalization(.words)
                    }
                }
                .navigationTitle("Confirm player")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Retake") {
                            pendingName = ""
                            pendingDescriptorBlob = nil
                            showNameSheet = false
                            captureService.reset()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm") {
                            if let blob = pendingDescriptorBlob, !pendingName.isEmpty {
                                viewModel.confirmPlayer(name: pendingName, descriptor: blob)
                            }
                            pendingName = ""
                            pendingDescriptorBlob = nil
                            showNameSheet = false
                            captureService.reset()
                            if viewModel.isComplete {
                                onComplete(viewModel.pendingPlayers)
                            }
                        }
                        .disabled(pendingName.isEmpty)
                    }
                }
            }
        }
    }
}
```

Note: `CameraPreviewView` and `CameraService.framePublisher` are the existing API used by `LiveSessionView`. If the signatures differ in this codebase, adapt the binding but not the structure. Check `HoopTrack/Views/Components/CameraPreviewView.swift` or similar for the actual signature before writing this task.

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Game/GameRegistrationView.swift
git commit -m "feat(game): GameRegistrationView — landscape camera + lock ring + name sheet"
```

---

### Task 16: TeamAssignmentView

**Files:**
- Create: `HoopTrack/Views/Game/TeamAssignmentView.swift`

- [ ] **Step 1: Create the view**

```swift
// TeamAssignmentView.swift
// Tap-to-toggle team chips for the pending roster. Drag-and-drop was
// considered but tap is simpler, matches the rest of the app, and works
// with VoiceOver for free.

import SwiftUI

struct TeamAssignmentView: View {
    let players: [GameRegistrationViewModel.PendingPlayer]
    let onConfirm: (_ assignments: [UUID: TeamAssignment]) -> Void
    let onBack: () -> Void

    @State private var assignments: [UUID: TeamAssignment] = [:]

    var body: some View {
        VStack(spacing: 20) {
            Text("Assign teams")
                .font(.title2.bold())

            HStack(spacing: 12) {
                teamColumn(.teamA, "Team A", .orange)
                teamColumn(.teamB, "Team B", .blue)
            }

            Button {
                onConfirm(assignments)
            } label: {
                Text(readyToConfirm ? "Start game" : "Assign all \(players.count) players")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(readyToConfirm ? Color.orange : Color.secondary.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .disabled(!readyToConfirm)
            .padding(.horizontal)

            Button("Back", action: onBack)
                .foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            // Default: alternate teams for convenience
            for (i, p) in players.enumerated() {
                assignments[p.id] = (i % 2 == 0) ? .teamA : .teamB
            }
        }
    }

    private var readyToConfirm: Bool {
        assignments.count == players.count
    }

    @ViewBuilder
    private func teamColumn(_ team: TeamAssignment, _ name: String, _ colour: Color) -> some View {
        VStack(spacing: 8) {
            Text(name).font(.headline).foregroundStyle(colour)
            ForEach(players) { p in
                let assigned = assignments[p.id]
                if assigned == team {
                    Button {
                        let other: TeamAssignment = (team == .teamA) ? .teamB : .teamA
                        assignments[p.id] = other
                    } label: {
                        Text(p.name)
                            .font(.subheadline.bold())
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(colour.opacity(0.2), in: Capsule())
                    }
                }
            }
            if players.filter({ assignments[$0.id] == team }).isEmpty {
                Text("No players yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
        .background(colour.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Game/TeamAssignmentView.swift
git commit -m "feat(game): TeamAssignmentView — tap-toggle between Team A/B"
```

---

### Task 17: LiveGameView shell + GameSummaryView stub

**Files:**
- Create: `HoopTrack/Views/Game/LiveGameView.swift`
- Create: `HoopTrack/Views/Game/GameSummaryView.swift`

- [ ] **Step 1: Create LiveGameView shell**

```swift
// LiveGameView.swift
// SP1: camera-free shell that shows the scoreboard and manual make/miss
// buttons. SP2 replaces the manual buttons with CV attribution and adds
// the killfeed + player overlays.

import SwiftUI

struct LiveGameView: View {
    @ObservedObject var viewModel: GameSessionViewModel
    let onEndGame: () -> Void

    @State private var selectedShooter: GamePlayer?

    var body: some View {
        VStack(spacing: 20) {
            scoreboard

            playerPicker

            HStack(spacing: 12) {
                manualShotButton(.miss, label: "Miss", colour: .red)
                manualShotButton(.make, label: "2PT", colour: .green, shotType: .twoPoint)
                manualShotButton(.make, label: "3PT", colour: .orange, shotType: .threePoint)
            }

            Spacer()

            Button {
                viewModel.endSession()
                onEndGame()
            } label: {
                Text("End game")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        }
        .padding()
        .onAppear {
            selectedShooter = viewModel.session.players.first
        }
    }

    // MARK: - Subviews

    private var scoreboard: some View {
        HStack {
            VStack {
                Text("TEAM A").font(.caption).foregroundStyle(.orange)
                Text("\(viewModel.session.teamAScore)").font(.system(size: 48, weight: .black))
            }
            Spacer()
            Text("—").font(.largeTitle)
            Spacer()
            VStack {
                Text("TEAM B").font(.caption).foregroundStyle(.blue)
                Text("\(viewModel.session.teamBScore)").font(.system(size: 48, weight: .black))
            }
        }
        .padding(.horizontal)
    }

    private var playerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shooter").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(viewModel.session.players) { player in
                        Button {
                            selectedShooter = player
                        } label: {
                            Text(player.name)
                                .font(.subheadline.bold())
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(
                                    selectedShooter?.id == player.id
                                        ? Color.orange.opacity(0.4)
                                        : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                        }
                    }
                }
            }
        }
    }

    private func manualShotButton(
        _ result: ShotResult,
        label: String,
        colour: Color,
        shotType: ShotType = .twoPoint
    ) -> some View {
        Button {
            guard let shooter = selectedShooter else { return }
            // Court position: manual logging is court-agnostic in SP1 — centre of half-court.
            viewModel.logShot(
                shooter: shooter,
                result: result,
                courtX: 0.5, courtY: 0.5,
                shotType: shotType
            )
        } label: {
            Text(label)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(colour, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .disabled(selectedShooter == nil)
    }
}
```

- [ ] **Step 2: Create GameSummaryView stub**

```swift
// GameSummaryView.swift
// SP1: just final team scores + player list + duration. SP2 replaces
// this with the full box score.

import SwiftUI

struct GameSummaryView: View {
    let session: GameSession
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        teamBlock(name: "Team A", score: session.teamAScore, colour: .orange)
                        Text("vs").font(.title2).foregroundStyle(.secondary)
                        teamBlock(name: "Team B", score: session.teamBScore, colour: .blue)
                    }

                    Label(session.durationSeconds.formatted(.number.precision(.fractionLength(0))) + " sec",
                          systemImage: "clock")
                        .font(.subheadline).foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Players").font(.headline)
                        ForEach(session.players) { p in
                            HStack {
                                Text(p.name)
                                Spacer()
                                Text(p.teamAssignment.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .navigationTitle("Game summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone).bold().tint(.orange)
                }
            }
        }
    }

    private func teamBlock(name: String, score: Int, colour: Color) -> some View {
        VStack {
            Text(name).font(.caption).foregroundStyle(colour)
            Text("\(score)").font(.system(size: 48, weight: .black, design: .rounded))
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(colour.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Game/LiveGameView.swift HoopTrack/HoopTrack/Views/Game/GameSummaryView.swift
git commit -m "feat(game): LiveGameView shell + GameSummaryView stub"
```

---

### Task 18: TrainTabView entry + Progress tab integration

**Files:**
- Modify: `HoopTrack/Views/Train/TrainTabView.swift`
- Modify: `HoopTrack/Views/Progress/ProgressTabView.swift`
- Create: `HoopTrack/Views/Game/GameEntryCard.swift`

- [ ] **Step 1: Create the Game entry card**

```swift
// GameEntryCard.swift
// Top-of-Train-tab promotional card for Game Mode. Kept as its own file so
// its layout can evolve without touching the drill grid below it.

import SwiftUI

struct GameEntryCard: View {
    let onStart: (GameFormat, GameType) -> Void
    @State private var showSheet = false
    @State private var selectedFormat: GameFormat = .twoOnTwo

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(.orange, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pickup Game").font(.headline)
                    Text("2v2 or 3v3 with live scoring")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            NavigationStack {
                Form {
                    Section("Format") {
                        Picker("", selection: $selectedFormat) {
                            ForEach(GameFormat.allCases) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .navigationTitle("Start pickup game")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showSheet = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue") {
                            showSheet = false
                            onStart(selectedFormat, .pickup)
                        }.bold()
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}
```

- [ ] **Step 2: Add GameEntryCard to TrainTabView**

Open `HoopTrack/Views/Train/TrainTabView.swift`. At the top of the main `VStack` (before the existing drill grid), insert:

```swift
GameEntryCard { format, gameType in
    // Route via the existing AppState / AppRoute mechanism your TrainTabView already uses.
    // Example (adapt to the existing navigation pattern in this file):
    appState.push(.gameConsent(format: format, gameType: gameType))
}
.padding(.horizontal)
.padding(.top, 4)
```

Note: inspect `TrainTabView` for how it navigates to `LiveSessionView` today (likely via `NavigationStack`, `fullScreenCover`, or `appState.push`). Match that pattern. If routing is via a `@State var route: AppRoute?`, set it here instead of calling `appState.push`.

- [ ] **Step 3: Add game-session rendering to ProgressTabView**

Open `HoopTrack/Views/Progress/ProgressTabView.swift`. Find the existing session history list. Extend the fetch to also include `GameSession` and render game cards with a distinct visual style — e.g.:

```swift
@Query(sort: \GameSession.startTimestamp, order: .reverse) private var games: [GameSession]
```

Then in the list body, alongside the existing `TrainingSession` rows, render:

```swift
ForEach(games) { g in
    HStack {
        Image(systemName: "person.2.fill")
            .foregroundStyle(.orange)
            .frame(width: 32, height: 32)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        VStack(alignment: .leading) {
            Text("\(g.gameType.rawValue) · \(g.gameFormat.displayName)")
                .font(.subheadline.bold())
            Text("\(g.teamAScore) – \(g.teamBScore)")
                .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(g.startTimestamp, style: .date)
            .font(.caption).foregroundStyle(.tertiary)
    }
    .padding(.vertical, 8)
}
```

Adjust integration (`List` vs `LazyVStack`, spacing, card styling) to match the existing file's conventions.

- [ ] **Step 4: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Game/GameEntryCard.swift \
        HoopTrack/HoopTrack/Views/Train/TrainTabView.swift \
        HoopTrack/HoopTrack/Views/Progress/ProgressTabView.swift
git commit -m "feat(game): Train-tab GameEntryCard + Progress-tab game session rendering"
```

---

### Task 19: PrivacyInfo.xcprivacy — declare appearance capture

**Files:**
- Modify: `HoopTrack/PrivacyInfo.xcprivacy`

- [ ] **Step 1: Open the privacy manifest in Xcode or a plist editor**

Xcode renders `.xcprivacy` as a structured plist — editing it as text is fine too. Find the `NSPrivacyCollectedDataTypes` array.

- [ ] **Step 2: Add a new collected-data entry for appearance embeddings**

Append a dictionary to `NSPrivacyCollectedDataTypes` (adjust XML indentation to match surrounding entries):

```xml
<dict>
    <key>NSPrivacyCollectedDataType</key>
    <string>NSPrivacyCollectedDataTypeOtherDiagnosticData</string>
    <key>NSPrivacyCollectedDataTypeLinked</key>
    <false/>
    <key>NSPrivacyCollectedDataTypeTracking</key>
    <false/>
    <key>NSPrivacyCollectedDataTypePurposes</key>
    <array>
        <string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
    </array>
</dict>
```

Apple doesn't have a dedicated "appearance descriptor" category. `OtherDiagnosticData` with `Linked=false` and `Tracking=false` is the closest honest match, since the data is session-scoped, never uploaded, and used solely for in-app functionality.

- [ ] **Step 3: Build**

Run: `xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/PrivacyInfo.xcprivacy
git commit -m "chore(privacy): declare appearance descriptor capture in PrivacyInfo.xcprivacy"
```

---

### Task 20: End-to-end manual verification

**Files:** none (manual QA)

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -quiet 2>&1 | grep -E "(Test Suite 'All tests'|failed|passed at)" | tail -5`
Expected: `Test Suite 'All tests' passed` + zero failures

- [ ] **Step 2: Install on a physical device and walk the happy path**

Open Xcode, select your iPhone, run the app. Verify in order:

1. Train tab → "Pickup Game" card is visible at the top, above the drill grid
2. Tapping it shows the format picker sheet (2v2 / 3v3)
3. Continue → GameConsentView appears; "I understand" proceeds
4. Camera preview opens in landscape; banner says "Player 1 of 4 — step in front of the camera."
5. Standing ~6-8 feet from the camera for 3 seconds causes the lock ring to complete and the name-entry sheet appears
6. Enter a name + tap Confirm → banner updates to "Player 2 of 4"
7. Repeat until all 4 players registered
8. TeamAssignmentView appears in portrait; default alternates A/B/A/B; tap a chip to flip
9. "Start game" → LiveGameView shows scoreboard at 0–0, player picker, make/miss/2PT/3PT buttons
10. Tap a player, tap 3PT → their team score increments by 3 (Team A 3–0 or Team B 0–3)
11. Tap 2PT and miss in various combinations
12. Tap "End game" → GameSummaryView shows final scores, player list, duration
13. Tap Done → returns to the Train tab
14. Progress tab → the finished game appears in the history list with the distinct card style

- [ ] **Step 3: Verify no regressions in existing flows**

1. Start a regular solo Free Shoot session — should work exactly as before
2. Existing training-session history still appears in the Progress tab
3. Sign out + back in — no crashes (validates additive SwiftData migration)

- [ ] **Step 4: Finalise the branch with `superpowers:finishing-a-development-branch`**

Follow the finishing-a-development-branch skill to verify tests, update `docs/ROADMAP.md` to mark SP1 complete + add the Game Mode parallel track, then merge.

---

## Notes for the Implementer

- **Landscape handling.** `GameRegistrationView` needs landscape. The existing app uses `LandscapeHostingController` — check `LiveSessionView`'s setup for the exact pattern (force-landscape via an AppDelegate flag, landscape hosting controller, or a `.supportedInterfaceOrientations` override). Apply the same pattern to `GameRegistrationView`.
- **Camera availability.** The simulator has no camera. For step-2 of Task 20, test registration on a real device only; iPhone 14 simulator will show an empty preview.
- **CameraService API.** This plan assumes `CameraService` exposes `start()`, `session` (AVCaptureSession), and `framePublisher` (a `Combine` publisher of `CMSampleBuffer`). If the real API differs, adapt `GameRegistrationView` to match — the shape of the view otherwise stays the same.
- **`DataService.modelContext`.** Task 13 assumes you can reach `modelContext` from `GameSessionViewModel`. Whether that's via a public property, a helper method, or passing `ModelContext` in alongside `DataService`, pick the path that fits the existing style in `DataService.swift`.
- **Testing note.** `AppearanceExtractionTests` uses Vision-free coordinate math only. Real-frame testing of `AppearanceCaptureService` is manual QA only — it depends on live camera input.

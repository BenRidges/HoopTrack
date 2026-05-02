# SP4 Live Commentary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an event-driven, pre-recorded audio commentary track that reacts to in-session events (makes, misses, streaks, clutch, game outcomes) with selectable personalities (Hype Man + Broadcast at launch).

**Architecture:** Producers publish typed `CommentaryEvent` values onto a single `CommentaryEventBus` Combine subject. A `@MainActor CommentaryService` subscribes, runs each event through a pure `PacingQueue` (back-pressure / priority drop) then a pure `ClipSelector` (event-tag + intensity filter + anti-repetition), and plays the chosen file via `AVAudioPlayer`. Pure logic is fully unit-tested; the audio layer is a thin shell.

**Tech Stack:** Swift 6, SwiftUI, Combine, AVFoundation (`AVAudioSession`, `AVAudioPlayer`), SwiftData (3 additive `PlayerProfile` fields).

**Spec:** [`docs/superpowers/specs/2026-04-19-game-commentary-design.md`](../specs/2026-04-19-game-commentary-design.md)

---

## File Structure

**New files:**
- `HoopTrack/Models/CommentaryEvent.swift` — `enum CommentaryEvent` + `ShotContext` payload
- `HoopTrack/Models/CommentaryClipManifest.swift` — `Codable` manifest + `Clip` entry
- `HoopTrack/Services/CommentaryEventBus.swift` — `PassthroughSubject` wrapper
- `HoopTrack/Utilities/PacingQueue.swift` — pure priority queue / back-pressure logic
- `HoopTrack/Utilities/ClipSelector.swift` — pure clip-picking function
- `HoopTrack/Services/CommentaryService.swift` — `@MainActor`, owns audio player + manifest
- `HoopTrack/Views/Profile/CommentarySettingsView.swift` — settings UI
- `HoopTrack/Audio/Commentary/hype_man/manifest.json` — placeholder for asset pipeline
- `HoopTrack/Audio/Commentary/broadcast/manifest.json` — placeholder for asset pipeline
- `HoopTrackTests/PacingQueueTests.swift`
- `HoopTrackTests/ClipSelectorTests.swift`
- `HoopTrackTests/CommentaryEventBusTests.swift`
- `HoopTrackTests/CommentaryClipManifestTests.swift`

**Modified files:**
- `HoopTrack/Models/PlayerProfile.swift` — add 3 fields (additive SwiftData migration)
- `HoopTrack/Sync/DTOs/PlayerProfileDTO.swift` — sync the 3 new fields
- `HoopTrack/Utilities/Constants.swift` — new `HoopTrack.Commentary` enum
- `HoopTrack/CoordinatorHost.swift` (or `HoopTrackApp`) — instantiate `CommentaryService` and inject as `@EnvironmentObject`
- `HoopTrack/HoopTrackApp.swift` — register `CommentaryService` in environment
- `HoopTrack/Services/SessionFinalizationCoordinator.swift` — publish `sessionEnd`, `personalBest`
- `HoopTrack/ViewModels/LiveSessionViewModel.swift` — publish `sessionStart`, `shotMade`, `shotMissed`, `streak`
- `HoopTrack/Views/Profile/ProfileTabView.swift` — link to `CommentarySettingsView`

---

## Task 1: Constants

**Files:**
- Modify: `HoopTrack/Utilities/Constants.swift`

- [ ] **Step 1: Add `Commentary` enum to `HoopTrack` namespace**

```swift
enum Commentary {
    static let minGapBetweenClipsSec: Double = 2.0
    static let antiRepetitionWindow: Int = 15
    static let pacingQueueMax: Int = 3
    static let maxQueueAgeSec: Double = 5.0
    static let defaultVolume: Double = 0.7
    static let clipCooldownSec: Double = 30.0
    static let defaultPersonality: String = "hype_man"
    static let availablePersonalities: [String] = ["hype_man", "broadcast"]
}
```

- [ ] **Step 2: Build to confirm namespace compiles**

Run: `xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack build -destination 'platform=iOS Simulator,name=iPhone 14'`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/Utilities/Constants.swift
git commit -m "SP4 Task 1: add Commentary constants namespace"
```

---

## Task 2: `CommentaryEvent` model + `ShotContext`

**Files:**
- Create: `HoopTrack/Models/CommentaryEvent.swift`

- [ ] **Step 1: Create the file**

```swift
// CommentaryEvent.swift
// SP4 — typed event taxonomy published onto CommentaryEventBus.

import Foundation

enum CommentaryEvent: Equatable {
    // Solo + game shared
    case sessionStart(drillType: DrillType?)
    case sessionEnd(makes: Int, attempts: Int)
    case shotMade(context: ShotContext)
    case shotMissed(context: ShotContext)
    case streak(count: Int, playerName: String?)
    case coldStreak(count: Int, playerName: String?)
    case personalBest(stat: String, value: String)

    // Game mode (SP1+)
    case clutchMake(context: ShotContext)
    case gameWinner(playerName: String?, teamScore: Int)
    case hotPlayer(name: String, makesInRow: Int)
    case leadChange(newLeader: TeamAssignment, scoreA: Int, scoreB: Int)
    case blowout(leader: TeamAssignment, differential: Int)

    // Playoff (SP3)
    case playoffAdvance(round: PlayoffRound)
    case playoffElimination(round: PlayoffRound)
}

struct ShotContext: Equatable {
    let result: ShotResult
    let zone: CourtZone
    let isThreePoint: Bool
    let intensity: Int            // 1...5
}

extension CommentaryEvent {
    /// Priority used when the queue overflows. Higher wins.
    var priority: Int {
        switch self {
        case .gameWinner, .playoffAdvance, .playoffElimination: return 100
        case .clutchMake:                                       return 80
        case .personalBest:                                     return 70
        case .leadChange, .blowout, .hotPlayer:                 return 60
        case .streak, .coldStreak:                              return 50
        case .shotMade:                                         return 30
        case .shotMissed:                                       return 20
        case .sessionStart, .sessionEnd:                        return 10
        }
    }

    /// Manifest-event tag this event maps to. Single source of truth — used by ClipSelector.
    var manifestTag: String {
        switch self {
        case .sessionStart:          return "session_start"
        case .sessionEnd:            return "session_end"
        case .shotMade:              return "shot_made"
        case .shotMissed:            return "shot_missed"
        case .streak:                return "streak"
        case .coldStreak:            return "cold_streak"
        case .personalBest:          return "personal_best"
        case .clutchMake:            return "clutch_make"
        case .gameWinner:            return "game_winner"
        case .hotPlayer:             return "hot_player"
        case .leadChange:            return "lead_change"
        case .blowout:               return "blowout"
        case .playoffAdvance:        return "playoff_advance"
        case .playoffElimination:    return "playoff_elimination"
        }
    }

    /// Intensity on the 1...5 scale. Most events carry it on a payload; the rest pick a default.
    var intensity: Int {
        switch self {
        case .shotMade(let c), .shotMissed(let c), .clutchMake(let c):
            return c.intensity
        case .gameWinner, .playoffAdvance:                      return 5
        case .playoffElimination, .blowout:                     return 4
        case .streak(let n, _), .coldStreak(let n, _):          return min(5, max(2, n - 1))
        case .personalBest, .leadChange, .hotPlayer:            return 4
        case .sessionStart, .sessionEnd:                        return 2
        }
    }
}
```

> **Note:** `PlayoffRound` ships with SP3. If SP4 ships before SP3, gate the two playoff cases behind `#if false` or stub the enum locally — but in the planned sequencing (SP1 → SP2 ∥ SP4 → SP3), SP4 lands first and we need the cases declared. Add a temporary `enum PlayoffRound { case quarterfinal, semifinal, final }` in this same file under a `// TODO: replaced by SP3` comment — SP3 will delete the stub when it ships its real enum.

- [ ] **Step 2: Add the `PlayoffRound` stub at the bottom of the file** (delete in SP3 Task 1)

```swift
// TODO(SP3): delete this stub — replaced by real PlayoffRound in PlayoffSeries.swift
enum PlayoffRound: String, Codable, CaseIterable {
    case quarterfinal, semifinal, final
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack build -destination 'platform=iOS Simulator,name=iPhone 14'`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Models/CommentaryEvent.swift
git commit -m "SP4 Task 2: add CommentaryEvent + ShotContext"
```

---

## Task 3: `CommentaryClipManifest` Codable model

**Files:**
- Create: `HoopTrack/Models/CommentaryClipManifest.swift`
- Test: `HoopTrackTests/CommentaryClipManifestTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
@testable import HoopTrack

final class CommentaryClipManifestTests: XCTestCase {

    func test_decode_minimalManifest() throws {
        let json = """
        {
          "personality": "hype_man",
          "version": 1,
          "clips": [
            {
              "id": "hype_001",
              "file": "shot_made/001.m4a",
              "event": "shot_made",
              "intensity_min": 2,
              "intensity_max": 5,
              "duration": 1.8,
              "tags": ["make", "3pt"],
              "transcript": "Boom!"
            }
          ]
        }
        """.data(using: .utf8)!

        let manifest = try JSONDecoder().decode(CommentaryClipManifest.self, from: json)
        XCTAssertEqual(manifest.personality, "hype_man")
        XCTAssertEqual(manifest.clips.count, 1)
        XCTAssertEqual(manifest.clips[0].id, "hype_001")
        XCTAssertEqual(manifest.clips[0].event, "shot_made")
        XCTAssertEqual(manifest.clips[0].intensityRange, 2...5)
        XCTAssertEqual(manifest.clips[0].tags, ["make", "3pt"])
    }
}
```

- [ ] **Step 2: Run — expect failure (`CommentaryClipManifest` not found)**

Run: `xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 14' -only-testing:HoopTrackTests/CommentaryClipManifestTests`
Expected: compile failure

- [ ] **Step 3: Implement the model**

```swift
// CommentaryClipManifest.swift
// SP4 — Codable description of a personality's clip library.
// One manifest.json per personality folder under HoopTrack/Audio/Commentary/.

import Foundation

struct CommentaryClipManifest: Codable, Equatable {
    let personality: String
    let version: Int
    let clips: [Clip]

    struct Clip: Codable, Equatable {
        let id: String
        let file: String
        let event: String
        let intensityMin: Int
        let intensityMax: Int
        let duration: Double
        let tags: [String]
        let transcript: String?

        var intensityRange: ClosedRange<Int> { intensityMin...intensityMax }

        enum CodingKeys: String, CodingKey {
            case id, file, event, duration, tags, transcript
            case intensityMin = "intensity_min"
            case intensityMax = "intensity_max"
        }
    }
}
```

- [ ] **Step 4: Re-run test — expect pass**

Expected: test passes

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Models/CommentaryClipManifest.swift HoopTrackTests/CommentaryClipManifestTests.swift
git commit -m "SP4 Task 3: add CommentaryClipManifest Codable model + decode test"
```

---

## Task 4: `PacingQueue` pure logic (TDD)

**Files:**
- Create: `HoopTrack/Utilities/PacingQueue.swift`
- Test: `HoopTrackTests/PacingQueueTests.swift`

The queue is a value-type state machine: events go in with a timestamp; `dequeueNext(now:)` returns the next event to play (respecting min-gap + age cutoff + priority drop). Pure — no audio, no Combine.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import HoopTrack

final class PacingQueueTests: XCTestCase {

    private func ctx(_ intensity: Int) -> ShotContext {
        ShotContext(result: .make, zone: .midRange, isThreePoint: false, intensity: intensity)
    }

    func test_emptyQueue_returnsNil() {
        var q = PacingQueue()
        XCTAssertNil(q.dequeueNext(now: 0))
    }

    func test_enqueueAndDequeue_sameEvent() {
        var q = PacingQueue()
        q.enqueue(.shotMade(context: ctx(3)), at: 1.0)
        let popped = q.dequeueNext(now: 1.0)
        XCTAssertNotNil(popped)
        XCTAssertNil(q.dequeueNext(now: 1.0))
    }

    func test_minGap_blocksSecondClipUntilGapElapses() {
        var q = PacingQueue()
        q.enqueue(.shotMade(context: ctx(3)), at: 0.0)
        _ = q.dequeueNext(now: 0.0)                          // play first, lastPlayedAt = 0.0
        q.enqueue(.shotMade(context: ctx(3)), at: 1.0)
        XCTAssertNil(q.dequeueNext(now: 1.0))                // still under 2s gap
        XCTAssertNotNil(q.dequeueNext(now: 2.5))             // gap satisfied
    }

    func test_overflow_dropsLowestPriority() {
        var q = PacingQueue(maxSize: 3)
        q.enqueue(.sessionStart(drillType: nil), at: 0.0)        // pri 10
        q.enqueue(.shotMissed(context: ctx(2)), at: 0.1)         // pri 20
        q.enqueue(.shotMade(context: ctx(3)), at: 0.2)           // pri 30
        q.enqueue(.gameWinner(playerName: nil, teamScore: 21), at: 0.3) // pri 100
        XCTAssertEqual(q.count, 3)
        let first = q.dequeueNext(now: 10.0)
        guard case .gameWinner = first else {
            return XCTFail("expected gameWinner highest priority, got \(String(describing: first))")
        }
    }

    func test_staleEvents_areDropped() {
        var q = PacingQueue()
        q.enqueue(.shotMade(context: ctx(2)), at: 0.0)
        // now = 0.0 + maxQueueAgeSec + 0.1 → stale
        let result = q.dequeueNext(now: HoopTrack.Commentary.maxQueueAgeSec + 0.1)
        XCTAssertNil(result)
    }

    func test_higherPriorityJumpsAhead_evenIfQueuedLater() {
        var q = PacingQueue()
        q.enqueue(.shotMade(context: ctx(3)), at: 0.0)            // pri 30
        q.enqueue(.gameWinner(playerName: nil, teamScore: 21), at: 0.1) // pri 100
        let popped = q.dequeueNext(now: 5.0)
        if case .gameWinner = popped {} else { XCTFail("expected gameWinner first") }
    }
}
```

- [ ] **Step 2: Run — expect failure**

Run: `xcodebuild test ... -only-testing:HoopTrackTests/PacingQueueTests`
Expected: compile failure

- [ ] **Step 3: Implement `PacingQueue`**

```swift
// PacingQueue.swift
// SP4 — pure value-type pacing/priority logic for commentary.
// Holds events with arrival timestamps. dequeueNext(now:) returns the next
// event to play, respecting min-gap, max-age, and priority-on-overflow.

import Foundation

struct PacingQueue {

    struct Entry {
        let event: CommentaryEvent
        let arrivedAt: Double           // seconds (caller's clock; tests pass synthetic values)
    }

    private(set) var entries: [Entry] = []
    private var lastPlayedAt: Double?

    let maxSize: Int
    let minGapSec: Double
    let maxAgeSec: Double

    init(maxSize: Int = HoopTrack.Commentary.pacingQueueMax,
         minGapSec: Double = HoopTrack.Commentary.minGapBetweenClipsSec,
         maxAgeSec: Double = HoopTrack.Commentary.maxQueueAgeSec) {
        self.maxSize = maxSize
        self.minGapSec = minGapSec
        self.maxAgeSec = maxAgeSec
    }

    var count: Int { entries.count }

    mutating func enqueue(_ event: CommentaryEvent, at arrivedAt: Double) {
        entries.append(Entry(event: event, arrivedAt: arrivedAt))
        if entries.count > maxSize {
            // Drop the lowest-priority entry (ties: oldest wins, drop newest tied)
            if let dropIdx = entries.indices.min(by: { lhs, rhs in
                let lp = entries[lhs].event.priority
                let rp = entries[rhs].event.priority
                if lp != rp { return lp < rp }
                return entries[lhs].arrivedAt > entries[rhs].arrivedAt   // drop newer on tie
            }) {
                entries.remove(at: dropIdx)
            }
        }
    }

    /// Returns the next event to play, or nil if none is eligible right now.
    mutating func dequeueNext(now: Double) -> CommentaryEvent? {
        // 1. Drop stale entries
        entries.removeAll { now - $0.arrivedAt > maxAgeSec }

        // 2. Respect min gap from the previous played clip
        if let last = lastPlayedAt, now - last < minGapSec { return nil }

        // 3. Pick the highest priority. Ties: earliest arrival wins.
        guard let idx = entries.indices.max(by: { lhs, rhs in
            let lp = entries[lhs].event.priority
            let rp = entries[rhs].event.priority
            if lp != rp { return lp < rp }
            return entries[lhs].arrivedAt > entries[rhs].arrivedAt
        }) else { return nil }

        let popped = entries.remove(at: idx)
        lastPlayedAt = now
        return popped.event
    }
}
```

- [ ] **Step 4: Re-run tests — all pass**

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Utilities/PacingQueue.swift HoopTrackTests/PacingQueueTests.swift
git commit -m "SP4 Task 4: add PacingQueue with priority/age/min-gap logic"
```

---

## Task 5: `ClipSelector` pure logic (TDD)

**Files:**
- Create: `HoopTrack/Utilities/ClipSelector.swift`
- Test: `HoopTrackTests/ClipSelectorTests.swift`

Pure: given (manifest, event, recentlyPlayed), return a clip ID or nil.

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import HoopTrack

final class ClipSelectorTests: XCTestCase {

    private typealias Clip = CommentaryClipManifest.Clip

    private func clip(id: String, event: String = "shot_made",
                      intensity: ClosedRange<Int> = 1...5,
                      tags: [String] = []) -> Clip {
        Clip(id: id, file: "\(id).m4a", event: event,
             intensityMin: intensity.lowerBound, intensityMax: intensity.upperBound,
             duration: 1.5, tags: tags, transcript: nil)
    }

    private func manifest(_ clips: [Clip]) -> CommentaryClipManifest {
        CommentaryClipManifest(personality: "test", version: 1, clips: clips)
    }

    private func ctx(_ intensity: Int) -> ShotContext {
        ShotContext(result: .make, zone: .midRange, isThreePoint: false, intensity: intensity)
    }

    func test_emptyManifest_returnsNil() {
        let pick = ClipSelector.pick(manifest: manifest([]),
                                     event: .shotMade(context: ctx(3)),
                                     recentlyPlayed: [],
                                     rng: { _ in 0 })
        XCTAssertNil(pick)
    }

    func test_filtersByEventTag() {
        let m = manifest([
            clip(id: "make_a", event: "shot_made"),
            clip(id: "miss_a", event: "shot_missed")
        ])
        let pick = ClipSelector.pick(manifest: m,
                                     event: .shotMade(context: ctx(3)),
                                     recentlyPlayed: [],
                                     rng: { _ in 0 })
        XCTAssertEqual(pick, "make_a")
    }

    func test_filtersByIntensityWindow() {
        let m = manifest([
            clip(id: "low",  intensity: 1...2),
            clip(id: "mid",  intensity: 3...4),
            clip(id: "high", intensity: 5...5)
        ])
        let pick = ClipSelector.pick(manifest: m,
                                     event: .shotMade(context: ctx(5)),
                                     recentlyPlayed: [],
                                     rng: { _ in 0 })
        XCTAssertEqual(pick, "high")
    }

    func test_excludesRecentlyPlayed_whenAlternativesExist() {
        let m = manifest([clip(id: "a"), clip(id: "b"), clip(id: "c")])
        // rng returns 0 → would pick first remaining after filter
        let pick = ClipSelector.pick(manifest: m,
                                     event: .shotMade(context: ctx(3)),
                                     recentlyPlayed: ["a"],
                                     rng: { _ in 0 })
        XCTAssertNotEqual(pick, "a")
        XCTAssertNotNil(pick)
    }

    func test_relaxesAntiRepetition_whenAllExcluded() {
        let m = manifest([clip(id: "a"), clip(id: "b")])
        let pick = ClipSelector.pick(manifest: m,
                                     event: .shotMade(context: ctx(3)),
                                     recentlyPlayed: ["a", "b"],
                                     rng: { _ in 0 })
        // Should still return one (we relaxed the filter)
        XCTAssertNotNil(pick)
    }

    func test_rngControlsRandomPick() {
        let m = manifest([clip(id: "a"), clip(id: "b"), clip(id: "c")])
        let pick0 = ClipSelector.pick(manifest: m, event: .shotMade(context: ctx(3)),
                                      recentlyPlayed: [], rng: { _ in 0 })
        let pick2 = ClipSelector.pick(manifest: m, event: .shotMade(context: ctx(3)),
                                      recentlyPlayed: [], rng: { _ in 2 })
        XCTAssertEqual(pick0, "a")
        XCTAssertEqual(pick2, "c")
    }
}
```

- [ ] **Step 2: Run tests — expect failure**

- [ ] **Step 3: Implement**

```swift
// ClipSelector.swift
// SP4 — pure clip-selection function. No side effects, no audio.
// rng is injectable for deterministic testing.

import Foundation

enum ClipSelector {

    /// Returns a clip ID to play, or nil if the manifest has nothing for the given event.
    /// - Parameters:
    ///   - manifest: personality's clip library
    ///   - event: the event being announced
    ///   - recentlyPlayed: ordered set of clip IDs played in the last N selections
    ///   - rng: returns an Int in [0, upper). Default uses Swift's standard RNG.
    static func pick(
        manifest: CommentaryClipManifest,
        event: CommentaryEvent,
        recentlyPlayed: [String],
        rng: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> String? {
        let tag = event.manifestTag
        let intensity = event.intensity

        // 1. Tag + intensity-window filter
        let matching = manifest.clips.filter {
            $0.event == tag && $0.intensityRange.contains(intensity)
        }
        guard !matching.isEmpty else { return nil }

        // 2. Anti-repetition filter — relax if it empties the set
        let recent = Set(recentlyPlayed)
        let filtered = matching.filter { !recent.contains($0.id) }
        let pool = filtered.isEmpty ? matching : filtered

        // 3. Random pick from pool using injected RNG
        let idx = rng(pool.count)
        return pool[idx].id
    }
}
```

- [ ] **Step 4: Re-run tests — pass**

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Utilities/ClipSelector.swift HoopTrackTests/ClipSelectorTests.swift
git commit -m "SP4 Task 5: add ClipSelector pure picker with anti-repetition"
```

---

## Task 6: `CommentaryEventBus` Combine subject

**Files:**
- Create: `HoopTrack/Services/CommentaryEventBus.swift`
- Test: `HoopTrackTests/CommentaryEventBusTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import Combine
@testable import HoopTrack

final class CommentaryEventBusTests: XCTestCase {

    func test_publish_deliversToSubscribers() {
        let bus = CommentaryEventBus()
        var received: [CommentaryEvent] = []
        let cancellable = bus.events.sink { received.append($0) }

        bus.publish(.sessionStart(drillType: nil))
        bus.publish(.shotMade(context: ShotContext(result: .make, zone: .midRange,
                                                    isThreePoint: false, intensity: 3)))

        XCTAssertEqual(received.count, 2)
        cancellable.cancel()
    }
}
```

- [ ] **Step 2: Run — expect failure**

- [ ] **Step 3: Implement**

```swift
// CommentaryEventBus.swift
// SP4 — single global Combine subject for typed commentary events.
// Producers publish; CommentaryService subscribes. Decouples every subsystem
// (LiveSessionVM, GameVM, PlayoffVM, FinalizationCoordinator) from audio code.

import Foundation
import Combine

@MainActor
final class CommentaryEventBus: ObservableObject {

    private let subject = PassthroughSubject<CommentaryEvent, Never>()

    var events: AnyPublisher<CommentaryEvent, Never> {
        subject.eraseToAnyPublisher()
    }

    func publish(_ event: CommentaryEvent) {
        subject.send(event)
    }
}
```

- [ ] **Step 4: Test passes; commit**

```bash
git add HoopTrack/Services/CommentaryEventBus.swift HoopTrackTests/CommentaryEventBusTests.swift
git commit -m "SP4 Task 6: add CommentaryEventBus Combine subject"
```

---

## Task 7: `PlayerProfile` additive fields (commentary settings)

**Files:**
- Modify: `HoopTrack/Models/PlayerProfile.swift`
- Modify: `HoopTrack/Sync/DTOs/PlayerProfileDTO.swift`

Additive SwiftData migration: just add fields with defaults — no migration plan needed (per CLAUDE.md convention).

- [ ] **Step 1: Add fields to `PlayerProfile`**

In the `// MARK: - Settings` section, after `videosAutoDeleteDays`:

```swift
    // MARK: - Commentary (SP4)
    var commentaryEnabled: Bool
    var commentaryPersonality: String
    var commentaryVolume: Double
```

In `init`, after `self.videosAutoDeleteDays = ...`:

```swift
        self.commentaryEnabled     = true
        self.commentaryPersonality = HoopTrack.Commentary.defaultPersonality
        self.commentaryVolume      = HoopTrack.Commentary.defaultVolume
```

- [ ] **Step 2: Update `PlayerProfileDTO`**

Open `HoopTrack/Sync/DTOs/PlayerProfileDTO.swift`. Add the 3 fields with snake_case CodingKeys (`commentary_enabled`, `commentary_personality`, `commentary_volume`). Update both `init(from profile: PlayerProfile)` and `apply(to profile:)` paths.

> **Note for the engineer:** the DTO follows the same shape as the other 5 DTOs — open one (e.g. `TrainingSessionDTO.swift`) for reference if unsure about CodingKey + init pattern.

- [ ] **Step 3: Build**

Run: `xcodebuild ... build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Add a Supabase column migration note in `docs/production-readiness.md` under a new "SP4 commentary" subsection**

Body: "Add `commentary_enabled bool default true`, `commentary_personality text default 'hype_man'`, `commentary_volume float8 default 0.7` to `player_profiles` table before SP4 deploys to TestFlight."

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Models/PlayerProfile.swift HoopTrack/Sync/DTOs/PlayerProfileDTO.swift docs/production-readiness.md
git commit -m "SP4 Task 7: add commentary settings to PlayerProfile + DTO"
```

---

## Task 8: `CommentaryService` — manifest loading

**Files:**
- Create: `HoopTrack/Services/CommentaryService.swift`

Load the JSON manifest from the bundle for the current personality. Audio playback added in Task 9.

- [ ] **Step 1: Stub the service with manifest loading**

```swift
// CommentaryService.swift
// SP4 — owns personality manifest, audio engine, and the
// PacingQueue / ClipSelector loop. Subscribes to CommentaryEventBus.

import Foundation
import Combine
import AVFoundation
import os

@MainActor
final class CommentaryService: ObservableObject {

    private static let log = Logger(subsystem: "com.edgesemantics.hooptrack", category: "Commentary")

    // MARK: - Configurable state
    @Published private(set) var currentPersonality: String
    @Published var enabled: Bool
    @Published var volume: Double

    // MARK: - Internals
    private let bus: CommentaryEventBus
    private var cancellables: Set<AnyCancellable> = []
    private var manifest: CommentaryClipManifest?
    private var queue = PacingQueue()
    private var recentlyPlayed: [String] = []                 // ring buffer of recent IDs
    private var player: AVAudioPlayer?

    init(bus: CommentaryEventBus,
         personality: String = HoopTrack.Commentary.defaultPersonality,
         enabled: Bool = true,
         volume: Double = HoopTrack.Commentary.defaultVolume) {
        self.bus = bus
        self.currentPersonality = personality
        self.enabled = enabled
        self.volume = volume
        loadManifest(for: personality)
        subscribe()
    }

    // MARK: - Personality

    func setPersonality(_ name: String) {
        guard name != currentPersonality else { return }
        currentPersonality = name
        loadManifest(for: name)
    }

    private func loadManifest(for personality: String) {
        guard let url = Bundle.main.url(forResource: "manifest",
                                        withExtension: "json",
                                        subdirectory: "Audio/Commentary/\(personality)") else {
            Self.log.warning("No manifest.json for personality \(personality, privacy: .public)")
            manifest = nil
            return
        }
        do {
            let data = try Data(contentsOf: url)
            manifest = try JSONDecoder().decode(CommentaryClipManifest.self, from: data)
            Self.log.info("Loaded \(self.manifest?.clips.count ?? 0) clips for \(personality, privacy: .public)")
        } catch {
            Self.log.error("Failed to decode \(personality, privacy: .public) manifest: \(error.localizedDescription, privacy: .public)")
            manifest = nil
        }
    }

    // MARK: - Subscription

    private func subscribe() {
        bus.events
            .sink { [weak self] event in self?.handle(event) }
            .store(in: &cancellables)
    }

    private func handle(_ event: CommentaryEvent) {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        queue.enqueue(event, at: now)
        drain(now: now)
    }

    private func drain(now: Double) {
        guard let next = queue.dequeueNext(now: now) else { return }
        play(next)
    }

    // Stubbed in Task 9.
    private func play(_ event: CommentaryEvent) {
        guard let manifest else { return }
        guard let id = ClipSelector.pick(
            manifest: manifest,
            event: event,
            recentlyPlayed: recentlyPlayed
        ) else { return }
        Self.log.debug("Would play clip \(id, privacy: .public)")
        // Audio playback wired in Task 9.
        appendRecentlyPlayed(id)
    }

    private func appendRecentlyPlayed(_ id: String) {
        recentlyPlayed.append(id)
        if recentlyPlayed.count > HoopTrack.Commentary.antiRepetitionWindow {
            recentlyPlayed.removeFirst(recentlyPlayed.count - HoopTrack.Commentary.antiRepetitionWindow)
        }
    }
}
```

- [ ] **Step 2: Build**

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/Services/CommentaryService.swift
git commit -m "SP4 Task 8: scaffold CommentaryService with manifest loading + queue"
```

---

## Task 9: `CommentaryService` — audio playback

**Files:**
- Modify: `HoopTrack/Services/CommentaryService.swift`

- [ ] **Step 1: Configure AVAudioSession in `init`**

Add at the end of `init`:

```swift
        configureAudioSession()
```

And add the helper:

```swift
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers, .duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.log.error("AVAudioSession failed: \(error.localizedDescription, privacy: .public)")
        }
    }
```

- [ ] **Step 2: Implement real `play` body**

Replace the stub `play(_:)` with:

```swift
    private func play(_ event: CommentaryEvent) {
        guard let manifest else { return }
        guard let id = ClipSelector.pick(
            manifest: manifest,
            event: event,
            recentlyPlayed: recentlyPlayed
        ) else { return }
        guard let clip = manifest.clips.first(where: { $0.id == id }) else { return }

        let folder = "Audio/Commentary/\(currentPersonality)"
        // clip.file is a relative path like "shot_made/001.m4a"
        let parts = clip.file.split(separator: "/", omittingEmptySubsequences: true)
        guard let fileName = parts.last else { return }
        let subPath = parts.dropLast().joined(separator: "/")
        let resourceName = (fileName as NSString).deletingPathExtension
        let resourceExt  = (fileName as NSString).pathExtension
        let bundleSub    = subPath.isEmpty ? folder : "\(folder)/\(subPath)"

        guard let url = Bundle.main.url(forResource: resourceName,
                                        withExtension: resourceExt,
                                        subdirectory: bundleSub) else {
            Self.log.warning("Clip file not found: \(clip.file, privacy: .public)")
            return
        }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = Float(volume)
            p.prepareToPlay()
            p.play()
            self.player = p
            appendRecentlyPlayed(id)
        } catch {
            Self.log.error("AVAudioPlayer failed for \(clip.file, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
```

- [ ] **Step 3: Build**

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Services/CommentaryService.swift
git commit -m "SP4 Task 9: add AVAudioPlayer-backed playback in CommentaryService"
```

---

## Task 10: Wire `CommentaryEventBus` + `CommentaryService` into the app

**Files:**
- Modify: `HoopTrack/CoordinatorHost.swift`
- Modify: `HoopTrack/HoopTrackApp.swift` (or wherever environment objects are injected at root)

The bus is process-wide; the service subscribes and is held by the host.

- [ ] **Step 1: Add bus + service to `CoordinatorBox`**

In `CoordinatorHost.swift`, in `CoordinatorBox`:

```swift
    private(set) var commentaryBus: CommentaryEventBus?
    private(set) var commentaryService: CommentaryService?
```

In `build(modelContext:notificationService:)`, after the existing telemetry setup:

```swift
        let bus = CommentaryEventBus()
        commentaryBus = bus
        let profile = (try? ds.fetchOrCreateProfile())
        let svc = CommentaryService(
            bus: bus,
            personality: profile?.commentaryPersonality ?? HoopTrack.Commentary.defaultPersonality,
            enabled: profile?.commentaryEnabled ?? true,
            volume: profile?.commentaryVolume ?? HoopTrack.Commentary.defaultVolume
        )
        commentaryService = svc
```

- [ ] **Step 2: Inject into the view tree**

In `CoordinatorHost.body`'s `if let coordinator = ... { ContentView()...` branch, add:

```swift
                    .environmentObject(bus)              // commentaryBus
                    .environmentObject(commentaryService) // CommentaryService
```

(Use `if let bus = box.commentaryBus, let cs = box.commentaryService` guards as needed to match the existing optional-unwrap pattern.)

- [ ] **Step 3: Build + run on simulator; confirm no crash on launch**

Run: `xcodebuild ... build`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/CoordinatorHost.swift
git commit -m "SP4 Task 10: wire CommentaryEventBus + Service into CoordinatorHost"
```

---

## Task 11: Producers — `LiveSessionViewModel` publishes shot events

**Files:**
- Modify: `HoopTrack/ViewModels/LiveSessionViewModel.swift`

> **Note:** `LiveSessionViewModel` should accept a `CommentaryEventBus?` (optional so existing tests/initializers don't break). Inject from `LiveSessionView` via `@EnvironmentObject`.

- [ ] **Step 1: Add bus parameter to the VM init**

```swift
    private let commentaryBus: CommentaryEventBus?

    init(/* ... existing ..., */ commentaryBus: CommentaryEventBus? = nil) {
        // ... existing ...
        self.commentaryBus = commentaryBus
    }
```

- [ ] **Step 2: Publish on `sessionStart`** — wherever the VM transitions to `.recording` (or similar). Add:

```swift
    commentaryBus?.publish(.sessionStart(drillType: drillType))
```

- [ ] **Step 3: Publish on `shotMade` / `shotMissed`** — in the shot-resolution path:

```swift
    let ctx = ShotContext(result: shot.result,
                          zone: shot.zone ?? .midRange,
                          isThreePoint: shot.isThreePoint,
                          intensity: 3)            // solo default; game mode overrides via SP2
    commentaryBus?.publish(shot.result == .make
                           ? .shotMade(context: ctx)
                           : .shotMissed(context: ctx))
```

- [ ] **Step 4: Publish streak events** when `consecutiveMakes >= 3`:

```swift
    if consecutiveMakes >= 3 {
        commentaryBus?.publish(.streak(count: consecutiveMakes, playerName: nil))
    }
```

- [ ] **Step 5: In `LiveSessionView`, read the bus from environment and pass into the VM init.** (Pattern matches how `dataService` is injected today.)

- [ ] **Step 6: Build**

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add HoopTrack/ViewModels/LiveSessionViewModel.swift HoopTrack/Views/Train/LiveSessionView.swift
git commit -m "SP4 Task 11: publish shot/streak events from LiveSessionViewModel"
```

---

## Task 12: Producer — `SessionFinalizationCoordinator` publishes `sessionEnd` + `personalBest`

**Files:**
- Modify: `HoopTrack/Services/SessionFinalizationCoordinator.swift`

- [ ] **Step 1: Add an optional `CommentaryEventBus` to the coordinator init** (matches existing optional-injection pattern for `syncCoordinator` / `telemetry*`)

```swift
    private let commentaryBus: CommentaryEventBus?

    init(/* ... existing ..., */ commentaryBus: CommentaryEventBus? = nil) {
        // ...
        self.commentaryBus = commentaryBus
    }
```

- [ ] **Step 2: After step 7 in each `finalise*` method (right after `kickOffSync`), add:**

```swift
        commentaryBus?.publish(.sessionEnd(makes: session.shotsMade,
                                            attempts: session.shotsAttempted))
        if session.fgPercent > profile.prBestFGPercentSession {
            commentaryBus?.publish(.personalBest(stat: "Session FG%",
                                                  value: String(format: "%.0f%%", session.fgPercent)))
        }
```

- [ ] **Step 3: Pass the bus through `CoordinatorHost.build(...)` when constructing the coordinator**

```swift
        value = SessionFinalizationCoordinator(
            // ... existing args ...
            commentaryBus: bus
        )
```

- [ ] **Step 4: Build**

Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Services/SessionFinalizationCoordinator.swift HoopTrack/CoordinatorHost.swift
git commit -m "SP4 Task 12: publish sessionEnd + personalBest from finalization"
```

---

## Task 13: `CommentarySettingsView`

**Files:**
- Create: `HoopTrack/Views/Profile/CommentarySettingsView.swift`
- Modify: `HoopTrack/Views/Profile/ProfileTabView.swift`

- [ ] **Step 1: Create the view**

```swift
// CommentarySettingsView.swift
// SP4 — Profile-tab settings for commentary track.

import SwiftUI
import SwiftData

struct CommentarySettingsView: View {
    @EnvironmentObject private var commentary: CommentaryService
    @EnvironmentObject private var dataService: DataService

    @State private var profile: PlayerProfile?

    var body: some View {
        Form {
            Section {
                Toggle("Enable commentary", isOn: bindingEnabled)
            } footer: {
                Text("Plays a reactive commentary track during sessions.")
            }

            if commentary.enabled {
                Section("Personality") {
                    Picker("Voice", selection: bindingPersonality) {
                        ForEach(HoopTrack.Commentary.availablePersonalities, id: \.self) { name in
                            Text(displayName(name)).tag(name)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Volume") {
                    Slider(value: bindingVolume, in: 0...1)
                    HStack {
                        Text("0%").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(commentary.volume * 100))%").font(.caption2)
                        Spacer()
                        Text("100%").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Play sample") {
                        commentary.playSample()
                    }
                }
            }
        }
        .navigationTitle("Commentary")
        .task {
            profile = try? dataService.fetchOrCreateProfile()
        }
    }

    // MARK: - Bindings that mirror service state into PlayerProfile.

    private var bindingEnabled: Binding<Bool> {
        Binding(
            get: { commentary.enabled },
            set: { newValue in
                commentary.enabled = newValue
                profile?.commentaryEnabled = newValue
                try? dataService.saveProfile()
            }
        )
    }

    private var bindingPersonality: Binding<String> {
        Binding(
            get: { commentary.currentPersonality },
            set: { newValue in
                commentary.setPersonality(newValue)
                profile?.commentaryPersonality = newValue
                try? dataService.saveProfile()
            }
        )
    }

    private var bindingVolume: Binding<Double> {
        Binding(
            get: { commentary.volume },
            set: { newValue in
                commentary.volume = newValue
                profile?.commentaryVolume = newValue
                try? dataService.saveProfile()
            }
        )
    }

    private func displayName(_ key: String) -> String {
        switch key {
        case "hype_man":  return "Hype Man"
        case "broadcast": return "Broadcast"
        case "analyst":   return "Analyst"
        default:          return key.capitalized
        }
    }
}
```

- [ ] **Step 2: Add `playSample()` to `CommentaryService`**

```swift
    /// Triggers a representative `shotMade` clip for UI preview.
    func playSample() {
        let ctx = ShotContext(result: .make, zone: .midRange,
                              isThreePoint: false, intensity: 3)
        handle(.shotMade(context: ctx))
    }
```

- [ ] **Step 3: Confirm `dataService.saveProfile()` exists**

If it doesn't, use `try? dataService.modelContext.save()` directly. Match whatever existing settings views (e.g. video retention toggle) use today.

- [ ] **Step 4: Add a `NavigationLink` to `CommentarySettingsView` from `ProfileTabView`**

In `ProfileTabView`, alongside the existing settings rows:

```swift
    NavigationLink("Commentary") { CommentarySettingsView() }
```

- [ ] **Step 5: Build**

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add HoopTrack/Views/Profile/CommentarySettingsView.swift HoopTrack/Views/Profile/ProfileTabView.swift HoopTrack/Services/CommentaryService.swift
git commit -m "SP4 Task 13: add CommentarySettingsView and playSample()"
```

---

## Task 14: Stub asset bundle (manifests + placeholder clips)

**Files:**
- Create: `HoopTrack/Audio/Commentary/hype_man/manifest.json`
- Create: `HoopTrack/Audio/Commentary/broadcast/manifest.json`

Real audio clips ship via the separate `hooptrack-audio/` repo (out of scope for this code plan — see spec §10). For SP4 to build + boot, we need at least empty manifests so `CommentaryService` doesn't log "No manifest.json".

- [ ] **Step 1: Create `hype_man/manifest.json`**

```json
{
  "personality": "hype_man",
  "version": 0,
  "clips": []
}
```

- [ ] **Step 2: Create `broadcast/manifest.json`** (same content, `"personality": "broadcast"`).

- [ ] **Step 3: Add the `Audio` folder reference to the Xcode project** as a **folder reference (blue)**, NOT a group, so the directory layout is preserved at runtime for `Bundle.main.url(forResource:withExtension:subdirectory:)` lookups.

> **CRITICAL:** Folder references vs groups are easy to confuse. Right-click the `HoopTrack` group in Xcode → "Add Files to 'HoopTrack'..." → select the `Audio` folder → choose **"Create folder references"** (blue folder icon). Confirm Target Membership: HoopTrack.

- [ ] **Step 4: Build, run on simulator, open Profile → Commentary**

Toggle should be functional but no audio (empty manifests = no clips to pick). Confirm no crash.

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Audio HoopTrack.xcodeproj/project.pbxproj
git commit -m "SP4 Task 14: add empty placeholder manifests for hype_man + broadcast"
```

---

## Task 15: End-to-end smoke test on simulator

This task is manual — verify on a simulator before merging.

- [ ] **Step 1: Run all tests**

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14'
```

Expected: all tests pass (existing 209 + ~15 new across PacingQueue / ClipSelector / Manifest / EventBus tests).

- [ ] **Step 2: Manual flow on simulator**

1. Launch app, complete sign-in flow.
2. Profile tab → Commentary → toggle on, pick "Hype Man", volume 70%, tap "Play sample" — expect a log line "Would play clip" or "Clip file not found" (because manifest is empty). No crash.
3. Start a Free Shoot session, fire a few shots manually (or in a debug build, manually publish events). Expect log lines from `CommentaryService` for `sessionStart`, `shotMade`, `shotMissed`.
4. Toggle commentary off, replay → expect zero log lines from the service.

- [ ] **Step 3: Run security review on the diff**

```bash
git diff origin/main..HEAD --name-only
```

Dispatch a single `swift-security-reviewer` subagent against the file list. Fix any CRITICAL/HIGH findings.

- [ ] **Step 4: Use `superpowers:finishing-a-development-branch` skill to merge**

---

## Notes for the engineer

- **Audio assets aren't shipped here.** SP4 produces the *engine*; clip libraries are produced in a sibling content pipeline (see spec §10). The manifests are intentionally empty so this branch builds and ships safely without 200+ audio files. Once clips arrive, dropping them into `HoopTrack/Audio/Commentary/<personality>/` and updating `manifest.json` is the only change needed.
- **Producers are `optional`-injected.** Every place that publishes accepts `CommentaryEventBus?` so unit tests don't need to wire the bus. Pattern matches `syncCoordinator` / `telemetry*` from Phase 9 and CV-A.
- **Pure logic is heavily tested** (PacingQueue + ClipSelector). The service shell deliberately stays thin so we don't try to mock `AVAudioPlayer` in tests.
- **Concurrency:** all classes are `@MainActor` (Swift 6 default for this project). No `DispatchQueue.main.async`; use `Task { @MainActor in }` if you ever need to defer.
- **`PlayoffRound` stub** in `CommentaryEvent.swift` is to be removed by SP3 Task 1, which introduces the real `PlayoffSeries` enum.

---

## Self-Review (post-write)

- ✅ Spec coverage: §3 events, §4 personality system (manifest), §5 selection (PacingQueue + ClipSelector), §7 settings UI, §8 files touched, §9 constants — all covered. §6 dynamic slots / Analyst is explicitly deferred (per spec §4.1).
- ✅ No placeholders: all code is concrete; the only "stubs" are intentionally-empty asset manifests (Task 14) and the temporary `PlayoffRound` (documented in Task 2 step 2).
- ✅ Type consistency: `ShotContext`, `CommentaryEvent`, `CommentaryClipManifest.Clip`, `PacingQueue`, `ClipSelector` signatures referenced consistently across tasks.
- ⚠️ Open question: `dataService.saveProfile()` — Task 13 step 3 flags that engineer must confirm against existing pattern; not a blocker.

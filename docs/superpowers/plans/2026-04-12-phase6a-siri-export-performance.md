# Phase 6A — Siri Shortcuts, Data Export & Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Siri Shortcuts for voice-activated session launching and stat querying, JSON data export via the share sheet, and targeted performance improvements (MetricKit, autoreleasepool, DataService query optimisation).

**Architecture:** App Intents are self-contained files registered via a single `AppShortcutsProvider`. URL scheme routing uses a new `AppState` observable injected at the root. `ExportService` is a pure transform + file-writer with no UI coupling. Performance fixes are surgical: one autoreleasepool in `CameraService`, one query optimisation in `ProgressViewModel` via a new `DataService` method, and MetricKit wired at app launch.

**Tech Stack:** App Intents framework (iOS 16+), `@MainActor` Swift 6, SwiftData `FetchDescriptor`, `MetricKit (MXMetricManager)`, `ShareLink`, `autoreleasepool`

**Working directory:** `/Users/benridges/Documents/projects/HoopTrack/.claude/worktrees/phase6a-impl/HoopTrack`

**Build command:**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

**Test command:**
```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(Test Case.*passed|Test Case.*failed|error:|BUILD FAILED)"
```

---

## File Map

### New Files
| File | Purpose |
|---|---|
| `HoopTrack/Utilities/AppState.swift` | Published `selectedTab` + `handleDeepLink(_:)` |
| `HoopTrack/Info.plist` | URL scheme (`hooptrack://`) declaration |
| `HoopTrack/AppIntents/StartFreeShootSessionIntent.swift` | ForegroundContinuableIntent → `hooptrack://train/freeshoot` |
| `HoopTrack/AppIntents/ShowMyStatsIntent.swift` | ForegroundContinuableIntent → `hooptrack://progress` |
| `HoopTrack/AppIntents/ShotsTodayIntent.swift` | Background intent — spoken shot count |
| `HoopTrack/AppIntents/HoopTrackShortcuts.swift` | `AppShortcutsProvider` — single registration point |
| `HoopTrack/Models/Export/SessionExportRecord.swift` | Codable session export struct |
| `HoopTrack/Models/Export/ShotExportRecord.swift` | Codable shot export struct |
| `HoopTrack/Services/ExportService.swift` | JSON transform + temp-file writer |
| `HoopTrack/Services/MetricsService.swift` | MXMetricManager subscriber |
| `../HoopTrackTests/DataServiceExportTests.swift` | Tests for `fetchShotsTodayCount` + `fetchSessions(since:)` |
| `../HoopTrackTests/ExportServiceTests.swift` | Tests for `ExportService.exportJSON(for:)` |
| `../docs/performance-report.md` | Instruments audit findings before fixes |

### Modified Files
| File | Change |
|---|---|
| `HoopTrack/HoopTrackApp.swift` | Inject `AppState`; `.onOpenURL` handler; register `MetricsService` |
| `HoopTrack/ContentView.swift` | Bind `TabView` to `appState.selectedTab` |
| `HoopTrack/HoopTrack.xcodeproj/project.pbxproj` | Add `INFOPLIST_FILE` for app target |
| `HoopTrack/Services/DataService.swift` | Add `fetchShotsTodayCount()` + `fetchSessions(since:limit:)` |
| `HoopTrack/ViewModels/ProgressViewModel.swift` | Use `fetchSessions(since:)` instead of unbounded fetch |
| `HoopTrack/Views/Profile/ProfileTabView.swift` | Replace CSV export with JSON via `ExportService` |
| `HoopTrack/Services/CameraService.swift` | Wrap `frameSubject.send` in `autoreleasepool` |

---

## Task 1: AppState — Deep Link Navigation State

**Files:**
- Create: `HoopTrack/HoopTrack/Utilities/AppState.swift`
- Modify: `HoopTrack/HoopTrack/ContentView.swift`
- Modify: `HoopTrack/HoopTrack/HoopTrackApp.swift`

- [ ] **Step 1: Create `AppState.swift`**

```swift
// AppState.swift
// Shared navigation state. Injected at root; lets HoopTrackApp route deep
// links to the correct tab without coupling ContentView to URL parsing.

import SwiftUI

@MainActor
final class AppState: ObservableObject {

    @Published var selectedTab: AppTab = .home

    // MARK: - Deep Link Routing

    /// Handles `hooptrack://` URLs from Siri Shortcuts and notification taps.
    /// Add new routes here as the app grows — no other file needs to change.
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "hooptrack" else { return }
        switch url.host?.lowercased() {
        case "train":    selectedTab = .train
        case "progress": selectedTab = .progress
        case "profile":  selectedTab = .profile
        default:         break   // unknown host — stay on current tab
        }
    }
}
```

- [ ] **Step 2: Update `ContentView.swift` to bind `TabView` selection to `appState.selectedTab`**

Replace the existing `@State private var selectedTab: AppTab = .home` and `TabView(selection: $selectedTab)` with environment-object binding. The diff is small — only the state declaration and `TabView` line change:

```swift
// ContentView.swift
import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var appState: AppState  // ← add this

    var body: some View {
        TabView(selection: $appState.selectedTab) {    // ← was $selectedTab

            NavigationStack { HomeTabView() }
                .tabItem { Label("Home", systemImage: "house.fill") }
                .tag(AppTab.home)

            NavigationStack { TrainTabView() }
                .tabItem { Label("Train", systemImage: "basketball.fill") }
                .tag(AppTab.train)

            NavigationStack { ProgressTabView() }
                .tabItem { Label("Progress", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.progress)

            NavigationStack { ProfileTabView() }
                .tabItem { Label("Profile", systemImage: "person.fill") }
                .tag(AppTab.profile)
        }
        .tint(.orange)
    }
}

enum AppTab: Hashable {
    case home, train, progress, profile
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
```

- [ ] **Step 3: Update `HoopTrackApp.swift` — inject `AppState` and add `.onOpenURL`**

```swift
// HoopTrackApp.swift
import SwiftUI
import SwiftData

@main
struct HoopTrackApp: App {

    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: PlayerProfile.self, TrainingSession.self,
                     ShotRecord.self, GoalRecord.self, EarnedBadge.self,
                migrationPlan: HoopTrackMigrationPlan.self
            )
        } catch {
            fatalError("HoopTrack: Failed to create ModelContainer — \(error)")
        }
    }()

    @StateObject private var hapticService       = HapticService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var cameraService       = CameraService()
    @StateObject private var appState            = AppState()    // ← new

    var body: some Scene {
        WindowGroup {
            CoordinatorHost()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
                .environmentObject(appState)                    // ← new
                .onOpenURL { appState.handleDeepLink($0) }      // ← new
        }
    }
}
```

- [ ] **Step 4: Build and verify no errors**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Utilities/AppState.swift \
        HoopTrack/HoopTrack/ContentView.swift \
        HoopTrack/HoopTrack/HoopTrackApp.swift
git commit -m "feat(nav): add AppState + onOpenURL deep link routing"
```

---

## Task 2: URL Scheme — Register `hooptrack://`

**Files:**
- Create: `HoopTrack/HoopTrack/Info.plist`
- Modify: `HoopTrack/HoopTrack.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create `HoopTrack/HoopTrack/Info.plist`**

This minimal plist declares the `hooptrack://` URL scheme. Xcode 14+ merges it with the auto-generated plist (from `GENERATE_INFOPLIST_FILE = YES`) at build time — only new keys need to be listed here.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLName</key>
            <string>com.hooptrack.app</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>hooptrack</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Add `INFOPLIST_FILE` to the app target's build configurations in the xcodeproj**

The following Python script adds `INFOPLIST_FILE = "HoopTrack/Info.plist";` only to build configurations that already have `INFOPLIST_KEY_NSCameraUsageDescription` (i.e. the app target, not the test target):

```bash
python3 - <<'EOF'
import re

path = 'HoopTrack.xcodeproj/project.pbxproj'
with open(path, 'r') as f:
    content = f.read()

# Match GENERATE_INFOPLIST_FILE = YES; immediately followed (within a few lines)
# by INFOPLIST_KEY_NSCameraUsageDescription — this fingerprints the app target only.
content = re.sub(
    r'(GENERATE_INFOPLIST_FILE = YES;)(\s*\n\s*INFOPLIST_KEY_NSCameraUsageDescription)',
    r'\1\n\t\t\t\tINFOPLIST_FILE = "HoopTrack/Info.plist";\2',
    content
)

with open(path, 'w') as f:
    f.write(content)

print("Done — check that INFOPLIST_FILE appears exactly twice (Debug + Release).")
EOF
```

Verify the edit worked (should print 2 matches):

```bash
grep -c 'INFOPLIST_FILE = "HoopTrack/Info.plist"' HoopTrack.xcodeproj/project.pbxproj
```

Expected output: `2`

- [ ] **Step 3: Build to confirm URL scheme merges cleanly**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Info.plist \
        HoopTrack/HoopTrack.xcodeproj/project.pbxproj
git commit -m "feat(url-scheme): register hooptrack:// in Info.plist"
```

---

## Task 3: `StartFreeShootSessionIntent`

**Files:**
- Create: `HoopTrack/HoopTrack/AppIntents/StartFreeShootSessionIntent.swift`

- [ ] **Step 1: Create the intent file**

```swift
// StartFreeShootSessionIntent.swift
// Opens HoopTrack and navigates to a live free shoot session.
// ForegroundContinuableIntent pauses execution in Siri until the app
// is in the foreground, then fires the deep link.

import AppIntents
import UIKit

struct StartFreeShootSessionIntent: AppIntent, ForegroundContinuableIntent {

    static let title: LocalizedStringResource = "Start a free shoot session"
    static let description = IntentDescription(
        "Opens HoopTrack and starts a free shoot session.",
        categoryName: "Training"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try await requestToContinueInForeground()
        UIApplication.shared.open(URL(string: "hooptrack://train/freeshoot")!)
        return .result()
    }
}
```

- [ ] **Step 2: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/AppIntents/StartFreeShootSessionIntent.swift
git commit -m "feat(intents): add StartFreeShootSessionIntent"
```

---

## Task 4: `ShowMyStatsIntent`

**Files:**
- Create: `HoopTrack/HoopTrack/AppIntents/ShowMyStatsIntent.swift`

- [ ] **Step 1: Create the intent file**

```swift
// ShowMyStatsIntent.swift
// Opens HoopTrack and navigates to the Progress tab.

import AppIntents
import UIKit

struct ShowMyStatsIntent: AppIntent, ForegroundContinuableIntent {

    static let title: LocalizedStringResource = "Show my stats"
    static let description = IntentDescription(
        "Opens HoopTrack and shows your progress and stats.",
        categoryName: "Progress"
    )

    @MainActor
    func perform() async throws -> some IntentResult {
        try await requestToContinueInForeground()
        UIApplication.shared.open(URL(string: "hooptrack://progress")!)
        return .result()
    }
}
```

- [ ] **Step 2: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/AppIntents/ShowMyStatsIntent.swift
git commit -m "feat(intents): add ShowMyStatsIntent"
```

---

## Task 5: `ShotsTodayIntent` + `DataService.fetchShotsTodayCount`

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/DataService.swift`
- Create: `HoopTrack/HoopTrack/AppIntents/ShotsTodayIntent.swift`
- Create: `HoopTrackTests/DataServiceExportTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// HoopTrackTests/DataServiceExportTests.swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class DataServiceExportTests: XCTestCase {

    private var container: ModelContainer!
    private var sut: DataService!

    override func setUp() async throws {
        let schema = Schema([
            PlayerProfile.self, TrainingSession.self,
            ShotRecord.self, GoalRecord.self, EarnedBadge.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        sut = DataService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        container = nil
        sut = nil
    }

    func test_fetchShotsTodayCount_returnsZeroWhenNoSessions() throws {
        let count = try sut.fetchShotsTodayCount()
        XCTAssertEqual(count, 0)
    }

    func test_fetchShotsTodayCount_returnsCorrectShotTotal() throws {
        // Arrange
        let session = try sut.startSession(drillType: .freeShoot)
        _ = try sut.addShot(to: session, result: .make,
                            zone: .midRange, shotType: .jumpShot,
                            courtX: 0.5, courtY: 0.5)
        _ = try sut.addShot(to: session, result: .miss,
                            zone: .midRange, shotType: .jumpShot,
                            courtX: 0.4, courtY: 0.6)
        try sut.finaliseSession(session)

        // Act
        let count = try sut.fetchShotsTodayCount()

        // Assert
        XCTAssertEqual(count, 2)
    }
}
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HoopTrackTests/DataServiceExportTests \
  2>&1 | grep -E "(Test Case|error:|BUILD FAILED)"
```

Expected: build error — `'fetchShotsTodayCount' is not a member of 'DataService'`

- [ ] **Step 3: Add `fetchShotsTodayCount()` to `DataService.swift`**

Add the following method after the `fetchSessions(drillType:)` method (around line 50):

```swift
/// Total shots attempted across all sessions that started today.
/// Used by ShotsTodayIntent for the background spoken response.
func fetchShotsTodayCount() throws -> Int {
    let startOfDay = Calendar.current.startOfDay(for: .now)
    let predicate  = #Predicate<TrainingSession> { $0.startedAt >= startOfDay }
    let descriptor = FetchDescriptor(predicate: predicate)
    let todaySessions = try modelContext.fetch(descriptor)
    return todaySessions.reduce(0) { $0 + $1.shotsAttempted }
}
```

- [ ] **Step 4: Run test — expect PASS**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HoopTrackTests/DataServiceExportTests \
  2>&1 | grep -E "(Test Case|error:|BUILD FAILED)"
```

Expected:
```
Test Case '-[HoopTrackTests.DataServiceExportTests test_fetchShotsTodayCount_returnsZeroWhenNoSessions]' passed
Test Case '-[HoopTrackTests.DataServiceExportTests test_fetchShotsTodayCount_returnsCorrectShotTotal]' passed
```

- [ ] **Step 5: Create `ShotsTodayIntent.swift`**

```swift
// ShotsTodayIntent.swift
// Background intent — queries today's shot count and returns a spoken response.
// Does NOT require the app to be in the foreground.

import AppIntents
import SwiftData

@MainActor
struct ShotsTodayIntent: AppIntent {

    static let title: LocalizedStringResource = "How many shots today?"
    static let description = IntentDescription(
        "Tells you how many shots you've taken today.",
        categoryName: "Stats"
    )

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let container = try ModelContainer(
            for: PlayerProfile.self, TrainingSession.self,
                 ShotRecord.self, GoalRecord.self, EarnedBadge.self,
            migrationPlan: HoopTrackMigrationPlan.self
        )
        let dataService = DataService(modelContext: container.mainContext)
        let count       = try dataService.fetchShotsTodayCount()

        let response: String
        switch count {
        case 0:  response = "You haven't taken any shots today. Time to get on the court!"
        case 1:  response = "You've taken 1 shot today."
        default: response = "You've taken \(count) shots today."
        }
        return .result(value: response)
    }
}
```

- [ ] **Step 6: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add HoopTrack/HoopTrack/Services/DataService.swift \
        HoopTrack/HoopTrack/AppIntents/ShotsTodayIntent.swift \
        ../HoopTrackTests/DataServiceExportTests.swift
git commit -m "feat(intents): add ShotsTodayIntent + DataService.fetchShotsTodayCount"
```

---

## Task 6: `HoopTrackShortcuts` Provider

**Files:**
- Create: `HoopTrack/HoopTrack/AppIntents/HoopTrackShortcuts.swift`

- [ ] **Step 1: Create the shortcuts provider**

```swift
// HoopTrackShortcuts.swift
// Single registration point for all Siri Shortcuts.
// To add a new shortcut: create a new AppIntent file, then add one
// AppShortcut entry here. No other files need to change.

import AppIntents

struct HoopTrackShortcuts: AppShortcutsProvider {

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {

        AppShortcut(
            intent: StartFreeShootSessionIntent(),
            phrases: [
                "Start a free shoot session in \(.applicationName)",
                "Start shooting in \(.applicationName)",
                "Begin a shooting session in \(.applicationName)"
            ],
            shortTitle: "Free Shoot",
            systemImageName: "basketball.fill"
        )

        AppShortcut(
            intent: ShowMyStatsIntent(),
            phrases: [
                "Show my stats in \(.applicationName)",
                "Open my progress in \(.applicationName)",
                "My basketball stats in \(.applicationName)"
            ],
            shortTitle: "My Stats",
            systemImageName: "chart.line.uptrend.xyaxis"
        )

        AppShortcut(
            intent: ShotsTodayIntent(),
            phrases: [
                "How many shots today in \(.applicationName)",
                "Shots today in \(.applicationName)",
                "How many shots have I taken in \(.applicationName)"
            ],
            shortTitle: "Shots Today",
            systemImageName: "basketball"
        )
    }
}
```

- [ ] **Step 2: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrack/AppIntents/HoopTrackShortcuts.swift
git commit -m "feat(intents): add HoopTrackShortcuts provider — registers all 3 shortcuts"
```

---

## Task 7: `SessionExportRecord` + `ShotExportRecord`

**Files:**
- Create: `HoopTrack/HoopTrack/Models/Export/SessionExportRecord.swift`
- Create: `HoopTrack/HoopTrack/Models/Export/ShotExportRecord.swift`

- [ ] **Step 1: Create `ShotExportRecord.swift`**

```swift
// ShotExportRecord.swift
// Codable value type for shot-level export. Plain struct — not a SwiftData @Model.

import Foundation

struct ShotExportRecord: Codable {
    let zone: String                   // CourtZone.rawValue
    let made: Bool
    let releaseAngleDeg: Double?
    let releaseTimeMs: Double?
    let shotSpeedMph: Double?
    let courtX: Double
    let courtY: Double
}

extension ShotExportRecord {
    init(from record: ShotRecord) {
        self.zone             = record.zone.rawValue
        self.made             = record.result == .make
        self.releaseAngleDeg  = record.releaseAngleDeg
        self.releaseTimeMs    = record.releaseTimeMs
        self.shotSpeedMph     = record.shotSpeedMph
        self.courtX           = record.courtX
        self.courtY           = record.courtY
    }
}
```

- [ ] **Step 2: Create `SessionExportRecord.swift`**

```swift
// SessionExportRecord.swift
// Codable value type for session-level export. Plain struct — not a SwiftData @Model.

import Foundation

struct SessionExportRecord: Codable {
    let id: String                     // UUID string
    let date: Date
    let drillType: String              // DrillType.rawValue
    let durationSeconds: Double
    let fgPercent: Double
    let threePointPercent: Double?
    let shots: [ShotExportRecord]
}

extension SessionExportRecord {
    init(from session: TrainingSession) {
        self.id                 = session.id.uuidString
        self.date               = session.startedAt
        self.drillType          = session.drillType.rawValue
        self.durationSeconds    = session.durationSeconds
        self.fgPercent          = session.fgPercent / 100.0   // 0–1 range
        self.threePointPercent  = session.threePointPercentage.map { $0 / 100.0 }
        self.shots              = session.shots
            .filter { $0.result != .pending }
            .map    { ShotExportRecord(from: $0) }
    }
}
```

- [ ] **Step 3: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Models/Export/SessionExportRecord.swift \
        HoopTrack/HoopTrack/Models/Export/ShotExportRecord.swift
git commit -m "feat(export): add SessionExportRecord + ShotExportRecord Codable structs"
```

---

## Task 8: `ExportService` + Test

**Files:**
- Create: `HoopTrack/HoopTrack/Services/ExportService.swift`
- Create: `HoopTrackTests/ExportServiceTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// HoopTrackTests/ExportServiceTests.swift
import XCTest
import SwiftData
@testable import HoopTrack

@MainActor
final class ExportServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var dataService: DataService!

    override func setUp() async throws {
        let schema = Schema([
            PlayerProfile.self, TrainingSession.self,
            ShotRecord.self, GoalRecord.self, EarnedBadge.self
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        dataService = DataService(modelContext: container.mainContext)
    }

    override func tearDown() async throws {
        container = nil
        dataService = nil
    }

    func test_exportJSON_producesValidJSONWithCorrectShape() async throws {
        // Arrange
        let profile = try dataService.fetchOrCreateProfile()
        profile.name = "Test Player"
        let session = try dataService.startSession(drillType: .freeShoot)
        _ = try dataService.addShot(to: session, result: .make,
                                    zone: .midRange, shotType: .jumpShot,
                                    courtX: 0.5, courtY: 0.5)
        _ = try dataService.addShot(to: session, result: .miss,
                                    zone: .cornerThree, shotType: .jumpShot,
                                    courtX: 0.1, courtY: 0.1)
        try dataService.finaliseSession(session)

        let sut = ExportService()

        // Act
        let url = try await sut.exportJSON(for: profile)

        // Assert — valid JSON file was written
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["profileName"] as? String, "Test Player")
        XCTAssertNotNil(json["exportedAt"])

        let sessions = json["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 1)

        let shots = sessions?.first?["shots"] as? [[String: Any]]
        XCTAssertEqual(shots?.count, 2)

        let firstShot = shots?.first
        XCTAssertEqual(firstShot?["zone"] as? String, "midRange")
        XCTAssertEqual(firstShot?["made"] as? Bool, true)
    }

    func test_exportJSON_emptySessionListProducesValidJSON() async throws {
        let profile = try dataService.fetchOrCreateProfile()
        profile.name = "Empty Player"
        let sut = ExportService()

        let url = try await sut.exportJSON(for: profile)
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["profileName"] as? String, "Empty Player")
        let sessions = json["sessions"] as? [[String: Any]]
        XCTAssertEqual(sessions?.count, 0)
    }
}
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HoopTrackTests/ExportServiceTests \
  2>&1 | grep -E "(Test Case|error:|BUILD FAILED)"
```

Expected: build error — `cannot find type 'ExportService'`

- [ ] **Step 3: Create `ExportService.swift`**

```swift
// ExportService.swift
// Transforms SwiftData profile + sessions into JSON and writes to a temp file.
// Returns a URL that can be passed directly to ShareLink or UIActivityViewController.

import Foundation

/// Top-level export envelope — the JSON root object.
private struct ProfileExport: Codable {
    let exportedAt: Date
    let profileName: String
    let sessions: [SessionExportRecord]
}

@MainActor
final class ExportService {

    // MARK: - Public Interface

    /// Builds JSON from `profile` and writes it to a dated temp file.
    /// Deletes any previous export file for this profile before writing.
    /// - Returns: URL of the written file in the system temp directory.
    func exportJSON(for profile: PlayerProfile) async throws -> URL {
        let envelope = ProfileExport(
            exportedAt:  .now,
            profileName: profile.name.isEmpty ? "Player" : profile.name,
            sessions:    profile.sessions
                .filter { $0.isComplete }
                .sorted { $0.startedAt > $1.startedAt }
                .map    { SessionExportRecord(from: $0) }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)

        let fileName = "hooptrack-export-\(dateStamp()).json"
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Private Helpers

    private func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: .now)
    }
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HoopTrackTests/ExportServiceTests \
  2>&1 | grep -E "(Test Case|error:|BUILD FAILED)"
```

Expected:
```
Test Case '-[HoopTrackTests.ExportServiceTests test_exportJSON_producesValidJSONWithCorrectShape]' passed
Test Case '-[HoopTrackTests.ExportServiceTests test_exportJSON_emptySessionListProducesValidJSON]' passed
```

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Services/ExportService.swift \
        ../HoopTrackTests/ExportServiceTests.swift
git commit -m "feat(export): add ExportService + JSON export tests"
```

---

## Task 9: `ProfileTabView` — JSON Export Row

**Files:**
- Modify: `HoopTrack/HoopTrack/Views/Profile/ProfileTabView.swift`

The existing "Data" section has a CSV export using `ShareSheet`. This task replaces that with JSON export using `ExportService`.

- [ ] **Step 1: Replace CSV export state with JSON export state**

In `ProfileTabView`, remove:
```swift
@State private var isShowingExportSheet = false
@State private var exportCSV: String = ""
```
And add:
```swift
@State private var exportURL: URL?
@State private var isExporting = false
@State private var exportErrorMessage: String?
```

- [ ] **Step 2: Replace the "Data" section button**

Find the existing "Data" section:
```swift
// MARK: Data & Export
Section("Data") {
    Button {
        exportCSV       = viewModel.exportData()
        isShowingExportSheet = true
    } label: {
        Label("Export Session Data (CSV)", systemImage: "square.and.arrow.up")
            .foregroundStyle(.orange)
    }
}
```

Replace it with:
```swift
// MARK: Data & Export
Section("Data") {
    Button {
        guard !isExporting, let profile = viewModel.profile else { return }
        isExporting = true
        Task {
            do {
                exportURL   = try await ExportService().exportJSON(for: profile)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
            isExporting = false
        }
    } label: {
        HStack {
            Label("Export Data (JSON)", systemImage: "square.and.arrow.up")
                .foregroundStyle(.orange)
            if isExporting {
                Spacer()
                ProgressView()
                    .tint(.orange)
            }
        }
    }
    .disabled(isExporting)
}
```

- [ ] **Step 3: Replace the `.sheet` modifier**

Find:
```swift
.sheet(isPresented: $isShowingExportSheet) {
    ShareSheet(items: [exportCSV])
        .presentationDetents([.medium, .large])
}
```

Replace with:
```swift
.sheet(item: $exportURL) { url in
    ShareSheet(items: [url])
        .presentationDetents([.medium, .large])
}
.alert("Export Failed", isPresented: .constant(exportErrorMessage != nil)) {
    Button("OK") { exportErrorMessage = nil }
} message: {
    Text(exportErrorMessage ?? "")
}
```

Note: `URL` does not conform to `Identifiable` by default. Add this extension at the bottom of `ProfileTabView.swift` (or in a separate extensions file):

```swift
// MARK: - URL + Identifiable (for .sheet(item:))
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
```

- [ ] **Step 4: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Views/Profile/ProfileTabView.swift
git commit -m "feat(export): replace CSV export with JSON export in ProfileTabView"
```

---

## Task 10: `MetricsService` + App Registration

**Files:**
- Create: `HoopTrack/HoopTrack/Services/MetricsService.swift`
- Modify: `HoopTrack/HoopTrack/HoopTrackApp.swift`

- [ ] **Step 1: Create `MetricsService.swift`**

```swift
// MetricsService.swift
// Subscribes to MetricKit's daily payload delivery.
// Writes a human-readable summary to Documents/metrics.log on each delivery.
// Developer-facing only — no UI surface. Wired at app launch in HoopTrackApp.

import MetricKit
import Foundation

@MainActor
final class MetricsService: NSObject, ObservableObject {

    // MARK: - Registration

    func register() {
        MXMetricManager.shared.add(self)
    }

    // MARK: - Convenience

    private var logURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("metrics.log")
    }

    private func append(line: String) {
        let entry = "[\(ISO8601DateFormatter().string(from: .now))] \(line)\n"
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }
}

// MARK: - MXMetricManagerSubscriber

extension MetricsService: MXMetricManagerSubscriber {

    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let lines = summarise(payload)
            Task { @MainActor in
                lines.forEach { self.append(line: $0) }
            }
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            Task { @MainActor in
                self.append(line: "DIAGNOSTIC: \(payload.timeStampEnd)")
            }
        }
    }

    nonisolated private func summarise(_ payload: MXMetricPayload) -> [String] {
        var lines: [String] = []
        lines.append("=== MetricKit Payload \(payload.timeStampBegin) – \(payload.timeStampEnd) ===")

        if let cpu = payload.cpuMetrics {
            lines.append("CPU cumulative time: \(cpu.cumulativeCPUTime)")
        }
        if let mem = payload.memoryMetrics {
            lines.append("Memory peak: \(mem.peakMemoryUsage)")
        }
        if let launch = payload.applicationLaunchMetrics {
            lines.append("Time to first draw (cold): \(launch.histogrammedTimeToFirstDraw.bucketEnumerator.allObjects.first ?? "n/a")")
        }
        if let hang = payload.applicationResponsivenessMetrics {
            lines.append("Hang rate histogram: \(hang.histogrammedApplicationHangTime.totalBucketCount) buckets")
        }
        return lines
    }
}
```

- [ ] **Step 2: Register `MetricsService` in `HoopTrackApp.swift`**

Add `@StateObject private var metricsService = MetricsService()` and call `.register()` on launch.

Replace the `HoopTrackApp` body with:

```swift
@main
struct HoopTrackApp: App {

    let modelContainer: ModelContainer = {
        do {
            return try ModelContainer(
                for: PlayerProfile.self, TrainingSession.self,
                     ShotRecord.self, GoalRecord.self, EarnedBadge.self,
                migrationPlan: HoopTrackMigrationPlan.self
            )
        } catch {
            fatalError("HoopTrack: Failed to create ModelContainer — \(error)")
        }
    }()

    @StateObject private var hapticService       = HapticService()
    @StateObject private var notificationService = NotificationService()
    @StateObject private var cameraService       = CameraService()
    @StateObject private var appState            = AppState()
    @StateObject private var metricsService      = MetricsService()   // ← new

    var body: some Scene {
        WindowGroup {
            CoordinatorHost()
                .modelContainer(modelContainer)
                .environmentObject(hapticService)
                .environmentObject(notificationService)
                .environmentObject(cameraService)
                .environmentObject(appState)
                .onOpenURL { appState.handleDeepLink($0) }
                .task { metricsService.register() }                   // ← new
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Services/MetricsService.swift \
        HoopTrack/HoopTrack/HoopTrackApp.swift
git commit -m "feat(perf): add MetricsService — MetricKit subscriber wired at launch"
```

---

## Task 11: Performance Audit → `docs/performance-report.md`

Before applying fixes, document findings with file + line references so the before/after baseline is clear.

**Files:**
- Create: `docs/performance-report.md`

Read the following files in the worktree before writing the report:
- `HoopTrack/HoopTrack/Services/CameraService.swift`
- `HoopTrack/HoopTrack/Services/DataService.swift`
- `HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift`

- [ ] **Step 1: Write `docs/performance-report.md`**

The report must follow this exact structure. Fill in actual line numbers from the files you read:

```markdown
# HoopTrack Performance Audit Report

**Date:** 2026-04-12  
**Auditor:** Phase 6A implementation  
**Status:** Pre-fix baseline

---

## CVPipeline / CameraService

### Finding 1 — CVPixelBuffer not released promptly
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/Services/CameraService.swift:<line>`  
**Description:**  
`captureOutput(_:didOutput:from:)` calls `frameSubject.send(sampleBuffer)` without an `autoreleasepool`. The CMSampleBuffer (and its backing CVPixelBuffer) is Objective-C memory managed via autorelease. Without an explicit pool, the buffer is not released until the next run loop drain — potentially holding 2–3 live buffers at 60fps, adding ~10–15 MB peak memory overhead.

**Fix:** Wrap `frameSubject.send(sampleBuffer)` in `autoreleasepool { }`.

---

## DataService — Query Optimisation

### Finding 2 — Unbounded session fetch in ProgressViewModel
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift:<line>`  
**Description:**  
`ProgressViewModel.load()` calls `dataService.fetchSessions()` with no date predicate and no limit. This loads the entire session history into memory on every load and time-range change. For a user with 500+ sessions, this is a full table scan and unnecessary allocation.

**Fix:** Add `DataService.fetchSessions(since:limit:)` with a `FetchDescriptor` date predicate. `ProgressViewModel` should pass `selectedTimeRange`'s cutoff date so only in-range sessions are loaded.

---

## CameraService — Thread Safety Note

### Finding 3 — `DispatchQueue.main.async` in session configuration (Swift 6 lint)
**Severity:** Minor  
**File:** `HoopTrack/HoopTrack/Services/CameraService.swift:<line>`  
**Description:**  
`buildSession(mode:)` uses `DispatchQueue.main.async { self.error = .deviceUnavailable }` to set `@Published` state. Under strict Swift 6 concurrency, this should be `Task { @MainActor in self.error = .deviceUnavailable }`. The current form compiles under Swift 5 but will generate a warning under Swift 6 strict mode.

**Fix:** Defer to Swift 6 upgrade phase — does not affect runtime behaviour today.

---

## Summary

| # | Finding | Severity | Fix In |
|---|---|---|---|
| 1 | CVPixelBuffer autoreleasepool | Important | Task 13 |
| 2 | Unbounded session fetch | Important | Task 12 |
| 3 | DispatchQueue.main.async (Swift 6 lint) | Minor | Future Swift 6 upgrade |
```

- [ ] **Step 2: Commit**

```bash
git add docs/performance-report.md
git commit -m "docs: add performance audit report (pre-fix baseline)"
```

---

## Task 12: DataService — `fetchSessions(since:)` + ProgressViewModel

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/DataService.swift`
- Modify: `HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift`
- Modify: `HoopTrackTests/DataServiceExportTests.swift`

- [ ] **Step 1: Write failing test for `fetchSessions(since:)`**

Add these two test cases to `DataServiceExportTests.swift`:

```swift
func test_fetchSessionsSince_returnsOnlySessionsAfterCutoff() throws {
    // Arrange — create a session, then fabricate a "yesterday" check
    let session = try sut.startSession(drillType: .freeShoot)
    try sut.finaliseSession(session)
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now)!
    let futureDate = Calendar.current.date(byAdding: .day, value: +1, to: .now)!

    // Act
    let sinceYesterday = try sut.fetchSessions(since: yesterday)
    let sinceTomorrow  = try sut.fetchSessions(since: futureDate)

    // Assert
    XCTAssertEqual(sinceYesterday.count, 1)
    XCTAssertEqual(sinceTomorrow.count,  0)
}

func test_fetchSessionsSince_respectsLimit() throws {
    for _ in 0..<5 {
        let s = try sut.startSession(drillType: .freeShoot)
        try sut.finaliseSession(s)
    }
    let epoch = Date(timeIntervalSince1970: 0)
    let result = try sut.fetchSessions(since: epoch, limit: 3)
    XCTAssertEqual(result.count, 3)
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HoopTrackTests/DataServiceExportTests \
  2>&1 | grep -E "(Test Case|error:|BUILD FAILED)"
```

Expected: build error — `'fetchSessions(since:)' is not a member of 'DataService'`

- [ ] **Step 3: Add `fetchSessions(since:limit:)` to `DataService.swift`**

Add after `fetchSessions(drillType:)` (around line 56):

```swift
/// Fetches sessions that started on or after `date`, most recent first.
/// Pass a `limit` to avoid full-table scans when only recent data is needed.
func fetchSessions(since date: Date, limit: Int? = nil) throws -> [TrainingSession] {
    let predicate  = #Predicate<TrainingSession> { $0.startedAt >= date }
    var descriptor = FetchDescriptor(predicate: predicate,
                                     sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
    descriptor.fetchLimit = limit
    return try modelContext.fetch(descriptor)
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:HoopTrackTests/DataServiceExportTests \
  2>&1 | grep -E "(Test Case|error:|BUILD FAILED)"
```

Expected: all `DataServiceExportTests` pass.

- [ ] **Step 5: Update `ProgressViewModel.load()` to use the new method**

In `ProgressViewModel.swift`, replace:
```swift
sessions = try dataService.fetchSessions()
```

With:
```swift
let cutoff = Calendar.current.date(
    byAdding: .day, value: -selectedTimeRange.days, to: .now
)!
sessions = try dataService.fetchSessions(since: cutoff)
```

Note: the existing `computeFGTrend()` and `heatMapShots` filter by `selectedTimeRange` after fetch — these filters are now redundant for date range but harmless (they still guard against edge cases). Leave them in place.

- [ ] **Step 6: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 7: Commit**

```bash
git add HoopTrack/HoopTrack/Services/DataService.swift \
        HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift \
        ../HoopTrackTests/DataServiceExportTests.swift
git commit -m "perf(data): add fetchSessions(since:limit:) + use in ProgressViewModel"
```

---

## Task 13: `CameraService` — `autoreleasepool` Fix

**Files:**
- Modify: `HoopTrack/HoopTrack/Services/CameraService.swift`

- [ ] **Step 1: Apply the `autoreleasepool` fix**

In `CameraService.swift`, find the `captureOutput(_:didOutput:from:)` delegate method (around line 142):

```swift
nonisolated func captureOutput(_ output: AVCaptureOutput,
                               didOutput sampleBuffer: CMSampleBuffer,
                               from connection: AVCaptureConnection) {
    // Phase 2: pass to CV pipeline
    // cvPipeline?.processBuffer(sampleBuffer)
    frameSubject.send(sampleBuffer)
}
```

Replace with:

```swift
nonisolated func captureOutput(_ output: AVCaptureOutput,
                               didOutput sampleBuffer: CMSampleBuffer,
                               from connection: AVCaptureConnection) {
    // Wrap in autoreleasepool to ensure the CMSampleBuffer's backing
    // CVPixelBuffer is released promptly rather than waiting for the
    // next run loop drain. Without this, 60fps capture can hold 2-3
    // live pixel buffers (~10-15 MB) simultaneously.
    autoreleasepool {
        // Phase 2: pass to CV pipeline
        // cvPipeline?.processBuffer(sampleBuffer)
        frameSubject.send(sampleBuffer)
    }
}
```

- [ ] **Step 2: Build**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild build \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(error:|BUILD SUCCEEDED|BUILD FAILED)"
```

Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run all tests**

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test \
  -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  2>&1 | grep -E "(Test Case.*passed|Test Case.*failed|error:|BUILD FAILED)"
```

Expected: all tests pass, no failures.

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Services/CameraService.swift
git commit -m "perf(camera): wrap frameSubject.send in autoreleasepool to release CVPixelBuffer promptly"
```

---

## Self-Review Checklist

### Spec Coverage

| Spec Requirement | Task |
|---|---|
| Three Siri Shortcuts (Start free shoot, Show stats, Shots today) | Tasks 3, 4, 5 |
| Extensible AppShortcutsProvider | Task 6 |
| URL scheme registered + `.onOpenURL` routing | Tasks 1, 2 |
| JSON export with per-shot detail | Tasks 7, 8 |
| Export entry point in ProfileTabView | Task 9 |
| MetricsService (MXMetricManager) | Task 10 |
| Performance findings documented before fixes | Task 11 |
| DataService FetchDescriptor optimisation | Task 12 |
| CVPixelBuffer autoreleasepool fix | Task 13 |

### Placeholder Scan
No TBDs, TODOs, or incomplete code blocks. All steps include exact file paths, concrete code, and expected test output.

### Type Consistency
- `AppState.handleDeepLink(_:)` — used in Task 1 (creation) and Task 1 (HoopTrackApp registration). ✓
- `DataService.fetchShotsTodayCount()` — defined in Task 5, used in `ShotsTodayIntent` Task 5. ✓
- `DataService.fetchSessions(since:limit:)` — defined in Task 12, used in ProgressViewModel Task 12. ✓
- `ExportService.exportJSON(for:)` — defined in Task 8, used in ProfileTabView Task 9. ✓
- `SessionExportRecord(from:)` / `ShotExportRecord(from:)` — defined in Task 7, used in `ExportService` Task 8. ✓
- `MetricsService.register()` — defined in Task 10, called in `HoopTrackApp` Task 10. ✓

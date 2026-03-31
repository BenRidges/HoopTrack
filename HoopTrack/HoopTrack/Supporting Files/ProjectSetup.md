# HoopTrack — Xcode Project Setup

## Creating the Xcode Project

All Swift source files are in this directory. To wire them into Xcode:

1. **New Project** → iOS → App
   - Product Name: `HoopTrack`
   - Bundle ID: `com.hooptrack.app`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Minimum Deployment: **iOS 16.0**
   - Storage: **SwiftData** (Xcode will scaffold the container — we override it in `HoopTrackApp.swift`)

2. **Add all source files** — drag the `HoopTrack/` folder into the Xcode project navigator, ensuring "Copy items if needed" is checked.

3. **Info.plist** — replace the auto-generated one with `Supporting Files/Info.plist`.

4. **Entitlements** — in the project target → Signing & Capabilities:
   - Add **HealthKit** capability
   - When ready: add **iCloud** (CloudKit) and **Push Notifications**

5. **Swift Package Dependencies** (optional Phase 5+):
   - `https://github.com/apple/swift-algorithms` — sliding-window stats in the metrics pipeline

6. **Build & Run** on iPhone 14 simulator or device.

---

## Architecture Overview

```
HoopTrack/
├── HoopTrackApp.swift          # @main — SwiftData container + environment injection
├── ContentView.swift           # TabView root (Home / Train / Progress / Profile)
│
├── Models/                     # SwiftData @Model classes (iOS 17+)
│   ├── Enums.swift             # All domain enums (DrillType, ShotType, CourtZone, …)
│   ├── PlayerProfile.swift     # Single player profile, career stats, skill ratings
│   ├── TrainingSession.swift   # One training session, aggregate stats + zone breakdown
│   ├── ShotRecord.swift        # Individual shot — position, result, Shot Science fields
│   └── GoalRecord.swift        # User-defined goal with progress tracking
│
├── ViewModels/                 # MVVM — one VM per tab + LiveSession
│   ├── DashboardViewModel.swift
│   ├── TrainViewModel.swift
│   ├── LiveSessionViewModel.swift
│   ├── ProgressViewModel.swift
│   └── ProfileViewModel.swift
│
├── Views/
│   ├── Home/
│   │   └── HomeTabView.swift          # Dashboard: ratings, streak, mission, volume chart
│   ├── Train/
│   │   ├── TrainTabView.swift         # Drill picker grid + quick-start banner
│   │   ├── LiveSessionView.swift      # Full-screen camera HUD
│   │   └── SessionSummaryView.swift   # Post-session stats + shot chart
│   ├── Progress/
│   │   └── ProgressTabView.swift      # FG% trend, heat map, zones, goals
│   ├── Profile/
│   │   └── ProfileTabView.swift       # History log, settings, export
│   └── Components/
│       ├── StatCard.swift             # Reusable labelled metric card
│       ├── CourtMapView.swift         # Canvas half-court with shot dots
│       ├── SkillRadarView.swift       # Canvas radar chart (5 axes)
│       └── CameraPermissionView.swift # Permission request / denied prompt
│
├── Services/
│   ├── CameraService.swift     # AVCaptureSession lifecycle, frame publisher
│   ├── DataService.swift       # SwiftData abstraction — CRUD + analytics queries
│   ├── HapticService.swift     # UIImpactFeedbackGenerator wrappers
│   └── NotificationService.swift # UNUserNotificationCenter — streak/goal/mission
│
└── Utilities/
    ├── Constants.swift         # All magic numbers and targets from the spec
    └── Extensions.swift        # Double, Date, View, Color, CGPoint helpers
```

---

## Phase Roadmap

| Phase | What to build next | Key files to extend |
|---|---|---|
| **1** ✅ | Foundation (this PR) | All files above |
| **2** | Shot tracking MVP — Core ML ball detection, make/miss via CV | `CameraService.framePublisher`, new `CVPipeline.swift`, `LiveSessionViewModel.logShot()` |
| **3** | Shot Science — Vision body pose, release angle/time/vertical | New `ShotScienceProcessor.swift`, populate `ShotRecord` optional fields |
| **4** | Dribble drills — front camera, ARKit floor targets | New `DribblePipeline.swift`, `ARDrillView.swift`, `CameraService.configureSession(.front)` |
| **5** | Progress & Analytics — skill rating algorithm, goals, heat map density | `DataService` analytics methods, `ProgressViewModel.zoneEfficiency`, `GoalListView` |
| **6** | Polish — HealthKit, Haptics, Siri, Watch, export, notifications | `HoopTrackApp` entitlements, new `HealthKitService.swift`, `SiriIntentHandler.swift` |
| **7** | TestFlight + App Store | — |

---

## Key Design Decisions

- **No third-party dependencies** — all CV, AR, charting, and data use Apple-native frameworks.
- **MVVM + Combine** — ViewModels are `@MainActor ObservableObject`; services emit via `@Published` or Combine publishers.
- **DataService abstraction** — ViewModels never touch `ModelContext` directly; makes unit testing and the iOS 16 Core Data fallback straightforward.
- **CameraService.framePublisher** — a `PassthroughSubject<CMSampleBuffer, Never>` decouples the camera from the CV pipeline. Phase 2 subscribes to it.
- **Portrait-only** — locked in `Info.plist` for consistent CV coordinate mapping.
- **Offline-first** — all data is local; iCloud sync is opt-in only.

# Landscape LiveSessionView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert LiveSessionView from portrait to always-landscape with a right sidebar layout and border glow make/miss animations.

**Architecture:** LiveSessionView is wrapped in a `UIHostingController` subclass that forces landscape orientation. The view layout changes from vertical stacking to an `HStack` with camera feed (80%) and sidebar (20%). The CV pipeline coordinate mapping is updated for landscape by changing `videoRotationAngle` from 90° (portrait) to 0° (landscape). A new `ShotGlowOverlay` view handles the border glow animation.

**Tech Stack:** SwiftUI, AVFoundation, Vision, UIKit (orientation control)

**Spec:** `docs/superpowers/specs/2026-04-12-landscape-live-session-design.md`

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `HoopTrack/Views/Train/LandscapeHostingController.swift` | UIHostingController subclass forcing landscape orientation |
| Create | `HoopTrack/Views/Components/ShotGlowOverlay.swift` | Border glow + text flash animation overlay |
| Modify | `HoopTrack/Views/Train/LiveSessionView.swift` | Rewrite layout from VStack to HStack with sidebar |
| Modify | `HoopTrack/Views/Train/TrainTabView.swift` | Wrap LiveSessionView in LandscapeHostingController |
| Modify | `HoopTrack/Services/CameraService.swift` | Accept orientation parameter for videoRotationAngle |
| Modify | `HoopTrack/Services/VideoRecordingService.swift` | Accept orientation parameter for videoRotationAngle |
| Modify | `Info.plist` | Add landscape orientations for iPhone |
| Modify | `HoopTrack/HoopTrackApp.swift` | Add AppDelegate to restrict non-session VCs to portrait |

---

### Task 1: Info.plist + AppDelegate Orientation Control

**Files:**
- Modify: `Info.plist:56-59` (add landscape orientations for iPhone)
- Modify: `HoopTrack/HoopTrackApp.swift` (add AppDelegate with orientation gate)

The app currently only allows portrait on iPhone via Info.plist. To let LiveSessionView rotate to landscape while keeping everything else portrait, we need to: (1) allow landscape in Info.plist, and (2) use an AppDelegate to dynamically control which orientations are permitted based on a shared flag.

- [ ] **Step 1: Update Info.plist to allow landscape on iPhone**

Change the `UISupportedInterfaceOrientations~iphone` array in `Info.plist` from:

```xml
<key>UISupportedInterfaceOrientations~iphone</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
</array>
```

to:

```xml
<key>UISupportedInterfaceOrientations~iphone</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

- [ ] **Step 2: Add an AppDelegate class to HoopTrackApp.swift**

Add the following above the `@main` struct in `HoopTrackApp.swift`:

```swift
// MARK: - Orientation Control
// A global flag set by LandscapeHostingController to allow landscape
// for the live session only. All other screens remain portrait.
enum OrientationLock {
    /// When `true`, landscape orientations are permitted.
    @MainActor static var allowLandscape: Bool = false
}

final class HoopTrackAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.allowLandscape ? .landscape : .portrait
    }
}
```

- [ ] **Step 3: Wire the AppDelegate into HoopTrackApp**

Add the adapter inside `HoopTrackApp`:

```swift
@UIApplicationDelegateAdaptor(HoopTrackAppDelegate.self) var appDelegate
```

Place it right after the `modelContainer` property.

- [ ] **Step 4: Build to verify no regressions**

Run:
```bash
xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Info.plist HoopTrack/HoopTrackApp.swift
git commit -m "feat: add AppDelegate orientation gate for landscape live session"
```

---

### Task 2: LandscapeHostingController

**Files:**
- Create: `HoopTrack/Views/Train/LandscapeHostingController.swift`

A `UIHostingController` subclass that forces landscape orientation. It sets `OrientationLock.allowLandscape = true` on appear and resets to `false` on disappear, then requests the rotation.

- [ ] **Step 1: Create LandscapeHostingController.swift**

Create `HoopTrack/Views/Train/LandscapeHostingController.swift`:

```swift
// LandscapeHostingController.swift
// UIHostingController subclass that forces landscape orientation
// for LiveSessionView. Sets OrientationLock flag and requests rotation.

import SwiftUI
import UIKit

final class LandscapeHostingController<Content: View>: UIHostingController<Content> {

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscapeRight
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationLock.allowLandscape = true
        requestOrientationChange(to: .landscapeRight)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        OrientationLock.allowLandscape = false
        requestOrientationChange(to: .portrait)
    }

    private func requestOrientationChange(to orientation: UIInterfaceOrientation) {
        guard let windowScene = view.window?.windowScene else { return }
        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: orientation == .landscapeRight ? .landscapeRight : .portrait
        )
        windowScene.requestGeometryUpdate(geometryPreferences) { error in
            // Non-fatal — the system may decline the request
            print("HoopTrack: orientation change request error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Create a SwiftUI wrapper for presenting via fullScreenCover**

Add the following to the same file, below `LandscapeHostingController`:

```swift
/// SwiftUI view that presents its content inside a LandscapeHostingController.
/// Use as the content of a `.fullScreenCover`.
struct LandscapeContainer<Content: View>: UIViewControllerRepresentable {

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> LandscapeHostingController<Content> {
        LandscapeHostingController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: LandscapeHostingController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}
```

- [ ] **Step 3: Build to verify**

Run:
```bash
xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Views/Train/LandscapeHostingController.swift
git commit -m "feat: add LandscapeHostingController for forced landscape presentation"
```

---

### Task 3: ShotGlowOverlay Component

**Files:**
- Create: `HoopTrack/Views/Components/ShotGlowOverlay.swift`

A standalone overlay view that renders the border glow effect and centered text when a shot result is detected. It takes a `ShotResult?` binding and animates in/out.

- [ ] **Step 1: Create ShotGlowOverlay.swift**

Create `HoopTrack/Views/Components/ShotGlowOverlay.swift`:

```swift
// ShotGlowOverlay.swift
// Border glow + text flash overlay for make/miss shot detection.
// Radiates colour from screen edges inward with opacity gradient.

import SwiftUI

struct ShotGlowOverlay: View {

    let shotResult: ShotResult?
    /// Width of the sidebar to offset the text toward the camera area centre.
    let sidebarWidth: CGFloat

    @State private var isVisible: Bool = false

    private var glowColor: Color {
        switch shotResult {
        case .make:    return .green
        case .miss:    return .red
        case .pending, .none: return .clear
        }
    }

    private var labelText: String {
        switch shotResult {
        case .make:    return "MAKE"
        case .miss:    return "MISS"
        case .pending, .none: return ""
        }
    }

    var body: some View {
        ZStack {
            // Border glow — thick blurred stroke creates an edge-inward glow
            Rectangle()
                .fill(.clear)
                .overlay {
                    Rectangle()
                        .stroke(glowColor, lineWidth: 120)
                        .blur(radius: 70)
                }
                .clipped()
                .ignoresSafeArea()

            // "MAKE" / "MISS" text — centred on camera area (offset left of sidebar)
            Text(labelText)
                .font(.system(size: 56, weight: .black, design: .rounded))
                .foregroundStyle(glowColor)
                .shadow(color: glowColor.opacity(0.8), radius: 40)
                .shadow(color: glowColor.opacity(0.4), radius: 80)
                .padding(.trailing, sidebarWidth)
        }
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .onChange(of: shotResult) { _, newValue in
            guard newValue == .make || newValue == .miss else { return }
            withAnimation(.easeIn(duration: 0.1)) {
                isVisible = true
            }
            withAnimation(.easeOut(duration: 0.9).delay(0.1)) {
                isVisible = false
            }
        }
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/Views/Components/ShotGlowOverlay.swift
git commit -m "feat: add ShotGlowOverlay with border glow and text flash animation"
```

---

### Task 4: Update CameraService for Landscape Orientation

**Files:**
- Modify: `HoopTrack/Services/CameraService.swift:56-107`

CameraService currently hardcodes `videoRotationAngle = 90` (portrait). We need to accept a `CameraOrientation` parameter so the caller can request landscape (angle = 0) instead.

- [ ] **Step 1: Add CameraOrientation enum to CameraService.swift**

Add above the `CameraService` class:

```swift
/// Orientation mode for the camera output.
/// Portrait = 90° rotation (device upright). Landscape = 0° (device sideways).
enum CameraOrientation {
    case portrait
    case landscape

    var videoRotationAngle: CGFloat {
        switch self {
        case .portrait:  return 90
        case .landscape: return 0
        }
    }
}
```

- [ ] **Step 2: Update configureSession to accept orientation**

Change the `configureSession` method signature from:

```swift
func configureSession(mode: CameraMode) {
    currentMode = mode
    sessionQueue.async { [weak self] in
        self?.buildSession(mode: mode)
    }
}
```

to:

```swift
func configureSession(mode: CameraMode, orientation: CameraOrientation = .portrait) {
    currentMode = mode
    sessionQueue.async { [weak self] in
        self?.buildSession(mode: mode, orientation: orientation)
    }
}
```

- [ ] **Step 3: Update buildSession to use orientation parameter**

Change `buildSession` signature from:

```swift
nonisolated private func buildSession(mode: CameraMode) {
```

to:

```swift
nonisolated private func buildSession(mode: CameraMode, orientation: CameraOrientation = .portrait) {
```

Then change the videoRotationAngle block from:

```swift
// Lock portrait orientation for consistent CV coordinate mapping
if let connection = videoOutput.connection(with: .video) {
    if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
    }
}
```

to:

```swift
// Set video rotation for the requested orientation
if let connection = videoOutput.connection(with: .video) {
    let angle = orientation.videoRotationAngle
    if connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
    }
}
```

- [ ] **Step 4: Build to verify (no callers changed yet — default param keeps existing behaviour)**

Run:
```bash
xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/Services/CameraService.swift
git commit -m "feat: add CameraOrientation parameter to CameraService.configureSession"
```

---

### Task 5: Update VideoRecordingService for Landscape Orientation

**Files:**
- Modify: `HoopTrack/Services/VideoRecordingService.swift:22-29`

Same pattern as CameraService — accept a `CameraOrientation` parameter so landscape video is tagged correctly.

- [ ] **Step 1: Update configure method**

Change from:

```swift
func configure(captureSession: AVCaptureSession) {
    guard captureSession.canAddOutput(movieOutput) else { return }
    captureSession.addOutput(movieOutput)
    if let connection = movieOutput.connection(with: .video),
       connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
    }
}
```

to:

```swift
func configure(captureSession: AVCaptureSession, orientation: CameraOrientation = .portrait) {
    guard captureSession.canAddOutput(movieOutput) else { return }
    captureSession.addOutput(movieOutput)
    let angle = orientation.videoRotationAngle
    if let connection = movieOutput.connection(with: .video),
       connection.isVideoRotationAngleSupported(angle) {
        connection.videoRotationAngle = angle
    }
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/Services/VideoRecordingService.swift
git commit -m "feat: add CameraOrientation parameter to VideoRecordingService.configure"
```

---

### Task 6: Rewrite LiveSessionView Layout to Landscape + Sidebar

**Files:**
- Modify: `HoopTrack/Views/Train/LiveSessionView.swift` (full rewrite of `body` and subviews)

This is the largest task. The view layout changes from a `VStack` overlay to an `HStack` with camera on the left and a sidebar on the right. The `ShotGlowOverlay` replaces the old make/miss animations. Camera is configured with `.landscape` orientation.

- [ ] **Step 1: Update the state properties**

Remove the old animation states and add a sidebar width constant. Replace:

```swift
@State private var showMakeAnimation = false
@State private var showMissAnimation = false
```

with:

```swift
private let sidebarWidth: CGFloat = 140
```

- [ ] **Step 2: Rewrite the body**

Replace the entire `body` computed property with:

```swift
var body: some View {
    ZStack {
        HStack(spacing: 0) {
            // MARK: Camera Area (~80%)
            ZStack {
                CameraPreviewView(captureSession: cameraService.captureSession)
                    .ignoresSafeArea()

                // Camera permission overlay
                if cameraService.permissionStatus != .authorized {
                    Color.black.ignoresSafeArea()
                    CameraPermissionView()
                }

                // Manual make/miss fallback — shown only when CV pipeline is not active
                if cvPipeline == nil {
                    VStack {
                        Spacer()
                        manualShotButtons
                            .padding(.bottom, 20)
                            .padding(.horizontal, 20)
                    }
                }
            }

            // MARK: Right Sidebar (~20%)
            sidebar
        }

        // Phase 2: calibration prompt — shown until hoop is locked
        if !viewModel.isCalibrated {
            calibrationOverlay
        }

        // MARK: Shot glow overlay
        ShotGlowOverlay(shotResult: viewModel.lastShotResult,
                         sidebarWidth: sidebarWidth)
    }
    .task {
        viewModel.configure(
            dataService:  dataService,
            hapticService: hapticService,
            coordinator:  coordinator
        )

        if cameraService.permissionStatus == .notDetermined {
            await cameraService.requestPermission()
        }
        if cameraService.permissionStatus == .authorized {
            cameraService.configureSession(mode: .rear, orientation: .landscape)
            cameraService.startSession()
        }

        viewModel.start(drillType: drillType, namedDrill: namedDrill, courtType: .nba)

        // Phase 2: start CV pipeline
        if let detector = BallDetectorFactory.make(BallDetectorFactory.active) {
            let cal = CourtCalibrationService()
            cal.onStateChange = { [weak viewModel] state in
                viewModel?.updateCalibrationState(isCalibrated: state.isCalibrated)
            }
            cal.startCalibration()

            let poseService = PoseEstimationService()
            let pipeline = CVPipeline(detector: detector,
                                      calibration: cal,
                                      poseService: poseService)
            pipeline.start(framePublisher: cameraService.framePublisher, viewModel: viewModel)

            calibration = cal
            cvPipeline  = pipeline
        } else {
            viewModel.updateCalibrationState(isCalibrated: true)
        }

        // Phase 3: record session video for replay
        let recorder = VideoRecordingService()
        recorder.configure(captureSession: cameraService.captureSession,
                           orientation: .landscape)
        if let sessionID = viewModel.session?.id {
            recorder.startRecording(sessionID: sessionID)
            recorder.onRecordingFinished = { result in
                if case .success(let url) = result {
                    viewModel.session?.videoFileName = url.lastPathComponent
                }
            }
        }
        videoRecorder = recorder
    }
    .onDisappear {
        cvPipeline?.stop()
        calibration?.reset()
        videoRecorder?.stopRecording()
        cameraService.stopSession()
    }
    .sheet(isPresented: $showMidSessionBreakdown) {
        MidSessionBreakdownView(viewModel: viewModel)
            .presentationDetents([.medium, .large])
    }
    .fullScreenCover(isPresented: $viewModel.isFinished) {
        if let session = viewModel.session {
            SessionSummaryView(
                session:      session,
                badgeChanges: viewModel.sessionResult?.badgeChanges ?? []
            ) {
                viewModel.isFinished = false
                onFinish()
            }
        }
    }
    .statusBarHidden(true)
}
```

- [ ] **Step 3: Rewrite the sidebar**

Replace the old `topHUD`, `recentShotsStrip`, and `bottomControls` with a single `sidebar` computed property:

```swift
// MARK: - Right Sidebar

private var sidebar: some View {
    VStack(spacing: 0) {
        // Stats — top
        VStack(spacing: 2) {
            Text(viewModel.fgPercentString)
                .font(.system(size: 32, weight: .black, design: .rounded))
                .foregroundStyle(fgTintColor)
                .shadow(radius: 4)
            Text("\(viewModel.shotsMade) / \(viewModel.shotsAttempted)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))

            Divider()
                .background(.white.opacity(0.2))
                .padding(.vertical, 8)

            Text(viewModel.elapsedFormatted)
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(radius: 4)

            if viewModel.isPaused {
                Text("PAUSED")
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(.top, 16)

        Spacer()

        // Recent shots — middle
        VStack(spacing: 6) {
            Text("RECENT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)
            HStack(spacing: 5) {
                ForEach(Array(viewModel.recentShots.enumerated()), id: \.element.id) { index, shot in
                    Circle()
                        .fill(dotColor(for: shot.result))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(.white, lineWidth: index == viewModel.recentShots.count - 1 ? 2 : 0)
                        )
                }
            }
        }

        Spacer()

        // Controls — bottom
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // Pause / Resume
                Button {
                    viewModel.isPaused ? viewModel.resume() : viewModel.pause()
                    hapticService.tap()
                } label: {
                    Image(systemName: viewModel.isPaused ? "play.fill" : "pause.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }

                // Mid-session breakdown
                Button {
                    hapticService.tap()
                    showMidSessionBreakdown = true
                } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .foregroundStyle(.white)

            // End Session
            HoldToEndButton {
                await viewModel.endSession()
            }
        }
        .padding(.bottom, 16)
    }
    .frame(width: sidebarWidth)
    .background(Color.black.opacity(0.85))
}
```

- [ ] **Step 4: Add FG% tint colour helper and manual shot buttons**

Add these computed properties/views:

```swift
// MARK: - FG% Tint Colour

/// Briefly tints the FG% text green or red to match the last shot result.
private var fgTintColor: Color {
    switch viewModel.lastShotResult {
    case .make:    return .green
    case .miss:    return .red
    case .pending, .none: return .white
    }
}

// MARK: - Manual Shot Buttons

private var manualShotButtons: some View {
    HStack(spacing: 20) {
        Button {
            viewModel.logShot(result: .miss)
        } label: {
            Label("Miss", systemImage: "xmark")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }

        Button {
            viewModel.logShot(result: .make)
        } label: {
            Label("Make", systemImage: "checkmark")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
        }
    }
}
```

- [ ] **Step 5: Remove old subviews that are no longer needed**

Delete the following computed properties from `LiveSessionView`:
- `topHUD`
- `makeAnimation`
- `missAnimation`
- `recentShotsStrip`
- `bottomControls`

Also remove the `onChange(of: viewModel.lastShotResult)` modifier from the old body — the `ShotGlowOverlay` handles animations now.

- [ ] **Step 6: Build to verify**

Run:
```bash
xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add HoopTrack/Views/Train/LiveSessionView.swift
git commit -m "feat: rewrite LiveSessionView to landscape layout with right sidebar"
```

---

### Task 7: Wire LandscapeContainer into TrainTabView

**Files:**
- Modify: `HoopTrack/Views/Train/TrainTabView.swift:40-59`

Wrap the `LiveSessionView` inside `LandscapeContainer` so it presents in forced landscape.

- [ ] **Step 1: Update the fullScreenCover content**

In `TrainTabView`, find the `.fullScreenCover` block and change the `LiveSessionView` branch from:

```swift
} else {
    LiveSessionView(
        drillType: drillToLaunch?.drillType ?? .freeShoot,
        namedDrill: drillToLaunch
    ) {
        isShowingLiveSession = false
        drillToLaunch        = nil
    }
}
```

to:

```swift
} else {
    LandscapeContainer {
        LiveSessionView(
            drillType: drillToLaunch?.drillType ?? .freeShoot,
            namedDrill: drillToLaunch
        ) {
            isShowingLiveSession = false
            drillToLaunch        = nil
        }
    }
    .ignoresSafeArea()
}
```

- [ ] **Step 2: Build to verify**

Run:
```bash
xcodebuild build -project HoopTrack.xcodeproj -scheme HoopTrack -destination 'platform=iOS Simulator,name=iPhone 16' | tail -5
```

Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/Views/Train/TrainTabView.swift
git commit -m "feat: wrap LiveSessionView in LandscapeContainer for forced landscape"
```

---

### Task 8: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

Update the documentation to reflect that LiveSessionView is now landscape.

- [ ] **Step 1: Update the portrait-only convention**

In `CLAUDE.md`, find:

```
- **Portrait-only.** The app is locked to portrait; landscape breaks CV coordinate mapping.
```

Replace with:

```
- **Portrait by default.** The app is portrait-locked except for `LiveSessionView`, which forces landscape via `LandscapeHostingController`. The `OrientationLock` flag in `HoopTrackApp.swift` gates which orientations the AppDelegate allows. CV coordinate mapping uses `CameraOrientation.landscape` (videoRotationAngle = 0°) during live sessions.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md to reflect landscape LiveSessionView"
```

---

## Task Dependency Graph

```
Task 1 (Info.plist + AppDelegate)
  └─► Task 2 (LandscapeHostingController)
        └─► Task 7 (Wire into TrainTabView)
Task 3 (ShotGlowOverlay) ──────────┐
Task 4 (CameraService orientation) ─┤
Task 5 (VideoRecording orientation) ┤
                                     └─► Task 6 (Rewrite LiveSessionView)
                                           └─► Task 7 (Wire into TrainTabView)
                                                 └─► Task 8 (Update CLAUDE.md)
```

**Parallel tracks:** Tasks 1-2 and Tasks 3-5 can run in parallel. Task 6 depends on both tracks. Task 7 depends on Tasks 2 and 6. Task 8 is last.

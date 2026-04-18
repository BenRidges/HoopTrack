# Landscape LiveSessionView Design Spec

**Date:** 2026-04-12
**Status:** Approved
**Scope:** Convert LiveSessionView from portrait to always-landscape with right sidebar layout and border glow shot animations.

## Overview

LiveSessionView currently runs in portrait orientation with a vertically stacked HUD. This spec converts it to an always-landscape layout optimised for tripod/propped-phone use, where the user is shooting from a distance and needs glanceable stats with maximum camera visibility.

The rest of the app remains portrait-locked. Only LiveSessionView forces landscape orientation.

## Layout: Camera + Right Sidebar

### Structure

```
┌──────────────────────────────┬────────────┐
│                              │   67%      │
│                              │   8 / 12   │
│                              │  ───────   │
│      Camera Feed             │   4:32     │
│      (~80% width)            │            │
│                              │  ● ● ○ ● ○ │
│                              │            │
│                              │  [⏸] [📊]  │
│                              │ [HOLD END] │
└──────────────────────────────┴────────────┘
```

### Camera Area (~80% width)

- Full-height camera preview filling the left portion of the screen.
- `CameraPreviewView` uses `.resizeAspectFill` video gravity — same as today.
- When CV pipeline is unavailable, manual Make/Miss buttons appear at the bottom of the camera area (horizontally laid out, same as current portrait fallback but repositioned).

### Right Sidebar (~20% width, ~140pt)

Three vertically-spaced sections with `ultraThinMaterial` or solid dark background (`rgba(0,0,0,0.85)`):

**Top — Stats:**
- FG% in large weight-900 rounded font (~32pt), white.
- "makes / attempts" subtitle below in smaller muted text.
- Horizontal divider.
- Elapsed time in monospaced weight-900 font (~26pt), white.
- "PAUSED" label appears below timer when paused (yellow, caption bold — same as current).

**Middle — Recent Shots Strip:**
- "RECENT" label in small uppercase muted text.
- Horizontal row of 5 coloured dots (green = make, red = miss, grey = pending).
- Latest shot gets a white border ring to indicate recency.

**Bottom — Controls:**
- Row of two circular buttons: Pause/Resume and Mid-Session Breakdown (chart).
- Below: full-width "HOLD TO END" button (red background, rounded rectangle).
- Same `HoldToEndButton` component as current implementation.

## Make/Miss Animation: Border Glow

### Effect

When a shot is detected as make or miss:

1. **Border glow:** An inset box-shadow (or SwiftUI equivalent using `overlay` + `RadialGradient`) radiates from all screen edges toward the center. The glow is opaque at the edges and fades to transparent toward the center of the screen.
   - Make: green (`#4ade80` / `Color.green`)
   - Miss: red (`#ef4444` / `Color.red`)

2. **Text flash:** "MAKE" or "MISS" in large weight-900 rounded font (~48-56pt) centered on the camera area (not the full screen — offset left of the sidebar). Text has a matching colour glow/shadow.

3. **FG% tint:** The FG% text in the sidebar briefly tints to match the shot colour (green on make, red on miss) before fading back to white.

### Timing

- Duration: ~1 second.
- Easing: ease-out (fast appearance, slow fade).
- The glow, text, and FG% tint all animate together and fade out together.

### SwiftUI Implementation Approach

Use a `ZStack` overlay on the entire `LiveSessionView`:
- `Rectangle().fill(.clear)` with `.overlay` containing a `Rectangle` with inset shadow or layered `RadialGradient`s from each edge.
- Opacity animated from 1 → 0 over 1 second.
- Text overlay centered within the camera area's frame (use `GeometryReader` or alignment guides to exclude sidebar width).

## Calibration Overlay

Full-screen overlay (covers both camera area and sidebar) until `isCalibrated` is true. Same content as current: viewfinder icon, "Aim at the hoop" title, instruction text, circular progress indicator. Dark semi-transparent background.

No changes to calibration behaviour — only layout adaptation to landscape frame.

## Orientation Management

### Forcing Landscape

LiveSessionView is presented via `fullScreenCover` from `TrainTabView`. To force landscape:

1. **Hosting controller approach:** Wrap LiveSessionView in a `UIHostingController` subclass that overrides `supportedInterfaceOrientations` to return `.landscape` (or `.landscapeRight` specifically).
2. **On appear:** Request orientation change via `UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")` and call `UIViewController.attemptRotationToDeviceOrientation()`.
3. **On disappear:** Restore portrait by reversing the orientation request.

The `fullScreenCover` presentation isolates the orientation override — the rest of the app's portrait lock is unaffected.

### Safe Areas

Landscape on iPhones with notch/Dynamic Island creates asymmetric safe areas (notch on left or right depending on rotation direction). The layout must:
- Respect safe area on the notch side to avoid content being clipped.
- The sidebar should be on the **right side** (opposite the notch when in `.landscapeRight`).
- Camera preview ignores safe areas (`.ignoresSafeArea()`) as it does today.

## CV Pipeline: Coordinate Transform

### Problem

The CV pipeline (`CVPipeline`, `CourtCalibrationService`) normalises shot positions to 0–1 half-court coordinates assuming a portrait camera orientation. In landscape, the camera sensor's orientation relative to the scene changes by 90°.

### Solution

Apply a coordinate transform at the boundary between the CV pipeline and the view model:

1. **Camera feed:** `AVCaptureConnection.videoRotationAngle` set to match landscape orientation so the preview displays correctly. The raw `CMSampleBuffer` frames may still arrive in the sensor's native orientation.

2. **Pipeline output transform:** When the pipeline produces normalised coordinates `(x, y)`, apply a 90° rotation transform before passing to the view model:
   - Landscape right: `(x', y') = (y, 1 - x)` (or the inverse, depending on sensor orientation — must be verified empirically during implementation).

3. **Calibration service:** `CourtCalibrationService` hoop detection uses Vision framework coordinates (0–1, origin bottom-left). The Vision request's `regionOfInterest` may need adjustment, or the transform can be applied post-detection.

4. **No changes to stored data:** `ShotRecord` court coordinates remain in the same 0–1 normalised half-court space. The transform is applied at the CV → ViewModel boundary only, so all persisted data is orientation-agnostic.

### Verification

The coordinate transform must be validated by:
- Shooting from a known position and verifying the court map dot appears in the correct zone.
- Testing both `.landscapeRight` and `.landscapeLeft` if both are supported (recommendation: support `.landscapeRight` only for simplicity).

## Video Recording

`VideoRecordingService` records via `AVCaptureMovieFileOutput`. In landscape:
- The video file's metadata orientation tag should reflect landscape so playback in SessionSummaryView and Photos is correct.
- Set `AVCaptureConnection.videoRotationAngle` on the movie file output's connection to match the landscape orientation.

## Mid-Session Breakdown Sheet

The `.sheet` presentation (MidSessionBreakdownView) will appear as a sheet over the landscape view. No layout changes needed to the sheet content itself — SwiftUI handles sheet presentation in landscape automatically. The `.presentationDetents([.medium, .large])` remain.

## What Does NOT Change

- **LiveSessionViewModel:** No changes. All published properties and methods remain the same. The view reads the same state.
- **CVPipeline internals:** Shot detection state machine is unchanged. Only the coordinate output is transformed.
- **CourtCalibrationService internals:** Hoop detection logic is unchanged. Transform applied post-detection.
- **DataService / ShotRecord:** No schema changes. Court coordinates remain 0–1 normalised.
- **SessionSummaryView:** Presented via `fullScreenCover` after session ends — returns to portrait automatically when LiveSessionView dismisses.
- **HoldToEndButton:** Reused as-is, just repositioned in the sidebar.
- **HapticService integration:** Unchanged.
- **Other tabs / views:** Remain portrait-locked.

## Edge Cases

- **Device rotation during session:** Since we force landscape, if the user physically rotates the phone to portrait mid-session, the UI stays landscape. The camera preview may briefly show letterboxing — `resizeAspectFill` handles this.
- **Phone call interruption:** Standard `scenePhase` handling pauses the session. Orientation is re-forced on return.
- **Notch side detection:** Use the key window's `safeAreaInsets` (via `UIApplication.shared.connectedScenes`) to determine which side has the notch and ensure the sidebar is on the opposite side.
- **iPad:** If the app ever runs on iPad, landscape is the natural orientation. The sidebar layout works well on larger screens without changes.

# HoopTrack Performance Audit Report

**Date:** 2026-04-12  
**Auditor:** Phase 6A implementation  
**Status:** Pre-fix baseline

---

## CVPipeline / CameraService

### Finding 1 — CVPixelBuffer not released promptly
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/Services/CameraService.swift:147`  
**Description:**  
`captureOutput(_:didOutput:from:)` calls `frameSubject.send(sampleBuffer)` at line 147 without an `autoreleasepool`. The CMSampleBuffer (and its backing CVPixelBuffer) is Objective-C memory managed via autorelease. Without an explicit pool, the buffer is not released until the next run loop drain — potentially holding 2–3 live buffers at 60fps, adding ~10–15 MB peak memory overhead.

**Fix:** Wrap `frameSubject.send(sampleBuffer)` in `autoreleasepool { }`.

---

### Finding 2 — `DispatchQueue.main.async` in session configuration (Swift 6 lint)
**Severity:** Minor  
**File:** `HoopTrack/HoopTrack/Services/CameraService.swift:78, 94, 126, 134`  
**Description:**  
`buildSession(mode:)` uses `DispatchQueue.main.async { self.error = .deviceUnavailable }` (lines 78, 94) and `DispatchQueue.main.async { self?.isSessionRunning = true/false }` (lines 126, 134) to set `@Published` state. Under strict Swift 6 concurrency, this should be `Task { @MainActor in self.error = .deviceUnavailable }`. The current form compiles under Swift 5 but will generate a warning under Swift 6 strict mode.

**Fix (Task 13):** Replace `DispatchQueue.main.async { ... }` blocks with `Task { @MainActor in ... }` at each of the four call sites.

---

## DataService — Query Optimisation

### Finding 3 — Unbounded session fetch in ProgressViewModel
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/ViewModels/ProgressViewModel.swift:39`  
**Description:**  
`ProgressViewModel.load()` calls `dataService.fetchSessions()` with no date predicate and no limit (line 39). This loads the entire session history into memory on every load and time-range change. For a user with 500+ sessions, this is a full table scan and unnecessary allocation.

`DataService.fetchSessions(sortBy:limit:)` (lines 37–43) accepts an optional `limit` but no `since:` date predicate. The existing `fetchSessions(drillType:)` overload (lines 45–50) shows the predicate pattern — the same approach is needed for date filtering.

**Fix (Task 12):** Add `DataService.fetchSessions(since:)` with a `FetchDescriptor` date predicate. `ProgressViewModel` should pass `selectedTimeRange`'s cutoff date so only in-range sessions are loaded from SwiftData.

---

## CameraService — autoreleasepool Fix

### Finding 4 — Missing autoreleasepool in captureOutput
**Severity:** Important  
**File:** `HoopTrack/HoopTrack/Services/CameraService.swift:142–148`  
**Description:**  
The full `captureOutput(_:didOutput:from:)` delegate method (lines 142–148) does not wrap its CMSampleBuffer handling in `autoreleasepool`. This is the standard pattern for AVFoundation capture pipelines to ensure prompt release of the pixel buffer memory rather than waiting for the ARC autorelease drain.

**Fix (Task 13):**
```swift
nonisolated func captureOutput(_ output: AVCaptureOutput,
                               didOutput sampleBuffer: CMSampleBuffer,
                               from connection: AVCaptureConnection) {
    autoreleasepool {
        frameSubject.send(sampleBuffer)
    }
}
```

---

## Summary Table

| # | Finding | Severity | File | Fix Task |
|---|---------|----------|------|----------|
| 1 | CVPixelBuffer not released promptly — missing autoreleasepool | Important | CameraService.swift:147 | Task 13 |
| 2 | DispatchQueue.main.async should be Task { @MainActor in } | Minor | CameraService.swift:78,94,126,134 | Task 13 |
| 3 | Unbounded session fetch — no date predicate in ProgressViewModel | Important | ProgressViewModel.swift:39 | Task 12 |
| 4 | captureOutput missing autoreleasepool (same as #1, full context) | Important | CameraService.swift:142–148 | Task 13 |

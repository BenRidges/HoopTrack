# CV-A — Telemetry Foundation Design Spec

**Date:** 2026-04-19
**Status:** Approved
**Scope:** Capture real HoopTrack footage + per-frame detection metadata during sessions, upload to Supabase Storage on Wi-Fi, build the dataset pipeline that unblocks a data-driven CV-B retrain.
**Parent:** [upgrade-cv-detection.md](../../../../docs/upgrade-cv-detection.md) (Phase A section — this is the scoped-down, dev-only delivery).
**Parallel track:** CV-C (Kalman tracking) — see [2026-04-19-cv-c-tracking-design.md](2026-04-19-cv-c-tracking-design.md). The two don't conflict; CV-C's smoothed output will feed this service's detection log once it lands.

---

## 1. Goal

Every improvement to the shipped `BallDetector.mlmodel` beyond the current yolo11m retrain is capped by the distribution gap between the public Roboflow datasets it's trained on and real HoopTrack footage. CV-A is the pipe that captures real footage + enough metadata to drive the Grounding-DINO autolabel tooling that already exists at `hooptrack-ball-detection/autolabel/`.

Goal posts:

1. After any training / game session ends, ~500–1000 sampled frames from the recorded video plus a detection-metadata sidecar land in a private Supabase Storage bucket, without any manual action from the user.
2. Zero measurable performance regression on the live CV pipeline — all heavy work happens post-session.
3. Target: ≥ 2,000 uploaded frames across ≥ 20 sessions unlocks the real CV-B retrain (as gated in `upgrade-cv-detection.md` §Phase B).

Dev-only for now. This is a solo, unreleased project. Consent / opt-in UI is deferred to production-readiness work before App Store submission.

---

## 2. Architecture

```
During session (live)           After session (finalization)
──────────────────────          ──────────────────────────────
 CameraService                   SessionFinalizationCoordinator
    │                               │  step 10 (new)
    ▼                               ▼
 CVPipeline                      TelemetryCaptureService
    │                               │
    └─► DetectionLogger ─────────►  reads detections.jsonl
        writes .jsonl              │  applies trigger rules
        (per-frame metadata)       ▼
                                 FrameSampler (pure)
                                    │  returns timestamp set
                                    ▼
                                 AVAssetImageGenerator
                                    │  extracts jpgs from .mov
                                    ▼
                                 Writes session manifest.json
                                    │  creates TelemetryUpload row
                                    ▼
                                 TelemetryUploadService
                                    │  fire-and-forget Task
                                    │  Wi-Fi-only URLSession
                                    ▼
                                 Supabase Storage (telemetry-sessions)
```

Three new services, all single-responsibility:

- **`DetectionLogger`** — appends one line per frame to `detections.jsonl` during the live session. Subscribes to `CVPipeline` output on the existing session queue; no main-actor work. Batch-flushed every 1s.
- **`TelemetryCaptureService`** — fires at session finalization (new step 10 in `SessionFinalizationCoordinator`). Reads the detection log, applies `FrameSampler` rules, extracts JPEGs from the recorded `.mov` with `AVAssetImageGenerator`, writes `manifest.json`, creates the `TelemetryUpload` row.
- **`TelemetryUploadService`** — reads pending `TelemetryUpload` rows, uploads the session directory to Supabase Storage via a dedicated Wi-Fi-only `URLSession`, updates row state through the lifecycle, deletes local files on success. Retry sweep on app launch.

Pure sampling logic (the trigger rules) lives in a `FrameSampler` struct, `nonisolated`, unit-tested.

---

## 3. DetectionLogger — live-session component

Records per-frame detection state to `Documents/Telemetry/<sessionID>/detections.jsonl`. Input comes from whatever `CVPipeline` publishes after CV-C merges (raw or smoothed — CV-A captures whatever's available).

### 3.1 Per-frame record

One JSON object per line:

```json
{"t":1234.567,"ci":0.82,"bb":[0.41,0.62,0.08,0.09],"ri":0.91,"rb":[0.45,0.10,0.12,0.06],"st":"tracking"}
```

| Field | Meaning |
|---|---|
| `t` | Timestamp in seconds from `CMSampleBuffer` presentation time, aligned to the recorded `.mov` timeline so the sampler can find frames in the video |
| `ci` | Ball detection confidence (0–1); null when no ball detected this frame |
| `bb` | Ball bbox normalized `[x, y, w, h]`; null when no detection |
| `ri` | Rim detection confidence (from `CourtCalibrationService`); null when no rim lock |
| `rb` | Rim bbox normalized; null when no rim |
| `st` | `CVPipeline.state` at the frame (`idle` / `tracking` / `release_detected` / `resolved`) |

At 30fps for a 10-min session: ~18k lines × ~120 bytes each = **~2 MB**. Trivial.

### 3.2 Concurrency + storage

- Writes happen on `CameraService.sessionQueue`; no main-actor hop per frame.
- In-memory buffer of ~30 records; flushed every 1s or when buffer fills.
- Final flush on session end, before `TelemetryCaptureService` reads the file.
- Output file gets `FileProtectionType.complete` (same as session videos).

### 3.3 Integration

`CVPipeline` already produces the data; `DetectionLogger` only subscribes. No change to pipeline logic or published output. Can be enabled/disabled independently of everything else; when disabled, no file is written and `TelemetryCaptureService` skips the session.

---

## 4. TelemetryCaptureService — post-session pipeline

Runs as new step 10 in `SessionFinalizationCoordinator`, after the existing cloud-sync step (step 9). Runs off-main via `Task.detached(priority: .background)` so it doesn't block the UI closing the session summary.

### 4.1 Trigger rules (driven by `FrameSampler`)

Union of four trigger sets, deduplicated by timestamp:

1. **Baseline** — `stride(0, sessionDuration, step: 1.0 / HoopTrack.Telemetry.baselineSampleFPS)`. At 1 fps, ~600 frames per 10-min session.
2. **Around each `ShotRecord`** — 10 frames in the ~333ms before shot timestamp + 10 frames in the ~333ms after. ~20 frames per shot.
3. **Flicker windows** — walk the detection log. Any run where `ci` drops from ≥ `flickerThresholdHigh` (0.6) to < `flickerThresholdLow` (0.3) for ≥ 3 consecutive frames and then recovers. Sample every 3rd frame of that run + 3 frames on each side.
4. **Session boundaries** — first 5 and last 5 frames.

### 4.2 Decimation when over cap

Hard cap: `HoopTrack.Telemetry.maxFramesPerSession = 1000`.

If the union exceeds the cap, decimate in this priority order (least-to-most information-dense):
1. Baseline (every other timestamp dropped until cap met)
2. Flicker (drop oldest windows first)
3. Around-shot (keep)
4. Boundaries (keep)

### 4.3 Frame extraction

```swift
let asset = AVURLAsset(url: sessionVideoURL)
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.maximumSize = CGSize(
    width: HoopTrack.Telemetry.frameMaxLongestEdgePx,
    height: HoopTrack.Telemetry.frameMaxLongestEdgePx
)
generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 30)
generator.requestedTimeToleranceAfter  = CMTime(value: 1, timescale: 30)

for (idx, ts) in sampledTimestamps.enumerated() {
    let cgImage = try generator.copyCGImage(
        at: CMTime(seconds: ts, preferredTimescale: 600),
        actualTime: nil
    )
    let jpeg = UIImage(cgImage: cgImage).jpegData(
        compressionQuality: HoopTrack.Telemetry.frameJpegQuality
    )
    let filename = String(format: "frame_%04d.jpg", idx)
    try jpeg.write(to: sessionTelemetryDir.appendingPathComponent(filename))
}
```

Target sizing: 960px longest edge @ q0.7 JPEG → ~30–50 KB/frame → ~30 MB for a full 1000-frame session.

### 4.4 Output layout

Per session:

```
Documents/Telemetry/<sessionID>/
├── detections.jsonl
├── manifest.json
├── frame_0000.jpg
├── frame_0001.jpg
└── ...
```

### 4.5 Manifest schema

```json
{
  "session_id": "uuid",
  "session_kind": "training",
  "app_version": "1.0.42",
  "model_version": "BallDetector-yolo11m-2026-04-19",
  "session_started_at": "2026-04-19T14:02:13Z",
  "session_duration_sec": 612.3,
  "total_shots": 18,
  "frame_count": 734,
  "trigger_summary": {
    "baseline": 600,
    "around_shot": 98,
    "flicker": 26,
    "boundaries": 10
  },
  "frames": [
    {
      "file": "frame_0000.jpg",
      "timestamp_sec": 0.0,
      "trigger": "boundaries",
      "width": 960,
      "height": 540
    }
  ]
}
```

`model_version` string is stored so future retrains can correlate telemetry data with which detector was in use when it was captured.

---

## 5. TelemetryUploadService — Supabase Storage upload

### 5.1 Supabase Storage bucket

New private bucket `telemetry-sessions`. Path layout:

```
telemetry-sessions/
└── <supabase_user_id>/
    └── <session_id>/
        ├── manifest.json
        ├── detections.jsonl
        ├── frame_0000.jpg
        └── ...
```

### 5.2 RLS policies (SQL)

```sql
-- INSERT: authenticated users can only write under their own user_id folder
CREATE POLICY "telemetry_insert_own"
ON storage.objects FOR INSERT TO authenticated
WITH CHECK (
    bucket_id = 'telemetry-sessions'
    AND (storage.foldername(name))[1] = auth.uid()::text
);

-- SELECT / UPDATE / DELETE: denied for all authenticated users.
-- Admin service-role key reads for dataset puller / dashboard.
```

Append-only from the client's perspective. Admin-only read access via service-role key.

### 5.3 URLSession configuration

```swift
let config = URLSessionConfiguration.default
config.allowsCellularAccess = false       // Wi-Fi only — multi-MB uploads shouldn't eat cell data
config.waitsForConnectivity = true        // queue if offline
config.timeoutIntervalForRequest = HoopTrack.Telemetry.uploadRequestTimeoutSec  // 60s
```

Dedicated session — not shared with `SupabaseContainer`'s auth session — so its policies don't bleed.

### 5.4 Upload flow

```swift
@MainActor
final class TelemetryUploadService {
    func uploadPending() async {
        let pending = try dataService.fetchTelemetryUploads(
            in: [.pending, .failed]
        )
        for row in pending where row.attemptCount < HoopTrack.Telemetry.maxUploadAttempts {
            await upload(row: row)
        }
    }

    private func upload(row: TelemetryUpload) async {
        row.state = .uploading
        row.lastAttemptAt = .now
        row.attemptCount += 1
        try? modelContext.save()

        do {
            try await uploadManifestAndLog(row: row)
            try await uploadFrames(row: row, maxConcurrent: HoopTrack.Telemetry.concurrentFrameUploads)
            row.state = .uploaded
            row.remoteBucketPath = "\(userID)/\(row.sessionID)/"
            try? FileManager.default.removeItem(at: localDir(for: row.sessionID))
        } catch {
            row.state = row.attemptCount >= HoopTrack.Telemetry.maxUploadAttempts
                ? .abandoned : .failed
            row.errorMessage = String(describing: error)
        }
        try? modelContext.save()
    }
}
```

### 5.5 Retry strategy

1. **On session finalization** — fire-and-forget: `Task { await telemetryUpload.uploadPending() }`. Same pattern Phase 9 sync uses.
2. **On app launch** — sweep pending / failed rows, retry.
3. **Abandoned** — after 5 failed attempts, state moves to `.abandoned`. Local files kept for manual off-device recovery via Xcode Devices window. No further retry without user intervention.

### 5.6 Local cleanup

On successful upload: delete `Documents/Telemetry/<sessionID>/` entirely. Session video (`.mov`) is separate and follows existing `DataService.purgeOldVideos` retention rules.

---

## 6. Data model

One new `@Model` type.

```swift
@Model
final class TelemetryUpload {
    @Attribute(.unique) var sessionID: UUID         // FK to TrainingSession or GameSession
    var stateRaw: String                            // UploadState.rawValue
    var sessionKindRaw: String                      // SessionKind.rawValue
    var frameCount: Int
    var totalBytes: Int
    var remoteBucketPath: String?                   // "<user>/<session>/" once uploaded
    var createdAt: Date
    var lastAttemptAt: Date?
    var attemptCount: Int
    var errorMessage: String?

    init(
        sessionID: UUID,
        sessionKind: SessionKind,
        frameCount: Int,
        totalBytes: Int
    ) {
        self.sessionID = sessionID
        self.stateRaw = UploadState.pending.rawValue
        self.sessionKindRaw = sessionKind.rawValue
        self.frameCount = frameCount
        self.totalBytes = totalBytes
        self.createdAt = .now
        self.attemptCount = 0
    }

    var state: UploadState {
        get { UploadState(rawValue: stateRaw) ?? .pending }
        set { stateRaw = newValue.rawValue }
    }

    var sessionKind: SessionKind {
        get { SessionKind(rawValue: sessionKindRaw) ?? .training }
        set { sessionKindRaw = newValue.rawValue }
    }
}

enum UploadState: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
    case abandoned
}

enum SessionKind: String, Codable {
    case training
    case game
}
```

### Design notes

- **No relationship to `TrainingSession` / `GameSession`** — kept loose via UUID so the upload row outlives either session if the user deletes it mid-upload.
- **No shot-level rows** — unlike the reference spec's full `ShotTelemetry`. Per-shot metadata lives on disk in `detections.jsonl` + `manifest.json`; queryable via file I/O if we ever need it in-app.
- **`sessionKind` stored** — avoids a table split; we rarely look back at the session itself from here.
- **`totalBytes` stored** — cheap way to show cumulative upload stats somewhere without filesystem scanning.

### Migration

Additive only: new `@Model` appended to `HoopTrackApp.modelContainer`'s schema list. Matches the Phase 8 / Phase 9 / SP1 pattern. No migration plan needed.

---

## 7. Integration with `SessionFinalizationCoordinator`

Current coordinator runs steps 1–9 (existing phases). Step 9 is the Phase 9 Supabase sync.

**New step 10**, after step 9:

```swift
// Step 10 — CV-A Telemetry Capture & Upload
// Fire-and-forget: runs after sync so it never blocks session summary.
// Skips silently if the session has no recorded video (drill without camera).
Task.detached(priority: .background) { [weak self] in
    await self?.telemetryCaptureService?.captureAndUpload(
        sessionID: sessionID,
        sessionKind: sessionKind
    )
}
```

Guards in `captureAndUpload`:
- Skip if `videoFileName == nil`
- Skip if session duration < `HoopTrack.Telemetry.minSessionDurationSec` (same 30s threshold as Phase 9 sync)
- Skip if `detections.jsonl` is missing (e.g. if the logger crashed mid-session)
- Skip if `AuthViewModel.user == nil` (no user = nowhere to upload)

---

## 8. Testing strategy

### 8.1 Pure-logic XCTest (TDD)

- **`FrameSamplerTests`** — given a detection log + shot list + trigger config, returns expected timestamp set. Cases: empty session, shot-heavy, flicker-heavy, over-cap decimation priority order, single-shot short session.
- **`DetectionLoggerTests`** — JSONL encoding round-trip; missing-field resilience; batch flush correctness.
- **`TelemetryUploadStateTests`** — state transitions (pending→uploading→uploaded; failed retry; abandonment after N attempts).

### 8.2 Integration — manual QA on device

1. Start a Free Shoot session, take a handful of shots, end session
2. Verify `Documents/Telemetry/<sessionID>/` contains `manifest.json` + `detections.jsonl` + jpgs
3. Verify Supabase Studio shows the files under `telemetry-sessions/<user>/<session>/` within ~30s on Wi-Fi
4. Verify local cleanup: `Documents/Telemetry/<sessionID>/` is gone after successful upload
5. Force offline → start session → finalize → should see `TelemetryUpload` row in `.pending`
6. Relaunch app on Wi-Fi → retry sweep picks up pending row and uploads
7. Kill app mid-upload → relaunch → state should be `.failed`, retry sweep resumes

### 8.3 No fixture-based CV eval in this phase

The reference spec §A7 describes a `BallDetectorEvalTests` fixture set. That's its own follow-up piece of work once enough real telemetry exists to hand-label a fixture set. Punt.

---

## 9. Constants

Added to `HoopTrack/Utilities/Constants.swift` as `HoopTrack.Telemetry`:

```swift
enum Telemetry {
    // Sampling
    static let baselineSampleFPS: Double = 1.0
    static let aroundShotPreFrames: Int = 10
    static let aroundShotPostFrames: Int = 10
    static let flickerThresholdHigh: Double = 0.6
    static let flickerThresholdLow: Double = 0.3
    static let flickerMinConsecutiveFrames: Int = 3
    static let boundaryFrames: Int = 5

    // Caps
    static let maxFramesPerSession: Int = 1000
    static let frameMaxLongestEdgePx: Int = 960
    static let frameJpegQuality: CGFloat = 0.7

    // Session eligibility
    static let minSessionDurationSec: Double = 30.0

    // Upload
    static let maxUploadAttempts: Int = 5
    static let concurrentFrameUploads: Int = 4
    static let uploadRequestTimeoutSec: TimeInterval = 60

    // Paths
    static let telemetryDirectoryName = "Telemetry"
    static let supabaseBucketName = "telemetry-sessions"
}
```

---

## 10. Files touched / created

### New
- `HoopTrack/Models/TelemetryUpload.swift`
- `HoopTrack/Services/DetectionLogger.swift`
- `HoopTrack/Services/TelemetryCaptureService.swift`
- `HoopTrack/Services/TelemetryUploadService.swift`
- `HoopTrack/Utilities/FrameSampler.swift` (pure, TDD)
- `HoopTrackTests/FrameSamplerTests.swift`
- `HoopTrackTests/DetectionLoggerTests.swift`
- `HoopTrackTests/TelemetryUploadStateTests.swift`

### Modified
- `HoopTrack/Services/CVPipeline.swift` — hook `DetectionLogger` into the frame output
- `HoopTrack/Services/SessionFinalizationCoordinator.swift` — new step 10 (capture + upload)
- `HoopTrack/Utilities/Constants.swift` — new `HoopTrack.Telemetry` block
- `HoopTrack/HoopTrackApp.swift` — register `TelemetryUpload.self` with `ModelContainer`
- `HoopTrack/Sync/SupabaseClient+Shared.swift` — expose `storage` accessor if not already
- `docs/production-readiness.md` — add P0 item: "CV-A telemetry must be gated or made opt-in before App Store submission"

### Supabase (applied via MCP or Studio)
- Create `telemetry-sessions` private Storage bucket
- Apply the 4 RLS policies (1 INSERT allow, 3 DENY for authenticated role)

---

## 11. Open questions

Intentionally deferred to implementation or follow-up work:

1. **Audio capture**. Reference spec §A2 mentions a synchronized mic recording. CV-E (audio classifier) is multiple hops away. Design accommodates adding `audio_clip.m4a` per session later without schema changes.
2. **Remote dataset puller + labeling dashboard**. How uploaded telemetry gets pulled, triaged, and handed to the Grounding DINO autolabel pipeline at `hooptrack-ball-detection/autolabel/`. Likely a Python script using Supabase service-role credentials. Not CV-A's job.
3. **When to trigger the next CV-B retrain**. Reference spec gates CV-B on ≥ 2k frames × ≥ 20 sessions. We'll eyeball via Supabase Studio; no code path needed.
4. **Game-mode privacy**. SP1 game sessions include other players' torsos in the recorded video (and therefore in uploaded frames). Dev-only scope means this is acceptable for now — flagged in `docs/production-readiness.md`. Resolution before App Store: per-player consent + face blurring, or opt-in.
5. **CV-C integration detail**. When CV-C merges, `detections.jsonl` should add smoothed-track samples in addition to raw detection. Additive change to the JSONL schema; doesn't break CV-A first cut.
6. **Retention-bucket TTL in Supabase**. No lifecycle policy defined in this spec — uploaded objects stay indefinitely. Revisit once the bucket starts costing real money.

---

## 12. Exit criteria

CV-A is done when:
- A full Free Shoot session ends and telemetry appears in Supabase Storage on Wi-Fi within 60s, without any manual action
- A session ended offline uploads on next launch once Wi-Fi is available
- `TelemetryUpload` state transitions behave correctly across kill/retry
- Local `Documents/Telemetry/<sessionID>/` is deleted after successful upload
- `FrameSampler` unit tests pass including over-cap decimation priority
- `detections.jsonl` + `manifest.json` shapes match the schemas in §3.1 and §4.5
- `docs/production-readiness.md` carries the "gate or remove before App Store" P0
- Manual QA walkthrough in §8.2 completes end-to-end once

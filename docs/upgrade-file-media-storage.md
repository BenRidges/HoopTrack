# HoopTrack — File & Media Storage Integration Plan

**Date:** 2026-04-12  
**Phase:** Post Phase 5 / Pre Phase 6 Cloud Infrastructure  
**Status:** Planning

---

## 1. Overview

HoopTrack's `CameraService` / `VideoRecordingService` stack already captures session videos to `Documents/Sessions/<uuid>.mov`. Every recording can be up to 300 MB (`HoopTrack.Storage.maxSessionVideoMB`) and is auto-deleted after 60 days (`HoopTrack.Storage.defaultVideoRetainDays`) unless pinned by the user. This is sound on-device housekeeping, but it means a missed session or device swap permanently loses irreplaceable training footage.

Cloud video storage unlocks the following capabilities, each of which is a near-term roadmap requirement:

| Capability | Why it matters |
|---|---|
| **Coach review** | Coaches need to access session videos from their own device without the athlete physically sharing their phone. |
| **Highlight sharing** | Clipping a contested make or personal-best drill run and sharing to social requires the clip to survive off-device. |
| **Cross-device access** | Users who upgrade iPhones, or who use an iPad for training, need their session history to follow them. |
| **Automatic backup** | `videoPinnedByUser = true` sessions currently rely entirely on the device not being lost or reset. |
| **Shot Science replay** | `SessionReplayView` needs a stable URL to stream replays; a local path breaks the moment the local copy is rotated. |

No third-party Swift packages are added. All network calls use `URLSession` natively.

---

## 2. Storage Architecture Decision

### Phase 1 (current plan): Supabase Storage

HoopTrack's roadmap already identifies Supabase as the recommended Postgres + Auth backend. Supabase Storage is built on the same stack: same project dashboard, same Row Level Security model, same JWT for auth. Choosing Supabase Storage for the first cloud video integration minimises infrastructure surface area and avoids introducing a second vendor before scale justifies it.

Supabase Storage uses S3-compatible internals. Every API call from iOS is a standard HTTPS request with a Bearer token — no SDK required.

**Supabase Storage limits (as of April 2026):**
- Free tier: 1 GB storage, 2 GB bandwidth/month
- Pro tier ($25/mo): 100 GB storage, 200 GB bandwidth, then $0.021/GB storage and $0.09/GB egress

At early indie scale (< 200 active users, ~2 sessions/week, ~100 MB/session), the Pro tier comfortably covers 3–4 months of growth before storage costs become material.

### Phase 2 (scale trigger): Cloudflare R2 + Stream

Migrate when any of the following conditions are met:
- Monthly egress from Supabase Storage exceeds $30
- Video transcoding is needed for adaptive bitrate delivery (e.g. coach review on variable mobile connections)
- The highlight-clip feature requires server-side HLS packaging

Cloudflare R2 has **zero egress fees** and an S3-compatible API — the iOS upload code requires no changes, only the endpoint URL and credentials swap. Cloudflare Stream handles upload, transcoding, thumbnail generation, and HLS delivery as a single managed product.

The migration path is covered in sections 8 and 9.

---

## 3. Supabase Storage Setup

### Bucket configuration

Create a single private bucket named `session-videos` in the Supabase project dashboard.

**Settings:**
- **Public:** No (all access via signed URLs)
- **File size limit:** 350 MB (headroom above `HoopTrack.Storage.maxSessionVideoMB`)
- **Allowed MIME types:** `video/quicktime, video/mp4`

### Row Level Security policies

Enable RLS on the `storage.objects` table. Add two policies for the `session-videos` bucket:

```sql
-- Upload: only the authenticated user can write to their own path
CREATE POLICY "Users upload own videos"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'session-videos' AND
  (storage.foldername(name))[1] = auth.uid()::text
);

-- Read: only the authenticated user can read their own videos
CREATE POLICY "Users read own videos"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'session-videos' AND
  (storage.foldername(name))[1] = auth.uid()::text
);
```

### File path convention

```
session-videos/{user_id}/{session_id}.mov
```

Example: `session-videos/a1b2c3d4-…/550e8400-e29b-41d4-a716-446655440000.mov`

This convention means:
- RLS policies only require checking `foldername[0] == auth.uid()`
- A single `LIST` call to `{user_id}/` returns all of a user's videos
- File names are stable and idempotent (re-uploading the same session overwrites the same key)

---

## 4. iOS Upload Implementation

### URLSession background transfers

Session videos are large (50–300 MB). Uploading on the foreground session would block the UI and fail if the user switches apps. Use a `URLSessionConfiguration.background` session so the OS transfers the file even after the app is suspended.

Background uploads require the file to exist at a stable URL before the transfer starts — which is exactly the case here, since `VideoRecordingService` writes the complete `.mov` to `Documents/Sessions/<uuid>.mov` before calling `onRecordingFinished`.

### Retry logic

Use `URLSessionTask`'s built-in retry only for transient network failures. On a non-retryable HTTP error (4xx), surface it to the user rather than silently retrying. On any failure, persist the session ID in an `uploadQueue: [UUID]` so the next app launch resumes the outstanding uploads.

### Integration point: `SessionFinalizationCoordinator`

After the coordinator completes its 7-step pipeline (`finaliseSession`, goal updates, HealthKit, skill rating, badges, notifications), it fires a `VideoUploadService.enqueueUpload(for:)` call as step 8. This is non-fatal: a failed enqueue does not roll back the session record.

```swift
// Inside SessionFinalizationCoordinator.finaliseSession(_:)
// Step 8 — enqueue cloud upload (non-fatal)
if let fileName = session.videoFileName {
    videoUploadService.enqueueUpload(sessionID: session.id, localFileName: fileName)
}
return SessionResult(session: session, badgeChanges: badgeChanges)
```

Add `videoUploadService: VideoUploadService` as an injected dependency in the coordinator's `init`, matching the existing protocol-injection pattern.

---

## 5. VideoUploadService Design

```swift
// VideoUploadService.swift
// Manages background URLSession uploads of session videos to Supabase Storage.
// Phase 6 — cloud video storage.

import Foundation
import Combine

@MainActor final class VideoUploadService: NSObject, ObservableObject {

    // MARK: - Published state

    /// Upload progress per session UUID, 0.0–1.0.
    @Published var uploadProgress: [UUID: Double] = [:]

    /// Session IDs whose upload confirmed cloud-side.
    @Published var completedUploads: Set<UUID> = []

    // MARK: - Private

    private var backgroundSession: URLSession!
    private let supabaseURL: URL
    private let supabaseAnonKey: String
    private var pendingQueue: [UUID] = []   // persisted across launches

    private let documentsDir = FileManager.default.urls(
        for: .documentDirectory, in: .userDomainMask)[0]

    // MARK: - Init

    init(supabaseURL: URL, supabaseAnonKey: String) {
        self.supabaseURL     = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        super.init()

        let config = URLSessionConfiguration.background(
            withIdentifier: "com.hooptrack.app.videoupload")
        config.isDiscretionary          = false   // upload promptly on Wi-Fi
        config.allowsCellularAccess     = false   // default: Wi-Fi only
        config.sessionSendsLaunchEvents = true    // wake app on completion
        backgroundSession = URLSession(
            configuration: config, delegate: self, delegateQueue: nil)

        restorePendingQueue()
    }

    // MARK: - Public API

    /// Enqueue a session video for upload. Safe to call multiple times (idempotent).
    func enqueueUpload(sessionID: UUID, localFileName: String) {
        guard !completedUploads.contains(sessionID) else { return }
        guard !pendingQueue.contains(sessionID) else { return }
        pendingQueue.append(sessionID)
        savePendingQueue()
        startUpload(sessionID: sessionID, localFileName: localFileName)
    }

    /// Call on app launch to resume any uploads that were interrupted.
    func resumePendingUploads(dataService: DataService) {
        for sessionID in pendingQueue {
            guard let session = dataService.fetchSession(id: sessionID),
                  let fileName = session.videoFileName else { continue }
            startUpload(sessionID: sessionID, localFileName: fileName)
        }
    }

    // MARK: - Upload

    func uploadSession(_ session: TrainingSession) async throws {
        guard let fileName = session.videoFileName else {
            throw UploadError.noLocalFile
        }
        let localURL = documentsDir
            .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw UploadError.noLocalFile
        }
        return try await withCheckedThrowingContinuation { continuation in
            enqueueUpload(sessionID: session.id, localFileName: fileName)
            // Continuation is resolved by URLSessionDelegate on completion/failure.
            // For one-shot async callers, observe completedUploads via Combine instead.
            _ = continuation  // placeholder — wire up via Combine in production
        }
    }

    // MARK: - Persistence

    private let queueDefaultsKey = "VideoUploadService.pendingQueue"

    private func savePendingQueue() {
        let strings = pendingQueue.map { $0.uuidString }
        UserDefaults.standard.set(strings, forKey: queueDefaultsKey)
    }

    private func restorePendingQueue() {
        let strings = UserDefaults.standard.stringArray(forKey: queueDefaultsKey) ?? []
        pendingQueue = strings.compactMap { UUID(uuidString: $0) }
    }

    // MARK: - Private helpers

    private func startUpload(sessionID: UUID, localFileName: String) {
        let localURL = documentsDir
            .appendingPathComponent(HoopTrack.Storage.sessionVideoDirectory)
            .appendingPathComponent(localFileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }

        // Retrieve the stored JWT from Keychain (see Auth integration plan)
        guard let jwt = KeychainStore.shared.accessToken,
              let userID = KeychainStore.shared.userID else { return }

        let remotePath = "\(userID)/\(sessionID.uuidString).mov"
        let uploadURL  = supabaseURL
            .appendingPathComponent("storage/v1/object")
            .appendingPathComponent("session-videos")
            .appendingPathComponent(remotePath)

        var request              = URLRequest(url: uploadURL)
        request.httpMethod       = "PUT"
        request.setValue("Bearer \(jwt)",         forHTTPHeaderField: "Authorization")
        request.setValue(supabaseAnonKey,          forHTTPHeaderField: "apikey")
        request.setValue("video/quicktime",        forHTTPHeaderField: "Content-Type")
        request.setValue("max-age=0",              forHTTPHeaderField: "Cache-Control")

        let task = backgroundSession.uploadTask(with: request, fromFile: localURL)
        task.taskDescription = sessionID.uuidString
        task.resume()
    }

    // MARK: - Error types

    enum UploadError: Error {
        case noLocalFile
        case serverError(Int)
        case authMissing
    }
}

// MARK: - URLSessionDelegate

extension VideoUploadService: URLSessionTaskDelegate, URLSessionDelegate {

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64,
                                totalBytesExpectedToSend: Int64) {
        guard let idString = task.taskDescription,
              let id = UUID(uuidString: idString),
              totalBytesExpectedToSend > 0 else { return }
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor [weak self] in
            self?.uploadProgress[id] = progress
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        guard let idString = task.taskDescription,
              let id = UUID(uuidString: idString) else { return }
        if let error {
            // Non-retryable errors (e.g. 403 auth) are left in the pending queue
            // for the user to resolve. Transient errors will be retried on next launch.
            print("[VideoUploadService] Upload failed for \(id): \(error)")
            return
        }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
            print("[VideoUploadService] Server error \(statusCode) for \(id)")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.completedUploads.insert(id)
            self.uploadProgress.removeValue(forKey: id)
            self.pendingQueue.removeAll { $0 == id }
            self.savePendingQueue()
            // Notify DataService to mark session as cloud-uploaded
            NotificationCenter.default.post(
                name: .videoUploadDidComplete,
                object: id)
        }
    }

    nonisolated func urlSessionDidFinishEvents(
        forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            // Call the background completion handler stored in AppDelegate
            if let handler = BackgroundUploadCompletionStore.shared.handler {
                handler()
                BackgroundUploadCompletionStore.shared.handler = nil
            }
        }
    }
}

extension Notification.Name {
    static let videoUploadDidComplete = Notification.Name("VideoUploadDidComplete")
}
```

**AppDelegate wiring** (required for background session wake-up):

```swift
// In AppDelegate or HoopTrackApp scene phase handler:
func application(_ application: UIApplication,
                 handleEventsForBackgroundURLSession identifier: String,
                 completionHandler: @escaping () -> Void) {
    if identifier == "com.hooptrack.app.videoupload" {
        BackgroundUploadCompletionStore.shared.handler = completionHandler
    }
}

// Lightweight store for the OS-provided completion handler
final class BackgroundUploadCompletionStore {
    static let shared = BackgroundUploadCompletionStore()
    var handler: (() -> Void)?
}
```

---

## 6. Local-to-Cloud Sync

### New fields on `TrainingSession`

Add two new properties to the `TrainingSession` SwiftData model:

```swift
// MARK: - Cloud Storage (Phase 6)
var cloudUploaded: Bool        // true once Supabase confirms the upload
var cloudUploadedAt: Date?     // timestamp of confirmed upload
```

Add a migration in `HoopTrackMigrationPlan.swift` (SwiftData `VersionedSchema`) to populate `cloudUploaded = false` for all existing sessions.

### Upload queue behaviour

The background upload queue should follow these rules:

1. **Enqueue on session end.** `SessionFinalizationCoordinator` enqueues after the local save completes.
2. **Wi-Fi only by default.** `config.allowsCellularAccess = false`. Expose a user toggle in Settings to allow cellular uploads.
3. **Respect `videoPinnedByUser`.** Pinned videos are uploaded with higher priority (moved to front of the queue).
4. **Auto-delete local copy after confirmed upload.** Once `cloudUploaded = true` is set and `videoPinnedByUser = false`, the local `.mov` file is eligible for the existing 60-day retention sweep in `DataService`. For pinned sessions, keep the local copy indefinitely.
5. **Never delete the local copy before upload is confirmed.** The cloud path must be verified (HTTP 2xx) before the local file becomes deletable.

```swift
// DataService extension — call from NotificationCenter observer
func markSessionCloudUploaded(sessionID: UUID) throws {
    guard let session = fetchSession(id: sessionID) else { return }
    session.cloudUploaded   = true
    session.cloudUploadedAt = .now
    // Schedule local file for deletion on next retention sweep if not pinned
    if !session.videoPinnedByUser {
        scheduleLocalVideoCleanup(for: session)
    }
    try modelContext.save()
}
```

### Retention sweep

The existing video retention sweep (currently deletes files older than 60 days) should be updated to also delete the local copy of any session where `cloudUploaded == true && !videoPinnedByUser`, regardless of age. This frees device storage faster after a successful upload.

---

## 7. Video Streaming and Playback

### Signed URL generation

Supabase Storage supports signed URLs with a configurable expiry. Never expose permanent public URLs — all playback goes through time-limited signed URLs.

**iOS call to generate a signed URL:**

```swift
func signedPlaybackURL(for session: TrainingSession,
                       expiresIn seconds: Int = 3600) async throws -> URL {
    guard let jwt = KeychainStore.shared.accessToken,
          let userID = KeychainStore.shared.userID else {
        throw UploadError.authMissing
    }
    let remotePath = "\(userID)/\(session.id.uuidString).mov"
    let endpoint   = supabaseURL
        .appendingPathComponent("storage/v1/object/sign")
        .appendingPathComponent("session-videos")
        .appendingPathComponent(remotePath)

    var request        = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    request.setValue(supabaseAnonKey, forHTTPHeaderField: "apikey")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody   = try JSONEncoder().encode(["expiresIn": seconds])

    let (data, _) = try await URLSession.shared.data(for: request)
    struct SignedURLResponse: Decodable { let signedURL: String }
    let response = try JSONDecoder().decode(SignedURLResponse.self, from: data)
    guard let url = URL(string: supabaseURL.absoluteString + response.signedURL) else {
        throw UploadError.serverError(0)
    }
    return url
}
```

### AVPlayer integration in `SessionReplayView`

```swift
// SessionReplayView — Phase 6 update
.task {
    if session.cloudUploaded {
        let url = try? await videoUploadService.signedPlaybackURL(for: session)
        player = url.map { AVPlayer(url: $0) }
    } else if let fileName = session.videoFileName {
        // Fall back to local file
        let localURL = localVideoURL(fileName: fileName)
        player = AVPlayer(url: localURL)
    }
}
```

### URL expiry strategy

| Context | Expiry |
|---|---|
| `SessionReplayView` inline playback | 1 hour (3600 s) — refreshed on each view appearance |
| Coach review share link | 7 days (604800 s) — generated at share time, stored in the share payload |
| Highlight clip export preview | 15 minutes (900 s) — ephemeral |

**Caching policy:** Do not cache signed URLs on disk — they are short-lived and tied to the user's auth token. Cache in-memory only (as a `@State var` on the view), and regenerate on each view appearance if the URL is expired or absent.

---

## 8. Cloudflare R2 Migration Path

### When to migrate

Trigger evaluation when **any** of these conditions hold for two consecutive months:
- Supabase Storage egress exceeds $20/month
- Monthly active users > 2,000
- Highlight-clip or coach-review features require transcoding (Supabase Storage does not transcode)

### How to migrate

Because Supabase Storage's upload API is S3-compatible, the iOS `VideoUploadService` requires no code changes — only the endpoint URL and credentials change:

**Before (Supabase):**
```
PUT https://<project>.supabase.co/storage/v1/object/session-videos/{user_id}/{session_id}.mov
Authorization: Bearer <supabase_jwt>
apikey: <supabase_anon_key>
```

**After (R2 via S3-compatible API):**
```
PUT https://<account>.r2.cloudflarestorage.com/session-videos/{user_id}/{session_id}.mov
Authorization: AWS4-HMAC-SHA256 ...
```

Swap the URL and auth header builder. All delegate methods, progress reporting, and queue logic remain identical.

**Migration steps:**
1. Create R2 bucket `session-videos` in Cloudflare dashboard.
2. Enable S3 API compatibility on the bucket and generate an R2 API token.
3. Write a one-time migration script (server-side) to copy existing objects from Supabase Storage to R2 using `rclone` or the AWS CLI with both remotes configured.
4. Deploy a small API endpoint that generates R2 presigned URLs (equivalent to Supabase's `/object/sign`), since R2 presigned URL generation requires HMAC signing on the server.
5. Update `VideoUploadService` with the new endpoint URL and auth scheme.
6. Validate with a canary group before rolling out.

R2 public egress pricing: $0/GB (zero egress fees). Storage: $0.015/GB/month.

---

## 9. Cloudflare Stream for Transcoding

### Why transcoding matters

Session videos are recorded at 720p/60fps as `.mov` files. On variable mobile connections (coach reviewing from a coffee shop), a 150 MB raw `.mov` produces stuttering playback. HLS adaptive bitrate streaming solves this by serving lower-quality segments when bandwidth is constrained.

Cloudflare Stream handles: upload → transcoding → HLS packaging → delivery via Cloudflare's CDN — all in one product.

### Upload flow with Stream

Replace the direct R2 `PUT` upload with a Stream-specific upload URL:

```swift
// 1. Request a one-time upload URL from your backend
// (backend calls: POST https://api.cloudflare.com/client/v4/accounts/{account}/stream/direct_upload)
struct StreamUploadURLResponse: Decodable {
    let uploadURL: String
    let uid: String   // Cloudflare Stream video UID
}

// 2. PUT the .mov file to the upload URL (same background URLSession pattern)
// No auth headers needed — the upload URL is pre-signed.

// 3. Store stream.uid on TrainingSession for later playback
// var cloudStreamUID: String?   (new field, Phase 6B)
```

### Transcoding completion webhook

Configure a Stream webhook in the Cloudflare dashboard pointing to your backend:

```
POST https://api.yourbackend.com/webhooks/stream
{
  "uid": "abc123...",
  "status": { "state": "ready" },
  "playback": {
    "hls": "https://customer-<hash>.cloudflarestream.com/abc123.../manifest/video.m3u8"
  }
}
```

When the webhook fires with `state: "ready"`:
1. Backend looks up the `TrainingSession` by `cloudStreamUID`.
2. Stores the HLS manifest URL on the session record.
3. Sends a push notification to the user: "Your session replay is ready."

### HLS playback in `SessionReplayView`

```swift
// AVPlayer handles HLS natively — no code changes beyond swapping the URL
if let hlsURLString = session.cloudHLSURL,
   let hlsURL = URL(string: hlsURLString) {
    player = AVPlayer(url: hlsURL)
} else {
    // Fall back to signed R2 URL while transcoding is in progress
    player = AVPlayer(url: signedR2URL)
}
```

### Stream pricing (as of April 2026)

- $5/month per 1,000 minutes of stored video
- $1 per 1,000 minutes of delivered video
- No egress fees (delivery via Cloudflare CDN)

A 30-minute session = 30 minutes stored. At 1,000 active users with 2 sessions/week, monthly storage = 240,000 minutes = $1,200/month at $5/1k. This is the cost trigger for evaluating per-user storage caps or a freemium model where only pinned sessions get transcoded.

---

## 10. Highlight Clip Export

### Trimming clips with AVFoundation

```swift
// HighlightExportService.swift
// Phase 6 — trims a clip from a session recording and overlays stats.

import AVFoundation
import UIKit

@MainActor final class HighlightExportService {

    enum ExportError: Error {
        case noSourceFile
        case compositionFailed
        case exportFailed(String)
    }

    /// Trim a clip from [startTime, endTime] and overlay a stats graphic.
    func exportHighlight(
        sourceURL: URL,
        startTime: CMTime,
        endTime: CMTime,
        stats: HighlightStats
    ) async throws -> URL {
        let asset     = AVURLAsset(url: sourceURL)
        let duration  = try await asset.load(.duration)
        let clampedEnd = CMTimeMinimum(endTime, duration)

        // Composition
        let composition = AVMutableComposition()
        guard
            let videoTrack = try await asset.loadTracks(withMediaType: .video).first,
            let compVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.compositionFailed }

        let timeRange = CMTimeRange(start: startTime, end: clampedEnd)
        try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        // Audio (optional — keep original audio)
        if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first,
           let compAudioTrack = composition.addMutableTrack(
               withMediaType: .audio,
               preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
        }

        // Stats overlay via AVVideoComposition + CIFilter / Core Graphics
        let videoComposition = try await makeStatsOverlay(
            for: composition, track: compVideoTrack, stats: stats)

        // Export to a temp file
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("highlight_\(UUID().uuidString).mp4")

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.compositionFailed
        }
        exporter.outputURL           = outputURL
        exporter.outputFileType      = .mp4
        exporter.videoComposition    = videoComposition
        exporter.shouldOptimizeForNetworkUse = true

        await exporter.export()
        if let error = exporter.error {
            throw ExportError.exportFailed(error.localizedDescription)
        }
        return outputURL
    }

    // MARK: - Stats overlay

    private func makeStatsOverlay(
        for composition: AVMutableComposition,
        track: AVMutableCompositionTrack,
        stats: HighlightStats
    ) async throws -> AVVideoComposition {
        let naturalSize = try await track.load(.naturalSize)

        // Draw stats card as a CGImage using Core Graphics
        let overlayImage = renderStatsCard(stats: stats, size: naturalSize)

        let overlayLayer   = CALayer()
        overlayLayer.contents  = overlayImage
        overlayLayer.frame     = CGRect(
            x: 16, y: 16,
            width: naturalSize.width * 0.45,
            height: 80)

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: naturalSize)

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: naturalSize)
        parentLayer.addSublayer(videoLayer)
        parentLayer.addSublayer(overlayLayer)

        return AVVideoComposition(
            propertiesOf: composition,
            completionHandler: { request in
                request.finish(with: request.sourceImage, context: nil)
            })
        // NOTE: For a production overlay, use AVVideoCompositionCoreAnimationTool
        // with the parentLayer/videoLayer setup above instead of the closure form.
    }

    private func renderStatsCard(stats: HighlightStats, size: CGSize) -> CGImage? {
        let width  = Int(size.width  * 0.45)
        let height = 80
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // Semi-transparent dark background
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Stats text — use NSAttributedString for rich styling
        let text  = "\(stats.fgPctString) FG  |  \(stats.madeString) made"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: UIColor.white
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let line    = CTLineCreateWithAttributedString(attrStr)
        ctx.textPosition = CGPoint(x: 12, y: 28)
        CTLineDraw(line, ctx)

        return ctx.makeImage()
    }
}

struct HighlightStats {
    let fgPctString: String    // e.g. "67%"
    let madeString: String     // e.g. "8/12"
    let drillType: String      // e.g. "Free Shoot"
}
```

### Share sheet integration

```swift
// In SessionSummaryView or SessionReplayView
Button("Share Highlight") {
    Task {
        let sourceURL  = localVideoURL(fileName: session.videoFileName ?? "")
        let clipURL    = try await highlightExportService.exportHighlight(
            sourceURL: sourceURL,
            startTime: CMTime(seconds: highlightStart, preferredTimescale: 600),
            endTime:   CMTime(seconds: highlightEnd,   preferredTimescale: 600),
            stats: HighlightStats(
                fgPctString: "\(Int(session.fgPercent))%",
                madeString:  "\(session.shotsMade)/\(session.shotsAttempted)",
                drillType:   session.drillType.displayName))
        showShareSheet(url: clipURL)
    }
}

private func showShareSheet(url: URL) {
    let controller = UIActivityViewController(
        activityItems: [url], applicationActivities: nil)
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?.windows.first?
        .rootViewController?.present(controller, animated: true)
}
```

**Notes:**
- Exported highlights are MP4 (`.mp4`) for maximum compatibility with Instagram Reels and TikTok, even though source recordings are `.mov`.
- Temp files are written to `FileManager.default.temporaryDirectory` and are eligible for OS cleanup; do not persist them.
- For Phase 6B, add automatic moment detection: identify the 30 seconds around a shot make event using `ShotRecord.timestamp` offsets against `TrainingSession.startedAt`.

---

## 11. Storage Cost Model

All figures are estimates based on:
- Average session video: **100 MB** (15 min at 720p/60fps, H.264)
- Sessions per active user per week: **2**
- Retention: **50% of sessions** uploaded to cloud (remaining 50% auto-deleted locally without upload, or user opted out)

### Supabase Storage

| Scale | Monthly uploads | Storage (cumulative, 60-day window) | Egress (playback) | Monthly cost |
|---|---|---|---|---|
| 100 MAU | ~800 sessions × 50 MB avg compressed = **40 GB** | **~80 GB** | ~20 GB | ~$2–4 (Pro tier: 200 GB bandwidth incl.) |
| 1,000 MAU | **400 GB uploads** | **~800 GB** | ~200 GB | ~$25 base + $180 storage + $0 bandwidth (within 200 GB) ≈ **~$225/mo** |
| 10,000 MAU | **4 TB uploads** | **~8 TB** | ~2 TB | ~$25 + $1,680 storage + $162 egress ≈ **~$1,900/mo** |

At 1,000 MAU, Supabase Storage costs become meaningful. This is the migration-to-R2 trigger.

### Cloudflare R2 (post-migration)

| Scale | Storage | Egress | Monthly cost |
|---|---|---|---|
| 1,000 MAU | ~800 GB | ~200 GB | $12 storage + **$0 egress** = **~$12/mo** |
| 10,000 MAU | ~8 TB | ~2 TB | $120 storage + **$0 egress** = **~$120/mo** |

R2's zero egress model is the primary driver of migration. At 10,000 MAU the cost difference is roughly $1,780/month.

### Cloudflare Stream (transcoding tier)

| Scale | Stored minutes | Delivered minutes | Monthly cost |
|---|---|---|---|
| 1,000 MAU | 60,000 min | 120,000 min | $300 storage + $120 delivery = **~$420/mo** |
| 10,000 MAU | 600,000 min | 1.2M min | $3,000 + $1,200 = **~$4,200/mo** |

Stream is appropriate only when the per-user value of adaptive playback (coach review, highlight sharing) justifies the cost. At 1,000 MAU with a $5/month premium tier, Stream breaks even at ~84 paying users covering the infrastructure cost.

### Practical recommendation

| Phase | Infrastructure | Est. cost |
|---|---|---|
| 0–500 MAU | Supabase Storage | $25–50/mo |
| 500–2,000 MAU | Supabase Storage | $50–225/mo |
| 2,000+ MAU | Cloudflare R2 | $25–120/mo |
| Transcoding needed | + Cloudflare Stream | + $400–4,200/mo |

Introduce per-user storage caps (e.g. 5 GB free, unlimited on premium) before the 2,000 MAU tier to protect against outlier users with 100+ pinned sessions.

---

## Appendix — New Constants

Add to `HoopTrack/Utilities/Constants.swift` under `HoopTrack.Storage`:

```swift
enum Storage {
    static let sessionVideoDirectory   = "Sessions"
    static let maxSessionVideoMB       = 300
    static let defaultVideoRetainDays  = 60

    // Phase 6 — cloud storage
    static let uploadBackgroundSessionID  = "com.hooptrack.app.videoupload"
    static let signedURLExpirySeconds     = 3600       // 1 hour for playback
    static let coachShareURLExpirySeconds = 604_800    // 7 days for share links
    static let cloudBucketName            = "session-videos"
}
```

## Appendix — New `TrainingSession` Fields (SwiftData migration required)

```swift
// Phase 6 — Cloud Storage fields
var cloudUploaded: Bool        // default: false
var cloudUploadedAt: Date?     // nil until confirmed
var cloudStreamUID: String?    // Cloudflare Stream UID (Phase 6B)
var cloudHLSURL: String?       // HLS manifest URL after transcoding (Phase 6B)
```

Add a `SchemaMigrationStage` in `HoopTrackMigrationPlan.swift` that sets `cloudUploaded = false` and `cloudUploadedAt = nil` for all existing `TrainingSession` rows.

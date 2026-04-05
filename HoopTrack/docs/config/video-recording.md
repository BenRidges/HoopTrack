# Video Recording — Configuration

Session video is recorded automatically during every live session and used for Shot Science replay.

## Storage

- Location: `<app Documents>/Sessions/<session-UUID>.mov`
- Format: H.264 (AVCaptureMovieFileOutput default)
- Approximate size: < 300 MB per 30-minute session

## Retention

Auto-deletion is handled by `DataService.purgeOldVideos(olderThanDays:)`.
Default retention: 60 days (configurable via `HoopTrack.Storage.defaultVideoRetainDays`).
Users can pin a video permanently by setting `TrainingSession.videoPinnedByUser = true`.

## No-video fallback

If recording fails (disk full, AVCaptureSession error), `TrainingSession.videoFileName` remains nil.
`SessionSummaryView` and `SessionReplayView` both check for nil before showing the Replay button — no crash.

## Testing

To test replay without a full session, copy any `.mov` file to the simulator's Documents/Sessions/ directory
and set a `TrainingSession.videoFileName` to match in the SwiftData store via a debug route or unit test fixture.

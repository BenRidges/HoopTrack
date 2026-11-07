# Tools/cv — run the app's shot recognition on a video

`cv-replay` (in `Tools/HoopTrackCore`, macOS only) feeds a video file through
the shipped pipeline — `CVPipeline` with `CoreMLBallDetector` on
`ML/BallDetector.mlmodel`, `CourtCalibrationService`, `ShotTracker`,
`NetWatch`/`NetCheck`, `DetectionRegion` crops — and writes what the app
would have logged and called, plus annotated frames and a check that
`shot-eval` tells the same story from the log (log-replay consistency).

`replay.sh` drives it from a machine without Swift (the Linux PC) over ssh.

## From the Linux PC

```
Tools/cv/replay.sh <video> [labels.csv] [out-dir] [-- cv-replay options]

Tools/cv/replay.sh ~/Projects/hoop-footage/gym.mp4
Tools/cv/replay.sh clip.mp4 clip.labels.csv
Tools/cv/replay.sh clip.mp4 - /tmp/clip -- --stride 2 --fov 64   # "-" = no labels
```

It syncs the whole repo to the Mac (`rsync --delete`; the package is built
from symlinks into the app sources, so syncing only the package would leave
them dangling), copies the video unless the same file is already in the
Mac's `~/Projects/hoop-footage`, builds `cv-replay` and `shot-eval` (debug),
runs, copies the results back (default `/tmp/cv-replay/<clip name>/`),
cleans up on the Mac and prints `summary.txt`.

| Variable | Default | |
|---|---|---|
| `CV_REPLAY_HOST` | `macbook` | ssh host |
| `CV_REPLAY_DIR` | `Projects/wt-replay` | repo copy on the Mac, relative to its home. Videos and results go in its `.replay/` (kept out of the `--delete`). |
| `CV_REPLAY_FOOTAGE` | `~/Projects/hoop-footage` | local footage folder that is mirrored on the Mac |
| `CV_REPLAY_MAC_FOOTAGE` | `Projects/hoop-footage` | the Mac's copy, relative to its home; a video under the local folder that's there at the same path and size is used in place, never copied or deleted |
| `CV_REPLAY_KEEP` | unset | `1` keeps a video this run copied, for the next run (one already there is never removed) |

`labels.csv` is the `shot-eval` format: `seconds,make|miss` per shot, at the
moment the ball reaches the rim, in seconds of the video.

## On a Mac

```
cd Tools/HoopTrackCore
swift build                                   # cv-replay + shot-eval
.build/debug/cv-replay clip.mp4 --labels clip.labels.csv --out /tmp/clip
```

| Option | |
|---|---|
| `--out DIR` | output directory (default `./cv-replay-out/<clip>`) |
| `--labels FILE` | score the calls against `labels.csv` (`ShotEvaluation`) |
| `--stride N` | feed every Nth frame (default every frame). The tracker works from timestamps, so it copes, but it's a 30/N or 60/N fps camera, not the app. |
| `--start S`, `--duration S` | process part of the video. Outputs stay in video seconds; labels outside the part are left out of the score. |
| `--fit letterbox\|crop` | how a video that isn't 16:9 fills the 1280×720 frame (below) |
| `--fov DEG` | camera horizontal field of view for court position and distance (default 68, the app's fallback when the camera doesn't report one). Wrong FOV scales distances. |
| `--court nba\|ncaa\|fiba\|hs` | three-point distance for zones (default NBA) |
| `--model PATH` | a different `.mlmodel` / `.mlpackage` / `.mlmodelc` (default: the app's, compiled at start-up like Xcode does) |
| `--pts-offset S` | add S seconds to every timestamp before the pipeline sees it, as the camera's host-clock timestamps are (the log still starts at 0). Exercises the time shift between live and log; outputs stay in video seconds. |
| `--frame-cost-ms N` | drop late frames as the phone does: a frame that arrives while the previous one would still be in `process()` (N ms each — a phone figure, not the Mac's) is skipped and counted (below) |
| `--pause A-B[,C-D]` | pause the session from A to B s of the video, as the pause button does (`CVPipeline.isPaused`): the shot in the air is dropped, a call waiting for the net is settled. The replay and `shot-eval --pause` are told, since the log can't show a pause. |
| `--keep-video` | keep the HEVC video `SessionRecorder` wrote, as `session.mov` |
| `--no-strips` | skip the PNGs |
| `--shot-eval PATH` | `shot-eval` binary (default: next to `cv-replay`) |

About 60–100 frames/s on an M2 MacBook with 8 GB, depending on what else
it's doing (debug build; the detector takes ~8–14 ms a frame on the Mac's
GPU / Neural Engine), so a 60 fps clip runs at about real time. The summary
reports the rate, the time of the whole of `process()` per frame (not just
the detector), and where Core ML's compute plan puts the model.

## Same as the app, and not

The pipeline is built exactly as `LiveSessionViewModel.startTracking` builds
it: `CVPipeline(detector:threePointDistanceFt:fieldOfView:)`, a
`SessionRecorder` as `recorder`, `publishesBall` off, a `DetectionLogger` via
`attachTelemetry`, then `start(framePublisher:delegate:)`, and `stop()` at the
end as `end()` does. Frames go through a `PassthroughSubject` from one serial
queue, one at a time, synchronously, as `CameraService`'s capture callback
sends them. After each frame the queue waits on the main queue, so the
delegate calls that frame caused (`Task { @MainActor … }`) have run before
the next frame: every call is pinned to its frame. At the end `stop()` hands
back what the delegate hasn't been given — a call still waiting for the net
check, settled with the footage there is — and the harness records it, as
`end()` does (`shots.csv` / `consistency.txt` show it as published at `end`).

**Late frames.** On the phone, `alwaysDiscardsLateVideoFrames` is on and
`CVPipeline` does all its work synchronously on the delivery queue, so a
frame that arrives while the previous one is still being processed is
discarded. The harness feeds every frame however long each takes, which is
the phone only while `process()` stays under the frame interval (16.7 ms at
60 fps). `--frame-cost-ms N` models the phone with a virtual clock: a frame
whose timestamp is before the previous processed frame's timestamp + N ms is
skipped and counted. The summary also gives `process()` time per frame on
the Mac and how many frames a camera would drop at those times.

Frames:

- decoded with `AVAssetReader` straight to
  `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` (the app's capture format;
  `NetWatch` reads its luma plane), with the file's own presentation
  timestamps (variable frame rate is fine);
- turned upright by the track's `preferredTransform` (quarter turns and
  mirrors, done with vImage on the Y and CbCr planes);
- fitted into **1280×720**: 16:9 video is scaled to fill it; 1280×720
  upright video is passed through untouched. Other shapes are
  **letterboxed / pillarboxed with black** by default (the whole picture is
  kept at its true shape, so the tracker's 16:9 geometry is right for it, but
  it gets fewer pixels), or with `--fit crop` scaled to fill and
  centre-cropped. Portrait video ends up as a narrow pillar — the app never
  sees portrait (it's landscape-right only).
- the source's colour description (matrix, primaries, transfer) is kept, so
  Vision converts to RGB as it would.

Differences that remain:

- **Camera vs file.** No camera ISP, and compression artefacts; a 1080p clip
  is downscaled with Lanczos, not by the sensor. HDR (HLG / Dolby Vision)
  clips are decoded to 8-bit as is, so they look flat to the model. The
  summary lists every way the source differs from the camera's frames
  (**Source differs from the app's camera**): a frame rate other than 60
  (NetWatch's per-frame activity and ShotTracker's `dt × 30` gates change
  with it — two of the four labelled clips are 30 fps), variable frame rate,
  HDR / 10-bit, letterboxing or cropping, missing or non-BT.709 colour tags.
- **Mac Core ML.** Same model, same `VNCoreMLRequest`, but not the phone's
  stack: the Mac's GPU / Neural Engine (the summary records the chip and
  Core ML's compute plan), its macOS release rather than the phone's iOS
  (Vision's resampling and Core ML's op lowering can differ), and the model
  compiled at run time with `MLModel.compileModel` where the app ships
  Xcode's build of it. Confidences are close to a phone's, not
  bit-identical; a detection right at a threshold (ball 0.30, hoop 0.45)
  can flip. Only running a phone's own session video against its own
  `detections.jsonl` would measure this, and the harness doesn't do that yet.
- **Field of view** isn't in the file: set `--fov` for meaningful distances.
- **Thermal shedding** follows the Mac's thermal state, so it can change from
  run to run on a busy Mac. The summary counts the frames shed and the
  verdict line says when a result depended on it. `--stride 2` is the
  deterministic stand-in for a phone at `.serious` (the pipeline then skips
  every other frame before detection).
- **Pauses** happen only with `--pause`. A phone's session video keeps
  recording through pauses, so replaying one without `--pause` detects shots
  in stretches the app ignored.
- **A probe around the detector.** `CVPipeline` gets a `DetectorProbe` that
  calls `CoreMLBallDetector` and returns its result untouched; it only times
  inference and keeps every hoop candidate.
- `DetectionLogger` and `SessionRecorder` write under `~/Documents`; the
  harness points `CFFIXED_USER_HOME` at a scratch folder in the output
  directory first and moves the files out, so the Mac's Documents stay clean.
  Both make their folders with `FileProtectionType.complete`, and while the
  Mac's screen is locked (normal over ssh) nothing can be created inside such
  a folder, so the harness makes the two folders first, unprotected.

## Outputs

| File | |
|---|---|
| `detections.jsonl` | the telemetry log, written by `DetectionLogger` — the same format a phone writes, readable by `shot-eval` |
| `shots.csv` | one row per call the delegate received, in order: `time_s` (ball at the rim, video seconds — the labels' convention; from the matching replay call), `published_s` (frame that published it), then as the delegate got it: `video_offset_s` (release, seconds into the session video), result, confidence, `flagged` (< 0.6, the app's "Check"), zone, court x/y, distance, release angle, speed; `release_s`, `matches_replay` |
| `summary.txt` | video and conversion, the Mac (OS, chip, Core ML compute plan), how the source differs from the camera's frames, frames decoded / dropped as late / fed / paused / shed / logged, frames/s, `process()` and detector time per frame, thermal, % of frames with the hoop tracked (the state the delegate saw) and with the detector's rim box, % with ≥ 1 ball, ball box sizes in px (all candidates and the tracked shot ball), shots, the log-replay consistency verdict, score |
| `consistency.txt` | the call-by-call comparison below |
| `shot-eval.txt` | `shot-eval`'s own output on `detections.jsonl` (and the labels, shifted to log time if needed) |
| `strips/shot-NN-<result>.png` | per call: frames at release, apex, rim, rim + 0.5 s — the whole frame at half size and a 1:1 close-up |
| `strips/overview.png` | four frames across the run, same overlays — a quick check even when nothing was called |
| `session.mov` | with `--keep-video` |

Strip colours: yellow ball candidates (confidence in the close-up), orange
the tracker's shot ball (its last accepted box, so it trails the ball when a
frame has no detection), cyan the detector's top hoop (the log's `rb`),
blue other hoops, green the smoothed hoop from the log replay (thick dashed
green: the hoop the live pipeline last published to the delegate), white
dashed the rim the shot is judged against (held from release), magenta
dashed the detection crop.
Boxes are drawn from the Vision-normalised log values (origin bottom-left),
so a box off the ball means the coordinates are off.

## Log-replay consistency: live vs replay

Tuning happens offline: `shot-eval` replays `detections.jsonl` through
`ShotReplay.run`. That's only useful if the replay makes the calls the app
made. Each run checks it — the Mac's pipeline against a replay of the log
that same pipeline wrote. It is not a comparison with a phone: it can't see
how a phone's detections or frame timing would differ (above).

1. `shot-eval` (the binary) on the log vs `ShotReplay.run` in process;
2. the harness's own frame-by-frame trace of `ShotReplay.run` (to know which
   frame published each call and its release time) vs `ShotReplay.run`;
3. each call the delegate received vs the replay's: same publishing frame,
   same release time (`videoOffset`), same result, same confidence
   (tolerance 1e-9; times 1e-6 s).

Also compared: shot starts (frames), the hoop state frame by frame, and the
hoop rect itself at every update the delegate got (two different hoops can
both be "tracking"). With every basket logged, it also counts the frames
where a replay from the top basket only — all logs kept before — would
have followed another hoop. Anything different is listed in
`consistency.txt` and summarised in `summary.txt` as **MISMATCH**; frames
the Mac's thermal state shed are named in the verdict.

Known ways the two can differ:

- **A call held at the end** no longer differs. An unsure call waits up to
  0.7 s for the net; if the session ends inside that wait, `CVPipeline.stop()`
  settles it with the footage there is and the session records it, and
  `ShotReplay.run` flushes it the same way at the end of the log. (Until
  November 2026 the app dropped it and `shot-eval` counted a shot the app
  never logged; logs from phones on older builds can still show that.)
- **Two hoops in view, in older logs.** The detector returns up to three
  hoops and `CourtCalibrationService` picks the one overlapping the hoop it
  tracks (or the biggest). Logs now keep all of them (`rs`) and the replay
  chooses among them the same way; logs from before kept only the most
  confident (`rb`), so a replay of one can lock onto another hoop. The
  summary counts frames with 2+ hoops.
- The log's `cv` field holds one published call per frame (the last); a
  frame that publishes two logs one. `shot-eval` recomputes calls and doesn't
  read it.

## Smoke test without footage

```
python3 -I Tools/cv/synth_clip.py /tmp/synth.mp4 [--shots 16] [--rotate 90] [--size 960x720]
Tools/cv/replay.sh /tmp/synth.mp4 /tmp/synth.labels.csv
```

draws a cartoon gym (backboard, rim, net that swings after a make, a ball
alternating makes and misses) and writes its labels. The shipped detector
does find this ball and hoop, so it exercises everything end to end; it says
nothing about accuracy on real footage. `--rotate` stores the frames turned
and tags the file (`preferredTransform`), as a phone does.

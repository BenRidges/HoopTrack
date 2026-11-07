# Tools/cv — run the app's shot recognition on a video

`cv-replay` (in `Tools/HoopTrackCore`, macOS only) feeds a video file through
the shipped pipeline — `CVPipeline` with `CoreMLBallDetector` on
`ML/BallDetector.mlmodel`, `CourtCalibrationService`, `ShotTracker`,
`NetWatch`/`NetCheck`, `DetectionRegion` crops — and writes what the app
would have logged and called, plus annotated frames and a check that
`shot-eval` tells the same story from the log.

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
| `--keep-video` | keep the HEVC video `SessionRecorder` wrote, as `session.mov` |
| `--no-strips` | skip the PNGs |
| `--shot-eval PATH` | `shot-eval` binary (default: next to `cv-replay`) |

About 60–100 frames/s on an M2 MacBook with 8 GB, depending on what else
it's doing (debug build; the detector takes ~8–12 ms a frame on the Mac's
GPU / Neural Engine), so a 60 fps clip runs at about real time. The summary
reports the rate.

## Same as the app, and not

The pipeline is built exactly as `LiveSessionViewModel.startTracking` builds
it: `CVPipeline(detector:threePointDistanceFt:fieldOfView:)`, a
`SessionRecorder` as `recorder`, `publishesBall` off, a `DetectionLogger` via
`attachTelemetry`, then `start(framePublisher:delegate:)`, and `stop()` at the
end as `end()` does. Frames go through a `PassthroughSubject` from one serial
queue, one at a time, synchronously, like `CameraService`'s capture callback.
After each frame the queue waits on the main queue, so the delegate calls
that frame caused (`Task { @MainActor … }`) have run before the next frame:
every call is pinned to its frame and nothing is lost at the end.

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
  clips are decoded to 8-bit as is, so they look flat to the model.
- **Mac Core ML.** Same model, same `VNCoreMLRequest`, but the Mac's GPU /
  Neural Engine: confidences are close to a phone's, not bit-identical. A
  detection right at a threshold (ball 0.30, hoop 0.45) can flip.
- **Field of view** isn't in the file: set `--fov` for meaningful distances.
- **Thermal shedding** follows the Mac's thermal state (the summary shows
  it, and frames the pipeline skipped).
- **A probe around the detector.** `CVPipeline` gets a `DetectorProbe` that
  calls `CoreMLBallDetector` and returns its result untouched; it only times
  inference and keeps every hoop candidate (the log keeps one).
- `DetectionLogger` and `SessionRecorder` write under `~/Documents`; the
  harness points `CFFIXED_USER_HOME` at a scratch folder in the output
  directory first and moves the files out, so the Mac's Documents stay clean.

## Outputs

| File | |
|---|---|
| `detections.jsonl` | the telemetry log, written by `DetectionLogger` — the same format a phone writes, readable by `shot-eval` |
| `shots.csv` | one row per call the delegate received, in order: `time_s` (ball at the rim, video seconds — the labels' convention; from the matching replay call), `published_s` (frame that published it), then as the delegate got it: `video_offset_s` (release, seconds into the session video), result, confidence, `flagged` (< 0.6, the app's "Check"), zone, court x/y, distance, release angle, speed; `release_s`, `matches_replay` |
| `summary.txt` | video and conversion, frames decoded / fed / logged, frames/s, detector latency, thermal, % of frames with the hoop tracked (the state the delegate saw) and with the detector's rim box, % with ≥ 1 ball, ball box sizes in px (all candidates and the tracked shot ball), shots, fidelity verdict, score |
| `fidelity.txt` | the call-by-call comparison below |
| `shot-eval.txt` | `shot-eval`'s own output on `detections.jsonl` (and the labels, shifted to log time if needed) |
| `strips/shot-NN-<result>.png` | per call: frames at release, apex, rim, rim + 0.5 s — the whole frame at half size and a 1:1 close-up |
| `strips/overview.png` | four frames across the run, same overlays — a quick check even when nothing was called |
| `session.mov` | with `--keep-video` |

Strip colours: yellow ball candidates (confidence in the close-up), orange
the tracker's shot ball (its last accepted box, so it trails the ball when a
frame has no detection), cyan the detector's top hoop (what the log keeps),
blue other hoops, green the smoothed hoop, white dashed the rim the shot is
judged against (held from release), magenta dashed the detection crop.
Boxes are drawn from the Vision-normalised log values (origin bottom-left),
so a box off the ball means the coordinates are off.

## Fidelity: live vs replay

Tuning happens offline: `shot-eval` replays `detections.jsonl` through
`ShotReplay.run`. That's only useful if the replay makes the calls the app
made. Each run checks it:

1. `shot-eval` (the binary) on the log vs `ShotReplay.run` in process;
2. the harness's own frame-by-frame trace of `ShotReplay.run` (to know which
   frame published each call and its release time) vs `ShotReplay.run`;
3. each call the delegate received vs the replay's: same publishing frame,
   same release time (`videoOffset`), same result, same confidence
   (tolerance 1e-9; times 1e-6 s).

Also compared: shot starts (frames), and the hoop state frame by frame.
Anything different is listed in `fidelity.txt` and summarised in
`summary.txt` as **MISMATCH**.

Known ways the two can differ:

- **A call held at the end.** An unsure call waits up to 0.7 s for the net.
  If the session ends inside that wait, `CVPipeline.stop()` drops it
  (`NetCheck.drop`), but `ShotReplay.run` flushes it, so `shot-eval` counts a
  shot the app never logged. Seen on a clip cut 0.3 s after a miss.
- **Two hoops in view.** The detector returns up to three hoops and
  `CourtCalibrationService` picks the one overlapping the hoop it tracks; the
  log keeps only the most confident, so the replay's smoother can pick
  another. The summary counts frames with 2+ hoops.
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

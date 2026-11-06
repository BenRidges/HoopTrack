# Shot tracking review — November 2026

A review of the image recognition stack (detector → hoop tracking → shot
state machine → court position / arc) and what the overhaul changed. The
end of the doc lists what to do next, most valuable first. It sits alongside
`upgrade-cv-detection.md`, which is still the long-range plan; this doc is
about where the code actually stood and stands.

Nothing here has been run on a phone yet. The tracker logic is covered by
unit tests on synthetic trajectories, and `Tools/HoopTrackCore` can now
replay real session logs through it (see "Tuning it" below). The thresholds
still need tuning against real sessions.

## What was broken

| Area | Problem | Effect |
|---|---|---|
| Hoop detection | `CoreMLBallDetector` looked for a label containing `"rim"`. The bundled model's classes are `ball`, `basket`, `person`. | The hoop was never found, and shot detection is gated on a hoop rect, so **automatic make/miss never ran**. Every logged shot came from the manual buttons. |
| Make/miss | "Make" = ball centre anywhere inside the hoop box grown by 20 % × 50 % after the apex. "Miss" = ball below the box. | Rim bounces, balls passing in front of or behind the rim, and anything dropping past the backboard all counted as makes. |
| Shot start | A shot began when the top-confidence ball rose 5 % of the frame and then fell 3 %. | Dribbles, passes and rebounds started shots; with two balls on court the tracker jumped between them. |
| Release point | The "release" box was taken at the apex. | Shot position and arc were computed from a point near the hoop, not the shooter. |
| Court position | `(ball.x − hoop.x) / hoop.width` and `(hoop.y − ball.y) / hoop.height`, clamped to 0–1. | Image offsets aren't court distances: almost every shot landed in the paint. |
| Release angle | Read off the image trajectory. | Perspective makes on-screen angles meaningless when the camera is behind the shooter. |
| Recording | `AVCaptureMovieFileOutput` was added from the main thread while the session queue rebuilt the session and removed every output. | Sessions were never recorded. |
| Frame rate | The 720p preset only offers 30 fps formats; the 60 fps code then set a max frame duration shorter than the min on 120 fps formats (AVFoundation throws). | 30 fps at best: a fast ball moves a third of a rim width between frames. |
| Orientation | Landscape allowed both directions; capture was fixed at 0°. | Turning the phone the other way flipped the picture, and "up" for the tracker. |
| Dribble counting | ARKit frames handed to Vision as `.up` in portrait, on the main thread. | Wrist "height" was actually side-to-side motion, and the UI stuttered. |

## What it does now

**Detector** (`ML/CoreMLBallDetector.swift`): matches classes by label (`ball`
by substring, `basket`/`rim`/`hoop` as whole words), uses per-class
thresholds (ball 0.30, hoop 0.45), returns up to four ball candidates and
runs on all compute units. The model has NMS built in, so the hand-rolled
YOLO decoder is gone.

**Hoop** (`Services/CourtCalibrationService.swift`): unchanged EMA smoother
with a 0.5 s lost timeout. The HUD shows searching / tracking / lost, with a
coach card until the hoop is found.

**Shots** (`Utilities/ShotTracker.swift`): a pure struct, unit tested.

- Measures everything in rim widths, so it works at any distance from the hoop.
- Between shots it keeps a short track for every ball in view, so any of
  them can start a shot. Another ball higher in the frame no longer blocks
  it.
- From release on, a constant-velocity Kalman filter
  (`Utilities/BallFilter.swift`) predicts where the ball should be. It picks
  the least surprising detection each frame: one noisy box doesn't derail
  the track, a crossing ball or a second shooter's ball can't take it over,
  and the gate widens on its own across missed frames.
- Release is the frame of peak upward speed: close to where the ball left
  the hands, not the apex.
- A make has to drop through the rim line inside the rim's width. It then
  has to leave below the net, or disappear into it and stay gone for
  0.45 s. A ball that comes back up is a bounce, not a make.
- Timeouts and lost-ball guesses get low confidence. Shots under 0.6 are
  flagged "Check" in the summary, which has a one-tap "They're all right".

**Where from** (`Utilities/ShotGeometry.swift`):

- Distance comes from apparent size. A ball is 0.239 m across and a rim
  0.457 m, and with the camera's real field of view
  (`activeFormat.videoFieldOfView`) that gives depth for each.
- Lateral offset comes from the angle.
- The result becomes normalised court coordinates and a zone.

**Arc**: projectile physics from the horizontal distance and the flight time
from release to rim height, assuming a 2.2 m release height. Angles outside
20–80° or flights outside 0.35–2.5 s are thrown away rather than stored.

**Close-up detection while a shot is in flight**
(`Utilities/DetectionRegion.swift`):

- Once the shot ball is being tracked, the detector runs on a square crop
  around the hoop, the net and the ball instead of the letterboxed frame.
  That gives up to ~2× more pixels on the ball at the moments that decide
  make or miss.
- Between shots it goes back to the full frame, so a release anywhere is
  seen.
- To switch it off, set `HoopTrack.CV.focusDuringShots` to false.

**Capture**: 1280×720 at 60 fps when the camera has such a format, locked to
landscape-right. HEVC recording is fed from the same buffers as the CV, so
video offsets line up with shots and the replay can jump to each one. When
the phone reaches `.serious` thermal state, detection drops to every other
frame and recording stays at full rate. This happens before iOS throttles
the phone itself.

**Logging**: with "Help improve shot tracking" on, every frame's ball
candidates, raw rim box, detection crop and tracker calls go to
`detections.jsonl`. That's enough to replay the session offline. Older logs
still decode.

**Dribbles** (`Services/DribblePipeline.swift`): body pose rather than hand pose,
because at 2–3 m hands are too small. It runs at about 30 fps on the camera
queue. A bounce counts when a wrist moves at least 12 % of torso length,
which filters out jitter.

## Known limits

- **Small ball at release.** Close-up detection only applies during flight.
  The release itself is still detected in the letterboxed full frame, where
  a far ball is about 10 px across.
- **Close-up mapping.** Vision returns boxes relative to the region of
  interest, and `DetectionRegion.toFullFrame` maps them back. This is unit
  tested but not yet checked on a device. With Profile → Developer → Show
  detection boxes on, a misplaced box is obvious in the first shot.
- **Depth from size** is roughly ±15–20 % at range, and box size is noisy
  frame to frame. Zones near the three-point line will sometimes be wrong.
- **Rim line.** The rim line sits at a fixed fraction of the hoop box. A camera
  well below rim height sees the rim as a thin ellipse and the line drifts.
- **Release height** is assumed. A tall shooter or a jumper shifts the arc by
  a few degrees.
- **Tuning.** `ShotTracker.Tuning` values are first-principles guesses that
  pass synthetic tests. None of them come from real footage yet.

## Tuning it

`Tools/HoopTrackCore` is a Swift package of the app's pure logic. It's built
from symlinks into the app target and needs no simulator.

```
cd Tools/HoopTrackCore
swift test                                        # 131 logic tests
swift run shot-eval detections.jsonl labels.csv   # replay + score a session
```

To get a scored session:

1. Record a session with sharing on.
2. Pull `Documents/Telemetry/<session id>/detections.jsonl` from the device
   (Xcode → Devices → Download Container).
3. Write `labels.csv` by watching the session video: one `seconds,make|miss`
   line per shot, timed to when the ball reaches the rim.

The report shows how many shots were detected, how many calls were right,
which way the wrong calls went, phantom shots and missed shots. Change
`ShotTracker.Tuning`, re-run, compare.

## Next, in order of payoff

1. **Label 20–30 real sessions** and tune `ShotTracker.Tuning` with
   `shot-eval` until the numbers stop improving. Commit the labelled logs as
   fixtures so regressions show up in `swift test`.
2. **Check close-up detection on device**, then try a tighter
   `minSidePx` and margin.
3. **Retrain from this viewpoint.**
   - Phone behind the shooter at chest height, in gyms and outdoors, at dusk.
   - Opt-in frames and user corrections (`isUserCorrected`, confirmed "Check"
     calls) are the best labels the app produces.
   - Add a `net` class: net motion is the strongest make signal when the
     ball is hidden behind the rim.
4. **Better position from the shooter.** The model already detects `person`.
   - At release, take the person box nearest the ball. The bottom of the box
     is where the feet touch the floor.
   - Add a one-time calibration (tap the free-throw line or the rim on
     screen) to get camera height and tilt. Ground-plane geometry then gives
     position to well under a metre, much tighter than ball size.
5. **Smooth sizes before depth.** Feed the ball filter's box sizes, rather
   than the median of five raw boxes, into `CourtPositionEstimator`.
6. **Sound** (Phase E of `upgrade-cv-detection.md`). A tiny on-device
   classifier for rim, backboard and net audio is a strong second opinion on
   low-confidence calls.

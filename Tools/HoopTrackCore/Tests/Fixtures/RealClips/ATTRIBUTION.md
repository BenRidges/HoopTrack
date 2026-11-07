# Real-clip fixtures: what these files are

`<clip>.detections.jsonl.gz` is the telemetry log (`detections.jsonl`, the
format a phone writes) that the shipped pipeline — `CVPipeline` with
`CoreMLBallDetector` on `ML/BallDetector.mlmodel` — wrote while `cv-replay`
fed it the clip below, on a Mac (see `Tools/cv/README.md`), compressed with
`gzip -9`. `<clip>.labels.csv` is the clip's hand labels. Both are derived
from the CC BY 3.0 videos listed below; the videos themselves are not in
this repository. `RealClipFixtureTests` replays the logs with
`ShotReplay.run` and holds each clip to a floor.

Regenerate (on a Mac, with the footage in `~/Projects/hoop-footage`):

```
cd Tools/HoopTrackCore && swift build --product cv-replay && swift build --product shot-eval
.build/debug/cv-replay ~/Projects/hoop-footage/<clip>.mp4 \
    --labels ~/Projects/hoop-footage/<clip>.labels.csv --out /tmp/<clip> --no-strips
gzip -9 -c /tmp/<clip>/detections.jsonl > Tests/Fixtures/RealClips/<clip>.detections.jsonl.gz
```

The attribution for the source videos follows, as it stands with the
footage.

---

# Basketball test footage: sources and licences

The clips here are trimmed and re-encoded copies of videos their uploaders
published on YouTube under the Creative Commons Attribution licence
("Creative Commons Attribution license (reuse allowed)", which is CC BY 3.0).
The licence was checked with `yt-dlp --print license` on 2026-11-07. The
original authors keep their copyright. These copies are changed: trimmed,
audio removed, and re-encoded to H.264 1280x720 yuv420p at the original frame
rate. The authors have not endorsed this use.

Labels (`<clip>.labels.csv`) hold one row per shot, `seconds,make|miss`. The
time is measured from the start of the trimmed clip and marks the moment the
ball reaches the rim. Each call was checked frame by frame. Lines starting
with `#` are notes and are ignored by `ShotEvaluation`.

| Clip | Shots | Makes | Misses | Duration | fps |
|---|---|---|---|---|---|
| alec-park-2020-08-01.mp4 | 40 | 22 | 18 | 566.1 s | 59.94 |
| alec-park-2020-07-11.mp4 | 22 | 15 | 7 | 325.0 s | 59.94 |
| somorin-dusk-cam1.mp4 | 27 | 17 | 10 | 169.4 s | 30 |
| somorin-dusk-cam2.mp4 | 29 | 17 | 12 | 194.1 s | 30 |
| **Total** | **118** | **71** | **47** | | |

## alec-park-2020-08-01.mp4

- Source: "^_^Alec's Basketball Practice - Shooting Drills 2020-08-01 Part-2"
- Author: Agent Tennis (https://www.youtube.com/channel/UCzcMeUERINc6-IVhQJ3lEGg)
- URL: https://www.youtube.com/watch?v=Z_uTdVte3Tk
- Licence: CC BY 3.0 (YouTube Creative Commons Attribution)
- Trimmed: nothing. This is the whole video (0-566.1 s), taken from the 720p60 stream. Audio removed.
- Scene: one player shooting jump shots, free-throw-range shots and close shots on an outdoor park
  hoop with a white string net, in daylight. The camera is a tripod on the court, low and roughly
  side-on to the shots (about 60-70 degrees off the shot line), looking up. The hoop sits near the top
  edge (rim at about x 892-956, y 118-140 of 1280x720, roughly 50 px wide), so the ball usually leaves
  the top of the frame near its apex. Trees are behind the hoop. There are no cuts or pans.
- Distractors: someone in a red/orange cap stands just below the frame and the cap pokes into the
  bottom edge; it passes in front of the hoop at about 397.9 s and 430.5 s. A player carries the ball
  past the camera at about 540.9 s and 553.9 s.

## alec-park-2020-07-11.mp4

- Source: "^_^Alec's Basketball Practice - Shooting Drills - Recovery during Pandemic 2020-07-11 Part 3"
- Author: Agent Tennis (https://www.youtube.com/channel/UCzcMeUERINc6-IVhQJ3lEGg)
- URL: https://www.youtube.com/watch?v=fDOZpyYVpFw
- Licence: CC BY 3.0 (YouTube Creative Commons Attribution)
- Trimmed: source 7.0-332.0 s, taken from the 1080p60 stream and scaled to 720p. Clip time is
  source time minus 7.0 s. The first 7 s (empty court) and the last 26 s (after the final shot) were
  dropped. Audio removed.
- Scene: the same player at a different park hoop, a curved-pole hoop with a thin white string net
  that is barely visible at 720p. The camera is a tripod on the court, side-on to the shots and further
  back. The hoop is right of centre (rim at about x 760-817, y 270-290). The backboard is seen nearly
  edge-on and the rim sticks out to the left of it. There are no cuts or pans.
- Notes: makes often drop out of the net toward the bottom-left. Three events were left unlabelled (see
  the comments in the CSV). The player walks past the camera at the start.

## somorin-dusk-cam1.mp4 and somorin-dusk-cam2.mp4

- Source: "Hannah Somorin - 5' 8' 2024 - PG - Shooting outside in the Dark"
- Author: Hannah Somorin (https://www.youtube.com/channel/UCFQxJRRyijANwwO0AKLsk7A)
- URL: https://www.youtube.com/watch?v=bt4XXlxxawo
- Licence: CC BY 3.0 (YouTube Creative Commons Attribution)
- Trimmed: the source is one 366 s video with a crossfade (about 170.4-171.9 s) where the camera
  moves. Taken from the 720p30 stream, audio removed.
  - cam1 = source 0.0-169.4 s. It ends before a shot released at about 169.6 s, whose rim arrival falls inside the crossfade.
  - cam2 = source 172.0-366.1 s. Clip time is source time minus 172.0 s.
- Scene: one shooter on an outdoor court with a white net, snow around, at dusk (cam2 is noticeably
  darker, and the ball shows as a dark silhouette with no visible orange). A rebounder in black stands
  under the hoop and passes the ball back after every shot. The camera is a tripod behind and to the
  side of the shooter, about 45 degrees off the shot line. The shooter is at the left edge in cam1,
  partly out of frame. The hoop is in the upper middle (cam1 rim at about x 562-617, y 130-142; cam2
  rim at about x 805-857, y 115-130). The ball usually leaves the top of the frame near its apex. The
  lens has two dark smudges in the upper-left sky.
- Notes: in both clips the first shot is already on its way within the first second (cam1's release
  happens before the video starts). A tracker that is still locking onto the hoop will probably miss
  those two.

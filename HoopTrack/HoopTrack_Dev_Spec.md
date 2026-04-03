# HoopTrack
## Personal Basketball Progress Tracker
### iOS Application — Development Specification v1.0

| | |
|---|---|
| **Platform** | iOS 16+ (iPhone 14 primary target) |
| **App Type** | Native iOS — SwiftUI + UIKit hybrid |
| **Purpose** | Personal basketball training tracker & performance analytics |
| **Inspired By** | HomeCourt (Nex Team Inc.) |
| **Document Version** | 1.0 — March 2026 |

---

## 1. Product Overview

HoopTrack is a personal-use iOS application that uses the iPhone 14 camera, on-device AI, and Apple's Vision framework to automatically track, analyse, and log basketball training sessions. The goal is to replace manual stat-keeping with a single-phone setup that delivers the kind of data analytics previously only available to professional teams.

**Design Philosophy**

- Solo-player first — designed to be used alone, propped up on a phone stand
- No special equipment — works with any basketball and any court
- Progress-centric — every feature serves the goal of tracking personal improvement over time
- Offline-capable — core tracking works without internet; sync happens in the background

---

## 2. Core Features

### 2.1 Shot Tracking

The most critical feature. The app uses the rear iPhone camera with computer vision to automatically detect shots, categorise makes and misses, and record shot location on a court map.

| Feature | Description |
|---|---|
| **Shot Detection** | Automatic make/miss detection via real-time computer vision using Apple Vision framework + Core ML. No manual input required. |
| **Shot Mapping** | Court overhead view with heat map of attempts vs makes. Zones auto-classified: paint, mid-range, corner 3, above-break 3, free throw. |
| **Shot Correction** | After session, review shot-by-shot with video thumbnail. Edit make/miss result or drag shot marker to correct location. |
| **Shot Type Detection** | Classifies: catch-and-shoot, off-dribble, pull-up, free throw, layup, floater. Displayed per shot and aggregated by type. |

### 2.2 Shot Science — Advanced Biomechanics

Deeper metrics captured via pose estimation (Apple Vision body pose), available for any session recorded with good lighting and clear player silhouette.

- **Release Angle** — launch angle of the ball at the point of release
  - Optimal range: 43°–57° depending on shot distance
  - Shown per shot and as session average
- **Release Time** — time from ball pickup to release (milliseconds)
  - Lower values indicate quicker shot release
- **Vertical Jump** — estimated jump height at point of release
  - Derived from hip/ankle keypoints via Vision body pose
- **Leg Angle** — knee bend angle at jump initiation
- **Shot Speed** — estimated ball velocity in MPH post-release
- **Consistency Score** — variance of release angle across a session (lower = more consistent)

### 2.3 Dribble & Ball-Handling Tracker

Uses the front-facing camera with AR overlays to track ball-handling drills. Phone is placed on the floor pointing upward, tracking the player from ground level.

- Dribble speed — dribbles per second, max speed, average speed
- Hand tracking — left hand vs. right hand dribble count and speed
- AR targets — virtual floor targets appear; player must dribble to activate each one
- Combo detection — crossover, between-the-legs, behind-the-back auto-detected
- Session metrics: total dribbles, drill completion time, accuracy %

### 2.4 Agility & Movement

Measures off-ball athleticism using the full-body camera view.

- Shuttle Run — lateral speed between two AR cones placed on screen
- Lane Agility — timed footwork drill (standard NBA combine format)
- Sprint Speed — straight-line acceleration measured in feet/second
- Standing Reach & Wingspan — camera-based body measurement (approximate, ±5% error)

### 2.5 Session & Workout Management

- Start session — choose drill type: Free Shoot, Dribble, Agility, or Full Workout
- Session timer with pause/resume
- Voice audio feedback during session: "Nice make!", "That's 5 in a row", "Switch hands"
- Session summary shown immediately on finish — FG%, shot chart, best metric highlights
- Name, date, location tag, and notes saved per session
- Sessions searchable and filterable in history log

---

## 3. Progress Tracking & Analytics

### 3.1 Personal Dashboard

The home screen surfaces the player's most important progress metrics at a glance. All data is stored locally on device (with optional iCloud backup).

- Overall Skill Rating — composite score (0–100) updated after each session
- Shooting %: career, last 7 days, last 30 days
- Streaks — longest consecutive session streak, current streak
- Personal records — best FG% session, most makes in a session, best release consistency
- Weekly volume — shots attempted per day (bar chart)

### 3.2 Skill Ratings Breakdown

Each core skill gets its own rating, updated dynamically. Ratings are shown as a radar/spider chart.

| Skill | Basis |
|---|---|
| **Shooting** | FG% weighted by shot difficulty (distance, shot type, game-speed) |
| **Ball Handling** | Dribble speed, combo variety, hand balance |
| **Athleticism** | Vertical jump, sprint speed, shuttle run time |
| **Consistency** | Variance in release angle and shot timing |
| **Volume** | Training frequency and total reps per week |

### 3.3 Historical Charts & Trends

- Interactive line charts: FG% over time, skill rating trend, vertical jump trend
- Heat map evolution — compare shot charts from different time periods side by side
- Zone efficiency — which zones are improving / declining
- Best/worst session stats with drill-down to individual shots
- Export session data as CSV for external analysis

### 3.4 Goal Setting

- Set numeric goals per skill (e.g. "Shoot 45% from 3 by June")
- Goal progress shown as percentage bar on dashboard
- Push notifications for milestones and streaks
- Daily mission suggestions based on weakest skill rating

---

## 4. Drill Library

A built-in catalogue of structured training drills, each with AR-guided execution and automatic stat capture.

| Drill Name | Category | Description |
|---|---|---|
| Around the Arc | Shooting | 5 spots around the 3-point arc, 5 shots each. Tracks zone accuracy. |
| Free Throw Challenge | Shooting | Sets of 10 FTs. Tracks % and consistency over time. |
| Mid-Side-Mid | Shooting | Mid-range triangle drill. 3 positions, timed. |
| 5-Min Endurance Shoot | Shooting | As many makes as possible in 5 mins. Tracks fatigue curve. |
| Mikan Drill | Finishing | Alternating-hand layup loop. Tracks makes per 60 seconds. |
| Crossover Series | Dribbling | AR targets guide dribble direction. Combo tracking on. |
| Two-Ball Dribble | Dribbling | Simultaneous dribble with both hands. Balance score output. |
| Shuttle Run | Agility | Lateral sprint between two AR cones. 3-rep average. |
| Lane Agility | Agility | Box-step footwork drill. Timed to nearest 0.01 second. |
| Vertical Jump Test | Athleticism | 3 attempts. Best height recorded and saved to profile. |

---

## 5. Technology Stack

### 5.1 Core Languages & Frameworks

| | |
|---|---|
| **Language** | Swift 5.9+ |
| **UI Framework** | SwiftUI (primary UI) + UIKit (camera layer, AVFoundation integration) |
| **Minimum iOS** | iOS 16.0 (fully compatible with iPhone 14 running iOS 16–18) |
| **Xcode Version** | Xcode 15+ |
| **Architecture** | MVVM + Combine for reactive state. Clean separation of CV pipeline, data layer, and UI. |

### 5.2 Computer Vision & AI

| | |
|---|---|
| **Apple Vision** | VNDetectHumanBodyPoseRequest for pose estimation. Used for jump height, leg angle, release biomechanics. |
| **Core ML** | On-device ML model for ball detection and shot classification. Model converted via coremltools from YOLO or MobileNet base. |
| **Ball Tracking** | Object tracking via VNTrackObjectRequest. Tracks arc trajectory to determine make/miss against hoop bounding box. |
| **ARKit** | Used for floor target projection in dribble drills and AR cone placement in agility drills. Plane detection via ARWorldTrackingConfiguration. |
| **Create ML** | Tool for training/fine-tuning the shot detection model on custom basketball footage. Used in development, not at runtime. |

### 5.3 Camera & Media

| | |
|---|---|
| **AVFoundation** | AVCaptureSession at 60fps for real-time CV. Rear camera (wide lens) for shot tracking; front camera for dribble drills. |
| **iPhone 14 Camera** | 12 MP main sensor (f/1.5, OIS). ProMotion not available on 14 base, but 60fps video fully supported. |
| **Session Replay** | Sessions stored as compressed H.264 video (HEVC preferred). Playback via AVPlayer with frame-accurate shot annotations overlaid. |

### 5.4 Data Storage

| | |
|---|---|
| **SwiftData / Core Data** | Primary local datastore for sessions, shots, metrics, and goals. SwiftData preferred for iOS 17+; Core Data fallback for iOS 16. |
| **CloudKit (optional)** | iCloud sync for cross-device backup. User opt-in only. Uses CKContainer for private database. |
| **FileManager** | Video session files stored in app's Documents directory. Automatically cleaned after 60 days unless pinned by user. |

### 5.5 Analytics & Charts

| | |
|---|---|
| **Swift Charts** | Apple-native charting framework (iOS 16+). Used for trend lines, bar charts, shot zone heatmaps. |
| **Custom Canvas** | SwiftUI Canvas for court overhead rendering and shot placement dots. No third-party dependency. |

### 5.6 Apple Platform Integrations

- **HealthKit** — write workout sessions (calories, active minutes). Request `HKWorkoutType.basketball` permission.
- **Apple Watch** — optional companion for heart rate overlay during sessions. WatchConnectivity framework.
- **Haptics** — UIImpactFeedbackGenerator for make/miss confirmation during sessions.
- **Notifications** — UNUserNotificationCenter for streak reminders and goal milestone alerts.
- **Siri Shortcuts** — "Hey Siri, start a shooting session" to launch directly into Free Shoot mode.
- **Share Sheet** — export session summary card as image (UIActivityViewController).

---

## 6. Screen Architecture & UX

### 6.1 Navigation Structure

Tab-bar navigation with 4 primary tabs:

| Tab | Screen | Key Content |
|---|---|---|
| 🏠 Home | Dashboard | Skill ratings, streak, daily mission, last session summary, quick-start buttons |
| 🎯 Train | Drill Picker | Browse & launch drills. Live camera session view. Post-session summary. |
| 📊 Progress | Stats Hub | Trend charts, shot heat maps, personal records, goal tracking. |
| 👤 Profile | My Profile | Player info, session history log, data export, settings. |

### 6.2 Live Session Screen

The camera view is full-screen. Overlay HUD shows real-time stats without obscuring the tracking area.

- Top left: FG% counter (makes / attempts)
- Top right: session timer
- Bottom strip: last 5 shots (green = make, red = miss)
- Floating make/miss confirmation animation on detect
- Tap to pause; swipe up for mid-session breakdown
- End Session button (long press to prevent accidental triggers)

---

## 7. Performance Requirements

All requirements validated on iPhone 14 (A15 Bionic chip, 6GB RAM).

| Requirement | Target |
|---|---|
| Real-time CV frame processing | < 20ms per frame (60fps target) |
| Shot detection latency | < 0.5s from release to on-screen confirmation |
| App launch to camera ready | < 3 seconds cold start |
| Battery consumption (60 min session) | < 20% battery drain |
| Storage per session (video + data) | < 300MB per 30-min session |
| Make/miss detection accuracy | > 92% under good indoor lighting |
| Pose estimation accuracy (release angle) | Error margin < 3 degrees |
| App memory footprint (active session) | < 300MB RAM |

---

## 8. Development Phases

| Phase | Name | Deliverables | Est. Duration |
|---|---|---|---|
| Phase 1 | Foundation | Project setup, SwiftUI shell, tab navigation, Core Data schema, camera permission flow, basic AVFoundation capture | 2–3 weeks |
| Phase 2 | Shot Tracking MVP | Core ML ball detection model, make/miss logic, shot location mapping, session storage, basic session summary screen | 4–6 weeks |
| Phase 3 | Shot Science | Vision body pose integration, release angle + time + vertical calculations, Shot Science overlay in replay | 3–4 weeks |
| Phase 4 | Dribble Drills | Front camera mode, AR floor target projection (ARKit), dribble speed tracking, hand-balance detection | 3–4 weeks |
| Phase 5 | Progress & Analytics | Swift Charts integration, trend screens, skill rating algorithm, goals system, heat map court renderer | 3–4 weeks |
| Phase 6 | Polish & Integration | HealthKit, Haptics, Siri Shortcuts, Watch companion, notification system, export, UI polish, performance profiling | 2–3 weeks |
| Phase 7 | Testing & Launch | TestFlight beta, accuracy testing vs manual counting, App Store submission, metadata, privacy policy | 2 weeks |

---

## 9. Privacy & Data Handling

- All session video and biometric data stored on-device only by default
- No analytics or tracking SDKs included (no Firebase, no Mixpanel)
- Camera permission requested with clear purpose string in Info.plist
- HealthKit data written only — app never reads HealthKit data
- iCloud sync is strictly opt-in; user can disable at any time
- Video auto-deleted after 60 days (user-configurable); aggregated stats are retained
- App Store privacy label: no data linked to identity; no data shared with third parties

---

## 10. Third-Party Dependencies

HoopTrack is intentionally light on third-party libraries to minimise supply-chain risk and App Store review friction. All core functionality uses Apple-native frameworks.

| Dependency | Notes |
|---|---|
| **No required third-party dependencies** | All CV, AR, charting, and data features use Apple Vision, ARKit, Core ML, Swift Charts, SwiftData, HealthKit. |
| **Optional: Swift Algorithms (Apple OSS)** | SPM package for efficient sliding-window calculations in the metrics pipeline. Apple-maintained, MIT licence. |
| **Dev tooling: coremltools (Python)** | Used offline to convert and quantise the ball detection model into `.mlpackage` format. Not shipped in the app. |

---

## 11. Known Constraints & Limitations

- Outdoor courts with strong sunlight or complex backgrounds reduce CV accuracy — recommend indoor use initially
- Shot tracking requires the hoop to be fully visible in-frame; extreme-angle phone placement degrades accuracy
- Pose estimation (Shot Science) requires the full player body to be in frame and well-lit
- iPhone 14 base model has no ProMotion display; this does not affect camera capture (still 60fps)
- Ball detection model will require periodic retraining as training data expands
- 3-point line distance varies by court; app should allow user to confirm court type (NBA, NCAA, international) at session start for accurate zone mapping

---

*HoopTrack v1.0 Development Spec — March 2026*

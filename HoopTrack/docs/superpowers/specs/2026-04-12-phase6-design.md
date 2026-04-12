# Phase 6 Design Spec — Polish & Integration

**Date:** 2026-04-12  
**Status:** Approved  
**Structure:** Two sub-phases (mirrors Phase 5A/5B approach)

---

## Scope

### In Scope
- Phase 6A: Siri Shortcuts, Data Export, Performance
- Phase 6B: UI Polish (onboarding, loading/empty states, animations), Refactor Analysis, Extension Report

### Backlog (not in Phase 6)
- Haptics — tactile feedback on shot make/miss, badge earn, agility trigger
- Watch Companion — glanceable stats, session start/stop from wrist, complication

---

## Phase 6A

### 1. Siri Shortcuts (App Intents)

**Goal:** Three voice-activated shortcuts using the modern App Intents framework, designed so adding new shortcuts requires only a new file + one line in the provider.

**Architecture:**

New folder: `HoopTrack/AppIntents/`

- **`HoopTrackShortcuts.swift`** — implements `AppShortcutsProvider`. The `appShortcuts` array is the single registration point for all shortcuts. Phrases registered here surface automatically in Siri and the Shortcuts app without user configuration.
- **`StartFreeShootSessionIntent.swift`** — `AppIntent` conforming to `ForegroundContinuableIntent`. Opens the app and navigates to a live free shoot session via URL scheme `hooptrack://train/freeshoot`.
- **`ShowMyStatsIntent.swift`** — `AppIntent` conforming to `ForegroundContinuableIntent`. Opens the app to the Progress tab via `hooptrack://progress`.
- **`ShotsTodayIntent.swift`** — `AppIntent` (background-capable, no app launch). Queries `DataService` for today's total shot count and returns a spoken `IntentResultValue<String>` (e.g. "You've taken 47 shots today").

**URL scheme routing:**
- Register `hooptrack` scheme in `Info.plist`
- `HoopTrackApp.swift` gains `.onOpenURL` handler routing to the correct tab/view
- This URL routing also serves as a foundation for future deep links and notification taps

**Extensibility pattern:**
Each new shortcut is a single new file. No changes to existing files except appending one entry to the `appShortcuts` array in `HoopTrackShortcuts.swift`.

**Tech:** App Intents framework (iOS 16+), Swift 6 `@MainActor`

---

### 2. Data Export

**Goal:** One-tap JSON export of session history with per-shot detail, delivered via the system share sheet.

**Architecture:**

- **`Services/ExportService.swift`** — `@MainActor final class` with a single public method: `func exportJSON(for profile: PlayerProfile) async throws -> URL`. Transforms SwiftData models into Codable structs, serialises to JSON, writes to a temp file, returns the URL.

**Export data shape:**
```json
{
  "exportedAt": "2026-04-12T13:45:00Z",
  "profileName": "Ben",
  "sessions": [
    {
      "id": "uuid",
      "date": "2026-04-10T10:00:00Z",
      "drillType": "freeShoot",
      "durationSeconds": 1823,
      "fgPercent": 0.52,
      "threePointPercent": 0.38,
      "shots": [
        {
          "zone": "midRange",
          "made": true,
          "releaseAngle": 48.2,
          "releaseTimeSeconds": 0.41
        }
      ]
    }
  ]
}
```

**Codable structs** (plain value types, not `@Model`):
- `SessionExportRecord` — mirrors `TrainingSession` fields relevant to export
- `ShotExportRecord` — mirrors `ShotRecord` fields relevant to export

**Entry point:** New "Export Data" row in `ProfileTabView` → Settings section. Tapping calls `ExportService.exportJSON(for:)` then presents the system share sheet via `ShareLink(item: url)`.

---

### 3. Performance

**Goal:** Instrument the app for production metric collection, audit the three highest-risk areas, and apply targeted fixes.

**MetricKit integration:**

- **`Services/MetricsService.swift`** — `@MainActor final class` subscribing to `MXMetricManager.shared`. Implements `MXMetricManagerSubscriber.didReceive(_:)`. On each daily payload delivery, logs CPU time, memory peak, launch time, and hang rate to `Documents/metrics.log`. Registered in `HoopTrackApp.init()`. Developer-facing only — no UI surface.

**Instruments audit — three targets:**

1. **CV pipeline (`CVPipeline.swift`)** — measure frame processing time per frame. Target: <20ms on iPhone 12+. Fix if over budget: move non-critical processing (e.g. court zone classification when ball is not detected) off the hot path using `Task.detached(priority: .utility)`.

2. **SwiftData queries (`DataService`)** — profile fetch calls that load full session history. Fix: add `FetchDescriptor` predicates (e.g. date range filter) and `.fetchLimit` where full scans are unnecessary (home tab summary needs only the last 30 sessions).

3. **Memory (`CameraService`)** — profile `CVPixelBuffer` retention across frames. Fix: wrap frame processing in `autoreleasepool {}` blocks to ensure buffers are released promptly between frames.

**Documentation:** Findings recorded in `docs/performance-report.md` before fixes land, establishing a clear before/after baseline.

---

## Phase 6B

### 4. UI Polish

#### 4a. Onboarding

**Goal:** 5-screen first-launch experience combining feature showcase with permission requests. Shown only once, gated by `@AppStorage("hasCompletedOnboarding")`.

**Screens (swipeable `TabView` with `.tabViewStyle(.page)`):**

1. **Welcome** — app name, tagline ("Track every shot. Own your game."), Get Started button.
2. **Camera + Shot Tracking** — mini demo of auto shot detection UI, explains camera purpose, "Allow Camera" button triggers `AVCaptureDevice.requestAccess(for: .video)`.
3. **Notifications + Badges** — badge earn illustration, explains milestone notifications, "Allow Notifications" button triggers `UNUserNotificationCenter.requestAuthorization`. Marked optional with skip affordance.
4. **Goals showcase** — goal progress card illustration, no permission needed, Continue button.
5. **Profile setup** — name TextField, "Start Training 🏀" button saves name to `PlayerProfile` and sets `hasCompletedOnboarding = true`.

**Implementation notes:**
- All screens use the app's existing visual language: orange accents, `.ultraThinMaterial` cards, SF Symbols, dark background — not the wireframe aesthetic from brainstorming.
- `HoopTrackApp.swift` wraps root view in a check: if `!hasCompletedOnboarding`, present `OnboardingView` as `.fullScreenCover`.
- `Views/Onboarding/OnboardingView.swift` — container with page tab view and progress dots.
- Each page is its own private subview within the file.

#### 4b. Loading & Empty States

**Shimmer loading:**
- **`ViewModifiers/ShimmerModifier.swift`** — animated diagonal gradient sweeping left-to-right using `TimelineView(.animation)`. Applied via `.shimmer(isActive: Bool)`. Composed with SwiftUI's `.redacted(reason: .placeholder)` for skeleton loading.
- Applied to: `HomeTabView` career stats block, `ProgressTabView` session list, `BadgeBrowserView` badge rows.

**Empty states (using `ContentUnavailableView`, iOS 17):**
- `HomeTabView` — *"No sessions yet"* with Train tab CTA.
- `ProgressTabView` — *"Complete your first session to see trends"* with SF Symbol `chart.line.uptrend.xyaxis`.
- `GoalListView` — already implemented in Phase 5B; reviewed for style consistency only.

#### 4c. Animations & Transitions

**Session summary counters:**
- **`ViewModifiers/AnimatedCounterModifier.swift`** — drives a `Double` from 0 to a target value over 0.6s with `.easeOut` using `withAnimation` + `.onAppear`. Applied to FG%, shot count, and duration in `SessionSummaryView`, `DribbleSessionSummaryView`, and `AgilitySessionSummaryView`.

**Badge earn celebration:**
- `BadgesUpdatedSection` rows animate in with `.transition(.scale(scale: 0.8).combined(with: .opacity))` and `.spring(response: 0.4, dampingFraction: 0.6)` on appear.
- Single `UINotificationFeedbackGenerator().notificationOccurred(.success)` haptic fires when the section appears with non-empty changes.

**Session transitions:**
- `LiveSessionView`, `DribbleDrillView`, and `AgilitySessionView` all use `.fullScreenCover` — verify `.transition(.move(edge: .bottom))` is consistent and applied uniformly. No custom transition work if the default is already consistent.

---

### 5. Refactor Analysis

**Goal:** A subagent performs a thorough codebase read and produces a structured findings report before Phase 6B closes.

**Scope of analysis:**

- **File size & responsibility** — flag files over ~250 lines or with mixed concerns (Views containing business logic, Services doing UI work).
- **Duplication** — identify repeated patterns suitable for extraction. Known candidate: the long-press end-session button pattern appears in `LiveSessionView`, `DribbleDrillView`, and `AgilitySessionView` — could become a `LongPressEndButton` component.
- **Concurrency hygiene** — any `DispatchQueue.main.async` patterns that should be `Task { @MainActor in }`, missing `@MainActor` annotations, unsafe captures.
- **SwiftData access** — confirm all model context access flows through `DataService`; flag any Views reaching into `modelContext` directly for non-trivial operations.
- **Dead code** — commented-out blocks, unused `@Published` properties, unreachable switch branches.

**Output:** `docs/refactor-report.md`  
Format: each finding has severity (Critical / Important / Minor), file:line reference, description, and concrete suggested fix. Findings rated Critical or Important become tracked follow-up tasks.

---

### 6. Extension Report

**Output:** `docs/extension-report.md` — two-part document.

#### Part 1 — Strategic Vision

What HoopTrack could become beyond a solo training tool:

- **Team & multiplayer sessions** — shared court sessions, team drill competitions
- **Coach review mode** — coaches receive session recordings with annotation tools, athletes see feedback inline
- **Drill marketplace** — community-created named drills, rated and discoverable
- **Social leaderboards** — friends, city, global rankings by skill dimension
- **Video sharing** — highlight clips from session recordings shared to social
- **Web dashboard** — long-term progress charts, historical heatmaps, accessible from any device

#### Part 2 — Technical Options Brief

Comprehensive production-readiness options across every category:

**Authentication & Identity**
- Sign in with Apple (recommended — native iOS, zero friction, privacy-preserving, App Store required if other social auth is offered)
- Sign in with Google (via Firebase Auth or Supabase Auth)
- Email/password (traditional, requires email verification flow)
- Face ID / Touch ID for local re-authentication (Keychain + `LAContext`)
- JWT strategy: short-lived access tokens + refresh token rotation; secure storage in Keychain (never `UserDefaults`)

**Backend & API**
- REST API: FastAPI (Python, fast to build), Express/Hono (TypeScript, lightweight), Rails (batteries included)
- GraphQL: Hasura (auto-generates from Postgres schema, zero backend code for CRUD), Apollo Server (custom resolvers)
- tRPC: type-safe end-to-end if pairing with a TypeScript backend; excellent DX, no code generation
- gRPC: strong Swift support via `grpc-swift`; ideal for streaming live session data to a backend in real time
- Serverless functions: Vercel/Netlify Functions/AWS Lambda for lightweight endpoints (e.g. badge leaderboard, export trigger)

**Sync & Real-time**
- CloudKit (already wired via iCloud toggle — zero infrastructure cost, Apple-managed, private database per user)
- Supabase Realtime (Postgres changes streamed via WebSocket — good for coach review, live leaderboards)
- Firebase Firestore (mature real-time subscriptions, offline support, larger vendor ecosystem)
- Custom WebSockets (most control, most work — worth it only for live co-session features)
- Offline-first conflict resolution: last-write-wins for most fields; set-union for `ShotRecord` arrays (shots are append-only)

**Database**
- SwiftData only (current — appropriate for solo, on-device use; no operational cost)
- PostgreSQL: Supabase (managed, open-source, excellent Swift SDK), Railway (simple deployment), Neon (serverless Postgres, scales to zero)
- SQLite at edge: Turso (distributed SQLite, ultra-low latency reads globally)
- MongoDB Atlas (document model maps naturally to session JSON; less ideal for relational queries)
- Redis: leaderboards (sorted sets), session caching, rate limiting for API endpoints

**File & Media Storage**
- Session video storage: AWS S3 (industry standard), Cloudflare R2 (S3-compatible, zero egress fees — recommended), Supabase Storage (integrated with Supabase auth)
- Video transcoding/streaming: AWS MediaConvert + CloudFront, Cloudflare Stream (simplest — handles upload, transcode, delivery)
- CDN for assets: Cloudflare (free tier covers most indie app needs)

**Push Notifications**
- APNs direct (full control, requires backend to manage device tokens and payload construction)
- OneSignal (managed — free tier generous, handles token management, segmentation, A/B testing)
- Firebase Cloud Messaging (unified push for iOS + future Android; integrates with Firebase ecosystem)

**Analytics & Monitoring**
- Crash reporting: Sentry (open-source, self-hostable, excellent Swift SDK), Firebase Crashlytics (free, tightly integrated)
- Product analytics: PostHog (open-source, self-hostable, privacy-friendly — recommended for GDPR), Mixpanel (powerful funnels), Amplitude (enterprise)
- Performance monitoring: MetricKit (already in plan — on-device), Firebase Performance (cloud aggregation)
- Uptime/API monitoring: Better Uptime, Checkly

**CI/CD & Distribution**
- Xcode Cloud (native Apple, zero config for standard builds, integrates with TestFlight and App Store Connect — recommended starting point)
- GitHub Actions + fastlane (most flexible; fastlane handles code signing, TestFlight upload, App Store submission, changelog generation)
- Bitrise (mobile-first CI, good Xcode support, more expensive)
- Code signing: Fastlane Match (certificates and provisioning profiles stored encrypted in a private git repo — team-friendly)
- TestFlight: beta distribution to internal testers → external testers → App Store review

**Security**
- Certificate pinning: `URLSession` with custom `URLAuthenticationChallenge` handler; prevents MITM against known API endpoints
- Keychain: all tokens, credentials, and sensitive preferences stored in Keychain (never `UserDefaults`)
- App Transport Security: enforce HTTPS for all domains; no ATS exceptions in production
- Data encryption at rest: iOS file data protection (`FileProtectionType.complete`) for exported files and metrics log
- Privacy manifest (`PrivacyInfo.xcprivacy`): required for App Store since iOS 17 — declare all API usage reasons
- Privacy nutrition labels: App Store Connect data practice declarations
- GDPR: right to export (already built), right to delete (delete `PlayerProfile` cascade), data residency considerations for CloudKit

**Monetisation**
- Freemium: core tracking free, advanced analytics/export/coaching behind paywall
- StoreKit 2: modern subscription API, server-side receipt validation via App Store Server API
- RevenueCat: subscription management SDK — handles receipt validation, entitlements, paywalls, analytics (recommended over raw StoreKit 2 for indie apps)
- One-time unlock: lifetime purchase via StoreKit 2 non-consumable
- Drill marketplace: community drills sold as consumables or included in subscription; 30% App Store commission applies
- Coach marketplace: coach subscription tier with revenue share model

**Web Presence**
- Marketing site: Next.js (React, App Store badge, feature highlights, privacy policy) — deploy to Vercel in <1 hour
- Web stats dashboard: Next.js + Supabase — user logs in with same credentials, sees their session history in charts (Swift Charts equivalent: Recharts/Nivo)
- Framework comparison: Next.js (most ecosystem, best SEO), Nuxt (Vue, slightly simpler), SvelteKit (lightest, fastest builds)
- API-first architecture prerequisite: web clients require the same REST/GraphQL API as any future Android client

**ML/CV Improvements**
- Real ball detection model: train YOLOv8-nano on a basketball dataset (Roboflow Universe has several) → export to Core ML via `coremltools`; replaces current `BallDetectorStub`
- Create ML: Apple's drag-and-drop model trainer — viable for object detection with sufficient labelled data
- Cloud inference fallback: for devices too old for on-device inference, send frames to a serverless endpoint running ONNX Runtime
- OpenAI Vision API: post-session video analysis — send key frames for shot form feedback ("your elbow was out on this attempt")
- Pose estimation improvements: upgrade `PoseEstimationService` from `VNDetectHumanBodyPoseRequest` to a fine-tuned sports pose model for better release angle accuracy

**Social Infrastructure**
- Leaderboards: Redis sorted sets (fast, O(log n) rank queries) vs Apple Game Center (zero infra, but limited customisation)
- Follow/friend graph: Postgres adjacency list or dedicated graph DB (Neo4j for complex social queries)
- Activity feed: fan-out-on-write (write to followers' feeds on session complete) vs fan-out-on-read (aggregate at request time); fan-out-on-write preferred for <10k followers
- Coach review: WebRTC for live co-session, or async — coach reviews recording and leaves timestamped annotations stored as JSON

**Accessibility**
- VoiceOver: audit all custom views for `accessibilityLabel`, `accessibilityValue`, `accessibilityHint`; ensure all interactive elements are reachable
- Dynamic Type: verify all `Text` views use `.font(.body)` style (not fixed sizes); test at largest accessibility size
- WCAG contrast: orange (`#FF6B35`) on dark background — verify 4.5:1 ratio at all opacity levels used
- Switch Control: ensure tab order and focus groups are logical; custom gestures (long-press end session) need alternative activation

---

## Backlog

Items deferred from Phase 6 — ready to spec when prioritised:

| Feature | Description |
|---|---|
| Haptics | Tactile feedback: medium impact on shot log, success notification on badge earn, selection feedback on agility trigger |
| Watch Companion | WatchKit app: glanceable today stats, session start/stop trigger, `CLKComplication` for daily goal progress |

---

## File Summary

### New Files — Phase 6A
| File | Purpose |
|---|---|
| `HoopTrack/AppIntents/HoopTrackShortcuts.swift` | `AppShortcutsProvider` — registers all shortcuts |
| `HoopTrack/AppIntents/StartFreeShootSessionIntent.swift` | Launch free shoot session intent |
| `HoopTrack/AppIntents/ShowMyStatsIntent.swift` | Open Progress tab intent |
| `HoopTrack/AppIntents/ShotsTodayIntent.swift` | Background spoken shot count intent |
| `HoopTrack/Services/ExportService.swift` | JSON serialisation + temp file writer |
| `HoopTrack/Models/Export/SessionExportRecord.swift` | Codable session export struct |
| `HoopTrack/Models/Export/ShotExportRecord.swift` | Codable shot export struct |
| `HoopTrack/Services/MetricsService.swift` | MetricKit subscriber |
| `docs/performance-report.md` | Instruments audit findings (written during implementation) |

### New Files — Phase 6B
| File | Purpose |
|---|---|
| `HoopTrack/Views/Onboarding/OnboardingView.swift` | 5-screen onboarding container + page subviews |
| `HoopTrack/ViewModifiers/ShimmerModifier.swift` | Animated shimmer loading modifier |
| `HoopTrack/ViewModifiers/AnimatedCounterModifier.swift` | Numeric counter animation modifier |
| `docs/refactor-report.md` | Codebase refactor analysis findings |
| `docs/extension-report.md` | Strategic vision + technical options brief |

### Modified Files — Phase 6A
| File | Change |
|---|---|
| `HoopTrack/HoopTrackApp.swift` | Register `MetricsService`, add `.onOpenURL` handler |
| `HoopTrack/Info.plist` | Register `hooptrack://` URL scheme |
| `HoopTrack/Views/Profile/ProfileTabView.swift` | Add "Export Data" row to Settings section |
| `HoopTrack/Services/DataService.swift` | Add predicate/limit optimisations |

### Modified Files — Phase 6B
| File | Change |
|---|---|
| `HoopTrack/HoopTrackApp.swift` | Add onboarding gate (`hasCompletedOnboarding` check) |
| `HoopTrack/Views/Train/SessionSummaryView.swift` | Animated counters |
| `HoopTrack/Views/Train/DribbleSessionSummaryView.swift` | Animated counters |
| `HoopTrack/Views/Train/AgilitySessionSummaryView.swift` | Animated counters |
| `HoopTrack/Views/Components/BadgesUpdatedSection.swift` | Spring animation + haptic on appear |
| `HoopTrack/Views/Home/HomeTabView.swift` | Shimmer + empty state |
| `HoopTrack/Views/Progress/ProgressTabView.swift` | Shimmer + empty state |
| `HoopTrack/Views/Profile/BadgeBrowserView.swift` | Shimmer on badge rows |

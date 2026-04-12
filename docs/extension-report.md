# HoopTrack Extension Report

**Date:** 2026-04-12  
**Written at:** End of Phase 6B  
**Purpose:** Strategic vision for HoopTrack's growth beyond a solo training tool, plus a comprehensive technical options brief for production readiness.

---

## Part 1 — Strategic Vision

### What HoopTrack Could Become

#### Team & Multiplayer Sessions

HoopTrack's per-shot tracking and real-time CV pipeline make it a natural fit for shared court sessions where multiple players run drills simultaneously. Teammates could join a named session, compete on drill leaderboards in real time, and review collective stats afterward. This transforms the app from a personal logger into a team training platform that coaches can run directly from the sideline.

#### Coach Review Mode

Athletes already capture rich session data — release angle, zone heat maps, FG% by distance. A coach review mode would let athletes share a session recording with their coach, who could leave timestamped annotations inline ("drive through here, don't pull up"). Athletes would see the feedback surfaced directly on the session timeline, closing the loop between training and instruction without requiring a separate video tool.

#### Drill Marketplace

Beyond the built-in free shoot, dribble, and agility session types, experienced coaches and trainers could publish named drills with defined sets, reps, and scoring criteria. A searchable marketplace — rated and curated by the community — would let any user download a drill and run it with full auto-tracking. Drills could be sold individually or bundled in coaching programs, creating a monetisation layer that aligns incentives between creators and athletes.

#### Social Leaderboards

Skill dimensions already tracked — FG%, dribble speed, agility time — translate directly into comparable rankings. Friends, city, and global leaderboards would give players motivating context for their numbers and create a retention loop around improving rank. Leaderboards are most compelling when scoped meaningfully: "top 10 in your city this week" beats a global list dominated by professionals.

#### Video Sharing

Session recordings already captured by `CameraService` contain highlight-worthy moments: contested makes, personal-best dribble runs, clean form. A highlight-clip feature would let users trim a short clip, optionally overlay session stats as a graphic, and share directly to Instagram Reels, TikTok, or iMessage. This turns every good training session into organic marketing for the app.

#### Web Dashboard

Long-term progress data — months of shot charts, zone heat maps, skill rating trends — benefits from a large screen with interactive filtering. A web dashboard where users log in with the same credentials and see their full history in rich charts (built on the same API as the mobile app) would also serve as an accessible fallback for users who prefer reviewing stats on a laptop. It is a prerequisite for any future team or coach portal, since coaches are unlikely to manage multiple athletes exclusively on a phone.

---

## Part 2 — Technical Options Brief

### Authentication & Identity

- **Sign in with Apple** — native iOS, zero friction, privacy-preserving, required by App Store if any other social auth is offered. **Recommended.**
- **Sign in with Google** — available via Firebase Auth or Supabase Auth; familiar to users but adds a third-party dependency.
- **Email/password** — traditional approach; requires email verification flow and password-reset infrastructure.
- **Face ID / Touch ID for local re-authentication** — implemented via Keychain + `LAContext`; appropriate as a re-auth layer on top of a primary auth method, not a standalone login.
- **JWT strategy** — short-lived access tokens with refresh token rotation; tokens stored in Keychain (never `UserDefaults`).

### Backend & API

- **FastAPI** (Python) — fast to build, automatic OpenAPI docs, strong async support.
- **Express / Hono** (TypeScript) — lightweight, large ecosystem, type-safe with Hono.
- **Rails** — batteries-included, excellent for rapid CRUD; less idiomatic for streaming use cases.
- **GraphQL via Hasura** — auto-generates a GraphQL API from a Postgres schema with zero custom resolver code for standard CRUD. **Recommended for data-heavy features like session history and leaderboards.**
- **gRPC via `grpc-swift`** — ideal for streaming live session data to a backend in real time; strong Swift client support.
- **Serverless functions** (Vercel / Netlify / AWS Lambda) — appropriate for lightweight endpoints such as badge leaderboard queries or export triggers.

### Sync & Real-time

- **CloudKit** — already wired via iCloud toggle; zero infrastructure cost, Apple-managed, private database per user. **Recommended starting point for solo sync.**
- **Supabase Realtime** — Postgres changes streamed via WebSocket; well-suited for coach review and live leaderboards.
- **Firebase Firestore** — mature real-time subscriptions with offline support and a larger vendor ecosystem.
- **Custom WebSockets** — maximum control; justified only for live co-session features where latency is critical.
- **Offline-first conflict resolution** — last-write-wins for scalar fields; set-union for `ShotRecord` arrays (shots are append-only and should never be dropped on merge).

### Database

- **SwiftData only** — current architecture; appropriate for solo, on-device use with no operational cost.
- **PostgreSQL via Supabase** — managed, open-source, excellent Swift SDK. **Recommended if a backend is introduced.**
- **PostgreSQL via Railway** — simple deployment, good developer experience for small teams.
- **Neon** — serverless Postgres that scales to zero; cost-effective for apps with spiky or low traffic.
- **Turso** — distributed SQLite at the edge; ultra-low latency reads globally for read-heavy endpoints.
- **MongoDB Atlas** — document model maps naturally to session JSON; less suitable for relational queries (e.g. cross-player leaderboards).
- **Redis** — sorted sets for leaderboard rank queries, session caching, and API rate limiting.

### File & Media Storage

- **Cloudflare R2** — S3-compatible, zero egress fees. **Recommended for session video storage.**
- **AWS S3** — industry standard, deep ecosystem integration, egress costs apply at scale.
- **Supabase Storage** — tightly integrated with Supabase Auth and Postgres; convenient if already on the Supabase stack.
- **Cloudflare Stream** — simplest end-to-end solution for video: handles upload, transcoding, and adaptive delivery in one product. **Recommended for video transcoding and streaming.**
- **AWS MediaConvert + CloudFront** — more control, more configuration; appropriate at large scale.
- **Cloudflare CDN** — free tier covers most indie app asset delivery needs.

### Push Notifications

- **APNs direct** — full control over payload and delivery; requires backend to manage device tokens, retry logic, and segmentation.
- **OneSignal** — managed push service with a generous free tier; handles token management, audience segmentation, and A/B testing. **Recommended for indie scale.**
- **Firebase Cloud Messaging (FCM)** — unified push for iOS and future Android clients; integrates cleanly with the Firebase ecosystem.

### Analytics & Monitoring

- **Sentry** — open-source crash reporting, self-hostable, excellent Swift SDK. **Recommended for crash reporting.**
- **Firebase Crashlytics** — free, zero-configuration, deeply integrated with the Firebase ecosystem.
- **PostHog** — open-source product analytics, self-hostable, privacy-friendly. **Recommended for GDPR-compliant event analytics.**
- **Mixpanel** — powerful funnel and retention analysis; hosted only.
- **Amplitude** — enterprise-grade analytics with strong behavioural cohort tools.
- **MetricKit** — on-device performance metrics; already integrated in Phase 6A.
- **Firebase Performance** — cloud aggregation of performance data across users.
- **Better Uptime / Checkly** — uptime monitoring and API health checks for backend endpoints.

### CI/CD & Distribution

- **Xcode Cloud** — native Apple CI, zero configuration for standard builds, integrates directly with TestFlight and App Store Connect. **Recommended starting point.**
- **GitHub Actions + fastlane** — most flexible pipeline; fastlane handles code signing, TestFlight upload, App Store submission, and changelog generation.
- **Bitrise** — mobile-first CI with strong Xcode support; more expensive than GitHub Actions.
- **Fastlane Match** — certificates and provisioning profiles stored encrypted in a private git repo; team-friendly code signing. **Recommended for team environments.**
- **TestFlight** — standard beta distribution path: internal testers → external testers → App Store review.

### Security

- **Certificate pinning** — implemented via `URLSession` with a custom `URLAuthenticationChallenge` handler; prevents MITM attacks against known API endpoints.
- **Keychain storage** — all tokens, credentials, and sensitive preferences stored in Keychain; never `UserDefaults`.
- **App Transport Security** — enforce HTTPS for all domains; no ATS exceptions in production builds.
- **Data encryption at rest** — iOS file data protection (`FileProtectionType.complete`) applied to exported files and the metrics log.
- **Privacy manifest (`PrivacyInfo.xcprivacy`)** — required for App Store submission since iOS 17; must declare all API usage reasons. **Required before App Store submission.**
- **Privacy nutrition labels** — App Store Connect data practice declarations covering all data types collected or linked to identity.
- **GDPR** — right to export (already implemented), right to delete (delete `PlayerProfile` with cascade), data residency considerations for CloudKit.

### Monetisation

- **Freemium** — core shot tracking free; advanced analytics, data export, coach access, and premium drills behind a paywall.
- **RevenueCat** — subscription management SDK handling receipt validation, entitlements, paywall configuration, and subscription analytics. **Recommended over raw StoreKit 2 for indie apps.**
- **StoreKit 2** — modern Apple subscription API with server-side validation via the App Store Server API; use directly if avoiding third-party dependencies.
- **One-time lifetime unlock** — non-consumable in-app purchase via StoreKit 2; eliminates churn for price-sensitive users.
- **Drill marketplace** — community drills sold as consumables or included in a subscription; standard 30% App Store commission applies.
- **Coach marketplace** — a coach subscription tier with a defined revenue share model; aligns coach incentives with platform growth.

### Web Presence

- **Next.js marketing site** — React-based, excellent SEO, App Store badge, feature highlights, and privacy policy; deployable to Vercel in under an hour. **Recommended starting point.**
- **Next.js + Supabase web dashboard** — users log in with the same credentials and view their session history in interactive charts (Recharts or Nivo as the Swift Charts equivalent).
- **Nuxt** (Vue) — slightly simpler mental model than Next.js; smaller ecosystem.
- **SvelteKit** — lightest framework, fastest build times; least ecosystem support for complex data visualisation.
- **API-first architecture prerequisite** — web and future Android clients both require the same REST or GraphQL API; the web dashboard cannot be built without first exposing a backend API.

### ML/CV Improvements

- **YOLOv8-nano via Core ML** — train on a basketball dataset from Roboflow Universe, export to Core ML via `coremltools`; replaces the current `BallDetectorStub`. **Recommended next ML investment.**
- **Create ML** — Apple's drag-and-drop model trainer; viable for object detection given sufficient labelled data, no Python toolchain required.
- **Cloud inference fallback** — for devices too old for on-device inference, send frames to a serverless endpoint running ONNX Runtime.
- **OpenAI Vision API** — post-session video analysis; send key frames for shot form feedback (e.g. "your elbow was out on this attempt").
- **Fine-tuned sports pose model** — upgrade `PoseEstimationService` from the generic `VNDetectHumanBodyPoseRequest` to a sports-specific pose model for improved release angle accuracy.

### Social Infrastructure

- **Redis sorted sets** — O(log n) rank queries; ideal for leaderboard reads at scale. **Recommended for leaderboard backend.**
- **Apple Game Center** — zero infrastructure leaderboards; limited customisation and no cross-platform story.
- **Postgres adjacency list** — simple follow/friend graph for small social graphs; adequate for a friends leaderboard.
- **Neo4j** — dedicated graph database for complex social queries (mutual friends, suggested connections); only justified at significant social scale.
- **Fan-out-on-write activity feed** — write session completion events to each follower's feed at write time; preferred for users with fewer than ~10k followers.
- **Fan-out-on-read activity feed** — aggregate at request time; simpler to implement but slower at read time; better for high-follower accounts.
- **Coach review async model** — coach reviews a session recording and leaves timestamped annotations stored as JSON; lower complexity than live WebRTC co-session and appropriate for the initial version.
- **WebRTC for live co-session** — enables real-time joint sessions; high implementation complexity, justified only after async review is established.

### Accessibility

- **VoiceOver audit** — all custom views need `accessibilityLabel`, `accessibilityValue`, and `accessibilityHint`; all interactive elements must be reachable in the VoiceOver element order.
- **Dynamic Type** — verify all `Text` views use semantic font styles (`.body`, `.headline`, not fixed sizes); test at the largest accessibility text size.
- **WCAG contrast** — the app's orange (`#FF6B35`) on dark backgrounds must meet the 4.5:1 contrast ratio at all opacity levels used in the UI.
- **Switch Control** — ensure tab order and focus groups are logical; custom gestures such as the long-press end-session button require an accessible alternative activation method.

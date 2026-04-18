# Production Readiness Checklist

**Last updated:** 2026-04-18
**Status:** Active — items move from ⏳ to ✅ as they ship.

This document tracks everything that is deliberately dev-only, placeholder, or deferred in the current codebase. It must reach zero P0 items before the first App Store submission.

**Priority:**
- **P0 — Blocking:** must be done before App Store submission. Security/legal/compliance/"user can't use the app" items.
- **P1 — High:** should be done before significant user growth. Reliability, support burden, polish.
- **P2 — Nice to have:** improves the experience but not required for launch.

---

## Authentication (Phase 8) — Supabase

### P0 — Blocking

- ⏳ **Custom SMTP sender domain**
  - *Current:* Dev uses Resend with `onboarding@resend.dev` as the sender.
  - *Required:* Add `hooptrack.app` (or chosen domain) to Resend → Domains. Add all DNS records at the registrar (MX, SPF, DKIM, DMARC). Wait for all four green checkmarks. Update Supabase **Project Settings → Auth → SMTP Settings → Sender email** to `noreply@hooptrack.app`. Smoke-test a signup email in production target.

- ⏳ **Confirm email enabled**
  - *Current:* May be toggled off in dev to bypass rate limits.
  - *Required:* Supabase dashboard → **Authentication → Providers → Email → Confirm email: ON**. Production users must verify.

- ⏳ **Site URL + redirect allow-list matches the production bundle**
  - *Current:* `hooptrack://auth/callback` configured in dev project.
  - *Required:* Same URL configured in the **production** Supabase project (if separate from dev). Plus an **HTTPS Universal Link** option (e.g. `https://hooptrack.app/auth/callback`) for email clients that refuse to follow non-HTTPS redirects. Requires an `apple-app-site-association` file hosted at `/.well-known/apple-app-site-association` on the domain.

- ⏳ **Forgot-password flow**
  - *Current:* Not implemented. A user who forgets their password cannot recover the account.
  - *Required:* New `ForgotPasswordView` off `SignInView`. Calls `client.resetPasswordForEmail(_:redirectTo:)`. Deep link handler recognises the password-reset callback and surfaces a `SetNewPasswordView`. ~2 hours of work.

- ⏳ **Server-side account deletion**
  - *Current:* `DataService.deleteAllUserData()` wipes local SwiftData, files, Keychain, UserDefaults. Does **not** delete the Supabase user.
  - *Required:* Add a Supabase Edge Function that deletes the authenticated user (`auth.admin.deleteUser(uid)`). App calls it from `DataService.deleteAllUserData()` before wiping local state. Required for App Store "Sign in with X" compliance if any social login is later added, and for GDPR / App Store Guideline 5.1.1(v) ("Account Deletion").

- ⏳ **PKCE vs. OTP flow decision**
  - *Current:* PKCE flow + custom URL scheme. Works on iOS Mail, fragile with email-preview scanners (Outlook, corporate Gmail) that can pre-consume tokens.
  - *Required:* Either (a) switch email template to a 6-digit OTP code and add a code-entry UI in `VerifyEmailView`, or (b) set up Universal Links properly (see above) so links open in-app without going through a browser. Option (a) is safer and takes ~1 hour.

### P1 — High

- ⏳ **Supabase-swift version pin**
  - *Current:* SPM rule "Up to Next Major Version" from 2.0.0.
  - *Recommended:* Pin to an exact tested version before submission. Bump deliberately between releases.

- ⏳ **Password complexity enforcement**
  - *Current:* Minimum 8 characters (`HoopTrack.Auth.minPasswordLength`). No character-class requirements.
  - *Recommended:* Add optional client-side checks (at least one letter + one number) or defer entirely to Supabase's server-side policy configured in the dashboard. Don't ship weaker than "8 chars + 1 digit".

- ⏳ **Rate-limit client-side retry**
  - *Current:* `AuthViewModel` fires sign-up / sign-in on button tap with no throttling.
  - *Recommended:* Disable the button for 2s after a tap, and after N consecutive failures show a cooldown message. Prevents users from hammering their own rate limit.

- ⏳ **Session refresh edge cases**
  - *Current:* Rely on supabase-swift's internal refresh logic.
  - *Recommended:* Manual test: force a stale token (edit expiry in Supabase dashboard if possible), attempt a restore, confirm the SDK either refreshes transparently or lands in `.unauthenticated` with a clear error. Today we haven't explicitly verified this path.

- ⏳ **Offline launch UX**
  - *Current:* `AuthViewModel.restore()` catches any `provider.restoreSession()` error and lands in `.unauthenticated`. A user on airplane mode at launch sees the sign-in screen, not a "no internet" message.
  - *Recommended:* When `AuthError.networkUnavailable` is surfaced during restore, preserve the last-known user from Keychain and show a "offline" banner instead of kicking the user back to sign-in.

- ⏳ **Change email / change password UI**
  - *Current:* Not implemented. Settings only has Sign Out and Delete All Data.
  - *Recommended:* Add a `ChangePasswordView` and `ChangeEmailView` in the Profile → Account section. Supabase API: `client.update(user: UserAttributes(email: …))` / `(password: …)`.

- ⏳ **Sign in with Apple as additional provider**
  - *Current:* Intentionally skipped in Phase 8. `AuthProviding` is generic so this is an additive change.
  - *Recommended:* Add once the app has an App Store listing. Requires paid Apple Developer membership and ~2 hours to wire up `ASAuthorizationAppleIDButton` + Supabase's `signInWithIdToken` for Apple.

### P2 — Nice to have

- ⏳ **Configurable biometric timeout**
  - *Current:* Hard-coded 60s (`HoopTrack.Auth.backgroundLockTimeoutSec`).
  - *Could:* Expose in Settings as "Require unlock after" with options 0 / 30s / 1 min / 5 min / Never.

- ⏳ **"Remember me" / skip biometric option**
  - For users who trust their device and don't want the lock screen at all.

- ⏳ **Email change re-verification**
  - If a user changes their email in-app, enforce re-verification on the new address before the change is permanent.

---

## Security (Phase 7) — Cert Pinning + Privacy Manifest

### P0 — Blocking

- ✅ **Real Supabase SPKI SHA-256 hash in `PinningURLSessionDelegate`** — shipped in Phase 9 (commit `4cbd258`). Primary pin is the GTS WE1 intermediate; backup pin is the supabase.co leaf. Both EC P-256.
- ⏳ **Wire `PinningURLSessionDelegate` into the supabase-swift URLSession** — NEW. The delegate has real hashes but is not yet routed to; supabase-swift uses its own default `URLSession`. Construct a custom `URLSessionConfiguration` and pass it into `AuthClient.Configuration` + `PostgrestClient` init. Without this, the pin hashes are scenery — TLS still validates via system trust only.

- ⏳ **Privacy manifest audit for all SPM dependencies**
  - *Current:* `PrivacyInfo.xcprivacy` declares our first-party data categories from Phase 7.
  - *Required:* `supabase-swift` and its transitive dependencies must each have their own privacy manifests. Apple requires the app's manifest to include the full list of "required reason API" declarations from the SDKs we use. If `supabase-swift` doesn't ship one (check its repo), we have to document its uses in ours.

- ⏳ **BackendSecrets.swift safety**
  - *Current:* Gitignored. Local copy has real anon key.
  - *Verified:* `git log` contains no `BackendSecrets.swift` blob. (Confirm before submission: `git log --all --full-history -- "**/BackendSecrets.swift"` returns empty.)

### P1 — High

- ⏳ **`NSFaceIDUsageDescription` copy review**
  - *Current:* "HoopTrack uses Face ID to unlock the app after it's been in the background."
  - *Recommended:* Final legal/marketing review. App Store reviewers are strict about these strings being accurate.

---

## CV Detection (Ongoing — Ball + Rim)

### P0 — Blocking

- ⏳ **Ship a production `.mlpackage` / `.mlmodelc`**
  - *Current:* `BallDetector.mlmodel` is v1 (yolov8s, 40 epochs, mAP50 0.988) trained on the public Roboflow dataset.
  - *Required:* Either (a) ship v1 as the launch model, OR (b) collect ≥ 20 sessions of real HoopTrack footage via `upgrade-cv-detection.md` Phase A, retrain, and ship v2. Don't ship the synthetic `BallDetectorStub` in production.

- ⏳ **`BallDetectorStub` gated to simulator/debug only**
  - *Current:* `BallDetectorFactory.active` returns `.bundled` always. Stub compiles into every build as a compile-time safety net but is never selected at runtime.
  - *Recommended:* Confirm the production archive does not include the stub in a runtime-reachable path. `grep -r BallDetectorStub` in the built `.app` should return nothing.

### P1 — High

- ⏳ **Remove raw-YOLO fallback decoder once confident**
  - *Current:* `CoreMLBallDetector.decodeYOLO()` exists as a safety net for non-NMS model exports. Dead code today since our bundled model has NMS.
  - *Recommended:* Keep for one or two releases in case a future model retrain accidentally ships without NMS. Remove in the v1.1 release after verifying the NMS path is the only one used in telemetry.

- ⏳ **Phase A telemetry foundation (see `docs/upgrade-cv-detection.md`)**
  - Shot telemetry capture + eval fixture + user-correction UI. Ships before Phase B retrain. This is the foundation for improving detection accuracy on real HoopTrack footage.

### P2 — Nice to have

- ⏳ **Detection overlay removal or gated toggle**
  - *Current:* `DetectionOverlay` always draws over the camera preview (green rim + orange ball boxes). Was shipped as a temporary debug aid.
  - *User decision:* Remove entirely once CV detection is trusted, or move behind a Settings toggle for power users. I've been explicitly asked to leave it until verification is done.

---

## Backend & Database (Phase 9 — Not Started)

### P0 — Blocking (once Phase 9 begins)

- ✅ **Postgres schema + RLS policies** — shipped in Phase 9. Five tables, 16 RLS policies keyed on `auth.uid()`, `shot_records` is append-only.
- ✅ **`cloudSyncedAt: Date?` on synced models** — shipped in Phase 9 as additive nullable field. No migration plan required.
- ⏳ **Conflict resolution logic tested** — NOT YET. Current Phase 9 is upload-only. Scalar LWW by `updated_at` (server-set via trigger) and set-union on `shot_records` happen automatically in the DB, but the *client* doesn't yet read back / reconcile. Lands with Phase 9.5 when cross-device restore ships.
- ⏳ **`InitialSyncCoordinator`** — NEW. Users upgrading from pre-Phase-9 builds have local-only history. Needs a one-shot batch-upload pass on first authenticated launch.
- ⏳ **Config.xcconfig or similar for separate dev / staging / prod projects**
  - *Current:* Single project (`nfzhqcgofuohsjhtxvqa`), shared between dev testing and any future prod traffic.
  - *Recommended:* Three Supabase projects. Xcode build configuration selects which URL + anon key baked in. Avoids a dev-only database with prod data.
- ⏳ **Stable enum export keys** — NEW. DTOs today serialize enum `rawValue` (display strings like "Free Shoot", "Mid-Range", "Make"). A UI relabel would create schema mismatch with existing Postgres rows. Introduce stable codes on `DrillType`, `ShotResult`, `ShotType`, `SkillDimension`, `GoalMetric` analogous to the existing `CourtZone.exportKey` pattern, then use those in DTOs.

### P1 — High

- ⏳ **Fire-and-forget sync on session finalization**
  - Non-fatal: upload failure does not roll back session save. Surface a retry mechanism somewhere.

- ⏳ **Initial sync coordinator for upgrading users**
  - Users who installed before Phase 9 have local-only data. On first sign-in post-upgrade, batch-upsert existing records to Supabase.

---

## App Store Submission

### P0 — Blocking

- ⏳ **App Store Connect metadata**
  - App name, subtitle, description, keywords, categories, age rating.
  - Screenshots at required iPhone sizes (6.7″, 6.5″, 5.5″) — App Store Connect rejects without these.
  - Privacy Policy URL (required for any app collecting data).
  - Support URL.
  - Marketing URL (optional but recommended).

- ⏳ **Age rating form filled accurately**
  - HoopTrack isn't mature content but uses the camera and sends data. Confirm the rating matches reality.

- ⏳ **Privacy nutrition label**
  - App Store Connect → Privacy. Declare every data category we collect, whether it's linked to the user's identity, and whether it's used for tracking. Must match `PrivacyInfo.xcprivacy` and actual behaviour. Easy to get wrong; re-review before every submission.

- ⏳ **Real App Store build signed with distribution cert**
  - *Current:* All builds are development-signed.
  - *Required:* Production scheme with distribution provisioning profile. Upload via Xcode Organizer or `xcodebuild -exportArchive`.

- ⏳ **Export compliance statement**
  - Because we use TLS and auth tokens (cryptography), the Info.plist may need `ITSAppUsesNonExemptEncryption = false` (we only use standard TLS) or a real export compliance number.

### P1 — High

- ⏳ **TestFlight internal beta smoke pass**
  - All auth flows, CV pipeline, session save, HealthKit write, exports, sign-out. Run through the Task-15 manual smoke from `2026-04-18-phase-8-auth.md`.

- ⏳ **Crash reporting**
  - MetricKit is already wired (`MetricsService`). Verify dashboards exist in App Store Connect Analytics once the app is live. Or bring in a third-party reporter (Sentry, Crashlytics) if App Store Connect's defaults are insufficient.

- ⏳ **Accessibility audit**
  - VoiceOver labels on every interactive element (including `HoldToEndButton` and `DetectionOverlay`).
  - Dynamic Type behaviour.
  - Colour-contrast ratios AA on key text (sign-in orange gradient text on dark background is borderline).

---

## Environment & Config

### P0 — Blocking

- ⏳ **Separate dev / staging / prod Supabase projects**
  - *Current:* Single project (dev).
  - *Required:* At minimum, a separate production project so dev tinkering can't nuke real user data. Three-tier (dev/staging/prod) is ideal.

- ⏳ **Distinct `BackendSecrets.swift` per environment**
  - Xcode build configurations can select different files via `EXCLUDED_SOURCE_FILE_NAMES`, or we use a single file whose values come from build settings fed by xcconfig per configuration. Either works.

### P1 — High

- ⏳ **Feature flags for risky new code**
  - No feature-flag infrastructure today. Phase 9 sync and CV v2 both benefit from a remote kill switch. Simplest path: a Supabase table `feature_flags` + a `FeatureFlagService` that caches values.

---

## Open Questions

Decisions to make before or during each phase:

1. **Universal Links vs URL scheme for auth callback** — Universal Links are required for production-quality email confirmation, but setup is a 1–2 day task (Apple Services ID + apple-app-site-association hosting + domain verification). Decide whether to stand up the domain infrastructure for launch or ship with URL scheme + OTP fallback.

2. **Custom sender domain** — `noreply@hooptrack.app` requires that domain to be owned + DNS-configured. If the domain is still being negotiated, launch with `onboarding@resend.dev` as the sender and swap later. Users will see Resend's domain in the From line during the interim.

3. **OTP vs email link as primary confirmation method** — OTP is robust to email scanners and shorter to type than a URL. Email link is more familiar UX. Pick one.

4. **Dev vs production Supabase project boundary** — are we willing to migrate existing dev users (sessions, shots, goals) into the production database, or start fresh? If fresh, users will lose their history. Likely fine for a pre-launch beta group.

5. **Crash-reporting vendor** — App Store Connect Analytics (free, Apple-native, delayed data) vs Sentry/Crashlytics (real-time, costs money after free tier). Nothing stops doing both.

---

## Tracking

Every P0 item flipping to ✅ moves one step closer to App Store submission. Re-check this document before every release. Don't add items without removing the ones they replace.

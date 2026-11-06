# Production Readiness Checklist

**Last updated:** 2026-11-07
**Status:** Active — items move from ⏳ to ✅ as they ship (🟡 = code done, a dashboard or App Store Connect step remains; ❎ = decided against, with the reason).

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

- ✅ **Forgot-password flow** (Nov 2026)
  - Account sheet → "Forgot password?" sends `resetPasswordForEmail` with `hooptrack://auth/reset`. The link signs the user in, and `SetNewPasswordView` asks for the new password.
  - *Still needed (dashboard):* allow-list `hooptrack://auth/reset` under Redirect URLs.

- ✅ **Server-side account deletion** (Nov 2026)
  - Profile → Delete account calls the `delete-account` Edge Function (`supabase/functions/delete-account`). It deletes the user's rows, their telemetry files and the auth user.
  - "Delete all my data" deletes the account first and stops if the server can't be reached.
  - *Still needed:* `supabase functions deploy delete-account` (see `supabase/README.md`).

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
- ❎ **Wire `PinningURLSessionDelegate` into supabase-swift: decided against** (Nov 2026)
  - The delegate had a bug: it only hashed the leaf certificate, while the primary pin is the intermediate. Wired in, every request would have failed after the first leaf renewal. Now fixed: any certificate in the chain matches, and every key type is handled.
  - Still deliberately unwired. `*.supabase.co` is served through Cloudflare, which renews about every 90 days and can switch CA (Let's Encrypt, Google Trust Services, SSL.com) without notice. Pins would eventually lock every user out until an app update. ATS already enforces TLS and a valid chain. The class doc says how to enable it if that changes.

- ✅ **Privacy manifest audit** (Nov 2026)
  - supabase-swift 2.43.1 and its dependencies use no required-reason APIs and ship no manifest.
  - `PrivacyInfo.xcprivacy` now lists what is actually sent: email, user ID, fitness data, and opt-in frames and diagnostics. It dropped two declarations: "Health", which is never sent, and the invalid "VideoAndSoundData".
  - Label answers: `docs/app-store/privacy.md`.

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

- ✅ **`BallDetectorStub` gated to debug only** (Nov 2026)
  - `BallDetectorStub` is wrapped in `#if DEBUG`; in a release build `.stub` returns nil (manual mode), so a fake detector can't ship.
- ⏳ **Detector licence** (Nov 2026)
  - *Current:* The bundled model is Ultralytics YOLO, AGPL-3.0. See `docs/training-review-2026-11.md`.
  - *Required:* An Ultralytics Enterprise licence, or a model trained with Create ML or an Apache-2.0 detector, before the first App Store build.

### P1 — High

- ✅ **Raw-YOLO fallback decoder removed** (Nov 2026)
  - The detector reads Vision's NMS output only. `Tools/training/train_detector.py` always exports with NMS.

- ✅ **Phase A telemetry foundation** (Nov 2026)
  - Capture: `detections.jsonl` plus `manifest.json`, which records each frame's boxes and each shot's outcome.
  - Eval: `swift run shot-eval`.
  - Correction UI: "Check" flags, edit and undo.
  - Dataset and retraining: `Tools/dataset`, `Tools/training`.
  - *Still needed:* real labelled sessions (see `docs/cv-review-2026-11.md`, "Next").

### P2 — Nice to have

- ⏳ **Detection overlay removal or gated toggle**
  - *Current:* `DetectionOverlay` always draws over the camera preview (green rim + orange ball boxes). Was shipped as a temporary debug aid.
  - *User decision:* Remove entirely once CV detection is trusted, or move behind a Settings toggle for power users. I've been explicitly asked to leave it until verification is done.

---

## Backend & Database (Phase 9 — Not Started)

> **7 Nov 2026:** `nfzhqcgofuohsjhtxvqa.supabase.co` returns NXDOMAIN; the
> domain no longer exists, so the project is paused or deleted. Sign-in
> and sync can't work until it's restored or replaced. Free projects pause
> after a week without traffic.

### P0 — Blocking (once Phase 9 begins)

- ✅ **Postgres schema + RLS policies** — shipped in Phase 9. Five tables, 16 RLS policies keyed on `auth.uid()`, `shot_records` is append-only.
- ✅ **`cloudSyncedAt: Date?` on synced models** — shipped in Phase 9 as additive nullable field. No migration plan required.
- ✅ **Restore and reconciliation** (Nov 2026)
  - `SyncCoordinator.restore` adds the sessions (with shots), goals and badges a phone doesn't have, matched by id. Local copies always win, and shots are only added to sessions restored at the same time.
  - It runs automatically on a phone with no history (new phone or reinstall). On a phone with history it only runs from Profile → Restore from backup, because sessions deleted locally still exist in the cloud.
  - Tests: `CloudBackupTests`.
  - *Limitation:* there's no delete sync yet, so a session deleted on one phone stays in the cloud.
- ✅ **Initial sync** (Nov 2026)
  - `SyncCoordinator.backUpEverything` runs after every sign-in and launch while signed in (`AppServices.syncCloudBackup`). It uploads every finished session or shot not yet in the cloud, plus profile, goals and badges.
  - Shot uploads skip rows already there. They used to re-insert every shot on each sync, so any retry failed on duplicate ids.
  - Corrections mark the session for re-upload.
- ⏳ **Config.xcconfig or similar for separate dev / staging / prod projects**
  - *Current:* Single project (`nfzhqcgofuohsjhtxvqa`), shared between dev testing and any future prod traffic.
  - *Recommended:* Three Supabase projects. Xcode build configuration selects which URL + anon key baked in. Avoids a dev-only database with prod data.
- ✅ **Stable enum keys** (Nov 2026)
  - Raw values are frozen as storage keys. SwiftData uses them too, not just the DTOs. Every enum shown in the UI has a `displayName`.
  - `PersistedKeysTests` fails if a key changes, so existing Postgres rows keep matching and no database migration is needed.

### P1 — High

- ✅ **Retry for failed uploads** (Nov 2026)
  - A failed post-session upload leaves `cloudSyncedAt` nil, and the next launch's backup pass sends it.

- 🟡 **Corrected shots in the backup**
  - `shot_records` is insert-only, so a corrected result can't overwrite the uploaded one, and a restore brings back the original call.
  - *To do:* apply `supabase/migrations/20261107000000_shot_record_updates.sql`, then set `HoopTrack.Backend.shotRowsUpdatable = true`.

---

## App Store Submission

### P0 — Blocking

- 🟡 **App Store Connect metadata** (drafted Nov 2026)
  - Name, subtitle, description, keywords, categories, review notes and screenshot list: `docs/app-store/listing.md`.
  - Privacy policy draft: `docs/app-store/privacy-policy.md`.
  - *Still needed:* host the policy and a support page, then take the screenshots.

- 🟡 **Age rating form**
  - 4+, with "None" for every content question. See `docs/app-store/listing.md`. Fill it in App Store Connect.

- 🟡 **Privacy nutrition label**
  - The answers are in `docs/app-store/privacy.md` and match `PrivacyInfo.xcprivacy`. Enter them in App Store Connect.

- ⏳ **Real App Store build signed with distribution cert**
  - *Current:* All builds are development-signed.
  - *Required:* Production scheme with distribution provisioning profile. Upload via Xcode Organizer or `xcodebuild -exportArchive`.

- ✅ **Export compliance** (Nov 2026)
  - `ITSAppUsesNonExemptEncryption = NO` in Info.plist. The app only uses standard Apple TLS and the Keychain.

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

- 🟡 **Distinct backend per environment** (Nov 2026)
  - `BackendSecrets.swift.example` now has a development project for Debug and a production one for Release (`#if DEBUG`), with no project-file changes.
  - *Still needed:* create the production project, then update the local `BackendSecrets.swift` to the new shape.

### P1 — High

- ⏳ **Feature flags for risky new code**
  - No feature-flag infrastructure today. Phase 9 sync and CV v2 both benefit from a remote kill switch. Simplest path: a Supabase table `feature_flags` + a `FeatureFlagService` that caches values.

---

## CV-A Telemetry (unreleased, dev-only today)

### P0 — Blocking

- ✅ **CV-A telemetry is opt-in** (Nov 2026)
  - Profile → Privacy → "Help improve shot tracking", off by default. It needs an account, and nothing is logged or uploaded without it.

- ✅ **Game-mode privacy**
  - Pickup games don't record video or telemetry, so no other players' frames are captured. Training sessions can still catch bystanders; the privacy policy asks users to turn sharing on only when people in view are happy with it.

### P1 — High

- 🟡 **Telemetry dataset puller**
  - `Tools/dataset/build_dataset.py` turns downloaded sessions into a YOLO dataset with a review list.
  - *Still needed:* a script that downloads the `telemetry-sessions` bucket and empties it. It needs the service key, so it runs on Ben's machine only.

- ⏳ **Supabase Storage cost revisit**
  - *Current:* Free tier is fine at dev volumes with the staging-area pattern (bucket is transit-only, puller empties it).
  - *Revisit trigger:* If the app ever ships with CV-A active for multiple users, re-evaluate bucket size + egress against Supabase Pro pricing. At that point the staging pattern may need to become a push-then-process pipeline instead of push-then-pull.

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

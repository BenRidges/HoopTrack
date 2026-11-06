# Privacy: label answers and manifest

What HoopTrack sends off the phone. Audited November 2026 against the code.
App Store Connect's privacy label and `PrivacyInfo.xcprivacy` must both say
the same thing. Re-check before every submission that adds a network call.

## What leaves the phone

| Data | When | Where | Linked to the user |
|---|---|---|---|
| Email address | Signing up / in | Supabase Auth | Yes |
| User ID | Signed in | Supabase (every row) | Yes |
| Sessions, shots, goals, badges | Signed in (cloud backup) | Supabase Postgres | Yes |
| Sampled video frames + detection logs | Signed in **and** "Help improve shot tracking" on (off by default) | Supabase Storage | Yes |

What never leaves the phone:
- session videos;
- Apple Health workouts (the app writes them; nothing is read back or sent);
- pickup-game player appearance data;
- MetricKit diagnostics;
- the Face ID result.

There's no advertising, no analytics SDK, no tracking and no third-party
data sharing.

## App Store Connect answers

"Do you or your third-party partners collect data from this app?" **Yes.**

| Category → type | Collected | Linked | Tracking | Purposes |
|---|---|---|---|---|
| Contact Info → Email Address | Yes | Yes | No | App Functionality |
| Identifiers → User ID | Yes | Yes | No | App Functionality |
| Health & Fitness → Fitness | Yes | Yes | No | App Functionality |
| User Content → Photos or Videos | Yes | Yes | No | App Functionality, Analytics |
| Diagnostics → Other Diagnostic Data | Yes | Yes | No | App Functionality, Analytics |

Everything else: not collected. The frames and logs are used only to
retrain the shot detector. If Apple's reviewer reads that as Product
Personalization rather than Analytics, change both places together.

## Account deletion

Profile → Cloud backup → Delete account calls the `delete-account` Edge
Function (`supabase/functions`). It removes the user's rows, their shared
telemetry files and the auth user. "Delete all my data" does the same and
then wipes the phone. Guideline 5.1.1(v) is covered once the function is
deployed.

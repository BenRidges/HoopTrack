# Coach Review Mode — Technical Extension Plan

**Status:** Design / Pre-implementation  
**Date:** 2026-04-12  
**Depends on:** upgrade-authentication-identity, upgrade-backend-api, upgrade-postgresql-supabase, upgrade-file-media-storage, upgrade-web-presence

---

## 1. Overview

Coach Review Mode is an async, annotation-based review workflow. There is no live co-session or WebRTC; instead, a coach reviews a recorded session at any convenient time and leaves timestamped feedback that the athlete reads on their own schedule. This matches real coaching workflows (where coaches watch film independently) and avoids the operational complexity of synchronised video calls.

### What a review contains

- The session recording (`.mov` already uploaded to Supabase Storage)
- Session-level metrics: FG%, Shot Science averages, zone heat map, agility times
- Per-shot records: court position, release angle, outcome, timestamp
- One or more **annotations** authored by the coach: timestamped markers tied to video seconds or specific shot records, each carrying text, a freehand draw path, or a zone highlight

### Two surfaces

| Surface | Role |
|---|---|
| iOS app (`SessionAnnotationsView`) | Athlete reads coach feedback; taps annotation to scrub video |
| Next.js web dashboard (`/dashboard/review/[session_id]`) | Coach watches video, inspects shot chart, writes annotations |

The web dashboard is the sole authoring surface in v1. A native iOS authoring view (coach on iPhone) is a later milestone.

---

## 2. Coach Role and Permissions

### User type field

Add a `role` column to `player_profiles`:

```sql
alter table player_profiles
  add column role text not null default 'athlete'
  check (role in ('athlete', 'coach'));
```

A user is a coach when `role = 'coach'`. Coaches authenticate via the same Sign in with Apple → Supabase Auth path as athletes; the role is set at onboarding.

### Coach-athlete relationship

```sql
create table coach_athletes (
  id          uuid primary key default gen_random_uuid(),
  coach_id    uuid not null references player_profiles(id) on delete cascade,
  athlete_id  uuid not null references player_profiles(id) on delete cascade,
  status      text not null default 'pending'
             check (status in ('pending', 'active', 'revoked')),
  invited_at  timestamptz not null default now(),
  accepted_at timestamptz,
  unique (coach_id, athlete_id)
);

create index idx_coach_athletes_athlete on coach_athletes(athlete_id);
create index idx_coach_athletes_coach   on coach_athletes(coach_id);
```

`status = 'pending'` when the invite link has been sent but the coach has not yet accepted.  
`status = 'active'` after the coach taps the invite link and confirms.  
`status = 'revoked'` when the athlete removes the coach; the row is kept for audit.

### Invite flow (athlete initiates)

1. Athlete taps **Add Coach** in their Profile tab.
2. App calls an Edge Function (`POST /functions/v1/generate-coach-invite`) which:
   - Creates a `coach_athletes` row with `status = 'pending'`
   - Returns a short-lived signed JWT (24 h) embedding `{ athlete_id, relationship_id }`
3. iOS presents a share sheet with a deep link: `https://app.hooptrack.io/invite/coach?token=<jwt>`
4. Coach opens the link in a browser → web dashboard shows the athlete profile preview → coach taps **Accept** → Edge Function (`POST /functions/v1/accept-coach-invite`) verifies the JWT and sets `status = 'active'`.

### RLS policies for coach access

```sql
-- Coaches can read sessions belonging to their active athletes
create policy "coach reads athlete sessions"
on training_sessions for select
using (
  exists (
    select 1 from coach_athletes ca
    where ca.coach_id  = auth.uid()
      and ca.athlete_id = training_sessions.player_id
      and ca.status    = 'active'
  )
);

-- Coaches can read shot records for those sessions
create policy "coach reads athlete shots"
on shot_records for select
using (
  exists (
    select 1 from training_sessions ts
    join coach_athletes ca on ca.athlete_id = ts.player_id
    where ts.id        = shot_records.session_id
      and ca.coach_id  = auth.uid()
      and ca.status    = 'active'
  )
);
```

Coaches cannot read `player_profiles` health columns (HealthKit-sourced fields) — those columns are excluded from the coach-facing API response at the application layer.

---

## 3. Database Schema Additions

### `session_shares`

Tracks each discrete share event so the athlete can revoke access on a per-share basis.

```sql
create table session_shares (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references training_sessions(id) on delete cascade,
  shared_by     uuid not null references player_profiles(id),
  shared_with   uuid references player_profiles(id),   -- null until coach claims the share
  share_token   text not null unique,                  -- opaque token embedded in the share URL
  permissions   text[] not null default array['read'], -- future: ['read','annotate']
  expires_at    timestamptz not null default (now() + interval '30 days'),
  revoked_at    timestamptz,
  created_at    timestamptz not null default now()
);

create index idx_session_shares_session  on session_shares(session_id);
create index idx_session_shares_token    on session_shares(share_token);
create index idx_session_shares_with     on session_shares(shared_with);
```

A share is considered active when: `revoked_at is null` and `expires_at > now()`.

### `session_annotations`

```sql
create table session_annotations (
  id               uuid primary key default gen_random_uuid(),
  session_id       uuid not null references training_sessions(id) on delete cascade,
  share_id         uuid references session_shares(id) on delete set null,
  coach_id         uuid not null references player_profiles(id),
  shot_record_id   uuid references shot_records(id) on delete set null,  -- optional link to specific shot
  timestamp_seconds numeric(8,3),   -- video timestamp; null for session-level notes
  annotation_type  text not null check (annotation_type in ('text','draw','zone_highlight')),
  content          jsonb not null,
  is_read          boolean not null default false,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index idx_annotations_session   on session_annotations(session_id);
create index idx_annotations_coach     on session_annotations(coach_id);
create index idx_annotations_timestamp on session_annotations(session_id, timestamp_seconds);
```

The composite index on `(session_id, timestamp_seconds)` supports efficient timeline queries for rendering marker positions.

### RLS on annotations

```sql
-- Athlete reads annotations on their own sessions
create policy "athlete reads own annotations"
on session_annotations for select
using (
  exists (
    select 1 from training_sessions ts
    where ts.id = session_annotations.session_id
      and ts.player_id = auth.uid()
  )
);

-- Coach reads/writes annotations they authored
create policy "coach manages own annotations"
on session_annotations for all
using  (coach_id = auth.uid())
with check (coach_id = auth.uid());
```

---

## 4. Share Flow (iOS)

### `ShareSessionSheet`

A SwiftUI sheet presented from the session summary view (`SessionSummaryView`). The sheet:

1. Shows a preview card (session date, FG%, zone thumbnail).
2. Has a **Share with Coach** primary action. If no active coach relationship exists, offers **Add Coach** instead.
3. For existing active coaches, shows a list of coach names; athlete selects one or more.
4. Tapping **Send** calls `SessionSharingService.createShare(sessionId:coachId:)`.

```swift
// SessionSharingService.swift
actor SessionSharingService {

    private let apiService: APIService

    func createShare(sessionId: UUID, coachId: UUID) async throws -> SessionShare {
        let response = try await apiService.post(
            path: "/functions/v1/create-session-share",
            body: CreateShareRequest(sessionId: sessionId, sharedWith: coachId)
        )
        return try response.decode(SessionShare.self)
    }

    func revokeShare(shareId: UUID) async throws {
        try await apiService.patch(
            path: "/functions/v1/revoke-session-share/\(shareId)",
            body: EmptyBody()
        )
    }
}
```

### Edge Function: `create-session-share`

```typescript
// supabase/functions/create-session-share/index.ts
import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { SignJWT } from "https://deno.land/x/jose/index.ts";

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  const { sessionId, sharedWith } = await req.json();
  const callerJwt = req.headers.get("Authorization")!.replace("Bearer ", "");

  // Verify caller owns the session
  const { data: session } = await supabase
    .from("training_sessions")
    .select("id, player_id")
    .eq("id", sessionId)
    .single();

  const secret = new TextEncoder().encode(Deno.env.get("SHARE_JWT_SECRET")!);
  const shareToken = await new SignJWT({ sessionId, sharedWith })
    .setProtectedHeader({ alg: "HS256" })
    .setExpirationTime("30d")
    .sign(secret);

  const { data: share } = await supabase
    .from("session_shares")
    .insert({
      session_id: sessionId,
      shared_by: session.player_id,
      shared_with: sharedWith,
      share_token: shareToken,
      expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
    })
    .select()
    .single();

  // Send push notification to coach (OneSignal or APNs — see §8)
  await notifyCoach(sharedWith, sessionId);

  return new Response(JSON.stringify(share), {
    headers: { "Content-Type": "application/json" },
  });
});
```

After `createShare` resolves, the iOS app invokes the system share sheet (`ShareLink` / `UIActivityViewController`) with a deep link URL:

```
https://app.hooptrack.io/review?token=<shareToken>
```

The athlete can send this via iMessage, email, or copy it. The coach taps the link on any device and is directed to the web dashboard.

---

## 5. Coach Web Review Interface

Route: `/dashboard/review/[session_id]` in the Next.js app.

### Page layout

```
┌─────────────────────────────┬──────────────────────┐
│  Video Player               │  Annotation Sidebar  │
│  (signed URL, <video>)      │  ┌────────────────┐  │
│                             │  │ Annotation list│  │
│  ─────────────────────────  │  │ (scrollable,   │  │
│  Timeline scrubber          │  │ sorted by ts)  │  │
│  ● ●  ●      ●   ●          │  └────────────────┘  │
│  (shot markers)             │  ┌────────────────┐  │
├─────────────────────────────│  │ New annotation │  │
│  Shot Chart (court SVG)     │  │ input (text /  │  │
│  Heat map overlay           │  │ draw toggle)   │  │
│                             │  └────────────────┘  │
└─────────────────────────────┴──────────────────────┘
```

### Key interactions

- **Shot chart click** — each `ShotRecord` bubble is rendered at its `(normalised_x, normalised_y)` position. Clicking a bubble calls `videoRef.currentTime = shot.video_timestamp_seconds` and opens the annotation input pre-filled with that shot's timestamp.
- **Timeline scrubber** — a custom `<input type="range">` overlaid with annotation marker ticks at their `timestamp_seconds / video_duration` positions. Clicking a tick jumps the video to that point and highlights the annotation in the sidebar.
- **Annotation input** — appears at the bottom of the sidebar. Type switches between `text` and `draw`. Current `videoRef.currentTime` is captured as `timestamp_seconds` at the moment the coach starts typing or drawing.

### Video component (Next.js)

```tsx
// components/ReviewVideoPlayer.tsx
"use client";
import { useRef, useEffect } from "react";

interface Props {
  signedUrl: string;
  annotations: Annotation[];
  onTimeUpdate: (seconds: number) => void;
  seekTo?: number;
}

export function ReviewVideoPlayer({ signedUrl, annotations, onTimeUpdate, seekTo }: Props) {
  const ref = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    if (seekTo !== undefined && ref.current) {
      ref.current.currentTime = seekTo;
    }
  }, [seekTo]);

  return (
    <video
      ref={ref}
      src={signedUrl}
      controls
      className="w-full rounded-lg"
      onTimeUpdate={() => onTimeUpdate(ref.current?.currentTime ?? 0)}
    />
  );
}
```

### Annotation submission

```typescript
// lib/annotations.ts
export async function createAnnotation(
  supabase: SupabaseClient,
  payload: {
    sessionId: string;
    shareId: string;
    timestampSeconds: number;
    shotRecordId?: string;
    type: "text" | "draw" | "zone_highlight";
    content: AnnotationContent;
  }
) {
  const { data, error } = await supabase
    .from("session_annotations")
    .insert({
      session_id: payload.sessionId,
      share_id: payload.shareId,
      coach_id: (await supabase.auth.getUser()).data.user!.id,
      shot_record_id: payload.shotRecordId ?? null,
      timestamp_seconds: payload.timestampSeconds,
      annotation_type: payload.type,
      content: payload.content,
    })
    .select()
    .single();

  if (error) throw error;
  return data;
}
```

---

## 6. Annotation Data Model

### `annotation_type` values and `content` schemas

#### `text`

Plain coaching note tied to a video timestamp.

```json
{
  "text": "Drive baseline here — don't pull up from the elbow.",
  "emphasis": "normal"
}
```

`emphasis`: `"normal" | "positive" | "critical"`

#### `draw`

Freehand path overlaid on the court or video frame.

```json
{
  "surface": "court",
  "paths": [
    {
      "d": "M 0.42 0.31 L 0.55 0.48 L 0.60 0.45",
      "color": "#FF3B30",
      "stroke_width": 2
    }
  ],
  "label": "Preferred drive lane"
}
```

`surface`: `"court" | "video"`. Court paths use normalised court coordinates `(0–1, 0–1)`. Video paths are normalised to frame dimensions. Storing as SVG `d` strings keeps content compact and renderer-agnostic.

#### `zone_highlight`

Highlights one or more named court zones with an optional instruction.

```json
{
  "zones": ["left_corner_3", "right_wing_3"],
  "action": "avoid",
  "note": "Shot efficiency drops significantly from these zones in your data."
}
```

`action`: `"focus" | "avoid" | "neutral"`

Zone names map to the existing `CourtZoneClassifier` identifiers already in the iOS codebase.

---

## 7. iOS Feedback View

### Notification badge

`TrainingSession` gains a computed property:

```swift
extension TrainingSession {
    var unreadAnnotationCount: Int {
        annotations.filter { !$0.isRead }.count
    }
}
```

The session row in the history list shows a blue badge when `unreadAnnotationCount > 0`.

### `SessionAnnotationsView`

Embedded as a tab or section within the existing session detail view.

```swift
struct SessionAnnotationsView: View {
    let session: TrainingSession
    @StateObject private var viewModel: SessionAnnotationsViewModel
    @State private var seekTarget: Double? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Video player
            VideoPlayerView(
                videoURL: viewModel.videoURL,
                seekTo: $seekTarget
            )
            .frame(height: 220)

            // Timeline scrubber with annotation markers
            AnnotationTimelineScrubber(
                duration: viewModel.videoDuration,
                currentTime: $viewModel.currentTime,
                annotations: viewModel.annotations
            ) { annotation in
                seekTarget = annotation.timestampSeconds
            }
            .frame(height: 44)
            .padding(.horizontal)

            // Annotation list
            List(viewModel.annotations) { annotation in
                AnnotationRow(annotation: annotation)
                    .onTapGesture {
                        seekTarget = annotation.timestampSeconds
                        Task { await viewModel.markRead(annotation) }
                    }
            }
        }
        .task { await viewModel.load() }
    }
}
```

### `AnnotationTimelineScrubber`

A custom `Canvas`-based view that renders:
- A horizontal track proportional to video duration
- Coloured tick marks at each annotation's `timestampSeconds / videoDuration` position
- The current playhead position

### Marking annotations as read

```swift
// SessionAnnotationsViewModel.swift
func markRead(_ annotation: SessionAnnotation) async {
    guard !annotation.isRead else { return }
    do {
        try await apiService.patch(
            path: "/rest/v1/session_annotations?id=eq.\(annotation.id)",
            body: ["is_read": true]
        )
        // Update local SwiftData model
        annotation.isRead = true
    } catch {
        // Non-fatal; badge will correct on next sync
    }
}
```

---

## 8. Push Notifications

### Trigger

When a coach submits their first annotation (or explicitly marks a review as "complete"), a Supabase Database Webhook fires on `INSERT` into `session_annotations`:

```sql
-- Supabase Dashboard: Database → Webhooks
-- Table: session_annotations
-- Events: INSERT
-- URL: https://<project>.functions.supabase.co/functions/v1/notify-athlete-annotation
```

### Edge Function: `notify-athlete-annotation`

```typescript
// supabase/functions/notify-athlete-annotation/index.ts
serve(async (req) => {
  const payload = await req.json(); // Supabase webhook payload
  const annotation = payload.record;

  // Fetch athlete's device token via player_profiles
  const { data: session } = await supabase
    .from("training_sessions")
    .select("player_id, player_profiles(onesignal_player_id, display_name)")
    .eq("id", annotation.session_id)
    .single();

  const athleteToken = session.player_profiles.onesignal_player_id;
  if (!athleteToken) return new Response("no token", { status: 200 });

  // Send via OneSignal REST API
  await fetch("https://onesignal.com/api/v1/notifications", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Basic ${Deno.env.get("ONESIGNAL_REST_API_KEY")}`,
    },
    body: JSON.stringify({
      app_id: Deno.env.get("ONESIGNAL_APP_ID"),
      include_player_ids: [athleteToken],
      headings: { en: "Coach Feedback" },
      contents: { en: "Your coach left notes on your session." },
      data: { session_id: annotation.session_id, deep_link: "hooptrack://session/\(annotation.session_id)/annotations" },
    }),
  });

  return new Response("ok");
});
```

### iOS deep link handling

`AppDelegate` / `SceneDelegate` intercepts `hooptrack://session/<id>/annotations` and navigates to `SessionAnnotationsView` for that session. The existing navigation coordinator should add a route case:

```swift
// NavigationCoordinator.swift
case sessionAnnotations(sessionId: UUID)
```

`player_profiles` gains a nullable `onesignal_player_id text` column; the iOS app registers with OneSignal on launch and upserts the token.

---

## 9. Real-time Annotation Delivery

When an athlete opens a session detail view immediately after training (common pattern — athlete reviews their own stats while still at the gym), annotations created by their coach arrive live without requiring a refresh.

### Supabase Realtime channel subscription

```swift
// SessionAnnotationsViewModel.swift
private var realtimeChannel: RealtimeChannel?

func subscribeToRealtime(sessionId: UUID) {
    let client = SupabaseManager.shared.client
    realtimeChannel = client.realtime
        .channel("annotations:\(sessionId.uuidString)")
        .on(
            .postgresChanges,
            filter: .init(
                event: .insert,
                schema: "public",
                table: "session_annotations",
                filter: "session_id=eq.\(sessionId.uuidString)"
            )
        ) { [weak self] message in
            guard let self,
                  let record = message.decodeRecord(SessionAnnotation.self)
            else { return }
            Task { @MainActor in
                self.annotations.append(record)
                self.annotations.sort { ($0.timestampSeconds ?? 0) < ($1.timestampSeconds ?? 0) }
            }
        }
        .subscribe()
}

func unsubscribe() {
    Task { try? await realtimeChannel?.unsubscribe() }
    realtimeChannel = nil
}
```

Call `subscribeToRealtime` in `.task` and `unsubscribe` in `.onDisappear`.

The subscription requires an active coach-athlete relationship and an active session share; Supabase's RLS policies enforce this at the database level before change events are emitted to the subscriber.

---

## 10. Video Signed URL Strategy

Session videos are stored in Supabase Storage at `sessions/<player_id>/<session_id>.mov` (per the existing `VideoUploadService` design).

### URL lifetime

| Consumer | URL lifetime | Rationale |
|---|---|---|
| Athlete (own sessions) | 1 hour | Refreshed automatically on view open |
| Coach (via share token) | 1 hour | Generated server-side per request |

Short-lived URLs prevent indefinite access after a share is revoked.

### Coach video URL generation

Coaches never receive a permanent storage path. The web dashboard fetches a signed URL via an Edge Function that validates the share token:

```typescript
// supabase/functions/get-session-video-url/index.ts
serve(async (req) => {
  const { shareToken } = await req.json();
  const secret = new TextEncoder().encode(Deno.env.get("SHARE_JWT_SECRET")!);

  // Verify the share token
  const { payload } = await jwtVerify(shareToken, secret);
  const { sessionId } = payload as { sessionId: string };

  // Check share is still active
  const { data: share } = await supabase
    .from("session_shares")
    .select("id, expires_at, revoked_at")
    .eq("share_token", shareToken)
    .single();

  if (!share || share.revoked_at || new Date(share.expires_at) < new Date()) {
    return new Response("Share expired or revoked", { status: 403 });
  }

  // Fetch the storage path from the session
  const { data: session } = await supabase
    .from("training_sessions")
    .select("video_file_path")
    .eq("id", sessionId)
    .single();

  const { data: signedUrl } = await supabase.storage
    .from("session-videos")
    .createSignedUrl(session.video_file_path, 3600);

  return new Response(JSON.stringify({ url: signedUrl.signedUrl }), {
    headers: { "Content-Type": "application/json" },
  });
});
```

The web dashboard calls this Edge Function on page load and passes the resulting URL to the `<video>` element. If the URL expires during a long review session, the dashboard re-fetches transparently on `error` events from the video element.

### `VideoUploadService` integration

`VideoUploadService` already handles upload; no change to the upload path. Add a `refreshSignedURL(for:)` helper to the existing service for athlete-side URL refresh:

```swift
extension VideoUploadService {
    func refreshSignedURL(for session: TrainingSession) async throws -> URL {
        let path = session.videoFilePath
        let response = try await supabase.storage
            .from("session-videos")
            .createSignedURL(path: path, expiresIn: 3600)
        return response
    }
}
```

---

## 11. Privacy Controls

### What a coach can see

- Session metrics: FG%, Shot Science averages, zone heat map, agility drill times
- Per-shot records: court position, release angle, outcome, video timestamp
- Session recording video

### What a coach cannot see

- HealthKit data: heart rate, HRV, sleep, body metrics
- `PlayerProfile` private fields: date of birth (used for age-gate logic), email address
- Other sessions not explicitly shared
- Annotations left by other coaches on the same session

These restrictions are enforced at two layers:
1. RLS policies (database layer) — coach-athlete join only permits access to sessions, shot_records, and session_annotations; `player_profiles` coach-facing API response is shaped to omit health columns.
2. Application layer — the Next.js API routes that serve coach dashboard data use a dedicated `getCoachSessionView()` query that never selects health columns.

### Athlete controls

| Action | Where |
|---|---|
| Revoke a specific share | Session detail → Share tab → tap share row → Revoke |
| Remove a coach entirely | Profile → Coaches → swipe to remove |
| Set share expiry | Share sheet → "Expires in" picker (7 days / 30 days / 90 days) |

Revoking a share sets `session_shares.revoked_at = now()`. The coach's next video URL request to the Edge Function will return `403`. Existing annotations are retained (athlete may want to keep the feedback text) but the coach loses the ability to add new ones.

Removing a coach sets `coach_athletes.status = 'revoked'` and calls a cascade that sets `revoked_at` on all active shares for that coach-athlete pair.

---

## 12. Testing Approach

### Integration tests — annotation CRUD

Using Supabase's test helpers (or a dedicated test project):

```typescript
// tests/integration/annotations.test.ts
describe("session_annotations", () => {
  it("coach can insert annotation on shared session", async () => {
    // Arrange: active coach-athlete relationship, active share
    const { data } = await coachClient
      .from("session_annotations")
      .insert({ session_id: testSessionId, ... })
      .select()
      .single();
    expect(data).toBeDefined();
  });

  it("unrelated user cannot insert annotation", async () => {
    const { error } = await strangerClient
      .from("session_annotations")
      .insert({ session_id: testSessionId, ... });
    expect(error?.code).toBe("42501"); // RLS violation
  });

  it("athlete can read annotations on own session", async () => {
    const { data } = await athleteClient
      .from("session_annotations")
      .select("*")
      .eq("session_id", testSessionId);
    expect(data!.length).toBeGreaterThan(0);
  });
});
```

### RLS cross-user access tests

```typescript
describe("RLS policies", () => {
  it("coach cannot read sessions of non-athletes", async () => {
    const { data } = await coachClient
      .from("training_sessions")
      .select("*")
      .eq("player_id", unrelatedAthleteId);
    expect(data).toHaveLength(0);
  });

  it("revoked coach loses access", async () => {
    await revokeCoachRelationship(coachId, athleteId);
    const { data } = await coachClient
      .from("training_sessions")
      .select("*")
      .eq("player_id", athleteId);
    expect(data).toHaveLength(0);
  });
});
```

### iOS unit tests — annotation view model

```swift
// SessionAnnotationsViewModelTests.swift
final class SessionAnnotationsViewModelTests: XCTestCase {

    func testAnnotationsSortedByTimestamp() async throws {
        let viewModel = SessionAnnotationsViewModel(
            session: .stub(),
            apiService: MockAPIService(annotations: [
                .stub(timestampSeconds: 45.2),
                .stub(timestampSeconds: 12.0),
                .stub(timestampSeconds: 78.9),
            ])
        )
        await viewModel.load()
        XCTAssertEqual(viewModel.annotations.map(\.timestampSeconds), [12.0, 45.2, 78.9])
    }

    func testMarkReadUpdatesBadgeCount() async throws {
        let viewModel = SessionAnnotationsViewModel(session: .stub(), apiService: MockAPIService())
        await viewModel.load()
        let unread = viewModel.annotations.first(where: { !$0.isRead })!
        await viewModel.markRead(unread)
        XCTAssertTrue(unread.isRead)
        XCTAssertEqual(viewModel.unreadCount, viewModel.annotations.filter { !$0.isRead }.count)
    }
}
```

### End-to-end share flow test

A Detox or XCTest UI test covering:

1. Athlete navigates to a completed session
2. Taps **Share with Coach** → selects a test coach account
3. Share sheet appears with a valid deep link URL
4. Simulate coach opening the URL → web dashboard loads (Playwright test)
5. Coach submits a text annotation
6. Athlete app receives the push notification (mocked APNs in test environment)
7. Athlete opens session → `SessionAnnotationsView` shows the annotation
8. Athlete taps annotation → video scrubs to `timestampSeconds`
9. Athlete revokes share → coach video URL request returns 403

---

## Implementation Sequencing

| Phase | Deliverables |
|---|---|
| 1 — Foundation | DB migrations (`coach_athletes`, `session_shares`, `session_annotations`); RLS policies; `role` column; `coach-invite` Edge Functions |
| 2 — Share flow (iOS) | `SessionSharingService`; `ShareSessionSheet`; `create-session-share` Edge Function; share deep link |
| 3 — Web review interface | `/dashboard/review/[session_id]` route; video player; shot chart; annotation sidebar; `createAnnotation` API call |
| 4 — iOS feedback view | `SessionAnnotationsView`; `AnnotationTimelineScrubber`; unread badge; `markRead` |
| 5 — Notifications & Realtime | `notify-athlete-annotation` Edge Function; OneSignal integration; Realtime subscription in view model |
| 6 — Privacy controls | Revoke share UI; remove coach UI; expiry picker; cascade revocation logic |
| 7 — Testing | Integration test suite; RLS cross-user tests; iOS unit tests; E2E share flow |

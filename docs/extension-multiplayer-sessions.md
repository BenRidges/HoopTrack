# HoopTrack — Multiplayer Sessions Extension Plan

**Date:** 2026-04-12
**Status:** Planning
**Prerequisite phases:** Phase 6+ baseline (Supabase Auth + SupabaseDataService + Realtime subscriptions implemented)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Session Lifecycle](#2-session-lifecycle)
3. [Database Schema Additions](#3-database-schema-additions)
4. [Real-Time Architecture](#4-real-time-architecture)
5. [iOS MultiplayerSessionService](#5-ios-multiplayersessionservice)
6. [Lobby UI](#6-lobby-ui)
7. [Live Leaderboard](#7-live-leaderboard)
8. [CV Pipeline Per Device](#8-cv-pipeline-per-device)
9. [Session Finalization](#9-session-finalization)
10. [Conflict Handling](#10-conflict-handling)
11. [WebRTC Consideration](#11-webrtc-consideration)
12. [Testing Approach](#12-testing-approach)

---

## 1. Overview

### What Multiplayer Sessions Are

A multiplayer session is a named training event that multiple players join from their own iPhones simultaneously. Each participant runs their own CV pipeline against their own camera feed; shot detection results are tagged with the player's identity and pushed to Supabase in real time. All participants see a shared leaderboard that updates live as shots are detected across devices.

This is **not** a video-sharing or co-inference feature. No video frames ever leave a device. The real-time data stream is lightweight structured events — shot results, drill completions, and presence signals — roughly analogous to a live sports scoreboard feed, not a broadcast stream. Bandwidth per participant is on the order of a few hundred bytes per shot event.

### Two Modes

**Coach-hosted drill session**
A coach (or senior player) creates the session and selects a specific `NamedDrill` and `DrillType`. All participants are assigned the same drill. The host has exclusive control over session state transitions (lobby → active, active → finalising). A "start" and "stop" button is host-only. This is the primary mode for organised practice.

**Peer-to-peer free session**
Any participant can create a session with no drill constraint (`drillType = .shooting`, `namedDrill = nil`). All participants are peers; the creator implicitly becomes host but others can also manually end their own participation. This mode is suited for pickup games where players want to compare their shot charts.

### What "Real-Time" Means Here

- **Shot feed:** Each device emits a `ShotEvent` (player id, result, zone, court position, timestamp) to the shared Supabase Realtime channel within ~200 ms of the CV pipeline resolving a shot.
- **Leaderboard updates:** The leaderboard `MultiplayerLeaderboardView` recomputes locally from the accumulated shot feed on every inbound event — no polling, no server aggregation during the session.
- **Presence:** Supabase Realtime Presence tracks who is currently connected (lobby and active phases) and surfaces a visual participant list with online/offline indicators.
- **No live video:** Each device's camera feed is private. Shot Science metrics (release angle, jump height) are computed locally and optionally included in the `ShotEvent` payload; they are never shared as raw video or pose keypoints.

---

## 2. Session Lifecycle

### States

```
lobby  ──►  active  ──►  finalising  ──►  complete
  │                           │
  └── (host cancels) ─────►  cancelled
```

| State | Who can advance it | What happens |
|---|---|---|
| `lobby` | Host only | Participants join via session code; presence list updates live |
| `active` | Host only (Start button) | Shot detection enabled on each device; shot events start flowing |
| `finalising` | Host only (Stop button) | Shot detection disabled; `SessionFinalizationCoordinator` runs locally on each device |
| `complete` | Automatic (server function) | Server aggregates final leaderboard; persisted to `multiplayer_sessions.final_leaderboard` JSONB |
| `cancelled` | Host only (from lobby) | Session deleted; participants notified and returned to Train tab |

### Join Flow

1. Host opens **Train tab → Multiplayer** and taps **Create Session**.
2. `MultiplayerSessionService.createSession(drillType:namedDrill:)` inserts a `multiplayer_sessions` row with `state = 'lobby'` and a generated six-character `session_code` (e.g. `HT-A4K9`).
3. Host subscribes to the Realtime channel `multiplayer:{session_id}`.
4. Participants open **Train tab → Join Session**, enter the `session_code`, and call `MultiplayerSessionService.joinSession(code:)`.
5. A `multiplayer_participants` row is inserted for each joiner. Realtime broadcasts the join to all channel subscribers; the lobby participant list animates in the new player.
6. Host taps **Start Session** → `state` transitions to `active` via a `PATCH multiplayer_sessions SET state = 'active'`. Realtime Postgres change event propagates to all subscribers; each device enables its CV pipeline.

### Code Generation

Session codes must be short enough to read off a court display and unambiguous enough to avoid collisions across concurrent sessions. Use a six-character code from a 32-character alphabet excluding visually ambiguous characters (`0 O I 1 L`).

```swift
// MultiplayerSessionService.swift
private func generateSessionCode() -> String {
    let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
    return String((0..<6).map { _ in alphabet.randomElement()! })
}
```

The `session_code` column has a `UNIQUE` constraint and an expiry: codes are valid only while `state != 'complete'` and `created_at > NOW() - INTERVAL '4 hours'`. A unique partial index on `(session_code)` where `state IN ('lobby','active')` enforces this at the database level.

---

## 3. Database Schema Additions

### 3.1 `multiplayer_sessions` Table

```sql
-- migrations/20260412100001_multiplayer_sessions.sql

CREATE TYPE multiplayer_session_state AS ENUM (
    'lobby', 'active', 'finalising', 'complete', 'cancelled'
);

CREATE TABLE multiplayer_sessions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    host_id             UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    session_code        TEXT NOT NULL,
    state               multiplayer_session_state NOT NULL DEFAULT 'lobby',
    drill_type          TEXT NOT NULL DEFAULT 'shooting',
    named_drill         TEXT,                   -- NULL = free session
    court_type          TEXT NOT NULL DEFAULT 'nba',
    location_tag        TEXT NOT NULL DEFAULT '',
    max_participants    INTEGER NOT NULL DEFAULT 8,
    started_at          TIMESTAMPTZ,            -- set when state → active
    finalised_at        TIMESTAMPTZ,            -- set when state → complete
    final_leaderboard   JSONB,                  -- written by server function at finalization
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT ms_code_length CHECK (char_length(session_code) = 6)
);

-- Only one active session per code at a time
CREATE UNIQUE INDEX idx_ms_active_code
    ON multiplayer_sessions (session_code)
    WHERE state IN ('lobby', 'active', 'finalising');

CREATE INDEX idx_ms_host ON multiplayer_sessions (host_id);

CREATE TRIGGER trg_ms_updated_at
    BEFORE UPDATE ON multiplayer_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

### 3.2 `multiplayer_participants` Join Table

```sql
CREATE TYPE participant_status AS ENUM (
    'joined', 'active', 'disconnected', 'finished'
);

CREATE TABLE multiplayer_participants (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          UUID NOT NULL REFERENCES multiplayer_sessions(id) ON DELETE CASCADE,
    user_id             UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    display_name        TEXT NOT NULL,
    status              participant_status NOT NULL DEFAULT 'joined',
    joined_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    disconnected_at     TIMESTAMPTZ,
    local_session_id    UUID,   -- TrainingSession.id on the participant's device

    CONSTRAINT mp_unique_participant UNIQUE (session_id, user_id)
);

CREATE INDEX idx_mp_session ON multiplayer_participants (session_id);
CREATE INDEX idx_mp_user    ON multiplayer_participants (user_id);
```

### 3.3 `multiplayer_shot_events` Table

Individual shot results are published here rather than directly to `shot_records` during a live session. At finalization, a server-side Postgres function copies confirmed shots into `shot_records` linked to each participant's `training_session_id`. This separation keeps the hot real-time write path off the main `shot_records` table and allows re-ordering and deduplication before the permanent record is written.

```sql
CREATE TABLE multiplayer_shot_events (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    session_id          UUID NOT NULL REFERENCES multiplayer_sessions(id) ON DELETE CASCADE,
    participant_id      UUID NOT NULL REFERENCES multiplayer_participants(id) ON DELETE CASCADE,
    user_id             UUID NOT NULL REFERENCES auth.users(id),

    -- Core shot data (mirrors ShotRecord fields)
    result              TEXT NOT NULL,          -- 'make' | 'miss'
    zone                TEXT NOT NULL,
    shot_type           TEXT NOT NULL DEFAULT 'unknown',
    court_x             DOUBLE PRECISION NOT NULL,
    court_y             DOUBLE PRECISION NOT NULL,
    sequence_index      INTEGER NOT NULL,
    shot_timestamp      TIMESTAMPTZ NOT NULL,   -- device wall-clock time

    -- Shot Science (optional — populated if PoseEstimationService is active)
    release_angle_deg   DOUBLE PRECISION,
    release_time_ms     DOUBLE PRECISION,
    vertical_jump_cm    DOUBLE PRECISION,
    shot_speed_mph      DOUBLE PRECISION,

    -- Network metadata
    received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    client_offset_ms    INTEGER,                -- NOW() - shot_timestamp in ms; for latency tracking

    CONSTRAINT mse_result_check CHECK (result IN ('make', 'miss'))
);

CREATE INDEX idx_mse_session     ON multiplayer_shot_events (session_id);
CREATE INDEX idx_mse_participant ON multiplayer_shot_events (participant_id, shot_timestamp);
```

### 3.4 `training_sessions` Linkage

Add a nullable foreign key to the existing `training_sessions` table so individual participants' post-finalization sessions can be traced back to the multiplayer event:

```sql
-- migrations/20260412100002_link_training_sessions_to_multiplayer.sql

ALTER TABLE training_sessions
    ADD COLUMN multiplayer_session_id UUID
        REFERENCES multiplayer_sessions(id) ON DELETE SET NULL;

CREATE INDEX idx_ts_multiplayer ON training_sessions (multiplayer_session_id)
    WHERE multiplayer_session_id IS NOT NULL;
```

The SwiftData `TrainingSession` model gains a corresponding optional field:
```swift
// Phase 7 addition — add after multiplayer launch
var multiplayerSessionID: UUID?   // non-nil for sessions that were part of a multiplayer event
```

### 3.5 Row Level Security (RLS)

```sql
-- multiplayer_sessions: visible to all authenticated users; only host can mutate
ALTER TABLE multiplayer_sessions ENABLE ROW LEVEL SECURITY;

CREATE POLICY ms_select ON multiplayer_sessions
    FOR SELECT TO authenticated USING (true);

CREATE POLICY ms_insert ON multiplayer_sessions
    FOR INSERT TO authenticated WITH CHECK (host_id = auth.uid());

CREATE POLICY ms_update ON multiplayer_sessions
    FOR UPDATE TO authenticated USING (host_id = auth.uid());

-- multiplayer_participants: session members can read; any authenticated user can insert their own row
ALTER TABLE multiplayer_participants ENABLE ROW LEVEL SECURITY;

CREATE POLICY mp_select ON multiplayer_participants
    FOR SELECT TO authenticated
    USING (
        session_id IN (
            SELECT id FROM multiplayer_sessions   -- any authenticated user can see any lobby
        )
    );

CREATE POLICY mp_insert ON multiplayer_participants
    FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());

CREATE POLICY mp_update ON multiplayer_participants
    FOR UPDATE TO authenticated USING (user_id = auth.uid());

-- multiplayer_shot_events: participants in the session can read; only author can write
ALTER TABLE multiplayer_shot_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY mse_select ON multiplayer_shot_events
    FOR SELECT TO authenticated
    USING (
        session_id IN (
            SELECT session_id FROM multiplayer_participants WHERE user_id = auth.uid()
        )
    );

CREATE POLICY mse_insert ON multiplayer_shot_events
    FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
```

---

## 4. Real-Time Architecture

### 4.1 Channel Per Session

Each active multiplayer session gets one Supabase Realtime channel:

```
channel name:  multiplayer:{session_id_uuid}
```

All participants subscribe to this channel on join. The channel carries two transport types:

| Transport type | What it carries | Direction |
|---|---|---|
| **Broadcast** | Shot events, drill completion signals | Client → channel → all clients |
| **Presence** | Online/offline participant status | Client ↔ channel |
| **Postgres Changes** | `multiplayer_sessions.state` transitions | Supabase → all clients |

### 4.2 Broadcast Events

Shot events use Broadcast rather than Postgres Changes for the live feed because Broadcast bypasses the WAL replication lag (~50–200 ms extra) and does not require a database write per shot during the session. The `multiplayer_shot_events` table is written asynchronously and serves as the durable record; Broadcast is the live signaling layer.

```swift
// Shot event broadcast payload
struct ShotEventPayload: Codable {
    let eventType: String        // "shot"
    let playerID: String         // auth.uid()
    let displayName: String
    let result: String           // "make" | "miss"
    let zone: String
    let courtX: Double
    let courtY: Double
    let sequenceIndex: Int
    let shotTimestamp: String    // ISO 8601
    let releaseAngleDeg: Double?
    let shotSpeedMph: Double?
}
```

Each device writes to the `multiplayer_shot_events` table in the background (after broadcasting) so the durable record exists for finalization. The write to the database is fire-and-forget during the session; failures are retried up to three times with exponential back-off.

### 4.3 Postgres Changes Events

State transitions on `multiplayer_sessions` are delivered via Postgres Changes, which ensures all participants respond to authoritative state — not just broadcasted signals that could be lost on reconnect.

```swift
// Subscribe to session state changes
channel.on(.postgresChanges,
           filter: ChannelFilter(
               event: "UPDATE",
               schema: "public",
               table: "multiplayer_sessions",
               filter: "id=eq.\(sessionID)"
           )) { [weak self] message in
    guard let self,
          let state = message.record["state"] as? String else { return }
    await self.handleSessionStateChange(state)
}
```

### 4.4 Presence

Supabase Realtime Presence uses a CRDT-based map; each client tracks its own key. On join:

```swift
try await channel.track([
    "user_id": playerID,
    "display_name": displayName,
    "status": "lobby"         // "active" once session starts
])
```

The lobby participant list and the leaderboard online indicators are driven from the local Presence state object, not from database queries.

### 4.5 Event Flow Diagram

```
Device A (host)                   Supabase                      Device B (participant)
     │                               │                                │
     │── createSession() ──────────► DB: INSERT multiplayer_sessions  │
     │                               │                                │
     │                               │ ◄── joinSession(code) ─────────│
     │                               │     DB: INSERT participants    │
     │◄── Presence sync ─────────────│──────────── Presence sync ────►│
     │                               │                                │
     │── Start (state→active) ──────►│ Postgres Change broadcast      │
     │                               │────────── state = active ─────►│
     │                               │                                │
     │  [CV pipeline detects shot]   │                                │
     │── Broadcast(ShotEvent) ───────►────────── ShotEvent ──────────►│ (updates leaderboard)
     │── INSERT shot_event (async) ──►│                               │
     │                               │                                │
     │                               │◄─ Broadcast(ShotEvent) ────────│ (other direction)
     │◄── ShotEvent ─────────────────│                                │
     │  (updates leaderboard)        │                                │
```

---

## 5. iOS `MultiplayerSessionService`

### 5.1 Class Definition

```swift
// MultiplayerSessionService.swift
// Manages the full lifecycle of a multiplayer session for the local participant.
// Injected as an @EnvironmentObject into multiplayer views.

import Foundation
import Combine
import Supabase   // supabase-swift SDK

@MainActor final class MultiplayerSessionService: ObservableObject {

    // MARK: - Published State

    @Published private(set) var sessionState: MultiplayerSessionState = .idle
    @Published private(set) var participants: [Participant] = []
    @Published private(set) var liveFeed: [ShotEvent] = []        // ordered, newest first
    @Published private(set) var leaderboard: [LeaderboardEntry] = []
    @Published private(set) var sessionCode: String?
    @Published private(set) var error: MultiplayerError?

    // MARK: - Internal

    private let supabase: SupabaseClient
    private let currentUserID: String
    private let currentDisplayName: String
    private var channel: RealtimeChannelV2?
    private var sessionID: UUID?
    private var pendingShotQueue: [ShotEventPayload] = []    // buffered if briefly offline

    // MARK: - Init

    init(supabase: SupabaseClient, userID: String, displayName: String) {
        self.supabase        = supabase
        self.currentUserID   = userID
        self.currentDisplayName = displayName
    }
```

### 5.2 Hosting a Session

```swift
    func createSession(drillType: DrillType,
                       namedDrill: NamedDrill? = nil,
                       courtType: CourtType = .nba,
                       locationTag: String = "") async throws {
        let code = generateSessionCode()
        let sessionID = UUID()
        self.sessionID = sessionID

        // 1. Insert the session row
        try await supabase
            .from("multiplayer_sessions")
            .insert([
                "id":           sessionID.uuidString,
                "host_id":      currentUserID,
                "session_code": code,
                "drill_type":   drillType.rawValue,
                "named_drill":  namedDrill?.rawValue as Any,
                "court_type":   courtType.rawValue,
                "location_tag": locationTag
            ])
            .execute()

        // 2. Insert the host as first participant
        try await insertSelfAsParticipant(sessionID: sessionID)

        // 3. Subscribe to the Realtime channel
        try await subscribeToChannel(sessionID: sessionID)

        self.sessionCode  = code
        self.sessionState = .lobby(isHost: true)
    }
```

### 5.3 Joining a Session

```swift
    func joinSession(code: String) async throws {
        // 1. Look up the session by code
        let response = try await supabase
            .from("multiplayer_sessions")
            .select("id, state, drill_type, named_drill, host_id")
            .eq("session_code", value: code.uppercased())
            .in("state", values: ["lobby", "active"])
            .single()
            .execute()

        guard let row = response.value as? [String: Any],
              let idString = row["id"] as? String,
              let sessionID = UUID(uuidString: idString) else {
            throw MultiplayerError.sessionNotFound
        }

        self.sessionID = sessionID

        // 2. Insert participant row (idempotent — UNIQUE constraint handles duplicates)
        try await insertSelfAsParticipant(sessionID: sessionID)

        // 3. Subscribe to channel
        try await subscribeToChannel(sessionID: sessionID)

        self.sessionState = .lobby(isHost: false)
    }
```

### 5.4 Channel Subscription

```swift
    private func subscribeToChannel(sessionID: UUID) async throws {
        let channelName = "multiplayer:\(sessionID.uuidString)"
        let ch = await supabase.realtimeV2.channel(channelName)
        self.channel = ch

        // Broadcast: incoming shot events from other participants
        await ch.onBroadcast(event: "shot") { [weak self] message in
            guard let self else { return }
            if let payload = try? JSONDecoder().decode(
                    ShotEventPayload.self,
                    from: JSONSerialization.data(withJSONObject: message)) {
                self.handleInboundShotEvent(payload)
            }
        }

        // Presence: participant join/leave
        await ch.onPresenceChange { [weak self] presenceChange in
            guard let self else { return }
            self.participants = presenceChange.currentPresences.compactMap {
                Participant(from: $0)
            }
        }

        // Postgres Changes: session state transitions
        await ch.on(.postgresChanges,
                    filter: ChannelFilter(
                        event: "UPDATE",
                        schema: "public",
                        table: "multiplayer_sessions",
                        filter: "id=eq.\(sessionID.uuidString)"
                    )) { [weak self] message in
            guard let self,
                  let newState = message.record["state"] as? String else { return }
            await self.handleSessionStateChange(newState)
        }

        try await ch.subscribe()

        // Track own presence
        try await ch.track([
            "user_id":      currentUserID,
            "display_name": currentDisplayName,
            "status":       "lobby"
        ])
    }
```

### 5.5 Publishing a Shot

Called by `CVPipeline` (via the ViewModel) when a shot is resolved. This is the hot path — it must not block the UI.

```swift
    func publishShot(_ shot: ShotRecord) {
        guard case .active = sessionState,
              let channel else { return }

        let payload = ShotEventPayload(
            eventType:       "shot",
            playerID:        currentUserID,
            displayName:     currentDisplayName,
            result:          shot.result == .make ? "make" : "miss",
            zone:            shot.zone.rawValue,
            courtX:          shot.courtX,
            courtY:          shot.courtY,
            sequenceIndex:   shot.sequenceIndex,
            shotTimestamp:   ISO8601DateFormatter().string(from: shot.timestamp),
            releaseAngleDeg: shot.releaseAngleDeg,
            shotSpeedMph:    shot.shotSpeedMph
        )

        // Broadcast is fire-and-forget on the UI layer
        Task {
            try? await channel.broadcast(event: "shot", message: payload.asDictionary())
        }

        // Persist to multiplayer_shot_events in the background; retry on failure
        Task.detached(priority: .utility) { [weak self] in
            await self?.persistShotEvent(payload)
        }

        // Update local leaderboard immediately (optimistic)
        handleInboundShotEvent(payload)
    }
```

### 5.6 Host Controls

```swift
    func startSession() async throws {
        guard let sessionID,
              case .lobby(let isHost) = sessionState, isHost else { return }

        try await supabase
            .from("multiplayer_sessions")
            .update(["state": "active", "started_at": ISO8601DateFormatter().string(from: .now)])
            .eq("id", value: sessionID.uuidString)
            .execute()
        // State transition propagated to all via Postgres Changes subscription
    }

    func finaliseSession() async throws {
        guard let sessionID,
              case .active = sessionState else { return }
        try await supabase
            .from("multiplayer_sessions")
            .update(["state": "finalising"])
            .eq("id", value: sessionID.uuidString)
            .execute()
    }
```

### 5.7 Supporting Types

```swift
enum MultiplayerSessionState: Equatable {
    case idle
    case lobby(isHost: Bool)
    case active
    case finalising
    case complete(leaderboard: [LeaderboardEntry])
    case error(MultiplayerError)
}

struct Participant: Identifiable, Equatable {
    let id: String           // auth.uid()
    let displayName: String
    var status: ParticipantStatus
    var shotsAttempted: Int
    var shotsMade: Int
    var fgPercent: Double { shotsAttempted > 0 ? Double(shotsMade) / Double(shotsAttempted) * 100 : 0 }
}

struct ShotEvent: Identifiable {
    let id: UUID
    let playerID: String
    let displayName: String
    let result: String
    let zone: String
    let courtX: Double
    let courtY: Double
    let receivedAt: Date
}

struct LeaderboardEntry: Identifiable, Comparable {
    let id: String           // playerID
    let displayName: String
    var rank: Int
    var shotsMade: Int
    var shotsAttempted: Int
    var fgPercent: Double
    var lastShotResult: String?

    static func < (lhs: LeaderboardEntry, rhs: LeaderboardEntry) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum MultiplayerError: LocalizedError {
    case sessionNotFound
    case sessionFull
    case notHost
    case realtimeDisconnected
    case serverError(String)
}
```

---

## 6. Lobby UI

### 6.1 `MultiplayerLobbyView`

```
┌────────────────────────────────────┐
│  ◀  Multiplayer                    │
│                                    │
│  Session Code                      │
│  ┌──────────────────────────────┐  │
│  │      HT - A 4 K 9            │  │
│  └──────────────────────────────┘  │
│  [Share Code]   [QR Code]          │
│                                    │
│  Drill: Spot-Up Shooting  •  NBA   │
│                                    │
│  Players (3 / 8)                   │
│  ● Ben Ridges         (host) ✓    │
│  ● Kenji Okafor             ✓    │
│  ● Maria Silva              ✓    │
│  ○ Waiting for players...          │
│                                    │
│  [  Start Session  ]  (host only)  │
└────────────────────────────────────┘
```

Key design decisions:

- **Session code display:** Render in a monospaced font at 36pt with a hyphen separator after character 2 (`HT-A4K9`). Visual chunking reduces transcription errors.
- **QR code:** Generate a `CoreImage` QR code from a deep link URL `hooptrack://join?code=HTA4K9`. The QR sheet is presented via `.sheet`. Non-host participants see the same QR for sharing with others.
- **Share sheet:** `ShareLink` with a pre-composed message: "Join my HoopTrack session — code: HT-A4K9 or hooptrack://join?code=HTA4K9".
- **Participant list:** Driven by `MultiplayerSessionService.participants`. Each entry animates in with `.transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))`. The host player row carries a crown icon badge.
- **Start Session button:** Visible only when `sessionState == .lobby(isHost: true)` and `participants.count >= 2`. Tapping calls `multiplayerService.startSession()` and triggers a brief 3-2-1 countdown overlay (`.fullScreenCover`) before the live session begins.
- **Cancel:** Host can cancel from the lobby via a destructive confirmation alert; this transitions state to `cancelled` and dismisses all participants.

```swift
struct MultiplayerLobbyView: View {
    @EnvironmentObject var multiplayerService: MultiplayerSessionService
    @State private var showQRSheet = false
    @State private var showCountdown = false

    var body: some View {
        VStack(spacing: 20) {
            SessionCodeCard(code: multiplayerService.sessionCode ?? "------")
                .contextMenu {
                    Button("Copy Code") {
                        UIPasteboard.general.string = multiplayerService.sessionCode
                    }
                }

            ShareLink(item: shareURL) {
                Label("Share Session", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)

            ParticipantListView(participants: multiplayerService.participants)

            if case .lobby(let isHost) = multiplayerService.sessionState, isHost {
                Button("Start Session") {
                    showCountdown = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(multiplayerService.participants.count < 2)
            }
        }
        .padding()
        .fullScreenCover(isPresented: $showCountdown) {
            CountdownOverlayView {
                Task { try await multiplayerService.startSession() }
            }
        }
    }
}
```

---

## 7. Live Leaderboard

### 7.1 `MultiplayerLeaderboardView`

The leaderboard overlays the standard `LiveSessionView` as a collapsible bottom drawer. Players can swipe it down to minimise it and focus on their own camera feed.

```
┌────────────────────────────────────┐
│  Leaderboard              ↕        │
│ ─────────────────────────────────  │
│  #1  Ben Ridges    12/18  66.7%  ● │
│  #2  Kenji Okafor  10/16  62.5%  ● │
│  #3  Maria Silva    7/14  50.0%  ○ │
│                                    │
│  You:  #2                          │
└────────────────────────────────────┘
```

Design constraints:

- **Up to 8 players.** At 8 entries the list height is approximately 320 pt — fits comfortably in the bottom third of an iPhone 16 screen without obscuring the camera feed.
- **Sort order:** Primary sort by `shotsMade` descending; tie-break by `fgPercent` descending; tie-break by `shotsAttempted` descending (reward higher volume in a pure-makes tie).
- **Rank animation:** When a player's rank changes, their row slides to the new position using `withAnimation(.spring(response: 0.4, dampingFraction: 0.75))` on a `ForEach` with explicit `id` keyed on `playerID`.
- **"You" highlight:** The current player's row has a `Color.accentColor.opacity(0.15)` background.
- **Last shot indicator:** A small colored dot (green = make, red = miss) fades in next to the player name on each inbound shot event and fades out after 1.5 s. Implemented via a `@State var lastShotAt: [String: Date]` dictionary and a `TimelineView`.
- **Presence indicator:** A filled circle (●) for connected participants, hollow (○) for disconnected (drawn from `Participant.status`).

```swift
struct MultiplayerLeaderboardView: View {
    @EnvironmentObject var multiplayerService: MultiplayerSessionService
    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            LeaderboardHeaderBar(isExpanded: $isExpanded)

            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(multiplayerService.leaderboard) { entry in
                            LeaderboardRowView(
                                entry: entry,
                                isCurrentUser: entry.id == multiplayerService.currentUserID
                            )
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .opacity))
                        }
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.75),
                           value: multiplayerService.leaderboard.map(\.rank))
                .frame(maxHeight: 320)
            }
        }
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .padding(.horizontal)
    }
}
```

### 7.2 Leaderboard Computation

The leaderboard is computed locally on every inbound `ShotEvent` — no server round-trip during the session. `MultiplayerSessionService` maintains a dictionary `[playerID: LeaderboardEntry]` and recomputes rankings in O(n log n) time, which is negligible for ≤8 players.

```swift
private func handleInboundShotEvent(_ payload: ShotEventPayload) {
    // Update live feed
    let event = ShotEvent(
        id: UUID(),
        playerID: payload.playerID,
        displayName: payload.displayName,
        result: payload.result,
        zone: payload.zone,
        courtX: payload.courtX,
        courtY: payload.courtY,
        receivedAt: .now
    )
    liveFeed.insert(event, at: 0)
    if liveFeed.count > 200 { liveFeed.removeLast() }   // cap memory usage

    // Update leaderboard entry for this player
    var entries = Dictionary(uniqueKeysWithValues: leaderboard.map { ($0.id, $0) })
    var entry = entries[payload.playerID] ?? LeaderboardEntry(
        id: payload.playerID, displayName: payload.displayName,
        rank: 0, shotsMade: 0, shotsAttempted: 0, fgPercent: 0)
    entry.shotsAttempted += 1
    if payload.result == "make" { entry.shotsMade += 1 }
    entry.lastShotResult = payload.result
    entries[payload.playerID] = entry

    // Re-rank
    var ranked = entries.values.sorted {
        if $0.shotsMade != $1.shotsMade { return $0.shotsMade > $1.shotsMade }
        if $0.fgPercent != $1.fgPercent { return $0.fgPercent > $1.fgPercent }
        return $0.shotsAttempted > $1.shotsAttempted
    }
    for i in ranked.indices { ranked[i].rank = i + 1 }
    leaderboard = ranked
}
```

---

## 8. CV Pipeline Per Device

### 8.1 Independence Principle

Each participant's `CVPipeline` and `DribblePipeline` run entirely locally on their device. There is no cross-device inference, no shared frame buffer, and no coordination between CV stacks. Shot detection is the same state machine (`idle → tracking → release_detected → resolved`) used in solo sessions.

The only change to the CV pipeline for multiplayer is a hook point at resolution time to call `multiplayerService.publishShot(_:)`.

### 8.2 Integration Point in `LiveSessionViewModel`

```swift
// In LiveSessionViewModel (existing @MainActor class)
// Added for multiplayer support — Phase 7

private var multiplayerService: MultiplayerSessionService?

func configure(forMultiplayer service: MultiplayerSessionService) {
    self.multiplayerService = service
}

// Called from CVPipeline result handler (already dispatched to main actor)
private func handleResolvedShot(_ shot: ShotRecord) {
    // 1. Persist locally (existing path)
    try? dataService.addShot(shot, to: currentSession)

    // 2. Publish to multiplayer channel (new path — no-op if not in multiplayer)
    multiplayerService?.publishShot(shot)
}
```

### 8.3 Shot Science in Multiplayer

`PoseEstimationService` runs on the rear camera and populates `ShotRecord` with `releaseAngleDeg`, `releaseTimeMs`, `verticalJumpCm`, and `shotSpeedMph` before `handleResolvedShot` is called. These metrics are included in the `ShotEventPayload` if available. Receiving devices render the shot science data in the live feed rows (compact format: "46°  •  11.2 mph") if the sender included it; the field is absent otherwise.

Shot science data from multiplayer peers is not written to the receiving device's local SwiftData store during the session. It is surfaced read-only in the live feed and captured in `multiplayer_shot_events` server-side for post-session review.

### 8.4 Dribble and Agility Modes

Multiplayer is initially scoped to `DrillType.shooting` sessions where shot detection produces discrete, attributable events. Dribble drill and agility modes emit fewer natural "events" and their coordination semantics are less clear (e.g., comparing BPS across two players on different drills). These modes are excluded from multiplayer in Phase 7 and can be added in a subsequent phase once the shot-based flow is stable.

---

## 9. Session Finalization

### 9.1 Trigger

The host taps **End Session** in the live session UI. `MultiplayerSessionService.finaliseSession()` transitions `multiplayer_sessions.state` to `'finalising'`. All participants receive this state change via their Postgres Changes subscription within ~100–200 ms.

On receiving `state = 'finalising'`, each device:

1. Calls `CVPipeline.stop()` — no new shots will be detected.
2. Flushes any pending shot event writes from `pendingShotQueue` to `multiplayer_shot_events`.
3. Invokes `SessionFinalizationCoordinator.finaliseSession(_:)` locally — the same 7-step pipeline used for solo sessions (goal updates, HealthKit workout, skill ratings, badge evaluation, notifications).
4. Sets `multiplayer_participants.status = 'finished'` for the local participant row.

### 9.2 Server-Side Aggregation

A Supabase Edge Function `aggregate_multiplayer_session` fires on the `multiplayer_sessions` table when `state` transitions to `'finalising'`. It:

1. Waits up to 10 seconds for all non-disconnected participants to reach `status = 'finished'` (or times out and processes whoever has finished).
2. Queries `multiplayer_shot_events` grouped by `participant_id` to compute final per-player stats.
3. Builds a `final_leaderboard` JSONB object.
4. Updates `multiplayer_sessions` SET `state = 'complete', final_leaderboard = ..., finalised_at = NOW()`.

All participants receive the `state = 'complete'` Postgres change event and fetch `final_leaderboard` from the session row. The `MultiplayerSessionSummaryView` is presented with the authoritative server-computed leaderboard.

```sql
-- Final leaderboard JSONB structure
-- [{
--   "rank": 1,
--   "player_id": "uuid",
--   "display_name": "Ben Ridges",
--   "shots_made": 18,
--   "shots_attempted": 26,
--   "fg_percent": 69.23,
--   "zones": {"aboveBreakThree": {"made": 3, "attempted": 5}, ...}
-- }, ...]
```

### 9.3 `TrainingSession` Linkage

During finalization, each device sets `TrainingSession.multiplayerSessionID` to the `multiplayer_sessions.id` before calling `DataService.finaliseSession(_:)`. This linkage persists in SwiftData and in the `training_sessions` cloud table, enabling queries like "show me all sessions that were part of a team practice."

### 9.4 Modified `SessionFinalizationCoordinator`

The coordinator gains an optional `multiplayerSessionID` parameter. When non-nil, the standard 7-step finalization runs unchanged — goal updates, HealthKit, skill ratings, badges, and notifications all execute identically to a solo session. The multiplayer linkage is purely additive.

```swift
// Phase 7 addition — optional multiplayer context
func finaliseSession(_ session: TrainingSession,
                     multiplayerSessionID: UUID? = nil) async throws -> SessionResult {
    if let mpID = multiplayerSessionID {
        session.multiplayerSessionID = mpID
    }
    // ... existing 7-step finalization unchanged ...
}
```

---

## 10. Conflict Handling

### 10.1 Late-Arriving Shot Events

Network jitter can cause a shot event from one device to arrive at the Supabase backend after events with a higher `received_at` timestamp. The `shot_timestamp` field (device wall-clock time) is the canonical ordering key for `multiplayer_shot_events`. At finalization, the Edge Function orders by `shot_timestamp` rather than `received_at` to reconstruct accurate sequence indexes.

The leaderboard shown during the live session may briefly reorder if a late shot arrives, but this is visually acceptable (the animation system smoothly re-ranks).

### 10.2 Disconnected Participants

If a participant's device loses connectivity, the Supabase Realtime library will attempt reconnection with exponential back-off. If reconnection does not occur within 30 seconds, the channel's Presence state transitions the participant to an offline visual state in the leaderboard.

From the server's perspective, a disconnected participant retains their `multiplayer_participants.status = 'active'`. Their shot events are not deleted. When (if) they reconnect:

- Realtime re-subscribes to the channel.
- The participant calls `channel.track(...)` to restore their Presence entry.
- Their locally buffered `pendingShotQueue` is flushed to `multiplayer_shot_events`.
- The leaderboard recomputes with the flushed shots included.

If a disconnected participant never reconnects, the Edge Function's 10-second wait at finalization proceeds without them. Their shots (those that were successfully written before disconnection) are included in the final leaderboard; any shots they took offline are lost.

### 10.3 Re-Join Flow

A participant who was disconnected and wants to re-join calls `joinSession(code:)` again. The `INSERT ... ON CONFLICT DO NOTHING` (via the UNIQUE constraint on `(session_id, user_id)`) handles the duplicate insert gracefully. The participant re-subscribes to the channel and resumes publishing shots.

Re-joining is only available while `state IN ('lobby', 'active')`. A participant cannot re-join a session in `finalising` or `complete` state.

### 10.4 Host Disconnect

If the host disconnects during an active session, the other participants continue shooting and the session remains `active` indefinitely (there is no auto-transition without the host). After 5 minutes in `active` state with no host Presence, a Supabase Edge Function fires and automatically transitions the session to `finalising`. This function is triggered by a pg_cron job checking for orphaned active sessions.

```sql
-- pg_cron: check for orphaned active sessions every minute
SELECT cron.schedule(
    'orphaned-session-finalizer',
    '* * * * *',
    $$
    UPDATE multiplayer_sessions
    SET state = 'finalising'
    WHERE state = 'active'
      AND started_at < NOW() - INTERVAL '5 minutes'
      AND id NOT IN (
          SELECT session_id FROM multiplayer_participants
          WHERE status = 'active'
            AND session_id IN (
                SELECT id FROM multiplayer_sessions WHERE state = 'active'
                  AND host_id = user_id   -- is this participant the host?
            )
      );
    $$
);
```

---

## 11. WebRTC Consideration

### Why WebRTC Is Not Used

WebRTC is a peer-to-peer real-time communication protocol designed primarily for low-latency audio/video streams and arbitrary data channels. Integrating it into HoopTrack for the multiplayer shot feed would introduce:

- **Significant complexity:** WebRTC requires signaling servers, ICE/STUN/TURN infrastructure, and peer connection lifecycle management. Supabase does not provide a managed WebRTC stack; this would require a separate service (e.g., Twilio, Agora, or a self-hosted mediasoup server) and a third-party SDK dependency, violating HoopTrack's current no-third-party-dependencies constraint.
- **Unnecessary capability:** The shot feed use case is a low-frequency event stream (≤1 event per second per player). Supabase Realtime Broadcast delivers events with <200 ms median latency over WebSocket, which is entirely adequate for a leaderboard. WebRTC's sub-50 ms latency advantage is only meaningful for audio, video, and interactive gaming scenarios.
- **Per-device CV:** Because each device runs its own inference locally, there is no shared video stream to relay. The only data that crosses the network is structured JSON payloads.

### When WebRTC Would Become Appropriate

WebRTC becomes the right choice if HoopTrack adds a "shared camera session" mode where a single camera device (e.g., a coach's iPad on a tripod) captures video that all players' phones display simultaneously while running inference on distinct ROIs. In that architecture, the iPad would broadcast the video stream to each participant's device, and each device would run its own CV pipeline on the received frames. That is a materially different product feature and warrants a standalone infrastructure design.

Another trigger would be a "watch my form" async video review feature where player A sends a shot clip to player B's device in real time. That is closer to a screen share than a data feed, and WebRTC peer connections would be the right transport.

---

## 12. Testing Approach

### 12.1 Unit Tests — Session Lifecycle State Machine

The multiplayer session state transitions form a pure state machine that can be tested without any network infrastructure. Extract the transition logic into a value-type `MultiplayerSessionStateMachine` struct:

```swift
// MultiplayerSessionStateMachine.swift

struct MultiplayerSessionStateMachine {
    private(set) var state: MultiplayerSessionState = .idle

    enum Transition {
        case create(isHost: Bool)
        case join
        case start
        case finalise
        case complete
        case cancel
        case disconnect
    }

    mutating func apply(_ transition: Transition) throws {
        switch (state, transition) {
        case (.idle, .create(let isHost)):
            state = .lobby(isHost: isHost)
        case (.idle, .join):
            state = .lobby(isHost: false)
        case (.lobby, .start):
            state = .active
        case (.active, .finalise):
            state = .finalising
        case (.finalising, .complete):
            state = .complete(leaderboard: [])
        case (.lobby, .cancel), (.active, .cancel):
            state = .idle
        default:
            throw MultiplayerStateMachineError.invalidTransition(state, transition)
        }
    }
}
```

```swift
// HoopTrackTests/MultiplayerSessionStateMachineTests.swift

final class MultiplayerSessionStateMachineTests: XCTestCase {

    func test_hostFlow_fullLifecycle() throws {
        var sm = MultiplayerSessionStateMachine()
        try sm.apply(.create(isHost: true))
        XCTAssertEqual(sm.state, .lobby(isHost: true))
        try sm.apply(.start)
        XCTAssertEqual(sm.state, .active)
        try sm.apply(.finalise)
        XCTAssertEqual(sm.state, .finalising)
        try sm.apply(.complete)
        if case .complete = sm.state { } else { XCTFail("Expected complete state") }
    }

    func test_participantFlow_joinThenActive() throws {
        var sm = MultiplayerSessionStateMachine()
        try sm.apply(.join)
        XCTAssertEqual(sm.state, .lobby(isHost: false))
        try sm.apply(.start)
        XCTAssertEqual(sm.state, .active)
    }

    func test_invalidTransition_throwsError() {
        var sm = MultiplayerSessionStateMachine()
        XCTAssertThrowsError(try sm.apply(.start))  // can't start from idle
    }

    func test_cancelFromLobby_returnsToIdle() throws {
        var sm = MultiplayerSessionStateMachine()
        try sm.apply(.create(isHost: true))
        try sm.apply(.cancel)
        XCTAssertEqual(sm.state, .idle)
    }
}
```

### 12.2 Unit Tests — Leaderboard Computation

```swift
// HoopTrackTests/MultiplayerLeaderboardTests.swift

final class MultiplayerLeaderboardTests: XCTestCase {

    func test_rankingByMakesThenFgPercent() {
        var service = LeaderboardComputationHelper()
        service.recordShot(playerID: "a", result: "make")   // a: 1/1
        service.recordShot(playerID: "b", result: "make")   // b: 1/1 (tie)
        service.recordShot(playerID: "a", result: "miss")   // a: 1/2

        let board = service.leaderboard
        XCTAssertEqual(board[0].id, "b")   // b wins: same makes, higher FG%
        XCTAssertEqual(board[1].id, "a")
    }
}
```

### 12.3 Integration Tests — Supabase Local Docker

Supabase provides a local development stack via Docker Compose. Run the full local stack to integration-test:

- Session creation and code uniqueness constraints.
- Participant join idempotency (duplicate insert returns no error).
- RLS: participant A cannot update participant B's shot events.
- Postgres Changes events fire correctly on state transitions.
- The `aggregate_multiplayer_session` Edge Function produces a correct `final_leaderboard`.

```bash
# Start local Supabase stack
supabase start

# Run migrations against local DB
supabase db push

# Run integration test suite (separate XCTestCase subclass, guarded by #if DEBUG)
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:HoopTrackTests/MultiplayerIntegrationTests \
  SUPABASE_URL=http://localhost:54321 \
  SUPABASE_ANON_KEY=<local-anon-key>
```

Integration tests should cover the full lifecycle: create → join (second simulator) → start → publish shots (both sides) → finalise → verify `final_leaderboard` JSONB.

### 12.4 Manual Test Matrix

| Scenario | Expected result |
|---|---|
| Host creates session on Device A, participant joins on Device B | Both see participant list in lobby within 1 s |
| Host starts session | Both devices enable CV pipeline; shot detection active |
| Device B detects a make | Device A leaderboard updates within 200 ms |
| Device B force-quits during active session | Device B shown as disconnected (○) on Device A within 30 s |
| Device B relaunches and re-joins | Device B shown as connected; previously buffered shots included |
| Host ends session | Both devices show `MultiplayerSessionSummaryView` with final leaderboard |
| 8 players in lobby | All 8 appear in lobby list; leaderboard renders without overflow |

---

## Appendix: File Locations

New files introduced by this feature:

| File | Purpose |
|---|---|
| `Services/MultiplayerSessionService.swift` | Main service class (Section 5) |
| `Views/Multiplayer/MultiplayerLobbyView.swift` | Lobby UI (Section 6) |
| `Views/Multiplayer/MultiplayerLeaderboardView.swift` | Live leaderboard overlay (Section 7) |
| `Views/Multiplayer/MultiplayerSessionSummaryView.swift` | Post-session summary with final leaderboard |
| `Views/Multiplayer/CountdownOverlayView.swift` | 3-2-1 countdown before session starts |
| `Utilities/MultiplayerSessionStateMachine.swift` | Pure state machine for testing |
| `HoopTrackTests/MultiplayerSessionStateMachineTests.swift` | State machine unit tests |
| `HoopTrackTests/MultiplayerLeaderboardTests.swift` | Leaderboard ranking unit tests |
| `supabase/migrations/20260412100001_multiplayer_sessions.sql` | New tables + RLS |
| `supabase/migrations/20260412100002_link_training_sessions_to_multiplayer.sql` | FK on `training_sessions` |
| `supabase/functions/aggregate_multiplayer_session/index.ts` | Edge Function for final leaderboard |

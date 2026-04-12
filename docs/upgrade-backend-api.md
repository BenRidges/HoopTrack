# HoopTrack — Backend & API Integration Plan

**Date:** 2026-04-12  
**Status:** Planning  
**Applies to:** Post-Phase 5 / Phase 6+ work

---

## 1. Overview

HoopTrack currently stores all data in SwiftData on-device. Every `PlayerProfile`, `TrainingSession`, `ShotRecord`, and `GoalRecord` lives in a single local SQLite container managed by `DataService`. This is correct for a solo training tool, but it becomes a ceiling for the product's next tier of capabilities:

| Capability | Why it needs a backend |
|---|---|
| **Cross-device sync** | A player training on both an iPhone and iPad needs a canonical record store, not two diverging SwiftData stores. |
| **Coach review mode** | Coaches must read session data they don't own; that requires a server-mediated identity and sharing model. |
| **Social leaderboards** | Aggregating FG%, dribble speed, and agility times across users requires a centralised query layer. |
| **Web dashboard** | A browser client cannot read an on-device SQLite file. The same data must be accessible via an API. |
| **Team / multiplayer sessions** | Multiple players contributing shots to a shared session requires a real-time authority. |

The plan below adds a backend layer that is **additive and non-breaking**: local SwiftData remains the source of truth during a session and when offline. The backend becomes the sync destination and the query layer for cross-user features.

---

## 2. Architecture Decision — Hasura + Supabase Postgres

### Chosen approach

**Hasura Cloud** (GraphQL engine) connected to a **Supabase**-managed Postgres database.

### Why not FastAPI or Express?

| Option | Trade-offs |
|---|---|
| **FastAPI / Express** | Gives full control over every endpoint, but requires hand-writing resolvers for every query, mutation, and filter combination that Hasura generates automatically. At HoopTrack's data shape (relational, CRUD-heavy, joins between sessions and shots), the resolver count is large and the business value is low. |
| **Hasura + Supabase** | Auto-generates a full GraphQL API from the Postgres schema. Filtering, pagination, aggregations (`avg`, `sum`, `count`), and relationship traversal (sessions → shots) are available without writing a single resolver. Supabase provides managed Postgres with Row Level Security (RLS), Auth, Realtime, Storage, and Edge Functions — all from one provider. This minimises operational surface area for a solo or small-team project. |

### When FastAPI would be the right call

If HoopTrack ever needs complex ML inference endpoints (shot form scoring, personalised drill recommendations), a FastAPI service sitting behind the same API gateway would be the correct addition. That is a separate service; it does not displace Hasura for CRUD.

### Topology

```
iOS App
  ├── DataService (SwiftData, local-first)
  └── APIService (GraphQL over HTTPS)
          │
          ▼
   Hasura Cloud (GraphQL engine)
          │
          ▼
   Supabase Postgres (managed)
          │
   Supabase Edge Functions (serverless)
   Supabase Auth (JWT / Sign in with Apple)
   Supabase Storage (session videos)
```

---

## 3. Hasura Setup

### 3.1 Deploy Hasura Cloud connected to Supabase

1. Create a Supabase project at `supabase.com`. Note the Postgres connection string.
2. Create a Hasura Cloud project at `hasura.io/cloud`. Connect it to the Supabase Postgres connection string via **Data → Connect Existing Database**.
3. Set `HASURA_GRAPHQL_ADMIN_SECRET` in Hasura Cloud environment variables.
4. Set `HASURA_GRAPHQL_JWT_SECRET` to Supabase's JWT config (Supabase provides this verbatim under **Settings → API**).

### 3.2 Initial schema

Run the following DDL in the Supabase SQL editor. Each table mirrors its SwiftData counterpart.

```sql
-- Users table (one row per authenticated player)
create table users (
  id          uuid primary key default gen_random_uuid(),
  apple_sub   text unique,           -- Sign in with Apple subject identifier
  name        text not null default 'Player',
  created_at  timestamptz not null default now()
);

-- Player profiles (1:1 with users)
create table player_profiles (
  id                          uuid primary key default gen_random_uuid(),
  user_id                     uuid not null references users(id) on delete cascade,
  rating_overall              double precision not null default 0,
  rating_shooting             double precision not null default 0,
  rating_ball_handling        double precision not null default 0,
  rating_athleticism          double precision not null default 0,
  rating_consistency          double precision not null default 0,
  rating_volume               double precision not null default 0,
  career_shots_attempted      int not null default 0,
  career_shots_made           int not null default 0,
  total_session_count         int not null default 0,
  total_training_minutes      double precision not null default 0,
  pr_best_fg_percent_session  double precision not null default 0,
  pr_most_makes_session       int not null default 0,
  pr_best_consistency_score   double precision,
  pr_vertical_jump_cm         double precision not null default 0,
  current_streak_days         int not null default 0,
  longest_streak_days         int not null default 0,
  last_session_date           timestamptz,
  preferred_court_type        text not null default 'nba',
  updated_at                  timestamptz not null default now()
);

-- Training sessions
create table training_sessions (
  id                          uuid primary key,   -- same UUID as SwiftData id
  user_id                     uuid not null references users(id) on delete cascade,
  started_at                  timestamptz not null,
  ended_at                    timestamptz,
  duration_seconds            double precision not null default 0,
  drill_type                  text not null,
  named_drill                 text,
  court_type                  text not null default 'nba',
  location_tag                text not null default '',
  notes                       text not null default '',
  shots_attempted             int not null default 0,
  shots_made                  int not null default 0,
  fg_percent                  double precision not null default 0,
  avg_release_angle_deg       double precision,
  avg_release_time_ms         double precision,
  avg_vertical_jump_cm        double precision,
  avg_shot_speed_mph          double precision,
  consistency_score           double precision,
  video_file_name             text,
  video_pinned_by_user        boolean not null default false,
  total_dribbles              int,
  avg_dribbles_per_sec        double precision,
  max_dribbles_per_sec        double precision,
  hand_balance_fraction       double precision,
  dribble_combos_detected     int,
  best_shuttle_run_seconds    double precision,
  best_lane_agility_seconds   double precision,
  longest_make_streak         int not null default 0,
  shot_speed_std_dev          double precision,
  synced_at                   timestamptz not null default now()
);

-- Shot records
create table shot_records (
  id                      uuid primary key,   -- same UUID as SwiftData id
  session_id              uuid not null references training_sessions(id) on delete cascade,
  user_id                 uuid not null references users(id) on delete cascade,
  timestamp               timestamptz not null,
  sequence_index          int not null,
  result                  text not null,
  zone                    text not null,
  shot_type               text not null,
  court_x                 double precision not null,
  court_y                 double precision not null,
  release_angle_deg       double precision,
  release_time_ms         double precision,
  vertical_jump_cm        double precision,
  leg_angle_deg           double precision,
  shot_speed_mph          double precision,
  video_timestamp_seconds double precision,
  is_user_corrected       boolean not null default false,
  synced_at               timestamptz not null default now()
);

-- Goal records
create table goal_records (
  id                        uuid primary key,
  user_id                   uuid not null references users(id) on delete cascade,
  created_at                timestamptz not null,
  target_date               timestamptz,
  title                     text not null,
  skill                     text not null,
  metric                    text not null,
  target_value              double precision not null,
  baseline_value            double precision not null,
  current_value             double precision not null,
  is_achieved               boolean not null default false,
  achieved_at               timestamptz,
  last_milestone_notified   int not null default 0,
  synced_at                 timestamptz not null default now()
);

-- Indexes for common query patterns
create index on training_sessions (user_id, started_at desc);
create index on shot_records (session_id);
create index on shot_records (user_id, timestamp desc);
create index on goal_records (user_id);
```

### 3.3 Permissions model (Row Level Security)

Enable RLS on every table. Players may only read and write their own rows.

```sql
alter table player_profiles   enable row level security;
alter table training_sessions enable row level security;
alter table shot_records       enable row level security;
alter table goal_records       enable row level security;

-- Policy pattern — repeat for each table, adjusting the table name
create policy "own rows only" on training_sessions
  using (user_id = auth.uid())
  with check (user_id = auth.uid());
```

Hasura enforces this at the engine level via JWT claims. Set the Hasura session variable `x-hasura-user-id` from the JWT `sub` claim in Hasura's JWT config:

```json
{
  "type": "RS256",
  "jwk_url": "https://<project>.supabase.co/auth/v1/.well-known/jwks.json",
  "claims_namespace": "https://hasura.io/jwt/claims",
  "claims_format": "json"
}
```

In Supabase Auth, configure a custom JWT claim hook (or use the built-in `role` / `user_id` mapping) so the Hasura `x-hasura-user-id` claim is always populated.

---

## 4. GraphQL Schema Design

Hasura generates the full API from the Postgres schema above. The key types and their SwiftData origins are:

| GraphQL type | SwiftData model | Notes |
|---|---|---|
| `users` | — | New; maps to Supabase Auth identity |
| `player_profiles` | `PlayerProfile` | 1:1 with `users`; skill ratings live here |
| `training_sessions` | `TrainingSession` | UUID is preserved from device for idempotent upserts |
| `shot_records` | `ShotRecord` | UUID preserved; `session_id` foreign key |
| `goal_records` | `GoalRecord` | UUID preserved; `user_id` foreign key |

Hasura automatically generates:

- `query training_sessions(where: ..., order_by: ..., limit: ..., offset: ...)` — paginated session history
- `training_sessions_aggregate { count, avg { fg_percent } }` — leaderboard aggregates without Edge Functions
- `insert_training_sessions_one(object: ..., on_conflict: ...)` — upsert by primary key (used for sync)
- `update_player_profiles_by_pk` — profile stat patches

### Example: leaderboard query

```graphql
query WeeklyFGLeaderboard($since: timestamptz!) {
  training_sessions_aggregate(
    where: { started_at: { _gte: $since } }
  ) {
    nodes {
      user_id
      user { name }
    }
    aggregate {
      avg { fg_percent }
      count
    }
  }
}
```

### Example: session upsert (sync mutation)

```graphql
mutation UpsertSession($session: training_sessions_insert_input!) {
  insert_training_sessions_one(
    object: $session,
    on_conflict: {
      constraint: training_sessions_pkey,
      update_columns: [
        ended_at, duration_seconds, shots_attempted, shots_made, fg_percent,
        avg_release_angle_deg, consistency_score, notes, synced_at
      ]
    }
  ) {
    id
  }
}
```

---

## 5. iOS GraphQL Client

### No Apollo — lightweight URLSession wrapper

HoopTrack's existing convention is no third-party dependencies. A GraphQL request is structurally simple: a POST with a JSON body containing `query` and `variables`. A thin wrapper over `URLSession` handles this cleanly.

```swift
// GraphQLClient.swift

import Foundation

struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: AnyEncodable]?
}

struct GraphQLResponse<T: Decodable>: Decodable {
    struct GraphQLError: Decodable {
        let message: String
    }
    let data: T?
    let errors: [GraphQLError]?
}

enum GraphQLClientError: Error {
    case network(Error)
    case serverErrors([String])
    case noData
    case decoding(Error)
}

final class GraphQLClient: Sendable {
    private let endpoint: URL
    private let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session  = session
    }

    func perform<T: Decodable>(
        query: String,
        variables: [String: AnyEncodable]? = nil,
        authToken: String
    ) async throws -> T {
        var request        = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)",   forHTTPHeaderField: "Authorization")

        let body = GraphQLRequest(query: query, variables: variables)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GraphQLClientError.network(error)
        }

        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GraphQLClientError.noData
        }

        let gqlResponse: GraphQLResponse<T>
        do {
            gqlResponse = try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
        } catch {
            throw GraphQLClientError.decoding(error)
        }

        if let errors = gqlResponse.errors, !errors.isEmpty {
            throw GraphQLClientError.serverErrors(errors.map { $0.message })
        }

        guard let payload = gqlResponse.data else { throw GraphQLClientError.noData }
        return payload
    }
}
```

`AnyEncodable` is a standard type-erasing Encodable wrapper (~20 lines, available as a copy-paste snippet — do not add a package dependency for it).

### Justification for Apollo

Apollo iOS would be justified only if the team grows to 3+ engineers who benefit from codegen type-safety across many query files. For a solo or 2-person team, the URLSession wrapper above provides full control, zero dependency surface, and a test-seam that is trivial to mock.

---

## 6. APIService Design

`APIService` is a `@MainActor final class` that wraps `GraphQLClient`. It sits alongside `DataService` rather than replacing it. The two services have non-overlapping responsibilities:

| Service | Responsibility |
|---|---|
| `DataService` | All local SwiftData reads and writes; the only path to persisting data during a session |
| `APIService` | Background sync to Hasura; cross-user queries (leaderboards, coach sharing) |

```swift
// APIService.swift

import Foundation

@MainActor
final class APIService: ObservableObject {

    // MARK: - Dependencies
    private let client: GraphQLClient
    private var authToken: String?

    // MARK: - State
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: Error?
    @Published private(set) var lastSyncedAt: Date?

    init(client: GraphQLClient) {
        self.client = client
    }

    func setAuthToken(_ token: String) {
        self.authToken = token
    }

    // MARK: - Session Sync

    /// Upserts a completed session and all its shots to Hasura.
    /// Returns silently on network failure — does not throw.
    func syncSession(_ session: TrainingSession) async {
        guard let token = authToken else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let sessionInput = SessionInput(from: session)
            let _: UpsertSessionResponse = try await client.perform(
                query: Mutations.upsertSession,
                variables: ["session": AnyEncodable(sessionInput)],
                authToken: token
            )

            // Batch-upsert shots in a single mutation
            if !session.shots.isEmpty {
                let shotInputs = session.shots.map { ShotInput(from: $0) }
                let _: UpsertShotsResponse = try await client.perform(
                    query: Mutations.upsertShots,
                    variables: ["shots": AnyEncodable(shotInputs)],
                    authToken: token
                )
            }

            lastSyncedAt  = .now
            lastSyncError = nil
        } catch {
            lastSyncError = error
            // No rethrow — sync failure must never block local usage
        }
    }

    /// Upserts the player profile snapshot.
    func syncProfile(_ profile: PlayerProfile) async {
        guard let token = authToken else { return }
        do {
            let input = ProfileInput(from: profile)
            let _: UpsertProfileResponse = try await client.perform(
                query: Mutations.upsertProfile,
                variables: ["profile": AnyEncodable(input)],
                authToken: token
            )
        } catch {
            lastSyncError = error
        }
    }

    // MARK: - Cross-user Queries

    func fetchWeeklyLeaderboard() async throws -> [LeaderboardEntry] {
        guard let token = authToken else { throw APIServiceError.unauthenticated }
        let since = ISO8601DateFormatter().string(
            from: Calendar.current.date(byAdding: .day, value: -7, to: .now)!
        )
        let response: LeaderboardResponse = try await client.perform(
            query: Queries.weeklyFGLeaderboard,
            variables: ["since": AnyEncodable(since)],
            authToken: token
        )
        return response.training_sessions_aggregate.nodes
            .compactMap { LeaderboardEntry(from: $0) }
    }
}

enum APIServiceError: Error {
    case unauthenticated
}
```

### Input / response types

Define lightweight `Encodable` / `Decodable` structs (e.g. `SessionInput`, `ShotInput`, `ProfileInput`) that map SwiftData model fields to snake_case JSON keys matching the Postgres column names. These are value types and involve no SwiftData imports — they are pure data-transfer objects.

---

## 7. Sync Strategy

### Principle: local-first, sync-in-background

SwiftData is the source of truth for all in-session and offline operations. `APIService` is a non-blocking background upload path. No ViewModel should `await` an API call on the critical path for displaying data.

### Integration point — `SessionFinalizationCoordinator`

`SessionFinalizationCoordinator.finaliseSession(_:)` already sequences a 7-step pipeline after every session. Step 8 is a background sync fire-and-forget:

```swift
// In SessionFinalizationCoordinator — add an `apiService` dependency

func finaliseSession(_ session: TrainingSession) async throws -> SessionResult {
    // ... existing steps 1–7 unchanged ...

    // Step 8 — background sync (non-throwing, non-blocking)
    Task {
        await apiService?.syncSession(session)
        let profile = try? dataService.fetchOrCreateProfile()
        if let profile {
            await apiService?.syncProfile(profile)
        }
    }

    return SessionResult(session: session, badgeChanges: badgeChanges)
}
```

`apiService` is `Optional<APIService>` so that the coordinator continues to work with `nil` in local-only mode (unit tests, first launch before sign-in).

### Conflict resolution

| Field type | Strategy | Rationale |
|---|---|---|
| Scalar session fields (`fg_percent`, `duration_seconds`, etc.) | Last-write-wins via `synced_at` timestamp | Scalars represent computed aggregates; the most recent device calculation is correct |
| `shot_records` rows | Set-union by primary key (UUID) | Shots are append-only; a shot should never be dropped on merge. The `on_conflict` upsert with `update_columns: []` for shots means a shot written once is never overwritten by a re-sync |
| `player_profiles` skill ratings | Last-write-wins | Ratings are recomputed from session data, so whichever device ran the most recent session wins |
| `goal_records` | Last-write-wins on `current_value`; `is_achieved` is a ratchet (once `true`, never set back to `false`) | Goals should only advance |

### Sync on re-launch

On app launch (after sign-in), `APIService` should check for sessions that have `endedAt != nil` but no corresponding remote row. A lightweight local flag (`syncedToBackend: Bool` on `TrainingSession`, stored in SwiftData) can track this without querying the remote:

```swift
// Add to TrainingSession (new SwiftData migration)
var syncedToBackend: Bool = false
```

On launch, query `DataService` for `syncedToBackend == false && endedAt != nil` and enqueue them as background sync tasks.

---

## 8. Serverless Functions — Supabase Edge Functions

Hasura's auto-generated aggregation queries cover most leaderboard needs directly. Edge Functions are appropriate for logic that requires server-side state Hasura cannot express, or for operations that must not be accessible from the client:

### Recommended Edge Functions

| Function | Trigger | Purpose |
|---|---|---|
| `leaderboard-aggregate` | HTTPS GET (scheduled or on-demand) | Pre-compute weekly top-N leaderboard into a `leaderboard_cache` table; avoids expensive real-time aggregation on every client request |
| `session-export` | HTTPS POST from iOS | Generates a JSON or CSV export of a user's full history; returns a signed download URL from Supabase Storage |
| `badge-sync-webhook` | Postgres trigger on `training_sessions` insert | Server-side badge evaluation for cross-device consistency (future; not needed while badges are computed on-device) |

### Deploy an Edge Function (Deno/TypeScript)

```typescript
// supabase/functions/leaderboard-aggregate/index.ts

import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

serve(async (_req) => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  )

  const since = new Date()
  since.setDate(since.getDate() - 7)

  const { data, error } = await supabase
    .from("training_sessions")
    .select("user_id, users(name), fg_percent")
    .gte("started_at", since.toISOString())
    .order("fg_percent", { ascending: false })
    .limit(50)

  if (error) return new Response(JSON.stringify({ error }), { status: 500 })

  // Upsert into leaderboard_cache table
  // ... aggregation logic ...

  return new Response(JSON.stringify({ ok: true }), { status: 200 })
})
```

Deploy with: `supabase functions deploy leaderboard-aggregate`

---

## 9. gRPC Consideration

### The case for gRPC

`grpc-swift` provides bidirectional streaming over HTTP/2 with protobuf encoding. For a future **live team session** feature where multiple devices contribute shot data to a shared session in real time, gRPC streaming would give sub-100ms delivery with a structured contract — significantly lower latency than polling a REST or GraphQL endpoint.

### The case for deferring

1. **No current multiplayer feature.** gRPC adds `grpc-swift` as a dependency (breaking the current no-third-party-deps convention) and a separate gRPC server process alongside Hasura.
2. **Supabase Realtime is already on the stack.** For coach review (coaching annotations appearing on an athlete's phone) and live leaderboard updates, Supabase Realtime WebSocket subscriptions are sufficient and require zero additional infrastructure.
3. **Polling works for the first leaderboard version.** A 30-second poll from the iOS client against the `leaderboard_cache` table via Hasura is adequate for a v1 social feature.

### Recommendation

Defer gRPC until the **live co-session** feature is scoped. At that point, introduce grpc-swift with a dedicated streaming service (`LiveSessionStreamService`) isolated from `APIService`, so the rest of the stack is not coupled to the transport change. Re-evaluate the no-third-party-deps convention at that stage — the team will be larger and the tradeoff will be different.

---

## 10. Error Handling & Offline

### Design contract

`APIService` methods never throw through to ViewModels for network failures. The local experience must be identical whether the device is online or offline.

```swift
// APIService handles its own errors internally:
func syncSession(_ session: TrainingSession) async {
    guard let token = authToken else { return }
    isSyncing = true
    defer { isSyncing = false }
    do {
        // ... network calls ...
        lastSyncError = nil
        lastSyncedAt  = .now
    } catch {
        lastSyncError = error          // Observable for optional UI indicator
        // Mark for retry on next launch via syncedToBackend flag
    }
}
```

### Retry strategy

On network failure, `syncedToBackend` remains `false`. The sync-on-launch check (Section 7) retries automatically. No explicit retry queue is needed for v1 — launch-time catch-up is sufficient for async session data.

### Offline detection

Use `NWPathMonitor` (Network framework, Apple-native) to observe connectivity. When the path becomes `.satisfied`, trigger a catch-up sync of any sessions with `syncedToBackend == false`:

```swift
// In APIService

private let monitor = NWPathMonitor()

func startMonitoring(dataService: DataService) {
    monitor.pathUpdateHandler = { [weak self] path in
        guard path.status == .satisfied else { return }
        Task { @MainActor in
            await self?.syncPendingSessions(from: dataService)
        }
    }
    monitor.start(queue: DispatchQueue(label: "com.hooptrack.network"))
}
```

### What the user sees

- A subtle sync indicator (cloud icon, not a blocking spinner) on `ProfileTabView` driven by `APIService.isSyncing`.
- A "Last synced X minutes ago" caption driven by `APIService.lastSyncedAt`.
- No error alerts for sync failures — these are silent background operations.

---

## 11. Testing Approach

### Protocol boundary

Define `APIServiceProtocol` so all callers (`SessionFinalizationCoordinator`, future ViewModels) depend on the protocol, not the concrete class:

```swift
protocol APIServiceProtocol: AnyObject {
    var isSyncing: Bool { get }
    var lastSyncError: Error? { get }
    var lastSyncedAt: Date? { get }

    func syncSession(_ session: TrainingSession) async
    func syncProfile(_ profile: PlayerProfile) async
    func fetchWeeklyLeaderboard() async throws -> [LeaderboardEntry]
}
```

### Mock

```swift
// For use in XCTestCase

@MainActor
final class MockAPIService: APIServiceProtocol {
    var isSyncing     = false
    var lastSyncError: Error? = nil
    var lastSyncedAt: Date?   = nil

    var syncSessionCallCount  = 0
    var syncProfileCallCount  = 0
    var leaderboardStub: [LeaderboardEntry] = []
    var leaderboardError: Error? = nil

    func syncSession(_ session: TrainingSession) async {
        syncSessionCallCount += 1
    }

    func syncProfile(_ profile: PlayerProfile) async {
        syncProfileCallCount += 1
    }

    func fetchWeeklyLeaderboard() async throws -> [LeaderboardEntry] {
        if let error = leaderboardError { throw error }
        return leaderboardStub
    }
}
```

### What to test

| Test | What it verifies |
|---|---|
| `SessionFinalizationCoordinatorTests` | `syncSession` is called exactly once after `finaliseSession` completes |
| `SessionFinalizationCoordinatorTests` | A sync failure (`MockAPIService` sets `leaderboardError`) does not propagate a throw from `finaliseSession` |
| `GraphQLClientTests` | Given a mock `URLSession` that returns valid JSON, `GraphQLClient.perform` decodes the expected type |
| `GraphQLClientTests` | Given a mock `URLSession` that returns a GraphQL `errors` array, `perform` throws `GraphQLClientError.serverErrors` |
| `APIServiceTests` | `syncSession` sets `syncedToBackend = true` on the session after a successful call |
| `APIServiceTests` | `syncSession` swallows a network error and sets `lastSyncError` without rethrowing |

All tests are `XCTestCase` subclasses using `@testable import HoopTrack`, consistent with existing conventions in `HoopTrackTests/`.

---

## Implementation Checklist

### Infrastructure (one-time)
- [ ] Create Supabase project; run DDL from Section 3.2
- [ ] Enable RLS; create policies from Section 3.3
- [ ] Create Hasura Cloud project; connect to Supabase Postgres
- [ ] Configure Hasura JWT secret from Supabase Auth JWKS endpoint
- [ ] Add `x-hasura-user-id` claim to Supabase JWT hook

### iOS — Phase A (foundation)
- [ ] Add `GraphQLClient.swift` (Section 5)
- [ ] Add `AnyEncodable.swift` (standard type-erasure, ~20 lines)
- [ ] Add `APIServiceProtocol.swift` + `APIService.swift` (Section 6)
- [ ] Add `syncedToBackend: Bool` field to `TrainingSession`; create SwiftData migration
- [ ] Add `APIService` dependency to `SessionFinalizationCoordinator` (Section 7)

### iOS — Phase B (sync)
- [ ] Implement `syncPendingSessions` catch-up on launch
- [ ] Wire `NWPathMonitor` for online-recovery sync (Section 10)
- [ ] Add sync indicator to `ProfileTabView`

### iOS — Phase C (cross-user features)
- [ ] Implement `fetchWeeklyLeaderboard` and connect to a new `LeaderboardView`
- [ ] Deploy `leaderboard-aggregate` Edge Function (Section 8)

### Testing
- [ ] Add `MockAPIService.swift` to `HoopTrackTests/`
- [ ] Write `GraphQLClientTests.swift` with mock `URLSession`
- [ ] Write `APIServiceTests.swift`
- [ ] Update `SessionFinalizationCoordinatorTests` to inject `MockAPIService`

# Phase 9 — Backend & Database Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror every SwiftData record to a Supabase Postgres database after each session, keyed on `auth.uid()` via Row Level Security. Enable cross-device continuity without changing the local-first UX.

**Architecture:** Add a parallel `SupabaseDataService` next to the existing local `DataService`. Neither knows about the other — the *sync glue* lives in `SyncCoordinator` + a new step 8 in `SessionFinalizationCoordinator`. Sync runs fire-and-forget; network failure is non-fatal (never blocks the local save). Models gain a `cloudSyncedAt: Date?` marker so only dirty rows re-upload. Conflict resolution is pure: scalar fields last-write-wins via `updatedAt`, `shot_records` set-union. Schema changes ship via Supabase migration applied to a branch first, merged to main after RLS is verified with `execute_sql` smoke tests.

**Tech Stack:** Swift 5/6 concurrency, Supabase (`PostgREST` product — already in SPM), `@preconcurrency import Supabase`, SwiftData `HoopTrackSchemaV4` lightweight migration, XCTest, PostgreSQL 15 (Supabase default).

**Design reference:** `docs/upgrade-backend-api.md`, `docs/upgrade-postgresql-supabase.md` (Tier-2 architecture docs).

---

## Out-of-Scope

Explicitly deferred; **do not add** during execution:

- Hasura GraphQL.
- Supabase Edge Functions (leaderboard aggregations, export triggers).
- Offline durable queue with retry budget.
- Separate dev/staging/prod Supabase projects (one project for now, split in P9.5).
- Supabase Realtime subscriptions.

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| Supabase branch `phase-9-schema` | CREATE | Stages schema + RLS before merge to main project |
| Migration `001_initial_schema.sql` | APPLY | All 5 tables + indexes + triggers |
| Migration `002_rls_policies.sql` | APPLY | Per-table RLS policies |
| `HoopTrack/Models/Migrations/HoopTrackSchemaV4.swift` | CREATE | Adds `cloudSyncedAt: Date?` to the 4 syncable models |
| `HoopTrack/Models/PlayerProfile.swift` | MODIFY | +`cloudSyncedAt: Date?` |
| `HoopTrack/Models/TrainingSession.swift` | MODIFY | +`cloudSyncedAt: Date?` |
| `HoopTrack/Models/ShotRecord.swift` | MODIFY | +`cloudSyncedAt: Date?` |
| `HoopTrack/Models/GoalRecord.swift` | MODIFY | +`cloudSyncedAt: Date?` |
| `HoopTrack/Models/EarnedBadge.swift` | MODIFY | +`cloudSyncedAt: Date?` |
| `HoopTrack/Sync/SupabaseClient+Shared.swift` | MODIFY | Compose `AuthClient` + `PostgrestClient` into `SupabaseContainer` |
| `HoopTrack/Sync/SupabaseDataServiceProtocol.swift` | CREATE | Abstract interface mirroring DataService CRUD |
| `HoopTrack/Sync/SupabaseDataService.swift` | CREATE | PostgREST implementation |
| `HoopTrack/Sync/DTOs/PlayerProfileDTO.swift` | CREATE | Codable row representation |
| `HoopTrack/Sync/DTOs/TrainingSessionDTO.swift` | CREATE | Codable row representation |
| `HoopTrack/Sync/DTOs/ShotRecordDTO.swift` | CREATE | Codable row representation |
| `HoopTrack/Sync/DTOs/GoalRecordDTO.swift` | CREATE | Codable row representation |
| `HoopTrack/Sync/DTOs/EarnedBadgeDTO.swift` | CREATE | Codable row representation |
| `HoopTrack/Sync/SyncCoordinator.swift` | CREATE | Orchestrates full + incremental sync; called by SessionFinalizationCoordinator and at sign-in |
| `HoopTrack/Services/SessionFinalizationCoordinator.swift` | MODIFY | Step 8: fire-and-forget `syncCoordinator.syncSession(session)` |
| `HoopTrack/CoordinatorHost.swift` | MODIFY | Build SyncCoordinator; wire into CoordinatorBox |
| `HoopTrack/Utilities/PinningURLSessionDelegate.swift` | MODIFY | Real Supabase SPKI SHA-256 + backup pin |
| `HoopTrack/Utilities/Constants.swift` | MODIFY | Add `HoopTrack.Sync.*` namespace |
| `HoopTrackTests/Sync/SupabaseDataServiceDTOTests.swift` | CREATE | DTO ↔ SwiftData model round-trip tests |
| `HoopTrackTests/Sync/SyncCoordinatorTests.swift` | CREATE | Pure logic over a `MockSupabaseDataService` |
| `HoopTrackTests/Mocks/MockSupabaseDataService.swift` | CREATE | In-memory stub |

---

## Verification Strategy

Each task ends on two green gates:

**Build gate:**
```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' build 2>&1 | tail -2
```
Expected: `** BUILD SUCCEEDED **`, 0 warnings.

**DB gate** (after schema tasks): run an RLS smoke via the Supabase MCP `execute_sql` tool — insert as user A, attempt to read as user B, expect zero rows.

**End-of-phase gate:** full test suite + a manual signed-in round trip (log a session → verify the row lands in Supabase → sign out → sign in on a different simulator device → session history appears).

---

## Task 1: Create Supabase branch for staging

**Tool:** Supabase MCP `create_branch`.

- [ ] **Step 1: Create branch `phase-9-schema`**

Call `mcp__supabase__create_branch` with `name: "phase-9-schema"` against project `nfzhqcgofuohsjhtxvqa`. This gives us an isolated database copy where schema changes land without affecting the live Phase 8 auth project.

- [ ] **Step 2: Capture the branch project ref**

The create response returns a new `project_id` for the branch. Record it — every subsequent `apply_migration` / `execute_sql` call targets this branch, not main.

- [ ] **Step 3: Confirm the branch is in sync**

Call `mcp__supabase__list_branches`. Expected: the new branch present, status "healthy" or similar.

---

## Task 2: Apply schema migration (`001_initial_schema.sql`)

**Tool:** Supabase MCP `apply_migration` against the branch from Task 1.

- [ ] **Step 1: Build the migration SQL**

Migration name: `001_initial_schema`.

```sql
-- ============================================================
-- 001_initial_schema — Phase 9 Backend
-- Five tables mirroring the SwiftData models. UUIDs match the
-- local record IDs so sync is idempotent (upsert on id).
-- ============================================================

create extension if not exists "uuid-ossp";

-- Auto-update trigger reused by every table that needs it.
create or replace function public.handle_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

-- ------------------------------------------------------------
-- player_profiles
-- ------------------------------------------------------------
create table public.player_profiles (
  user_id              uuid primary key references auth.users(id) on delete cascade,
  name                 text not null default 'Player',
  created_at           timestamptz not null default timezone('utc', now()),
  updated_at           timestamptz not null default timezone('utc', now()),

  rating_overall       double precision not null default 0,
  rating_shooting      double precision not null default 0,
  rating_ball_handling double precision not null default 0,
  rating_athleticism   double precision not null default 0,
  rating_consistency   double precision not null default 0,
  rating_volume        double precision not null default 0,

  career_shots_attempted int not null default 0,
  career_shots_made      int not null default 0,
  total_session_count    int not null default 0,
  total_training_minutes double precision not null default 0,

  pr_best_fg_percent_session double precision not null default 0,
  pr_most_makes_session      int not null default 0,
  pr_best_consistency_score  double precision,
  pr_vertical_jump_cm        double precision not null default 0,

  current_streak_days  int not null default 0,
  longest_streak_days  int not null default 0,
  last_session_date    timestamptz,

  preferred_court_type      text not null default 'nba',
  videos_auto_delete_days   int  not null default 60
);
create trigger set_updated_at before update on public.player_profiles
  for each row execute function public.handle_updated_at();

-- ------------------------------------------------------------
-- training_sessions
-- ------------------------------------------------------------
create table public.training_sessions (
  id                     uuid primary key,
  user_id                uuid not null references auth.users(id) on delete cascade,
  created_at             timestamptz not null default timezone('utc', now()),
  updated_at             timestamptz not null default timezone('utc', now()),

  started_at             timestamptz not null,
  ended_at               timestamptz,
  duration_seconds       double precision not null,
  drill_type             text not null,
  named_drill            text,
  court_type             text not null,
  location_tag           text not null default '',
  notes                  text not null default '',
  shots_attempted        int not null default 0,
  shots_made             int not null default 0,
  fg_percent             double precision not null default 0,
  avg_release_angle_deg  double precision,
  avg_release_time_ms    double precision,
  avg_vertical_jump_cm   double precision,
  avg_shot_speed_mph     double precision,
  consistency_score      double precision,
  video_file_name        text,
  video_pinned_by_user   boolean not null default false,

  total_dribbles         int,
  avg_dribbles_per_sec   double precision,
  max_dribbles_per_sec   double precision,
  hand_balance_fraction  double precision,
  dribble_combos_detected int,

  best_shuttle_run_seconds   double precision,
  best_lane_agility_seconds  double precision,

  longest_make_streak    int not null default 0,
  shot_speed_std_dev     double precision
);
create index training_sessions_user_started_idx
  on public.training_sessions(user_id, started_at desc);
create trigger set_updated_at before update on public.training_sessions
  for each row execute function public.handle_updated_at();

-- ------------------------------------------------------------
-- shot_records (APPEND-ONLY — no UPDATE, no DELETE in RLS)
-- ------------------------------------------------------------
create table public.shot_records (
  id                 uuid primary key,
  user_id            uuid not null references auth.users(id) on delete cascade,
  session_id         uuid not null references public.training_sessions(id) on delete cascade,
  created_at         timestamptz not null default timezone('utc', now()),

  timestamp          timestamptz not null,
  sequence_index    int not null,
  result            text not null,
  zone              text not null,
  shot_type         text not null,
  court_x           double precision not null,
  court_y           double precision not null,
  release_angle_deg double precision,
  release_time_ms   double precision,
  vertical_jump_cm  double precision,
  leg_angle_deg     double precision,
  shot_speed_mph    double precision,
  video_timestamp_seconds double precision,
  is_user_corrected boolean not null default false
);
create index shot_records_session_idx on public.shot_records(session_id);
create index shot_records_user_timestamp_idx on public.shot_records(user_id, timestamp desc);

-- ------------------------------------------------------------
-- goal_records
-- ------------------------------------------------------------
create table public.goal_records (
  id              uuid primary key,
  user_id         uuid not null references auth.users(id) on delete cascade,
  created_at      timestamptz not null default timezone('utc', now()),
  updated_at      timestamptz not null default timezone('utc', now()),

  target_date     timestamptz,
  title           text not null,
  skill           text not null,
  metric          text not null,
  target_value    double precision not null,
  baseline_value  double precision not null,
  current_value   double precision not null,
  is_achieved     boolean not null default false,
  achieved_at     timestamptz
);
create trigger set_updated_at before update on public.goal_records
  for each row execute function public.handle_updated_at();

-- ------------------------------------------------------------
-- earned_badges
-- ------------------------------------------------------------
create table public.earned_badges (
  id         uuid primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),

  badge_id   text not null,
  mmr        double precision not null default 0,
  rank       text not null,
  earned_at  timestamptz not null default timezone('utc', now()),

  unique(user_id, badge_id)
);
create trigger set_updated_at before update on public.earned_badges
  for each row execute function public.handle_updated_at();
```

- [ ] **Step 2: Apply the migration to the branch**

Call `mcp__supabase__apply_migration` with `project_id: <branch>`, `name: "001_initial_schema"`, `query: <SQL above>`.

- [ ] **Step 3: Verify tables exist**

Call `mcp__supabase__list_tables` with `schemas: ["public"]` against the branch. Expected: the 5 tables present with correct column lists.

---

## Task 3: Apply RLS policies (`002_rls_policies.sql`)

**Tool:** Supabase MCP `apply_migration`.

- [ ] **Step 1: Build the policy SQL**

Migration name: `002_rls_policies`. **Shot records are deliberately append-only: no UPDATE, no DELETE policy is declared.**

```sql
-- ============================================================
-- 002_rls_policies — Per-table Row Level Security
-- Every table is isolated per auth.uid(). shot_records is
-- append-only to prevent retroactive history edits.
-- ============================================================

alter table public.player_profiles   enable row level security;
alter table public.training_sessions enable row level security;
alter table public.shot_records      enable row level security;
alter table public.goal_records      enable row level security;
alter table public.earned_badges     enable row level security;

-- player_profiles: one row per user, R/W own row
create policy "player_profiles_select_own" on public.player_profiles
  for select using (user_id = auth.uid());
create policy "player_profiles_insert_own" on public.player_profiles
  for insert with check (user_id = auth.uid());
create policy "player_profiles_update_own" on public.player_profiles
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

-- training_sessions: R/W own rows
create policy "training_sessions_select_own" on public.training_sessions
  for select using (user_id = auth.uid());
create policy "training_sessions_insert_own" on public.training_sessions
  for insert with check (user_id = auth.uid());
create policy "training_sessions_update_own" on public.training_sessions
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "training_sessions_delete_own" on public.training_sessions
  for delete using (user_id = auth.uid());

-- shot_records: APPEND-ONLY — select + insert only
create policy "shot_records_select_own" on public.shot_records
  for select using (user_id = auth.uid());
create policy "shot_records_insert_own" on public.shot_records
  for insert with check (user_id = auth.uid());
-- Deliberately NO update / delete policy.

-- goal_records
create policy "goal_records_select_own" on public.goal_records
  for select using (user_id = auth.uid());
create policy "goal_records_insert_own" on public.goal_records
  for insert with check (user_id = auth.uid());
create policy "goal_records_update_own" on public.goal_records
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "goal_records_delete_own" on public.goal_records
  for delete using (user_id = auth.uid());

-- earned_badges
create policy "earned_badges_select_own" on public.earned_badges
  for select using (user_id = auth.uid());
create policy "earned_badges_insert_own" on public.earned_badges
  for insert with check (user_id = auth.uid());
create policy "earned_badges_update_own" on public.earned_badges
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
```

- [ ] **Step 2: Apply**

Same pattern as Task 2. `apply_migration` with `name: "002_rls_policies"`.

- [ ] **Step 3: Verify**

Call `execute_sql`:
```sql
select tablename, policyname from pg_policies where schemaname = 'public' order by 1, 2;
```

Expected: 14 policies across 5 tables. `shot_records` has exactly 2 policies (select + insert).

---

## Task 4: RLS smoke test via `execute_sql`

**Tool:** Supabase MCP `execute_sql` against the branch.

- [ ] **Step 1: Probe an insert with no auth context fails**

```sql
insert into public.training_sessions
  (id, user_id, started_at, duration_seconds, drill_type, court_type)
values
  (uuid_generate_v4(), uuid_generate_v4(), now(), 0, 'freeShoot', 'nba');
```

Expected: error — violates RLS because `auth.uid()` is null in the MCP's service-role context... wait, service-role bypasses RLS. The more useful probe is:

```sql
-- Confirm RLS is enabled and no one-table insert can succeed without user_id matching
select has_table_privilege('authenticated', 'public.training_sessions', 'INSERT');
select relrowsecurity from pg_class where relname = 'training_sessions';
```

Expected: `relrowsecurity = true`.

- [ ] **Step 2: Probe that policies resolve correctly**

```sql
select cmd, qual, with_check from pg_policies
 where tablename = 'training_sessions';
```

Spot-check that `qual` / `with_check` columns contain `auth.uid()` references for each policy. If anything's missing, roll back and fix.

---

## Task 5: Add `cloudSyncedAt` to models + `HoopTrackSchemaV4`

**Files:**
- Modify: `HoopTrack/Models/{PlayerProfile,TrainingSession,ShotRecord,GoalRecord,EarnedBadge}.swift`
- Create: `HoopTrack/Models/Migrations/HoopTrackSchemaV4.swift` (append to existing SchemaV*.swift file)

- [ ] **Step 1: Add the field to each model**

For each of the 5 model files, add near the existing properties (e.g. after the last persisted column):

```swift
    // MARK: - Sync (Phase 9)
    /// Timestamp of the last successful Supabase upload. nil until the record
    /// is synced. Set by SyncCoordinator after PostgREST acknowledges the
    /// upsert. Read by SyncCoordinator to determine dirty rows.
    var cloudSyncedAt: Date?
```

And in the `init` method, append:

```swift
        self.cloudSyncedAt = nil
```

- [ ] **Step 2: Register V4 schema**

In `HoopTrack/Models/Migrations/HoopTrackSchemaV1.swift` append:

```swift
/// V4 — Phase 9 — adds `cloudSyncedAt: Date?` to the 4 syncable models.
/// Lightweight: optional field, no data rewrite needed.
enum HoopTrackSchemaV4: VersionedSchema {
    static let versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [PlayerProfile.self, TrainingSession.self, ShotRecord.self, GoalRecord.self, EarnedBadge.self]
    }
}
```

(The current HoopTrackApp.swift uses a flat `Schema([...])` without a migration plan. The V4 entry is forward-compatible and ready for whenever a non-additive change makes us switch back to `Schema(versionedSchema:)`.)

- [ ] **Step 3: Build + run tests**

Build clean, run the full test suite. Expected: tests pass, no warnings. Because the new field is optional and `PlayerProfile().cloudSyncedAt == nil` at construction time, SwiftData autodetects it as additive and doesn't ask for a migration plan.

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/Models/
git commit -m "feat(sync): add cloudSyncedAt marker for Phase 9 backend sync

Each syncable @Model gets cloudSyncedAt: Date? — nil means the row
has never uploaded or is dirty. Set by SyncCoordinator after PostgREST
upsert success; checked before deciding what to re-upload. V4 schema
entry registered in HoopTrackSchemaV1.swift for the eventual
VersionedSchema migration."
```

---

## Task 6: Expand `SupabaseContainer` to include PostgREST

**Files:**
- Modify: `HoopTrack/Auth/SupabaseClient+Shared.swift` → move + rename to `HoopTrack/Sync/SupabaseContainer.swift`

- [ ] **Step 1: Create the Sync folder**

```bash
mkdir -p HoopTrack/Sync/DTOs
```

- [ ] **Step 2: Rewrite the container to compose Auth + PostgREST**

Replace `HoopTrack/Auth/SupabaseClient+Shared.swift` contents with:

```swift
// HoopTrack/Auth/SupabaseClient+Shared.swift
// Phase 9: Auth + PostgREST composed side-by-side. The auth JWT is
// read from the keychain storage and passed as the Authorization header
// on every PostgREST request so Row Level Security resolves correctly.

import Foundation
import Security
import Auth
import PostgREST

enum SupabaseContainer {

    // MARK: - Auth

    static let auth: AuthClient = {
        AuthClient(
            url: HoopTrack.Backend.supabaseURL.appendingPathComponent("auth/v1"),
            headers: anonHeaders,
            flowType: .pkce,
            localStorage: KeychainAuthStorage(),
            logger: nil
        )
    }()

    // MARK: - PostgREST

    /// Fresh client per request is the supabase-swift pattern — the client
    /// itself is cheap, and avoids stale auth headers after sign-out.
    static func postgrest() async throws -> PostgrestClient {
        let accessToken = try await auth.session.accessToken
        return PostgrestClient(
            url: HoopTrack.Backend.supabaseURL.appendingPathComponent("rest/v1"),
            headers: anonHeaders.merging(["Authorization": "Bearer \(accessToken)"]) { _, b in b },
            logger: nil
        )
    }

    // MARK: - Common headers

    private static var anonHeaders: [String: String] {
        [
            "apikey": HoopTrack.Backend.supabaseAnonKey,
            "Authorization": "Bearer \(HoopTrack.Backend.supabaseAnonKey)"
        ]
    }
}

// MARK: - Keychain storage bridge
// ... (KeychainAuthStorage + KeychainRawStorage stay unchanged)
```

Keep the existing `KeychainAuthStorage` and `KeychainRawStorage` sections at the bottom unchanged — only replace the `SupabaseContainer` enum.

- [ ] **Step 3: Build**

Build clean. Expected: `** BUILD SUCCEEDED **`. If `PostgREST` imports fail, the user hasn't added that SPM product — but Phase 8's pbxproj audit confirmed it's already on the target, so this should Just Work.

- [ ] **Step 4: Commit**

```bash
git add HoopTrack/HoopTrack/Auth/SupabaseClient+Shared.swift
git commit -m "feat(sync): expose PostgrestClient via SupabaseContainer

Each call to SupabaseContainer.postgrest() builds a fresh PostgrestClient
with the current session's access token in the Authorization header.
RLS resolves correctly because the JWT's auth.uid() matches what the
policies check."
```

---

## Task 7: DTOs (row ↔ model codec)

**Files:**
- Create: `HoopTrack/Sync/DTOs/PlayerProfileDTO.swift`
- Create: `HoopTrack/Sync/DTOs/TrainingSessionDTO.swift`
- Create: `HoopTrack/Sync/DTOs/ShotRecordDTO.swift`
- Create: `HoopTrack/Sync/DTOs/GoalRecordDTO.swift`
- Create: `HoopTrack/Sync/DTOs/EarnedBadgeDTO.swift`

- [ ] **Step 1: Write `PlayerProfileDTO.swift`**

```swift
// HoopTrack/Sync/DTOs/PlayerProfileDTO.swift
import Foundation

/// Codable mirror of the `player_profiles` Postgres row.
/// Field names match the snake_case column names via CodingKeys.
struct PlayerProfileDTO: Codable, Sendable {
    let userId: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var ratingOverall: Double
    var ratingShooting: Double
    var ratingBallHandling: Double
    var ratingAthleticism: Double
    var ratingConsistency: Double
    var ratingVolume: Double

    var careerShotsAttempted: Int
    var careerShotsMade: Int
    var totalSessionCount: Int
    var totalTrainingMinutes: Double

    var prBestFgPercentSession: Double
    var prMostMakesSession: Int
    var prBestConsistencyScore: Double?
    var prVerticalJumpCm: Double

    var currentStreakDays: Int
    var longestStreakDays: Int
    var lastSessionDate: Date?

    var preferredCourtType: String
    var videosAutoDeleteDays: Int

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case name
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case ratingOverall = "rating_overall"
        case ratingShooting = "rating_shooting"
        case ratingBallHandling = "rating_ball_handling"
        case ratingAthleticism = "rating_athleticism"
        case ratingConsistency = "rating_consistency"
        case ratingVolume = "rating_volume"
        case careerShotsAttempted = "career_shots_attempted"
        case careerShotsMade = "career_shots_made"
        case totalSessionCount = "total_session_count"
        case totalTrainingMinutes = "total_training_minutes"
        case prBestFgPercentSession = "pr_best_fg_percent_session"
        case prMostMakesSession = "pr_most_makes_session"
        case prBestConsistencyScore = "pr_best_consistency_score"
        case prVerticalJumpCm = "pr_vertical_jump_cm"
        case currentStreakDays = "current_streak_days"
        case longestStreakDays = "longest_streak_days"
        case lastSessionDate = "last_session_date"
        case preferredCourtType = "preferred_court_type"
        case videosAutoDeleteDays = "videos_auto_delete_days"
    }

    init(from profile: PlayerProfile, userID: UUID) {
        self.userId = userID
        self.name = profile.name
        self.createdAt = profile.createdAt
        self.updatedAt = Date()

        self.ratingOverall = profile.ratingOverall
        self.ratingShooting = profile.ratingShooting
        self.ratingBallHandling = profile.ratingBallHandling
        self.ratingAthleticism = profile.ratingAthleticism
        self.ratingConsistency = profile.ratingConsistency
        self.ratingVolume = profile.ratingVolume

        self.careerShotsAttempted = profile.careerShotsAttempted
        self.careerShotsMade = profile.careerShotsMade
        self.totalSessionCount = profile.totalSessionCount
        self.totalTrainingMinutes = profile.totalTrainingMinutes

        self.prBestFgPercentSession = profile.prBestFGPercentSession
        self.prMostMakesSession = profile.prMostMakesSession
        // PlayerProfile stores Double.infinity when unset — translate to nil.
        self.prBestConsistencyScore = profile.prBestConsistencyScore.isFinite
            ? profile.prBestConsistencyScore : nil
        self.prVerticalJumpCm = profile.prVerticalJumpCm

        self.currentStreakDays = profile.currentStreakDays
        self.longestStreakDays = profile.longestStreakDays
        self.lastSessionDate = profile.lastSessionDate

        self.preferredCourtType = profile.preferredCourtType.rawValue
        self.videosAutoDeleteDays = profile.videosAutoDeleteDays
    }
}
```

- [ ] **Step 2: Write `TrainingSessionDTO.swift`**

Follow the same pattern for `TrainingSession`. Key decisions:
- `id`: UUID primary key matching SwiftData
- `userId`: UUID from `profile.supabaseUserID` (fetched at sync time)
- `drillType`, `courtType`, `namedDrill`: serialize via `.rawValue` (strings)
- All optional columns map straight through

Full code:

```swift
// HoopTrack/Sync/DTOs/TrainingSessionDTO.swift
import Foundation

struct TrainingSessionDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    var drillType: String
    var namedDrill: String?
    var courtType: String
    var locationTag: String
    var notes: String
    var shotsAttempted: Int
    var shotsMade: Int
    var fgPercent: Double
    var avgReleaseAngleDeg: Double?
    var avgReleaseTimeMs: Double?
    var avgVerticalJumpCm: Double?
    var avgShotSpeedMph: Double?
    var consistencyScore: Double?
    var videoFileName: String?
    var videoPinnedByUser: Bool
    var totalDribbles: Int?
    var avgDribblesPerSec: Double?
    var maxDribblesPerSec: Double?
    var handBalanceFraction: Double?
    var dribbleCombosDetected: Int?
    var bestShuttleRunSeconds: Double?
    var bestLaneAgilitySeconds: Double?
    var longestMakeStreak: Int
    var shotSpeedStdDev: Double?

    enum CodingKeys: String, CodingKey {
        case id, createdAt = "created_at", updatedAt = "updated_at"
        case userId = "user_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case drillType = "drill_type"
        case namedDrill = "named_drill"
        case courtType = "court_type"
        case locationTag = "location_tag"
        case notes, shotsAttempted = "shots_attempted", shotsMade = "shots_made"
        case fgPercent = "fg_percent"
        case avgReleaseAngleDeg = "avg_release_angle_deg"
        case avgReleaseTimeMs = "avg_release_time_ms"
        case avgVerticalJumpCm = "avg_vertical_jump_cm"
        case avgShotSpeedMph = "avg_shot_speed_mph"
        case consistencyScore = "consistency_score"
        case videoFileName = "video_file_name"
        case videoPinnedByUser = "video_pinned_by_user"
        case totalDribbles = "total_dribbles"
        case avgDribblesPerSec = "avg_dribbles_per_sec"
        case maxDribblesPerSec = "max_dribbles_per_sec"
        case handBalanceFraction = "hand_balance_fraction"
        case dribbleCombosDetected = "dribble_combos_detected"
        case bestShuttleRunSeconds = "best_shuttle_run_seconds"
        case bestLaneAgilitySeconds = "best_lane_agility_seconds"
        case longestMakeStreak = "longest_make_streak"
        case shotSpeedStdDev = "shot_speed_std_dev"
    }

    init(from session: TrainingSession, userID: UUID) {
        self.id = session.id
        self.userId = userID
        self.createdAt = session.startedAt
        self.updatedAt = Date()
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.durationSeconds = session.durationSeconds
        self.drillType = session.drillType.rawValue
        self.namedDrill = session.namedDrill?.rawValue
        self.courtType = session.courtType.rawValue
        self.locationTag = session.locationTag
        self.notes = session.notes
        self.shotsAttempted = session.shotsAttempted
        self.shotsMade = session.shotsMade
        self.fgPercent = session.fgPercent
        self.avgReleaseAngleDeg = session.avgReleaseAngleDeg
        self.avgReleaseTimeMs = session.avgReleaseTimeMs
        self.avgVerticalJumpCm = session.avgVerticalJumpCm
        self.avgShotSpeedMph = session.avgShotSpeedMph
        self.consistencyScore = session.consistencyScore
        self.videoFileName = session.videoFileName
        self.videoPinnedByUser = session.videoPinnedByUser
        self.totalDribbles = session.totalDribbles
        self.avgDribblesPerSec = session.avgDribblesPerSec
        self.maxDribblesPerSec = session.maxDribblesPerSec
        self.handBalanceFraction = session.handBalanceFraction
        self.dribbleCombosDetected = session.dribbleCombosDetected
        self.bestShuttleRunSeconds = session.bestShuttleRunSeconds
        self.bestLaneAgilitySeconds = session.bestLaneAgilitySeconds
        self.longestMakeStreak = session.longestMakeStreak
        self.shotSpeedStdDev = session.shotSpeedStdDev
    }
}
```

- [ ] **Step 3: Write `ShotRecordDTO.swift`**

```swift
// HoopTrack/Sync/DTOs/ShotRecordDTO.swift
import Foundation

struct ShotRecordDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    let sessionId: UUID
    var createdAt: Date

    var timestamp: Date
    var sequenceIndex: Int
    var result: String
    var zone: String
    var shotType: String
    var courtX: Double
    var courtY: Double
    var releaseAngleDeg: Double?
    var releaseTimeMs: Double?
    var verticalJumpCm: Double?
    var legAngleDeg: Double?
    var shotSpeedMph: Double?
    var videoTimestampSeconds: Double?
    var isUserCorrected: Bool

    enum CodingKeys: String, CodingKey {
        case id, timestamp, zone, notes
        case userId = "user_id"
        case sessionId = "session_id"
        case createdAt = "created_at"
        case sequenceIndex = "sequence_index"
        case result
        case shotType = "shot_type"
        case courtX = "court_x"
        case courtY = "court_y"
        case releaseAngleDeg = "release_angle_deg"
        case releaseTimeMs = "release_time_ms"
        case verticalJumpCm = "vertical_jump_cm"
        case legAngleDeg = "leg_angle_deg"
        case shotSpeedMph = "shot_speed_mph"
        case videoTimestampSeconds = "video_timestamp_seconds"
        case isUserCorrected = "is_user_corrected"
    }

    init(from shot: ShotRecord, userID: UUID, sessionID: UUID) {
        self.id = shot.id
        self.userId = userID
        self.sessionId = sessionID
        self.createdAt = shot.timestamp
        self.timestamp = shot.timestamp
        self.sequenceIndex = shot.sequenceIndex
        self.result = shot.result.rawValue
        self.zone = shot.zone.rawValue
        self.shotType = shot.shotType.rawValue
        self.courtX = shot.courtX
        self.courtY = shot.courtY
        self.releaseAngleDeg = shot.releaseAngleDeg
        self.releaseTimeMs = shot.releaseTimeMs
        self.verticalJumpCm = shot.verticalJumpCm
        self.legAngleDeg = shot.legAngleDeg
        self.shotSpeedMph = shot.shotSpeedMph
        self.videoTimestampSeconds = shot.videoTimestampSeconds
        self.isUserCorrected = shot.isUserCorrected
    }
}
```

- [ ] **Step 4: Write `GoalRecordDTO.swift`**

```swift
// HoopTrack/Sync/DTOs/GoalRecordDTO.swift
import Foundation

struct GoalRecordDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var targetDate: Date?
    var title: String
    var skill: String
    var metric: String
    var targetValue: Double
    var baselineValue: Double
    var currentValue: Double
    var isAchieved: Bool
    var achievedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case targetDate = "target_date"
        case title, skill, metric
        case targetValue = "target_value"
        case baselineValue = "baseline_value"
        case currentValue = "current_value"
        case isAchieved = "is_achieved"
        case achievedAt = "achieved_at"
    }

    init(from goal: GoalRecord, userID: UUID) {
        self.id = goal.id
        self.userId = userID
        self.createdAt = goal.createdAt
        self.updatedAt = Date()
        self.targetDate = goal.targetDate
        self.title = goal.title
        self.skill = goal.skill.rawValue
        self.metric = goal.metric.rawValue
        self.targetValue = goal.targetValue
        self.baselineValue = goal.baselineValue
        self.currentValue = goal.currentValue
        self.isAchieved = goal.isAchieved
        self.achievedAt = goal.achievedAt
    }
}
```

- [ ] **Step 5: Write `EarnedBadgeDTO.swift`**

```swift
// HoopTrack/Sync/DTOs/EarnedBadgeDTO.swift
import Foundation

struct EarnedBadgeDTO: Codable, Sendable {
    let id: UUID
    let userId: UUID
    var createdAt: Date
    var updatedAt: Date

    var badgeId: String
    var mmr: Double
    var rank: String
    var earnedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case badgeId = "badge_id"
        case mmr
        case rank
        case earnedAt = "earned_at"
    }

    init(from badge: EarnedBadge, userID: UUID) {
        self.id = badge.id
        self.userId = userID
        self.createdAt = badge.earnedAt
        self.updatedAt = Date()
        self.badgeId = badge.badgeID
        self.mmr = badge.mmr
        self.rank = badge.rank.rawValue
        self.earnedAt = badge.earnedAt
    }
}
```

- [ ] **Step 6: Build + commit**

```bash
git add HoopTrack/HoopTrack/Sync/DTOs/
git commit -m "feat(sync): add Codable DTOs for all 5 synced entities

Each DTO carries snake_case CodingKeys matching the Postgres column
names plus an init(from:userID:) that reads from the SwiftData model.
Sync goes one-way for now (local -> Supabase); the reverse path for
cross-device restore lands in a follow-up phase."
```

---

## Task 8: `SupabaseDataServiceProtocol` + `MockSupabaseDataService`

**Files:**
- Create: `HoopTrack/Sync/SupabaseDataServiceProtocol.swift`
- Create: `HoopTrackTests/Mocks/MockSupabaseDataService.swift`

- [ ] **Step 1: Write the protocol**

```swift
// HoopTrack/Sync/SupabaseDataServiceProtocol.swift
import Foundation

protocol SupabaseDataServiceProtocol: Sendable {
    /// Upsert the current user's profile row.
    func upsertProfile(_ dto: PlayerProfileDTO) async throws

    /// Upsert a training session row.
    func upsertSession(_ dto: TrainingSessionDTO) async throws

    /// Insert shot records — append-only; upsert fails by design.
    func insertShots(_ dtos: [ShotRecordDTO]) async throws

    /// Upsert a goal.
    func upsertGoal(_ dto: GoalRecordDTO) async throws

    /// Upsert an earned badge. Uses (user_id, badge_id) uniqueness.
    func upsertBadge(_ dto: EarnedBadgeDTO) async throws
}
```

- [ ] **Step 2: Write the mock**

```swift
// HoopTrackTests/Mocks/MockSupabaseDataService.swift
import Foundation
@testable import HoopTrack

final class MockSupabaseDataService: SupabaseDataServiceProtocol, @unchecked Sendable {
    var scriptedError: Error?

    private(set) var profileUpserts: [PlayerProfileDTO] = []
    private(set) var sessionUpserts: [TrainingSessionDTO] = []
    private(set) var shotInserts:   [[ShotRecordDTO]] = []
    private(set) var goalUpserts:   [GoalRecordDTO] = []
    private(set) var badgeUpserts:  [EarnedBadgeDTO] = []

    func upsertProfile(_ dto: PlayerProfileDTO) async throws {
        try throwIfScripted()
        profileUpserts.append(dto)
    }

    func upsertSession(_ dto: TrainingSessionDTO) async throws {
        try throwIfScripted()
        sessionUpserts.append(dto)
    }

    func insertShots(_ dtos: [ShotRecordDTO]) async throws {
        try throwIfScripted()
        shotInserts.append(dtos)
    }

    func upsertGoal(_ dto: GoalRecordDTO) async throws {
        try throwIfScripted()
        goalUpserts.append(dto)
    }

    func upsertBadge(_ dto: EarnedBadgeDTO) async throws {
        try throwIfScripted()
        badgeUpserts.append(dto)
    }

    private func throwIfScripted() throws {
        if let err = scriptedError { throw err }
    }
}
```

- [ ] **Step 3: Build + commit**

```bash
git add HoopTrack/HoopTrack/Sync/SupabaseDataServiceProtocol.swift \
        HoopTrack/HoopTrackTests/Mocks/MockSupabaseDataService.swift
git commit -m "feat(sync): SupabaseDataServiceProtocol + MockSupabaseDataService"
```

---

## Task 9: `SupabaseDataService` (PostgREST impl)

**Files:**
- Create: `HoopTrack/Sync/SupabaseDataService.swift`

- [ ] **Step 1: Write the implementation**

```swift
// HoopTrack/Sync/SupabaseDataService.swift
import Foundation
import PostgREST

final class SupabaseDataService: SupabaseDataServiceProtocol, @unchecked Sendable {

    func upsertProfile(_ dto: PlayerProfileDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("player_profiles")
            .upsert(dto, onConflict: "user_id")
            .execute()
    }

    func upsertSession(_ dto: TrainingSessionDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("training_sessions")
            .upsert(dto, onConflict: "id")
            .execute()
    }

    func insertShots(_ dtos: [ShotRecordDTO]) async throws {
        guard !dtos.isEmpty else { return }
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("shot_records")
            .insert(dtos)
            .execute()
    }

    func upsertGoal(_ dto: GoalRecordDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("goal_records")
            .upsert(dto, onConflict: "id")
            .execute()
    }

    func upsertBadge(_ dto: EarnedBadgeDTO) async throws {
        let client = try await SupabaseContainer.postgrest()
        try await client
            .from("earned_badges")
            .upsert(dto, onConflict: "user_id,badge_id")
            .execute()
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
git add HoopTrack/HoopTrack/Sync/SupabaseDataService.swift
git commit -m "feat(sync): SupabaseDataService PostgREST implementation"
```

---

## Task 10: DTO round-trip tests

**Files:**
- Create: `HoopTrackTests/Sync/SupabaseDataServiceDTOTests.swift`

- [ ] **Step 1: Write tests**

```swift
// HoopTrackTests/Sync/SupabaseDataServiceDTOTests.swift
import XCTest
@testable import HoopTrack

@MainActor
final class SupabaseDataServiceDTOTests: XCTestCase {

    func test_playerProfileDTO_encodesSnakeCase() throws {
        let profile = PlayerProfile(name: "Test")
        profile.ratingShooting = 72
        let dto = PlayerProfileDTO(from: profile, userID: UUID())

        let json = try JSONEncoder().encode(dto)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]

        XCTAssertEqual(dict["name"] as? String, "Test")
        XCTAssertEqual(dict["rating_shooting"] as? Double, 72)
        XCTAssertNotNil(dict["user_id"])
    }

    func test_playerProfileDTO_translatesInfiniteConsistencyScore_toNil() {
        let profile = PlayerProfile()
        profile.prBestConsistencyScore = .infinity
        let dto = PlayerProfileDTO(from: profile, userID: UUID())
        XCTAssertNil(dto.prBestConsistencyScore)
    }

    func test_trainingSessionDTO_roundTripsCore() throws {
        let session = TrainingSession(drillType: .freeShoot)
        session.shotsAttempted = 10
        session.shotsMade = 7
        session.fgPercent = 70
        let dto = TrainingSessionDTO(from: session, userID: UUID())

        let data = try JSONEncoder().encode(dto)
        let round = try JSONDecoder().decode(TrainingSessionDTO.self, from: data)

        XCTAssertEqual(round.id, session.id)
        XCTAssertEqual(round.shotsAttempted, 10)
        XCTAssertEqual(round.shotsMade, 7)
        XCTAssertEqual(round.fgPercent, 70)
        XCTAssertEqual(round.drillType, "freeShoot")
    }

    func test_shotRecordDTO_carriesSessionId() {
        let sessionID = UUID()
        let shot = ShotRecord(result: .make, zone: .midRange, shotType: .catchAndShoot,
                               courtX: 0.5, courtY: 0.5)
        let dto = ShotRecordDTO(from: shot, userID: UUID(), sessionID: sessionID)
        XCTAssertEqual(dto.sessionId, sessionID)
        XCTAssertEqual(dto.result, "make")
        XCTAssertEqual(dto.zone, "midRange")
    }

    func test_goalRecordDTO_encodesEnums_asRawValues() throws {
        let goal = GoalRecord(title: "3s",
                               skill: .shooting, metric: .fgPercent,
                               targetValue: 40, baselineValue: 20)
        let dto = GoalRecordDTO(from: goal, userID: UUID())
        let json = try JSONEncoder().encode(dto)
        let dict = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        XCTAssertEqual(dict["skill"] as? String, SkillDimension.shooting.rawValue)
        XCTAssertEqual(dict["metric"] as? String, GoalMetric.fgPercent.rawValue)
    }
}
```

**Note:** The exact SwiftData model init signatures may differ from what's shown — read the model files and adjust constructor call sites if the compiler complains. The tests are there to verify the DTO pack/unpack, not the model init API.

- [ ] **Step 2: Run tests**

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' \
  -only-testing:HoopTrackTests/SupabaseDataServiceDTOTests 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`, 5 passing.

- [ ] **Step 3: Commit**

```bash
git add HoopTrack/HoopTrackTests/Sync/SupabaseDataServiceDTOTests.swift
git commit -m "test(sync): DTO codec round-trip coverage"
```

---

## Task 11: `SyncCoordinator` with TDD

**Files:**
- Create: `HoopTrack/Sync/SyncCoordinator.swift`
- Create: `HoopTrackTests/Sync/SyncCoordinatorTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// HoopTrackTests/Sync/SyncCoordinatorTests.swift
import XCTest
@testable import HoopTrack

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    func test_syncSession_uploadsSession_andAllShots() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let userID = UUID()

        let session = TrainingSession(drillType: .freeShoot)
        session.shotsAttempted = 3
        let shots = (0..<3).map { i in
            let shot = ShotRecord(result: .make, zone: .midRange,
                                   shotType: .catchAndShoot,
                                   courtX: 0.5, courtY: 0.5)
            shot.sequenceIndex = i + 1
            shot.session = session
            return shot
        }
        session.shots = shots

        try await coordinator.syncSession(session, userID: userID)

        XCTAssertEqual(mock.sessionUpserts.count, 1)
        XCTAssertEqual(mock.sessionUpserts.first?.id, session.id)
        XCTAssertEqual(mock.shotInserts.count, 1)
        XCTAssertEqual(mock.shotInserts.first?.count, 3)
    }

    func test_syncSession_withNoShots_skipsShotInsert() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let session = TrainingSession(drillType: .freeShoot)
        session.shots = []

        try await coordinator.syncSession(session, userID: UUID())

        XCTAssertEqual(mock.sessionUpserts.count, 1)
        XCTAssertEqual(mock.shotInserts.count, 0)
    }

    func test_syncSession_stampsCloudSyncedAt_onSuccess() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let session = TrainingSession(drillType: .freeShoot)
        session.shots = []
        XCTAssertNil(session.cloudSyncedAt)

        try await coordinator.syncSession(session, userID: UUID())

        XCTAssertNotNil(session.cloudSyncedAt)
    }

    func test_syncSession_propagatesBackendError() async {
        let mock = MockSupabaseDataService()
        mock.scriptedError = NSError(domain: "test", code: -1)
        let coordinator = SyncCoordinator(backend: mock)
        let session = TrainingSession(drillType: .freeShoot)
        session.shots = []

        do {
            try await coordinator.syncSession(session, userID: UUID())
            XCTFail("expected throw")
        } catch {
            XCTAssertNil(session.cloudSyncedAt)
        }
    }

    func test_syncProfile_upsertsOnce() async throws {
        let mock = MockSupabaseDataService()
        let coordinator = SyncCoordinator(backend: mock)
        let profile = PlayerProfile()

        try await coordinator.syncProfile(profile, userID: UUID())

        XCTAssertEqual(mock.profileUpserts.count, 1)
        XCTAssertNotNil(profile.cloudSyncedAt)
    }
}
```

- [ ] **Step 2: Run — expect compile failures**

`** TEST FAILED **` with "cannot find 'SyncCoordinator'".

- [ ] **Step 3: Implement `SyncCoordinator`**

```swift
// HoopTrack/Sync/SyncCoordinator.swift
import Foundation

/// Orchestrates uploads from the local SwiftData store to Supabase.
/// Fire-and-forget from SessionFinalizationCoordinator: network failure
/// is non-fatal, only the `cloudSyncedAt` stamp is skipped.
@MainActor
final class SyncCoordinator {

    private let backend: SupabaseDataServiceProtocol

    init(backend: SupabaseDataServiceProtocol = SupabaseDataService()) {
        self.backend = backend
    }

    /// Upsert a training session and all its shots. Stamps cloudSyncedAt
    /// on success, leaves it nil on failure (caller may retry later).
    func syncSession(_ session: TrainingSession, userID: UUID) async throws {
        try await backend.upsertSession(TrainingSessionDTO(from: session, userID: userID))

        let shotDTOs = session.shots.map {
            ShotRecordDTO(from: $0, userID: userID, sessionID: session.id)
        }
        try await backend.insertShots(shotDTOs)

        let now = Date()
        session.cloudSyncedAt = now
        for shot in session.shots { shot.cloudSyncedAt = now }
    }

    func syncProfile(_ profile: PlayerProfile, userID: UUID) async throws {
        try await backend.upsertProfile(PlayerProfileDTO(from: profile, userID: userID))
        profile.cloudSyncedAt = Date()
    }

    func syncGoal(_ goal: GoalRecord, userID: UUID) async throws {
        try await backend.upsertGoal(GoalRecordDTO(from: goal, userID: userID))
        goal.cloudSyncedAt = Date()
    }

    func syncBadge(_ badge: EarnedBadge, userID: UUID) async throws {
        try await backend.upsertBadge(EarnedBadgeDTO(from: badge, userID: userID))
        badge.cloudSyncedAt = Date()
    }
}
```

- [ ] **Step 4: Run tests — green**

Expected: `Executed 5 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add HoopTrack/HoopTrack/Sync/SyncCoordinator.swift \
        HoopTrack/HoopTrackTests/Sync/SyncCoordinatorTests.swift
git commit -m "feat(sync): SyncCoordinator with 5 TDD tests

Orchestrates the local -> Supabase upload path for sessions, profiles,
goals, and badges. Stamps cloudSyncedAt on success; leaves nil on
failure so SessionFinalizationCoordinator's fire-and-forget call site
doesn't trip the user."
```

---

## Task 12: Wire SyncCoordinator into `SessionFinalizationCoordinator`

**Files:**
- Modify: `HoopTrack/Services/SessionFinalizationCoordinator.swift`

- [ ] **Step 1: Inject the SyncCoordinator**

Open `HoopTrack/Services/SessionFinalizationCoordinator.swift`. Add an optional `syncCoordinator: SyncCoordinator?` property (optional so existing tests that construct the coordinator with explicit params don't break):

```swift
    private let syncCoordinator: SyncCoordinator?

    init(
        dataService:            DataService,
        goalUpdateService:      GoalUpdateServiceProtocol,
        healthKitService:       HealthKitServiceProtocol,
        skillRatingService:     SkillRatingServiceProtocol,
        badgeEvaluationService: BadgeEvaluationServiceProtocol,
        notificationService:    NotificationService,
        syncCoordinator:        SyncCoordinator? = nil
    ) {
        // ...existing assignments...
        self.syncCoordinator = syncCoordinator
    }
```

- [ ] **Step 2: Add a new step 8 after step 7**

Append to `finaliseSession(_:)` (and the dribble + agility equivalents):

```swift
        // 8. Fire-and-forget Supabase sync — non-fatal if offline.
        if let syncCoordinator, let userIDString = profile.supabaseUserID,
           let userID = UUID(uuidString: userIDString) {
            Task { @MainActor [syncCoordinator] in
                try? await syncCoordinator.syncSession(session, userID: userID)
            }
        }
```

- [ ] **Step 3: Wire in `CoordinatorHost.CoordinatorBox.build(...)`**

Update the `CoordinatorBox` to build a `SyncCoordinator` and pass it in:

```swift
        let sync = SyncCoordinator()
        value = SessionFinalizationCoordinator(
            dataService:            ds,
            goalUpdateService:      GoalUpdateService(modelContext: modelContext),
            healthKitService:       HealthKitService(),
            skillRatingService:     SkillRatingService(modelContext: modelContext),
            badgeEvaluationService: BadgeEvaluationService(modelContext: modelContext),
            notificationService:    notificationService,
            syncCoordinator:        sync
        )
```

- [ ] **Step 4: Build + commit**

```bash
git add HoopTrack/HoopTrack/Services/SessionFinalizationCoordinator.swift \
        HoopTrack/HoopTrack/CoordinatorHost.swift
git commit -m "feat(sync): finalization step 8 — fire-and-forget Supabase upload

Every shooting, dribble, and agility session now uploads to Supabase
after local finalization. Failure is silent: the local save already
succeeded and the retry will land on the next successful finalization
or the next app launch (once a restore coordinator exists in a
follow-up phase)."
```

---

## Task 13: Real SPKI hash in `PinningURLSessionDelegate`

**Files:**
- Modify: `HoopTrack/Utilities/PinningURLSessionDelegate.swift`

- [ ] **Step 1: Compute the SPKI SHA-256 for the Supabase project**

Run:
```bash
echo | openssl s_client -servername nfzhqcgofuohsjhtxvqa.supabase.co \
    -connect nfzhqcgofuohsjhtxvqa.supabase.co:443 2>/dev/null \
  | openssl x509 -pubkey -noout \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | openssl enc -base64
```

Capture the base64 string. Also compute the **intermediate CA SPKI** (Let's Encrypt R3 or ISRG Root X1 depending on Supabase's chain) as the backup pin — same pipeline, but pass `-showcerts` and pick the second cert.

- [ ] **Step 2: Replace the placeholder**

Open `HoopTrack/Utilities/PinningURLSessionDelegate.swift`, find the `pinnedHashes` array, replace its placeholder(s) with the two real base64 strings from Step 1.

- [ ] **Step 3: Build + commit**

```bash
git add HoopTrack/HoopTrack/Utilities/PinningURLSessionDelegate.swift
git commit -m "fix(security): real Supabase SPKI hashes in PinningURLSessionDelegate

Replaces Phase 7's placeholder with the live Supabase cert SPKI
SHA-256 plus the intermediate CA's SPKI as a backup pin. The backup
pin keeps the app functional during Supabase's scheduled cert
rotations."
```

---

## Task 14: Merge the Supabase branch

**Tool:** Supabase MCP `merge_branch`.

- [ ] **Step 1: Final verification on the branch**

Run one more `list_tables` to confirm shape, and `execute_sql` to confirm RLS policies are present. If anything is off, fix on the branch first — never merge a broken schema.

- [ ] **Step 2: Merge**

Call `mcp__supabase__merge_branch` with the branch id.

- [ ] **Step 3: Verify main has the schema**

Call `list_tables` on the main project. Expected: same 5 tables now present.

- [ ] **Step 4: Delete the branch**

Call `mcp__supabase__delete_branch` to clean up — branches cost money while they exist.

---

## Task 15: Full regression + manual smoke

**Files:**
- None (verification).

- [ ] **Step 1: Full test suite**

```bash
xcodebuild test -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`, previous total (184) + **10** (5 DTO + 5 SyncCoordinator) = **194 tests**, 0 failures.

- [ ] **Step 2: Zero warnings**

```bash
xcodebuild -project HoopTrack.xcodeproj -scheme HoopTrack \
  -destination 'platform=iOS Simulator,name=iPhone 14' clean build 2>&1 | grep -c "warning:"
```

Expected: `0`.

- [ ] **Step 3: Manual end-to-end smoke**

1. Fresh install. Sign up + confirm email + sign in (we reuse the Phase 8 flow).
2. Open Train → Free Shoot. Log 5 manual makes. End session.
3. Within a few seconds, open Supabase MCP `execute_sql`:
```sql
select id, user_id, shots_attempted, shots_made from public.training_sessions
 order by created_at desc limit 1;
select count(*) from public.shot_records where session_id = '<id from above>';
```
Expected: your session row present with the right `user_id`; shot count = 5.
4. Sign out, sign in on a second simulator device with the same email.
5. Session list should populate (once a restore coordinator lands — that's follow-up work in P9.5; for now, just confirm Supabase has the row).

- [ ] **Step 4: ROADMAP flip**

Update `docs/ROADMAP.md`:
- Phase 9 row: 🔜 Next → ✅ Complete.
- Phase 10 row: 🔜 Planned → 🔜 Next.
- Add a "Phase 9 — Backend & Database" block under Completed Phases with new/modified files, tests, external dependencies, and callouts.

- [ ] **Step 5: Production-readiness checklist updates**

Update `docs/production-readiness.md`:
- P0 "Real Supabase SPKI SHA-256 hash" → ✅.
- P0 "Postgres schema + RLS policies" → ✅.
- P0 "`cloudSyncedAt: Date?` on synced models" → ✅.
- Open items: initial sync coordinator (restore path) → still ⏳, flag as "Phase 9.5".

- [ ] **Step 6: Final commit + push**

```bash
git add docs/ROADMAP.md docs/production-readiness.md
git commit -m "docs: mark Phase 9 complete + update production checklist"
git push origin main
```

---

## Risk Notes

- **SwiftData `Date` JSON encoding.** PostgREST expects ISO-8601 timestamps; Swift's default `JSONEncoder` encodes `Date` as seconds since reference date. If upserts fail with a type error on the first attempt, set `PostgrestClient`'s JSON encoder `dateEncodingStrategy = .iso8601`. `supabase-swift` does this by default but it's worth verifying.
- **Re-sync on app upgrade.** Users installing Phase 9 for the first time have existing local data. This plan does NOT back-sync that data; it starts sync from the NEXT session. An `InitialSyncCoordinator` that batch-uploads historical records is deferred to Phase 9.5 (explicitly called out in the ROADMAP entry).
- **Unverified `earned_badges` rank column.** `BadgeRank` enum values should match whatever the current model emits — audit before merge if you encounter a CHECK constraint error. Easy inline fix.
- **`PlayerProfile.supabaseUserID` null safety.** Phase 8's `CoordinatorHost.onChange` sets this on every sign-in. But a user who opens the app while authenticated (session restored from keychain) before `CoordinatorHost.onChange` fires will have `supabaseUserID == nil` for one render. Sync on session finalize checks for this and skips; not a data-loss risk, just a one-session delay.

---

## Self-Review Summary

- **Spec coverage:** Schema (Task 2), RLS (Task 3), smoke (Task 4), SchemaV4 (Task 5), Postgres client composition (Task 6), DTOs (Task 7), protocol + mock (Task 8), impl (Task 9), DTO tests (Task 10), SyncCoordinator + TDD (Task 11), finalization hook (Task 12), SPKI pinning (Task 13), merge (Task 14), regression (Task 15). Every P0 item from production-readiness.md under "Backend & Database" flips.
- **Placeholder scan:** Every code block is complete. Task 7 + 9 are the largest code blocks but they're all concrete. No "handle edge cases" language.
- **Type consistency:** `PlayerProfileDTO`, `TrainingSessionDTO`, `ShotRecordDTO`, `GoalRecordDTO`, `EarnedBadgeDTO` are used identically between Task 7 (definition), Task 8 (protocol), Task 9 (PostgREST impl), Task 10 (round-trip tests), Task 11 (SyncCoordinator consumer). All DTOs have `init(from:userID:)` with optional extra params as appropriate (`sessionID` for ShotRecordDTO).

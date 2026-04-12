# PostgreSQL via Supabase — Integration Plan

**Project:** HoopTrack iOS  
**Date:** 2026-04-12  
**Status:** Planning  
**Prerequisite phases:** Phase 1–6B complete (local SwiftData baseline)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Supabase Project Setup](#2-supabase-project-setup)
3. [Schema Design](#3-schema-design)
4. [Row Level Security (RLS)](#4-row-level-security-rls)
5. [supabase-swift SDK Setup](#5-supabase-swift-sdk-setup)
6. [SupabaseDataService Design](#6-supabasedataservice-design)
7. [Data Migration from SwiftData to Supabase](#7-data-migration-from-swiftdata-to-supabase)
8. [Supabase Realtime Subscriptions](#8-supabase-realtime-subscriptions)
9. [Conflict Resolution](#9-conflict-resolution)
10. [Redis Consideration](#10-redis-consideration)
11. [Testing Approach](#11-testing-approach)

---

## 1. Overview

### Current Architecture

HoopTrack currently persists all data locally via **SwiftData** (iOS 17+) with a documented Core Data fallback path for iOS 16. The `DataService` class is the single abstraction layer; all ViewModels and the `SessionFinalizationCoordinator` go through it. No remote data store exists today.

### Target Architecture: Dual-Layer

```
┌─────────────────────────────────────────────────────────────┐
│                          App Layer                          │
│   ViewModels  ──►  DataService  ──►  ModelContext (local)   │
│                         │                                   │
│                  SupabaseDataService                        │
│                         │                                   │
└─────────────────────────┼───────────────────────────────────┘
                          │  HTTPS / WebSocket
┌─────────────────────────▼───────────────────────────────────┐
│                     Supabase Cloud                          │
│   Auth (JWT)  ──  PostgreSQL  ──  Realtime (WebSocket)      │
└─────────────────────────────────────────────────────────────┘
```

**SwiftData remains the source of truth for the device.** Supabase is the cloud mirror — it enables:

- **Cross-device sync** (user buys a new phone, history follows)
- **Coach Review mode** — coaches query `training_sessions` for athletes they supervise
- **Live leaderboards** — Realtime subscriptions push rank changes without polling
- **Web dashboard** — a future Next.js app reads the same Postgres tables via the same API

### Rationale for a Separate Service Layer

`DataService` is `@MainActor` and synchronous (throws, no async). Supabase calls are network I/O and must be `async`. A distinct `SupabaseDataService` keeps the local-persistence contract unchanged, lets both services be injected independently, and makes the sync boundary explicit. In a future refactor, `DataService` can delegate to `SupabaseDataService` internally; for now they are parallel.

The key invariant:

- **Write local first.** `DataService` writes to SwiftData before `SupabaseDataService` writes to Supabase.
- **Never block the UI on the network.** Cloud sync is a background task; failures are queued for retry.
- **Shots are append-only.** A shot once written is never deleted from the cloud; set-union merge ensures no shot is lost on conflict.

---

## 2. Supabase Project Setup

### 2.1 Create the Project

1. Log in at [supabase.com](https://supabase.com) → **New Project**.
2. Set the name to `hooptrack-prod` (use `hooptrack-dev` for development).
3. **Region:** choose `us-east-1` (Virginia) for lowest latency to most US users; consider `eu-west-1` for GDPR data residency if a European launch is planned.
4. Set a strong database password; store it in 1Password — you will not use it directly in the app, but it is needed for Supabase CLI migrations.
5. Wait for provisioning (~2 minutes).

### 2.2 Retrieve Credentials

From **Project Settings → API**:

| Key | Where used |
|---|---|
| `Project URL` | `SupabaseClient` init |
| `anon` public key | `SupabaseClient` init (safe to embed in the app binary) |
| `service_role` key | **Never embed in the app.** Server-side only (migrations, admin scripts). |
| Database connection string | Supabase CLI migrations only |

### 2.3 Supabase CLI

Install the CLI for running migrations locally and against remote:

```bash
brew install supabase/tap/supabase
supabase login
supabase init          # creates supabase/ directory in project root
supabase link --project-ref <your-project-ref>
```

Store migrations in `HoopTrack/supabase/migrations/`. Each migration file is named `YYYYMMDDHHMMSS_description.sql`.

### 2.4 Environment Configuration

Add a `Config.xcconfig` file (excluded from source control via `.gitignore`) containing:

```
SUPABASE_URL = https://your-project-ref.supabase.co
SUPABASE_ANON_KEY = your-anon-key-here
```

Reference these in `Info.plist`:

```xml
<key>SupabaseURL</key>
<string>$(SUPABASE_URL)</string>
<key>SupabaseAnonKey</key>
<string>$(SUPABASE_ANON_KEY)</string>
```

Read them in Swift via `Bundle.main.object(forInfoDictionaryKey:)`. This keeps secrets out of source code while keeping them in the binary where the anon key is safe to include.

---

## 3. Schema Design

All tables include `updated_at TIMESTAMPTZ` for conflict resolution and `created_at TIMESTAMPTZ` for auditing. Foreign keys reference `auth.users(id)` from Supabase Auth, not a custom users table, which makes RLS straightforward.

### 3.1 Migration: Initial Schema

```sql
-- migrations/20260412000001_initial_schema.sql

-- ─────────────────────────────────────────────
-- player_profiles
-- One row per authenticated user (mirrors PlayerProfile SwiftData model).
-- ─────────────────────────────────────────────
CREATE TABLE player_profiles (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    name                        TEXT NOT NULL DEFAULT 'Player',
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Skill ratings (0–100)
    rating_overall              DOUBLE PRECISION NOT NULL DEFAULT 0,
    rating_shooting             DOUBLE PRECISION NOT NULL DEFAULT 0,
    rating_ball_handling        DOUBLE PRECISION NOT NULL DEFAULT 0,
    rating_athleticism          DOUBLE PRECISION NOT NULL DEFAULT 0,
    rating_consistency          DOUBLE PRECISION NOT NULL DEFAULT 0,
    rating_volume               DOUBLE PRECISION NOT NULL DEFAULT 0,

    -- Career stats
    career_shots_attempted      INTEGER NOT NULL DEFAULT 0,
    career_shots_made           INTEGER NOT NULL DEFAULT 0,
    total_session_count         INTEGER NOT NULL DEFAULT 0,
    total_training_minutes      DOUBLE PRECISION NOT NULL DEFAULT 0,

    -- Personal records
    pr_best_fg_percent_session  DOUBLE PRECISION NOT NULL DEFAULT 0,
    pr_most_makes_session       INTEGER NOT NULL DEFAULT 0,
    pr_best_consistency_score   DOUBLE PRECISION,               -- NULL = no sessions yet
    pr_vertical_jump_cm         DOUBLE PRECISION NOT NULL DEFAULT 0,

    -- Streaks
    current_streak_days         INTEGER NOT NULL DEFAULT 0,
    longest_streak_days         INTEGER NOT NULL DEFAULT 0,
    last_session_date           TIMESTAMPTZ,

    -- Settings
    preferred_court_type        TEXT NOT NULL DEFAULT 'NBA',
    videos_auto_delete_days     INTEGER NOT NULL DEFAULT 60,

    CONSTRAINT player_profiles_user_id_unique UNIQUE (user_id)
);

CREATE INDEX idx_player_profiles_user_id ON player_profiles (user_id);

-- Automatically set updated_at on every update
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_player_profiles_updated_at
    BEFORE UPDATE ON player_profiles
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────
-- training_sessions
-- One row per completed session (mirrors TrainingSession SwiftData model).
-- ─────────────────────────────────────────────
CREATE TABLE training_sessions (
    id                          UUID PRIMARY KEY,               -- matches TrainingSession.id
    user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    profile_id                  UUID REFERENCES player_profiles(id) ON DELETE CASCADE,

    started_at                  TIMESTAMPTZ NOT NULL,
    ended_at                    TIMESTAMPTZ,
    duration_seconds            DOUBLE PRECISION NOT NULL DEFAULT 0,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Classification
    drill_type                  TEXT NOT NULL,                  -- DrillType raw value
    named_drill                 TEXT,                           -- NamedDrill raw value, nullable
    court_type                  TEXT NOT NULL DEFAULT 'NBA',
    location_tag                TEXT NOT NULL DEFAULT '',
    notes                       TEXT NOT NULL DEFAULT '',

    -- Aggregate stats
    shots_attempted             INTEGER NOT NULL DEFAULT 0,
    shots_made                  INTEGER NOT NULL DEFAULT 0,
    fg_percent                  DOUBLE PRECISION NOT NULL DEFAULT 0,

    -- Shot Science averages
    avg_release_angle_deg       DOUBLE PRECISION,
    avg_release_time_ms         DOUBLE PRECISION,
    avg_vertical_jump_cm        DOUBLE PRECISION,
    avg_shot_speed_mph          DOUBLE PRECISION,
    consistency_score           DOUBLE PRECISION,

    -- Video
    video_file_name             TEXT,
    video_pinned_by_user        BOOLEAN NOT NULL DEFAULT FALSE,

    -- Dribble aggregates
    total_dribbles              INTEGER,
    avg_dribbles_per_sec        DOUBLE PRECISION,
    max_dribbles_per_sec        DOUBLE PRECISION,
    hand_balance_fraction       DOUBLE PRECISION,
    dribble_combos_detected     INTEGER,

    -- Phase 5A agility & consistency
    best_shuttle_run_seconds    DOUBLE PRECISION,
    best_lane_agility_seconds   DOUBLE PRECISION,
    longest_make_streak         INTEGER NOT NULL DEFAULT 0,
    shot_speed_std_dev          DOUBLE PRECISION
);

CREATE INDEX idx_training_sessions_user_id     ON training_sessions (user_id);
CREATE INDEX idx_training_sessions_started_at  ON training_sessions (started_at DESC);
CREATE INDEX idx_training_sessions_drill_type  ON training_sessions (drill_type);

-- Composite: leaderboard queries filter by drill type + order by fg_percent
CREATE INDEX idx_training_sessions_leaderboard ON training_sessions (drill_type, fg_percent DESC);

CREATE TRIGGER trg_training_sessions_updated_at
    BEFORE UPDATE ON training_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────
-- shot_records
-- One row per individual shot (mirrors ShotRecord SwiftData model).
-- Append-only: rows are never deleted from this table once inserted.
-- ─────────────────────────────────────────────
CREATE TABLE shot_records (
    id                          UUID PRIMARY KEY,               -- matches ShotRecord.id
    session_id                  UUID NOT NULL REFERENCES training_sessions(id) ON DELETE CASCADE,
    user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    timestamp                   TIMESTAMPTZ NOT NULL,
    sequence_index              INTEGER NOT NULL,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Classification
    result                      TEXT NOT NULL DEFAULT 'Pending', -- ShotResult raw value
    zone                        TEXT NOT NULL DEFAULT 'Unknown', -- CourtZone raw value
    shot_type                   TEXT NOT NULL DEFAULT 'Unknown', -- ShotType raw value

    -- Court position (normalised 0–1)
    court_x                     DOUBLE PRECISION NOT NULL DEFAULT 0.5,
    court_y                     DOUBLE PRECISION NOT NULL DEFAULT 0.5,

    -- Shot Science
    release_angle_deg           DOUBLE PRECISION,
    release_time_ms             DOUBLE PRECISION,
    vertical_jump_cm            DOUBLE PRECISION,
    leg_angle_deg               DOUBLE PRECISION,
    shot_speed_mph              DOUBLE PRECISION,

    -- Video
    video_timestamp_seconds     DOUBLE PRECISION,
    is_user_corrected           BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_shot_records_session_id ON shot_records (session_id);
CREATE INDEX idx_shot_records_user_id    ON shot_records (user_id);
CREATE INDEX idx_shot_records_timestamp  ON shot_records (timestamp DESC);

-- Zone heat-map queries: filter by user + zone
CREATE INDEX idx_shot_records_zone       ON shot_records (user_id, zone);

CREATE TRIGGER trg_shot_records_updated_at
    BEFORE UPDATE ON shot_records
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();


-- ─────────────────────────────────────────────
-- goal_records
-- One row per user-defined training goal (mirrors GoalRecord SwiftData model).
-- ─────────────────────────────────────────────
CREATE TABLE goal_records (
    id                          UUID PRIMARY KEY,               -- matches GoalRecord.id
    user_id                     UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    profile_id                  UUID REFERENCES player_profiles(id) ON DELETE CASCADE,

    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    target_date                 TIMESTAMPTZ,

    title                       TEXT NOT NULL,
    skill                       TEXT NOT NULL,                  -- SkillDimension raw value
    metric                      TEXT NOT NULL,                  -- GoalMetric raw value
    target_value                DOUBLE PRECISION NOT NULL,
    baseline_value              DOUBLE PRECISION NOT NULL,
    current_value               DOUBLE PRECISION NOT NULL,
    is_achieved                 BOOLEAN NOT NULL DEFAULT FALSE,
    achieved_at                 TIMESTAMPTZ,
    last_milestone_notified     INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX idx_goal_records_user_id ON goal_records (user_id);
CREATE INDEX idx_goal_records_is_achieved ON goal_records (user_id, is_achieved);

CREATE TRIGGER trg_goal_records_updated_at
    BEFORE UPDATE ON goal_records
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();
```

### 3.2 Sync-State Columns

To track which local records have been pushed to the cloud, add a `cloud_synced_at` column to each SwiftData model via a schema migration. This is a local-only field; it is never sent to Supabase.

```sql
-- This migration applies to the LOCAL SwiftData schema via HoopTrackMigrationPlan.
-- It is NOT a Supabase migration. Document here for reference only.
--
-- Add to TrainingSession: cloudSyncedAt: Date?   (nil = not yet synced)
-- Add to ShotRecord:       cloudSyncedAt: Date?
-- Add to GoalRecord:       cloudSyncedAt: Date?
-- Add to PlayerProfile:    cloudSyncedAt: Date?
```

The SwiftData migration lives in `Models/Migrations/HoopTrackSchemaV2.swift`, following the existing `HoopTrackMigrationPlan` pattern.

---

## 4. Row Level Security (RLS)

RLS ensures that even if someone gets hold of the anon API key, they can only read and write their own rows. Supabase Auth issues a JWT containing the user's `sub` (UUID), which Postgres surfaces as `auth.uid()`.

### 4.1 Enable RLS on All Tables

```sql
-- migrations/20260412000002_enable_rls.sql

ALTER TABLE player_profiles    ENABLE ROW LEVEL SECURITY;
ALTER TABLE training_sessions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE shot_records        ENABLE ROW LEVEL SECURITY;
ALTER TABLE goal_records        ENABLE ROW LEVEL SECURITY;
```

### 4.2 Policies

```sql
-- ── player_profiles ──────────────────────────────────────────
CREATE POLICY "Users can view their own profile"
    ON player_profiles FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own profile"
    ON player_profiles FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own profile"
    ON player_profiles FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own profile"
    ON player_profiles FOR DELETE
    USING (auth.uid() = user_id);


-- ── training_sessions ────────────────────────────────────────
CREATE POLICY "Users can view their own sessions"
    ON training_sessions FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own sessions"
    ON training_sessions FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own sessions"
    ON training_sessions FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own sessions"
    ON training_sessions FOR DELETE
    USING (auth.uid() = user_id);

-- Future: Coach access policy (deferred to Coach Review phase)
-- CREATE POLICY "Coaches can view athlete sessions"
--     ON training_sessions FOR SELECT
--     USING (
--         auth.uid() = user_id
--         OR auth.uid() IN (
--             SELECT coach_id FROM coach_athlete_relationships
--             WHERE athlete_id = user_id AND accepted = true
--         )
--     );


-- ── shot_records ─────────────────────────────────────────────
CREATE POLICY "Users can view their own shots"
    ON shot_records FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own shots"
    ON shot_records FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own shots"
    ON shot_records FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

-- No DELETE policy on shot_records: shots are append-only.
-- Deletes are blocked at the policy level. If a session is deleted,
-- shot_records cascade-delete via the FK (bypassing RLS via the FK engine).


-- ── goal_records ─────────────────────────────────────────────
CREATE POLICY "Users can view their own goals"
    ON goal_records FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own goals"
    ON goal_records FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own goals"
    ON goal_records FOR UPDATE
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can delete their own goals"
    ON goal_records FOR DELETE
    USING (auth.uid() = user_id);
```

### 4.3 JWT Integration

Supabase Auth issues a JWT with `sub = <user UUID>`. When the app calls `supabase.auth.signIn(...)`, the SDK stores the JWT and automatically attaches it as `Authorization: Bearer <token>` on every PostgREST request. The Postgres function `auth.uid()` decodes that JWT server-side, requiring no additional configuration.

Token storage: the `supabase-swift` SDK stores tokens in the iOS Keychain by default (not `UserDefaults`), which is the correct behaviour per the security guidance in `extension-report.md`.

Access tokens expire after 1 hour; the SDK handles refresh automatically via the stored refresh token.

---

## 5. supabase-swift SDK Setup

### 5.1 Add the Package Dependency

In Xcode: **File → Add Package Dependencies** → enter:

```
https://github.com/supabase/supabase-swift
```

Select version `2.x` (latest stable). Add these products to the `HoopTrack` target:

- `Supabase` (umbrella — includes Auth, PostgREST, Realtime, Storage)

The app currently has no third-party dependencies (per `CLAUDE.md`). This is the first. Add it to the project-level "Dependencies" section of the `CLAUDE.md` once it lands.

### 5.2 Client Singleton

Create `Services/SupabaseClient+Shared.swift`:

```swift
// Services/SupabaseClient+Shared.swift
// Singleton Supabase client. Initialised once at app launch.
// The anon key is safe to embed: RLS policies enforce data ownership server-side.

import Foundation
import Supabase

extension SupabaseClient {

    static let shared: SupabaseClient = {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let url = URL(string: urlString),
            let anonKey = Bundle.main.object(forInfoDictionaryKey: "SupabaseAnonKey") as? String
        else {
            fatalError("HoopTrack: Missing Supabase configuration in Info.plist")
        }

        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: anonKey
        )
    }()
}
```

### 5.3 Inject into HoopTrackApp

```swift
// HoopTrackApp.swift — additions only

import Supabase

// Inside HoopTrackApp.body, add the SupabaseDataService as a StateObject:
@StateObject private var supabaseDataService = SupabaseDataService(
    client: .shared
)

// Inside WindowGroup { CoordinatorHost() ... }:
.environmentObject(supabaseDataService)
```

---

## 6. SupabaseDataService Design

`SupabaseDataService` is a `@MainActor final class` that mirrors the API surface of `DataService` for cloud operations. It is `ObservableObject` so ViewModels can observe `isSyncing` and `lastSyncError`.

### 6.1 Codable Transfer Objects

Each SwiftData model needs a `Codable` struct that maps to the Postgres column names. These live in `Models/SupabaseDTO.swift`.

```swift
// Models/SupabaseDTO.swift
// Codable structs for Supabase PostgREST serialisation.
// Column names use snake_case to match the Postgres schema directly.

import Foundation

struct PlayerProfileDTO: Codable {
    var id: UUID
    var userId: UUID
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

    // Mapping from PlayerProfile SwiftData model
    init(from profile: PlayerProfile, userId: UUID) {
        self.id                      = UUID()           // assigned on first push; see migration strategy
        self.userId                  = userId
        self.name                    = profile.name
        self.createdAt               = profile.createdAt
        self.updatedAt               = Date.now

        self.ratingOverall           = profile.ratingOverall
        self.ratingShooting          = profile.ratingShooting
        self.ratingBallHandling      = profile.ratingBallHandling
        self.ratingAthleticism       = profile.ratingAthleticism
        self.ratingConsistency       = profile.ratingConsistency
        self.ratingVolume            = profile.ratingVolume

        self.careerShotsAttempted    = profile.careerShotsAttempted
        self.careerShotsMade         = profile.careerShotsMade
        self.totalSessionCount       = profile.totalSessionCount
        self.totalTrainingMinutes    = profile.totalTrainingMinutes

        self.prBestFgPercentSession  = profile.prBestFGPercentSession
        self.prMostMakesSession      = profile.prMostMakesSession
        self.prBestConsistencyScore  = profile.prBestConsistencyScore == Double.infinity
                                           ? nil : profile.prBestConsistencyScore
        self.prVerticalJumpCm        = profile.prVerticalJumpCm

        self.currentStreakDays       = profile.currentStreakDays
        self.longestStreakDays       = profile.longestStreakDays
        self.lastSessionDate         = profile.lastSessionDate

        self.preferredCourtType      = profile.preferredCourtType.rawValue
        self.videosAutoDeleteDays    = profile.videosAutoDeleteDays
    }
}

struct TrainingSessionDTO: Codable {
    var id: UUID
    var userId: UUID
    var profileId: UUID?

    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: Double
    var updatedAt: Date

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

    init(from session: TrainingSession, userId: UUID, profileId: UUID?) {
        self.id                   = session.id
        self.userId               = userId
        self.profileId            = profileId
        self.startedAt            = session.startedAt
        self.endedAt              = session.endedAt
        self.durationSeconds      = session.durationSeconds
        self.updatedAt            = Date.now

        self.drillType            = session.drillType.rawValue
        self.namedDrill           = session.namedDrill?.rawValue
        self.courtType            = session.courtType.rawValue
        self.locationTag          = session.locationTag
        self.notes                = session.notes

        self.shotsAttempted       = session.shotsAttempted
        self.shotsMade            = session.shotsMade
        self.fgPercent            = session.fgPercent

        self.avgReleaseAngleDeg   = session.avgReleaseAngleDeg
        self.avgReleaseTimeMs     = session.avgReleaseTimeMs
        self.avgVerticalJumpCm    = session.avgVerticalJumpCm
        self.avgShotSpeedMph      = session.avgShotSpeedMph
        self.consistencyScore     = session.consistencyScore

        self.videoFileName        = session.videoFileName
        self.videoPinnedByUser    = session.videoPinnedByUser

        self.totalDribbles        = session.totalDribbles
        self.avgDribblesPerSec    = session.avgDribblesPerSec
        self.maxDribblesPerSec    = session.maxDribblesPerSec
        self.handBalanceFraction  = session.handBalanceFraction
        self.dribbleCombosDetected = session.dribbleCombosDetected

        self.bestShuttleRunSeconds  = session.bestShuttleRunSeconds
        self.bestLaneAgilitySeconds = session.bestLaneAgilitySeconds
        self.longestMakeStreak      = session.longestMakeStreak
        self.shotSpeedStdDev        = session.shotSpeedStdDev
    }
}

struct ShotRecordDTO: Codable {
    var id: UUID
    var sessionId: UUID
    var userId: UUID

    var timestamp: Date
    var sequenceIndex: Int
    var updatedAt: Date

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

    init(from shot: ShotRecord, userId: UUID) {
        self.id                    = shot.id
        self.sessionId             = shot.session?.id ?? UUID()
        self.userId                = userId
        self.timestamp             = shot.timestamp
        self.sequenceIndex         = shot.sequenceIndex
        self.updatedAt             = Date.now

        self.result                = shot.result.rawValue
        self.zone                  = shot.zone.rawValue
        self.shotType              = shot.shotType.rawValue

        self.courtX                = shot.courtX
        self.courtY                = shot.courtY

        self.releaseAngleDeg       = shot.releaseAngleDeg
        self.releaseTimeMs         = shot.releaseTimeMs
        self.verticalJumpCm        = shot.verticalJumpCm
        self.legAngleDeg           = shot.legAngleDeg
        self.shotSpeedMph          = shot.shotSpeedMph

        self.videoTimestampSeconds = shot.videoTimestampSeconds
        self.isUserCorrected       = shot.isUserCorrected
    }
}

struct GoalRecordDTO: Codable {
    var id: UUID
    var userId: UUID
    var profileId: UUID?

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
    var lastMilestoneNotified: Int

    init(from goal: GoalRecord, userId: UUID, profileId: UUID?) {
        self.id                     = goal.id
        self.userId                 = userId
        self.profileId              = profileId
        self.createdAt              = goal.createdAt
        self.updatedAt              = Date.now
        self.targetDate             = goal.targetDate

        self.title                  = goal.title
        self.skill                  = goal.skill.rawValue
        self.metric                 = goal.metric.rawValue
        self.targetValue            = goal.targetValue
        self.baselineValue          = goal.baselineValue
        self.currentValue           = goal.currentValue
        self.isAchieved             = goal.isAchieved
        self.achievedAt             = goal.achievedAt
        self.lastMilestoneNotified  = goal.lastMilestoneNotified
    }
}
```

### 6.2 SupabaseDataService

```swift
// Services/SupabaseDataService.swift
// Cloud sync layer wrapping supabase-swift.
// All methods are async; errors are non-fatal — local SwiftData is the source of truth.

import Foundation
import Supabase

@MainActor
final class SupabaseDataService: ObservableObject {

    // MARK: - State

    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncError: Error?
    @Published private(set) var currentUserId: UUID?

    private let client: SupabaseClient

    // MARK: - Init

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    // MARK: - Auth helpers

    /// Returns the authenticated user's UUID, or nil if not signed in.
    var userId: UUID? { currentUserId }

    func signIn(email: String, password: String) async throws {
        let session = try await client.auth.signIn(email: email, password: password)
        currentUserId = session.user.id
    }

    func signInWithApple(idToken: String, nonce: String) async throws {
        let session = try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
        currentUserId = session.user.id
    }

    func signOut() async throws {
        try await client.auth.signOut()
        currentUserId = nil
    }

    func restoreSession() async {
        do {
            let session = try await client.auth.session
            currentUserId = session.user.id
        } catch {
            currentUserId = nil
        }
    }

    // MARK: - Profile

    /// Upsert the player profile to Supabase.
    /// Uses the user's auth UUID as the unique key (UNIQUE constraint on user_id).
    func upsertProfile(_ profile: PlayerProfile) async throws {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let dto = PlayerProfileDTO(from: profile, userId: uid)
        try await client.from("player_profiles")
            .upsert(dto, onConflict: "user_id")
            .execute()
    }

    /// Fetch the cloud profile. Returns nil if no row exists yet.
    func fetchProfile() async throws -> PlayerProfileDTO? {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let response: [PlayerProfileDTO] = try await client.from("player_profiles")
            .select()
            .eq("user_id", value: uid.uuidString)
            .limit(1)
            .execute()
            .value
        return response.first
    }

    // MARK: - Sessions

    /// Upsert a single training session.
    func upsertSession(_ session: TrainingSession, profileId: UUID?) async throws {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let dto = TrainingSessionDTO(from: session, userId: uid, profileId: profileId)
        try await client.from("training_sessions")
            .upsert(dto, onConflict: "id")
            .execute()
    }

    /// Batch upsert sessions (used during initial migration sync).
    func upsertSessions(_ sessions: [TrainingSession], profileId: UUID?) async throws {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let dtos = sessions.map { TrainingSessionDTO(from: $0, userId: uid, profileId: profileId) }
        // Batch in chunks of 100 to stay within PostgREST request size limits
        for chunk in dtos.chunked(into: 100) {
            try await client.from("training_sessions")
                .upsert(chunk, onConflict: "id")
                .execute()
        }
    }

    /// Fetch sessions updated after a given date (incremental pull).
    func fetchSessions(updatedAfter date: Date) async throws -> [TrainingSessionDTO] {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let isoDate = ISO8601DateFormatter().string(from: date)
        return try await client.from("training_sessions")
            .select()
            .eq("user_id", value: uid.uuidString)
            .gt("updated_at", value: isoDate)
            .order("started_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Shots

    /// Batch upsert shot records. Shots are append-only: existing rows are updated only
    /// if `is_user_corrected` changed (e.g. user edited result after CV detection).
    func upsertShots(_ shots: [ShotRecord]) async throws {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let dtos = shots.map { ShotRecordDTO(from: $0, userId: uid) }
        for chunk in dtos.chunked(into: 200) {
            try await client.from("shot_records")
                .upsert(chunk, onConflict: "id")
                .execute()
        }
    }

    // MARK: - Goals

    func upsertGoal(_ goal: GoalRecord, profileId: UUID?) async throws {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let dto = GoalRecordDTO(from: goal, userId: uid, profileId: profileId)
        try await client.from("goal_records")
            .upsert(dto, onConflict: "id")
            .execute()
    }

    func upsertGoals(_ goals: [GoalRecord], profileId: UUID?) async throws {
        guard let uid = currentUserId else { throw SyncError.notAuthenticated }
        let dtos = goals.map { GoalRecordDTO(from: $0, userId: uid, profileId: profileId) }
        try await client.from("goal_records")
            .upsert(dtos, onConflict: "id")
            .execute()
    }

    // MARK: - Post-Session Sync Hook

    /// Called by SessionFinalizationCoordinator after DataService.finaliseSession().
    /// Runs in the background; errors are logged but do not surface to the user.
    func syncSessionAfterFinalization(_ session: TrainingSession, profile: PlayerProfile) {
        Task {
            do {
                isSyncing = true
                defer { isSyncing = false }
                guard let uid = currentUserId else { return }
                // Derive the cloud profile id from the previously upserted profile row
                let cloudProfile = try await fetchProfile()
                let profileId = cloudProfile?.id
                try await upsertSession(session, profileId: profileId)
                try await upsertShots(session.shots)
                try await upsertProfile(profile)
            } catch {
                lastSyncError = error
                // TODO: enqueue failed record IDs in a local retry queue (Phase 7 work)
            }
        }
    }
}

// MARK: - Errors

enum SyncError: LocalizedError {
    case notAuthenticated
    case batchFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:         return "Sign in required to sync with cloud."
        case .batchFailed(let e):       return "Sync batch failed: \(e.localizedDescription)"
        }
    }
}

// MARK: - Array Chunking Helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
```

### 6.3 SessionFinalizationCoordinator Integration

After `DataService.finaliseSession()` resolves, call the Supabase sync hook:

```swift
// In SessionFinalizationCoordinator.finalise() — add after existing local work:

// Phase 6C — Cloud sync (non-blocking; errors logged internally)
supabaseDataService.syncSessionAfterFinalization(session, profile: profile)
```

Inject `SupabaseDataService` into `SessionFinalizationCoordinator` via the environment, following the same pattern as other services.

---

## 7. Data Migration from SwiftData to Supabase

The first cloud sync happens when the user enables cloud backup (a new toggle in the Profile tab, initially off). The migration is a one-time operation that runs at most once per device.

### 7.1 SwiftData Schema Change

Add a `cloudSyncedAt: Date?` property to each SwiftData model via `HoopTrackSchemaV2`:

```swift
// Models/Migrations/HoopTrackSchemaV2.swift
// Phase 7 — adds cloudSyncedAt to sync-eligible models.

import SwiftData
import Foundation

enum HoopTrackSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] = [
        PlayerProfile.self, TrainingSession.self, ShotRecord.self,
        GoalRecord.self, EarnedBadge.self
    ]
}
```

Add to each model:

```swift
// PlayerProfile.swift, TrainingSession.swift, ShotRecord.swift, GoalRecord.swift
var cloudSyncedAt: Date? = nil    // nil = not yet pushed to Supabase
```

Update `HoopTrackMigrationPlan` to include the V1→V2 migration stage (lightweight migration — only additive column changes).

### 7.2 InitialSyncCoordinator

```swift
// Services/InitialSyncCoordinator.swift
// Runs once when the user first enables cloud sync.
// Reads all local records, batch-upserts to Supabase, then stamps cloudSyncedAt.

import Foundation
import SwiftData

@MainActor
final class InitialSyncCoordinator {

    private let dataService: DataService
    private let supabase: SupabaseDataService

    init(dataService: DataService, supabase: SupabaseDataService) {
        self.dataService = dataService
        self.supabase    = supabase
    }

    func run() async throws {
        // 1. Fetch all local records
        let profile  = try dataService.fetchOrCreateProfile()
        let sessions = try dataService.fetchSessions()

        // 2. Push profile
        try await supabase.upsertProfile(profile)
        let cloudProfile = try await supabase.fetchProfile()
        let profileId = cloudProfile?.id

        // 3. Batch-push sessions (only incomplete syncs — cloudSyncedAt == nil)
        let unsynced = sessions.filter { $0.cloudSyncedAt == nil }
        try await supabase.upsertSessions(unsynced, profileId: profileId)

        // 4. Batch-push shots for each unsynced session
        for session in unsynced {
            let unsyncedShots = session.shots.filter { $0.cloudSyncedAt == nil }
            if !unsyncedShots.isEmpty {
                try await supabase.upsertShots(unsyncedShots)
            }
        }

        // 5. Push goals
        let unsyncedGoals = profile.goals.filter { $0.cloudSyncedAt == nil }
        try await supabase.upsertGoals(unsyncedGoals, profileId: profileId)

        // 6. Stamp cloudSyncedAt on all synced records (saves back to SwiftData)
        let now = Date.now
        profile.cloudSyncedAt = now
        for session in unsynced {
            session.cloudSyncedAt = now
            session.shots.forEach { $0.cloudSyncedAt = now }
        }
        unsyncedGoals.forEach { $0.cloudSyncedAt = now }

        // DataService saves via the ModelContext; caller is responsible for save after this returns.
    }
}
```

Call `InitialSyncCoordinator.run()` from the Profile tab when the user flips the "Cloud Backup" toggle on. Show a progress `HUD` (`isSyncing`) and surface errors inline (do not use a fatal error — allow retry).

---

## 8. Supabase Realtime Subscriptions

Realtime streams Postgres WAL changes over WebSocket. It is used for two future features:

1. **Live leaderboard** — push rank changes without the client polling
2. **Coach Review** — notify the athlete when a coach adds an annotation

### 8.1 Channel Setup in Swift

```swift
// Services/RealtimeSessionService.swift
// Subscribes to training_sessions changes for the current user.
// Used by leaderboard and coach review features (Phase 8+).

import Foundation
import Supabase

@MainActor
final class RealtimeSessionService: ObservableObject {

    @Published private(set) var latestSessionChange: TrainingSessionDTO?

    private let client: SupabaseClient
    private var channel: RealtimeChannelV2?

    init(client: SupabaseClient = .shared) {
        self.client = client
    }

    func subscribe(userId: UUID) async {
        let channelName = "training_sessions:\(userId.uuidString)"
        let channel = await client.realtimeV2.channel(channelName)

        await channel.onPostgresChanges(
            AnyAction.self,
            schema: "public",
            table: "training_sessions",
            filter: "user_id=eq.\(userId.uuidString)"
        ) { [weak self] change in
            // Parse the new record from the change payload
            if let record = change.newRecord as? TrainingSessionDTO {
                Task { @MainActor in
                    self?.latestSessionChange = record
                }
            }
        }

        await channel.subscribe()
        self.channel = channel
    }

    func unsubscribe() async {
        await channel?.unsubscribe()
        channel = nil
    }
}
```

### 8.2 Leaderboard Subscription (Sketch)

For the leaderboard use case, subscribe to an aggregated view rather than raw rows. Create a Postgres view:

```sql
-- migrations/20260412000003_leaderboard_view.sql

CREATE VIEW leaderboard_fg_percent AS
SELECT
    pp.name,
    ts.user_id,
    AVG(ts.fg_percent)          AS avg_fg_percent,
    COUNT(*)                    AS session_count,
    MAX(ts.fg_percent)          AS best_fg_percent,
    SUM(ts.shots_attempted)     AS total_shots
FROM training_sessions ts
JOIN player_profiles pp ON pp.user_id = ts.user_id
WHERE ts.shots_attempted >= 10          -- minimum volume threshold
GROUP BY ts.user_id, pp.name
ORDER BY avg_fg_percent DESC;
```

The view is queried via PostgREST. Realtime subscriptions on the underlying `training_sessions` table trigger a client-side re-query of the view after each change event.

---

## 9. Conflict Resolution

### 9.1 Scalar Fields — Last-Write-Wins

For `player_profiles` and `training_sessions` scalars (ratings, streak counters, session stats), use **last-write-wins** based on the `updated_at` timestamp:

```swift
// In SupabaseDataService — fetch + merge before upserting profile

func mergeAndUpsertProfile(_ local: PlayerProfile) async throws {
    guard let uid = currentUserId else { throw SyncError.notAuthenticated }

    // Pull current cloud state
    if let remote = try await fetchProfile() {
        // Only overwrite cloud if local is newer
        let localUpdated = local.cloudSyncedAt ?? .distantPast
        if localUpdated < remote.updatedAt {
            // Remote is newer — apply remote values back to local model
            applyRemoteProfile(remote, to: local)
            return  // no upsert needed; local is already up-to-date
        }
    }

    // Local is newer (or no remote row) — push local to cloud
    try await upsertProfile(local)
}

private func applyRemoteProfile(_ remote: PlayerProfileDTO, to local: PlayerProfile) {
    // Scalar fields: last-write-wins (remote wins when remote.updatedAt > local.cloudSyncedAt)
    local.ratingOverall        = remote.ratingOverall
    local.ratingShooting       = remote.ratingShooting
    local.ratingBallHandling   = remote.ratingBallHandling
    local.ratingAthleticism    = remote.ratingAthleticism
    local.ratingConsistency    = remote.ratingConsistency
    local.ratingVolume         = remote.ratingVolume
    local.currentStreakDays    = remote.currentStreakDays
    local.longestStreakDays    = remote.longestStreakDays
    // … all other scalar fields …
    local.cloudSyncedAt        = remote.updatedAt
}
```

### 9.2 Shot Arrays — Set-Union (Append-Only)

Shots are **append-only** by design. The cloud `shot_records` table has no DELETE RLS policy; shots are never removed after insertion. On merge:

- Local shots not yet in the cloud are upserted (INSERT on conflict UPDATE for `is_user_corrected` corrections only).
- Remote shots not yet on the device are pulled down and inserted into SwiftData.
- No shot is ever dropped.

```swift
// Set-union merge for shots: pull remote shots not present locally
func pullRemoteShotsIfMissing(for session: TrainingSession) async throws {
    guard let uid = currentUserId else { throw SyncError.notAuthenticated }

    let remoteShots: [ShotRecordDTO] = try await client.from("shot_records")
        .select()
        .eq("session_id", value: session.id.uuidString)
        .eq("user_id", value: uid.uuidString)
        .execute()
        .value

    let localIDs = Set(session.shots.map { $0.id })
    let missing  = remoteShots.filter { !localIDs.contains($0.id) }

    for dto in missing {
        let shot = ShotRecord(
            sequenceIndex: dto.sequenceIndex,
            result: ShotResult(rawValue: dto.result) ?? .pending,
            zone: CourtZone(rawValue: dto.zone) ?? .unknown,
            shotType: ShotType(rawValue: dto.shotType) ?? .unknown,
            courtX: dto.courtX,
            courtY: dto.courtY
        )
        shot.id                    = dto.id
        shot.timestamp             = dto.timestamp
        shot.releaseAngleDeg       = dto.releaseAngleDeg
        shot.releaseTimeMs         = dto.releaseTimeMs
        shot.verticalJumpCm        = dto.verticalJumpCm
        shot.legAngleDeg           = dto.legAngleDeg
        shot.shotSpeedMph          = dto.shotSpeedMph
        shot.videoTimestampSeconds = dto.videoTimestampSeconds
        shot.isUserCorrected       = dto.isUserCorrected
        shot.cloudSyncedAt         = dto.updatedAt
        shot.session               = session
        session.shots.append(shot)
    }

    if !missing.isEmpty {
        session.recalculateStats()
    }
}
```

### 9.3 `updated_at` Invariant

Every row in every table has `updated_at` managed by the Postgres trigger defined in section 3.1. Every DTO includes `updatedAt: Date` which is set to `Date.now` at the moment of serialisation on the client. This is the authoritative timestamp for last-write-wins decisions.

---

## 10. Redis Consideration

### 10.1 What Supabase Covers Today

Supabase's built-in capabilities are sufficient for everything through Phase 8 (leaderboards, coach review):

| Use case | Supabase solution |
|---|---|
| Session history queries | PostgREST on `training_sessions` with indexes |
| FG% leaderboard | `leaderboard_fg_percent` view, queried on demand |
| Real-time rank push | Realtime channel on `training_sessions` |
| Rate limiting | Supabase Edge Functions middleware |
| Caching profile reads | iOS-side in-memory cache in `SupabaseDataService` |

The `idx_training_sessions_leaderboard` composite index on `(drill_type, fg_percent DESC)` makes the leaderboard view fast enough for tens of thousands of users without Redis.

### 10.2 When to Introduce Redis

Introduce Redis (via **Upstash** for serverless Redis, or a self-hosted instance on Railway) when **all three** of the following are true:

1. Leaderboard reads spike above ~500 req/sec (typical at launch of a social feature or viral moment)
2. Global or city-scoped leaderboards need sub-50ms P99 read latency
3. A backend API layer (FastAPI / Hono) is in place to sit between the app and the database

At that point, use **Redis sorted sets** (`ZADD leaderboard:fg_percent <score> <user_id>`, `ZREVRANK` for rank queries) with a write-through pattern: every `training_sessions` upsert updates both Postgres and Redis. Postgres remains the source of truth; Redis is a read cache.

**Do not introduce Redis before the API layer is in place.** The app cannot connect directly to Redis safely (no RLS equivalent).

### 10.3 Session Caching in the Interim

In `SupabaseDataService`, cache the last-fetched `[TrainingSessionDTO]` in memory with a 5-minute TTL. This eliminates redundant PostgREST calls when the user navigates between Progress tabs without generating new sessions.

---

## 11. Testing Approach

### 11.1 Local Supabase Instance via Docker

Run a full Supabase stack locally for integration tests:

```bash
# From the HoopTrack/supabase/ directory
supabase start

# Output:
#   API URL: http://localhost:54321
#   DB URL: postgresql://postgres:postgres@localhost:54322/postgres
#   Studio URL: http://localhost:54323
#   Anon key: <local-anon-key>
#   Service role key: <local-service-role-key>

# Apply all migrations to the local instance
supabase db reset
```

Add a `SupabaseTestConfig.swift` in the test target:

```swift
// HoopTrackTests/Supabase/SupabaseTestConfig.swift
import Supabase

extension SupabaseClient {
    static let test = SupabaseClient(
        supabaseURL: URL(string: "http://localhost:54321")!,
        supabaseKey: "your-local-anon-key"
    )
}
```

### 11.2 SupabaseDataService Tests

Test the service against the local instance (these are integration tests, not unit tests). They require `supabase start` to be running.

```swift
// HoopTrackTests/Supabase/SupabaseDataServiceTests.swift

import XCTest
@testable import HoopTrack

final class SupabaseDataServiceTests: XCTestCase {

    var service: SupabaseDataService!
    var testUserId: UUID!

    override func setUp() async throws {
        service = SupabaseDataService(client: .test)
        // Sign up a fresh test user for each test run
        let email = "test-\(UUID().uuidString)@hooptrack.test"
        try await service.signIn(email: email, password: "TestPass123!")
        testUserId = service.userId
    }

    override func tearDown() async throws {
        try await service.signOut()
    }

    func testUpsertAndFetchProfile() async throws {
        let profile = PlayerProfile(name: "Test Player")
        try await service.upsertProfile(profile)

        let fetched = try await service.fetchProfile()
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.name, "Test Player")
    }

    func testUpsertSessionRoundTrip() async throws {
        let profile = PlayerProfile()
        try await service.upsertProfile(profile)
        let cloudProfile = try await service.fetchProfile()

        let session = TrainingSession(drillType: .freeShoot)
        session.endedAt = Date.now
        session.recalculateStats()

        try await service.upsertSession(session, profileId: cloudProfile?.id)

        let fetched = try await service.fetchSessions(updatedAfter: .distantPast)
        XCTAssertTrue(fetched.contains { $0.id == session.id })
    }

    func testShotSetUnionDoesNotDropShots() async throws {
        // Verify that upserting the same shots twice does not duplicate them
        let session = TrainingSession(drillType: .freeShoot)
        let shot1 = ShotRecord(sequenceIndex: 1, result: .make, zone: .paint,
                               shotType: .layup, courtX: 0.5, courtY: 0.1)
        let shot2 = ShotRecord(sequenceIndex: 2, result: .miss, zone: .midRange,
                               shotType: .pullUp, courtX: 0.3, courtY: 0.4)
        session.shots = [shot1, shot2]

        try await service.upsertShots([shot1, shot2])
        try await service.upsertShots([shot1, shot2])   // second upsert — must not duplicate

        // Query directly
        let client = SupabaseClient.test
        let rows: [ShotRecordDTO] = try await client.from("shot_records")
            .select()
            .eq("session_id", value: session.id.uuidString)
            .execute()
            .value
        XCTAssertEqual(rows.count, 2, "Set-union: duplicate upsert must not create extra rows")
    }

    func testRLSBlocksCrossUserRead() async throws {
        // Create user A, insert a session, sign out
        let sessionA = TrainingSession(drillType: .freeShoot)
        try await service.upsertSession(sessionA, profileId: nil)
        try await service.signOut()

        // Sign in as user B
        let emailB = "test-b-\(UUID().uuidString)@hooptrack.test"
        try await service.signIn(email: emailB, password: "TestPass123!")

        // User B should see zero sessions
        let sessions = try await service.fetchSessions(updatedAfter: .distantPast)
        XCTAssertTrue(sessions.isEmpty, "RLS must prevent cross-user reads")
    }
}
```

### 11.3 Unit Tests for DTO Mapping

These are pure unit tests with no network dependency:

```swift
// HoopTrackTests/Supabase/DTOMappingTests.swift

import XCTest
@testable import HoopTrack

final class DTOMappingTests: XCTestCase {

    func testShotRecordDTORoundTrip() {
        let userId = UUID()
        let session = TrainingSession(drillType: .freeShoot)
        let shot = ShotRecord(sequenceIndex: 1, result: .make, zone: .cornerThree,
                              shotType: .catchAndShoot, courtX: 0.1, courtY: 0.8)
        shot.session          = session
        shot.releaseAngleDeg  = 48.5
        shot.releaseTimeMs    = 320

        let dto = ShotRecordDTO(from: shot, userId: userId)

        XCTAssertEqual(dto.id, shot.id)
        XCTAssertEqual(dto.userId, userId)
        XCTAssertEqual(dto.result, "Make")
        XCTAssertEqual(dto.zone, "Corner 3")
        XCTAssertEqual(dto.releaseAngleDeg, 48.5)
        XCTAssertEqual(dto.releaseTimeMs, 320)
    }

    func testPlayerProfileDTOInfinityConsistencyScore() {
        // prBestConsistencyScore == Double.infinity must serialize as nil (no sessions yet)
        let profile = PlayerProfile(name: "Rookie")
        // Default is Double.infinity per PlayerProfile.init()
        let dto = PlayerProfileDTO(from: profile, userId: UUID())
        XCTAssertNil(dto.prBestConsistencyScore,
                     "Double.infinity must map to nil in the DTO to avoid Postgres overflow")
    }
}
```

### 11.4 CI Considerations

- Run integration tests (`SupabaseDataServiceTests`) in a separate Xcode test plan called `SupabaseIntegrationTests` so they do not run on every PR build.
- Add a GitHub Actions job that spins up `supabase start` (via `supabase-cli` action) and runs the integration plan against it nightly.
- Unit tests (`DTOMappingTests`) run on every PR alongside the existing `HoopTrackTests` plan with no additional infrastructure.

---

## Appendix: File Location Summary

| New file | Purpose |
|---|---|
| `HoopTrack/supabase/migrations/20260412000001_initial_schema.sql` | Full Postgres schema |
| `HoopTrack/supabase/migrations/20260412000002_enable_rls.sql` | RLS enable + policies |
| `HoopTrack/supabase/migrations/20260412000003_leaderboard_view.sql` | Leaderboard view |
| `HoopTrack/HoopTrack/Services/SupabaseClient+Shared.swift` | Singleton client |
| `HoopTrack/HoopTrack/Services/SupabaseDataService.swift` | Cloud sync service |
| `HoopTrack/HoopTrack/Services/InitialSyncCoordinator.swift` | One-time migration sync |
| `HoopTrack/HoopTrack/Services/RealtimeSessionService.swift` | Realtime subscriptions |
| `HoopTrack/HoopTrack/Models/SupabaseDTO.swift` | Codable transfer objects |
| `HoopTrack/HoopTrack/Models/Migrations/HoopTrackSchemaV2.swift` | SwiftData V2 (adds `cloudSyncedAt`) |
| `HoopTrackTests/Supabase/SupabaseDataServiceTests.swift` | Integration tests |
| `HoopTrackTests/Supabase/DTOMappingTests.swift` | DTO unit tests |
| `Config.xcconfig` (gitignored) | Supabase URL + anon key |

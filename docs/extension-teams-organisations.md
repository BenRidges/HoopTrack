# Teams & Organisations — Extension Plan

**Project:** HoopTrack iOS  
**Date:** 2026-04-12  
**Status:** Planning  
**Prerequisite plans:** upgrade-authentication-identity, upgrade-backend-api, upgrade-postgresql-supabase, extension-coach-review-mode, extension-multiplayer-sessions

---

## Table of Contents

1. [Overview](#1-overview)
2. [Data Model](#2-data-model)
3. [Role-Based Access Control](#3-role-based-access-control)
4. [Invite Flow](#4-invite-flow)
5. [iOS Role-Aware UI](#5-ios-role-aware-ui)
6. [Team Dashboard (iOS)](#6-team-dashboard-ios)
7. [Team Leaderboard](#7-team-leaderboard)
8. [Team Training Goals](#8-team-training-goals)
9. [Web Dashboard Additions](#9-web-dashboard-additions)
10. [Organisation Tier](#10-organisation-tier)
11. [Multiplayer Sessions Within Teams](#11-multiplayer-sessions-within-teams)
12. [Subscription Model](#12-subscription-model)
13. [Migration Path](#13-migration-path)
14. [Testing Approach](#14-testing-approach)

---

## 1. Overview

### Hierarchy

HoopTrack's social layer is structured as a three-tier hierarchy:

```
Organisation  (e.g. "Westside Basketball Academy")
    └── Team  (e.g. "U18 Varsity", "Adult Rec League")
          └── Member  (player, assistant_coach, head_coach)
```

An `Organisation` is the top-level entity — a club, school, or academy. It owns one or more `Teams`. Each `Team` has a roster of `Members`, each assigned a role. An organisation can also exist with a single team (the common case for independent coaches) or no team at all (reserved for future org-only admin tasks like billing).

### Role Model

| Role | Scope | Notes |
|---|---|---|
| `org_admin` | Organisation | Typically the club director or program coordinator. Manages teams, coaches, and billing. No court-level coaching duties assumed. |
| `head_coach` | Team | Primary coach for a specific team. Full read access to all member data on that team. Sets team goals and approves roster changes. |
| `assistant_coach` | Team | View-only plus annotation rights. Cannot set goals or alter the roster. |
| `player` | Team | Sees own data and team-scoped leaderboard. Cannot see other players' raw session data. |

Roles are additive: a user can be `head_coach` of Team A and `player` on Team B simultaneously. Role checks are always evaluated in the context of a specific team or organisation membership row, never as a global user property.

### Relationship to Coach Review Mode

The Coach Review Mode extension introduces a `coach_athletes` join table (one coach ↔ one athlete, bilateral opt-in). Teams & Organisations supersedes this for team contexts. The `coach_athletes` table remains valid for independent coach-athlete pairs who have no formal team. When a coach invites an athlete to a team, the existing `coach_athletes` relationship is preserved and does not need to be migrated — both coexist.

The `head_coach` team role grants the same data-read permissions that a `coach_athletes` entry grants, but scoped to all members of the team. RLS policies check both paths so that a coach who has team members via `team_members` and independent athletes via `coach_athletes` sees all of them through a single `canReadAthleteSession` policy function.

---

## 2. Data Model

All DDL is designed for **Supabase Postgres**. Run migrations in order using the Supabase CLI (`supabase db push`).

### 2.1 `organisations`

```sql
create table organisations (
  id                uuid        primary key default gen_random_uuid(),
  name              text        not null,
  slug              text        not null unique,          -- URL-safe identifier, e.g. "westside-academy"
  logo_url          text,
  created_by        uuid        not null references auth.users(id) on delete restrict,
  subscription_tier text        not null default 'free'   -- 'free' | 'pro_team' | 'org'
    check (subscription_tier in ('free', 'pro_team', 'org')),
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index organisations_created_by_idx on organisations(created_by);
create index organisations_slug_idx       on organisations(slug);

-- Auto-update updated_at on any row change
create trigger organisations_updated_at
  before update on organisations
  for each row execute function moddatetime(updated_at);
```

### 2.2 `teams`

```sql
create table teams (
  id            uuid        primary key default gen_random_uuid(),
  org_id        uuid        references organisations(id) on delete cascade,  -- nullable: team can exist without an org
  name          text        not null,
  sport_level   text        not null default 'recreational'
    check (sport_level in ('recreational', 'youth', 'high_school', 'college', 'semi_pro', 'pro')),
  head_coach_id uuid        references auth.users(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index teams_org_id_idx       on teams(org_id);
create index teams_head_coach_idx   on teams(head_coach_id);

create trigger teams_updated_at
  before update on teams
  for each row execute function moddatetime(updated_at);
```

### 2.3 `team_members`

```sql
create table team_members (
  team_id       uuid        not null references teams(id) on delete cascade,
  user_id       uuid        not null references auth.users(id) on delete cascade,
  role          text        not null default 'player'
    check (role in ('head_coach', 'assistant_coach', 'player')),
  jersey_number smallint,   -- nullable; players only
  joined_at     timestamptz not null default now(),
  primary key (team_id, user_id)
);

create index team_members_user_idx  on team_members(user_id);
create index team_members_team_idx  on team_members(team_id);
create index team_members_role_idx  on team_members(team_id, role);
```

### 2.4 `team_invites`

```sql
create table team_invites (
  id          uuid        primary key default gen_random_uuid(),
  token       text        not null unique default encode(gen_random_bytes(32), 'hex'),
  team_id     uuid        not null references teams(id) on delete cascade,
  role        text        not null default 'player'
    check (role in ('head_coach', 'assistant_coach', 'player')),
  email       text,        -- pre-filled but not required; invite link works for anyone
  invited_by  uuid        not null references auth.users(id),
  expires_at  timestamptz not null default (now() + interval '7 days'),
  used_at     timestamptz,
  used_by     uuid        references auth.users(id),
  revoked_at  timestamptz,
  created_at  timestamptz not null default now()
);

create index team_invites_token_idx   on team_invites(token) where used_at is null and revoked_at is null;
create index team_invites_team_idx    on team_invites(team_id);
create index team_invites_email_idx   on team_invites(email) where email is not null;
```

### 2.5 `team_training_goals`

```sql
create table team_training_goals (
  id            uuid        primary key default gen_random_uuid(),
  team_id       uuid        not null references teams(id) on delete cascade,
  goal_type     text        not null
    check (goal_type in ('fg_percent', 'agility_time', 'dribble_speed', 'session_count', 'custom')),
  target_value  numeric     not null,
  unit          text        not null default '%',          -- '%', 'seconds', 'dribbles/min', 'sessions', ''
  deadline      date        not null,
  description   text,
  created_by    uuid        not null references auth.users(id),
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz,                               -- set when goal is achieved or expired
  resolution    text        check (resolution in ('achieved', 'expired', 'cancelled'))
);

create index team_training_goals_team_idx     on team_training_goals(team_id);
create index team_training_goals_deadline_idx on team_training_goals(team_id, deadline)
  where resolved_at is null;
```

### 2.6 `org_members`

```sql
-- Tracks org-level admin membership separately from team membership
create table org_members (
  org_id     uuid        not null references organisations(id) on delete cascade,
  user_id    uuid        not null references auth.users(id) on delete cascade,
  role       text        not null default 'org_admin'
    check (role in ('org_admin')),
  joined_at  timestamptz not null default now(),
  primary key (org_id, user_id)
);

create index org_members_user_idx on org_members(user_id);
```

---

## 3. Role-Based Access Control

### 3.1 Permission Matrix

| Action | `org_admin` | `head_coach` | `assistant_coach` | `player` |
|---|---|---|---|---|
| Create / delete team | Yes (own org) | No | No | No |
| Invite members to team | Yes | Yes | No | No |
| Remove member from team | Yes | Yes | No | No |
| View all team members' session data | Yes | Yes | No | No |
| Leave annotations on sessions | Yes | Yes | Yes | No |
| Set team training goals | Yes | Yes | No | No |
| View team leaderboard | Yes | Yes | Yes | Yes |
| View own session data | Yes | Yes | Yes | Yes |
| Manage org billing | Yes | No | No | No |
| View org-wide analytics | Yes | No | No | No |

### 3.2 Supabase RLS Policies

Enable RLS on all tables, then add fine-grained policies. The helper functions below are created once and reused.

```sql
-- Helper: is the calling user a member of a given team?
create or replace function is_team_member(p_team_id uuid, p_role text default null)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from team_members
    where team_id = p_team_id
      and user_id = auth.uid()
      and (p_role is null or role = p_role)
  );
$$;

-- Helper: is the calling user a coach (head or assistant) on a given team?
create or replace function is_team_coach(p_team_id uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1 from team_members
    where team_id = p_team_id
      and user_id = auth.uid()
      and role in ('head_coach', 'assistant_coach')
  );
$$;

-- Helper: is the calling user an org_admin for the org that owns a team?
create or replace function is_org_admin_for_team(p_team_id uuid)
returns boolean language sql security definer stable as $$
  select exists (
    select 1
    from teams t
    join org_members om on om.org_id = t.org_id
    where t.id = p_team_id
      and om.user_id = auth.uid()
      and om.role = 'org_admin'
  );
$$;
```

#### `organisations` policies

```sql
alter table organisations enable row level security;

-- Anyone can read organisations (for discover/join flows)
create policy "organisations_select" on organisations
  for select using (true);

-- Only the creator or an org_admin can update
create policy "organisations_update" on organisations
  for update using (
    created_by = auth.uid()
    or exists (
      select 1 from org_members
      where org_id = id and user_id = auth.uid() and role = 'org_admin'
    )
  );

-- Only authenticated users can insert (Supabase Edge Function validates slug uniqueness)
create policy "organisations_insert" on organisations
  for insert with check (created_by = auth.uid());
```

#### `teams` policies

```sql
alter table teams enable row level security;

create policy "teams_select" on teams
  for select using (
    is_team_member(id)
    or is_org_admin_for_team(id)
    or head_coach_id = auth.uid()
  );

create policy "teams_insert" on teams
  for insert with check (
    -- Must be an org_admin of the parent org, or creating a standalone team
    org_id is null
    or exists (
      select 1 from org_members
      where org_id = teams.org_id and user_id = auth.uid() and role = 'org_admin'
    )
  );

create policy "teams_update" on teams
  for update using (
    head_coach_id = auth.uid()
    or is_org_admin_for_team(id)
  );
```

#### `team_members` policies

```sql
alter table team_members enable row level security;

-- Any team member can see the roster
create policy "team_members_select" on team_members
  for select using (is_team_member(team_id));

-- Only head_coach or org_admin can add/remove members
create policy "team_members_insert" on team_members
  for insert with check (
    is_team_member(team_id, 'head_coach')
    or is_org_admin_for_team(team_id)
  );

create policy "team_members_delete" on team_members
  for delete using (
    -- Allow self-removal (leave team)
    user_id = auth.uid()
    or is_team_member(team_id, 'head_coach')
    or is_org_admin_for_team(team_id)
  );
```

#### `team_invites` policies

```sql
alter table team_invites enable row level security;

-- Anyone can read an invite by token (used during accept flow — token is the secret)
-- Full invite list visible only to coaches and org_admins
create policy "team_invites_select" on team_invites
  for select using (
    invited_by = auth.uid()
    or is_team_coach(team_id)
    or is_org_admin_for_team(team_id)
  );

create policy "team_invites_insert" on team_invites
  for insert with check (
    is_team_member(team_id, 'head_coach')
    or is_org_admin_for_team(team_id)
  );

-- Coaches can revoke; the invited user can mark as used
create policy "team_invites_update" on team_invites
  for update using (
    invited_by = auth.uid()
    or is_team_member(team_id, 'head_coach')
    or is_org_admin_for_team(team_id)
    -- The accepting user can mark used_at
    or (used_by = auth.uid() and used_at is null)
  );
```

#### `training_sessions` cross-team visibility

```sql
-- Extend the existing training_sessions RLS policy to allow team coaches read access
-- Assumes training_sessions has a user_id column (the athlete who owns the session)

create policy "training_sessions_team_coach_select" on training_sessions
  for select using (
    user_id = auth.uid()  -- own sessions always visible
    or exists (           -- coach can see all members of their team
      select 1
      from team_members coach_row
      join team_members athlete_row
        on athlete_row.team_id = coach_row.team_id
      where coach_row.user_id = auth.uid()
        and coach_row.role in ('head_coach', 'assistant_coach')
        and athlete_row.user_id = training_sessions.user_id
    )
    or exists (           -- coach_athletes fallback for independent pairs
      select 1 from coach_athletes
      where coach_id = auth.uid()
        and athlete_id = training_sessions.user_id
    )
  );
```

---

## 4. Invite Flow

### 4.1 Happy Path

```
Coach creates invite
        │
        ▼
POST /functions/v1/team-invite
  { team_id, role, email? }
        │
        ▼
Edge Function inserts team_invites row
Returns { invite_url: "https://hooptrack.app/join?token=<hex>" }
        │
        ▼
Coach shares URL (copy/paste, iMessage, email)
        │
        ▼
Player opens URL on any device
        │
   ┌────┴────┐
   │         │
Not       Already
signed    signed
  in        in
   │         │
Sign in    Accept
with       dialog
Apple       │
   │         │
   └────┬────┘
        │
        ▼
POST /functions/v1/team-invite/accept
  { token }           (Auth header: Bearer <jwt>)
        │
        ▼
Validate: token exists, not expired, not used, not revoked
Insert team_members (team_id, user_id=auth.uid(), role)
Mark invite used_at = now(), used_by = auth.uid()
        │
        ▼
Redirect to deep link: hooptrack://team/<team_id>
```

### 4.2 Token Validation Edge Function

```typescript
// supabase/functions/team-invite/accept/index.ts
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

Deno.serve(async (req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  const authHeader = req.headers.get('Authorization')
  if (!authHeader) return new Response('Unauthorized', { status: 401 })

  const jwt = authHeader.replace('Bearer ', '')
  const { data: { user }, error: authError } = await supabase.auth.getUser(jwt)
  if (authError || !user) return new Response('Invalid token', { status: 401 })

  const { token } = await req.json()

  // Fetch and validate invite
  const { data: invite, error } = await supabase
    .from('team_invites')
    .select('*')
    .eq('token', token)
    .is('used_at', null)
    .is('revoked_at', null)
    .gt('expires_at', new Date().toISOString())
    .single()

  if (error || !invite) {
    return new Response(
      JSON.stringify({ error: 'Invite not found, expired, or already used' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    )
  }

  // Check if user is already a member
  const { data: existing } = await supabase
    .from('team_members')
    .select('user_id')
    .eq('team_id', invite.team_id)
    .eq('user_id', user.id)
    .maybeSingle()

  if (existing) {
    return new Response(
      JSON.stringify({ error: 'Already a member of this team', team_id: invite.team_id }),
      { status: 409, headers: { 'Content-Type': 'application/json' } }
    )
  }

  // Add to team
  await supabase.from('team_members').insert({
    team_id: invite.team_id,
    user_id: user.id,
    role: invite.role
  })

  // Mark invite used
  await supabase
    .from('team_invites')
    .update({ used_at: new Date().toISOString(), used_by: user.id })
    .eq('id', invite.id)

  return new Response(
    JSON.stringify({ success: true, team_id: invite.team_id }),
    { status: 200, headers: { 'Content-Type': 'application/json' } }
  )
})
```

### 4.3 Expiry and Revocation

- Invites expire after **7 days** by default (configurable per-invite for bulk onboarding).
- A coach can revoke an unused invite at any time: `UPDATE team_invites SET revoked_at = now() WHERE id = ?` — RLS ensures only the issuing coach or an org_admin can do this.
- Expired and used invite rows are never deleted; they form an audit trail. A nightly Supabase scheduled function archives rows older than 90 days into a `team_invites_archive` table.
- If the same email is re-invited after an expiry, the old token is ignored and a new row is created.

---

## 5. iOS Role-Aware UI

### 5.1 Tab Bar Adaptation

The existing tab bar has: Home, Train, History, Profile. When a user belongs to at least one team, a **Team** tab is injected between History and Profile.

```swift
// TeamContext.swift
import SwiftUI
import Combine

@MainActor
final class TeamContext: ObservableObject {
    @Published var memberships: [TeamMembership] = []  // user's teams + roles
    @Published var activeTeam: TeamMembership?          // selected team if multi-team

    var isPartOfAnyTeam: Bool { !memberships.isEmpty }

    var primaryRole: TeamRole? { activeTeam?.role }

    var isCoach: Bool {
        guard let role = primaryRole else { return false }
        return role == .headCoach || role == .assistantCoach
    }
}

// RootTabView.swift
struct RootTabView: View {
    @EnvironmentObject var teamContext: TeamContext

    var body: some View {
        TabView {
            HomeTabView()
                .tabItem { Label("Home", systemImage: "house") }
            TrainTabView()
                .tabItem { Label("Train", systemImage: "figure.basketball") }
            HistoryTabView()
                .tabItem { Label("History", systemImage: "chart.bar") }
            if teamContext.isPartOfAnyTeam {
                TeamTabView()
                    .tabItem { Label("Team", systemImage: "person.3") }
            }
            ProfileTabView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
    }
}
```

### 5.2 `TeamViewModel`

```swift
// TeamViewModel.swift
@MainActor
final class TeamViewModel: ObservableObject {
    @Published var roster: [TeamMemberSummary] = []
    @Published var goals: [TeamTrainingGoal] = []
    @Published var leaderboard: [LeaderboardEntry] = []
    @Published var recentSessions: [SessionFeedItem] = []
    @Published var teamStats: TeamAggregateStats?
    @Published var isLoading = false
    @Published var error: Error?

    private let apiService: APIService
    private let teamContext: TeamContext
    private var cancellables = Set<AnyCancellable>()

    init(apiService: APIService, teamContext: TeamContext) {
        self.apiService = apiService
        self.teamContext = teamContext
    }

    func loadTeamDashboard(teamId: String) async {
        isLoading = true
        defer { isLoading = false }
        async let rosterTask    = apiService.fetchRoster(teamId: teamId)
        async let goalsTask     = apiService.fetchTeamGoals(teamId: teamId)
        async let statsTask     = apiService.fetchTeamStats(teamId: teamId)
        async let sessionsTask  = apiService.fetchTeamSessionFeed(teamId: teamId, limit: 20)
        do {
            (roster, goals, teamStats, recentSessions) =
                try await (rosterTask, goalsTask, statsTask, sessionsTask)
        } catch {
            self.error = error
        }
    }
}
```

### 5.3 Conditional Coach vs. Player UI

Use `TeamContext.isCoach` to gate UI elements inline — avoid duplicating entire views.

```swift
// TeamTabView.swift
struct TeamTabView: View {
    @EnvironmentObject var teamContext: TeamContext
    @StateObject private var vm = TeamViewModel(...)

    var body: some View {
        NavigationStack {
            List {
                TeamStatsSection(stats: vm.teamStats)
                TeamGoalsSection(goals: vm.goals, isCoach: teamContext.isCoach)
                RosterSection(roster: vm.roster, isCoach: teamContext.isCoach)
                if teamContext.isCoach {
                    SessionFeedSection(sessions: vm.recentSessions)
                }
                LeaderboardSection(entries: vm.leaderboard)
            }
            .navigationTitle(teamContext.activeTeam?.teamName ?? "Team")
            .toolbar {
                if teamContext.isCoach {
                    ToolbarItem(placement: .primaryAction) {
                        NavigationLink("Manage") {
                            TeamManagementView()
                        }
                    }
                }
            }
        }
    }
}
```

---

## 6. Team Dashboard (iOS)

### 6.1 `TeamTabView` Structure

The Team tab is a single-scroll `List` divided into sections. Each section maps to a distinct Hasura/Supabase query.

```
TeamTabView
├── TeamHeaderView          — team name, sport level, member count badge
├── TeamAggregateStatsCard  — avg FG%, best agility, dribble speed
├── TeamGoalsProgressSection — active goals with progress bars
├── RosterListSection       — avatar + name + role + recent skill rating delta
├── LeaderboardPreviewSection — top 3 in primary skill + "See All" link
└── SessionFeedSection (coach only) — recent sessions across all members
```

### 6.2 Roster List

Each roster row shows:
- Player avatar (from `PlayerProfile.avatarURL`)
- Display name + jersey number
- Skill rating sparkline (last 4 sessions)
- Delta indicator (up/down arrow vs. previous week)

Coaches see a chevron → `AthleteDetailView` (same view used in Coach Review Mode). Players see chevrons only on their own row.

### 6.3 Team Aggregate Stats

```graphql
query TeamAggregateStats($teamId: uuid!) {
  team_members(where: { team_id: { _eq: $teamId }, role: { _eq: "player" } }) {
    user_id
  }
  training_sessions_aggregate(
    where: { user_id: { _in: $playerIds } }
  ) {
    aggregate {
      avg { fg_percent }
      min { best_agility_time_ms }
    }
  }
}
```

On iOS, `TeamAggregateStats` is a value type:

```swift
struct TeamAggregateStats {
    let avgFGPercent: Double?
    let bestAgilityTimeMs: Int?
    let totalSessionsThisWeek: Int
    let activeMemberCount: Int
}
```

### 6.4 Recent Session Feed (Coach View)

The session feed shows a reverse-chronological list of sessions from all team members. Each row: athlete name, session type icon, date, headline stat (FG% for shot sessions, best time for agility, etc.). Tapping opens `SessionDetailView` for that athlete. The feed uses a Supabase Realtime subscription so new sessions appear without a pull-to-refresh.

---

## 7. Team Leaderboard

### 7.1 Data Source

The leaderboard is built on top of `SkillRatingService` output (per-player skill ratings already written to Supabase as part of the Phase 5 backend plan). The leaderboard query aggregates the most recent rating per skill dimension per player.

```sql
-- Team leaderboard view (materialized for performance, refreshed hourly)
create materialized view team_leaderboard as
select
  tm.team_id,
  sr.user_id,
  sr.dimension,
  sr.score,
  sr.computed_at,
  rank() over (
    partition by tm.team_id, sr.dimension
    order by sr.score desc
  ) as rank
from skill_ratings sr
join team_members tm on tm.user_id = sr.user_id
where sr.computed_at = (
  select max(sr2.computed_at)
  from skill_ratings sr2
  where sr2.user_id = sr.user_id and sr2.dimension = sr.dimension
);

create unique index team_leaderboard_idx on team_leaderboard(team_id, user_id, dimension);

-- Refresh hook (call from a pg_cron job every hour)
select cron.schedule('refresh-team-leaderboard', '0 * * * *',
  $$refresh materialized view concurrently team_leaderboard$$
);
```

### 7.2 Scope Selector

The leaderboard supports **weekly** and **monthly** scopes. The scope filters `computed_at` within the window. The "all-time" view uses the materialized view directly.

```swift
enum LeaderboardScope: String, CaseIterable {
    case weekly   = "This Week"
    case monthly  = "This Month"
    case allTime  = "All Time"
}

struct LeaderboardEntry: Identifiable {
    let id: String           // user_id
    let displayName: String
    let avatarURL: URL?
    let rank: Int
    let score: Double
    let dimension: SkillDimension
    let delta: Int?          // rank change vs. previous period; nil on first entry
}
```

### 7.3 iOS `LeaderboardView`

- Segmented control: FG% | Agility | Dribble | Overall
- Scope picker: Week | Month | All Time
- Top 3 shown with podium styling; remaining positions in a plain list
- Current user's own row is highlighted regardless of their position (sticky at bottom if outside top 10)
- RLS ensures a player never sees teammates' raw session data — only their computed score and rank

---

## 8. Team Training Goals

### 8.1 Goal Types

| `goal_type` | Description | `target_value` | `unit` |
|---|---|---|---|
| `fg_percent` | Team average FG% above threshold | e.g. `45.0` | `%` |
| `agility_time` | Team best agility completion time below threshold | e.g. `18500` | `ms` |
| `dribble_speed` | Average dribble speed above threshold | e.g. `120` | `dribbles/min` |
| `session_count` | Total team sessions within window | e.g. `20` | `sessions` |
| `custom` | Free-text goal (manual progress update by coach) | e.g. `1` (0–1 scale) | `` |

### 8.2 Progress Calculation

Progress is computed by a Supabase Edge Function `compute-goal-progress`, called on demand and cached for 5 minutes in Redis.

```typescript
// supabase/functions/compute-goal-progress/index.ts
async function computeProgress(goalId: string, supabase: SupabaseClient) {
  const { data: goal } = await supabase
    .from('team_training_goals')
    .select('*')
    .eq('id', goalId)
    .single()

  switch (goal.goal_type) {
    case 'fg_percent': {
      const { data } = await supabase.rpc('team_avg_fg_percent', {
        p_team_id: goal.team_id,
        p_since: goal.created_at
      })
      return { current: data, target: goal.target_value }
    }
    case 'session_count': {
      const { count } = await supabase
        .from('training_sessions')
        .select('*', { count: 'exact', head: true })
        .in('user_id', memberIds(goal.team_id))
        .gte('session_date', goal.created_at)
        .lte('session_date', goal.deadline)
      return { current: count ?? 0, target: goal.target_value }
    }
    // ... other types
  }
}
```

### 8.3 iOS Goal Progress View

```swift
struct TeamGoalProgressRow: View {
    let goal: TeamTrainingGoal
    let progress: GoalProgress  // current + target values

    var progressFraction: Double {
        min(progress.current / progress.target, 1.0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(goal.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(goal.deadlineLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressFraction)
                .tint(progressFraction >= 1.0 ? .green : .orange)
            HStack {
                Text("\(progress.current, format: .number.precision(.fractionLength(1)))\(goal.unit)")
                    .font(.caption)
                Spacer()
                Text("Goal: \(progress.target, format: .number.precision(.fractionLength(1)))\(goal.unit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
```

Coaches see a "Add Goal" button (opens a sheet). Players see progress-only — no add/edit controls.

---

## 9. Web Dashboard Additions

### 9.1 Route Structure

New routes added to the existing Next.js web dashboard:

```
/dashboard/team/[id]            — team overview (roster + goals + aggregate stats)
/dashboard/team/[id]/athletes   — full roster table with drill-down
/dashboard/team/[id]/athletes/[userId] — individual athlete full session history
/dashboard/team/[id]/leaderboard — skill dimension rankings
/dashboard/team/[id]/goals       — goals CRUD (coach) or read-only (player)
/dashboard/org/[slug]            — org admin portal (see §10)
```

### 9.2 Team Overview Page (`/dashboard/team/[id]`)

```typescript
// app/dashboard/team/[id]/page.tsx
import { createServerClient } from '@supabase/ssr'

export default async function TeamPage({ params }: { params: { id: string } }) {
  const supabase = createServerClient(...)
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) redirect('/login')

  const { data: membership } = await supabase
    .from('team_members')
    .select('role')
    .eq('team_id', params.id)
    .eq('user_id', user.id)
    .single()

  if (!membership) notFound()

  const isCoach = ['head_coach', 'assistant_coach'].includes(membership.role)

  const [team, members, goals] = await Promise.all([
    supabase.from('teams').select('*').eq('id', params.id).single(),
    supabase.from('team_members').select('*, users(name, avatar_url)').eq('team_id', params.id),
    supabase.from('team_training_goals').select('*').eq('team_id', params.id).is('resolved_at', null)
  ])

  return (
    <TeamDashboard
      team={team.data}
      members={members.data ?? []}
      goals={goals.data ?? []}
      isCoach={isCoach}
    />
  )
}
```

### 9.3 Athlete Drill-Down

When a head coach clicks an athlete row, they navigate to `/dashboard/team/[id]/athletes/[userId]`. This page renders:

- Full `TrainingSession` history (FG% trend chart, shot zone heat map)
- Skill rating history per dimension (line chart, 90-day rolling)
- Active goals assigned to the athlete
- Coach annotation feed (from `session_annotations` table in Coach Review Mode)

The page is server-rendered with RLS enforcing that only coaches with access to this team can load the athlete's data.

### 9.4 Aggregate Charts

Built with **Recharts** (or **Observable Plot** for richer shot chart rendering). Charts displayed:

- Team FG% over time (line chart, one point per week)
- Skill rating distribution (box plot per dimension — shows median, IQR, outliers)
- Session frequency heatmap (GitHub-style activity calendar for the team)
- Goal progress gauge charts

---

## 10. Organisation Tier

### 10.1 Scope

The org tier is **web-only initially**. The iOS app surfaces org membership passively (a user may be a member of multiple teams across the same org), but the org admin portal is a dedicated web experience at `/dashboard/org/[slug]`.

### 10.2 Org Admin Portal

Accessible only to `org_members` with `role = 'org_admin'`.

**Teams tab:** Table of all teams under the org. Columns: team name, sport level, head coach, active member count, last session date. Actions: create team, assign head coach, archive team.

**Coaches tab:** List of all `head_coach` and `assistant_coach` rows across all org teams. Invite a coach to a team, remove coach from a team, promote assistant to head.

**Analytics tab:** Org-wide aggregate charts — all teams' FG% over time on one chart, cross-team leaderboard (useful for academies tracking development progression across age groups).

**Billing tab:** Subscription tier selector. Managed via RevenueCat web-to-app flow (see §12).

### 10.3 Org Analytics Query

```sql
-- Org-wide team performance summary (used in org analytics tab)
select
  t.id          as team_id,
  t.name        as team_name,
  count(tm.user_id) filter (where tm.role = 'player') as player_count,
  round(avg(ts.fg_percent)::numeric, 1)               as avg_fg_percent,
  max(ts.session_date)                                as last_session_date
from teams t
join org_members om on om.org_id = t.org_id
join team_members tm on tm.team_id = t.id
left join training_sessions ts
  on ts.user_id = tm.user_id
  and ts.session_date >= now() - interval '30 days'
where om.user_id = auth.uid()
  and om.role = 'org_admin'
group by t.id, t.name
order by last_session_date desc nulls last;
```

---

## 11. Multiplayer Sessions Within Teams

### 11.1 `team_id` Association

The `multiplayer_sessions` table (from the Multiplayer Sessions extension) gains an optional `team_id` foreign key:

```sql
alter table multiplayer_sessions
  add column team_id uuid references teams(id) on delete set null;

create index multiplayer_sessions_team_idx on multiplayer_sessions(team_id)
  where team_id is not null;
```

When a coach creates a session from the Team tab, the iOS client pre-populates `team_id` from `TeamContext.activeTeam`. When created from the Train tab as a standalone session, `team_id` remains null.

### 11.2 Team-Scoped Multiplayer Leaderboard

After a multiplayer session ends, results are aggregated and written to `multiplayer_results`. The team leaderboard picks these up in the next materialized view refresh.

For live within-session leaderboards (real-time rankings as shots drop), Supabase Realtime is used:

```swift
// TeamSessionLiveViewModel.swift
func subscribeToLiveRanking(sessionId: String) {
    supabase.realtimeV2
        .channel("team_session:\(sessionId)")
        .onPostgresChanges(
            InsertAction.self,
            schema: "public",
            table: "multiplayer_results",
            filter: "session_id=eq.\(sessionId)"
        ) { [weak self] change in
            Task { @MainActor in
                self?.handleNewResult(change.record)
            }
        }
        .subscribe()
}
```

### 11.3 Historical Team Session Feed

Multiplayer sessions with a `team_id` appear in the team session feed on the Team tab. Each row shows: participants (avatar stack), session type, duration, headline stats. Coaches can tap to see the full multi-player session breakdown.

---

## 12. Subscription Model

### 12.1 Tiers

| Tier | Price | Teams | Members per Team | Analytics | Org Portal |
|---|---|---|---|---|---|
| **Free** | $0 | 1 | 5 | Basic (7-day history) | No |
| **Pro Team** | $9.99/mo | 1 | Unlimited | Full (all-time + export) | No |
| **Org** | $49.99/mo | Unlimited | Unlimited | Full + cross-team | Yes |

The Free tier covers the "independent coach with a small group" use case and keeps the conversion funnel open. Pro Team is for active club teams. Org tier is for multi-team academies and school programs.

### 12.2 RevenueCat Integration

RevenueCat handles purchase validation, subscription state, and cross-platform entitlement checks.

```swift
// SubscriptionService.swift
import RevenueCat

@MainActor
final class SubscriptionService: ObservableObject {
    @Published var currentTier: SubscriptionTier = .free

    enum SubscriptionTier {
        case free, proTeam, org

        var maxMembers: Int {
            switch self {
            case .free:    return 5
            case .proTeam: return .max
            case .org:     return .max
            }
        }

        var maxTeams: Int {
            switch self {
            case .free, .proTeam: return 1
            case .org:            return .max
            }
        }
    }

    func loadEntitlements() async {
        do {
            let info = try await Purchases.shared.customerInfo()
            if info.entitlements["org"]?.isActive == true {
                currentTier = .org
            } else if info.entitlements["pro_team"]?.isActive == true {
                currentTier = .proTeam
            } else {
                currentTier = .free
            }
        } catch {
            // Default to free on error; server-side enforcement via RLS is the source of truth
            currentTier = .free
        }
    }
}
```

### 12.3 Enforcement

Client-side checks in `SubscriptionService` gate the "Invite Member" button and "Create Team" flow. Server-side enforcement is a Supabase Edge Function `validate-team-capacity` called before any `team_members` insert. This prevents circumvention by intercepting API calls:

```typescript
// supabase/functions/validate-team-capacity/index.ts
const { count } = await supabase
  .from('team_members')
  .select('*', { count: 'exact', head: true })
  .eq('team_id', teamId)

const tier = await getOrgSubscriptionTier(teamId, supabase)
const limit = tier === 'free' ? 5 : Infinity

if ((count ?? 0) >= limit) {
  return new Response(
    JSON.stringify({ error: 'Team member limit reached. Upgrade to Pro Team.' }),
    { status: 403 }
  )
}
```

---

## 13. Migration Path

### 13.1 Existing Solo Users

No action required. Solo users have no team membership rows. All existing `TrainingSession` and `PlayerProfile` data is unaffected. The Team tab does not appear. Users can join a team at any time via an invite link.

### 13.2 Existing Coach-Athlete Pairs (Coach Review Mode)

Coach-athlete pairs stored in `coach_athletes` are **not automatically migrated** to `team_members`. Automatic migration would require arbitrarily creating team names, which is disruptive. Instead:

1. After sign-in, if a user has `coach_athletes` entries but no `team_members` entries, a one-time prompt appears: "You have 3 athletes. Create a team to use the new Team features — or keep your existing coach connections as-is."
2. The user can optionally create a team and add their existing athletes. The assistant pre-fills the invite form with athlete names for convenience.
3. The `coach_athletes` table is retained indefinitely. Permissions granted via `coach_athletes` continue to work — no data access is lost.
4. If a coach migrates to a team, a backfill script populates `team_members` from the `coach_athletes` rows for that coach. Athletes receive an in-app notification that they have been added to a team and can accept or decline.

### 13.3 Multiplayer Sessions Already Recorded

Existing `multiplayer_sessions` rows have `team_id = null`. They do not appear in team feeds. This is intentional — historical sessions were not played in a team context. No migration needed.

### 13.4 Subscription State for Early Users

Users who signed up before the subscription model launches are granted a 90-day Pro Team trial (provisioned via RevenueCat promotional entitlement). After the trial, they are prompted to subscribe or drop to Free tier.

---

## 14. Testing Approach

### 14.1 RLS Cross-Role Access Tests

Run against a local Supabase instance (`supabase start`). Use the `supabase test db` runner with `pgTAP`.

```sql
-- test/rls/team_members_rls_test.sql
begin;
select plan(6);

-- Fixture: create two teams, three users
set local role authenticator;

-- Test 1: player can see own team roster
set local request.jwt.claims = '{"sub": "player-uid-1"}';
select is(
  (select count(*) from team_members where team_id = 'team-a-id'),
  2::bigint,
  'player can see team roster'
);

-- Test 2: player cannot see other team's roster
select is(
  (select count(*) from team_members where team_id = 'team-b-id'),
  0::bigint,
  'player cannot see other team roster'
);

-- Test 3: head_coach can see all members
set local request.jwt.claims = '{"sub": "coach-uid-1"}';
select is(
  (select count(*) from team_members where team_id = 'team-a-id'),
  2::bigint,
  'head_coach can see full roster'
);

-- Test 4: player cannot read another player's training_sessions
set local request.jwt.claims = '{"sub": "player-uid-1"}';
select is(
  (select count(*) from training_sessions where user_id = 'player-uid-2'),
  0::bigint,
  'player cannot read teammate session data'
);

-- Test 5: head_coach can read all team members' training_sessions
set local request.jwt.claims = '{"sub": "coach-uid-1"}';
select ok(
  (select count(*) from training_sessions where user_id = 'player-uid-2') > 0,
  'head_coach can read team member session data'
);

-- Test 6: org_admin can update team
set local request.jwt.claims = '{"sub": "org-admin-uid"}';
select lives_ok(
  $$update teams set name = 'Updated Name' where id = 'team-a-id'$$,
  'org_admin can update team'
);

select finish();
rollback;
```

### 14.2 Invite Flow Integration Tests

```swift
// TeamInviteIntegrationTests.swift
final class TeamInviteIntegrationTests: XCTestCase {

    func testInviteHappyPath() async throws {
        let (coachClient, playerClient) = try await TestFixtures.coachAndPlayer()
        let teamId = try await TestFixtures.createTeam(coach: coachClient)

        // Coach creates invite
        let invite = try await coachClient.functions.invoke(
            "team-invite",
            options: .init(body: ["team_id": teamId, "role": "player"])
        )
        let token = invite["token"] as! String

        // Player accepts
        let result = try await playerClient.functions.invoke(
            "team-invite/accept",
            options: .init(body: ["token": token])
        )
        XCTAssertEqual(result["success"] as? Bool, true)

        // Verify membership
        let membership = try await playerClient
            .from("team_members")
            .select()
            .eq("team_id", value: teamId)
            .eq("user_id", value: playerClient.auth.currentUser!.id)
            .single()
            .execute()
        XCTAssertNotNil(membership.data)
    }

    func testExpiredInviteRejected() async throws {
        // Insert an already-expired invite directly via service role
        let expiredToken = try await TestFixtures.insertExpiredInvite(teamId: "test-team")
        let playerClient = try await TestFixtures.newPlayer()

        await XCTAssertThrowsErrorAsync(
            try await playerClient.functions.invoke(
                "team-invite/accept",
                options: .init(body: ["token": expiredToken])
            )
        )
    }

    func testDuplicateAcceptRejected() async throws {
        let (_, playerClient, token) = try await TestFixtures.inviteAndAccept()

        // Second accept attempt should fail with 409
        await XCTAssertThrowsErrorAsync(
            try await playerClient.functions.invoke(
                "team-invite/accept",
                options: .init(body: ["token": token])
            )
        )
    }
}
```

### 14.3 Aggregate Query Performance Tests

Leaderboard and aggregate stats queries must perform under realistic data volumes. Benchmark targets: < 200 ms for a 100-member team leaderboard, < 500 ms for org-wide analytics across 10 teams.

```sql
-- Performance test: team leaderboard query on 100-member team with 12 months of data
explain (analyze, buffers, format text)
select *
from team_leaderboard
where team_id = 'test-team-uuid'
  and dimension = 'fg_percent'
order by rank;

-- Expected: Index Scan on team_leaderboard_idx, < 5 ms (materialized view)
-- If sequential scan observed: force index or increase work_mem
```

Run as part of the CI pipeline against a seeded staging Supabase database using `supabase db seed` + `pgbench`.

### 14.4 iOS Unit Tests

- `TeamViewModelTests` — mock `APIService`, verify correct conditional rendering flags for each role
- `SubscriptionServiceTests` — mock RevenueCat `CustomerInfo`, verify tier mapping and enforcement gate logic
- `LeaderboardEntryTests` — verify rank delta calculation (previous period vs. current)
- `GoalProgressTests` — verify `progressFraction` clamping and edge cases (zero target, exceeded target)

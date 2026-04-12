# HoopTrack Web Dashboard — Technical Extension Plan

**Date:** 2026-04-12  
**Status:** Proposed  
**Depends on:** `upgrade-web-presence.md` (Phase B), `upgrade-backend-api.md`, `upgrade-postgresql-supabase.md`, `upgrade-authentication-identity.md`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites Checklist](#2-prerequisites-checklist)
3. [Route Structure](#3-route-structure)
4. [Authentication Flow](#4-authentication-flow)
5. [Session List View](#5-session-list-view)
6. [Session Detail View](#6-session-detail-view)
7. [Shot Chart Implementation](#7-shot-chart-implementation)
8. [Progress View](#8-progress-view)
9. [Goals View](#9-goals-view)
10. [Shared TypeScript Types](#10-shared-typescript-types)
11. [Data Fetching Strategy](#11-data-fetching-strategy)
12. [Performance](#12-performance)
13. [Coach Access Preview](#13-coach-access-preview)

---

## 1. Overview

### Purpose

The HoopTrack web dashboard is an authenticated browser application that gives athletes access to their full training history on a large screen. It reads from the same Supabase Postgres database that the iOS app writes to, using the same Supabase Auth credentials. Users log in once with Sign in with Apple and arrive at a persistent dashboard requiring no app install.

### Who Uses It

**Primary user — athletes reviewing long-term progress.** Mobile screens work well for immediate post-session review; they are limiting for multi-month trend analysis. A player who has trained 150 sessions over six months cannot usefully scroll a list on a phone. On a laptop with a 27-inch monitor and a pointer device, the same data becomes a strategic tool: hovering over a shot dot to see exact release angle, filtering six months of sessions to Tuesdays only, comparing two different four-week blocks side by side.

**Secondary user — future coaches.** The route structure is designed to anticipate a coach portal (see Section 13). Coaches will not manage multiple athletes from a phone; they need the same large-screen interface with athlete-switching added. The athlete's own dashboard view becomes the coach's read-only view of any athlete they supervise.

### What It Shows That Mobile Cannot Easily Surface

| Capability | Why mobile is insufficient |
|---|---|
| Multi-month FG% trend line | 150+ data points need horizontal scroll space and interactive zoom |
| Zone heat map with drill-through | Tapping a zone on a 6-inch screen to reveal a filtered shot list is cramped; hover + click on a large screen is natural |
| Side-by-side session comparison | Two shot charts next to each other require a wide viewport |
| Detailed shot timeline | A scrollable table with 200 rows is hostile on mobile but standard on desktop |
| Skill rating history per dimension | Multi-line chart with tooltip inspection requires pointer precision |
| Exported data or printable summaries | Browser print / PDF export is a native browser capability unavailable in-app |

### Relationship to the Existing Web Presence Plan

`upgrade-web-presence.md` describes Phase A (marketing site) and Phase B (dashboard) of the same Next.js project deployed to Vercel. This document is the detailed technical specification for Phase B. The project setup, Tailwind brand tokens, Supabase client utilities, middleware pattern, and deployment configuration in that document apply here without repetition. This document begins at the route level.

---

## 2. Prerequisites Checklist

The following conditions must all be true before dashboard work begins. None of these are negotiable — attempting to build the dashboard UI without them leads to building against a mock that drifts from the real schema.

### Infrastructure

- [ ] **Supabase project provisioned.** Tables `users`, `player_profiles`, `training_sessions`, `shot_records`, `goal_records` exist per the schema in `upgrade-backend-api.md` Section 3.2.
- [ ] **Row Level Security enabled on every table** with `own rows only` policies. Verify by attempting a PostgREST query with the anon key and no Auth header — it must return zero rows, not an error.
- [ ] **Supabase Auth active** with Sign in with Apple configured. The Apple Services ID, private key, and team ID must be entered in the Supabase dashboard under Authentication → Providers.
- [ ] **TypeScript types generated** from the live schema:

  ```bash
  npx supabase gen types typescript \
    --project-id YOUR_PROJECT_ID \
    > src/types/supabase.ts
  ```

  Commit this file and re-run it whenever the schema changes.

### iOS App

- [ ] **iOS app writing sessions to Supabase.** `APIService.syncSession(_:)` and `APIService.syncProfile(_:)` are implemented and wired into `SessionFinalizationCoordinator` (see `upgrade-backend-api.md` Section 7). Dashboard development against an empty database is wasted effort.
- [ ] **At least one week of real session data written to the cloud** before beginning chart work. Charts built against synthetic fixtures frequently need redesign when real data arrives with edge cases (zero-shot sessions, very long sessions, unusual zone distributions).
- [ ] **`shot_records.court_x` and `court_y` columns populated** with valid 0–1 normalised fractions. Verify with a quick PostgREST spot-check before building the shot chart.

### Web Project

- [ ] **Phase A marketing site shipped.** The Next.js project is deployed, the domain is live, and Vercel CI is working. This confirms the deployment pipeline before adding authenticated routes.
- [ ] **`NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`** set in Vercel environment variables for both Preview and Production environments.
- [ ] **`@supabase/supabase-js` and `@supabase/ssr` installed** and the server/browser client utilities from `upgrade-web-presence.md` Section 3.2 are in place (`src/lib/supabase/server.ts`, `src/lib/supabase/client.ts`).

### Database Functions

The following Supabase RPCs must be created before the corresponding views can be built:

```sql
-- Zone breakdown per session (used in session detail view)
create or replace function get_zone_breakdown(p_session_id uuid)
returns table(zone text, attempts bigint, makes bigint, fg_pct numeric)
language sql stable security definer
as $$
  select
    zone,
    count(*)                                                   as attempts,
    count(*) filter (where result = 'make')                    as makes,
    round(
      count(*) filter (where result = 'make')::numeric
      / nullif(count(*), 0) * 100
    , 1)                                                       as fg_pct
  from shot_records
  where session_id = p_session_id
  group by zone
  order by zone;
$$;

-- FG% trend over time for a user (used in progress view)
create or replace function get_fg_trend(
  p_user_id  uuid,
  p_since    timestamptz default now() - interval '90 days',
  p_until    timestamptz default now()
)
returns table(session_date date, fg_pct numeric, shot_count bigint)
language sql stable security definer
as $$
  select
    started_at::date        as session_date,
    round(avg(fg_percent), 1) as fg_pct,
    sum(shots_attempted)    as shot_count
  from training_sessions
  where user_id  = p_user_id
    and started_at >= p_since
    and started_at <= p_until
    and ended_at is not null
  group by started_at::date
  order by session_date;
$$;

-- Skill rating snapshots over time (used in progress view)
-- Assumes a skill_rating_snapshots table is written on each profile update.
-- If not yet implemented, the progress view can derive this from training_sessions.
```

---

## 3. Route Structure

The dashboard lives under the `/dashboard` prefix. All routes in this subtree require an authenticated session (enforced by middleware — see Section 4).

```
src/app/
├── login/
│   └── page.tsx                        # /login
├── auth/
│   └── callback/
│       └── route.ts                    # /auth/callback  (OAuth handler)
└── dashboard/
    ├── layout.tsx                      # Shared chrome: sidebar nav, user menu, sync indicator
    ├── page.tsx                        # /dashboard  — overview: summary cards, recent activity
    ├── sessions/
    │   ├── page.tsx                    # /dashboard/sessions  — paginated session list + filters
    │   └── [id]/
    │       └── page.tsx                # /dashboard/sessions/[id]  — shot chart + zone heat map
    ├── progress/
    │   └── page.tsx                    # /dashboard/progress  — FG% trend, skill ratings, volume
    ├── goals/
    │   └── page.tsx                    # /dashboard/goals  — active goals + completed history
    └── profile/
        └── page.tsx                    # /dashboard/profile  — display name, skill ratings snapshot
```

### Route Summary

| Route | Primary component | Data source |
|---|---|---|
| `/dashboard` | `OverviewPage` | Last 5 sessions + profile summary |
| `/dashboard/sessions` | `SessionListPage` | `training_sessions` (paginated) |
| `/dashboard/sessions/[id]` | `SessionDetailPage` | `training_sessions` + `shot_records` + `get_zone_breakdown` RPC |
| `/dashboard/progress` | `ProgressPage` | `get_fg_trend` RPC + profile skill ratings |
| `/dashboard/goals` | `GoalsPage` | `goal_records` |
| `/dashboard/profile` | `ProfilePage` | `player_profiles` |

---

## 4. Authentication Flow

### Package setup

```bash
npm install @supabase/supabase-js @supabase/ssr
```

The `@supabase/ssr` package provides cookie-based session management that works correctly across Next.js Server Components, Route Handlers, and middleware. Do not use `createClient` from `@supabase/supabase-js` directly in server code — it does not read or write cookies.

### Middleware — protecting all dashboard routes

```ts
// src/middleware.ts
import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

export async function middleware(request: NextRequest) {
  let response = NextResponse.next({ request });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  // Always call getUser() — this refreshes the session if the access token
  // has expired. Never use getSession() in middleware; it trusts the JWT
  // without server validation.
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const isDashboard = request.nextUrl.pathname.startsWith("/dashboard");

  if (!user && isDashboard) {
    const redirectUrl = new URL("/login", request.url);
    redirectUrl.searchParams.set("next", request.nextUrl.pathname);
    return NextResponse.redirect(redirectUrl);
  }

  // If user is already authenticated and hits /login, send them to the dashboard
  if (user && request.nextUrl.pathname === "/login") {
    return NextResponse.redirect(new URL("/dashboard", request.url));
  }

  return response;
}

export const config = {
  matcher: ["/dashboard/:path*", "/login"],
};
```

### Sign-in page with Sign in with Apple (web flow)

```tsx
// src/app/login/page.tsx
import { createClient } from "@/lib/supabase/server";
import { redirect } from "next/navigation";
import { AppleSignInButton } from "@/components/AppleSignInButton";

export default async function LoginPage({
  searchParams,
}: {
  searchParams: { next?: string };
}) {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  // Already signed in — skip the login page
  if (user) redirect(searchParams.next ?? "/dashboard");

  return (
    <main className="min-h-screen bg-gray-950 flex items-center justify-center px-4">
      <div className="w-full max-w-sm space-y-8">
        <div className="text-center">
          <h1 className="text-3xl font-display font-bold text-white">
            HoopTrack
          </h1>
          <p className="mt-2 text-gray-400">Sign in to view your dashboard</p>
        </div>
        {/* Apple sign-in is a Client Component — needs onClick for the OAuth redirect */}
        <AppleSignInButton nextPath={searchParams.next} />
      </div>
    </main>
  );
}
```

```tsx
// src/components/AppleSignInButton.tsx
"use client";
import { createClient } from "@/lib/supabase/client";

export function AppleSignInButton({ nextPath }: { nextPath?: string }) {
  const supabase = createClient();

  async function handleSignIn() {
    await supabase.auth.signInWithOAuth({
      provider: "apple",
      options: {
        redirectTo: `${window.location.origin}/auth/callback?next=${nextPath ?? "/dashboard"}`,
        // scopes: "name email"  — request name so player_profiles can be pre-filled
        scopes: "name email",
      },
    });
  }

  return (
    <button
      onClick={handleSignIn}
      className="w-full flex items-center justify-center gap-3 bg-white text-black font-semibold py-3 px-4 rounded-xl hover:bg-gray-100 transition-colors"
    >
      {/* Apple logo SVG */}
      <svg viewBox="0 0 814 1000" className="w-5 h-5" fill="currentColor">
        <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76 0-103.7 40.8-165.9 40.8s-105-57.8-155.5-127.4C46.7 790.7 0 663 0 541.8c0-207.5 135.4-317.7 268.5-317.7 99.8 0 184 65.6 246.9 65.6 59.2 0 152-65.6 269.1-65.6 34.4 0 121.6 3.1 187.7 111.2zM549.8 148.8c58.9-69.8 98.3-167.1 98.3-264.6 0-12.9-.8-25.9-2.4-36.4-94.5 3.9-207.4 63.9-274.8 144.9-51.8 61.4-100.6 155.5-100.6 255.1 0 14.4 1.6 28.7 2.4 33.2 6.3.8 16.6 2.4 26.9 2.4 85.3 0 189.8-56.9 250.2-134.6z" />
      </svg>
      Sign in with Apple
    </button>
  );
}
```

### Auth callback Route Handler

```ts
// src/app/auth/callback/route.ts
import { createClient } from "@/lib/supabase/server";
import { NextResponse } from "next/server";

export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const next = searchParams.get("next") ?? "/dashboard";

  if (code) {
    const supabase = createClient();
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  // Auth error — redirect to login with an error indicator
  return NextResponse.redirect(`${origin}/login?error=auth_failed`);
}
```

### Session cookies vs. local storage

Supabase Auth with `@supabase/ssr` stores the session in **HTTP-only cookies**, not `localStorage`. This is the correct choice for a web dashboard:

- The Next.js middleware can read cookies to authenticate Server Components and protect routes server-side. It cannot read `localStorage`.
- HTTP-only cookies are inaccessible to JavaScript, preventing XSS from stealing the session token.
- The cookie is set with `SameSite=Lax` and `Secure` (on HTTPS), which prevents CSRF in the common case.

Do not use `createBrowserClient` with the default `localStorage` persistence for any route that needs server-side authentication. The browser client (`src/lib/supabase/client.ts`) is reserved for client-side Realtime subscriptions inside Client Components.

---

## 5. Session List View — `/dashboard/sessions`

### Data shape

```ts
// What the session list table needs per row
type SessionRow = {
  id: string;
  started_at: string;        // ISO timestamp
  ended_at: string | null;
  drill_type: string;
  named_drill: string | null;
  shots_attempted: number;
  shots_made: number;
  fg_percent: number;
  duration_seconds: number;
  consistency_score: number | null;
};
```

### Server Component with initial data + filter state

The page is a Server Component that performs the initial paginated query. Filters are encoded in URL search params so they are shareable and survive a page refresh. Client-side filter changes update the URL, triggering a server navigation that re-fetches data — no client-side state management library needed.

```tsx
// src/app/dashboard/sessions/page.tsx
import { createClient } from "@/lib/supabase/server";
import { SessionTable } from "@/components/SessionTable";
import { SessionFilters } from "@/components/SessionFilters";
import type { Database } from "@/types/supabase";

type PageProps = {
  searchParams: {
    from?: string;
    to?: string;
    drill?: string;
    page?: string;
  };
};

const PAGE_SIZE = 25;

export default async function SessionsPage({ searchParams }: PageProps) {
  const supabase = createClient();
  const page = Number(searchParams.page ?? 1);
  const offset = (page - 1) * PAGE_SIZE;

  let query = supabase
    .from("training_sessions")
    .select("id, started_at, ended_at, drill_type, named_drill, shots_attempted, shots_made, fg_percent, duration_seconds, consistency_score", {
      count: "exact",
    })
    .not("ended_at", "is", null)           // exclude in-progress sessions
    .order("started_at", { ascending: false })
    .range(offset, offset + PAGE_SIZE - 1);

  if (searchParams.from) {
    query = query.gte("started_at", searchParams.from);
  }
  if (searchParams.to) {
    // Add one day to make the 'to' date inclusive
    const toDate = new Date(searchParams.to);
    toDate.setDate(toDate.getDate() + 1);
    query = query.lt("started_at", toDate.toISOString());
  }
  if (searchParams.drill && searchParams.drill !== "all") {
    query = query.eq("drill_type", searchParams.drill);
  }

  const { data: sessions, count, error } = await query;

  if (error) throw new Error(error.message);

  const totalPages = Math.ceil((count ?? 0) / PAGE_SIZE);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">Sessions</h1>
        <span className="text-sm text-gray-400">
          {count} total
        </span>
      </div>

      {/* Filter bar — Client Component, updates URL search params */}
      <SessionFilters
        currentFrom={searchParams.from}
        currentTo={searchParams.to}
        currentDrill={searchParams.drill}
      />

      {/* Session table — Server Component, receives data as props */}
      <SessionTable sessions={sessions ?? []} />

      {/* Pagination */}
      {totalPages > 1 && (
        <Pagination currentPage={page} totalPages={totalPages} />
      )}
    </div>
  );
}
```

### SessionFilters Client Component

```tsx
// src/components/SessionFilters.tsx
"use client";
import { useRouter, usePathname, useSearchParams } from "next/navigation";
import { useCallback } from "react";

const DRILL_TYPES = [
  { value: "all", label: "All drill types" },
  { value: "shot_science", label: "Shot Science" },
  { value: "dribble", label: "Dribble Drill" },
  { value: "agility", label: "Agility" },
  { value: "free_shoot", label: "Free Shoot" },
];

export function SessionFilters({
  currentFrom,
  currentTo,
  currentDrill,
}: {
  currentFrom?: string;
  currentTo?: string;
  currentDrill?: string;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();

  const updateFilter = useCallback(
    (key: string, value: string) => {
      const params = new URLSearchParams(searchParams.toString());
      if (value) {
        params.set(key, value);
      } else {
        params.delete(key);
      }
      // Reset to page 1 when filters change
      params.delete("page");
      router.push(`${pathname}?${params.toString()}`);
    },
    [router, pathname, searchParams]
  );

  return (
    <div className="flex flex-wrap gap-3">
      <input
        type="date"
        value={currentFrom ?? ""}
        onChange={(e) => updateFilter("from", e.target.value)}
        className="bg-gray-800 border border-gray-700 text-white rounded-lg px-3 py-2 text-sm"
        aria-label="From date"
      />
      <input
        type="date"
        value={currentTo ?? ""}
        onChange={(e) => updateFilter("to", e.target.value)}
        className="bg-gray-800 border border-gray-700 text-white rounded-lg px-3 py-2 text-sm"
        aria-label="To date"
      />
      <select
        value={currentDrill ?? "all"}
        onChange={(e) => updateFilter("drill", e.target.value)}
        className="bg-gray-800 border border-gray-700 text-white rounded-lg px-3 py-2 text-sm"
        aria-label="Drill type"
      >
        {DRILL_TYPES.map((d) => (
          <option key={d.value} value={d.value}>
            {d.label}
          </option>
        ))}
      </select>
    </div>
  );
}
```

### Session table row

Each row links to `/dashboard/sessions/[id]`. Display FG% as a coloured pill: green above 50%, amber 35–50%, red below 35%. Show duration as `mm:ss`. Missing `consistency_score` is displayed as `—`.

---

## 6. Session Detail View — `/dashboard/sessions/[id]`

### Layout

The detail page uses a two-column layout on wide viewports: shot chart on the left, metrics panel on the right. On narrow viewports they stack vertically.

```tsx
// src/app/dashboard/sessions/[id]/page.tsx
import { createClient } from "@/lib/supabase/server";
import { notFound } from "next/navigation";
import { ShotChart } from "@/components/ShotChart";
import { ZoneHeatMap } from "@/components/ZoneHeatMap";
import { ShotSciencePanel } from "@/components/ShotSciencePanel";
import { ShotTimeline } from "@/components/ShotTimeline";

export default async function SessionDetailPage({
  params,
}: {
  params: { id: string };
}) {
  const supabase = createClient();

  // Parallel fetch — session metadata and shot records
  const [sessionResult, shotsResult, zoneResult] = await Promise.all([
    supabase
      .from("training_sessions")
      .select("*")
      .eq("id", params.id)
      .single(),
    supabase
      .from("shot_records")
      .select("id, court_x, court_y, result, zone, release_angle_deg, release_time_ms, timestamp, sequence_index")
      .eq("session_id", params.id)
      .order("sequence_index", { ascending: true }),
    supabase.rpc("get_zone_breakdown", { p_session_id: params.id }),
  ]);

  if (sessionResult.error || !sessionResult.data) notFound();

  const session = sessionResult.data;
  const shots = shotsResult.data ?? [];
  const zoneBreakdown = zoneResult.data ?? [];

  return (
    <div className="space-y-6">
      <SessionDetailHeader session={session} />

      <div className="grid grid-cols-1 xl:grid-cols-2 gap-6">
        {/* Left: shot chart with zone heat map overlay toggle */}
        <div className="bg-gray-900 rounded-2xl p-4 space-y-4">
          <h2 className="text-lg font-semibold text-white">Shot Chart</h2>
          <ShotChart shots={shots} />
          <ZoneHeatMap zones={zoneBreakdown} />
        </div>

        {/* Right: metrics panel */}
        <div className="space-y-4">
          <ShotSciencePanel session={session} />
          <ShotTimeline shots={shots} />
        </div>
      </div>
    </div>
  );
}
```

### Shot Science metrics panel

The `ShotSciencePanel` component displays:

- FG% (large, coloured by performance band)
- Average release angle (degrees) with reference band (ideal: 45–55°)
- Average release time (ms)
- Consistency score (0–100) with a horizontal gauge
- Longest make streak
- Shot count breakdown: makes / attempts

---

## 7. Shot Chart Implementation

### `ShotChart` SVG component

The court is drawn in SVG using real NBA half-court proportions (47 ft × 50 ft). All coordinates are normalised 0–1 fractions so the component is resolution-independent.

```tsx
// src/components/ShotChart.tsx
"use client";
import { useState } from "react";
import type { ShotRecord } from "@/types/hooptrack";

type Props = {
  shots: Pick<ShotRecord, "id" | "court_x" | "court_y" | "result" | "zone" | "release_angle_deg">[];
};

// SVG canvas dimensions — arbitrary; the component scales via CSS
const W = 500;
const H = 470;

// Helpers to map 0–1 fraction → SVG pixel
const sx = (x: number) => x * W;
const sy = (y: number) => y * H;

export function ShotChart({ shots }: Props) {
  const [tooltip, setTooltip] = useState<{
    shot: Props["shots"][number];
    svgX: number;
    svgY: number;
  } | null>(null);

  return (
    <div className="relative">
      <svg
        viewBox={`0 0 ${W} ${H}`}
        className="w-full rounded-xl border border-gray-700"
        aria-label="Shot chart — court diagram with shot locations"
      >
        {/* ── Court surface ── */}
        <rect width={W} height={H} fill="#C8A96E" rx={4} />

        {/* ── Baseline (bottom of the SVG = basket end) ── */}
        <line x1={0} y1={H} x2={W} y2={H} stroke="white" strokeWidth={2} />

        {/* ── Sidelines ── */}
        <line x1={0} y1={0} x2={0} y2={H} stroke="white" strokeWidth={2} />
        <line x1={W} y1={0} x2={W} y2={H} stroke="white" strokeWidth={2} />

        {/* ── Paint / key (16 ft wide, 19 ft deep on NBA court) ── */}
        {/* Normalised: width = 16/50 = 0.32; height = 19/47 = 0.404 */}
        <rect
          x={sx(0.34)}
          y={sy(0)}
          width={sx(0.32)}
          height={sy(0.404)}
          fill="none"
          stroke="white"
          strokeWidth={2}
        />

        {/* ── Free throw circle (radius 6 ft = 6/50 = 0.12 of width) ── */}
        <circle
          cx={sx(0.5)}
          cy={sy(0.404)}
          r={sx(0.12)}
          fill="none"
          stroke="white"
          strokeWidth={2}
        />

        {/* ── Basket ── */}
        <circle
          cx={sx(0.5)}
          cy={sy(0.05)}
          r={6}
          fill="none"
          stroke="white"
          strokeWidth={2}
        />
        <circle cx={sx(0.5)} cy={sy(0.05)} r={2} fill="white" />

        {/* ── Restricted area arc (4 ft radius from basket) ── */}
        {/* 4/50 = 0.08 width units */}
        <path
          d={`M ${sx(0.42)} ${sy(0)} A ${sx(0.08)} ${sx(0.08)} 0 0 1 ${sx(0.58)} ${sy(0)}`}
          fill="none"
          stroke="white"
          strokeWidth={1.5}
          strokeDasharray="4 4"
        />

        {/* ── Three-point arc ──
             NBA three-point radius = 23.75 ft from basket.
             Basket is at (0.5, 0.05). Radius in SVG = 23.75/50 * W ≈ 237.5px.
             Corner three lines: x = 3 ft from sideline = 0.06 of W, y from 0 to 14% */}
        <line x1={sx(0.06)} y1={sy(0)} x2={sx(0.06)} y2={sy(0.14)} stroke="white" strokeWidth={2} />
        <line x1={sx(0.94)} y1={sy(0)} x2={sx(0.94)} y2={sy(0.14)} stroke="white" strokeWidth={2} />
        {/* Arc connecting the two corner lines */}
        <path
          d={describeThreePointArc(W, H)}
          fill="none"
          stroke="white"
          strokeWidth={2}
        />

        {/* ── Half-court line ── */}
        <line x1={0} y1={sy(1)} x2={W} y2={sy(1)} stroke="white" strokeWidth={1} strokeOpacity={0.3} />

        {/* ── Shot dots ── */}
        {shots.map((shot) => (
          <circle
            key={shot.id}
            cx={sx(shot.court_x)}
            cy={sy(shot.court_y)}
            r={7}
            fill={shot.result === "make" ? "#22c55e" : "#ef4444"}
            fillOpacity={0.8}
            stroke="white"
            strokeWidth={1}
            className="cursor-pointer transition-opacity hover:opacity-100"
            onMouseEnter={(e) =>
              setTooltip({
                shot,
                svgX: sx(shot.court_x),
                svgY: sy(shot.court_y),
              })
            }
            onMouseLeave={() => setTooltip(null)}
            aria-label={`${shot.result} — ${shot.zone} — angle ${shot.release_angle_deg?.toFixed(1) ?? "?"}°`}
          />
        ))}
      </svg>

      {/* Tooltip */}
      {tooltip && (
        <ShotTooltip shot={tooltip.shot} svgX={tooltip.svgX} svgY={tooltip.svgY} svgW={W} svgH={H} />
      )}

      {/* Legend */}
      <div className="flex gap-4 mt-3 text-sm text-gray-400">
        <span className="flex items-center gap-1.5">
          <span className="w-3 h-3 rounded-full bg-green-500 inline-block" />
          Made ({shots.filter((s) => s.result === "make").length})
        </span>
        <span className="flex items-center gap-1.5">
          <span className="w-3 h-3 rounded-full bg-red-500 inline-block" />
          Missed ({shots.filter((s) => s.result !== "make").length})
        </span>
      </div>
    </div>
  );
}

/** Describe the three-point arc as an SVG path.
 *  Basket position: (0.5 * W, 0.05 * H)
 *  Arc radius: 23.75 ft on a 50 ft wide court → 0.475 * W
 *  Corner three y cutoff: ≈ 0.14 * H
 */
function describeThreePointArc(W: number, H: number): string {
  const cx = 0.5 * W;
  const cy = 0.05 * H;
  const r = 0.475 * W;
  const cornerY = 0.14 * H;

  // Find x coordinates where the arc intersects y = cornerY
  const dy = cornerY - cy;
  const dx = Math.sqrt(Math.max(0, r * r - dy * dy));
  const x1 = cx - dx; // left side
  const x2 = cx + dx; // right side

  return `M ${x1} ${cornerY} A ${r} ${r} 0 0 1 ${x2} ${cornerY}`;
}
```

### Zone heat map overlay

The zone heat map is a separate SVG layer rendered beneath the shot dots. Each zone polygon is filled with a colour interpolated from cool (low FG%) to warm (high FG%) based on the `get_zone_breakdown` RPC result.

```tsx
// src/components/ZoneHeatMap.tsx
"use client";

type ZoneBreakdown = {
  zone: string;
  attempts: number;
  makes: number;
  fg_pct: number | null;
};

// Maps zone name → normalised SVG polygon points (x y pairs, 0–1 space)
const ZONE_POLYGONS: Record<string, string> = {
  paint:              "0.34,0 0.66,0 0.66,0.404 0.34,0.404",
  free_throw:         "0.34,0.404 0.66,0.404 0.66,0.55 0.34,0.55",
  corner_three_left:  "0,0 0.06,0 0.06,0.14 0,0.14",
  corner_three_right: "0.94,0 1,0 1,0.14 0.94,0.14",
  // mid-range and above-break zones approximated as polygons
  mid_range_left:     "0,0.14 0.34,0.14 0.34,0.65 0,0.65",
  mid_range_right:    "0.66,0.14 1,0.14 1,0.65 0.66,0.65",
  mid_range_center:   "0.34,0.55 0.66,0.55 0.66,0.65 0.34,0.65",
  above_break_three:  "0.06,0.14 0.94,0.14 0.94,0.95 0.06,0.95",
};

function fgPctToColor(fgPct: number | null): string {
  if (fgPct === null) return "rgba(150,150,150,0.15)";
  // 0% → blue, 50% → yellow, 100% → red (hot zone)
  const t = Math.min(1, fgPct / 100);
  if (t < 0.5) {
    // Blue → Yellow
    const r = Math.round(t * 2 * 255);
    return `rgba(${r},${Math.round(t * 2 * 200)},${Math.round((1 - t * 2) * 255)},0.35)`;
  } else {
    // Yellow → Red
    const s = (t - 0.5) * 2;
    return `rgba(255,${Math.round((1 - s) * 200)},0,0.35)`;
  }
}

type Props = {
  zones: ZoneBreakdown[];
  svgW?: number;
  svgH?: number;
};

export function ZoneHeatMap({ zones, svgW = 500, svgH = 470 }: Props) {
  const byZone = Object.fromEntries(zones.map((z) => [z.zone, z]));

  return (
    <div className="mt-2">
      <svg viewBox={`0 0 ${svgW} ${svgH}`} className="w-full rounded-xl">
        {Object.entries(ZONE_POLYGONS).map(([zone, points]) => {
          const data = byZone[zone];
          const scaledPoints = points
            .split(" ")
            .map((pair) => {
              const [x, y] = pair.split(",").map(Number);
              return `${x * svgW},${y * svgH}`;
            })
            .join(" ");

          return (
            <polygon
              key={zone}
              points={scaledPoints}
              fill={fgPctToColor(data?.fg_pct ?? null)}
              stroke="white"
              strokeWidth={1}
              strokeOpacity={0.3}
            >
              <title>
                {zone.replace(/_/g, " ")}: {data ? `${data.fg_pct}% (${data.makes}/${data.attempts})` : "No shots"}
              </title>
            </polygon>
          );
        })}
      </svg>

      {/* Zone breakdown table below the heat map */}
      <table className="w-full text-sm mt-3 text-gray-300">
        <thead>
          <tr className="text-gray-500 border-b border-gray-800">
            <th className="text-left pb-2">Zone</th>
            <th className="text-right pb-2">Attempts</th>
            <th className="text-right pb-2">Makes</th>
            <th className="text-right pb-2">FG%</th>
          </tr>
        </thead>
        <tbody>
          {zones.map((z) => (
            <tr key={z.zone} className="border-b border-gray-800/50">
              <td className="py-1.5 capitalize">{z.zone.replace(/_/g, " ")}</td>
              <td className="text-right">{z.attempts}</td>
              <td className="text-right">{z.makes}</td>
              <td className="text-right font-medium">
                {z.fg_pct !== null ? `${z.fg_pct}%` : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
```

### Shot timeline

The timeline renders shots in sequence order as a scrollable horizontal strip. Each shot is a small coloured circle with a tooltip showing the timestamp and zone. Makes are green, misses red. The strip gives a visual sense of streaks and cold patches within the session.

---

## 8. Progress View — `/dashboard/progress`

### Date range selector

The progress view defaults to the last 90 days. A selector allows switching to 30 days, 90 days, 6 months, 1 year, or all time. As with the session list, the selected range is encoded in URL search params.

```tsx
// src/app/dashboard/progress/page.tsx
import { createClient } from "@/lib/supabase/server";
import { FGTrendChart } from "@/components/FGTrendChart";
import { SkillRadarChart } from "@/components/SkillRadarChart";
import { VolumeBarChart } from "@/components/VolumeBarChart";
import { ZoneDoughnut } from "@/components/ZoneDoughnut";
import { DateRangeSelector } from "@/components/DateRangeSelector";

const RANGE_DAYS: Record<string, number> = {
  "30d": 30,
  "90d": 90,
  "6m": 180,
  "1y": 365,
  all: 0,
};

export default async function ProgressPage({
  searchParams,
}: {
  searchParams: { range?: string };
}) {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const range = searchParams.range ?? "90d";
  const days = RANGE_DAYS[range] ?? 90;

  const since =
    days > 0
      ? new Date(Date.now() - days * 86400 * 1000).toISOString()
      : new Date(0).toISOString();

  const [trendResult, profileResult, aggregateResult] = await Promise.all([
    supabase.rpc("get_fg_trend", {
      p_user_id: user!.id,
      p_since: since,
      p_until: new Date().toISOString(),
    }),
    supabase
      .from("player_profiles")
      .select("*")
      .eq("user_id", user!.id)
      .single(),
    supabase
      .from("shot_records")
      .select("zone, result")
      .eq("user_id", user!.id)
      .gte("timestamp", since),
  ]);

  return (
    <div className="space-y-8">
      <div className="flex items-center justify-between">
        <h1 className="text-2xl font-bold text-white">Progress</h1>
        <DateRangeSelector current={range} />
      </div>

      {/* FG% trend line chart */}
      <section>
        <h2 className="text-lg font-semibold text-white mb-3">FG% Over Time</h2>
        <FGTrendChart data={trendResult.data ?? []} />
      </section>

      {/* Two-column: skill radar + zone doughnut */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <section>
          <h2 className="text-lg font-semibold text-white mb-3">Skill Ratings</h2>
          {profileResult.data && (
            <SkillRadarChart profile={profileResult.data} />
          )}
        </section>
        <section>
          <h2 className="text-lg font-semibold text-white mb-3">Shot Distribution by Zone</h2>
          <ZoneDoughnut shots={aggregateResult.data ?? []} />
        </section>
      </div>

      {/* Weekly volume bar chart */}
      <section>
        <h2 className="text-lg font-semibold text-white mb-3">Weekly Shot Volume</h2>
        <VolumeBarChart data={trendResult.data ?? []} />
      </section>
    </div>
  );
}
```

### FG% trend line chart

```tsx
// src/components/FGTrendChart.tsx
"use client";
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ReferenceLine,
  ResponsiveContainer,
} from "recharts";
import { format } from "date-fns";

type DataPoint = {
  session_date: string;
  fg_pct: number;
  shot_count: number;
};

export function FGTrendChart({ data }: { data: DataPoint[] }) {
  const formatted = data.map((d) => ({
    ...d,
    label: format(new Date(d.session_date), "MMM d"),
  }));

  return (
    <div className="bg-gray-900 rounded-2xl p-4">
      <ResponsiveContainer width="100%" height={280}>
        <LineChart data={formatted} margin={{ top: 8, right: 16, bottom: 0, left: 0 }}>
          <CartesianGrid strokeDasharray="3 3" stroke="#1F2937" />
          <XAxis
            dataKey="label"
            tick={{ fill: "#6B7280", fontSize: 11 }}
            tickLine={false}
            axisLine={false}
          />
          <YAxis
            domain={[0, 100]}
            tickFormatter={(v) => `${v}%`}
            tick={{ fill: "#6B7280", fontSize: 11 }}
            tickLine={false}
            axisLine={false}
            width={40}
          />
          {/* Reference line at 50% FG — typical mid-range average */}
          <ReferenceLine y={50} stroke="#374151" strokeDasharray="4 4" />
          <Tooltip
            content={({ active, payload, label }) => {
              if (!active || !payload?.length) return null;
              const d = payload[0].payload as DataPoint & { label: string };
              return (
                <div className="bg-gray-800 border border-gray-700 rounded-lg p-3 text-sm shadow-xl">
                  <p className="text-gray-400">{label}</p>
                  <p className="text-white font-semibold">
                    {d.fg_pct.toFixed(1)}% FG
                  </p>
                  <p className="text-gray-400">{d.shot_count} shots</p>
                </div>
              );
            }}
          />
          <Line
            type="monotone"
            dataKey="fg_pct"
            stroke="#FF6B35"
            strokeWidth={2.5}
            dot={{ fill: "#FF6B35", r: 3, strokeWidth: 0 }}
            activeDot={{ r: 5, fill: "#FF6B35" }}
            connectNulls
          />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}
```

### Skill rating history multi-line chart

The `player_profiles` table stores the current skill ratings. To show _history_, a `skill_rating_snapshots` table must be written each time `player_profiles` is updated from iOS. If that table does not yet exist, the progress view can show current ratings only as a radar chart, deferring the multi-line history view.

```sql
-- Schema addition — write one row per profile update
create table skill_rating_snapshots (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references users(id) on delete cascade,
  snapshot_date  date not null default current_date,
  rating_shooting         double precision not null,
  rating_ball_handling    double precision not null,
  rating_athleticism      double precision not null,
  rating_consistency      double precision not null,
  rating_volume           double precision not null
);

alter table skill_rating_snapshots enable row level security;

create policy "own rows only" on skill_rating_snapshots
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create index on skill_rating_snapshots (user_id, snapshot_date desc);
```

iOS `APIService.syncProfile(_:)` should be extended to also upsert a row into `skill_rating_snapshots` using `(user_id, snapshot_date)` as the conflict target, so at most one snapshot per day is written.

### Weekly volume bar chart

Derived from `get_fg_trend` output: sum `shot_count` by ISO week number. Recharts `BarChart` with one bar per week. Colour intensity proportional to volume.

### Zone doughnut

A `PieChart` from Recharts showing shot attempts by zone as proportional arcs. Clicking a segment filters the shot chart (if combined on one page) or links to `/dashboard/sessions` pre-filtered to that zone.

---

## 9. Goals View — `/dashboard/goals`

```tsx
// src/app/dashboard/goals/page.tsx
import { createClient } from "@/lib/supabase/server";
import { GoalCard } from "@/components/GoalCard";

export default async function GoalsPage() {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: goals } = await supabase
    .from("goal_records")
    .select("*")
    .eq("user_id", user!.id)
    .order("created_at", { ascending: false });

  const active = goals?.filter((g) => !g.is_achieved) ?? [];
  const completed = goals?.filter((g) => g.is_achieved) ?? [];

  return (
    <div className="space-y-8">
      <h1 className="text-2xl font-bold text-white">Goals</h1>

      {active.length > 0 && (
        <section>
          <h2 className="text-lg font-semibold text-white mb-4">Active Goals</h2>
          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            {active.map((goal) => (
              <GoalCard key={goal.id} goal={goal} />
            ))}
          </div>
        </section>
      )}

      {completed.length > 0 && (
        <section>
          <h2 className="text-lg font-semibold text-gray-400 mb-4">
            Completed ({completed.length})
          </h2>
          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            {completed.map((goal) => (
              <GoalCard key={goal.id} goal={goal} completed />
            ))}
          </div>
        </section>
      )}

      {(goals?.length ?? 0) === 0 && (
        <p className="text-gray-500 text-sm">
          No goals yet. Create goals in the HoopTrack app and they will appear here.
        </p>
      )}
    </div>
  );
}
```

### GoalCard component

Shows: goal title, skill dimension, target value vs. current value, a linear progress bar (`current_value / target_value`), target date (if set), and an achieved badge with `achieved_at` date for completed goals. The progress bar is colour-coded: grey for 0–25%, amber for 25–75%, green for 75–100%.

---

## 10. Shared TypeScript Types

### Mirror of Swift models

These types live at `src/types/hooptrack.ts`. They are hand-maintained to mirror the Swift data models. The Supabase generated types in `src/types/supabase.ts` cover raw database rows; these types represent the logical application model with any transformations applied.

```ts
// src/types/hooptrack.ts

export type ShotResult = "make" | "miss";

export type CourtZone =
  | "paint"
  | "free_throw"
  | "corner_three_left"
  | "corner_three_right"
  | "mid_range_left"
  | "mid_range_right"
  | "mid_range_center"
  | "above_break_three";

export type DrillType =
  | "shot_science"
  | "dribble"
  | "agility"
  | "free_shoot";

export interface ShotRecord {
  id: string;
  session_id: string;
  user_id: string;
  timestamp: string;
  sequence_index: number;
  /** Normalised 0–1 fraction of court width from left sideline */
  court_x: number;
  /** Normalised 0–1 fraction of court length from baseline */
  court_y: number;
  result: ShotResult;
  zone: CourtZone;
  shot_type: string;
  release_angle_deg: number | null;
  release_time_ms: number | null;
  vertical_jump_cm: number | null;
  shot_speed_mph: number | null;
  is_user_corrected: boolean;
}

export interface TrainingSession {
  id: string;
  user_id: string;
  started_at: string;
  ended_at: string | null;
  duration_seconds: number;
  drill_type: DrillType;
  named_drill: string | null;
  shots_attempted: number;
  shots_made: number;
  fg_percent: number;
  avg_release_angle_deg: number | null;
  avg_release_time_ms: number | null;
  consistency_score: number | null;
  longest_make_streak: number;
  notes: string;
}

export interface SkillRatings {
  /** 0–100 composite rating */
  overall: number;
  shooting: number;
  ball_handling: number;
  athleticism: number;
  consistency: number;
  volume: number;
}

export interface PlayerProfile {
  id: string;
  user_id: string;
  career_shots_attempted: number;
  career_shots_made: number;
  total_session_count: number;
  total_training_minutes: number;
  current_streak_days: number;
  longest_streak_days: number;
  last_session_date: string | null;
  ratings: SkillRatings;
  pr_best_fg_percent_session: number;
  pr_most_makes_session: number;
  pr_best_consistency_score: number | null;
}

export interface GoalRecord {
  id: string;
  user_id: string;
  created_at: string;
  target_date: string | null;
  title: string;
  skill: string;
  metric: string;
  target_value: number;
  baseline_value: number;
  current_value: number;
  is_achieved: boolean;
  achieved_at: string | null;
}

export interface ZoneBreakdown {
  zone: CourtZone;
  attempts: number;
  makes: number;
  fg_pct: number | null;
}

export interface FGTrendPoint {
  session_date: string;
  fg_pct: number;
  shot_count: number;
}
```

### Supabase generated types integration

```bash
# Run whenever the Postgres schema changes
npx supabase gen types typescript \
  --project-id YOUR_PROJECT_ID \
  --schema public \
  > src/types/supabase.ts
```

The generated `Database` type is used to parameterise the Supabase client:

```ts
// src/lib/supabase/server.ts
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { Database } from "@/types/supabase";

export function createClient() {
  const cookieStore = cookies();
  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() { return cookieStore.getAll(); },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) =>
            cookieStore.set(name, value, options)
          );
        },
      },
    }
  );
}
```

This gives full TypeScript inference on `.from("training_sessions").select(...)` — column names, types, and return shapes are all inferred from the generated schema.

---

## 11. Data Fetching Strategy

### React Server Components for initial data

All dashboard pages are Server Components by default in the Next.js App Router. Initial data is fetched on the server, reducing the time-to-first-meaningful-paint and avoiding client-side waterfall requests. The pattern is: create a server-side Supabase client, `await` the query, pass data as props to child components.

Server Components have two advantages specific to this dashboard:

1. **RLS is enforced server-side.** The server client reads the session cookie to authenticate the user before querying Supabase. There is no window where un-authenticated data could appear in the browser.
2. **No client-side loading states for the initial render.** The page HTML arrives with data already populated; no spinner appears on first load.

Child components that need interactivity (filter controls, chart tooltips, hover states) are Client Components marked with `"use client"`. They receive data as props from the parent Server Component.

### Client-side Supabase Realtime for live session updates

When a user opens a session detail page while a session is actively in progress on their phone, new shots should appear on the chart without requiring a refresh. This uses a Supabase Realtime subscription in a Client Component:

```tsx
// src/hooks/useRealtimeShots.ts
"use client";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import type { ShotRecord } from "@/types/hooptrack";

export function useRealtimeShots(
  sessionId: string,
  initialShots: ShotRecord[]
) {
  const [shots, setShots] = useState<ShotRecord[]>(initialShots);
  const supabase = createClient();

  useEffect(() => {
    const channel = supabase
      .channel(`session-shots-${sessionId}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "shot_records",
          filter: `session_id=eq.${sessionId}`,
        },
        (payload) => {
          setShots((prev) => {
            // Guard against duplicates if the initial fetch and the subscription overlap
            if (prev.find((s) => s.id === payload.new.id)) return prev;
            return [...prev, payload.new as ShotRecord].sort(
              (a, b) => a.sequence_index - b.sequence_index
            );
          });
        }
      )
      .subscribe();

    return () => {
      supabase.removeChannel(channel);
    };
  }, [sessionId, supabase]);

  return shots;
}
```

Usage in the session detail page: the Server Component fetches initial shots; a thin Client Component wrapper subscribes to Realtime and merges new arrivals:

```tsx
// src/components/LiveShotChart.tsx
"use client";
import { useRealtimeShots } from "@/hooks/useRealtimeShots";
import { ShotChart } from "@/components/ShotChart";
import type { ShotRecord } from "@/types/hooptrack";

export function LiveShotChart({
  sessionId,
  initialShots,
  isActive,
}: {
  sessionId: string;
  initialShots: ShotRecord[];
  isActive: boolean;
}) {
  // Only subscribe if the session is still in progress
  const shots = isActive
    ? useRealtimeShots(sessionId, initialShots)
    : initialShots;

  return (
    <div>
      {isActive && (
        <div className="flex items-center gap-2 text-sm text-green-400 mb-3">
          <span className="w-2 h-2 rounded-full bg-green-400 animate-pulse" />
          Live session in progress
        </div>
      )}
      <ShotChart shots={shots} />
    </div>
  );
}
```

### Server Actions for mutations

The dashboard is primarily read-only, but the goals view may eventually support creating or updating goals from the web. Use Next.js Server Actions for these mutations rather than a separate API route:

```ts
// src/app/dashboard/goals/actions.ts
"use server";
import { createClient } from "@/lib/supabase/server";
import { revalidatePath } from "next/cache";

export async function markGoalAchieved(goalId: string) {
  const supabase = createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) throw new Error("Unauthenticated");

  const { error } = await supabase
    .from("goal_records")
    .update({ is_achieved: true, achieved_at: new Date().toISOString() })
    .eq("id", goalId)
    .eq("user_id", user.id); // Belt-and-suspenders: RLS also enforces this

  if (error) throw new Error(error.message);

  revalidatePath("/dashboard/goals");
}
```

---

## 12. Performance

### Pagination for session history

Sessions are fetched in pages of 25 using PostgREST range queries (`.range(offset, offset + PAGE_SIZE - 1)`). The `count: "exact"` option returns the total count in one round trip. Avoid `count: "exact"` on `shot_records` — that table will be large; use the pre-computed `shots_attempted` column on `training_sessions` instead.

```sql
-- Index that makes paginated session queries fast
create index on training_sessions (user_id, started_at desc);
-- Already defined in upgrade-backend-api.md — verify it exists
```

### Virtual scrolling for shot lists

A session with 300+ shots cannot be rendered as 300 DOM nodes without jank. Use `@tanstack/react-virtual` for the shot timeline inside the session detail view:

```tsx
"use client";
import { useVirtualizer } from "@tanstack/react-virtual";
import { useRef } from "react";
import type { ShotRecord } from "@/types/hooptrack";

export function ShotTimeline({ shots }: { shots: ShotRecord[] }) {
  const parentRef = useRef<HTMLDivElement>(null);

  const virtualizer = useVirtualizer({
    count: shots.length,
    getScrollElement: () => parentRef.current,
    estimateSize: () => 48,     // row height in px
    overscan: 10,
  });

  return (
    <div
      ref={parentRef}
      className="h-64 overflow-auto bg-gray-900 rounded-xl"
    >
      <div
        style={{ height: virtualizer.getTotalSize() }}
        className="relative w-full"
      >
        {virtualizer.getVirtualItems().map((virtualItem) => {
          const shot = shots[virtualItem.index];
          return (
            <div
              key={shot.id}
              style={{
                position: "absolute",
                top: 0,
                transform: `translateY(${virtualItem.start}px)`,
                height: virtualItem.size,
              }}
              className="w-full flex items-center gap-3 px-4 border-b border-gray-800 text-sm"
            >
              <span
                className={`w-2.5 h-2.5 rounded-full flex-shrink-0 ${
                  shot.result === "make" ? "bg-green-500" : "bg-red-500"
                }`}
              />
              <span className="text-gray-400 w-8 text-right">
                #{shot.sequence_index + 1}
              </span>
              <span className="capitalize text-gray-300">
                {shot.zone.replace(/_/g, " ")}
              </span>
              {shot.release_angle_deg !== null && (
                <span className="text-gray-500 ml-auto">
                  {shot.release_angle_deg.toFixed(1)}°
                </span>
              )}
            </div>
          );
        })}
      </div>
    </div>
  );
}
```

Install: `npm install @tanstack/react-virtual`

### Chart data downsampling for multi-month trend views

When the FG% trend view covers 12 months of daily data, Recharts renders 365 points. Beyond approximately 150 points on a line chart, individual points are visually indistinguishable and the SVG path becomes computationally expensive. Downsample to weekly averages in the `get_fg_trend` RPC when the date range exceeds 90 days:

```sql
-- Extended version of get_fg_trend with bucketing
create or replace function get_fg_trend(
  p_user_id  uuid,
  p_since    timestamptz default now() - interval '90 days',
  p_until    timestamptz default now()
)
returns table(session_date date, fg_pct numeric, shot_count bigint)
language sql stable security definer
as $$
  select
    -- Weekly bucket when range > 90 days, daily otherwise
    case
      when (p_until - p_since) > interval '90 days'
        then date_trunc('week', started_at)::date
      else started_at::date
    end                         as session_date,
    round(avg(fg_percent), 1)   as fg_pct,
    sum(shots_attempted)        as shot_count
  from training_sessions
  where user_id    = p_user_id
    and started_at >= p_since
    and started_at <= p_until
    and ended_at   is not null
  group by 1
  order by 1;
$$;
```

This keeps chart data under 60 points regardless of the date range, ensuring smooth rendering without any client-side processing.

### Avoiding N+1 queries

Never fetch sessions in a list and then make a separate query per session to get shot counts. The `shots_attempted` column on `training_sessions` is the correct source for shot counts in the list view — it is a pre-computed integer, not a join. Use it. Only fetch `shot_records` when the user navigates to a session detail page.

---

## 13. Coach Access Preview

### Route structure anticipation

The current route structure is athlete-centric: all routes implicitly scope to `auth.uid()`. The coach portal requires viewing another user's data. The structure is designed so that adding coach access requires only adding a new branch, not restructuring existing routes:

```
src/app/dashboard/
├── (athlete)/              # Route group — athlete's own data (current routes)
│   ├── sessions/
│   ├── progress/
│   ├── goals/
│   └── profile/
└── athletes/               # Future coach portal
    ├── page.tsx             # /dashboard/athletes — list of athletes the coach supervises
    └── [id]/
        ├── sessions/
        │   ├── page.tsx     # /dashboard/athletes/[id]/sessions
        │   └── [sessionId]/
        │       └── page.tsx # /dashboard/athletes/[id]/sessions/[sessionId]
        ├── progress/
        │   └── page.tsx     # /dashboard/athletes/[id]/progress
        └── profile/
            └── page.tsx     # /dashboard/athletes/[id]/profile
```

The athlete-facing pages under `(athlete)/` already exist. The coach pages under `athletes/[id]/` are identical in structure but pass a different `userId` to each data-fetching call (the athlete's ID rather than `auth.uid()`).

A shared data-access layer abstracted over `userId` enables this cleanly:

```ts
// src/lib/data/sessions.ts
import { createClient } from "@/lib/supabase/server";

export async function getSessionsForUser(
  userId: string,
  opts: { limit?: number; offset?: number } = {}
) {
  const supabase = createClient();
  const { limit = 25, offset = 0 } = opts;

  return supabase
    .from("training_sessions")
    .select("*", { count: "exact" })
    .eq("user_id", userId)
    .not("ended_at", "is", null)
    .order("started_at", { ascending: false })
    .range(offset, offset + limit - 1);
}
```

The athlete page calls `getSessionsForUser(currentUser.id)`. The coach page calls `getSessionsForUser(params.id)` — but only after verifying the coach has a supervision relationship with that athlete.

### RLS policy additions for coach access

The current RLS policies allow only `auth.uid() = user_id`. Coach access requires a separate table recording supervision relationships and an updated policy:

```sql
-- Coach supervision relationship table
create table coach_athlete_links (
  id          uuid primary key default gen_random_uuid(),
  coach_id    uuid not null references users(id) on delete cascade,
  athlete_id  uuid not null references users(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (coach_id, athlete_id)
);

alter table coach_athlete_links enable row level security;

-- Coaches can see their own links; athletes can see who coaches them
create policy "coaches see their links" on coach_athlete_links
  using (coach_id = auth.uid() or athlete_id = auth.uid());

-- Updated policy for training_sessions — athletes see own rows; coaches see supervised athletes
create policy "athlete or coach can read sessions"
  on training_sessions for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from coach_athlete_links
      where coach_id   = auth.uid()
        and athlete_id = training_sessions.user_id
    )
  );

-- Same pattern for shot_records and player_profiles
create policy "athlete or coach can read shots"
  on shot_records for select
  using (
    user_id = auth.uid()
    or exists (
      select 1 from coach_athlete_links
      where coach_id   = auth.uid()
        and athlete_id = shot_records.user_id
    )
  );
```

Coaches are write-blocked on athlete data by design — there is no `INSERT` or `UPDATE` policy for coaches on any athlete table. Coach annotations (future feature) would live in a separate `session_annotations` table owned by the coach.

### Middleware update for coach routes

When coach routes are added, the middleware must verify that the authenticated user has coach access before rendering `/dashboard/athletes/[id]/...`:

```ts
// Addition to src/middleware.ts
const isCoachRoute = request.nextUrl.pathname.startsWith("/dashboard/athletes/");

if (user && isCoachRoute) {
  const athleteId = request.nextUrl.pathname.split("/")[3]; // /dashboard/athletes/[id]/...
  if (athleteId) {
    const supabaseCheck = createServerClient(/* ... */);
    const { data: link } = await supabaseCheck
      .from("coach_athlete_links")
      .select("id")
      .eq("coach_id", user.id)
      .eq("athlete_id", athleteId)
      .maybeSingle();

    if (!link) {
      return NextResponse.redirect(new URL("/dashboard", request.url));
    }
  }
}
```

---

## Implementation Order

The recommended sequence minimises blocked work and delivers value incrementally:

1. **Verify prerequisites** — confirm iOS is writing to Supabase, RLS is validated, TypeScript types are generated. (1 day)
2. **Scaffold routes and shared layout** — create the `dashboard/` directory tree, `layout.tsx` with sidebar nav, and a minimal `/dashboard` overview page. Deploy to Vercel Preview. (1 day)
3. **Authentication flow** — middleware, login page with Sign in with Apple, auth callback route. Verify sign-in/sign-out round-trip. (1 day)
4. **Session list view** — paginated table, date range and drill type filters. (1–2 days)
5. **Shot chart** — `ShotChart` SVG component with accurate court geometry and shot dots. Validate coordinate mapping against real shot data. (2 days)
6. **Session detail view** — combine shot chart, zone heat map, Shot Science metrics panel, shot timeline. (2 days)
7. **Progress view** — FG% trend chart, skill radar, zone doughnut, weekly volume bars. Create `get_fg_trend` RPC if not already done. (2–3 days)
8. **Goals view** — active and completed goal cards. (1 day)
9. **Realtime subscription** — wire `useRealtimeShots` to the session detail page, add live session indicator. (1 day)
10. **Performance pass** — virtual scroll for shot timeline, confirm downsampling RPC, add missing indexes. (1 day)
11. **Coach route scaffolding** — add `coach_athlete_links` table, update RLS policies, stub out `/dashboard/athletes/[id]` routes. (2 days — deferred until coach portal is prioritised)

# HoopTrack Web Presence — Technical Integration Plan

**Date:** 2026-04-12
**Status:** Proposed
**Scope:** Two-phase web strategy — marketing site (Phase A) and authenticated web dashboard (Phase B)

---

## 1. Overview

HoopTrack currently has no web presence. This plan introduces a two-phase strategy:

- **Phase A — Marketing site:** A public Next.js site deployed to Vercel. No backend required. Goal: drive App Store downloads, communicate features, and host the privacy policy. Can be built and deployed independently.
- **Phase B — Web dashboard:** An authenticated Next.js application where users log in with their HoopTrack credentials (Supabase Auth) and explore their training history in interactive large-screen charts. **Cannot be started until the Supabase backend and a data API are in place.**

### Prerequisites by phase

| Phase | Prerequisite |
|-------|-------------|
| A — Marketing site | None. Fully static/SSG, no backend needed. |
| B — Web dashboard | Supabase project provisioned; Row Level Security policies written; REST or GraphQL API exposing `TrainingSession`, `ShotRecord`, and `PlayerProfile` data; Supabase Auth active with email/Apple Sign In. |

### Phase B hard blocker — API-first

The web dashboard cannot be built meaningfully without a backend API. Before any Phase B frontend work begins:

1. Supabase tables must be created and RLS enabled for `training_sessions`, `shot_records`, and `player_profiles`.
2. Either Supabase auto-generated REST (PostgREST) or a custom GraphQL layer (e.g. pg_graphql) must be confirmed as the API strategy.
3. The iOS app must be writing session data to Supabase (not only local SwiftData) so web clients have data to query.

---

## 2. Phase A — Marketing Site (Next.js + Vercel)

### 2.1 Project setup

```bash
npx create-next-app@latest hooptrack-web \
  --typescript \
  --tailwind \
  --eslint \
  --app \
  --src-dir \
  --import-alias "@/*"

cd hooptrack-web
```

This produces an App Router project with TypeScript and Tailwind pre-configured.

### 2.2 App Router structure

```
hooptrack-web/
├── src/
│   └── app/
│       ├── layout.tsx          # Root layout: nav, footer, font, metadata defaults
│       ├── page.tsx            # / — landing page
│       ├── features/
│       │   └── page.tsx        # /features — detailed feature breakdown
│       ├── privacy/
│       │   └── page.tsx        # /privacy — privacy policy (required for App Store)
│       ├── support/
│       │   └── page.tsx        # /support — FAQ, contact link
│       └── globals.css
├── public/
│   ├── screenshots/            # App Store-quality screenshots
│   ├── app-store-badge.svg
│   └── og-image.png            # 1200×630 Open Graph image
├── tailwind.config.ts
└── next.config.ts
```

### 2.3 Design system — Tailwind + HoopTrack brand

Extend `tailwind.config.ts` with the brand colour and typography:

```ts
// tailwind.config.ts
import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{ts,tsx}"],
  theme: {
    extend: {
      colors: {
        brand: {
          orange: "#FF6B35",
          "orange-dark": "#E55A25",
          "orange-light": "#FF8C5A",
        },
        court: {
          floor: "#C8A96E",
          lines: "#FFFFFF",
        },
      },
      fontFamily: {
        // Match the app's feel — swap for licensed font if available
        display: ["var(--font-inter)", "system-ui", "sans-serif"],
      },
    },
  },
  plugins: [],
};

export default config;
```

### 2.4 Key page sections

#### Landing page (`/`)

Sections in order:

1. **Hero** — headline, sub-headline, App Store badge + download CTA, hero screenshot.
2. **Feature highlights** — three cards: CV shot tracking, Shot Science analytics, agility drills.
3. **Screenshot gallery** — horizontal scroll or lightbox of in-app screenshots.
4. **Social proof** — quotes / star rating if available.
5. **Download CTA** — repeated App Store badge.

```tsx
// src/app/page.tsx (hero section sketch)
import Image from "next/image";

export default function LandingPage() {
  return (
    <main>
      <section className="relative bg-gray-950 text-white py-24 px-6">
        <div className="max-w-5xl mx-auto grid md:grid-cols-2 gap-12 items-center">
          <div>
            <h1 className="text-5xl font-display font-bold leading-tight">
              Train smarter.{" "}
              <span className="text-brand-orange">Track every shot.</span>
            </h1>
            <p className="mt-6 text-lg text-gray-300">
              HoopTrack uses computer vision to automatically log your shots,
              map your zones, and reveal the patterns that improve your game.
            </p>
            <a
              href="https://apps.apple.com/app/hooptrack/idXXXXXXXXX"
              className="mt-8 inline-block"
              aria-label="Download HoopTrack on the App Store"
            >
              <Image
                src="/app-store-badge.svg"
                alt="Download on the App Store"
                width={160}
                height={54}
              />
            </a>
          </div>
          <div className="flex justify-center">
            <Image
              src="/screenshots/hero.png"
              alt="HoopTrack shot tracking screen"
              width={280}
              height={560}
              className="rounded-3xl shadow-2xl"
              priority
            />
          </div>
        </div>
      </section>

      {/* Feature highlights, gallery, CTA sections follow */}
    </main>
  );
}
```

#### Privacy policy (`/privacy`)

The privacy policy page must exist before App Store submission. Minimum content: data collected, data retention, third-party services (Supabase, PostHog), contact email, and effective date. Write it as static MDX or plain TSX — no dynamic data needed.

### 2.5 SEO

Use the App Router `metadata` export on each page. Set defaults in `layout.tsx` and override per-page.

```tsx
// src/app/layout.tsx
import type { Metadata } from "next";

export const metadata: Metadata = {
  metadataBase: new URL("https://hooptrack.app"),
  title: {
    default: "HoopTrack — Basketball Training Tracker",
    template: "%s | HoopTrack",
  },
  description:
    "Track every shot with computer vision. HoopTrack maps your zones, measures Shot Science, and shows your progress over time.",
  openGraph: {
    type: "website",
    siteName: "HoopTrack",
    images: [{ url: "/og-image.png", width: 1200, height: 630 }],
  },
  twitter: {
    card: "summary_large_image",
  },
};
```

Generate a sitemap automatically using the built-in Next.js `sitemap.ts` convention:

```ts
// src/app/sitemap.ts
import type { MetadataRoute } from "next";

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: "https://hooptrack.app", lastModified: new Date(), changeFrequency: "monthly", priority: 1 },
    { url: "https://hooptrack.app/features", lastModified: new Date(), changeFrequency: "monthly", priority: 0.8 },
    { url: "https://hooptrack.app/privacy", lastModified: new Date(), changeFrequency: "yearly", priority: 0.3 },
    { url: "https://hooptrack.app/support", lastModified: new Date(), changeFrequency: "monthly", priority: 0.5 },
  ];
}
```

### 2.6 Deployment to Vercel

1. Push `hooptrack-web` to a GitHub repository (e.g. `BenRidges/hooptrack-web`).
2. In the Vercel dashboard, click **Add New Project**, import the repo. Vercel auto-detects Next.js.
3. Set **Framework Preset** = Next.js. No build command override needed.
4. Add environment variables (Phase A has none initially; Phase B variables added later):

   | Variable | Phase | Description |
   |----------|-------|-------------|
   | `NEXT_PUBLIC_POSTHOG_KEY` | A | PostHog project API key |
   | `NEXT_PUBLIC_POSTHOG_HOST` | A | PostHog ingest URL |
   | `NEXT_PUBLIC_SUPABASE_URL` | B | Supabase project URL |
   | `NEXT_PUBLIC_SUPABASE_ANON_KEY` | B | Supabase anon/public key |

5. In **Domains**, add `hooptrack.app` (or your domain) and follow the DNS CNAME/A record instructions.
6. Vercel issues a TLS certificate automatically.

---

## 3. Phase B — Web Dashboard Prerequisites

### 3.1 API-first requirement

The dashboard requires structured access to HoopTrack data. Before building any dashboard UI, confirm the following endpoints/queries are available and tested.

**Required data access:**

| Resource | Operations needed |
|----------|------------------|
| `training_sessions` | List (paginated, filtered by date range + drill type); get by ID |
| `shot_records` | List by session ID (returns `court_x`, `court_y`, `angle`, `outcome`, `zone`) |
| `player_profiles` | Get current user's profile (skill ratings, badges) |
| `session_aggregates` | FG% per session; shot count per zone per session (can be a Supabase view or RPC) |

**Recommended approach:** Use Supabase's PostgREST auto-generated REST API plus a small set of database functions (RPCs) for aggregates. This avoids a separate API server.

```sql
-- Example RPC for zone breakdown per session
create or replace function get_zone_breakdown(p_session_id uuid)
returns table(zone text, attempts int, makes int, fg_pct numeric)
language sql stable
as $$
  select
    zone,
    count(*) as attempts,
    count(*) filter (where outcome = 'make') as makes,
    round(count(*) filter (where outcome = 'make')::numeric / count(*) * 100, 1) as fg_pct
  from shot_records
  where session_id = p_session_id
  group by zone;
$$;
```

### 3.2 Authentication with Supabase Auth + `@supabase/ssr`

Install the SSR-aware Supabase client:

```bash
npm install @supabase/supabase-js @supabase/ssr
```

Create a server-side Supabase client utility:

```ts
// src/lib/supabase/server.ts
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import type { Database } from "@/types/supabase"; // generated types

export function createClient() {
  const cookieStore = cookies();
  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
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

Protect dashboard routes with a middleware guard:

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
        getAll() { return request.cookies.getAll(); },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          );
        },
      },
    }
  );

  const { data: { user } } = await supabase.auth.getUser();

  if (!user && request.nextUrl.pathname.startsWith("/dashboard")) {
    return NextResponse.redirect(new URL("/login", request.url));
  }

  return response;
}

export const config = {
  matcher: ["/dashboard/:path*"],
};
```

### 3.3 Dashboard route structure

```
src/app/
├── login/
│   └── page.tsx                   # /login — Supabase Auth UI or custom form
├── auth/
│   └── callback/
│       └── route.ts               # /auth/callback — OAuth + magic link handler
└── dashboard/
    ├── layout.tsx                 # Shared sidebar nav, user menu
    ├── page.tsx                   # /dashboard — summary stats, recent sessions
    ├── sessions/
    │   ├── page.tsx               # /dashboard/sessions — session list + filters
    │   └── [id]/
    │       └── page.tsx           # /dashboard/sessions/[id] — shot chart + zone breakdown
    └── progress/
        └── page.tsx               # /dashboard/progress — FG% trend, skill ratings, badges
```

---

## 4. Dashboard Data Visualisation

Install charting dependencies:

```bash
npm install recharts
# Recharts is React-native, works well with App Router client components
```

### 4.1 Session list with filtering

```tsx
// src/app/dashboard/sessions/page.tsx (simplified)
"use client";
import { useState } from "react";

type Filters = {
  from: string;
  to: string;
  drillType: string;
};

export default function SessionsPage() {
  const [filters, setFilters] = useState<Filters>({
    from: "",
    to: "",
    drillType: "all",
  });

  // Fetch sessions from Supabase via Server Action or Route Handler,
  // passing filters as query params to PostgREST.
  // e.g. GET /rest/v1/training_sessions?started_at=gte.{from}&started_at=lte.{to}

  return (
    <div>
      <div className="flex gap-4 mb-6">
        <input type="date" value={filters.from}
          onChange={(e) => setFilters((f) => ({ ...f, from: e.target.value }))}
          className="border rounded px-3 py-2" />
        <input type="date" value={filters.to}
          onChange={(e) => setFilters((f) => ({ ...f, to: e.target.value }))}
          className="border rounded px-3 py-2" />
        <select value={filters.drillType}
          onChange={(e) => setFilters((f) => ({ ...f, drillType: e.target.value }))}
          className="border rounded px-3 py-2">
          <option value="all">All drill types</option>
          <option value="shot_science">Shot Science</option>
          <option value="dribble">Dribble Drill</option>
          <option value="agility">Agility</option>
        </select>
      </div>
      {/* Session rows rendered here */}
    </div>
  );
}
```

### 4.2 Shot chart — court SVG with zone heat map

`ShotRecord` stores court position as normalised 0–1 fractions (`court_x`, `court_y`). Render these onto an SVG court diagram.

```tsx
// src/components/ShotChart.tsx
"use client";

type ShotRecord = {
  id: string;
  court_x: number; // 0–1 fraction of court width
  court_y: number; // 0–1 fraction of court length (from baseline)
  outcome: "make" | "miss";
  zone: string;
};

type Props = {
  shots: ShotRecord[];
  width?: number;
  height?: number;
};

// Standard half-court aspect ratio ≈ 47ft × 50ft → 0.94
const COURT_ASPECT = 47 / 50;

export function ShotChart({ shots, width = 500, height = 470 }: Props) {
  const toSvgX = (x: number) => x * width;
  const toSvgY = (y: number) => y * height;

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className="w-full max-w-lg rounded-lg border border-gray-200"
      aria-label="Shot chart"
    >
      {/* Court background */}
      <rect width={width} height={height} fill="#C8A96E" />

      {/* Three-point arc (approximate — refine with real court geometry) */}
      <path
        d={`M ${toSvgX(0.07)} ${toSvgY(0)} A ${toSvgX(0.44)} ${toSvgY(0.44)} 0 0 1 ${toSvgX(0.93)} ${toSvgY(0)}`}
        fill="none"
        stroke="white"
        strokeWidth={2}
      />

      {/* Paint / key */}
      <rect
        x={toSvgX(0.31)}
        y={toSvgY(0)}
        width={toSvgX(0.38)}
        height={toSvgY(0.38)}
        fill="none"
        stroke="white"
        strokeWidth={2}
      />

      {/* Shot dots */}
      {shots.map((shot) => (
        <circle
          key={shot.id}
          cx={toSvgX(shot.court_x)}
          cy={toSvgY(shot.court_y)}
          r={6}
          fill={shot.outcome === "make" ? "#22c55e" : "#ef4444"}
          fillOpacity={0.75}
          stroke="white"
          strokeWidth={1}
        />
      ))}
    </svg>
  );
}
```

For a heat map overlay, aggregate makes and misses by zone and colour each zone polygon from cool (low FG%) to warm (high FG%) using a linear colour interpolation.

### 4.3 Progress charts — FG% trend and skill rating history

```tsx
// src/components/FGPercentChart.tsx
"use client";
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
} from "recharts";

type DataPoint = {
  date: string; // ISO date string, formatted for display
  fg_pct: number;
};

export function FGPercentChart({ data }: { data: DataPoint[] }) {
  return (
    <ResponsiveContainer width="100%" height={300}>
      <LineChart data={data} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
        <XAxis dataKey="date" tick={{ fill: "#9CA3AF", fontSize: 12 }} />
        <YAxis
          domain={[0, 100]}
          tickFormatter={(v) => `${v}%`}
          tick={{ fill: "#9CA3AF", fontSize: 12 }}
        />
        <Tooltip
          formatter={(value: number) => [`${value.toFixed(1)}%`, "FG%"]}
          contentStyle={{ background: "#1F2937", border: "none", borderRadius: 8 }}
          labelStyle={{ color: "#F3F4F6" }}
        />
        <Line
          type="monotone"
          dataKey="fg_pct"
          stroke="#FF6B35"
          strokeWidth={2}
          dot={{ fill: "#FF6B35", r: 4 }}
          activeDot={{ r: 6 }}
        />
      </LineChart>
    </ResponsiveContainer>
  );
}
```

Skill rating history uses the same `LineChart` with multiple `<Line>` elements — one per skill category (e.g. shooting, ball handling, agility). Badge history is rendered as a scrollable grid of badge icons with earned date and description tooltip.

---

## 5. Supabase Integration on the Web

### 5.1 Client setup

```ts
// src/lib/supabase/client.ts  (browser client for Client Components)
import { createBrowserClient } from "@supabase/ssr";
import type { Database } from "@/types/supabase";

export function createClient() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!
  );
}
```

Generate the `Database` TypeScript types from the live Supabase schema:

```bash
npx supabase gen types typescript \
  --project-id YOUR_PROJECT_ID \
  > src/types/supabase.ts
```

Re-run this command whenever the database schema changes.

### 5.2 Row Level Security

Every table must have RLS enabled and a policy that restricts reads to the owning user. Example for `training_sessions`:

```sql
alter table training_sessions enable row level security;

create policy "Users can read own sessions"
  on training_sessions for select
  using (auth.uid() = user_id);

create policy "Users can insert own sessions"
  on training_sessions for insert
  with check (auth.uid() = user_id);
```

Repeat equivalent policies for `shot_records` (via `session_id` join) and `player_profiles`. The anon key used in the web client is safe to expose publicly because RLS enforces data isolation server-side.

### 5.3 Real-time subscriptions for live session monitoring

```tsx
// src/hooks/useSessionRealtime.ts
"use client";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

export function useLatestShots(sessionId: string) {
  const [shots, setShots] = useState<ShotRecord[]>([]);
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
          setShots((prev) => [...prev, payload.new as ShotRecord]);
        }
      )
      .subscribe();

    return () => { supabase.removeChannel(channel); };
  }, [sessionId, supabase]);

  return shots;
}
```

This enables a live "watch mode" where a coach or player can open the dashboard on a laptop while recording a session on their phone and see shot dots appear on the court chart in real time.

---

## 6. Shared Component Library

### 6.1 TypeScript types mirroring Swift models

```ts
// src/types/hooptrack.ts

export type ShotOutcome = "make" | "miss";

export type CourtZone =
  | "paint"
  | "mid_range_left"
  | "mid_range_center"
  | "mid_range_right"
  | "three_left_corner"
  | "three_right_corner"
  | "three_left_wing"
  | "three_right_wing"
  | "three_top";

export interface ShotRecord {
  id: string;
  session_id: string;
  court_x: number;       // 0–1, mirrors ShotRecord.courtPosition.x
  court_y: number;       // 0–1, mirrors ShotRecord.courtPosition.y
  angle: number;         // degrees
  outcome: ShotOutcome;
  zone: CourtZone;
  created_at: string;
}

export interface TrainingSession {
  id: string;
  user_id: string;
  started_at: string;
  ended_at: string | null;
  drill_type: "shot_science" | "dribble" | "agility" | "free_shoot";
  fg_pct: number | null;
  shot_count: number;
  notes: string | null;
}

export interface SkillRatings {
  shooting: number;       // 0–100
  ball_handling: number;
  agility: number;
  shot_selection: number;
}

export interface PlayerProfile {
  id: string;
  user_id: string;
  display_name: string;
  skill_ratings: SkillRatings;
  badge_history: Badge[];
  updated_at: string;
}

export interface Badge {
  id: string;
  key: string;           // e.g. "hot_streak", "zone_master"
  earned_at: string;
  display_name: string;
  description: string;
}
```

### 6.2 Court coordinate utilities

```ts
// src/lib/court.ts

/** Convert normalised 0–1 court fractions to SVG pixel coordinates. */
export function toSvgCoords(
  courtX: number,
  courtY: number,
  svgWidth: number,
  svgHeight: number
): { x: number; y: number } {
  return {
    x: courtX * svgWidth,
    y: courtY * svgHeight,
  };
}

/** Determine the CourtZone for a given normalised position. */
export function classifyZone(x: number, y: number): CourtZone {
  // Paint: roughly centre bottom 38% width, bottom 38% height
  if (x >= 0.31 && x <= 0.69 && y <= 0.38) return "paint";

  // Corners
  if (y <= 0.22 && x < 0.31) return "three_left_corner";
  if (y <= 0.22 && x > 0.69) return "three_right_corner";

  // Wings
  const distFromCenter = Math.sqrt((x - 0.5) ** 2 + y ** 2);
  const isThree = distFromCenter > 0.44;

  if (isThree) {
    if (x < 0.35) return "three_left_wing";
    if (x > 0.65) return "three_right_wing";
    return "three_top";
  }

  if (x < 0.4) return "mid_range_left";
  if (x > 0.6) return "mid_range_right";
  return "mid_range_center";
}

/** Compute FG% for a filtered array of shots. */
export function computeFGPct(shots: ShotRecord[]): number {
  if (shots.length === 0) return 0;
  const makes = shots.filter((s) => s.outcome === "make").length;
  return (makes / shots.length) * 100;
}
```

---

## 7. Responsive Design

### 7.1 Breakpoint strategy

| Breakpoint | Width | Layout |
|-----------|-------|--------|
| `sm` | 640px | Single column, stacked cards |
| `md` | 768px | Two-column grid for feature cards |
| `lg` | 1024px | Dashboard sidebar becomes persistent rail (not hamburger) |
| `xl` | 1280px | Charts expand to full width; session list + chart side-by-side |

### 7.2 Dashboard layout

```tsx
// src/app/dashboard/layout.tsx
export default function DashboardLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="min-h-screen bg-gray-950 text-white flex flex-col lg:flex-row">
      {/* Sidebar: hamburger on mobile, persistent on lg+ */}
      <aside className="w-full lg:w-64 bg-gray-900 lg:min-h-screen">
        <nav className="p-4 flex lg:flex-col gap-2">
          <NavLink href="/dashboard" label="Overview" />
          <NavLink href="/dashboard/sessions" label="Sessions" />
          <NavLink href="/dashboard/progress" label="Progress" />
        </nav>
      </aside>
      <main className="flex-1 p-4 lg:p-8 overflow-x-hidden">
        {children}
      </main>
    </div>
  );
}
```

### 7.3 Shot chart on mobile

On screens narrower than 640px, replace the full shot chart with a zone summary table (zone name, attempts, FG%) to keep the layout readable. Use the `hidden sm:block` / `sm:hidden` Tailwind utilities to toggle between the two views.

---

## 8. Analytics Integration

### 8.1 PostHog setup

PostHog provides privacy-friendly analytics with no data sold to third parties — suitable given HoopTrack's athlete user base and potential COPPA considerations.

```bash
npm install posthog-js posthog-node
```

```tsx
// src/providers/PostHogProvider.tsx
"use client";
import posthog from "posthog-js";
import { PostHogProvider as PHProvider } from "posthog-js/react";
import { useEffect } from "react";

export function PostHogProvider({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    posthog.init(process.env.NEXT_PUBLIC_POSTHOG_KEY!, {
      api_host: process.env.NEXT_PUBLIC_POSTHOG_HOST ?? "https://app.posthog.com",
      capture_pageview: false, // handled manually in usePathname hook
      persistence: "memory",  // avoid cookies until consent given
    });
  }, []);

  return <PHProvider client={posthog}>{children}</PHProvider>;
}
```

### 8.2 Cookie consent banner

PostHog's `persistence: "memory"` mode collects no persistent identifiers until the user consents. Show a simple banner on first visit:

```tsx
// src/components/CookieBanner.tsx
"use client";
import { useState, useEffect } from "react";
import posthog from "posthog-js";

export function CookieBanner() {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const consent = localStorage.getItem("analytics_consent");
    if (!consent) setVisible(true);
  }, []);

  const accept = () => {
    localStorage.setItem("analytics_consent", "accepted");
    posthog.set_config({ persistence: "localStorage+cookie" });
    setVisible(false);
  };

  const decline = () => {
    localStorage.setItem("analytics_consent", "declined");
    setVisible(false);
  };

  if (!visible) return null;

  return (
    <div className="fixed bottom-0 inset-x-0 bg-gray-900 border-t border-gray-700 p-4 flex flex-col sm:flex-row items-start sm:items-center gap-4 z-50">
      <p className="text-sm text-gray-300 flex-1">
        We use anonymous analytics to improve HoopTrack. No personal data is shared.{" "}
        <a href="/privacy" className="underline text-brand-orange">Privacy policy</a>
      </p>
      <div className="flex gap-3">
        <button onClick={decline} className="text-sm text-gray-400 hover:text-white">Decline</button>
        <button onClick={accept} className="text-sm bg-brand-orange text-white px-4 py-2 rounded-lg hover:bg-brand-orange-dark">
          Accept
        </button>
      </div>
    </div>
  );
}
```

---

## 9. Deployment and CI/CD

### 9.1 Vercel project settings

| Setting | Value |
|---------|-------|
| Framework | Next.js (auto-detected) |
| Build command | `next build` (default) |
| Output directory | `.next` (default) |
| Node version | 20.x |
| Root directory | `hooptrack-web/` (if monorepo) |

### 9.2 Branch and preview strategy

Vercel creates a unique preview URL for every pull request automatically. No extra configuration needed.

| Git event | Vercel action |
|-----------|--------------|
| PR opened / commit pushed to PR branch | Preview deployment at `hooptrack-web-git-{branch}.vercel.app` |
| Merge to `main` | Production deployment at `hooptrack.app` |
| Commit to `main` directly | Production deployment |

### 9.3 Environment variable management

- **Development:** `.env.local` (never committed — add to `.gitignore`).
- **Preview:** Set in Vercel dashboard under **Settings → Environment Variables → Preview**.
- **Production:** Set in Vercel dashboard under **Settings → Environment Variables → Production**.
- The `NEXT_PUBLIC_` prefix is required for any variable accessed in browser (client) code. Server-only secrets (e.g. Supabase service role key for admin RPCs) must use names without the prefix.

```
# .env.local (development only — do not commit)
NEXT_PUBLIC_SUPABASE_URL=https://xxxx.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
NEXT_PUBLIC_POSTHOG_KEY=phc_...
NEXT_PUBLIC_POSTHOG_HOST=https://app.posthog.com
SUPABASE_SERVICE_ROLE_KEY=eyJ...  # server-only, no NEXT_PUBLIC_ prefix
```

### 9.4 Recommended GitHub Actions additions

While Vercel handles deployments automatically, add a lightweight CI step to catch TypeScript and lint errors before merge:

```yaml
# .github/workflows/ci.yml
name: CI
on: [pull_request]
jobs:
  typecheck:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: hooptrack-web
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
          cache-dependency-path: hooptrack-web/package-lock.json
      - run: npm ci
      - run: npm run lint
      - run: npx tsc --noEmit
```

---

## Appendix — Recommended implementation order

1. Create `hooptrack-web` repo and deploy a skeleton to Vercel with the custom domain. (1 day)
2. Build landing page, features page, privacy policy, support page. Ship Phase A. (3–5 days)
3. Add PostHog + cookie consent banner to Phase A. (half day)
4. Provision Supabase project; write schema, RLS policies, and initial RPCs. (2 days)
5. Connect iOS app to Supabase; write sessions and shots to the cloud. (separate iOS work)
6. Generate TypeScript types from Supabase schema; scaffold `/login` and `/dashboard` routes. (1 day)
7. Build session list, shot chart, progress charts. (3–5 days)
8. Add real-time subscriptions and live session view. (1–2 days)

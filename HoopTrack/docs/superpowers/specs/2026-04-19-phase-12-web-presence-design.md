# Phase 12 — Web Presence Design Spec

**Date:** 2026-04-19  
**Status:** Approved  
**Scope:** 12A — Marketing site + 12B — Authenticated web dashboard (Extended: shot chart + zone heat map + badges page)

---

## 1. Overview

Phase 12 ships HoopTrack's web presence as a standalone Next.js project deployed to Vercel. It covers two sub-phases:

- **12A — Marketing site:** Public static site. No prerequisites. Goal: drive App Store downloads and host the legally required privacy policy.
- **12B — Web dashboard:** Authenticated dashboard. Prerequisite: Phase 9 (Supabase backend) — **already complete**. Users log in with the same email + password they use in the iOS app and explore their training history in interactive charts.

### Decisions made

| Decision | Choice | Rationale |
|---|---|---|
| Repo | Standalone `hooptrack-web` GitHub repo | Keeps iOS and web histories separate; Vercel deploys independently |
| Auth method | Email + password only | Matches iOS app; no Apple Developer membership required |
| Domain | Vercel-generated URL for launch; custom domain added later | No domain purchased yet |
| Real-time live sessions | Deferred to Phase 13/14 | Adds Supabase Realtime complexity without enough users to justify it yet |
| Dashboard depth | Extended (C) — includes zone heat map + badges page | Zone heat map is the app's best visual showcase on web |
| Screenshots | Placeholder images for launch; real screenshots before App Store submission | None available yet |

---

## 2. Project Setup

**Repo:** `hooptrack-web` (new standalone GitHub repo, separate from iOS)  
**Deploy:** Vercel — auto-deploys `main` to production, PR branches to preview URLs  
**CI:** GitHub Actions on every PR — `tsc --noEmit` + `eslint`

### Bootstrap command

```bash
npx create-next-app@latest hooptrack-web \
  --typescript --tailwind --eslint --app --src-dir \
  --import-alias "@/*"
```

### Directory structure

```
hooptrack-web/
├── src/
│   ├── app/
│   │   ├── layout.tsx              # Root layout: nav, footer, font, metadata defaults
│   │   ├── page.tsx                # / — landing page
│   │   ├── features/page.tsx       # /features
│   │   ├── privacy/page.tsx        # /privacy (required for App Store)
│   │   ├── support/page.tsx        # /support
│   │   ├── sitemap.ts              # Auto-generated sitemap
│   │   ├── login/page.tsx          # /login
│   │   ├── auth/callback/route.ts  # /auth/callback — Supabase session exchange
│   │   └── dashboard/
│   │       ├── layout.tsx          # Sidebar nav + user menu
│   │       ├── page.tsx            # /dashboard — overview
│   │       ├── sessions/
│   │       │   ├── page.tsx        # /dashboard/sessions — list + filters
│   │       │   └── [id]/page.tsx   # /dashboard/sessions/[id] — shot chart + zones
│   │       ├── progress/page.tsx   # /dashboard/progress — FG% trend + skill ratings
│   │       └── badges/page.tsx     # /dashboard/badges — earned badge grid
│   ├── components/
│   │   ├── ShotChart.tsx           # SVG half-court with shot dots + zone heat map
│   │   ├── ZoneTable.tsx           # Zone breakdown table
│   │   ├── FGPercentChart.tsx      # Recharts line chart
│   │   ├── SkillRatingBars.tsx     # CSS progress bars for 4 skill dimensions
│   │   ├── SessionCard.tsx         # Session list row
│   │   ├── StatCard.tsx            # Overview stat card
│   │   ├── BadgeGrid.tsx           # Earned/in-progress badge display
│   │   ├── Nav.tsx                 # Marketing site nav
│   │   ├── DashboardSidebar.tsx    # Dashboard sidebar + mobile top bar
│   │   ├── CookieBanner.tsx        # PostHog consent banner
│   │   └── PostHogProvider.tsx     # Analytics provider wrapper
│   ├── lib/
│   │   ├── supabase/
│   │   │   ├── server.ts           # createServerClient (Server Components + Route Handlers)
│   │   │   └── client.ts           # createBrowserClient (Client Components)
│   │   └── court.ts                # toSvgCoords, classifyZone, computeFGPct, zone polygon defs
│   └── types/
│       ├── hooptrack.ts            # TypeScript mirrors of Swift models
│       └── supabase.ts             # Generated via `supabase gen types typescript`
├── public/
│   ├── screenshots/                # Placeholder images; swap for real screenshots pre-launch
│   ├── app-store-badge.svg
│   └── og-image.png                # 1200×630 Open Graph image
├── src/middleware.ts               # Supabase session refresh + /dashboard auth guard
├── .github/workflows/ci.yml        # Typecheck + lint on PRs
└── .env.local.example              # Template; .env.local is gitignored
```

---

## 3. Design System

All tokens map directly from iOS `Color+Brand.swift` and the Auth/Live session screen palette.

### Tailwind config extensions

```ts
// tailwind.config.ts
colors: {
  brand: {
    orange: '#FF6B35',             // brandOrange — CTAs on light backgrounds
    'orange-accessible': '#FF804F', // brandOrangeAccessible — text on dark (4.5:1 contrast)
    'orange-dark': '#E55A25',      // hover state for orange buttons
  },
  bg: {
    deep: '#0A0A12',               // page background, hero sections
    dark: '#0F0D1A',               // nav bar, sidebar
    card: '#1A1426',               // card/panel backgrounds
  },
  court: {
    floor: '#D7AD6B',              // hardwood background on shot chart
  },
}
```

### Typography

System font stack: `-apple-system, BlinkMacSystemFont, 'SF Pro Rounded', Inter, system-ui, sans-serif`

- Gives SF Pro (Rounded) on Apple devices — matches the iOS `.system(..., design: .rounded)` feel
- Falls back to Inter on other platforms
- No additional font load; zero layout shift

### Component patterns

| iOS | Web equivalent |
|---|---|
| `.ultraThinMaterial` card | `bg-white/[0.04] backdrop-blur-md border border-white/[0.08] rounded-2xl` |
| Solid orange CTA | `bg-brand-orange hover:bg-brand-orange-dark text-white font-bold rounded-xl` |
| Orange ghost button | `bg-brand-orange/10 text-brand-orange-accessible border border-brand-orange/25 rounded-xl` |
| System background | `bg-bg-deep` (the `#0A0A12` purple-black) |

---

## 4. Phase 12A — Marketing Site

### Pages

| Route | Purpose | Notes |
|---|---|---|
| `/` | Landing — hero, 3 feature cards, screenshot gallery, download CTA | Placeholder screenshots at launch |
| `/features` | Feature deep-dive — full list of shipped capabilities through Phase 11 | Static content |
| `/privacy` | Privacy policy | **Required before App Store submission.** Static MDX or TSX. |
| `/support` | FAQ + contact email | 4–5 common questions; `benr@edgesemantics.com` as contact |

### Landing page sections (in order)

1. **Hero** — headline (`Train smarter.` / `Track every shot.`), sub-headline, App Store badge CTA, placeholder iPhone screenshot
2. **Feature highlights** — three cards: CV Shot Tracking, Shot Science, Agility Drills
3. **Screenshot gallery** — horizontal scroll of placeholder images (swap before launch)
4. **Download CTA** — repeated App Store badge

### Privacy policy minimum content

- Data collected (camera frames, body pose, shot coordinates, session timing)
- Data retention (video: 7-day default per Phase 10; sessions: until account deletion)
- Third-party services: Supabase (cloud sync), PostHog (anonymous analytics)
- User rights: delete all data via Profile → Delete My Data
- Contact email: `benr@edgesemantics.com`
- Effective date

### SEO

- `metadata` export on every page with `metadataBase: new URL('https://hooptrack.app')` — swap URL when domain is purchased
- Open Graph image: `public/og-image.png` (1200×630)
- `src/app/sitemap.ts` — 4 static entries with appropriate `changeFrequency` and `priority`
- Twitter card: `summary_large_image`

### Analytics

- **PostHog** — `persistence: 'memory'` until cookie consent given; no persistent identifiers before consent
- `PostHogProvider` wraps root layout; cookie consent banner shown on first visit
- Declining keeps `persistence: 'memory'`; accepting upgrades to `localStorage+cookie`

### Deployment

- Push repo to GitHub, connect to Vercel
- **12A env vars:** `NEXT_PUBLIC_POSTHOG_KEY` + `NEXT_PUBLIC_POSTHOG_HOST` only — set in Vercel dashboard
- **12B env vars:** add `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- Custom domain wired up when purchased; Vercel issues TLS automatically

---

## 5. Phase 12B — Web Dashboard

### Authentication

- **Email + password only** — matches iOS exactly; no Sign in with Apple on web
- `@supabase/ssr` for HTTP-only session cookies (no JWT in localStorage)
- `src/middleware.ts` handles two responsibilities:
  1. Refresh the Supabase session on every request (required by `@supabase/ssr`)
  2. Redirect unauthenticated requests to `/dashboard/*` → `/login`
- `/auth/callback` route handler exchanges the auth code for a session after email confirmation
- Web users **cannot sign up** via the dashboard — sign-up is iOS-only. The login page links to the App Store instead of a sign-up form.

### Data access

- Supabase PostgREST auto-generated REST API — no separate API server
- Server Components fetch data directly via `createServerClient`; no client-side data fetching except for interactive filter updates
- TypeScript types generated from live schema: `npx supabase gen types typescript --project-id nfzhqcgofuohsjhtxvqa > src/types/supabase.ts`
- Re-run types generation whenever schema changes

### Dashboard routes

| Route | Content | Data sources |
|---|---|---|
| `/dashboard` | Overview: 3 stat cards (FG% 7d, session count, shot count), recent sessions list | `training_sessions`, `shot_records` |
| `/dashboard/sessions` | Session list with date-range + drill-type filters, paginated | `training_sessions` |
| `/dashboard/sessions/[id]` | Session detail: shot chart + zone heat map + zone breakdown table | `shot_records` for session |
| `/dashboard/progress` | FG% trend line chart (Recharts), skill rating bars | `training_sessions`, `player_profiles` |
| `/dashboard/badges` | Earned badge grid (icon, name, date) + in-progress badges dimmed | `earned_badges` |

### Shot chart + zone heat map (`ShotChart.tsx`)

- SVG rendered at full width, `viewBox` maintains half-court aspect ratio (47:50 ≈ 0.94)
- Court background: `#D7AD6B` (hardwood, from `CourtMapView.swift`)
- Court lines (3PT arc, paint, free-throw circle): white at 40% opacity
- **Shot dots:** green (`#22c55e`) for makes, red (`#ef4444`) for misses; 6px radius, white 1px stroke
- **Zone heat map overlay:** 9 SVG polygon paths, one per `CourtZone`. Fill colour interpolated from green (high FG%) → orange → red (low FG%) based on zone FG%. Opacity 0.35.
- Zone polygon coordinates defined in `src/lib/court.ts` as normalised 0–1 fractions; scaled to SVG dimensions at render time
- On screens < 640px: shot chart hidden; zone breakdown table shown full-width instead

### Progress charts (`FGPercentChart.tsx`, `SkillRatingsChart.tsx`)

- **Recharts** — single added dependency (`npm install recharts`); used only for the FG% trend line
- FG% trend: `LineChart` with one `Line` (stroke `#FF6B35`), `CartesianGrid` at 4% white, tooltip styled dark (`#1A1426` background)
- Skill ratings: CSS progress bars in `SkillRatingBars.tsx` (4 skills: Shooting, Ball Handling, Agility, Shot Selection) — no Recharts; simpler and matches the iOS bar style exactly
- Both components are `'use client'` inside otherwise Server-rendered pages

### Dashboard layout

- Desktop (≥ 1024px): persistent left sidebar (160px) with logo, 4 nav links, sign-out
- Mobile (< 1024px): sidebar collapses to horizontal top bar; hamburger if links overflow
- Page background: `bg-bg-deep` (`#0A0A12`)
- Sidebar background: `bg-bg-dark` (`#0F0D1A`)
- Cards: glass panel pattern (see design system above)

### Environment variables

```bash
# .env.local (development — never commit)
NEXT_PUBLIC_SUPABASE_URL=https://nfzhqcgofuohsjhtxvqa.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
NEXT_PUBLIC_POSTHOG_KEY=phc_...
NEXT_PUBLIC_POSTHOG_HOST=https://app.posthog.com
```

Set Production + Preview variants in Vercel dashboard under Settings → Environment Variables.

---

## 6. CI/CD

```yaml
# .github/workflows/ci.yml
name: CI
on: [pull_request]
jobs:
  typecheck:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: .
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npx tsc --noEmit
```

Vercel handles all deployments automatically — no deploy step in CI.

---

## 7. Implementation Order

1. Bootstrap `hooptrack-web` repo; Vercel project wired up; skeleton deployed (day 1)
2. Tailwind design tokens, shared `Nav`, `Footer` components (day 1)
3. Landing page with placeholder screenshots (day 2)
4. Features, Privacy, Support pages + sitemap + SEO metadata (day 2–3)
5. PostHog + cookie consent banner — **Phase 12A ships here** (day 3)
6. Generate Supabase TypeScript types; scaffold `/login` + `/auth/callback` + middleware (day 4)
7. Dashboard layout (sidebar + responsive shell) + `/dashboard` overview (day 4–5)
8. `/dashboard/sessions` list with filters (day 5)
9. `ShotChart` component — shot dots, court SVG, zone heat map polygons (day 6–7)
10. `/dashboard/sessions/[id]` — shot chart + zone breakdown table (day 7)
11. `/dashboard/progress` — FG% trend chart + skill rating bars (day 8)
12. `/dashboard/badges` — badge grid (day 8)
13. Responsive polish + mobile layout testing — **Phase 12B ships here** (day 9)
14. Security review via `swift-security-reviewer` subagent scoped to changed files (day 9)

---

## 8. Out of Scope for Phase 12

- Custom domain (purchased and wired in a future pass)
- Real App Store link (placeholder `href` until submission)
- Real screenshots (placeholder images until available)
- Real-time live session monitoring (deferred to Phase 13/14)
- Sign in with Apple on web (deferred; can be added as another Supabase OAuth provider)
- Video playback in dashboard (deferred to Phase 15 — Coach Review Mode)
- Coach access / athlete sharing (Phase 15)

---

## 9. Relation to Other Phases

- **Depends on Phase 9** (Supabase tables, RLS, PostgREST) — complete ✅
- **Feeds Phase 14** (Extended Web Dashboard — session detail video, skill rating history snapshots)
- **Feeds Phase 15** (Coach Review Mode — `/dashboard/review/[session_id]` route group)
- **No iOS code changes** — Phase 12 is entirely in `hooptrack-web`; the iOS repo is untouched

---

## 10. Notes for ROADMAP Update

Update `docs/ROADMAP.md` Phase 12 block to mark 12A and 12B as the implementation target, remove the old "Phase 12B — Web Dashboard" section that was listed as a separate item, and note that the `upgrade-web-presence.md` reference doc is superseded by this spec.

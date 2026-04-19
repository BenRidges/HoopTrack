# Phase 12 — Web Presence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `hooptrack-web` — a standalone Next.js 15 site with a public marketing site (12A: landing, features, privacy, support) and an authenticated web dashboard (12B: session history, shot chart with zone heat map, progress charts, badges).

**Architecture:** Standalone GitHub repo separate from the iOS project. Next.js 15 App Router with TypeScript and Tailwind CSS. 12A pages are fully static (no backend). 12B uses `@supabase/ssr` for server-side session cookies; Server Components fetch data directly from the existing Supabase project via PostgREST. No separate API server.

**Tech Stack:** Next.js 15 (App Router), TypeScript, Tailwind CSS, `@supabase/ssr`, Recharts (FG% trend only), PostHog (analytics), vitest (unit tests), Vercel (deploy), GitHub Actions (CI)

**Supabase project ID:** `nfzhqcgofuohsjhtxvqa`  
**Supabase URL:** `https://nfzhqcgofuohsjhtxvqa.supabase.co`

---

## File Map

| File | Responsibility |
|---|---|
| `tailwind.config.ts` | Brand colour tokens from iOS `Color+Brand.swift` |
| `src/app/layout.tsx` | Root layout: font stack, metadata defaults, Nav, Footer, providers |
| `src/app/sitemap.ts` | Auto-generated sitemap for 4 marketing pages |
| `src/app/page.tsx` | Landing page: hero, feature cards, screenshot gallery, CTA |
| `src/app/features/page.tsx` | Feature deep-dive list |
| `src/app/privacy/page.tsx` | Privacy policy (App Store required) |
| `src/app/support/page.tsx` | FAQ + contact |
| `src/app/login/page.tsx` | Email + password sign-in form |
| `src/app/auth/callback/route.ts` | Supabase session exchange after email confirmation |
| `src/app/dashboard/layout.tsx` | Dashboard shell: sidebar + responsive top bar |
| `src/app/dashboard/page.tsx` | Overview: 3 stat cards + recent sessions |
| `src/app/dashboard/sessions/page.tsx` | Session list with date/type filters |
| `src/app/dashboard/sessions/[id]/page.tsx` | Session detail: shot chart + zone table |
| `src/app/dashboard/progress/page.tsx` | FG% trend chart + skill rating bars |
| `src/app/dashboard/badges/page.tsx` | Earned + in-progress badge grid |
| `src/components/Nav.tsx` | Marketing site top nav |
| `src/components/Footer.tsx` | Site footer |
| `src/components/StatCard.tsx` | Overview stat card (label, value, delta) |
| `src/components/SessionCard.tsx` | Single session row in the list |
| `src/components/ShotChart.tsx` | SVG half-court with shot dots + zone heat map |
| `src/components/ZoneTable.tsx` | Zone breakdown table (zone, attempts, makes, FG%) |
| `src/components/FGPercentChart.tsx` | Recharts line chart for FG% trend |
| `src/components/SkillRatingBars.tsx` | CSS progress bars for 4 skill dimensions |
| `src/components/BadgeGrid.tsx` | Earned/in-progress badge display |
| `src/components/DashboardSidebar.tsx` | Sidebar nav (desktop) + top bar (mobile) |
| `src/components/PostHogProvider.tsx` | PostHog initialisation, memory persistence |
| `src/components/CookieBanner.tsx` | Cookie consent — upgrades PostHog on accept |
| `src/lib/court.ts` | `toSvgCoords`, `classifyZone`, `computeFGPct`, `zoneHeatColor`, `ZONE_POLYGONS` |
| `src/lib/supabase/server.ts` | `createClient()` for Server Components and Route Handlers |
| `src/lib/supabase/client.ts` | `createClient()` for Client Components |
| `src/middleware.ts` | Session refresh on every request; redirect `/dashboard/*` to `/login` |
| `src/types/hooptrack.ts` | TypeScript mirrors of Swift models |
| `src/types/supabase.ts` | Generated from `supabase gen types typescript` |
| `src/__tests__/court.test.ts` | Unit tests for all `court.ts` exports |
| `.github/workflows/ci.yml` | Typecheck + lint on PRs |
| `.env.local.example` | Template for required env vars |

---

## Task 1: Bootstrap repo + Tailwind design tokens

**Files:**
- Create: `hooptrack-web/` (new directory via `create-next-app`)
- Modify: `tailwind.config.ts`
- Create: `.env.local.example`
- Create: `vitest.config.ts`

- [ ] **Step 1: Run create-next-app**

Run from your projects directory (e.g. `~/Documents/projects/`), NOT inside the iOS `HoopTrack/` folder:

```bash
cd ~/Documents/projects
npx create-next-app@latest hooptrack-web \
  --typescript --tailwind --eslint --app --src-dir \
  --import-alias "@/*"
cd hooptrack-web
```

When prompted, accept all defaults (App Router, no `src/` override needed — already set by flag).

- [ ] **Step 2: Install additional dependencies**

```bash
npm install posthog-js
npm install -D vitest @vitest/ui
```

- [ ] **Step 3: Add vitest scripts to package.json**

Open `package.json` and add two entries to `scripts`:

```json
{
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint",
    "test": "vitest run",
    "test:watch": "vitest"
  }
}
```

- [ ] **Step 4: Create vitest.config.ts**

```typescript
// vitest.config.ts
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    environment: 'node',
    include: ['src/__tests__/**/*.test.ts'],
  },
})
```

- [ ] **Step 5: Extend Tailwind with brand tokens**

Replace the entire contents of `tailwind.config.ts`:

```typescript
import type { Config } from 'tailwindcss'

const config: Config = {
  content: ['./src/**/*.{ts,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          orange: '#FF6B35',
          'orange-accessible': '#FF804F',
          'orange-dark': '#E55A25',
        },
        bg: {
          deep: '#0A0A12',
          dark: '#0F0D1A',
          card: '#1A1426',
        },
        court: {
          floor: '#D7AD6B',
        },
      },
      fontFamily: {
        sans: [
          '-apple-system',
          'BlinkMacSystemFont',
          '"SF Pro Rounded"',
          'Inter',
          'system-ui',
          'sans-serif',
        ],
      },
    },
  },
  plugins: [],
}

export default config
```

- [ ] **Step 6: Create .env.local.example**

```bash
# .env.local.example — copy to .env.local and fill in values
NEXT_PUBLIC_SUPABASE_URL=https://nfzhqcgofuohsjhtxvqa.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=          # Supabase dashboard → Settings → API → anon key
NEXT_PUBLIC_POSTHOG_KEY=                # PostHog project settings → Project API key
NEXT_PUBLIC_POSTHOG_HOST=https://us.i.posthog.com
```

- [ ] **Step 7: Add .env.local to .gitignore**

The generated `.gitignore` already excludes `.env*.local`. Verify:

```bash
grep "env" .gitignore
```

Expected output includes `.env*.local`.

- [ ] **Step 8: Create GitHub repo and push**

```bash
git init   # already done by create-next-app
git add -A
git commit -m "chore: bootstrap hooptrack-web with Next.js 15 + Tailwind brand tokens"
```

Then create a new repo on GitHub named `hooptrack-web` (no README, no .gitignore — we have those), and push:

```bash
git remote add origin git@github.com:YOUR_USERNAME/hooptrack-web.git
git branch -M main
git push -u origin main
```

- [ ] **Step 9: Connect to Vercel**

1. Go to vercel.com → Add New Project → Import `hooptrack-web`
2. Framework: Next.js (auto-detected). No overrides needed.
3. Click Deploy. Note the preview URL (e.g. `hooptrack-web.vercel.app`) — this is the live URL until a custom domain is added.

---

## Task 2: Root layout, Nav, Footer, and sitemap

**Files:**
- Modify: `src/app/layout.tsx`
- Create: `src/app/globals.css` (update existing)
- Create: `src/app/sitemap.ts`
- Create: `src/components/Nav.tsx`
- Create: `src/components/Footer.tsx`

- [ ] **Step 1: Update globals.css**

Replace the contents of `src/app/globals.css`:

```css
@tailwind base;
@tailwind components;
@tailwind utilities;

@layer base {
  body {
    @apply bg-bg-deep text-white antialiased;
  }
}
```

- [ ] **Step 2: Create Nav.tsx**

```tsx
// src/components/Nav.tsx
import Link from 'next/link'

export function Nav() {
  return (
    <header className="sticky top-0 z-50 bg-bg-dark/80 backdrop-blur-md border-b border-white/[0.06]">
      <nav className="max-w-6xl mx-auto px-6 h-16 flex items-center justify-between">
        <Link href="/" className="text-brand-orange-accessible font-black text-lg tracking-tight">
          🏀 HoopTrack
        </Link>
        <div className="flex items-center gap-6 text-sm text-gray-400">
          <Link href="/features" className="hover:text-white transition-colors">Features</Link>
          <Link href="/privacy" className="hover:text-white transition-colors">Privacy</Link>
          <Link href="/support" className="hover:text-white transition-colors">Support</Link>
          <Link
            href="#download"
            className="bg-brand-orange hover:bg-brand-orange-dark text-white font-bold px-4 py-2 rounded-xl transition-colors"
          >
            Download
          </Link>
        </div>
      </nav>
    </header>
  )
}
```

- [ ] **Step 3: Create Footer.tsx**

```tsx
// src/components/Footer.tsx
import Link from 'next/link'

export function Footer() {
  return (
    <footer className="bg-bg-dark border-t border-white/[0.06] py-8 px-6">
      <div className="max-w-6xl mx-auto flex flex-col sm:flex-row items-center justify-between gap-4 text-sm text-gray-500">
        <span>© {new Date().getFullYear()} HoopTrack</span>
        <div className="flex gap-6">
          <Link href="/privacy" className="hover:text-gray-300 transition-colors">Privacy</Link>
          <Link href="/support" className="hover:text-gray-300 transition-colors">Support</Link>
          <Link href="/dashboard" className="hover:text-gray-300 transition-colors">Dashboard</Link>
        </div>
      </div>
    </footer>
  )
}
```

- [ ] **Step 4: Update root layout.tsx**

```tsx
// src/app/layout.tsx
import type { Metadata } from 'next'
import './globals.css'
import { Nav } from '@/components/Nav'
import { Footer } from '@/components/Footer'

export const metadata: Metadata = {
  metadataBase: new URL('https://hooptrack.app'),
  title: {
    default: 'HoopTrack — Basketball Training Tracker',
    template: '%s | HoopTrack',
  },
  description:
    'Track every shot with computer vision. HoopTrack maps your zones, measures Shot Science, and shows your progress over time.',
  openGraph: {
    type: 'website',
    siteName: 'HoopTrack',
    images: [{ url: '/og-image.png', width: 1200, height: 630 }],
  },
  twitter: {
    card: 'summary_large_image',
  },
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Nav />
        <main>{children}</main>
        <Footer />
      </body>
    </html>
  )
}
```

- [ ] **Step 5: Create sitemap.ts**

```typescript
// src/app/sitemap.ts
import type { MetadataRoute } from 'next'

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    { url: 'https://hooptrack.app', lastModified: new Date(), changeFrequency: 'monthly', priority: 1 },
    { url: 'https://hooptrack.app/features', lastModified: new Date(), changeFrequency: 'monthly', priority: 0.8 },
    { url: 'https://hooptrack.app/support', lastModified: new Date(), changeFrequency: 'monthly', priority: 0.5 },
    { url: 'https://hooptrack.app/privacy', lastModified: new Date(), changeFrequency: 'yearly', priority: 0.3 },
  ]
}
```

- [ ] **Step 6: Add placeholder public assets**

```bash
mkdir -p public/screenshots
# Create a 1200x630 placeholder og-image (use any image editor or a simple coloured PNG)
# Create a placeholder app-store-badge.svg
# Download the official badge from https://developer.apple.com/app-store/marketing/guidelines/
# For now, create a placeholder:
cat > public/app-store-badge.svg << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 160 54">
  <rect width="160" height="54" rx="8" fill="#000"/>
  <text x="80" y="32" text-anchor="middle" fill="white" font-size="14" font-family="sans-serif">App Store</text>
</svg>
EOF
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: root layout, Nav, Footer, sitemap"
```

---

## Task 3: Landing page (/)

**Files:**
- Modify: `src/app/page.tsx`

- [ ] **Step 1: Write the landing page**

```tsx
// src/app/page.tsx
import type { Metadata } from 'next'
import Image from 'next/image'
import Link from 'next/link'

export const metadata: Metadata = {
  title: 'HoopTrack — Basketball Training Tracker',
}

const FEATURES = [
  {
    icon: '🎯',
    title: 'CV Shot Tracking',
    body: 'Computer vision automatically detects every make and miss — no manual logging.',
  },
  {
    icon: '📐',
    title: 'Shot Science',
    body: 'Pose estimation measures release angle, elbow alignment, and shot arc every rep.',
  },
  {
    icon: '⚡',
    title: 'Agility Drills',
    body: 'Shuttle run, lane agility, and vertical jump tracking built right in.',
  },
]

export default function LandingPage() {
  return (
    <>
      {/* Hero */}
      <section className="bg-gradient-to-br from-bg-card to-bg-deep py-24 px-6">
        <div className="max-w-6xl mx-auto grid md:grid-cols-2 gap-12 items-center">
          <div>
            <p className="text-brand-orange-accessible text-xs font-bold uppercase tracking-widest mb-4">
              Basketball training, reimagined
            </p>
            <h1 className="text-5xl font-black leading-tight">
              Train smarter.{' '}
              <span className="text-brand-orange-accessible">Track every shot.</span>
            </h1>
            <p className="mt-6 text-lg text-gray-400 leading-relaxed">
              HoopTrack uses computer vision to automatically log your shots, map
              your zones, and reveal the patterns that improve your game.
            </p>
            <div id="download" className="mt-8 flex gap-4 items-center flex-wrap">
              <a
                href="https://apps.apple.com/app/hooptrack/id000000000"
                aria-label="Download HoopTrack on the App Store"
              >
                <Image
                  src="/app-store-badge.svg"
                  alt="Download on the App Store"
                  width={160}
                  height={54}
                />
              </a>
              <Link
                href="/features"
                className="text-sm text-gray-400 hover:text-white transition-colors underline underline-offset-4"
              >
                See all features →
              </Link>
            </div>
          </div>
          <div className="flex justify-center">
            <div className="w-[220px] h-[440px] bg-bg-card rounded-3xl border border-white/10 flex items-center justify-center text-gray-600 text-sm">
              App screenshot
            </div>
          </div>
        </div>
      </section>

      {/* Feature highlights */}
      <section className="py-20 px-6">
        <div className="max-w-6xl mx-auto">
          <h2 className="text-3xl font-black text-center mb-12">
            Everything you need to{' '}
            <span className="text-brand-orange-accessible">train like a pro.</span>
          </h2>
          <div className="grid md:grid-cols-3 gap-6">
            {FEATURES.map((f) => (
              <div
                key={f.title}
                className="bg-white/[0.04] backdrop-blur-md border border-white/[0.08] rounded-2xl p-6"
              >
                <div className="text-3xl mb-4">{f.icon}</div>
                <h3 className="font-bold text-lg mb-2">{f.title}</h3>
                <p className="text-gray-400 text-sm leading-relaxed">{f.body}</p>
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Screenshot gallery */}
      <section className="py-16 px-6 bg-bg-dark">
        <div className="max-w-6xl mx-auto">
          <h2 className="text-2xl font-black text-center mb-10">See it in action</h2>
          <div className="flex gap-4 overflow-x-auto pb-4 scrollbar-hide">
            {[1, 2, 3, 4].map((i) => (
              <div
                key={i}
                className="flex-shrink-0 w-[180px] h-[360px] bg-bg-card rounded-2xl border border-white/10 flex items-center justify-center text-gray-600 text-xs"
              >
                Screenshot {i}
              </div>
            ))}
          </div>
        </div>
      </section>

      {/* Download CTA */}
      <section className="py-20 px-6 text-center">
        <h2 className="text-3xl font-black mb-4">Ready to elevate your game?</h2>
        <p className="text-gray-400 mb-8">Free to download. No subscription required.</p>
        <a
          href="https://apps.apple.com/app/hooptrack/id000000000"
          aria-label="Download HoopTrack on the App Store"
          className="inline-block"
        >
          <Image
            src="/app-store-badge.svg"
            alt="Download on the App Store"
            width={160}
            height={54}
          />
        </a>
      </section>
    </>
  )
}
```

- [ ] **Step 2: Run dev server and verify the page renders**

```bash
npm run dev
```

Open http://localhost:3000. You should see: Nav, hero with orange headline, 3 feature cards, gallery row with placeholders, download CTA, Footer.

- [ ] **Step 3: Commit**

```bash
git add src/app/page.tsx
git commit -m "feat(12a): landing page — hero, feature cards, screenshot gallery, CTA"
```

---

## Task 4: Features, Privacy, Support pages

**Files:**
- Create: `src/app/features/page.tsx`
- Create: `src/app/privacy/page.tsx`
- Create: `src/app/support/page.tsx`

- [ ] **Step 1: Create features/page.tsx**

```tsx
// src/app/features/page.tsx
import type { Metadata } from 'next'

export const metadata: Metadata = { title: 'Features' }

const FEATURE_LIST = [
  { tag: 'CV', label: 'Real-time shot detection — no manual logging' },
  { tag: 'Science', label: 'Pose estimation for release angle, arc, and elbow alignment' },
  { tag: 'Zones', label: 'Court zone map with heat map and per-zone FG% breakdown' },
  { tag: 'Goals', label: 'Set shooting goals, earn badges, track skill ratings over time' },
  { tag: 'Dribble', label: 'Hand-tracking dribble drills with AR overlay (front camera)' },
  { tag: 'Agility', label: 'Shuttle run, lane agility, and vertical jump timer' },
  { tag: 'Export', label: 'Full session JSON export and Siri Shortcuts' },
  { tag: 'Sync', label: 'Cloud sync via Supabase — your data on every device' },
  { tag: 'Privacy', label: 'Local-first: sessions saved on device first, synced when online' },
]

export default function FeaturesPage() {
  return (
    <div className="max-w-3xl mx-auto px-6 py-20">
      <h1 className="text-4xl font-black mb-4">
        Everything you need to{' '}
        <span className="text-brand-orange-accessible">train like a pro.</span>
      </h1>
      <p className="text-gray-400 mb-12 text-lg">
        HoopTrack ships with a full suite of training tools — all on your iPhone.
      </p>
      <ul className="space-y-4">
        {FEATURE_LIST.map((f) => (
          <li key={f.label} className="flex gap-4 items-start">
            <span className="bg-brand-orange/15 text-brand-orange-accessible text-xs font-bold px-2 py-1 rounded-md mt-0.5 shrink-0">
              {f.tag}
            </span>
            <span className="text-gray-300">{f.label}</span>
          </li>
        ))}
      </ul>
    </div>
  )
}
```

- [ ] **Step 2: Create privacy/page.tsx**

```tsx
// src/app/privacy/page.tsx
import type { Metadata } from 'next'

export const metadata: Metadata = { title: 'Privacy Policy' }

export default function PrivacyPage() {
  return (
    <div className="max-w-3xl mx-auto px-6 py-20 prose prose-invert">
      <h1 className="text-4xl font-black mb-2">Privacy Policy</h1>
      <p className="text-gray-500 text-sm mb-12">Effective date: April 19, 2026</p>

      <section className="mb-10">
        <h2 className="text-xl font-bold mb-3">Data We Collect</h2>
        <p className="text-gray-400 leading-relaxed">
          HoopTrack collects the following data to provide its training features:
        </p>
        <ul className="text-gray-400 mt-3 space-y-2 list-disc list-inside">
          <li>Camera frames (processed on-device; not uploaded unless you enable cloud sync)</li>
          <li>Body pose keypoints for Shot Science metrics</li>
          <li>Shot coordinates (normalised court position, 0–1 scale)</li>
          <li>Session timing and drill metadata</li>
          <li>Account email address (for authentication)</li>
        </ul>
      </section>

      <section className="mb-10">
        <h2 className="text-xl font-bold mb-3">Data Retention</h2>
        <ul className="text-gray-400 space-y-2 list-disc list-inside">
          <li>Session videos: deleted after 7 days by default (configurable in Profile settings)</li>
          <li>Shot and session records: retained until you delete your account</li>
          <li>You can delete all data at any time from Profile → Delete All My Data</li>
        </ul>
      </section>

      <section className="mb-10">
        <h2 className="text-xl font-bold mb-3">Third-Party Services</h2>
        <ul className="text-gray-400 space-y-2 list-disc list-inside">
          <li><strong className="text-white">Supabase</strong> — cloud database for session sync (optional; data stays local if offline)</li>
          <li><strong className="text-white">PostHog</strong> — anonymous, privacy-friendly analytics on this website only; no personal data shared</li>
        </ul>
      </section>

      <section className="mb-10">
        <h2 className="text-xl font-bold mb-3">Your Rights</h2>
        <p className="text-gray-400 leading-relaxed">
          You can request deletion of all your data by using the in-app delete feature
          (Profile → Delete All My Data) or by contacting us at{' '}
          <a href="mailto:benr@edgesemantics.com" className="text-brand-orange-accessible hover:underline">
            benr@edgesemantics.com
          </a>
          . We will respond within 30 days.
        </p>
      </section>

      <section>
        <h2 className="text-xl font-bold mb-3">Contact</h2>
        <p className="text-gray-400">
          <a href="mailto:benr@edgesemantics.com" className="text-brand-orange-accessible hover:underline">
            benr@edgesemantics.com
          </a>
        </p>
      </section>
    </div>
  )
}
```

- [ ] **Step 3: Create support/page.tsx**

```tsx
// src/app/support/page.tsx
import type { Metadata } from 'next'

export const metadata: Metadata = { title: 'Support' }

const FAQ = [
  {
    q: 'How does shot detection work?',
    a: 'HoopTrack uses your iPhone camera with a YOLO-based computer vision model to detect the basketball and rim in real time. Every make and miss is logged automatically — no tapping required.',
  },
  {
    q: 'Do I need an internet connection to use the app?',
    a: 'No. Sessions are saved locally on your device and sync to the cloud when you have a connection. You can train fully offline.',
  },
  {
    q: 'Which iPhone models are supported?',
    a: 'HoopTrack requires iOS 16 or later. For best CV performance, an iPhone with an A15 chip or newer is recommended.',
  },
  {
    q: 'How do I delete my data?',
    a: 'Go to Profile → Delete All My Data inside the app. This permanently removes all sessions, shots, and your account from our servers.',
  },
  {
    q: 'I have a question not answered here.',
    a: 'Email us at benr@edgesemantics.com and we will get back to you within 48 hours.',
  },
]

export default function SupportPage() {
  return (
    <div className="max-w-3xl mx-auto px-6 py-20">
      <h1 className="text-4xl font-black mb-4">Support</h1>
      <p className="text-gray-400 mb-12 text-lg">Frequently asked questions.</p>
      <ul className="space-y-8">
        {FAQ.map((item) => (
          <li key={item.q} className="border-b border-white/[0.06] pb-8 last:border-0">
            <h2 className="font-bold text-lg mb-2">{item.q}</h2>
            <p className="text-gray-400 leading-relaxed">{item.a}</p>
          </li>
        ))}
      </ul>
    </div>
  )
}
```

- [ ] **Step 4: Verify all pages at dev server**

Navigate to:
- http://localhost:3000/features — list of 9 tagged features
- http://localhost:3000/privacy — full privacy policy with sections
- http://localhost:3000/support — 5 FAQ items

- [ ] **Step 5: Commit**

```bash
git add src/app/features src/app/privacy src/app/support
git commit -m "feat(12a): features, privacy, and support pages"
```

---

## Task 5: PostHog analytics + cookie consent → 12A ships

**Files:**
- Create: `src/components/PostHogProvider.tsx`
- Create: `src/components/CookieBanner.tsx`
- Modify: `src/app/layout.tsx`

- [ ] **Step 1: Create PostHogProvider.tsx**

```tsx
// src/components/PostHogProvider.tsx
'use client'
import posthog from 'posthog-js'
import { PostHogProvider as PHProvider } from 'posthog-js/react'
import { useEffect } from 'react'

export function PostHogProvider({ children }: { children: React.ReactNode }) {
  useEffect(() => {
    if (!process.env.NEXT_PUBLIC_POSTHOG_KEY) return
    posthog.init(process.env.NEXT_PUBLIC_POSTHOG_KEY, {
      api_host: process.env.NEXT_PUBLIC_POSTHOG_HOST ?? 'https://us.i.posthog.com',
      capture_pageview: true,
      persistence: 'memory', // no cookies until consent given
    })
  }, [])

  return <PHProvider client={posthog}>{children}</PHProvider>
}
```

- [ ] **Step 2: Create CookieBanner.tsx**

```tsx
// src/components/CookieBanner.tsx
'use client'
import posthog from 'posthog-js'
import { useEffect, useState } from 'react'

const CONSENT_KEY = 'hooptrack_analytics_consent'

export function CookieBanner() {
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    if (!localStorage.getItem(CONSENT_KEY)) setVisible(true)
  }, [])

  function accept() {
    localStorage.setItem(CONSENT_KEY, 'accepted')
    posthog.set_config({ persistence: 'localStorage+cookie' })
    setVisible(false)
  }

  function decline() {
    localStorage.setItem(CONSENT_KEY, 'declined')
    setVisible(false)
  }

  if (!visible) return null

  return (
    <div className="fixed bottom-0 inset-x-0 z-50 bg-bg-dark border-t border-white/[0.08] p-4 flex flex-col sm:flex-row items-start sm:items-center gap-4">
      <p className="text-sm text-gray-400 flex-1">
        We use anonymous analytics to improve HoopTrack. No personal data is sold.{' '}
        <a href="/privacy" className="underline text-brand-orange-accessible hover:text-white">
          Privacy policy
        </a>
      </p>
      <div className="flex gap-3 shrink-0">
        <button
          onClick={decline}
          className="text-sm text-gray-500 hover:text-white transition-colors"
        >
          Decline
        </button>
        <button
          onClick={accept}
          className="text-sm bg-brand-orange hover:bg-brand-orange-dark text-white font-bold px-4 py-2 rounded-xl transition-colors"
        >
          Accept
        </button>
      </div>
    </div>
  )
}
```

- [ ] **Step 3: Wire both into root layout.tsx**

```tsx
// src/app/layout.tsx
import type { Metadata } from 'next'
import './globals.css'
import { Nav } from '@/components/Nav'
import { Footer } from '@/components/Footer'
import { PostHogProvider } from '@/components/PostHogProvider'
import { CookieBanner } from '@/components/CookieBanner'

export const metadata: Metadata = {
  metadataBase: new URL('https://hooptrack.app'),
  title: {
    default: 'HoopTrack — Basketball Training Tracker',
    template: '%s | HoopTrack',
  },
  description:
    'Track every shot with computer vision. HoopTrack maps your zones, measures Shot Science, and shows your progress over time.',
  openGraph: {
    type: 'website',
    siteName: 'HoopTrack',
    images: [{ url: '/og-image.png', width: 1200, height: 630 }],
  },
  twitter: { card: 'summary_large_image' },
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <PostHogProvider>
          <Nav />
          <main>{children}</main>
          <Footer />
          <CookieBanner />
        </PostHogProvider>
      </body>
    </html>
  )
}
```

- [ ] **Step 4: Create a .env.local from the example**

```bash
cp .env.local.example .env.local
# Open .env.local and fill in:
# NEXT_PUBLIC_POSTHOG_KEY — get from PostHog dashboard (posthog.com)
# NEXT_PUBLIC_POSTHOG_HOST — use https://us.i.posthog.com (US region)
# Leave Supabase vars empty for now
```

- [ ] **Step 5: Verify cookie banner appears and can be dismissed**

```bash
npm run dev
```

Open http://localhost:3000 in a private/incognito window. Cookie banner should appear at the bottom. Accept and decline should both dismiss it.

- [ ] **Step 6: Set PostHog env vars on Vercel**

In the Vercel dashboard → project settings → Environment Variables, add:
- `NEXT_PUBLIC_POSTHOG_KEY` (Production + Preview)
- `NEXT_PUBLIC_POSTHOG_HOST` = `https://us.i.posthog.com` (Production + Preview)

- [ ] **Step 7: Push and verify Vercel production deploy**

```bash
git add -A
git commit -m "feat(12a): PostHog analytics + cookie consent — 12A complete"
git push
```

Wait for Vercel to deploy. Open the Vercel production URL and verify all four pages load.

> **✅ Phase 12A is live.**

---

## Task 6: court.ts utilities (TDD)

**Files:**
- Create: `src/__tests__/court.test.ts`
- Create: `src/lib/court.ts`

- [ ] **Step 1: Create test directory and write failing tests**

```bash
mkdir -p src/__tests__
```

```typescript
// src/__tests__/court.test.ts
import { describe, it, expect } from 'vitest'
import {
  toSvgCoords,
  classifyZone,
  computeFGPct,
  zoneHeatColor,
  ZONE_POLYGONS,
} from '@/lib/court'
import type { CourtZone, ShotRecord } from '@/types/hooptrack'

describe('toSvgCoords', () => {
  it('maps (0,0) to top-left of SVG', () => {
    expect(toSvgCoords(0, 0, 500, 470)).toEqual({ x: 0, y: 0 })
  })
  it('maps (1,1) to bottom-right of SVG', () => {
    expect(toSvgCoords(1, 1, 500, 470)).toEqual({ x: 500, y: 470 })
  })
  it('maps (0.5, 0.5) to centre', () => {
    expect(toSvgCoords(0.5, 0.5, 500, 470)).toEqual({ x: 250, y: 235 })
  })
})

describe('classifyZone', () => {
  it('classifies paint correctly', () => {
    expect(classifyZone(0.5, 0.1)).toBe<CourtZone>('paint')
  })
  it('classifies left corner three', () => {
    expect(classifyZone(0.05, 0.1)).toBe<CourtZone>('three_left_corner')
  })
  it('classifies right corner three', () => {
    expect(classifyZone(0.95, 0.1)).toBe<CourtZone>('three_right_corner')
  })
  it('classifies top-of-key three', () => {
    expect(classifyZone(0.5, 0.8)).toBe<CourtZone>('three_top')
  })
  it('classifies left wing three', () => {
    expect(classifyZone(0.1, 0.55)).toBe<CourtZone>('three_left_wing')
  })
  it('classifies right wing three', () => {
    expect(classifyZone(0.9, 0.55)).toBe<CourtZone>('three_right_wing')
  })
  it('classifies mid-range centre', () => {
    expect(classifyZone(0.5, 0.45)).toBe<CourtZone>('mid_range_center')
  })
  it('classifies mid-range left', () => {
    expect(classifyZone(0.2, 0.45)).toBe<CourtZone>('mid_range_left')
  })
  it('classifies mid-range right', () => {
    expect(classifyZone(0.8, 0.45)).toBe<CourtZone>('mid_range_right')
  })
})

describe('computeFGPct', () => {
  it('returns 0 for empty array', () => {
    expect(computeFGPct([])).toBe(0)
  })
  it('returns 100 for all makes', () => {
    const shots: Pick<ShotRecord, 'outcome'>[] = [
      { outcome: 'make' }, { outcome: 'make' },
    ]
    expect(computeFGPct(shots as ShotRecord[])).toBe(100)
  })
  it('returns 50 for half makes', () => {
    const shots: Pick<ShotRecord, 'outcome'>[] = [
      { outcome: 'make' }, { outcome: 'miss' },
    ]
    expect(computeFGPct(shots as ShotRecord[])).toBe(50)
  })
  it('rounds to one decimal place', () => {
    const shots: Pick<ShotRecord, 'outcome'>[] = [
      { outcome: 'make' }, { outcome: 'make' }, { outcome: 'miss' },
    ]
    expect(computeFGPct(shots as ShotRecord[])).toBeCloseTo(66.7, 1)
  })
})

describe('zoneHeatColor', () => {
  it('returns a non-empty string for any valid fgPct', () => {
    expect(zoneHeatColor(0)).toBeTruthy()
    expect(zoneHeatColor(50)).toBeTruthy()
    expect(zoneHeatColor(100)).toBeTruthy()
  })
  it('is redder at low FG%', () => {
    const low = zoneHeatColor(10)
    const high = zoneHeatColor(90)
    expect(low).not.toBe(high)
  })
})

describe('ZONE_POLYGONS', () => {
  const zones: CourtZone[] = [
    'paint', 'mid_range_left', 'mid_range_center', 'mid_range_right',
    'three_left_corner', 'three_right_corner', 'three_left_wing',
    'three_right_wing', 'three_top',
  ]
  it('defines all 9 zones', () => {
    expect(Object.keys(ZONE_POLYGONS)).toHaveLength(9)
  })
  zones.forEach((z) => {
    it(`polygon for ${z} has at least 3 points`, () => {
      expect(ZONE_POLYGONS[z].length).toBeGreaterThanOrEqual(3)
    })
    it(`all points in ${z} are in [0,1] range`, () => {
      ZONE_POLYGONS[z].forEach(([x, y]) => {
        expect(x).toBeGreaterThanOrEqual(0)
        expect(x).toBeLessThanOrEqual(1)
        expect(y).toBeGreaterThanOrEqual(0)
        expect(y).toBeLessThanOrEqual(1)
      })
    })
  })
})
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
npm test
```

Expected: multiple failures — `Cannot find module '@/lib/court'`

- [ ] **Step 3: Create src/lib/court.ts**

```typescript
// src/lib/court.ts
import type { CourtZone, ShotRecord } from '@/types/hooptrack'

// ---------------------------------------------------------------------------
// Coordinate conversion
// ---------------------------------------------------------------------------

/** Convert normalised 0–1 court fractions to SVG pixel coordinates.
 *  y=0 is the baseline (basket), y=1 is the half-court line.
 *  In SVG, y=0 is the top of the element, so y=0 (basket) maps to svgY=0. */
export function toSvgCoords(
  courtX: number,
  courtY: number,
  svgWidth: number,
  svgHeight: number,
): { x: number; y: number } {
  return { x: courtX * svgWidth, y: courtY * svgHeight }
}

// ---------------------------------------------------------------------------
// Zone classification (mirrors Swift CourtZoneClassifier)
// ---------------------------------------------------------------------------

export function classifyZone(x: number, y: number): CourtZone {
  // Paint: centre rectangle
  if (x >= 0.31 && x <= 0.69 && y <= 0.36) return 'paint'

  // Corners: narrow strips along sidelines within baseline area
  if (y <= 0.22) {
    if (x < 0.12) return 'three_left_corner'
    if (x > 0.88) return 'three_right_corner'
  }

  // Three-point arc radius ≈ 0.44 of court width from basket (x=0.5, y=0)
  const dx = x - 0.5
  const distFromBasket = Math.sqrt(dx * dx + y * y)
  const isThree = distFromBasket > 0.44

  if (isThree) {
    if (x < 0.35) return 'three_left_wing'
    if (x > 0.65) return 'three_right_wing'
    return 'three_top'
  }

  // Mid-range
  if (x < 0.4) return 'mid_range_left'
  if (x > 0.6) return 'mid_range_right'
  return 'mid_range_center'
}

// ---------------------------------------------------------------------------
// FG% calculation
// ---------------------------------------------------------------------------

export function computeFGPct(shots: ShotRecord[]): number {
  if (shots.length === 0) return 0
  const makes = shots.filter((s) => s.outcome === 'make').length
  return (makes / shots.length) * 100
}

// ---------------------------------------------------------------------------
// Zone heat map colour interpolation
// ---------------------------------------------------------------------------

function hexToRgb(hex: string): [number, number, number] {
  const r = parseInt(hex.slice(1, 3), 16)
  const g = parseInt(hex.slice(3, 5), 16)
  const b = parseInt(hex.slice(5, 7), 16)
  return [r, g, b]
}

function lerp(a: number, b: number, t: number) {
  return Math.round(a + (b - a) * t)
}

/** Returns an rgb() colour interpolated from red (0%) → orange (50%) → green (100%). */
export function zoneHeatColor(fgPct: number): string {
  const red = hexToRgb('#ef4444')
  const orange = hexToRgb('#FF6B35')
  const green = hexToRgb('#22c55e')

  let r: number, g: number, b: number
  if (fgPct <= 50) {
    const t = fgPct / 50
    r = lerp(red[0], orange[0], t)
    g = lerp(red[1], orange[1], t)
    b = lerp(red[2], orange[2], t)
  } else {
    const t = (fgPct - 50) / 50
    r = lerp(orange[0], green[0], t)
    g = lerp(orange[1], green[1], t)
    b = lerp(orange[2], green[2], t)
  }
  return `rgb(${r},${g},${b})`
}

// ---------------------------------------------------------------------------
// Zone polygon definitions (normalised 0–1 coordinates)
// ---------------------------------------------------------------------------

/** Approximate rectangular polygons for each CourtZone.
 *  Used to render the zone heat map overlay in ShotChart.
 *  y=0 = baseline/basket, y=1 = half-court line. */
export const ZONE_POLYGONS: Record<CourtZone, [number, number][]> = {
  paint: [
    [0.31, 0], [0.69, 0], [0.69, 0.36], [0.31, 0.36],
  ],
  mid_range_left: [
    [0.12, 0.22], [0.31, 0.22], [0.31, 0.58], [0.12, 0.58],
  ],
  mid_range_center: [
    [0.31, 0.36], [0.69, 0.36], [0.69, 0.58], [0.31, 0.58],
  ],
  mid_range_right: [
    [0.69, 0.22], [0.88, 0.22], [0.88, 0.58], [0.69, 0.58],
  ],
  three_left_corner: [
    [0, 0], [0.12, 0], [0.12, 0.22], [0, 0.22],
  ],
  three_right_corner: [
    [0.88, 0], [1, 0], [1, 0.22], [0.88, 0.22],
  ],
  three_left_wing: [
    [0, 0.22], [0.12, 0.22], [0.35, 0.58], [0, 0.75],
  ],
  three_right_wing: [
    [0.88, 0.22], [1, 0.22], [1, 0.75], [0.65, 0.58],
  ],
  three_top: [
    [0.35, 0.58], [0.65, 0.58], [0.72, 1], [0.28, 1],
  ],
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
npm test
```

Expected output:
```
✓ src/__tests__/court.test.ts (25 tests)
Test Files  1 passed
Tests  25 passed
```

- [ ] **Step 5: Commit**

```bash
git add src/__tests__/court.test.ts src/lib/court.ts
git commit -m "feat: court.ts utilities — toSvgCoords, classifyZone, computeFGPct, zoneHeatColor, ZONE_POLYGONS"
```

---

## Task 7: TypeScript types + Supabase clients

**Files:**
- Create: `src/types/hooptrack.ts`
- Create: `src/types/supabase.ts` (generated)
- Create: `src/lib/supabase/server.ts`
- Create: `src/lib/supabase/client.ts`

- [ ] **Step 1: Install @supabase/ssr**

```bash
npm install @supabase/supabase-js @supabase/ssr
```

- [ ] **Step 2: Create src/types/hooptrack.ts**

```typescript
// src/types/hooptrack.ts
// TypeScript mirrors of HoopTrack Swift models (snake_case matches Postgres columns)

export type ShotOutcome = 'make' | 'miss'

export type CourtZone =
  | 'paint'
  | 'mid_range_left'
  | 'mid_range_center'
  | 'mid_range_right'
  | 'three_left_corner'
  | 'three_right_corner'
  | 'three_left_wing'
  | 'three_right_wing'
  | 'three_top'

export type DrillType = 'free_shoot' | 'shot_science' | 'dribble' | 'agility'

export interface ShotRecord {
  id: string
  session_id: string
  court_x: number       // 0–1, mirrors ShotRecord.courtPosition.x
  court_y: number       // 0–1, mirrors ShotRecord.courtPosition.y
  angle: number         // release angle in degrees
  outcome: ShotOutcome
  zone: CourtZone
  created_at: string
}

export interface TrainingSession {
  id: string
  user_id: string
  started_at: string
  ended_at: string | null
  drill_type: DrillType
  fg_pct: number | null
  shot_count: number
  duration_seconds: number | null
  notes: string | null
}

export interface SkillRatings {
  shooting: number      // 0–100
  ball_handling: number
  agility: number
  shot_selection: number
}

export interface PlayerProfile {
  id: string
  user_id: string
  display_name: string
  skill_ratings: SkillRatings
  updated_at: string
}

export interface EarnedBadge {
  id: string
  user_id: string
  badge_id: string
  display_name: string
  description: string
  earned_at: string
}

export interface ZoneStats {
  zone: CourtZone
  attempts: number
  makes: number
  fg_pct: number
}
```

- [ ] **Step 3: Generate Supabase TypeScript types**

Make sure your `.env.local` has `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` filled in, then run:

```bash
npx supabase gen types typescript \
  --project-id nfzhqcgofuohsjhtxvqa \
  > src/types/supabase.ts
```

If prompted to login to Supabase CLI, run `npx supabase login` first. This generates types from the live Supabase schema. Re-run whenever schema changes.

- [ ] **Step 4: Create src/lib/supabase/server.ts**

```typescript
// src/lib/supabase/server.ts
// Use in Server Components, Server Actions, and Route Handlers.
import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import type { Database } from '@/types/supabase'

export async function createClient() {
  const cookieStore = await cookies()

  return createServerClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll()
        },
        setAll(cookiesToSet) {
          try {
            cookiesToSet.forEach(({ name, value, options }) =>
              cookieStore.set(name, value, options),
            )
          } catch {
            // setAll may throw in Server Components — safe to ignore
          }
        },
      },
    },
  )
}
```

- [ ] **Step 5: Create src/lib/supabase/client.ts**

```typescript
// src/lib/supabase/client.ts
// Use in Client Components ('use client').
import { createBrowserClient } from '@supabase/ssr'
import type { Database } from '@/types/supabase'

export function createClient() {
  return createBrowserClient<Database>(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
  )
}
```

- [ ] **Step 6: Verify typecheck passes**

```bash
npx tsc --noEmit
```

Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add src/types src/lib/supabase
git commit -m "feat: TypeScript types + Supabase server/browser clients"
```

---

## Task 8: Auth — login page, callback route, middleware

**Files:**
- Create: `src/app/login/page.tsx`
- Create: `src/app/auth/callback/route.ts`
- Create: `src/middleware.ts`

- [ ] **Step 1: Create the login page**

```tsx
// src/app/login/page.tsx
'use client'
import type { Metadata } from 'next'
import Link from 'next/link'
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

// Note: metadata can't be exported from a 'use client' file —
// move to a server wrapper if SEO for /login matters.

export default function LoginPage() {
  const router = useRouter()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setLoading(true)
    const supabase = createClient()
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    setLoading(false)
    if (error) {
      setError(error.message)
    } else {
      router.push('/dashboard')
      router.refresh()
    }
  }

  return (
    <div className="min-h-[calc(100vh-64px)] flex items-center justify-center px-6 bg-gradient-to-br from-bg-card to-bg-deep">
      <div className="w-full max-w-sm">
        <h1 className="text-3xl font-black text-center mb-2">Welcome back 👋</h1>
        <p className="text-gray-400 text-center text-sm mb-8">
          Sign in to your HoopTrack account
        </p>

        <form onSubmit={handleSubmit} className="space-y-4">
          <input
            type="email"
            placeholder="Email address"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            required
            className="w-full bg-white/[0.04] border border-white/10 rounded-xl px-4 py-3 text-sm placeholder:text-gray-600 focus:outline-none focus:border-brand-orange/50"
          />
          <input
            type="password"
            placeholder="Password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            required
            className="w-full bg-white/[0.04] border border-white/10 rounded-xl px-4 py-3 text-sm placeholder:text-gray-600 focus:outline-none focus:border-brand-orange/50"
          />

          {error && (
            <p className="text-red-400 text-sm text-center">{error}</p>
          )}

          <button
            type="submit"
            disabled={loading}
            className="w-full bg-brand-orange hover:bg-brand-orange-dark disabled:opacity-50 text-white font-bold py-3 rounded-xl transition-colors"
          >
            {loading ? 'Signing in…' : 'Sign In'}
          </button>
        </form>

        <p className="text-center text-sm text-gray-500 mt-6">
          Don&apos;t have an account?{' '}
          <Link
            href="/#download"
            className="text-brand-orange-accessible hover:underline"
          >
            Download the app to sign up
          </Link>
        </p>
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Create the auth callback route**

```typescript
// src/app/auth/callback/route.ts
import { NextResponse } from 'next/server'
import { createClient } from '@/lib/supabase/server'

export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url)
  const code = searchParams.get('code')
  const next = searchParams.get('next') ?? '/dashboard'

  if (code) {
    const supabase = await createClient()
    const { error } = await supabase.auth.exchangeCodeForSession(code)
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`)
    }
  }

  // Auth code missing or exchange failed — redirect to login with error
  return NextResponse.redirect(`${origin}/login?error=auth_callback_failed`)
}
```

- [ ] **Step 3: Create middleware.ts**

```typescript
// src/middleware.ts
import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

export async function middleware(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          )
          supabaseResponse = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          )
        },
      },
    },
  )

  // Refresh session — must call getUser() not getSession()
  const { data: { user } } = await supabase.auth.getUser()

  // Redirect unauthenticated users away from /dashboard
  if (!user && request.nextUrl.pathname.startsWith('/dashboard')) {
    const url = request.nextUrl.clone()
    url.pathname = '/login'
    return NextResponse.redirect(url)
  }

  return supabaseResponse
}

export const config = {
  matcher: [
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)',
  ],
}
```

- [ ] **Step 4: Verify auth redirect works**

```bash
npm run dev
```

Navigate to http://localhost:3000/dashboard — should redirect to http://localhost:3000/login (because you're not signed in).

- [ ] **Step 5: Commit**

```bash
git add src/app/login src/app/auth src/middleware.ts
git commit -m "feat(12b): auth — login page, callback route, middleware guard"
```

---

## Task 9: Dashboard shell + overview page

**Files:**
- Create: `src/components/DashboardSidebar.tsx`
- Create: `src/components/StatCard.tsx`
- Create: `src/app/dashboard/layout.tsx`
- Create: `src/app/dashboard/page.tsx`

- [ ] **Step 1: Create DashboardSidebar.tsx**

```tsx
// src/components/DashboardSidebar.tsx
'use client'
import Link from 'next/link'
import { usePathname, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Overview' },
  { href: '/dashboard/sessions', label: 'Sessions' },
  { href: '/dashboard/progress', label: 'Progress' },
  { href: '/dashboard/badges', label: 'Badges' },
]

export function DashboardSidebar({ email }: { email: string }) {
  const pathname = usePathname()
  const router = useRouter()

  async function signOut() {
    const supabase = createClient()
    await supabase.auth.signOut()
    router.push('/')
    router.refresh()
  }

  return (
    <>
      {/* Desktop sidebar */}
      <aside className="hidden lg:flex flex-col w-44 min-h-screen bg-bg-dark border-r border-white/[0.06] p-4 shrink-0">
        <div className="text-brand-orange-accessible font-black text-base mb-8 px-2">
          🏀 HoopTrack
        </div>
        <nav className="flex flex-col gap-1 flex-1">
          {NAV_ITEMS.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={`px-3 py-2 rounded-lg text-sm transition-colors ${
                pathname === item.href
                  ? 'bg-brand-orange/10 text-brand-orange-accessible font-semibold'
                  : 'text-gray-500 hover:text-white'
              }`}
            >
              {item.label}
            </Link>
          ))}
        </nav>
        <div className="text-xs text-gray-600 px-2 mb-2 truncate">{email}</div>
        <button
          onClick={signOut}
          className="text-xs text-gray-500 hover:text-white transition-colors text-left px-2"
        >
          Sign out
        </button>
      </aside>

      {/* Mobile top bar */}
      <div className="lg:hidden flex items-center justify-between px-4 py-3 bg-bg-dark border-b border-white/[0.06]">
        <span className="text-brand-orange-accessible font-black">🏀 HoopTrack</span>
        <nav className="flex gap-3 text-xs text-gray-400">
          {NAV_ITEMS.map((item) => (
            <Link
              key={item.href}
              href={item.href}
              className={pathname === item.href ? 'text-brand-orange-accessible font-semibold' : 'hover:text-white'}
            >
              {item.label}
            </Link>
          ))}
        </nav>
        <button onClick={signOut} className="text-xs text-gray-500 hover:text-white">
          Sign out
        </button>
      </div>
    </>
  )
}
```

- [ ] **Step 2: Create StatCard.tsx**

```tsx
// src/components/StatCard.tsx
interface StatCardProps {
  label: string
  value: string
  delta?: string
  deltaPositive?: boolean
}

export function StatCard({ label, value, delta, deltaPositive }: StatCardProps) {
  return (
    <div className="bg-white/[0.04] backdrop-blur-md border border-white/[0.08] rounded-2xl p-5">
      <p className="text-xs text-gray-500 uppercase tracking-wider mb-2">{label}</p>
      <p className="text-3xl font-black">{value}</p>
      {delta && (
        <p className={`text-xs mt-1 ${deltaPositive ? 'text-brand-orange-accessible' : 'text-gray-500'}`}>
          {delta}
        </p>
      )}
    </div>
  )
}
```

- [ ] **Step 3: Create dashboard/layout.tsx**

```tsx
// src/app/dashboard/layout.tsx
import { redirect } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { DashboardSidebar } from '@/components/DashboardSidebar'

export default async function DashboardLayout({
  children,
}: {
  children: React.ReactNode
}) {
  const supabase = await createClient()
  const { data: { user } } = await supabase.auth.getUser()

  if (!user) redirect('/login')

  return (
    <div className="flex min-h-screen bg-bg-deep">
      <DashboardSidebar email={user.email ?? ''} />
      <div className="flex-1 flex flex-col min-w-0">
        <main className="flex-1 p-6 lg:p-8">{children}</main>
      </div>
    </div>
  )
}
```

- [ ] **Step 4: Create dashboard/page.tsx (overview)**

```tsx
// src/app/dashboard/page.tsx
import { createClient } from '@/lib/supabase/server'
import { StatCard } from '@/components/StatCard'
import { computeFGPct } from '@/lib/court'
import type { TrainingSession, ShotRecord } from '@/types/hooptrack'
import Link from 'next/link'

export default async function DashboardPage() {
  const supabase = await createClient()

  // Sessions in last 7 days
  const sevenDaysAgo = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000).toISOString()

  const { data: recentSessions } = await supabase
    .from('training_sessions')
    .select('*')
    .gte('started_at', sevenDaysAgo)
    .order('started_at', { ascending: false })

  const { data: allSessions } = await supabase
    .from('training_sessions')
    .select('id, fg_pct, shot_count, started_at, ended_at, drill_type')
    .order('started_at', { ascending: false })
    .limit(5)

  const sessions = (recentSessions ?? []) as TrainingSession[]
  const latestSessions = (allSessions ?? []) as TrainingSession[]

  // Aggregate FG% across recent sessions (weight by shot count)
  const totalMakes = sessions.reduce((acc, s) => acc + ((s.fg_pct ?? 0) / 100) * s.shot_count, 0)
  const totalShots = sessions.reduce((acc, s) => acc + s.shot_count, 0)
  const avgFg = totalShots > 0 ? (totalMakes / totalShots) * 100 : 0

  const drillLabel: Record<string, string> = {
    free_shoot: 'Free Shoot',
    shot_science: 'Shot Science',
    dribble: 'Dribble',
    agility: 'Agility',
  }

  return (
    <div>
      <h1 className="text-2xl font-black mb-1">Overview</h1>
      <p className="text-gray-500 text-sm mb-8">Your training at a glance</p>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4 mb-10">
        <StatCard
          label="FG% (7 days)"
          value={totalShots > 0 ? `${avgFg.toFixed(1)}%` : '—'}
          delta={totalShots > 0 ? `${totalShots} shots across ${sessions.length} sessions` : undefined}
          deltaPositive
        />
        <StatCard
          label="Sessions (7 days)"
          value={String(sessions.length)}
        />
        <StatCard
          label="Total shots (7 days)"
          value={totalShots > 0 ? String(totalShots) : '—'}
        />
      </div>

      <h2 className="text-sm font-bold uppercase tracking-wider text-gray-500 mb-4">Recent Sessions</h2>
      <div className="space-y-2">
        {latestSessions.length === 0 && (
          <p className="text-gray-600 text-sm">No sessions yet. Start training in the app!</p>
        )}
        {latestSessions.map((s) => (
          <Link
            key={s.id}
            href={`/dashboard/sessions/${s.id}`}
            className="flex items-center justify-between p-4 bg-white/[0.04] border border-white/[0.06] rounded-xl hover:border-brand-orange/30 transition-colors"
          >
            <div>
              <span className="text-sm font-medium">
                {drillLabel[s.drill_type] ?? s.drill_type}
              </span>
              <span className="text-gray-600 text-xs ml-3">
                {new Date(s.started_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })}
              </span>
            </div>
            <div className="flex items-center gap-4 text-sm">
              <span className="text-gray-500">{s.shot_count} shots</span>
              {s.fg_pct != null && (
                <span className="text-brand-orange-accessible font-bold">
                  {s.fg_pct.toFixed(1)}%
                </span>
              )}
            </div>
          </Link>
        ))}
      </div>
    </div>
  )
}
```

- [ ] **Step 5: Sign in and verify the dashboard loads**

Go to http://localhost:3000/login, sign in with your HoopTrack credentials. Should redirect to http://localhost:3000/dashboard showing stat cards and recent sessions.

- [ ] **Step 6: Commit**

```bash
git add src/components/DashboardSidebar.tsx src/components/StatCard.tsx \
        src/app/dashboard/layout.tsx src/app/dashboard/page.tsx
git commit -m "feat(12b): dashboard shell — sidebar, overview with stat cards + recent sessions"
```

---

## Task 10: Sessions list page

**Files:**
- Create: `src/components/SessionCard.tsx`
- Create: `src/app/dashboard/sessions/page.tsx`

- [ ] **Step 1: Create SessionCard.tsx**

```tsx
// src/components/SessionCard.tsx
import Link from 'next/link'
import type { TrainingSession } from '@/types/hooptrack'

const DRILL_LABEL: Record<string, string> = {
  free_shoot: 'Free Shoot',
  shot_science: 'Shot Science',
  dribble: 'Dribble',
  agility: 'Agility',
}

interface Props {
  session: TrainingSession
}

export function SessionCard({ session }: Props) {
  const date = new Date(session.started_at).toLocaleDateString('en-US', {
    month: 'short', day: 'numeric', year: 'numeric',
  })
  const time = new Date(session.started_at).toLocaleTimeString('en-US', {
    hour: 'numeric', minute: '2-digit',
  })

  return (
    <Link
      href={`/dashboard/sessions/${session.id}`}
      className="flex items-center justify-between p-4 bg-white/[0.04] border border-white/[0.06] rounded-xl hover:border-brand-orange/30 transition-colors"
    >
      <div className="flex flex-col gap-1">
        <span className="text-sm font-medium">{date} · {time}</span>
        <span className="inline-block bg-brand-orange/10 text-brand-orange-accessible text-xs font-bold px-2 py-0.5 rounded-md w-fit">
          {DRILL_LABEL[session.drill_type] ?? session.drill_type}
        </span>
      </div>
      <div className="flex items-center gap-6 text-sm">
        <span className="text-gray-500 hidden sm:block">{session.shot_count} shots</span>
        {session.fg_pct != null ? (
          <span className="text-brand-orange-accessible font-bold w-14 text-right">
            {session.fg_pct.toFixed(1)}%
          </span>
        ) : (
          <span className="text-gray-600 w-14 text-right">—</span>
        )}
      </div>
    </Link>
  )
}
```

- [ ] **Step 2: Create sessions/page.tsx**

```tsx
// src/app/dashboard/sessions/page.tsx
import { createClient } from '@/lib/supabase/server'
import { SessionCard } from '@/components/SessionCard'
import type { TrainingSession } from '@/types/hooptrack'

interface Props {
  searchParams: Promise<{ from?: string; to?: string; type?: string }>
}

export default async function SessionsPage({ searchParams }: Props) {
  const params = await searchParams
  const supabase = await createClient()

  let query = supabase
    .from('training_sessions')
    .select('*')
    .order('started_at', { ascending: false })
    .limit(50)

  if (params.from) query = query.gte('started_at', params.from)
  if (params.to) query = query.lte('started_at', params.to + 'T23:59:59')
  if (params.type && params.type !== 'all') query = query.eq('drill_type', params.type)

  const { data } = await query
  const sessions = (data ?? []) as TrainingSession[]

  return (
    <div>
      <h1 className="text-2xl font-black mb-1">Sessions</h1>
      <p className="text-gray-500 text-sm mb-8">{sessions.length} sessions found</p>

      {/* Filters — submit as GET params for Server Component rendering */}
      <form className="flex flex-wrap gap-3 mb-8">
        <input
          type="date"
          name="from"
          defaultValue={params.from ?? ''}
          className="bg-white/[0.04] border border-white/10 rounded-xl px-3 py-2 text-sm focus:outline-none focus:border-brand-orange/50"
        />
        <input
          type="date"
          name="to"
          defaultValue={params.to ?? ''}
          className="bg-white/[0.04] border border-white/10 rounded-xl px-3 py-2 text-sm focus:outline-none focus:border-brand-orange/50"
        />
        <select
          name="type"
          defaultValue={params.type ?? 'all'}
          className="bg-white/[0.04] border border-white/10 rounded-xl px-3 py-2 text-sm focus:outline-none focus:border-brand-orange/50"
        >
          <option value="all">All types</option>
          <option value="free_shoot">Free Shoot</option>
          <option value="shot_science">Shot Science</option>
          <option value="dribble">Dribble</option>
          <option value="agility">Agility</option>
        </select>
        <button
          type="submit"
          className="bg-brand-orange hover:bg-brand-orange-dark text-white font-bold px-4 py-2 rounded-xl text-sm transition-colors"
        >
          Filter
        </button>
      </form>

      <div className="space-y-2">
        {sessions.length === 0 && (
          <p className="text-gray-600 text-sm">No sessions match your filters.</p>
        )}
        {sessions.map((s) => (
          <SessionCard key={s.id} session={s} />
        ))}
      </div>
    </div>
  )
}
```

- [ ] **Step 3: Verify filtering works**

Visit http://localhost:3000/dashboard/sessions. Try filtering by date range and drill type — page should reload with filtered results.

- [ ] **Step 4: Commit**

```bash
git add src/components/SessionCard.tsx src/app/dashboard/sessions/page.tsx
git commit -m "feat(12b): sessions list with date and drill-type filters"
```

---

## Task 11: ShotChart + ZoneTable components

**Files:**
- Create: `src/components/ShotChart.tsx`
- Create: `src/components/ZoneTable.tsx`

- [ ] **Step 1: Create ShotChart.tsx**

```tsx
// src/components/ShotChart.tsx
'use client'
import { toSvgCoords, zoneHeatColor, ZONE_POLYGONS } from '@/lib/court'
import type { ShotRecord, ZoneStats } from '@/types/hooptrack'

interface Props {
  shots: ShotRecord[]
  zoneStats: ZoneStats[]
  width?: number
  height?: number
}

// Half-court aspect ratio: 47ft wide × 50ft deep → viewBox 470×500
const VB_W = 470
const VB_H = 500

export function ShotChart({ shots, zoneStats, width = VB_W, height = VB_H }: Props) {
  const toX = (x: number) => x * VB_W
  const toY = (y: number) => y * VB_H

  const zoneColorMap = new Map(
    zoneStats.map((z) => [z.zone, zoneHeatColor(z.fg_pct)])
  )

  return (
    <div className="w-full">
      {/* Desktop: show chart */}
      <div className="hidden sm:block">
        <svg
          viewBox={`0 0 ${VB_W} ${VB_H}`}
          className="w-full max-w-md rounded-xl border border-white/10"
          aria-label="Shot chart"
        >
          {/* Court background */}
          <rect width={VB_W} height={VB_H} fill="#D7AD6B" rx={8} />

          {/* Zone heat map overlays */}
          {Object.entries(ZONE_POLYGONS).map(([zone, points]) => {
            const color = zoneColorMap.get(zone as ShotRecord['zone'])
            if (!color) return null
            const pts = points.map(([x, y]) => `${toX(x)},${toY(y)}`).join(' ')
            return (
              <polygon
                key={zone}
                points={pts}
                fill={color}
                fillOpacity={0.35}
                stroke={color}
                strokeOpacity={0.5}
                strokeWidth={1}
              />
            )
          })}

          {/* Court lines */}
          {/* Three-point arc */}
          <path
            d={`M ${toX(0.12)} ${toY(0)} A ${toX(0.44)} ${toX(0.44)} 0 0 1 ${toX(0.88)} ${toY(0)}`}
            fill="none"
            stroke="rgba(255,255,255,0.5)"
            strokeWidth={2}
          />
          {/* Corner three lines */}
          <line x1={toX(0.12)} y1={toY(0)} x2={toX(0.12)} y2={toY(0.22)} stroke="rgba(255,255,255,0.5)" strokeWidth={2} />
          <line x1={toX(0.88)} y1={toY(0)} x2={toX(0.88)} y2={toY(0.22)} stroke="rgba(255,255,255,0.5)" strokeWidth={2} />
          {/* Paint */}
          <rect
            x={toX(0.31)} y={toY(0)}
            width={toX(0.38)} height={toY(0.36)}
            fill="none"
            stroke="rgba(255,255,255,0.5)"
            strokeWidth={2}
          />
          {/* Free-throw circle */}
          <circle
            cx={toX(0.5)} cy={toY(0.36)}
            r={toX(0.12)}
            fill="none"
            stroke="rgba(255,255,255,0.4)"
            strokeWidth={1.5}
          />
          {/* Basket */}
          <circle
            cx={toX(0.5)} cy={toY(0.04)}
            r={6}
            fill="none"
            stroke="rgba(255,255,255,0.7)"
            strokeWidth={2}
          />

          {/* Shot dots */}
          {shots.map((shot) => {
            const { x, y } = toSvgCoords(shot.court_x, shot.court_y, VB_W, VB_H)
            return (
              <circle
                key={shot.id}
                cx={x}
                cy={y}
                r={6}
                fill={shot.outcome === 'make' ? '#22c55e' : '#ef4444'}
                fillOpacity={0.8}
                stroke="white"
                strokeWidth={1}
              />
            )
          })}
        </svg>

        {/* Legend */}
        <div className="flex gap-4 mt-3 text-xs text-gray-400">
          <span className="flex items-center gap-1.5">
            <span className="w-3 h-3 rounded-full bg-[#22c55e] inline-block" />
            Make
          </span>
          <span className="flex items-center gap-1.5">
            <span className="w-3 h-3 rounded-full bg-[#ef4444] inline-block" />
            Miss
          </span>
          <span className="text-gray-600 ml-2">Heat map = FG% by zone</span>
        </div>
      </div>

      {/* Mobile: show message instead */}
      <div className="sm:hidden text-sm text-gray-500 italic">
        Shot chart available on larger screens.
      </div>
    </div>
  )
}
```

- [ ] **Step 2: Create ZoneTable.tsx**

```tsx
// src/components/ZoneTable.tsx
import type { ZoneStats } from '@/types/hooptrack'

const ZONE_LABEL: Record<string, string> = {
  paint: 'Paint',
  mid_range_left: 'Mid Left',
  mid_range_center: 'Mid Centre',
  mid_range_right: 'Mid Right',
  three_left_corner: 'Left Corner 3',
  three_right_corner: 'Right Corner 3',
  three_left_wing: 'Left Wing 3',
  three_right_wing: 'Right Wing 3',
  three_top: 'Top of Key 3',
}

function fgColor(pct: number) {
  if (pct >= 60) return 'text-green-400'
  if (pct >= 45) return 'text-brand-orange-accessible'
  return 'text-red-400'
}

interface Props {
  stats: ZoneStats[]
}

export function ZoneTable({ stats }: Props) {
  if (stats.length === 0) {
    return <p className="text-gray-600 text-sm">No shots recorded.</p>
  }

  const sorted = [...stats].sort((a, b) => b.attempts - a.attempts)

  return (
    <table className="w-full text-sm">
      <thead>
        <tr className="text-xs text-gray-500 uppercase tracking-wider border-b border-white/[0.06]">
          <th className="text-left pb-3">Zone</th>
          <th className="text-right pb-3">Att</th>
          <th className="text-right pb-3">Makes</th>
          <th className="text-right pb-3">FG%</th>
        </tr>
      </thead>
      <tbody>
        {sorted.map((z) => (
          <tr key={z.zone} className="border-b border-white/[0.04] last:border-0">
            <td className="py-2.5 text-gray-300">{ZONE_LABEL[z.zone] ?? z.zone}</td>
            <td className="py-2.5 text-right text-gray-500">{z.attempts}</td>
            <td className="py-2.5 text-right text-gray-500">{z.makes}</td>
            <td className={`py-2.5 text-right font-bold ${fgColor(z.fg_pct)}`}>
              {z.fg_pct.toFixed(1)}%
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}
```

- [ ] **Step 3: Commit**

```bash
git add src/components/ShotChart.tsx src/components/ZoneTable.tsx
git commit -m "feat(12b): ShotChart SVG with heat map + ZoneTable breakdown"
```

---

## Task 12: Session detail page

**Files:**
- Create: `src/app/dashboard/sessions/[id]/page.tsx`

- [ ] **Step 1: Create the session detail page**

```tsx
// src/app/dashboard/sessions/[id]/page.tsx
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { ShotChart } from '@/components/ShotChart'
import { ZoneTable } from '@/components/ZoneTable'
import { classifyZone, computeFGPct } from '@/lib/court'
import type { ShotRecord, TrainingSession, ZoneStats, CourtZone } from '@/types/hooptrack'

interface Props {
  params: Promise<{ id: string }>
}

export default async function SessionDetailPage({ params }: Props) {
  const { id } = await params
  const supabase = await createClient()

  const [{ data: sessionData }, { data: shotsData }] = await Promise.all([
    supabase.from('training_sessions').select('*').eq('id', id).single(),
    supabase.from('shot_records').select('*').eq('session_id', id),
  ])

  if (!sessionData) notFound()

  const session = sessionData as TrainingSession
  const shots = (shotsData ?? []) as ShotRecord[]

  // Build zone stats from shot records
  const zoneMap = new Map<CourtZone, { attempts: number; makes: number }>()
  shots.forEach((shot) => {
    const zone = shot.zone ?? classifyZone(shot.court_x, shot.court_y)
    const existing = zoneMap.get(zone) ?? { attempts: 0, makes: 0 }
    zoneMap.set(zone, {
      attempts: existing.attempts + 1,
      makes: existing.makes + (shot.outcome === 'make' ? 1 : 0),
    })
  })

  const zoneStats: ZoneStats[] = Array.from(zoneMap.entries()).map(([zone, { attempts, makes }]) => ({
    zone,
    attempts,
    makes,
    fg_pct: attempts > 0 ? (makes / attempts) * 100 : 0,
  }))

  const overallFg = computeFGPct(shots)
  const makes = shots.filter((s) => s.outcome === 'make').length

  const drillLabel: Record<string, string> = {
    free_shoot: 'Free Shoot', shot_science: 'Shot Science',
    dribble: 'Dribble', agility: 'Agility',
  }

  const sessionDate = new Date(session.started_at).toLocaleDateString('en-US', {
    weekday: 'short', month: 'short', day: 'numeric', year: 'numeric',
  })

  return (
    <div>
      {/* Header */}
      <div className="flex flex-wrap items-baseline gap-4 mb-8">
        <h1 className="text-2xl font-black">
          {drillLabel[session.drill_type] ?? session.drill_type}
        </h1>
        <span className="text-gray-500 text-sm">{sessionDate}</span>
        {shots.length > 0 && (
          <>
            <span className="text-3xl font-black text-brand-orange-accessible">
              {overallFg.toFixed(1)}%
            </span>
            <span className="text-gray-500 text-sm">
              {makes} / {shots.length} makes
            </span>
          </>
        )}
      </div>

      {/* Shot chart + zone table */}
      {shots.length > 0 ? (
        <div className="grid lg:grid-cols-2 gap-8">
          <div>
            <h2 className="text-xs font-bold uppercase tracking-wider text-gray-500 mb-4">
              Shot Chart + Zone Heat Map
            </h2>
            <ShotChart shots={shots} zoneStats={zoneStats} />
          </div>
          <div>
            <h2 className="text-xs font-bold uppercase tracking-wider text-gray-500 mb-4">
              Zone Breakdown
            </h2>
            <ZoneTable stats={zoneStats} />
          </div>
        </div>
      ) : (
        <p className="text-gray-600 text-sm">
          No shot records for this session. Only shooting sessions have shot charts.
        </p>
      )}
    </div>
  )
}
```

- [ ] **Step 2: Verify session detail renders**

Click any session in the sessions list. You should see the header with session type and date, the shot chart on the left with zone heat map, and the zone breakdown table on the right.

- [ ] **Step 3: Commit**

```bash
git add src/app/dashboard/sessions/
git commit -m "feat(12b): session detail — shot chart + zone heat map + zone breakdown table"
```

---

## Task 13: Progress page

**Files:**
- Create: `src/components/FGPercentChart.tsx`
- Create: `src/components/SkillRatingBars.tsx`
- Create: `src/app/dashboard/progress/page.tsx`

- [ ] **Step 1: Install Recharts**

```bash
npm install recharts
```

- [ ] **Step 2: Create FGPercentChart.tsx**

```tsx
// src/components/FGPercentChart.tsx
'use client'
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid,
  Tooltip, ResponsiveContainer,
} from 'recharts'

interface DataPoint {
  date: string
  fg_pct: number
}

export function FGPercentChart({ data }: { data: DataPoint[] }) {
  if (data.length === 0) {
    return <p className="text-gray-600 text-sm">Not enough sessions to show a trend.</p>
  }

  return (
    <ResponsiveContainer width="100%" height={260}>
      <LineChart data={data} margin={{ top: 8, right: 16, bottom: 8, left: 0 }}>
        <CartesianGrid strokeDasharray="3 3" stroke="rgba(255,255,255,0.04)" />
        <XAxis
          dataKey="date"
          tick={{ fill: '#6b7280', fontSize: 11 }}
          tickLine={false}
          axisLine={false}
        />
        <YAxis
          domain={[0, 100]}
          tickFormatter={(v: number) => `${v}%`}
          tick={{ fill: '#6b7280', fontSize: 11 }}
          tickLine={false}
          axisLine={false}
          width={40}
        />
        <Tooltip
          formatter={(value: number) => [`${value.toFixed(1)}%`, 'FG%']}
          contentStyle={{
            background: '#1A1426',
            border: '1px solid rgba(255,255,255,0.08)',
            borderRadius: 12,
            color: '#fff',
          }}
          labelStyle={{ color: '#9ca3af', marginBottom: 4 }}
        />
        <Line
          type="monotone"
          dataKey="fg_pct"
          stroke="#FF6B35"
          strokeWidth={2}
          dot={{ fill: '#FF6B35', r: 4, strokeWidth: 0 }}
          activeDot={{ r: 6, fill: '#FF804F' }}
        />
      </LineChart>
    </ResponsiveContainer>
  )
}
```

- [ ] **Step 3: Create SkillRatingBars.tsx**

```tsx
// src/components/SkillRatingBars.tsx
import type { SkillRatings } from '@/types/hooptrack'

const SKILLS: { key: keyof SkillRatings; label: string }[] = [
  { key: 'shooting', label: 'Shooting' },
  { key: 'ball_handling', label: 'Ball Handling' },
  { key: 'agility', label: 'Agility' },
  { key: 'shot_selection', label: 'Shot Selection' },
]

export function SkillRatingBars({ ratings }: { ratings: SkillRatings }) {
  return (
    <div className="space-y-4">
      {SKILLS.map(({ key, label }) => {
        const value = ratings[key]
        return (
          <div key={key} className="flex items-center gap-4">
            <span className="text-sm text-gray-400 w-28 shrink-0">{label}</span>
            <div className="flex-1 h-2 bg-white/[0.06] rounded-full overflow-hidden">
              <div
                className="h-full bg-brand-orange rounded-full transition-all"
                style={{ width: `${value}%` }}
              />
            </div>
            <span className="text-sm font-bold text-brand-orange-accessible w-8 text-right">
              {value}
            </span>
          </div>
        )
      })}
    </div>
  )
}
```

- [ ] **Step 4: Create dashboard/progress/page.tsx**

```tsx
// src/app/dashboard/progress/page.tsx
import { createClient } from '@/lib/supabase/server'
import { FGPercentChart } from '@/components/FGPercentChart'
import { SkillRatingBars } from '@/components/SkillRatingBars'
import type { TrainingSession, PlayerProfile } from '@/types/hooptrack'

export default async function ProgressPage() {
  const supabase = await createClient()

  const [{ data: sessionsData }, { data: profileData }] = await Promise.all([
    supabase
      .from('training_sessions')
      .select('started_at, fg_pct, shot_count')
      .not('fg_pct', 'is', null)
      .order('started_at', { ascending: true })
      .limit(60),
    supabase
      .from('player_profiles')
      .select('skill_ratings, display_name')
      .single(),
  ])

  const sessions = (sessionsData ?? []) as Pick<TrainingSession, 'started_at' | 'fg_pct' | 'shot_count'>[]
  const profile = profileData as PlayerProfile | null

  const chartData = sessions
    .filter((s) => s.fg_pct != null)
    .map((s) => ({
      date: new Date(s.started_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' }),
      fg_pct: Number(s.fg_pct!.toFixed(1)),
    }))

  return (
    <div>
      <h1 className="text-2xl font-black mb-8">Progress</h1>

      <section className="mb-10">
        <h2 className="text-xs font-bold uppercase tracking-wider text-gray-500 mb-4">
          FG% Trend (last 60 sessions)
        </h2>
        <div className="bg-white/[0.04] border border-white/[0.08] rounded-2xl p-4">
          <FGPercentChart data={chartData} />
        </div>
      </section>

      {profile?.skill_ratings && (
        <section>
          <h2 className="text-xs font-bold uppercase tracking-wider text-gray-500 mb-4">
            Skill Ratings
          </h2>
          <div className="bg-white/[0.04] border border-white/[0.08] rounded-2xl p-6">
            <SkillRatingBars ratings={profile.skill_ratings} />
          </div>
        </section>
      )}
    </div>
  )
}
```

- [ ] **Step 5: Verify progress page renders**

Go to http://localhost:3000/dashboard/progress. You should see the FG% trend line chart and skill rating bars.

- [ ] **Step 6: Commit**

```bash
git add src/components/FGPercentChart.tsx src/components/SkillRatingBars.tsx \
        src/app/dashboard/progress/page.tsx
git commit -m "feat(12b): progress page — FG% trend chart (Recharts) + skill rating bars"
```

---

## Task 14: Badges page

**Files:**
- Create: `src/components/BadgeGrid.tsx`
- Create: `src/app/dashboard/badges/page.tsx`

- [ ] **Step 1: Create BadgeGrid.tsx**

```tsx
// src/components/BadgeGrid.tsx
import type { EarnedBadge } from '@/types/hooptrack'

interface Props {
  badges: EarnedBadge[]
}

export function BadgeGrid({ badges }: Props) {
  if (badges.length === 0) {
    return (
      <p className="text-gray-600 text-sm">
        No badges earned yet — keep training in the app!
      </p>
    )
  }

  return (
    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
      {badges.map((badge) => (
        <div
          key={badge.id}
          className="bg-white/[0.04] border border-white/[0.08] rounded-2xl p-4 flex flex-col items-center text-center"
          title={badge.description}
        >
          <div className="text-3xl mb-2">🏅</div>
          <p className="text-sm font-bold">{badge.display_name}</p>
          <p className="text-xs text-gray-500 mt-1">
            {new Date(badge.earned_at).toLocaleDateString('en-US', {
              month: 'short', day: 'numeric', year: 'numeric',
            })}
          </p>
        </div>
      ))}
    </div>
  )
}
```

- [ ] **Step 2: Create dashboard/badges/page.tsx**

```tsx
// src/app/dashboard/badges/page.tsx
import { createClient } from '@/lib/supabase/server'
import { BadgeGrid } from '@/components/BadgeGrid'
import type { EarnedBadge } from '@/types/hooptrack'

export default async function BadgesPage() {
  const supabase = await createClient()

  const { data } = await supabase
    .from('earned_badges')
    .select('*')
    .order('earned_at', { ascending: false })

  const badges = (data ?? []) as EarnedBadge[]

  return (
    <div>
      <h1 className="text-2xl font-black mb-2">Badges</h1>
      <p className="text-gray-500 text-sm mb-8">{badges.length} earned</p>
      <BadgeGrid badges={badges} />
    </div>
  )
}
```

- [ ] **Step 3: Verify badges page renders**

Go to http://localhost:3000/dashboard/badges. If you have badges in Supabase, they should appear. An empty state message appears if not.

- [ ] **Step 4: Commit**

```bash
git add src/components/BadgeGrid.tsx src/app/dashboard/badges/page.tsx
git commit -m "feat(12b): badges page — earned badge grid"
```

---

## Task 15: CI, responsive polish, and final ship

**Files:**
- Create: `.github/workflows/ci.yml`
- Modify: `src/app/dashboard/layout.tsx` (remove duplicate Nav for dashboard pages)

- [ ] **Step 1: Create GitHub Actions CI**

```bash
mkdir -p .github/workflows
```

```yaml
# .github/workflows/ci.yml
name: CI
on: [pull_request]
jobs:
  typecheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 20
          cache: npm
      - run: npm ci
      - run: npm run lint
      - run: npx tsc --noEmit
      - run: npm test
```

- [ ] **Step 2: Remove Nav and Footer from dashboard pages**

The root layout adds `Nav` and `Footer` to every page, but the dashboard has its own sidebar. Update `src/app/dashboard/layout.tsx` to wrap in a div that hides the marketing Nav:

Actually, the cleanest solution is a separate layout group. Create a route group for marketing pages:

Rename `src/app/layout.tsx` so that Nav/Footer only appear on marketing pages:

```tsx
// src/app/(marketing)/layout.tsx  — NEW file
import { Nav } from '@/components/Nav'
import { Footer } from '@/components/Footer'
import { PostHogProvider } from '@/components/PostHogProvider'
import { CookieBanner } from '@/components/CookieBanner'

export default function MarketingLayout({ children }: { children: React.ReactNode }) {
  return (
    <PostHogProvider>
      <Nav />
      <main>{children}</main>
      <Footer />
      <CookieBanner />
    </PostHogProvider>
  )
}
```

Move these pages into `src/app/(marketing)/`:
```bash
mkdir -p src/app/\(marketing\)
mv src/app/page.tsx src/app/\(marketing\)/page.tsx
mv src/app/features src/app/\(marketing\)/features
mv src/app/privacy src/app/\(marketing\)/privacy
mv src/app/support src/app/\(marketing\)/support
```

Update the root `src/app/layout.tsx` to remove Nav/Footer (keep metadata + html shell only):

```tsx
// src/app/layout.tsx
import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  metadataBase: new URL('https://hooptrack.app'),
  title: {
    default: 'HoopTrack — Basketball Training Tracker',
    template: '%s | HoopTrack',
  },
  description:
    'Track every shot with computer vision. HoopTrack maps your zones, measures Shot Science, and shows your progress over time.',
  openGraph: {
    type: 'website',
    siteName: 'HoopTrack',
    images: [{ url: '/og-image.png', width: 1200, height: 630 }],
  },
  twitter: { card: 'summary_large_image' },
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  )
}
```

Also move `sitemap.ts` back to `src/app/sitemap.ts` (not inside the marketing group — sitemaps must be at the root app level).

- [ ] **Step 3: Verify typecheck and tests pass**

```bash
npx tsc --noEmit
npm test
npm run lint
```

Expected: 0 errors, 25 tests passing, 0 lint errors.

- [ ] **Step 4: Run a final dev server smoke test**

```bash
npm run dev
```

Check:
- http://localhost:3000 — landing page with Nav + Footer
- http://localhost:3000/features — features list
- http://localhost:3000/privacy — privacy policy
- http://localhost:3000/support — FAQ
- http://localhost:3000/login — login form, no Nav sidebar
- http://localhost:3000/dashboard — redirects to /login if not signed in; shows overview if signed in
- http://localhost:3000/dashboard/sessions — session list with filters
- http://localhost:3000/dashboard/sessions/[any-id] — shot chart + zone table
- http://localhost:3000/dashboard/progress — FG% chart + skill bars
- http://localhost:3000/dashboard/badges — badge grid

- [ ] **Step 5: Add Supabase env vars to Vercel for 12B**

In the Vercel dashboard → project settings → Environment Variables, add (Production + Preview):
- `NEXT_PUBLIC_SUPABASE_URL` = `https://nfzhqcgofuohsjhtxvqa.supabase.co`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY` — get from Supabase dashboard → Settings → API → `anon` `public` key

- [ ] **Step 6: Final commit and push**

```bash
git add -A
git commit -m "feat(12b): CI, responsive layout groups, final smoke test — Phase 12 complete"
git push
```

Wait for Vercel deploy to complete. Verify the production URL shows the marketing site and dashboard.

> **✅ Phase 12 (12A + 12B) is live.**

- [ ] **Step 7: Update ROADMAP.md in the iOS project**

In `/Users/benridges/Documents/projects/docs/ROADMAP.md`, update the Phase 12 row:

```markdown
| 12 | Web Presence | ✅ Complete |
```

And update the Phase 12 section header from `🔜 Planned` to `✅ Complete`, noting the spec at `HoopTrack/docs/superpowers/specs/2026-04-19-phase-12-web-presence-design.md`.

```bash
cd /Users/benridges/Documents/projects/HoopTrack
git add docs/ROADMAP.md
git commit -m "docs: mark Phase 12 complete in ROADMAP"
```

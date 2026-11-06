# App Store listing

Draft copy for App Store Connect. The character limits are Apple's.

## Name and subtitle

| Field | Text | Limit |
|---|---|---|
| Name | HoopTrack | 30 |
| Subtitle | Shot tracking for basketball | 30 |

## Promotional text (170, can change without review)

Prop your phone behind you and shoot. HoopTrack calls every make and miss,
maps where you shot from, and now runs best-of-seven playoffs against your
own percentages.

## Description (4000)

HoopTrack watches the ball and the rim so you don't have to count. Stand
your phone sideways behind where you shoot, start a session and play.

SHOT TRACKING
• Makes and misses called automatically, on your phone. No sensors, no
  subscription.
• Every shot placed on a court chart, by zone.
• Release angle and arc from the ball's flight.
• Unsure calls are flagged so you can confirm them with one tap.
• Score by hand any time, with or without a hoop in view.

PLAYOFFS
• Four rounds, best of seven, from the arc, mid-range or the line.
• Each round needs more makes. Lose a series and earn your way back with
  a comeback drill aimed at your weakest spot.

DRILLS
• Around the arc, free throw sets, mid-range pull-ups, a timed five-minute
  shootout, Mikan drill.
• Ball handling with dribble counting from the front camera.
• Shuttle run and lane agility timers.

PROGRESS
• Field goal % over time, shot charts, zones, skill ratings, goals and
  badges.
• Watch any session back and jump straight to each shot.
• Pickup games with a box score for 1v1 to 3v3.

PRIVATE BY DEFAULT
• Everything works offline with no account.
• Session videos never leave your phone.
• An optional account backs up your sessions. Delete it in the app at any
  time.
• Optional Face ID lock and Apple Health workouts.

## Keywords (100, comma-separated, no spaces)

```
basketball,shooting,shot tracker,jumpshot,free throw,three,hoops,drills,workout,fg,training,coach
```

## Categories

- Primary: Sports
- Secondary: Health & Fitness

## URLs

- Privacy policy: required. Host `privacy-policy.md` (e.g. `https://hooptrack.app/privacy`).
- Support: required. A page or a mailto with a contact address.
- Marketing: optional.

## Age rating

Answer "None" to every content question. There's no user-generated content
shared with others, no web browsing and no gambling. That gives **4+**.

## Screenshots

These need the 6.9" (1320 × 2868) and 6.5" (1284 × 2778) sizes. Use
portrait for the tabs and landscape for the live session:

1. Live session, tracking: HUD with makes, the hoop bracket and the shot flash.
2. Playoffs HUD in a game, with the series score.
3. Progress: headline FG %, trend and shot chart.
4. Session replay jumping between shots.
5. Train tab with a playoff run in progress.
6. Summary with a flagged "Check" call being confirmed.

## Review notes

> No account is needed; every feature works signed out. To see shot
> tracking without a hoop, start a session and use the Make / Miss buttons
> (bottom right), or point the camera at any basketball hoop. The camera is
> used only on-device to follow the ball. Videos stay on the phone. An
> optional email account backs up sessions; Profile → Delete account
> removes it and its data from our servers.

## Export compliance

The app only uses standard encryption provided by Apple (HTTPS/TLS and the
Keychain), so `ITSAppUsesNonExemptEncryption` is set to `NO` in Info.plist.
App Store Connect then doesn't ask for documentation.

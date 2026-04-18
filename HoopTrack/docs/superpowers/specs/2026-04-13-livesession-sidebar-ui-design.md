# LiveSessionView Sidebar UI Redesign

**Date:** 2026-04-13
**Scope:** Visual overhaul of the right sidebar in `LiveSessionView` — Sport Broadcast style.

## Summary

Redesign the 140pt right sidebar from its current flat/minimal look to a sport broadcast scoreboard style. Same information, better visual hierarchy. Compact typography optimised for close-range reading (user is near the phone/camera).

## Design Decisions

- **Style:** Sport Broadcast — dark gradient cards, orange accent, ESPN-overlay vibe
- **Width:** Keep at 140pt (no change)
- **Info shown:** Same as current — FG%, made/miss count, timer, recent shots, pause/stats/end buttons
- **Typography:** Small (7-9pt uppercase labels), readable at arm's length only
- **No new data:** No streak counters, zone labels, or mini court map added

## Visual Spec

### Sidebar Background

- Replace `Color.black.opacity(0.85)` with a vertical gradient: `#111118` → `#08080d`
- 10pt horizontal padding, 10pt vertical padding
- 6pt gap between card sections

### FG% Card (top)

- Card: rounded rect (12pt radius), gradient bg `#1a1a2e` → `#12121f`, 1px border `rgba(255,149,0,0.15)` (orange tint)
- "FIELD GOAL" label: 8pt, weight 700, color `rgba(255,149,0,0.6)`, letter-spacing 1.5px
- FG% number: 34pt, weight 900, color `#ff9500` (orange), letter-spacing -2px. The `%` is 16pt superscript.
- On make/miss: briefly tint green/red (existing `fgTintColor` logic), resting state is orange
- MADE/MISS split row below: background `rgba(255,255,255,0.04)`, rounded 6pt
  - Made count: 14pt weight 800, green `#34c759`; "MADE" label 7pt, `rgba(255,255,255,0.3)`
  - Miss count: 14pt weight 800, red `#ff3b30`; "MISS" label 7pt, `rgba(255,255,255,0.3)`
  - Separated by 1px vertical line `rgba(255,255,255,0.08)`

### Timer Card

- Same card style as FG% but with `rgba(255,255,255,0.06)` border (no orange tint)
- "TIME" label: 8pt, weight 700, `rgba(255,255,255,0.3)`, letter-spacing 1.5px
- Time value: 22pt, weight 800, white, monospaced, letter-spacing 1px
- "PAUSED" label below when paused: 8pt bold, yellow (existing behaviour)

### Recent Shots Card (middle)

- Same card style, `rgba(255,255,255,0.06)` border
- "RECENT" label: 7pt, weight 700, `rgba(255,255,255,0.25)`, letter-spacing 1.5px
- Shot indicators: rounded bars (16pt wide x 5pt tall, 3pt radius) instead of circles
  - Green `#34c759` for makes, red `#ff3b30` for misses
  - Latest shot has a glow: `box-shadow 0 0 4px` with the shot colour at 50% opacity
  - 3pt gap between bars

### Control Buttons (bottom)

- Pause and stats buttons: 36x36pt rounded squares (10pt radius) instead of circles
  - Background `rgba(255,255,255,0.06)`, border 1px `rgba(255,255,255,0.1)`
  - Icon colour `rgba(255,255,255,0.5)`, same SF Symbols as current
  - 6pt gap between buttons

### End Session Button

- Gradient background: `#d42020` → `#ff3b30`
- Rounded rect 8pt radius
- Text: 9pt, weight 800, white, letter-spacing 1.5px, all caps "END SESSION"
- Subtle shadow: `0 2px 8px rgba(255,59,48,0.25)`
- Still uses `HoldToEndButton` long-press behaviour — visual styling changes only

## Files Changed

1. **`HoopTrack/Views/Train/LiveSessionView.swift`** — rewrite `sidebar` computed property with new card-based layout
2. **`HoopTrack/Views/Components/HoldToEndButton.swift`** — update visual styling (gradient, rounded rect, uppercase text)

## Out of Scope

- Camera area / main content changes
- ShotGlowOverlay changes
- Manual shot buttons styling
- Calibration overlay styling
- MidSessionBreakdownView changes
- Adding new information or features to the sidebar

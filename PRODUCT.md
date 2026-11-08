# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Ben, a solo player training indoors in a lit gym. He shoots on his own, chases his own rebounds, and sets the phone on a tripod or stand a few metres behind where he shoots. During a session he is 3–6 m from the screen with his hands full, so he glances at it rather than reads it, and touches it only between shots.

## Product Purpose

HoopTrack turns an iPhone into a shooting coach: the camera watches the hoop, calls each make or miss on its own, and keeps the numbers (field goal %, zones, arc, streaks, goals, playoffs) without anyone keeping score by hand. Success is a session where the player never has to walk back to the phone except to end it, and trusts the count when he does.

## Positioning

On-device ball and rim tracking from a phone on a stand, with every call checkable afterwards against the session's own video. Works fully offline; an account only adds cloud backup.

## Operating Context

- Live shooting is landscape, full-bleed camera, phone fixed on a stand behind the shooter; the rim usually sits in the upper-middle of the picture.
- Indoor gym lighting. The screen is read from across the key, not up close.
- Sessions run 10–40 minutes; named drills (Around the arc, Free throws, Mid-side-mid, 5-minute endurance) and solo best-of-seven playoff runs ride on the same live screen.
- Session options (Profile → Session options) add spoken calls or sounds, setup tips, drill steps, auto-pause, screen dimming and a best to beat.

## Capabilities and Constraints

- SwiftUI, iOS 17+, iPhone 14 class hardware; the camera, detector and recorder run for the whole session, so battery and heat matter.
- Manual Make / Miss / Undo stay available; while the hoop is tracked they hide until the picture is tapped, and tapping the other result right after a call changes it.
- Ending a session is a hold-to-end gesture so a stray touch can't end it.
- Green and red are reserved for make and miss.

## Brand Commitments

- Established look: "gym at night" (Design/Theme.swift): near-black court surfaces, one basketball-leather orange accent, compressed heavy scoreboard numerals, flat panels without borders or blur.
- Minimal and uncluttered: simple, clear, nice to look at, one clear primary thing per screen (Ben, confirmed for the live screen redesign, 8 Nov 2026).
- No cream/terracotta/serif "AI default" look.

## Evidence on Hand

- Real court footage (CC BY 3.0) in ~/Projects/hoop-footage with frame-accurate labels; usable for mockup backdrops, attributed per ATTRIBUTION.md.
- No testimonials, customers or App Store reviews exist; none may be invented.

## Product Principles

1. Readable from the shooting spot: the one number that matters is legible at 5 m; everything else waits.
2. Hands-off by default: the tracker and the voice do the work, touch is the exception.
3. The camera picture is the player's aim: never cover the rim.
4. Trust through checkability: every call can be seen and fixed.

## Accessibility & Inclusion

VoiceOver gets every call and setup tip as an announcement; controls keep labels and hints. Make/miss colour always comes with a word or symbol.

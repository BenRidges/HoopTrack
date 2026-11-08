---
version: 1
slug: "optrack-views-train-livesessionview-swift-36523b99"
primary_target: "HoopTrack/HoopTrack/Views/Train/LiveSessionView.swift"
related_targets: ["HoopTrack/HoopTrack/Views/Train/LiveSessionOverlays.swift"]
---

# Live shooting session

Scope: the landscape live shooting screen (LiveSessionView and its overlays). Mode: operate. Audience: a solo player shooting in a lit gym, phone on a stand 3–6 m behind; glances, touches only between shots. Task: trust the count from the shooting spot; fix a call, pause or end when walking up. Constraints: never cover the rim (top-centre in real setups); green/red only for calls; hold-to-end; VoiceOver keeps every control.

Chosen: Edge-lit frame (round 1, option C), Quiet arrangement (round 2, C2) as the default and Centre (C3) as a Session options choice ("Live screen layout"), per Ben 8 Nov 2026.

## Direction contract

THESIS: The camera owns the screen; the session lives in two readings and a lit edge. Refuses the floating-pill HUD with a status chip, cards and buttons in every corner.

OWN-WORLD: Gym at night: court-black, leather orange only for "act here / what's next", make green and miss red only for calls. Compressed heavy scoreboard numerals straight on the picture with a soft shadow over a bottom fade; no panels at rest, no blur, no borders except the edge line.

STORY: From the shooting spot the player reads makes over attempts and sees the screen's edge flash green or red with each call. Walking up, one tap brings every control into one place; nothing else ever asks for attention unless the setup or the session needs it.

FIRST VIEWPORT: Quiet: bottom-left, a call word (MAKE / MISS, or the session's state) over makes at ~118 pt and "/attempts" at ~48 pt, then "% · best" and the drill step; bottom-right, the clock at ~36 pt; nothing else. Tap: one bottom-right row of clock, Pause, Hold to end, Undo, Miss, Make. Centre: the same block centred at the bottom with %, drill and clock on one line; Pause bottom-left and Hold to end bottom-right always; tap puts Undo+Miss left and Make right of the number. Setup and coach text sit bottom-centre on the picture.

FORM: Edge-lit frame, 5th on my ordered list of seven; seed:f20246982bc8bc0f.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

Signature interaction: the edge. A 4 pt line inset along the screen's rounded corners: green or red for ~1.2 s on each call, then fades; leather and slowly breathing while finding the hoop or when a setup tip needs fixing; dim white while paused. At rest, no line. Motion: fade in 0.12 s, hold, ease-out 0.6 s; Reduce Motion keeps colour, drops the breathing.

Unresolved: none.

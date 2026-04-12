# HoopTrack Backlog

Items deferred from active phases for future consideration. Not committed to any timeline.

---

## Athleticism — Strength Metric

**Deferred from:** Phase 5A (2026-04-11)
**Context:** `SkillRatingCalculator.athleticismScore` currently uses vertical jump (60%) and shuttle run (40%). A strength component was discussed but no measurable data source exists yet.

**What we want:** A strength input that reflects lower-body or upper-body power — not a proxy of vertical jump, which already carries 60% weight.

**Candidates to explore:**
- Box jump height (requires agility drill instrumentation)
- Push-up / pull-up count (manual entry)
- Estimated power from jump impulse curve (Vision body pose + frame rate)
- Resistance band / weight training integration (third-party API)

**When to revisit:** When a new agility or gym drill type is added that can collect a strength-specific measurement. At that point, add a `strengthScore` input to `SkillRatingCalculator.athleticismScore` with weight ~20% (redistributing from vertical and shuttle).

---
name: phase-start
description: Start a new HoopTrack implementation phase. Creates a git worktree, verifies ROADMAP alignment, and scaffolds the plan doc.
---

# Starting a New Implementation Phase

Follow these steps when beginning any phase from `docs/ROADMAP.md`.

## Step 1 — Verify prerequisites

Read `docs/ROADMAP.md` and confirm:
- The previous phase is complete and merged to main
- All prerequisites listed for this phase are satisfied
- Any outstanding technical debt items that should be fixed first (see the debt table in ROADMAP)

## Step 2 — Create a git worktree

```bash
# Replace PHASE with e.g. phase7-security, phase8-auth
git worktree add HoopTrack/.claude/worktrees/PHASE -b feat/PHASE
```

## Step 3 — Scaffold the plan document

Create `docs/superpowers/plans/YYYY-MM-DD-PHASE-plan.md` with:

```markdown
# HoopTrack — Phase N Plan: [Name]

**Date:** YYYY-MM-DD
**Status:** In progress
**Prerequisites:** [from ROADMAP]

## Tasks

| # | Task | File(s) | Done |
|---|------|---------|------|
| 1 | ... | ... | [ ] |

## Key decisions

...

## Testing approach

...
```

## Step 4 — Begin implementation

Work through tasks in the plan document in order. Mark each `[x]` as complete.
Use the `superpowers:test-driven-development` skill before writing implementation code.

## Step 5 — Finish

When all tasks are done, use `superpowers:finishing-a-development-branch` to merge.
Delete the plan doc once the branch is merged (completed plans are removed per project convention).

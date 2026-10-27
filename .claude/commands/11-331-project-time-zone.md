---
description: "Task 11.331 — a deployment day is the field site's day, wherever the person looking at it is"
model: opus
---

Implement task **11.331** from `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`. Read that entry, `CLAUDE.md` standing decision 4,
the notes at the top of `packages/tritrack_sync/lib/src/deployment_interlock.dart`, tasks 11.264, 11.266, 11.276 and
11.326, and `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md`.

1. Projects get a time zone: default from the centre of the project area (always the centre's own zone, a sea
   zone if it is at sea, never the nearest land; the creator's zone if no area), confirmed and changeable at creation, works offline.
2. Each deployment row keeps the zone its days were written in; screens, "today", overlap rules and export use it.
3. The project zone can be changed later; recorded days stay the same days; no row rewritten.
4. The server's bare-day test uses the row's zone. Re-prove the overlap rules (other-zone entry, mid-season change,
   both DST transitions, Arizona/Navajo).
5. Migrate existing rows; season clone and import carry the zone; schema bump with old/new app behavior stated.
6. `deployments.csv` adds plain-date days and the zone name.
7. The time-zone library is a §3.8 decision: named, pinned, justified, alternatives stated.

Watched red first. Full night green. Copy list. Progress lines. **Do not run `dart format`.** Stage only the files
you changed, by name. End with Michael's one-device check, one step at a time. Report into `CLAUDE_DOCS/TASK_COMMS.md`.

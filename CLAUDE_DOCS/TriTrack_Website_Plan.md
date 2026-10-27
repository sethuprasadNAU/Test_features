# Tri Track Website Addition — Plan

Not yet built. This documents the agreed scope/design for adding Tri Track to the
UAV-RT lab website (`/Users/mws22/Library/CloudStorage/OneDrive-NorthernArizonaUniversity/CODE_PLAYGROUND/uavrt_website`)
so a future session can pick this up without re-deriving it.

## Context

The website repo is a separate project: a plain static HTML/CSS/JS site (no
framework, no build step, no `package.json`) for **UAV-RT**, a drone-based
wildlife radio-telemetry system from the same lab (PI: Michael Shafer, NAU).
It's a deliberately minimal 6-page sales/collaboration site — Home, Technology,
Field Results, Publications, Team, Collaborate — built to fit one conversion
goal ("get an ecologist to reach out"). Every page shares one hand-authored
stylesheet (`css/styles.css`) and repeats the same header/nav/footer markup
verbatim (no templating). Deep technical/build material is deliberately kept
off-site on GitBook rather than reproduced. Planning docs to read before
touching this repo: `CLAUDE.md`, `SITE_MAP.md`, `CONTENT_BRIEF.md` (all at the
website repo root).

Tri Track is a different, second product from the same lab — a field-use
companion app for wildlife VHF telemetry (bearing capture, Lenth MLE
triangulation, offline maps/viewshed, team data sharing). It has no existing
presence on this site.

## Decisions made (confirmed with the user)

1. **Two additions, not one:**
   - A **feature/sales page** (like `technology.html`'s tone — benefits-first,
     highlight main features) — NOT documentation.
   - A **deep docs section**, PX4-documentation-style: a left sidebar nav,
     how-to-manual structure, markdown-authored content with screenshots.
2. **Docs tooling: Docsify.** No build step (fits this site's "just static
   files" philosophy), pure client-side markdown renderer via one CDN
   `<script>` tag, auto-generates the left sidebar from a `_sidebar.md`. This
   is the only new "dependency" the site would gain — alternative considered
   and rejected: hand-rolled `.html` doc pages with a copy-pasted sidebar
   partial (zero new tooling, but manual nav upkeep on every new doc page).
3. **Site placement: new top-level nav item.** "Tri Track" gets its own
   primary nav link alongside Technology/Field Results/etc. (not nested under
   Technology) — framed as a second product from the lab, not a UAV-RT
   accessory.
4. **Screenshots: real, captured from the running app**, not mockups or
   user-supplied images. Plan is to build the Tri Track macOS target, seed it
   with realistic demo data (a project, tags, several bearing observations, a
   triangulated position estimate, populated map/terrain), and capture actual
   screenshots of each key screen — Map, Record (bearing capture), Compass,
   Position Estimation, Data Export — rather than asking the user to stage and
   capture these by hand.

## Proposed structure (not yet built)

- `tri-track.html` — sales/feature page at the site root, following the
  existing `technology.html` pattern exactly: `.intro-banner` hero (background
  photo/screenshot + 1-liner), zig-zag `.explainer` blocks (one per major
  feature: bearing capture & compass, Lenth MLE triangulation, offline
  maps/viewshed, team data sharing/export), a stat-callout per block, a
  "Go deeper" dark section linking into the new docs section instead of
  GitHub, closing `.cta-banner` back to Collaborate. Reuses the site's
  existing CSS tokens/classes (`brand/tokens/*.css`, `.section`,
  `.section-subtle`, `.section-dark`, `.stat-callout`, `.btn.btn-gold`, etc.)
  — no new CSS patterns needed for this page.
- `tri-track/docs/` (or similar) — Docsify-powered docs subsite: `index.html`
  (Docsify loader shell) + `_sidebar.md` (PX4-style left nav config) + one
  markdown file per topic (e.g. Overview, Getting Started, Recording a
  Bearing, Triangulating a Position, Offline Maps & Terrain, Data Export &
  Backup, Cloud Auto-Backup). Screenshots embedded inline per section.
- **Nav change across all existing pages:** add a `Tri Track` link to the
  shared `<nav class="site-nav">` block, which is duplicated verbatim across
  all 7 existing HTML files (`index.html`, `technology.html`,
  `field-results.html`, `publications.html`, `team.html`, `collaborate.html`,
  `tool.html`) — each of the 7 needs the same one-line addition since there's
  no shared header partial.

## Content sourcing

Feature copy and screen list should draw from `TriTrack_Design_Document_CURRENT.md`
(screen-by-screen spec) and `TriTrack_Technical_Context_CURRENT.md` (algorithm/
schema detail, for anything the docs section wants to go deeper on) in this
same `CLAUDE_DOCS/` folder, plus the app's actual current screens (some
described behavior in the design doc is aspirational/partially open work —
see that doc's "Known Issues / Open Work" section — so the marketing copy
should match what's actually shipped, not the full spec wishlist).

## Explicitly not done yet

No files have been created or modified in the website repo. No screenshots
have been captured. No demo data has been seeded into the app. This is scope
alignment only — implementation is a future session's work, to proceed only
once greenlit.

# TriTrack — Design Document (Reconciled/Current)

**App name:** TriTrack (single word, no space). *Naming note: earlier design material used "Tri Track" (two words) — this is the app's original working name from the initial design chat. The developer has since directed a rename to "TriTrack" everywhere (app title, both platform manifests, README). As of this reconciliation the codebase is inconsistent (`app.dart`/iOS use "Tri Track"; Android label is "tri_track"). Treat "TriTrack" as the name of record going forward; the rename itself is tracked as open work below.*

**Purpose:** Field-use companion app for wildlife VHF radio telemetry — logging bearings, triangulating tag positions, and coordinating team observations, built for outdoor use in variable light and weather.

*Note: This document covers UI/UX and screen-level design only. Logo and brand identity design (mark, wordmark, color system, usage guidelines) was proposed during design discussion but explicitly deferred — no separate brand document exists yet. Treat as open, unscheduled work.*

---

## Design Principles

- **High contrast**, outdoor-readable: `#1a1a1a` on `#ffffff` base, WCAG AA minimum
- **Large touch targets**: 44x44pt minimum (Apple HIG's figure; matches the app's actual `DesignTokens.minTouchTarget` constant — corrected 2026-07-29, was previously misstated here as 48x48pt), for use with gloves or in motion
- **Bold sans-serif typography**, 14pt+ body text
- **Dynamic type scaling** and **screen-reader labels** on all controls (accessibility is not just contrast)
- **Scroll wheels with haptic ticks** for all categorical selections (not dropdowns)
- **Progress bar** at the bottom of screen during long operations (viewshed computation, Lenth calculation, tile/DEM downloads)
- **No color-only cues** — every color-coded element is paired with a label, icon, or shape difference
- **Destructive actions** (delete observation, delete tiles, delete project) require confirm + undo; undo affordances (snackbars) must auto-dismiss (~6s) and not linger indefinitely
- Voice commands deferred to Phase Two

### Map Layer Color Coding
**[Superseded 2026-07-28 — see Phase 4, "Tag Color Coding," in `DEVELOPMENT_PLAN.md`]** Bearing rays, estimated positions, and actual tag locations are now colored **per-tag** (each tag has a user-assignable `color_hex`, auto-assigned from a curated colorblind-safe palette when the tag is created) rather than by fixed element-type color. This was a deliberate decision: with multiple tags on screen, distinguishing "which ray belongs to which tag" matters more in practice than distinguishing "ray vs. estimate" by color, and shape already carries the ray/estimate/actual-location distinction (see Screens → Main Map and → Position Estimation).

| Element | Color |
|---|---|
| Bearing rays | tag's `color_hex` |
| Estimated positions | tag's `color_hex` |
| Actual tag locations | tag's `color_hex` |
| Viewshed overlay | `#60a5fa` semi-transparent (light blue) — **unchanged, stays fixed** (not tag-specific; represents predicted receiver coverage, not a tag) |

**Non-color cue requirement still applies** — per-tag color is a convenience layer on top of, not a replacement for, shape-based distinction: rays keep an observer-position circle + line (not a bare line) with a translucent uncertainty wedge, estimated positions keep their semi-transparent ellipse, actual tag locations keep a distinct marker icon. Map labels continue to show `tag_name`/`frequency_mhz` text (never color alone) per the Display Conventions in the Technical Context doc.

**Map legend** must become tag-keyed (tag name + color swatch) rather than the old fixed element-type legend, and should show only tags with currently-visible elements on screen rather than every tag in the project, to avoid an unbounded legend as tag count grows.

### Compass Rose Color Coding
Color is **redundant, never required** — each indicator is distinguishable by shape and label alone (critical: red/light-green is the worst pair for the most common color-vision deficiency).

| Element | Color | Non-color cue (required) |
|---|---|---|
| Magnetic north needle | Red | "M" label + solid shaft, distinct head shape |
| True north arrow | Light green | "T" label + dashed/outlined shaft, distinct head shape |
| Bubble level (level) | Green | Centered bubble + "level" state |
| Bubble level (tilted) | Orange/red | Off-center bubble + tilt angle readout |

*Implementation status: the magnetic needle exists; the dual-needle true-north indicator described here needs to be re-verified in `compass_dial.dart` — a prior code pass found only the single magnetic needle painter. Confirm before treating this as done.*

---

## Screens (Phase One)

### 1. Login / Project Selection
- Select observer profile
- Pick active project from list

### 2. Main Map
- Full-screen map (terrain/street/satellite toggle)
- Bearing rays from observations
- Estimated positions with uncertainty ellipses
- Actual tag locations (labeled with name + frequency)
- Viewshed overlay (toggleable)
- Current location indicator
- **Live updates required:** newly added or deleted bearings/positions/other recordings must appear/disappear on the map immediately, without requiring an app restart (currently an open bug — see Known Issues).
- Map furniture (see below) must not overlap: the "+" record button, the map-source bar, and the lat/lon readout bar have been overlapping at the bottom of the screen and need a layout fix. Map type selector buttons (terrain/street/satellite) need small edge padding, not flush to the screen edge.
- Recordings (bearings, positions, other) should be selectable directly on the map, surfacing info + an edit option in a bottom sheet. For estimated positions specifically: toggle to show/hide the error ellipse and highlight which bearings were used to produce that estimate.
- Layers toggle (terrain/street/satellite, viewshed, etc.) checkboxes must reliably reflect and control visibility — has had inconsistent on/off behavior.
- **Uncertainty wedges are their own independent layer toggle** (added 2026-07-29, ad hoc during Phase 4 implementation): a separate "Uncertainty wedges" row in the Layers & Filters sheet, distinct from the "Bearings" toggle — a tag's rays and its uncertainty wedges can be shown/hidden independently. The map legend counts a tag as visible if either is on. Wedge fill/border opacity was also increased from the original values (fill 0.12→0.2 baseline / 0.22→0.35 highlighted / 0.04→0.08 dimmed; border 0.3→0.45 / 0.08→0.14 dimmed) per direct user feedback that they read as too transparent — exact numbers were a judgment call, not a specified target, so revisit if still off.
- Only one entry point to record a new observation is needed (the "+" button); a redundant bottom "record" button, if still present anywhere, should be removed.

### 3. Observation Logging ("Record")
- Record-type selector (directional / omnidirectional / **Note** / **No Signal**) should be at the **top** of the screen, above the tag selector — not below it as originally built.
  - **Note** type: ties a plain-text note to a tag (or "No tag"), no radio-specific fields, but still captures standard position/time metadata like any other record.
  - **No Signal** type: lets the user multi-select several tags at once to record "listened for these, heard nothing" in a single fast action (distinct from a single-tag Non_Detection).
- Tag scroll wheel (shows "frequency | pulse rate | name" — pulse rate disambiguates same-frequency tags); persists the last-used tag as default across sessions (users typically focus on one individual at a time)
- Tag selector needs an **"Add new tag"** option (jumps to tag input screen) and, when "Note" is selected, a **"No tag"** option pinned at the top of the list
- Compass or manual bearing entry
- Bearing method toggle: peak / null
- Signal type toggle: regular pulse / mortality signal
- Signal strength: **horizontal slider** (faint → very strong, left to right), not a scroll wheel; keep existing color scheme (faint→strong reads red→green)
- Bearing quality quick-flag: good / fair / suspected bounce (one tap) — **omnidirectional records do not need a bearing-quality flag; omit it for that record type**
- Optional: antenna type, receiver gain (collapsible "advanced" row to keep the fast path fast)
- Notes field (plain text)
- GPS location (auto-populated with accuracy readout; manual pin fallback). Show GPS accuracy so the user knows when a fix is poor.
- **Preview button:** after capturing a bearing/omnidirectional record, jump to the map to see it plotted, with a way to manually reposition the point (GPS multipath in canyons/dense forest can put the auto-fix in the wrong place)
- Optional: attach to / start a triangulation session (groups near-simultaneous bearings for one fix)

### 4. Compass (Instrument Screen)
Kept deliberately separate from bearing recording — the compass is a standalone instrument; "Save Bearing" belongs only on the Record screen, not here.

**Layout:**
- Full-screen compass rose graphic, centered
  - Cardinal directions and degree markings (0–360°), labels positioned to avoid overlapping tick marks
  - **Magnetic north needle** ("M", red, solid shaft): rotates live with phone
  - **True north arrow** ("T", light green, dashed/outlined shaft): rotates live, offset by declination
  - The two indicators differ by shape and label, not only color; the visual gap between them communicates declination at a glance
  - Declination shown as a computed value based on device location (WMM), with a manual-override option for the user
- Bubble level indicator: behaves like a real bubble (moves opposite to tilt direction in both pitch and roll), turns green when level
- **Interference warning banner**: appears when the magnetometer reads a field magnitude far outside the expected range or calibration is stale
- Bearing capture toggle: **Single Point** / **Range Capture**
  - Single Point: manual bearing field or spin buttons, uncertainty slider (default 10–15°), labeled with the live numeric degree value, not just the wedge graphic
  - Range Capture: "Start" button, "End" button; while sweeping, the angular band the user is passing through is highlighted live so that at "End" the full selected band remains highlighted with its center marked as the bearing; display shows "Start: XXX° End: YYY° → Bearing: ZZZ° ± UUU°". **Wedge and midpoint computed with circular math** so a sweep across North (e.g., 350°→10°) reads correctly as 0° ± 10°, not 180°.
- Calibrate button, triggers figure-eight calibration routine with haptic feedback
- No "Save Bearing" action lives on this screen — saving only happens from the Record flow, which mirrors this same compass display exactly (no visual divergence between the two)
- Map rotation sensitivity (on the main map's rotate-with-compass mode) should be low enough that panning/zooming doesn't accidentally rotate the map; a "recenter to North" tap target on the north arrow/N label resets map orientation

### 5. Position Estimation
**Layout:**
- Tag selector at top — user must choose a tag before anything else; only that tag's observations are shown below
- **No finite time limit** on which bearings are eligible for triangulation — all of a tag's bearings should be selectable, presented as a **reverse-chronological list (newest first)** with a **select/deselect-all** control
- Map view: needs full map-screen parity — map type switching (terrain/street/satellite), pan, zoom, and the point-to-point measure tool, not a static/limited view as originally built. Bearings for the selected tag are plotted and directly clickable on the map to include/exclude them from the estimate (mirrors the checkbox list); excluded bearings remain visible but rendered translucent so the user can reselect them.
- Lenth MLE best-fit point (blue marker), uncertainty ellipse (semi-transparent blue overlay), pairwise intersection points (toggleable)
- Side panel: list of observations for the selected tag with checkboxes (observer name, local timestamp, bearing ± uncertainty, signal strength, quality flag); "Recompute" button; summary stats (N observations, ellipse size, confidence, **time span of selected set**)
- Inline warnings must not expand to the point of covering/blocking the bearing selection list
- "Save Position" button at bottom

**Warnings (surfaced inline, non-blocking):**
- **Temporal spread:** if the selected observations span more than the project window (default ~15–20 min, **entered as free text, not a +/- stepper**), warn that the animal may have moved between bearings.
- **Geometry quality:** if bearings are near-parallel, observers are nearly coincident, or the ellipse is huge/elongated (high GDOP), explain *why* the estimate is poor and suggest a better next observer position.
- **Single bearing:** with only one observation selected, show the ray only — no estimate or ellipse.

**Constraint:** All observations contributing to one estimate must share the same `tag_id` — enforced by the tag-first selection flow.

### 6. Viewshed Prediction
- Tap any point on the map to preview visibility from that point
- Semi-transparent overlay shows visible terrain, clipped to the project/tag's `max_detection_range_m` (a large open line-of-sight polygon at long range overstates realistic hand-held VHF detection distance)
- Toggle overlay on/off
- Progress indicator during computation; if the tapped area lacks downloaded DEM coverage, say so explicitly and prompt the user to download elevation data for that area (never a silent perpetual "Computing viewshed…" state)
- **Labeling:** call this "predicted line-of-sight coverage" in the UI, not "reception area" or similar language implying a guarantee
- **Live viewshed mode (open request):** compute/update the viewshed continuously from the user's current GPS position (e.g., while driving), rather than only from a manually tapped point
- **[Phase Two candidate, under review]** Route-based coverage planning: let the user pick a driving route and either (a) compute the scanned viewshed for continuous scanning while driving, or (b) have the app suggest optimal stop points along the route to maximize coverage
- **[Under review, not yet approved]** A future relative-likelihood gradient (via ITM/Longley-Rice) is being evaluated as a richer alternative to the binary overlay — see Technical Context. Not scheduled to a phase; substantially heavier computation, no ready-made Dart package, likely needs server-side compute (Phase 3).

### 7. Observation History ("Log")
- Sortable list of records by tag name, frequency, time, distance to current position
- Filter by tag, date range, or observer
- Edit permitted only for observations the current user created
- Share button on each observation row

### 8. Tag Database Management
- View, add, edit tags (frequency, pulse rate, name, status, dates)
- Bulk CSV import with a preview/dry-run before commit
- Selectable list in project edit/setup to assign existing tags to a project, and to remove a tag from a project

### 9. Map & Offline Data Management
- Dedicated map-based interface for downloading and deleting offline tiles (terrain, street, satellite) and DEM data — rectangle or polygon area selector, with the ability to drag existing points/midpoints to reshape the polygon, and delete misplaced points
- The interface should visually show what's already been downloaded (extent/coverage) so the user knows what more they need, both for adding and for freeing space by deleting
- Download progress: real progress bar tied to actual bytes/tiles fetched (not a bar stuck at 100% while only a fraction counter moves), an explicit "Completed" state that replaces "Cancel" once done, and an estimated time remaining based on current download rate
- Keep the phone from sleeping/locking mid-download so downloads continue to completion
- Storage usage indicator

### 10. Observation Sharing
- Copy a versioned, structured payload for sending via any messaging app (robust to locale/encoding; carries observer, timestamp, uncertainty, pulse rate, tag key)
- Paste incoming payload to parse and preview on map as a temporary overlay; if the tag isn't known locally, offer to create it or show unlinked

### 11. Data Export / Backup
- Export full project archive (.zip)
- Export CSV (filterable)
- Import backup to restore project state (with defined merge behavior; warns on schema/version differences and corrupt archives)

### 12. Project Setup / Extent
- Name, description, species notes
- **Define geographic extent** (draw/adjust a bounding box on the map) — drives which tiles and DEM to pre-download and later crops viewshed
- Coordinate display preference (decimal degrees / DMS / UTM)
- Triangulation time window (default ~15–20 min, free-text entry) used for the temporal-spread warning

### 13. Pre-Trip Checklist
- Surfaced before leaving connectivity: maps + DEM downloaded for the project bbox, tags loaded, GPS acquiring, compass calibrated
- Simple checklist with live status indicators; the point is to catch "no offline data on site" before it happens

---

## Map Furniture (all map screens)
- Scale bar, north arrow (tap to reset map orientation to north-up), live coordinate readout (in the user's chosen coordinate format)
- **Legend, tag-keyed (updated 2026-07-28):** one row per tag currently visible on screen — swatch + tag name — plus one fixed row for the viewshed overlay. Not a per-element-type legend anymore; see "Map Layer Color Coding" above.
- **Point-to-point measure tool**: tap two points to read distance + bearing between them; user can drag either endpoint afterward to adjust (measurement updates live), plus a "Clear" button to remove the line and start a new one
- **Elevation profile**: when a measurement line is drawn, show an elevation profile graph at the bottom of the map (~20% of screen height by default, user-resizable/swipeable to hide); graph should include faint gridlines on both axes, with resolution adapting to the graph's on-screen size for readability

---

## Interaction Patterns Summary
- Categorical inputs → scroll wheels with haptic feedback, never dropdowns (signal strength is the one deliberate exception — horizontal slider)
- Long operations → bottom progress bar, non-blocking where possible
- Color always paired with text/icon/shape labels — never color alone
- Destructive actions → confirm + undo (undo affordance auto-dismisses, ~6s); in-progress observation entry autosaves
- Compass screen is the most visually dense screen in the app — the dual-indicator system (M/red, T/green, distinguished by shape and label) is the signature interaction, communicating magnetic declination without requiring the user to read a number
- Map screens should behave consistently everywhere they appear (main map, position estimation, offline data management) — same pan/zoom/type-switch/measure affordances, not a cut-down map on secondary screens

---

## Known Issues / Open Work (as of this reconciliation)

Status assessed against the current codebase; treat as a working punch list, not a guarantee — spot-check before relying on any single line.

**Believed already resolved** (verify if revisiting): undo-snackbar auto-dismiss, triangulation time window as free text, compass calibration UI overhaul, compass vs. record-bearing redundancy (now separate, mirrored screens), splash screen + app icon, measurement tool clear/move-endpoint/basic elevation profile, offline-data polygon/rectangle download selector, signal-strength horizontal slider, tag-to-project assignment UI, Log/Record page naming/roles, compass needle visibility fix, map layers on/off checkboxes.

**Open / not yet done:**
- App name rename to "TriTrack" (no space) — not applied consistently (app.dart, iOS, Android manifest, README still say "Tri Track" or "tri_track")
- Live map updates on add/delete of bearings/positions/recordings (currently needs app restart)
- Position Estimation screen: full map parity (pan/zoom/type-switch/measure), click-to-toggle bearings on the map, translucent excluded bearings, warning banners not covering the list
- Map bottom-bar overlap (+ button / map-source bar / lat-lon bar) and map-selector edge padding
- Download UX: real moving progress bar, "Completed" state, ETA, keep-awake during download
- "Note" and "No Signal" record types (schema currently only supports `directional` / `omnidirectional` observation types plus a separate `Non_Detections` table — needs either a new observation type or explicit multi-tag no-signal flow, and a schema/UI decision)
- Record screen: move record-type toggle to top; "Add new tag" and "No tag" options in tag selector
- Bearing map rendering: observer-position circle + line (not a bare line), translucent uncertainty wedge
- Bearing/omnidirectional record preview + manual reposition step
- Bubble level pitch-direction behavior (reported wrong; roll direction reportedly correct — re-verify against current sensor code)
- Location-based declination with manual override
- Elevation profile graph gridlines/adaptive resolution
- Live (continuously updating) viewshed from current GPS position
- Route/driving-based coverage planning (explicitly Phase Two)
- Dual true/magnetic compass needle — re-verify it's actually rendered (a code check found only the magnetic needle painter)
- Redundant bottom "record" button on map, if still present, should be removed in favor of the "+" button only
- **[New, proposed 2026-07-27, under review]** Live audio pulse detection & signal-strength plotting: accept the receiver's demodulated audio via the phone's mic input (through a Lightning/USB-C-to-3.5mm adapter), detect pulses and a relative signal-strength/SNR-like reading in real time, and plot it live along the user's GPS track on the map — for road-cruise scanning with an omni antenna and for close-range homing on a tag. See Technical Context for the fuller writeup and open hardware/software questions; not yet designed to screen level or scheduled to a phase.

---

## Business Model — Under Review, Not Approved for Any Phase
A free core tier (Phase One feature set) plus a paid "Pro" tier gated at the Phase Two/Three team-sync boundary was discussed, priced per team/project rather than per seat. Not committed, not scheduled, no pricing finalized — logged here so it isn't lost, and so Phase Two/Three planning accounts for a possible paywall boundary at the sync/team-features line.

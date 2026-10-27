# Tri Track — Design Document

**App name:** Tri Track
**Purpose:** Field-use companion app for wildlife VHF radio telemetry — logging bearings, triangulating tag positions, and coordinating team observations, built for outdoor use in variable light and weather.

*Note: This document covers UI/UX and screen-level design only. Logo and brand identity design (mark, wordmark, color system, usage guidelines) will be handled in a separate design document.*

---

## Design Principles

- **High contrast**, outdoor-readable: `#1a1a1a` on `#ffffff` base, WCAG AA minimum
- **Large touch targets**: 48x48pt minimum, for use with gloves or in motion
- **Bold sans-serif typography**, 14pt+ body text
- **Dynamic type scaling** and **screen-reader labels** on all controls (accessibility is not just contrast)
- **Scroll wheels with haptic ticks** for all categorical selections (not dropdowns)
- **Progress bar** at the bottom of screen during long operations (viewshed computation, Lenth calculation)
- **No color-only cues** — every color-coded element is paired with a label, icon, or shape difference
- **Destructive actions** (delete observation, delete tiles) require confirm + undo; observation entry autosaves as a draft
- Voice commands deferred to Phase Two

### Map Layer Color Coding
| Element | Color |
|---|---|
| Bearing rays | `#3b82f6` (blue) |
| Estimated positions | `#2563eb` (darker blue) |
| Actual tag locations | `#16a34a` (green) |
| Viewshed overlay | `#60a5fa` semi-transparent (light blue) |

### Compass Rose Color Coding
Color is **redundant, never required** — each indicator is distinguishable by shape and label alone (critical: red/light-green is the worst pair for the most common color-vision deficiency).

| Element | Color | Non-color cue (required) |
|---|---|---|
| Magnetic north needle | Red | "M" label + solid shaft, distinct head shape |
| True north arrow | Light green | "T" label + dashed/outlined shaft, distinct head shape |
| Bubble level (level) | Green | Centered bubble + "level" state |
| Bubble level (tilted) | Orange/red | Off-center bubble + tilt angle readout |

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

### 3. Observation Logging
- Tag scroll wheel (shows "frequency | pulse rate | name" — pulse rate disambiguates same-frequency tags)
- Observation type toggle: directional / omnidirectional
- Compass or manual bearing entry
- Bearing method toggle: peak / null
- Signal type toggle: regular pulse / mortality signal
- Signal strength scroll wheel (faint → very strong)
- Bearing quality quick-flag: good / fair / suspected bounce (one tap; important in canyon/mesa terrain where cliff reflection is common)
- Optional: antenna type, receiver gain (collapsible "advanced" row to keep the fast path fast)
- Notes field (plain text)
- GPS location (auto-populated with accuracy readout; manual pin fallback). Show GPS accuracy so the user knows when a fix is poor.
- Optional: attach to / start a triangulation session (groups near-simultaneous bearings for one fix)

### 4. Compass Calibration
**Layout:**
- Full-screen compass rose graphic, centered
  - Cardinal directions and degree markings (0–360°)
  - **Magnetic north needle** ("M", red, solid shaft): rotates live with phone
  - **True north arrow** ("T", light green, dashed/outlined shaft): rotates live, offset by declination
  - The two indicators differ by shape and label, not only color; the visual gap between them communicates declination at a glance
- Bearing readouts side-by-side below the rose: "Magnetic: XXX°" / "True North: XXX°"
- Large center degree readout (e.g., "145°")
- Bubble level indicator (corner or side of compass)
- **Interference warning banner**: appears when the magnetometer reads a field magnitude far outside the expected range or calibration is stale — prompts the user to step away from the antenna/vehicle/metal, and reinforces that manual bearing entry is available
- Bearing capture toggle: **Single Point** / **Range Capture**
  - Single Point: manual bearing field or spin buttons, uncertainty slider (default 10–15°)
  - Range Capture: "Start" button, "End" button (distinguished by label + shape, not color alone); display shows "Start: XXX° End: YYY° → Bearing: ZZZ° ± UUU°"; visual wedge overlay on the compass rose shows the captured angular range. **Wedge and midpoint must be computed with circular math** so a sweep across North (e.g., 350°→10°) reads correctly as 0° ± 10°, not 180°.
- Calibrate button (medium size), triggers figure-eight calibration routine with haptic feedback
- Instruction text: "Point phone at antenna direction. Align with signal. For range: tap Start, rotate phone, tap End."
- "Save Bearing" button (large), bottom of screen

**Interactions:**
- Phone rotation updates the M (magnetic) and T (true north) indicators live
- Bubble level updates continuously with phone tilt
- Save writes magnetic bearing, true-north bearing, declination (for the observation date), WMM model version, capture method, and both local/UTC timestamps

### 5. Position Estimation
**Layout:**
- Tag selector at top — user must choose a tag before anything else; only that tag's observations are shown below
- Map view (~60% of screen): bearing rays for the selected tag, Lenth MLE best-fit point (blue marker), uncertainty ellipse (semi-transparent blue overlay), pairwise intersection points (toggleable), tap any ray to include/exclude it
- Side panel (~40% of screen): list of observations for the selected tag with checkboxes (observer name, local timestamp, bearing ± uncertainty, signal strength, quality flag); "Recompute" button; summary stats (N observations, ellipse size, confidence, **time span of selected set**)
- "Save Position" button at bottom

**Warnings (surfaced inline, non-blocking):**
- **Temporal spread:** if the selected observations span more than the project window (default ~15–20 min), warn that the animal may have moved between bearings — Lenth assumes a single stationary source.
- **Geometry quality:** if bearings are near-parallel, observers are nearly coincident, or the ellipse is huge/elongated (high GDOP), explain *why* the estimate is poor and suggest a better next observer position.
- **Single bearing:** with only one observation selected, show the ray only — no estimate or ellipse.

**Constraint:** All observations contributing to one estimate must share the same `tag_id` — enforced by the tag-first selection flow.

### 6. Viewshed Prediction
- Tap any point on the map to preview visibility from that point
- Semi-transparent overlay shows visible terrain, clipped to the project/tag's `max_detection_range_m` (a large open line-of-sight polygon at long range overstates realistic hand-held VHF detection distance)
- Toggle overlay on/off
- Progress indicator during computation
- Clear message when the tapped point falls outside downloaded DEM coverage (no crash)
- **Labeling:** call this "predicted line-of-sight coverage" in the UI, not "reception area" or similar language implying a guarantee — bare-earth DEMs miss canopy (can overstate clear cells in dense pine) while diffraction/multipath can deliver signal past terrain the model marks blocked (can understate real reach). Both directions of error are real; the copy should reflect that this is an estimate.
- **[Under review, not yet approved]** A future relative-likelihood gradient (via ITM/Longley-Rice) is being evaluated as a richer alternative to the binary overlay — see technical doc. Not scheduled to a phase.

### 7. Observation History
- Filter by tag, date range, or observer
- Edit permitted only for observations the current user created
- Share button on each observation row

### 8. Tag Database Management
- View, add, edit tags (frequency, pulse rate, name, status, dates)
- Bulk CSV import with a preview/dry-run before commit

### 9. Map Management
- Download/delete offline tiles (terrain, street, satellite) and DEM, scoped to the project bounding box
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
- Triangulation time window (default ~15–20 min) used for the temporal-spread warning

### 13. Pre-Trip Checklist
- Surfaced before leaving connectivity: maps + DEM downloaded for the project bbox, tags loaded, GPS acquiring, compass calibrated
- Simple checklist with live status indicators; the point is to catch "no offline data on site" before it happens

---

## Map Furniture (all map screens)
- Scale bar, north arrow, live coordinate readout (in the user's chosen coordinate format)
- Color/shape legend for ray / estimate / tag-location / viewshed
- **Point-to-point measure tool**: tap two points to read distance + bearing between them

---

## Interaction Patterns Summary
- Categorical inputs → scroll wheels with haptic feedback, never dropdowns
- Long operations → bottom progress bar, non-blocking where possible
- Color always paired with text/icon/shape labels — never color alone
- Destructive actions → confirm + undo; in-progress observation entry autosaves
- Compass screen is the most visually dense screen in the app — the dual-indicator system (M/red, T/green, distinguished by shape and label) is the signature interaction, communicating magnetic declination without requiring the user to read a number

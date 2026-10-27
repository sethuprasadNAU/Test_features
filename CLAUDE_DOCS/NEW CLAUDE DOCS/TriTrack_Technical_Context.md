# Tri Track — Technical Context Document

**Purpose:** Cross-platform Flutter mobile app (iOS + Android, developed on Mac) for field wildlife VHF radio telemetry. Built for offline field use by wildlife researchers performing triangulation-based localization. Development via Claude Code. No app store deployment planned initially.

---

## Global Data Conventions (apply to ALL tables)

These conventions exist so the Phase 1 local database can sync cleanly in Phase 2/3 without a painful migration. Build them in now, before any real data exists.

- **Timestamps:** every table stores `timestamp_local` + `timestamp_utc` + `timezone_offset` where a time is recorded. Times shown in the UI are local; UTC is authoritative in the data.
- **Sync/merge fields on every table:** `created_at`, `updated_at` (both UTC), `deleted_at` (UTC, nullable — **soft delete only**, no hard deletes anywhere), `revision` (integer, incremented on each edit, for last-write-wins/conflict detection), `last_modified_by` (user_id), `origin_device_id` (text).
- **No hard deletes:** a hard delete on one device would "resurrect" on the next merge. Everything is soft-deleted via `deleted_at`; queries filter `deleted_at IS NULL` by default.
- **Schema versioning:** set SQLite `PRAGMA user_version` and store a `schema_version` in the backup archive so older backups can be migrated forward on restore.
- **[Note for Claude Code — critical]** SQLite has foreign keys **OFF by default**. Run `PRAGMA foreign_keys = ON` on every connection or referential integrity is not enforced.
- **User identity across devices:** the same person will have a different `user_id` on two devices. Treat **email** (normalized, lowercased) as the cross-device identity anchor for dedup on import/merge.
- **Indexes:** create indexes on `project_id`, `tag_id`, and timestamp columns on the high-volume tables (Observations, Non_Detections, Estimated_Positions) from the start.

---

## Phase Structure

### Phase One (MVP — Core Field Tool)
- Tag database with VHF frequencies, names, bulk CSV import
- Observation logging: bearings, omnidirectional detections, non-detections
- Offline maps: terrain, street, satellite tile downloads + DEM elevation data
- Biangulation/triangulation via Lenth MLE with uncertainty ellipse visualization
- Viewshed: automatic from current location + tap-to-predict from any map point
- Compass with calibration, magnetic/true north display (dual needle), bubble level, bearing range capture
- CSV export, full project database backup/restore (archive ~100–250KB, suitable for WhatsApp transfer)
- Observation sharing via formatted plain text (parsed by receiving device, temporary map overlay, not stored unless explicitly saved)
- Project/user management with permission model
- High-contrast outdoor UI, haptic feedback, scroll wheels, minimal taps

### Phase Two
- Next-location recommendation: optimize viewshed along roads to minimize localization error
- Team member positions on shared map
- Road-based viewshed optimization for suggested stop points
- SMS auto-detection for observation sharing (if Phase One assessment shows it's not overly complex)

### Phase Three
- Inter-team communication via central server (university server planned)
- Habitat/multispectral layer integration (land cover, vegetation type)
- Potential export to CyberTracker or similar field data app

---

## SQLite Schema

### Users
- `user_id` (text, primary key, UUID)
- `first_name` (text)
- `last_name` (text)
- `email` (text)

### Projects
- `project_id` (text, primary key, UUID)
- `project_name` (text)
- `description` (text, nullable)
- `notes` (text, nullable) — species info, etc.
- `owner_user_id` (text, foreign key to Users)
- `creation_date` (datetime)
- `bbox_min_lat` (real, nullable) — geographic extent, drives tile/DEM pre-download and viewshed cropping
- `bbox_min_lon` (real, nullable)
- `bbox_max_lat` (real, nullable)
- `bbox_max_lon` (real, nullable)
- `datum` (text, default "WGS84") — stated explicitly for GIS handoff

### Project_Memberships
- `project_id` (text, foreign key to Projects)
- `user_id` (text, foreign key to Users)
- `join_date` (datetime)
- `end_date` (datetime, nullable)
- `role` (text) — "owner" | "contributor" | "viewer"

### Tags
Tags are global; linked to projects via junction table. Multiple tags can share the same name (e.g., same animal re-tagged across seasons).
- `tag_id` (text, primary key, UUID)
- `frequency_mhz` (real)
- `pulse_rate` (real, nullable) — pulses per minute; often the ONLY way to distinguish two tags on the same nominal frequency in the field
- `pulse_pattern` (text, nullable) — free/coded description of pulse pattern where applicable
- `tag_name` (text) — e.g., "Coco"
- `date_put_on` (date)
- `date_removed` (date, nullable)
- `status` (text) — "active" | "recovered" | "lost" | "malfunction"
- `capture_date` (date, nullable)
- `notes` (text, nullable)

### Project_Tags
Junction table. Tags are never deleted, only deactivated — maintains an audit trail.
- `project_id` (text, foreign key to Projects)
- `tag_id` (text, foreign key to Tags)
- `status` (text) — "active" | "inactive" within project

### Observations
- `observation_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `user_id` (text, foreign key to Users)
- `tag_id` (text, foreign key to Tags)
- `session_id` (text, nullable) — groups bearings intended as one near-simultaneous triangulation fix (see Triangulation Sessions below)
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `position_accuracy_m` (real, nullable) — GPS horizontal accuracy / HDOP-derived, meters
- `position_source` (text) — "gps_fix" | "manual_pin" | "manual_entry"
- `elevation` (real) — auto-populated from DEM
- `altitude_agl` (real, default 0)
- `observation_type` (text) — "directional" | "omnidirectional"
- `magnetic_bearing` (real, nullable)
- `true_north_bearing` (real, nullable)
- `bearing_uncertainty` (real, nullable) — degrees, default 10–15°
- `bearing_capture_method` (text, nullable) — "single_point" | "range_capture"
- `bearing_method` (text, nullable) — "peak" | "null" — peak vs. null antenna method; affects precision
- `magnetic_bearing_start` (real, nullable) — if range_capture
- `magnetic_bearing_end` (real, nullable) — if range_capture
- `true_north_bearing_start` (real, nullable)
- `true_north_bearing_end` (real, nullable)
- `magnetic_declination` (real, nullable) — computed for the observation DATE, stored for audit
- `wmm_model_version` (text, nullable) — WMM epoch/model used for the declination calc (e.g., "WMM2025")
- `antenna_type` (text, nullable) — e.g., "yagi_3el" | "yagi_5el" | "h_adcock" | "omni" | "other"
- `receiver_gain` (real, nullable) — gain/attenuation setting needed to hear signal; rough distance proxy
- `signal_type` (text) — "regular_pulse" | "mortality_signal"
- `signal_strength` (text) — "faint" | "weak" | "medium" | "strong" | "very_strong"
- `bearing_quality` (text, nullable) — "good" | "fair" | "suspected_bounce" — lets user flag likely multipath/reflection without deleting the record
- `notes` (text, nullable) — plain text only

### Non_Detections
- `non_detection_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `user_id` (text, foreign key to Users)
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `position_accuracy_m` (real, nullable)
- `position_source` (text) — "gps_fix" | "manual_pin" | "manual_entry"
- `elevation` (real)
- `altitude_agl` (real, default 0)
- `tag_ids_listened_for` (text) — JSON array
- `notes` (text, nullable)

### Estimated_Positions
Single tag per estimate — all contributing observations must share the same `tag_id`.
- `position_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `tag_id` (text, foreign key to Tags)
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `semi_major_axis` (real)
- `semi_minor_axis` (real)
- `rotation_angle` (real)
- `method` (text) — "lenth_mle"
- `observation_ids_used` (text) — JSON array, all same tag_id
- `notes` (text, nullable)

### Triangulation_Sessions
Groups observations intended to be near-simultaneous (same stationary animal position). Lenth's method assumes all bearings point at ONE stationary source; this table makes the "these belong together" intent explicit and enables the temporal-spread warning.
- `session_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `tag_id` (text, foreign key to Tags) — a session is always about one tag
- `label` (text, nullable) — optional user label (e.g., "Coco morning fix")
- `started_at_local` / `started_at_utc` (datetime)
- `notes` (text, nullable)

### Actual_Tag_Locations
- `location_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `tag_id` (text, foreign key to Tags)
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `uncertainty_radius` (real) — meters
- `notes` (text, nullable)

**Global rule:** All timestamps are stored as both local time and UTC, with timezone offset, across all tables.

---

## Key Technical Requirements

### Compass & Bearings
- Phone provides magnetic north; convert to true north using the NOAA World Magnetic Model (embedded, offline)
- Store all three: `magnetic_bearing`, `true_north_bearing`, `magnetic_declination` — full audit trail
- Compass rose UI: **red needle** points to magnetic north, **light green arrow** points to true north; both rotate live with the phone, visually showing the declination as the offset between them
- **[Note for Claude Code — accessibility, required]** Red/light-green is the worst color pair for the most common color-vision deficiency (~8% of men, and the field user base skews that way). The two indicators MUST be distinguishable by shape and label alone: label the magnetic needle "M" and the true-north arrow "T", give them different head/shaft geometry (e.g., solid vs. dashed shaft), so color is redundant, not required. This also satisfies the doc's own "no color-only cues" rule.
- Bubble level indicator alongside compass
- Two capture modes:
  - **Single Point**: point phone, press save
  - **Angular Range**: press Start at beginning angle, rotate, press End at final angle → midpoint = bearing, half-range = uncertainty
- **[Note for Claude Code — critical bug class]** All bearing/angle math must use circular statistics, NOT linear arithmetic. Linear averaging breaks across the 0/360 boundary: a sweep from 350°→10° must yield a midpoint of 0° (± 10°), not 180°. Use shortest-arc / von Mises handling for range-capture midpoint, uncertainty, and any bearing averaging or differencing.
- **[Note for Claude Code — WMM epoch]** Compute declination using the OBSERVATION date, not today's date (WMM is valid per ~5-year epoch and drifts). Store the model version used (`wmm_model_version`). Ensure the embedded model is updatable. Double-check the declination sign convention — Flagstaff/Arizona is ~+10° EAST; a sign flip here is a classic silent error that puts every true-north bearing off by ~20°.
- **[Note for Claude Code — magnetometer interference]** The normal field posture is holding a metal Yagi/H-antenna, often beside a vehicle, while reading the phone compass — this corrupts the magnetometer. Detect likely interference (magnetic field magnitude far from expected ~25–65 µT, or failed calibration) and warn the user to step away from metal/antenna. This is a primary reason manual bearing entry must remain first-class (sight along the antenna, read a standalone compass, type it in).
- Calibrate button accessible immediately before bearing capture
- **[Note for Claude Code]** iOS: Core Location + native calibration flow. Android: SensorManager + guided rotation (figure-eight).

### Observation Data Entry (Speed Critical)
- **[Note for Claude Code]** Minimize taps. Use scroll wheels (not dropdowns) for categorical fields, with haptic tick feedback on scroll.
- Signal strength: scroll wheel with qualitative levels (faint/weak/medium/strong/very_strong), not dBm
- Tag selection: scrollable list showing "frequency | name"
- Location: GPS auto-populated, or manual map pin if GPS unavailable
- Manual bearing entry allowed (not just compass)
- Manual lat/lon entry allowed (for remote reports relayed by colleagues)
- Bearing observations must be linked to a specific `tag_id` selected from the project's tag list

### Observation Sharing (Offline Team Coordination)
- Share button on each observation formats it as a **versioned, structured payload** (not a fragile human-readable string). Use versioned JSON, optionally base64-wrapped so messaging apps don't mangle it, with a short format-version prefix (e.g., `TT1:` + base64).
- **Why not a pipe-delimited string:** a raw `TAG: 147.5 MHz | BEARING: 145° | ...` string breaks if notes contain `|`, if a colleague's locale uses comma decimals, or if the degree symbol re-encodes in transit — and it carries no observer identity, timestamp, position uncertainty, pulse rate, or unambiguous tag key.
- Payload must include: format version, tag frequency + pulse rate + name, observer name, timestamp (UTC), lat/lon, position accuracy, true-north bearing, bearing uncertainty, and optional notes.
- **[Note for Claude Code]** Design this envelope generically now so Phase 2 team-position "pings" and Phase 3 server messages reuse the same versioned structure.
- On parse: handle the case where the receiver does NOT have the referenced tag (offer to create it or show as unlinked). Validate/bound-check every field on ingest.
- Received observations display as a temporary map overlay; not saved to the database unless the user explicitly saves.
- **[Note for Claude Code]** Attempt SMS auto-detection (similar to bank OTP autofill) if feasible; defer to Phase Two if too complex.

### Localization Algorithm
- **Reference:** Lenth, R.V. (1981). "On Finding the Source of a Signal." *Technometrics*, 23(2), 149–154.
- **[Note for Claude Code]** Validate implementation against the example data in the 1981 paper and cross-check against the R packages `radiotrack` and `sigloc`
- Inputs: observer position (lat/lon), true north bearing, bearing uncertainty
- Output: best-fit tag position + uncertainty ellipse (semi-major axis, semi-minor axis, rotation angle)
- Also compute pairwise bearing intersections for display as a separate, toggleable layer
- Position Estimation flow: user must first select a tag → only that tag's observations are shown → bearings from different tags are never mixed
- User can toggle individual observations on/off before recomputing
- Estimated positions are saved with the list of `observation_ids` used
- Positions are updatable: add a new observation, recompute, save the updated estimate

#### Stationary-source / temporal assumption (critical science point)
- Lenth assumes ALL bearings point at the SAME STATIONARY source. Bearings taken minutes apart on a moving animal will be fused into a confident but WRONG fix with a deceptively tight ellipse.
- Use `Triangulation_Sessions` to group bearings intended as one fix. In the Position Estimation screen, when selected observations span more than a configurable window (default ~15–20 min, project-adjustable), show a **soft warning** ("these bearings span 34 min; the animal may have moved") — warn, don't block.
- Surface the time span of the selected observation set in the UI at all times.

#### Degenerate-geometry guards (required — otherwise crashes / garbage output)
Claude Code must guard every one of these before running the MLE:
- **N = 1:** cannot triangulate. Render the single bearing as a ray only; do not attempt an estimate or ellipse.
- **N = 2, near-parallel:** intersection approaches infinity → near-singular matrix → inf/NaN ellipse. Detect small inter-bearing angle and warn/refuse.
- **All observers at (nearly) the same point:** no triangulation information regardless of N. Detect and warn.
- **Near-singular / near-zero semi-minor axis:** clamp and flag rather than emitting NaN.
- **Poor geometry (high GDOP):** when the resulting ellipse is very large or highly elongated, show a geometry-quality warning so the user understands WHY, and suggest a better next observer position.
- Down-weight or flag observations with large `position_accuracy_m` (Lenth assumes known observer positions; a ±20 m fix under canopy inflates true error).

### Viewshed
- DEM raster downloaded for offline use
- Grid spacing: 10–50 meters (coarse = fast, sufficient for signal propagation modeling)
- Phase One: computed on-device in real time
- Automatic viewshed from current location, displayed on map on open
- Tap-to-predict: user taps "predict viewshed," then taps any map point to preview visibility from that point
- Displayed as a semi-transparent overlay on the map
- Show a progress indicator during computation
- **[Note for Claude Code]** Crop the DEM to a radius around the observer before computing so a large project doesn't exhaust memory. Handle taps OUTSIDE downloaded DEM coverage gracefully (clear message, not a crash). The project bounding box bounds which DEM to fetch.
- **[Accuracy caveat — important, affects UI copy]** A binary optical viewshed is neither purely conservative nor purely liberal relative to real VHF reception: standard DEMs are bare-earth (no canopy), so a "clear" cell in dense ponderosa pine may not actually be clear for signal, while diffraction/multipath around ridges (~2m wavelength at these frequencies) can deliver signal into cells the viewshed marks blocked. The viewshed should be labeled in the UI as **predicted line-of-sight coverage**, not a guarantee of reception in either direction.
- **`max_detection_range_m`** (project- or tag-level, user-configurable): the viewshed display should clip to this radius, since a large open LOS polygon at long range overstates realistic detection distance for a hand-held VHF setup regardless of terrain clearance. This is a bigger source of over-statement than the canopy/diffraction nuance above and should be treated as a required field, not optional polish.

### Viewshed — Under Review, NOT approved for build (see addendum)
- **Relative-likelihood layer via ITM (Longley-Rice):** replacing/supplementing the binary viewshed with a graded "relative likelihood of detection" surface, using the open-source NTIA ITM reference implementation. Path loss from ITM does not require known transmitter power — output would be relative/comparative, not absolute — and could eventually be calibrated against real `Observations`/`Non_Detections` data already in the schema.
- Substantially heavier computation than binary viewshed (diffraction + troposcatter + statistical variability per grid cell, vs. a simple LOS ray cast); on-device feasibility at real-time speed is unproven and may require server-side computation (ties to Phase 3 server) rather than the on-device model Phase 1 viewshed uses.
- No ready-made Dart/Flutter package exists. Two integration paths considered: (a) Dart FFI wrapper around the official NTIA C++ implementation (public domain, freely usable) — likely the more tractable path but still needs native builds per platform; (b) full reimplementation of the algorithm in Dart — high risk of subtle numerical error given the model's legacy empirical curve-fit complexity, not expected to be a clean one-shot implementation even with AI-assisted coding.
- Any implementation must validate against NTIA's own reference test vectors (`area.csv`/`p2p.csv`) before being trusted, following the same discipline as the Lenth validation checklist.
- **Status: logged for future review, not scheduled to any phase yet.**

### Data Management
- Backup: export full project as a `.zip` archive (~100–250KB uncompressed, ~80–130KB compressed)
- Shareable via WhatsApp, email, or cloud storage
- CSV export: all observation fields, filterable by tag or date range
- Import backup to restore full project state
- Bulk tag import via CSV
- **[Note for Claude Code — import/merge semantics, must be defined]** Importing a project already held in a different state needs an explicit strategy. UUID PKs prevent ID collisions, but define merge vs. overwrite behavior using the per-row `revision` + `updated_at` fields (last-write-wins by default), dedup users by normalized email, and handle corrupt/partial zips without wiping the existing project. Validate `schema_version` and migrate forward if older.
- **[Note for Claude Code — offline tile licensing, resolve early]** Many providers (Google, some Mapbox tiers) prohibit bulk download / offline caching of tiles — satellite especially. Choose a provider whose license explicitly permits offline use (e.g., USGS/USFS topo, appropriately licensed ESRI, or Mapbox's official offline SDK). This constrains the map stack, so decide before building it.
- **[Note for Claude Code — validation]** Bound-check every field on BOTH manual entry and CSV import: frequency (sane VHF range), bearing (0–360), uncertainty (>0), lat/lon ranges, pulse rate. Bulk tag import needs a preview/dry-run before commit and must tolerate Excel UTF-8 BOM and header-name variants.
- **Coordinate display toggle:** offer decimal degrees / DMS / UTM (biologists and GIS handoffs vary); datum is WGS84 and stated explicitly.

### Security & Data Integrity
- Only the observation's creator can edit that observation
- Only the project owner can delete observations or modify project settings
- Roles: owner, contributor, viewer
- **[Important — Phase One reality]** With no server, everything is device-local and roles/permissions are **advisory only**: anyone holding the backup file can edit its contents. This is acceptable for Phase One, but the app (and users) should not mistake it for enforced security. Real enforcement arrives with the Phase Three server.
- **[Note for Phase Two]** Notes field is plain text only — no rich HTML. Sanitize inputs when server sync is added; encode output for web display to prevent XSS injection
- Tags and membership records are never deleted, only deactivated (audit trail preserved); all other records use soft-delete (`deleted_at`)

### Performance & Battery
- GPS throttled to every 5–10 seconds during active use
- Pause GPS, viewshed computation, and other background processes when the app is backgrounded
- Progress bar/indicator during long operations (viewshed computation, Lenth calculation)
- Haptic feedback on all scroll interactions

### Display Conventions
- Map labels show `tag_name` and `frequency_mhz` (never the internal `tag_id`) on all map overlays
- Observation rays: lines from the observer point at the recorded bearing angle, labeled with tag name/frequency
- Uncertainty ellipses: semi-transparent overlay on estimated positions
- Local time shown throughout the UI; UTC available in underlying data records

### Project & Team Management
- Project QR code as a join mechanism (Phase One: local project ID; Phase Two: server-based handshake)
- Owner can transfer ownership
- Project owner can add, remove, or deactivate members
- Tag database is global; each project selects a subset via `Project_Tags`
- Project tags are manageable after project creation (add, deactivate — never delete)

---

## Algorithm Validation Checklist (for Claude Code)
1. Implement Lenth MLE per the 1981 Technometrics paper
2. Reproduce the paper's worked example to confirm correctness
3. Cross-validate against R packages `radiotrack` and `sigloc` using shared test data
4. Confirm uncertainty ellipse parameters (semi-major, semi-minor, rotation) match expected outputs
5. Confirm pairwise intersection calculations are independent of and consistent with the MLE result
6. Verify circular-statistics handling across the 0/360 boundary (350°→10° sweep midpoint = 0°)
7. Verify all degenerate-geometry guards (N=1, near-parallel, coincident observers, near-singular) fail gracefully with warnings, never NaN/crash
8. Verify declination sign and magnitude against a known reference for Flagstaff (~+10° E)

---

## Field-Readiness (Phase One)
- **Pre-trip checklist** surfaced before heading out of connectivity: maps + DEM downloaded for the project bounding box, tags loaded, GPS acquiring, compass calibrated. The classic field disaster is arriving on site with no offline data and no signal to fetch it.
- **Project bounding box** (in Projects) drives tile/DEM pre-download, later crops viewshed, and feeds Phase 2 road optimization and Phase 3 habitat layers.
- **Destructive-action safety:** confirm + undo on deletes; autosave a draft observation so a mid-entry crash (cold hands, dying battery) doesn't lose data.

---

## Map Furniture (Phase One)
- Scale bar, north arrow, live coordinate readout
- Color legend for ray / estimate / tag-location / viewshed scheme
- **Point-to-point measure tool** (distance + bearing between two tapped points)

---

## Open/Deferred Items
- SMS auto-detection for observation sharing — assess complexity; implement in Phase One if straightforward, otherwise defer to Phase Two
- Export interoperability with CyberTracker or similar field data collection platforms (Phase Three candidate)
- Server-based team communication and project join handshake (Phase Three)
- Painted Dog Conservation (Zimbabwe) field-app identification for interoperability export target — **confirmed: SMART Mobile**, which is built on the CyberTracker engine (see below)

## Under Review — Not Yet Approved for Any Phase
These are candidate features surfaced during design discussion. None are committed; all need further review before being scheduled to a phase.

- **Movebank submission.** Movebank's official documented API is a *download* interface; data gets in primarily via manual file upload or a manufacturer-style automated feed arrangement. A couple of third-party API directory listings describe a writable v2 REST endpoint, but this isn't corroborated by Movebank's own docs — needs direct confirmation with Movebank before designing around it. Realistic near-term path if pursued: a Movebank-schema export formatter (mapping `Estimated_Positions`/observations to their expected fields) paired with either a genuine write endpoint (if confirmed to exist) or a manual-upload-ready file. Likely Phase 3 candidate.
- **SMART/CyberTracker interoperability via webhook.** Confirmed: SMART Mobile is built on CyberTracker's engine, used by Painted Dog Conservation. CyberTracker/SMART supports **outbound webhooks** — a POST of JSON to a configured URL whenever a field record is saved. This makes **one-way ingestion (SMART → Tri Track) technically feasible**, but only once Tri Track has a live server (Phase 3) to receive it, plus a parser for CyberTracker's JSON payload shape. The **reverse direction (Tri Track → SMART) has no equivalent inbound mechanism** — would require a manual import via a custom SMART data model configured by the conservation org, which is an organizational ask, not just engineering. Data models are structurally different: SMART is patrol/incident-centric (rangers, threats, sightings); Tri Track is tag/bearing-centric. Only a few fields map cleanly (ISO 8601 timestamps; location as lon/lat/alt/accuracy, which lines up with `latitude`/`longitude`/`elevation`/`position_accuracy_m`). Most of each vocabulary has no counterpart on the other side.
- **ITM relative-detection-likelihood layer** — see Viewshed section above for full detail. Logged here as a cross-reference; same "under review" status applies.

# Handoff: Tri Track — Wildlife VHF Telemetry Field App

## Overview
Tri Track is a Flutter field app for wildlife biologists doing VHF radio-telemetry: taking directional bearings on collared animals, triangulating position from multiple bearings, and managing offline maps in the field. This package covers the full hi-fi visual design (6 screens + splash, light & dark) and the finished brand mark.

## About the Design Files
The files in this bundle are **design references built in HTML** (Design Components run in a browser-based prototyping tool) — they show the intended look, layout, and states, but are not production code to copy directly. The task is to **recreate these designs in Flutter** (the app's actual target platform) using idiomatic Flutter widgets, theming (ThemeData/ColorScheme), and state management — not to embed HTML/WebViews.

## Fidelity
**High-fidelity.** Colors, typography, spacing, and copy below are final. Recreate pixel-accurate layouts using Flutter's widget system; exact hex values and type scale are given so there should be no guessing.

## Brand Mark
- **Icon**: a rounded-square (radius ~22% of size) chip in forest green (#3E7A4C), containing three white converging rays (a stylized triangulation/bearing-fix symbol) meeting at a small filled circle, rotated so the fix point sits upper-left (rotate -90° from the base ray geometry). Ray stroke-width scales with icon size (roughly 6% of icon width), rounded line caps, the two side rays at 75%/50% opacity to suggest secondary bearings converging on the primary.
- **Wordmark**: "TRI" + "TRACK" set as one word, font-weight 800, letter-spacing 0.03em, system sans. "TRI" is near-black (#1a1a1a) in light contexts / off-white (#f3efe4) in dark contexts. "TRACK" is always the brand green: #3E7A4C on light backgrounds, a lightened #6FBF82 on dark backgrounds (for contrast).
- **Splash screen**: full-bleed brand green (#3E7A4C), icon chip rendered in a translucent white circle-square (rgba(255,255,255,0.14) bg), wordmark below at 30px with "TRI" in near-black (#1a1a1a) and "TRACK" in white, plus a small letter-spaced "WILDLIFE TELEMETRY" tagline in rgba(255,255,255,0.6) near the bottom. No dark-mode variant — splash is always the brand green.
- Icon should be exported as a proper vector/asset (SVG or PNG at 1x/2x/3x + adaptive icon for Android) rather than redrawn inline; see the "Icon + wordmark size set" reference for the size ladder and platform variants (iOS squircle 1024, Android adaptive safe-zone, favicon 32).

## Screens / Views
All screens are laid out for a ~402×874pt iPhone viewport (portrait), with a 56px reserved status-bar area at the top and a 44px brand header row directly below it (icon chip 26px + wordmark 15px, 8px gap, 20px horizontal padding, 1px bottom border in the theme's divider color) before any screen-specific chrome. Bottom tab bar is 88px tall, 5 items (Map / Log / Compass / Position / More), each an 8px dot + 11px label, active item colored in the brand green.

### 0 · Splash Screen
**Purpose**: app launch / cold-start branding screen.
**Layout**: full-screen, brand green background, flex column centered, 22px gap between icon and wordmark.
**Components**: 96px icon chip (white rays on 14%-opacity white bg), 30px wordmark, tagline text positioned 56px from bottom.

### 1 · Main Map
**Purpose**: primary map view — see animal positions, bearings, viewshed, and switch basemap style.
**Layout**: brand header (44px) → basemap segmented control (Terrain/Street/Satellite, centered, pill-style, active tab filled brand green / white text) → flex:1 map canvas → 88px tab bar.
**Map canvas contents** (all absolute-positioned over the basemap):
- Own position dot (12px circle, brand green fill, 6px soft halo, 18% opacity ring — neutral chrome color, not a functional/semantic color)
- Two directional bearing rays from own position (2px lines, functional blue #3b82f6, one at 60% opacity)
- Estimated-position marker: 18px circle, 2.5px functional blue border (#2563eb light / #3b82f6 dark), fill matches bg, label "est. position" in functional blue
- Collared-animal marker: 16px square outline, functional green #16a34a (light) / #22c55e (dark) — this is a *different* green from the brand green, meaning "live animal fix"; keep as a separate token (e.g. colorAnimalFix) from colorBrand
- Viewshed ellipse: soft blue-tinted blur ellipse (rgba(96,165,250,0.30)/0.22 dark), label "viewshed" in saturated blue
- Coordinate readout bottom-left, monospace, on a translucent pill
- North indicator bottom-right ("▲ N")
- Layers button top-right: 40×40px white/dark rounded-square icon button
- FAB (add observation): 56px circle, brand green background, "+" glyph, white text, bottom-right above the tab bar, drop shadow tinted brand green (rgba(62,122,76,0.4) light / plain dark shadow)
**Tweak**: a mapStyle enum (realistic | abstract) swaps the basemap between a soft terrain-gradient placeholder and an abstract topographic-line placeholder — both stand in for real map tiles.

### 2 · Observation Logging
**Purpose**: log a single directional/omni bearing observation on a collared animal.
**Layout**: brand header → scrollable form (20px horizontal padding, 12px vertical gaps) → sticky "SAVE OBSERVATION" button + autosave note.
**Components** (each a labeled section, label = 12px/800/letter-spacing 0.04em/muted gray):
- **TAG** picker: 168px tall bordered list showing 5 nearby frequencies, the selected one enlarged (16px/800) and colored in the brand-green text token (#3E7A4C light / #6FBF82 dark), others shown small and faded by distance from the selection (9.5–11.5px, graduated gray)
- **Directional / Omnidirectional** segmented toggle (40px tall, active = brand green fill + white text)
- **BEARING** numeric readout (26px/800 in a bordered pill) + circular edit button (48px)
- **Peak / Null** detection-method toggle (36px, same active styling)
- **Regular pulse / Mortality** toggle (40px, same active styling) — note: despite the word "mortality" this toggle uses the same brand-green active state as everything else; it is not a semantic-danger control
- **SIGNAL STRENGTH**: single bordered pill, 4 inline text options (Faint/Weak/Moderate/Strong) with the selected one underlined, unselected-but-adjacent at 50% opacity
- **BEARING QUALITY**: 3 pill buttons in a row — "Bounce?" (outlined, functional red #dc2626/#f87171), "Fair" (outlined, functional amber #d97706), "✓ Good" (filled, functional green #16a34a/#22c55e) — semantic status colors, keep distinct from brand green
- Collapsible "Advanced" row (dashed border), optional Notes field, GPS coordinate readout with a "Manual pin" affordance in brand-green text, and an "Attach to triangulation session" checkbox
- Sticky footer: 52px "SAVE OBSERVATION" button, brand green fill / white text

### 3 · Compass Calibration
**Purpose**: take a compass bearing on the animal's signal, optionally as a range capture, with interference/level warnings.
**Layout**: brand header → interference warning banner (amber, dismissible) → centered 280×280 compass dial → Magnetic/True readout row → Single Point/Range Capture toggle → Start/End buttons → bearing math readout → "Calibrate (figure-8)" pill → helper caption → sticky "SAVE BEARING" button.
**Compass dial**: etched tick marks every 15° (neutral gray/white), needle rendered as a red kite shape (#dc2626 light / #f87171 dark — the *magnetic* bearing, a functional/instrument color, not brand green) with a dotted true-north sight-line and small flag, a shaded 33° uncertainty wedge (translucent blue), and a center readout disc showing the numeric bearing + magnetic/true split + uncertainty. A small "LEVEL" indicator circle (top-right of dial) turns functional green when the phone is level.
**Range Capture toggle**: active state uses the same brand-green active-pill styling as other segmented controls in the app.
**"SAVE BEARING"** button: 52px, brand green fill, white text.

### 4 · Position Estimation
**Purpose**: review triangulated bearings for a selected animal and compute/save an estimated position.
**Layout**: brand header → frequency/animal selector bar → 44%-height map preview (bearing rays + MLE estimate marker + uncertainty ellipse) → draggable-handle bottom sheet listing each observation → sticky "SAVE POSITION" button.
**Map preview**: 3 bearing rays (functional blue, graduated opacity), dashed uncertainty circle (neutral gray), MLE (maximum-likelihood estimate) marker (functional blue circle + label), "Show intersections" toggle button (top-right), "tap ray to exclude" hint (bottom-left).
**Bottom sheet**: metadata line (N observations, ellipse radius, confidence %, time span) + brand-green-outlined "Recompute" button; amber warning banners for stale time-span or near-parallel bearings; a checklist of individual observations (observer, time, bearing±uncertainty, signal strength, quality), each with a checkbox to include/exclude from the solve.
**"SAVE POSITION"**: 48px, brand green fill, white text.

### 5 · Project Setup / Extent
**Purpose**: create a project, set coordinate format, define the study-area extent on a map, and set the triangulation time window.
**Layout**: brand header → Name/Description/Species-notes text inputs → coordinate-format 3-way toggle (DD/DMS/UTM) → draggable extent-polygon map → time-window stepper → sticky "SAVE PROJECT" button.
**Extent map**: an editable pentagon boundary drawn over the basemap placeholder — fill/stroke/handles all in the brand-green chrome color, draggable vertex handles (small circles), and one non-vertex "add point" handle (an × marker) for inserting a new boundary point. Caption: "drag any point to adjust".
**Time window stepper**: −/+ buttons flanking a centered "15–20 min" readout, neutral (not brand-colored) bordered squares.
**"SAVE PROJECT"**: 48px, brand green fill, white text.

### 6 · Manage Offline Maps
**Purpose**: view/download/update/delete offline map layers for the current project extent.
**Layout**: brand header → "Offline Maps" title → 170px extent-map preview with an "Expand coverage" button → scrollable LAYERS list → sticky storage-usage footer with a progress bar.
**Layers list**: each row is a bordered card with layer name + size/status, and either Update+Delete buttons (downloaded) or a single brand-green "Download" button (not yet downloaded, dashed border card). Layers shown: Terrain, Street, Satellite, DEM (elevation).
**Footer**: "482 MB used · device storage: 12.4 GB free" caption + a 7px rounded progress bar filled in brand green to the used-storage percentage.

## Interactions & Behavior
- Segmented controls (basemap style, Directional/Omni, Peak/Null, Regular/Mortality, Single/Range, coordinate format): tap to select, single active state per group, active = brand-green fill.
- Compass dial should read live device heading in production; the mockup shows a static 145° magnetic / 137° true.
- "Calibrate (figure-8)" opens a guided calibration flow (not designed here — flag for follow-up).
- Position Estimation's observation checklist should recompute the MLE/ellipse live as observations are toggled; "Recompute" is likely a manual re-trigger/fallback.
- Extent-map and offline-map boundary handles are drag-to-adjust; the "+"/× handle inserts a new vertex.
- All primary CTAs ("SAVE …", "Download") are sticky/pinned at the screen bottom above the safe area.
- Warning banners (interference, stale time-span, near-parallel bearings) use functional amber, dismissible where shown with a "✕".

## State Management
- Current basemap style (per Main Map + wherever a basemap preview appears): enum realistic/abstract/satellite/street/terrain.
- Active theme: light/dark (system-driven; every screen has a fully specced dark variant).
- Per-observation form state: tag/frequency, directional vs omni, bearing degrees, detection method, pulse type, signal strength, quality flag, notes, GPS pin, triangulation-session attachment.
- Per-project: name, description, species notes, coordinate format, extent polygon vertices, triangulation time window (minutes range).
- Position-estimation session: list of observations with include/exclude checkboxes, computed N/ellipse-radius/confidence/time-span, warning flags.
- Offline layer download state per layer (not downloaded / downloading / downloaded / needs update) + aggregate storage usage.

## Design Tokens

### Colors — Brand
| Token | Light | Dark |
|---|---|---|
| Brand green (bg/fill) | #3E7A4C | #5FAE71 |
| Brand green (text-on-neutral-bg) | #3E7A4C | #6FBF82 |
| Text on brand-green fill | #ffffff | #0d1a10 |
| Brand green shadow tint | rgba(62,122,76,0.4) | rgba(95,174,113,0.5) |
| Wordmark "TRI" | #1a1a1a | #f3efe4 |

### Colors — Functional (do not rebrand these)
| Meaning | Light | Dark |
|---|---|---|
| Bearing / MLE / est. position (blue) | #3b82f6 / #2563eb | #60a5fa / #3b82f6 |
| Animal live-fix marker (green) | #16a34a | #22c55e |
| Bearing quality: bounce/bad (red) | #dc2626 | #f87171 |
| Bearing quality: fair (amber) | #d97706 | #f59e0b / #fbbf24 |
| Compass needle — magnetic (red) | #dc2626 | #f87171 |

### Colors — Neutrals
| Token | Light | Dark |
|---|---|---|
| App background | #eeeeec | #141414 |
| Card/sheet background | #ffffff | #1c1c1c / #1f1f1e |
| Primary text | #1a1a1a | #f2f2f0 |
| Secondary/muted text | #6b6b68 / #8a8a86 / #a3a39f | #9c9c98 / #8f8f8b / #6c6c68 |
| Border/divider | #e2e2df / #1a1a1a (heavy) | #2a2a2a / #2c2c2a / #f2f2f0 (heavy) |

### Typography
- Font: system sans (-apple-system / Helvetica Neue / Arial) throughout — in Flutter, default to the platform font (San Francisco/Roboto) via the app's TextTheme.
- Scale in use: 8–10px (map micro-labels, tick labels) · 11–13px (secondary/list text, buttons) · 14–16px (section headers, body) · 18–20px (screen titles) · 24–30px (bearing readout, wordmark).
- Weights: 400 (rare/body), 600–700 (buttons, labels), 800 (headers, key readouts, wordmark).
- Section eyebrow labels: 12px / 800 / letter-spacing 0.04em / uppercase / muted color.
- Wordmark: letter-spacing 0.03em / 800.

### Spacing & Radius
- Screen horizontal padding: 20px.
- Vertical rhythm between form sections: 10–12px gap.
- Card/input border-radius: 10px (small), 12px (larger cards/tag list), 20–22px (pill buttons), 50% (circular buttons/avatars).
- Icon chip radius: ~22% of icon size (9px at 40px, 26px at 120px).
- Borders: 1.5px solid for most bordered controls; 1px for hairline dividers.
- Touch targets: buttons/toggles are 36–52px tall; icon buttons 40–56px — keep ≥44pt minimum in the Flutter build.

## Assets
- All UI iconography (compass needle, tab-bar dots, layers glyphs, map pins) is drawn with inline SVG/CSS shapes in the mockups — no export needed for those. Map basemaps are gradient/pattern placeholders standing in for real tile imagery (MapBox/MapLibre/etc. in production).
- **App icon exports are included** in `assets/icon/`:
  - `tritrack-icon.svg` — master icon (rounded-square brand-green bg + white rays), source of truth.
  - `tritrack-icon-adaptive-foreground.svg` / `tritrack-icon-adaptive-background.svg` — Android adaptive-icon layers (foreground rays scaled to the safe zone, solid-green background layer).
  - `tritrack-icon-monochrome-white.svg` — rays only, transparent background, for dark surfaces or single-color print use.
  - `png/` — rasterized PNGs at 16, 29, 32, 40, 58, 60, 80, 87, 120, 152, 167, 180, 512, 1024px (covers iOS AppIcon.appiconset slots and standard web/favicon sizes), plus 1024px PNGs of the adaptive foreground/background/monochrome variants.
  - Regenerate any missing size by rasterizing `tritrack-icon.svg` — it's built on a 120×120 grid so it scales cleanly.

## App Icon Setup Notes
- **iOS**: drop the PNGs into `Assets.xcassets/AppIcon.appiconset` (Xcode maps sizes to slots automatically) or use `flutter_launcher_icons` pointed at the 1024px master.
- **Android**: use the two adaptive-icon layers (`tritrack-icon-adaptive-foreground` + `-background`) via `mipmap-anydpi-v26/ic_launcher.xml`, or again via `flutter_launcher_icons` with `adaptive_icon_foreground`/`adaptive_icon_background` set.
- **Web/favicon**: use `png/tritrack-icon-32.png` and `png/tritrack-icon-16.png`, or the SVG directly in modern browsers.

## Files
- TriTrack Hi-Fi.dc.html — all 7 screens (splash + 6 app screens), light + dark, with realistic sample telemetry data.
- TriTrack Logo.dc.html — full logo exploration history; the **final locked mark is turn 6, option "6c"** (thick converging rays, white-on-brand-green), with the icon+wordmark size set and platform variants in turn 7.
- TriTrack Wireframes.dc.html — original lo-fi wireframes (structure/flow reference only, superseded visually by the hi-fi file).

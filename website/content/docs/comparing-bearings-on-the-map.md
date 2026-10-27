---
title: "Comparing bearings on the map"
description: "Stretching a bearing out to see where it actually crosses another one, and why a longer ray is a wider one."
weight: 35
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): map_screen.dart (Layers & Filters,
the drag readout), tile_fetch_health.dart (tiles not arriving, download retry),
more_screen.dart, manage_offline_maps_screen.dart, offline_data_map_screen.dart.
-->

Bearings from well-separated spots cross where the animal is, but the Map tab
draws every ray at the same short length. You can drag a ray out to see the
crossing. _Nothing on the map says this gesture exists_, so this page is where
it is written down.

## Stretch a bearing

1. _Tap a bearing_ (anywhere on the ray, or the small circle at its base) to
   select it.
2. _A round handle appears at its tip._ If the tip is off screen, the handle
   sits at the last point you can reach.
3. _Press and hold the handle and drag along the line_: out to lengthen, back
   to shorten. Sideways movement is ignored, so the heading cannot change.

{{< shots >}}
{{< shot "bearing-selected" "A bearing tapped and selected. The small round dot at the far end of the ray is the handle; it appears only while a bearing is selected." >}}
{{< shot "bearing-dragged" "Mid-drag. The ray and its wedge have extended and the readout at the top names the length. The crosshair is not part of the app: it is where the tool that generates these pictures is holding its finger." >}}
{{< /shots >}}

While you drag, the readout shows {{< app "Drawn to" >}} and the distance.
Stretch several bearings and look where their wedges overlap.

## A longer ray is a wider one

A bearing's uncertainty is an angle, and an angle covers more ground the
farther out you go. A five-degree cone spans about 35 m at 400 m and close to
900 m at 10 km. That is why the wedge widens as you drag, and why two long
wedges crossing at a shallow angle say much less than their center lines
suggest. _Read the crossing from where the wedges overlap, not where the lines
meet._

## Lengths are not saved

A drawn length is display only: not saved, exported or synced. To put lengths
back, double-tap a tip, or use {{< app "Reset bearing lengths" >}} in
{{< app "Layers & Filters" >}}:
{{< app "Press and hold a selected bearing’s tip to drag its length. Lengths are for display only and reset when you leave the map." >}}
It is gray when nothing has been dragged.

The rays on the Position tab cannot be dragged: their lengths come from the
estimate.

## When map tiles stop arriving

Every map in the app, including the Position tab, says
{{< app "New map tiles are not arriving." >}} when the background stops filling
in. It does not guess why (no coverage and a provider outage look the same from
the phone), and it says what still works:
{{< app "Tiles already downloaded still draw, and recording a bearing does not need the map service." >}}

## Downloading map tiles for offline use

On wifi, open {{< app "More" >}} → {{< app "Manage Offline Maps" >}} →
{{< app "Manage on map" >}}, tap {{< app "New selection" >}}, cover your study
area, and tap {{< app "Download" >}}. The app asks you to
{{< app "Keep TriTrack open" >}} until it finishes. Each phone keeps its own
maps.

If some tiles do not arrive, the card says how many:
{{< app "Retry asks only for the ones still missing — whatever did arrive is already on this device." >}}

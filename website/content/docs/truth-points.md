---
title: "Truth points"
description: "Recording where the animal or the tag actually turned out to be, correcting one afterwards, and what comes out in the export."
weight: 35
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): observation_logging_screen.dart (the Truth
form and its precision helper), truth_point_edit_dialog.dart (panel lines, edit dialog, the
delete confirmation used by both the map and the Log), log_screen.dart, map_screen.dart.
Export: data_export_screen.dart writes truth_points.csv into the one .zip
(csv_export_archive.dart); columns from actual_tag_location_csv.dart.
-->

A truth point records where somebody physically found the animal, the tag, or
both. It is the yardstick for checking estimates against, so it never feeds an
estimate itself: TriTrack keeps it apart from bearings.

## Recording one

{{< shot "record-truth" "The record screen with the Truth tab chosen. What was found and the precision are the two fields that decide what the point means." >}}

On the Record tab, pick {{< app "Truth" >}} and the tag. Then two fields:

- _{{< app "WHAT WAS FOUND" >}}_: {{< app "Animal + tag" >}},
  {{< app "Animal only" >}} or {{< app "Tag only" >}}. As the screen says,
  {{< app "Only \"animal + tag\" checks a bearing estimate of a live tagged animal. A tag on its own may have been shed." >}}
- _{{< app "PRECISION" >}}_: a radius in meters, required.
  {{< app "SAVE TRUTH POINT" >}} stays gray until it is above zero. On a GPS
  fix it is prefilled from the phone's accuracy, with
  {{< app "Raise or lower it if you know better." >}} You often do: standing
  over the tag with it in your hand, type over the phone's ±12 m. For a pin
  placed on the map nothing is prefilled:
  {{< app "Not prefilled for a map pin: a pin is only as precise as your placing of it, and imagery can be off by a few meters." >}}

{{< app "Notes (optional) — e.g. found in burrow" >}} is for what you saw.
{{< app "Preview/Set" >}} places the pin somewhere you could see but not stand,
which is common here.

## Where they show up

- _Map_: a small square in the animal's color, labeled from
  {{< app "Truth" >}} with the tag's name and frequency (an estimate's label
  starts {{< app "Estimate" >}}). Tap it for the panel below.
- _Log_ ({{< app "More" >}} → {{< app "Log" >}}): a row starting
  {{< app "📍 Truth point · " >}}, with what was found, precision, finder and
  how the position was got.
- _Export_: its own file; see [below](#what-comes-out-in-the-export).

## The panel on the map

{{< shot "truth-point-panel" "Tapping a truth point on the map. Everything that decides whether the point can be used is on the panel: what was found, the precision, how the position was got, and who found it." >}}

- What was found and the precision, side by side, because each means little
  alone.
- {{< app "Position: " >}} one of {{< app "GPS fix" >}},
  {{< app "Placed by hand on the map" >}}, {{< app "Entered by hand" >}} or
  {{< app "GPS fix, later moved by hand" >}}.
- {{< app "Found by: " >}} the person who recorded it, not whoever last
  corrected it.

An older point missing any of these says {{< app "not recorded" >}} rather than
going blank, so nobody assumes a GPS fix or an animal-and-tag find.
{{< app "Navigate" >}} points the Compass tab at the point, with the distance.

## Correcting one

{{< shot "truth-point-edit" "Correcting a truth point. The position, the precision and what was found can all be changed; who found it and when cannot." >}}

Open it with {{< app "Edit" >}} on the map panel, or from the Log row's
three-dot menu: {{< app "Edit position / precision / what was found…" >}}

- _Position_: {{< app "Move on map…" >}} and drag the pin, for a point recorded
  from a vehicle or across a fence. A moved GPS fix becomes
  {{< app "GPS fix, later moved by hand" >}}.
- _Precision_: if you moved the pin, the dialog warns the old figure was for
  the old spot.
- _What was found._

_Who found it_ and _when_ cannot be changed. Your name is still recorded
against the edit.

## Who may change one

Any contributor or owner may correct or delete _any_ truth point, not only
their own, because a wrong precision spoils everyone's accuracy check. A viewer
sees {{< app "Viewers cannot change or delete a truth point — ask an owner to change your role." >}}
See [roles](../projects-members-and-roles/).

## Deleting one

{{< app "Delete" >}} is beside {{< app "Edit" >}} on the panel and in the Log
menu. It asks first:
{{< app "Where the animal or tag was actually found cannot be re-measured from your desk." >}}
{{< app "Deleting removes it from accuracy checks, the map, the Log and the CSV export, on every device once they sync." >}}
{{< app "You can undo it straight after." >}} The undo restores the same point,
with its finder and history.

## What comes out in the export

The CSV export is one zip, and a project with truth points gets a
`truth_points.csv` in it, one row per point. The columns to know:

- `found_kind`: `animal_and_collar`, `animal_only` or `collar_only`. Filter on
  this before computing anything.
- `precision_m`: the radius; never empty.
- `position_source`: `gps_fix`, `manual_pin`, `gps_fix_adjusted` or
  `manual_entry` (empty for points older than the field). It tells measurements
  from map readings.
- `found_by`: the finder's name. Empty means none was recorded; it is never
  filled from the last editor.
- Paired tag columns: the tag's name and frequency when the point was taken,
  and now.

More on [getting your data out](../getting-your-data-out/).

---
title: "Getting your data out"
description: "Exporting a project's records as spreadsheets, taking a backup file off the phone, and sending one record to somebody."
weight: 50
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): data_export_screen.dart (_exportCsv writes
one <project>_csv_<date>.zip; entries from csv_export_archive.dart plus deployments.csv; the
"Exported …" receipt), log_screen.dart, observation_sharing_screen.dart, map_screen.dart.
/w-35 (2026-10-10): position_estimates.csv (task 11.323, position_estimate_csv.dart) and
deployments.csv's time_zone, attached_day and removed_day (task 11.331, deployment_csv.dart).
-->

A spreadsheet is for analysis; a backup file moves a whole project or keeps a
second copy of it. Both are under {{< app "More" >}} →
{{< app "Data Export / Backup" >}}, and any role, viewers included, can use
both.

{{< shots >}}
{{< shot "more" "Data Export / Backup is on the More tab, near the bottom." >}}
{{< shot "data-export" "Both exports on one screen. The backup is the whole project; the spreadsheet is filtered by tag or by date." >}}
{{< /shots >}}

## Spreadsheets

Optionally filter by one tag or a date range, then tap
{{< app "Export CSV" >}} and choose where to save. You get one zip file named
for the project and the date, holding:

- `observations.csv`: one row per bearing, with time, position, magnetic and
  true bearing, uncertainty, quality, observer and notes;
- `non_detections.csv` and `truth_points.csv`, when the project has any
  no-signal records or [truth points](../truth-points/);
- `tags.csv`, `individuals.csv` and `deployments.csv`: the tags, the animals,
  and which tag was on which animal when;
- `position_estimates.csv`, when the project has saved estimates: one row per
  saved [estimate](../estimating-a-position/), with when and who saved it, the
  tag and the animal, the point, the 95% ellipse (empty for a two-bearing
  estimate, which has none) and the bearings it used.

The message afterwards counts what it wrote (observations, non-detections,
truth points, position estimates, tags, animals); a kind not mentioned had
nothing in it.

_In `deployments.csv`, use `attached_day` and `removed_day` for dates._ They
are the days as written in the field, in the project's
[time zone](../setting-up-a-project/#create-it), which `time_zone` names.
`attached_date` and `removed_date` are the same moments in UTC, so in a
spreadsheet a New Zealand season's days read a day early there.

_Tag columns come in pairs:_ what the tag was called and tuned to when the
bearing was taken, and what it is now, so a mid-season retune stays visible. A
bearing too old to know what it was recorded against leaves the first pair
empty rather than filling in today's values, and a column says so.

## A backup of the whole project

{{< app "Export project backup (.zip)" >}} writes everything in the project
(records, tags, people, map extent) into one small file you can send or store
anywhere.

{{< app "Import backup" >}} reads one back in. It adds to and corrects the
project rather than replacing it; anything it would overwrite is listed, old
value and new, before you agree. You need write access to the project.

## Sending one record

_To someone using TriTrack:_ on the {{< app "Log" >}} tab, a row's ⋮ menu has
{{< app "Share observation…" >}}, which copies a block of text. They open
{{< app "More" >}} → {{< app "Observation Sharing" >}},
{{< app "Paste from clipboard" >}}, {{< app "Parse" >}}, and see it before
anything is saved.

{{< shot "paste-preview" "The preview after pasting a colleague's bearing. Nothing is stored yet; this is the screen for deciding whether it is the record you were expecting and which of your own tags it belongs to." >}}

The card names who took the record (not who forwarded it) and whether the tag
details are as recorded at the time or as they read on the sender's phone
today, which matters if the tag was retuned.

_To someone who is not:_ tap a bearing, estimate or truth point on the map and
use the share menu on its card. {{< app "Copy coordinates" >}} copies the
position, {{< app "Open in Maps" >}} hands it to the phone's maps app, and
{{< app "Share…" >}} sends a `.gpx` waypoint that a handheld GPS, Gaia or
CalTopo can read. A bearing's card also has {{< app "Copy for TriTrack" >}}.

None of this is sync: it goes only to the person you send it to.

## Back up what has not synced

Unsynced records exist only on that phone. When working without coverage for days,
take a backup file off it every few days and put it somewhere else; it takes
seconds. {{< app "Sync Status" >}} shows how many records are waiting
([sync](../sync/)).

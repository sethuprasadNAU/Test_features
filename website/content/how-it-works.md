---
title: "How it works"
description: "A field day with TriTrack, from setting up the night before to the spreadsheet afterward."
---

One day of tracking, in order, with a link at each step to the full guide page.
The pictures show invented data.

## The night before

Open {{< app "More" >}} → {{< app "Pre-Trip Checklist" >}}. It shows what the
phone has ready for working without cell or wifi coverage, including whether your study
area's map is downloaded. If not, download it now, on wifi. See
[downloading map tiles](../docs/comparing-bearings-on-the-map/#downloading-map-tiles-for-offline-use).

{{< shot "checklist" "The Pre-Trip Checklist: each line is something the phone needs before it loses cell or wifi coverage, with what it found." >}}

## Take a bearing

On the {{< app "Record" >}} tab, spin the wheel to the tag you hear, point the
antenna, and tap {{< app "POINT" >}} at the peak or hold {{< app "RANGE" >}}
while you sweep across it. Choose the quality and save. Position and time are
filled in for you, and none of it needs cell or wifi coverage. See
[recording a bearing](../docs/recording-a-bearing/).

{{< shot "record" "The Record tab: the tag wheel, the live bearing, and the two ways to take it." >}}

## See where the animal is

Take another bearing from somewhere else. The {{< app "Position" >}} tab
estimates the location from the selected bearings, with an ellipse for the
uncertainty, and says in words when the geometry is poor. Untick a doubtful
bearing to see its effect. {{< app "SAVE POSITION" >}} keeps the estimate. See
[estimating a position](../docs/estimating-a-position/).
How the estimate is calculated, with the equations and the paper it comes from,
is [its own page](../docs/how-the-estimate-is-calculated/).

{{< shot "position" "The Position tab. Every bearing is listed with its time, direction, uncertainty and quality; unticking one recalculates the estimate." >}}

The {{< app "Map" >}} tab draws the day's bearings from everyone on the project,
each with a wedge for its uncertainty; drag a ray out to see where it crosses
another.

{{< shot "map" "The Map tab: each bearing is a line from where it was taken, with a wedge for its uncertainty." >}}

## Sync when back in range

Signed in to the TriTrack server, the app sends your records and collects your teammates'
whenever there is a connection; a mark on the {{< app "More" >}} tab shows how
it is going. Without a server, nothing happens and nothing nags. See
[sync](../docs/sync/).

{{< shot "joined-sync-indicator" "The map on a device that syncs. The sync icon is the small round button directly above the +, and here it is a green tick: this device is up to date." >}}

## Get the data out

{{< app "More" >}} → {{< app "Data Export / Backup" >}} writes spreadsheets,
filtered by tag or date if you like, or a backup of the whole project. See
[getting your data out](../docs/getting-your-data-out/).

## Trying it

TriTrack is not available to download yet. To learn more or try it on a
project, see [Support](../support/).

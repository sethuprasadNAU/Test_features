---
title: "TriTrack"
description: "Radio-telemetry field data collection for wildlife research: record bearings on the spot, see where the animal is, and keep a team's data in one place."
---

# TriTrack

TriTrack is a phone app for wildlife VHF radio telemetry. Point the antenna,
record the bearing, and see where the animal is while you are still in the
field.

{{< shot "position" "The Position tab: five bearings on one tag, the estimated location, and the shaded ellipse that shows how uncertain it is. Invented data, generated from the app itself." >}}

## What it does

### Bearings go straight into a record

Each bearing is saved on the phone as you take it, with the time, your
position, the direction, signal strength and uncertainty. Nothing to transcribe
at the truck. Tap at the signal's peak, or sweep across it and let the app take
the middle and record the width as your uncertainty. See
[recording a bearing](docs/recording-a-bearing/).

### The location, before you leave the field

The phone estimates the animal's position from the bearings you have taken,
with an ellipse for the uncertainty, and warns when the geometry is poor (for
example, nearly parallel bearings) while you can still move. {{< app "Take on map" >}}
shows a sweep crossing your earlier bearings before you accept it.

{{< shot "take-on-map-released" "Take on map, after a sweep. The wide wedge is the bearing just taken, crossing the two earlier ones on the same tag, with the number it read and the three buttons that wait for you." >}}

### No cell or wifi coverage needed

Recording and estimating use no network. Download your study area's map before
you leave coverage; the pre-trip checklist shows what is ready. With no server
at all, the app is still complete. See [how it works](how-it-works/).

{{< shot "checklist" "The Pre-Trip Checklist: each line is something the phone needs before it loses cell or wifi coverage, with what it found." >}}

### One dataset for the whole team

Signed in to the TriTrack server, everyone's bearings sync into one shared project, with
owners, contributors and viewers, instead of several spreadsheets to merge.
Teammates' bearings appear on your map and in your estimates, and syncing
happens whenever a connection returns. See
[projects, members and roles](docs/projects-members-and-roles/).

{{< shot "joined-sync-indicator" "The map on a device that syncs. The sync icon is the small round button directly above the +, and here it is a green tick: this device is up to date." >}}

### It knows which tag was on which animal

Tags, animals and the dates each tag was worn are separate records, so a
bearing taken before a tag moved to another animal, or was retuned, stays with
the right animal. See [managing your tags](docs/managing-your-tags/).

The data comes out as spreadsheets or as a backup of the whole project. See
[getting your data out](docs/getting-your-data-out/).

## Where it stands

TriTrack is developed by one person in the Dynamic and Active Systems Lab at
Northern Arizona University. _It is not available to download yet:_ there is no
store listing or public test version. The guide describes the app as it is
today, from an iPhone; nothing here covers Android yet.

If you work with radio-tagged animals and would like to try it on a project,
see [Support](support/).

- [Quick start](docs/quick-start/): from a new install to the first bearing.
- [How it works](how-it-works/): a day in the field, step by step.
- [User guide](docs/): every screen, in detail.
- [Support](support/): how to get in touch.
- [Privacy](privacy/): what the app stores and where it goes.

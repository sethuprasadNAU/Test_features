---
title: "Quick start"
description: "From a new install to the first bearing: the six things to do before a project goes into the field, each with a link to the full page."
weight: 5
---

<!--
Every quoted string on this page is read from the widgets (task /w-34, 2026-10-01; steps
1, 3, 4 and 5 re-read for /w-35, 2026-10-10, after tasks 11.324 and 11.331):
projects_screen.dart (the + button, the three-dot menu), project_setup_screen.dart,
animals_screen.dart and quick_add_screen.dart, manage_offline_maps_screen.dart and
offline_data_map_screen.dart, pretrip_checklist_screen.dart, more_screen.dart,
project_members_screen.dart, join_project_screen.dart, observation_logging_screen.dart.
Offline maps are stored per phone: offline_region_store.dart keeps them in the app's
own directory and nothing in the sync code reads them.
-->

Six steps, in order. The first time you open TriTrack it asks for your name
and email, which label everything you record.

## 1. Create the project

Open {{< app "More" >}}, then {{< app "Projects" >}}, and tap the + button at
the bottom right. Give it a {{< app "Name" >}}, and set its area with
{{< app "Set extent on map" >}}: that is the area the offline maps and the
checklist cover, so make it the whole study area. Tap
{{< app "SAVE PROJECT" >}}. The {{< app "Finish setting up" >}} sheet that
follows offers to publish the project and download its offline maps;
{{< app "Start" >}} does both. More in
[setting up a project](../setting-up-a-project/).

## 2. Add the animals and their tags

On {{< app "More" >}} → {{< app "Animals" >}}, tap {{< app "Quick add" >}}. Set
the day the tags went on once, at the top, then type one row per animal: its
name and its frequency, or paste the rows from a spreadsheet. A frequency that
matches no tag on the project or in your Tag Library becomes a new tag. Nothing
is saved until you tap {{< app "Review" >}} and then the add button under it.
More in [putting a tag on an animal](../managing-your-tags/#putting-a-tag-on-an-animal).

{{< shot "quick-add" "Quick add with three animals typed in. The date card at the top applies to every row." >}}

## 3. Download offline maps

On wifi, keep the app open until the download from step 1 finishes, or start
one from {{< app "More" >}} → {{< app "Manage Offline Maps" >}}. Each phone
keeps its own maps, so every member of the crew does this. More in
[downloading map tiles](../comparing-bearings-on-the-map/#downloading-map-tiles-for-offline-use).

## 4. Run the pre-trip checklist

{{< app "More" >}} → {{< app "Pre-Trip Checklist" >}}. Before you lose cell
or wifi coverage, every line should show a tick rather than an exclamation
mark: your identity, the maps and elevation for the project's area, the
project's tags, a GPS fix, the compass and, with a server, that the project is
published. The line under each says what it found. More in
[setting up a project](../setting-up-a-project/#the-pre-trip-checklist).

{{< shot "checklist" "The Pre-Trip Checklist. Every line is ready except the offline maps for the project's area, which shows their size and a Download button." >}}

## 5. Invite the crew

This step needs the TriTrack server and a connection, and the project must be
published first: the crew cannot join a project that is only on your phone.
Sign in under {{< app "More" >}} → {{< app "Server Connection" >}}. If you did
not publish in step 1, choose {{< app "Publish to server" >}} from the
three-dot button on your project's row under {{< app "Projects" >}}. Then choose
{{< app "Members" >}} from the same menu (see
[publishing](../setting-up-a-project/#publish-before-the-crew-can-join)). Turn on
{{< app "Let people join with a code" >}} and give the code to your crew. Each
of them signs in the same way, asks with the code under {{< app "Projects" >}} →
{{< app "Join a project" >}}, and you approve each one. More in
[joining a project](../joining-a-project/).

{{< shot "owner-members-and-code" "The Members screen on the owner's phone, with joining turned on and the code showing." >}}

## 6. Take the first bearing

On the {{< app "Record" >}} tab, spin the wheel to the tag you are hearing.
Point the antenna, tap {{< app "POINT" >}} when the signal peaks (or hold
{{< app "RANGE" >}} while you sweep across it), say how good it was, and tap
{{< app "SAVE OBSERVATION" >}}. None of this needs cell or wifi coverage. More in
[recording a bearing](../recording-a-bearing/).

{{< shot "record" "The Record tab, ready to take a bearing." >}}

With two or more bearings on one animal, the {{< app "Position" >}} tab
estimates where it is. See [estimating a position](../estimating-a-position/).

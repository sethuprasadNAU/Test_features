---
title: "Setting up a project"
description: "Creating a project: its area and time zone, the Finish setting up sheet, offline maps, the Pre-Trip Checklist, and publishing it so the crew can join."
weight: 7
---

<!--
Strings read from the widgets (/w-35, 2026-10-10): project_setup_screen.dart (the New
Project form, the extent and time zone sections, the change-zone confirmation),
widgets/finish_setting_up_sheet.dart, pretrip_checklist_screen.dart (the two rows task
11.324 added), manage_offline_maps_screen.dart, offline_data_map_screen.dart,
projects_screen.dart. What Start does: project_setup_screen.dart `_offerFinishSettingUp`
(queues the Offline Data screen's own download over the project's rectangle, and publishes
only when this phone is signed in).
-->

For whoever creates the project, usually the crew lead. The crew do not repeat
it: they [join](../joining-a-project/) the project you publish.

## Create it

Open {{< app "More" >}} → {{< app "Projects" >}} and tap the + button at the
bottom right. Only {{< app "Name" >}} is required, but set the area before you
save.

{{< shot "new-project-form" "The New Project form, scrolled to the project's area and time zone. The area was set with Use current location, and the time zone was worked out from its center." >}}

- _The area_ ({{< app "PROJECT EXTENT" >}}): {{< app "Set extent on map" >}}
  to drag a rectangle over the study area, or {{< app "Use current location" >}}
  for about a kilometer around where you stand. It is where maps open, and it is
  the area the offline maps below and the checklist's map line cover, so make it
  the whole study area.
- _The time zone_ ({{< app "TIME ZONE" >}}):
  {{< app "The days tags go on and come off are days in this time zone, wherever the phone showing them is." >}}
  It is worked out from the center of the area
  ({{< app "Chosen from the center of your project area." >}}). If that is
  wrong, tap {{< app "Change time zone" >}} and search for a city. Changing it
  later rewrites nothing: days already recorded stay the same days.

Then tap {{< app "SAVE PROJECT" >}}. It becomes the open project. To change any
of this later, use {{< app "Edit project" >}} in the project's row menu.

## Finish setting up

A new project is followed by one sheet with two choices, both ticked.

{{< shot "finish-setting-up" "Finish setting up, straight after SAVE PROJECT on a phone signed in to a server. Both choices are ticked; the maps line gives the download's size." >}}

- {{< app "Publish to the server now" >}}: shown only when the phone is signed
  in. It makes you the project's owner on the server, which is what lets the
  crew join.
- {{< app "Download offline maps for this area now" >}}: the map and elevation
  for the project's area, with an estimate of the size. Do it on wifi.

{{< app "Start" >}} does both. Keep TriTrack open until the download finishes:
it pauses if you leave the app. {{< app "Later" >}} starts nothing, and
{{< app "Later leaves these on the Pre-Trip Checklist." >}}

## More offline maps

Each phone keeps its own maps, so every member of the crew downloads them too.
For more than the project's area, or a different shape, draw it yourself:
{{< app "More" >}} → {{< app "Manage Offline Maps" >}} →
{{< app "Manage on map" >}}, then {{< app "New selection" >}}. The steps are on
[the map page](../comparing-bearings-on-the-map/#downloading-map-tiles-for-offline-use).

{{< shot "offline-data-selection" "The Offline Data Map after New selection: drag the corners over the area you need, then tap Download. The card gives the area and an estimate of the tiles and size." >}}

## The Pre-Trip Checklist

{{< app "More" >}} → {{< app "Pre-Trip Checklist" >}} checks what the phone
needs before it loses cell or wifi coverage. Two lines are about this setup:

- {{< app "Offline maps for this project's area" >}}: done only when the map and
  the elevation both cover the whole area. Otherwise it gives the size and a
  {{< app "Download" >}} button.
- {{< app "Published to the server" >}}: shown only when a server is set up.

{{< shot "checklist" "The Pre-Trip Checklist on a phone with no server set up, so there is no Published line. The project's area has no offline maps yet, so that line gives the size and a Download button." >}}

## Publish before the crew can join

A project that is only on your phone cannot be joined. Publish it from the
sheet above, or later with {{< app "Publish to server" >}} in the project's row
menu under {{< app "Projects" >}}. Then open {{< app "Members" >}}, turn on
{{< app "Let people join with a code" >}}, and give the crew the code. The rest
is on [joining a project](../joining-a-project/).

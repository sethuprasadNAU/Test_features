---
title: "Recording a bearing"
description: "The core of the app: point the antenna, take the bearing, save it."
weight: 30
---

<!--
Strings read from the widgets (/w-33, 2026-10-01): observation_logging_screen.dart (record
types, the tag wheel and its sort switch, quick-add, the empty states, the save bar),
bearing_map_capture_screen.dart (Take on map).
The wheel lists only tags on an animal right now (tagIdsAudibleOn, tasks 11.249 and 11.260), each
line frequency · animal in the order of the switch (_tagLine).
-->

Pick the tag, point the antenna, take the bearing, save.

{{< shot "record" "The Record tab, ready to take a bearing. The round button with a map on it, beside RANGE, is Take on map." >}}

_The pictures on this page are of a device with no server set up, so there is
no sync mark on them; the [sync](../sync/) page shows what one looks like._

## Choose the record type

The icons along the top pick it; only the selected one shows its name.
{{< app "Bearing" >}} is a direction to one animal, and most of this page is
about it. The others:

- {{< app "Omni" >}}: heard on an omnidirectional antenna, no direction.
- {{< app "Note" >}}: something worth writing down here and now that is not a
  detection.
- {{< app "No Signal" >}}: you listened for these frequencies here and heard
  nothing. Record it: it is evidence about where the animal was not.
- {{< app "Truth" >}}: you found the animal or the tag, and this is where it
  was. See [truth points](../truth-points/).

## Pick the tag

Spin the wheel to the tag you are hearing. It lists only tags on an animal
right now, each as its frequency and the animal's name. The two-icon switch beside
it sorts by frequency or by animal, and the phone remembers your choice.

If the tag you are hearing is not there, scroll to
{{< app "＋  Add new tag" >}} at the bottom of the wheel. It asks for a
{{< app "Tag ID" >}}, a {{< app "Frequency (MHz)" >}} and an
{{< app "Animal name" >}}, and
{{< app "Adds the tag to the Tag Library and the animal under Animals, wearing it from today." >}}
For a tag already in your library, link it instead, under
[putting a tag on an animal](../managing-your-tags/#putting-a-tag-on-an-animal).

With no tag on any animal, the wheel is replaced by
{{< app "No tag is on an animal today" >}} (or
{{< app "No tags in this project yet" >}}) and a {{< app "+ Quick-add tag" >}}
button. A viewer cannot add tags and is told so:
{{< app "Viewers cannot create tags" >}}.

## Take the bearing

Point the antenna; the number shown is the phone's live magnetic heading. Then:

- {{< app "POINT" >}}: tap when the signal peaks. Tap again to clear it.
- {{< app "RANGE" >}}: hold it while you sweep from one edge of the signal to
  the other, then let go. The middle of the sweep is the bearing and its width
  is the uncertainty. Use it on a broad peak; a point tap records a fixed
  uncertainty instead.

The pencil beside the number types a bearing in by hand, for a hand-compass
reading or a notebook. On a device with no compass it reads
{{< app "Manual entry" >}}, and the screen says
{{< app "No compass on this device — enter the bearing manually above." >}}

Bearings are stored as magnetic; true north is on [the compass tab](#the-compass-tab).

### Taking the range on a map

{{< app "Take on map" >}}, the round map button beside RANGE, does the same
sweep on a map, so you can see whether it crosses your earlier bearings before
you accept it.

{{< shots >}}
{{< shot "take-on-map" "Take on map before a sweep. The two lines with fainter wedges are today's earlier bearings on this tag, drawn out to the edge; the dashed line is where the phone points now, and the large number is its heading." >}}
{{< shot "take-on-map-released" "The same screen after the sweep is let go. The wide wedge is the sweep, the number is what it read, and the three buttons wait for you. Here the sweep crosses both earlier bearings, which is what the screen is for." >}}
{{< /shots >}}

{{< video "take-on-map" "One sweep, at four times real speed: hold the button, turn across the signal, let go, and the reading appears with Cancel, Retake and Confirm. The green cross marks where a finger holds the button. No sound." >}}

It draws today's earlier bearings on the selected tag, from everyone on the
project. Other tags, earlier days, records with no direction, deleted ones, and
bearings from before the tag moved to this animal are left out. With no tag
selected it says {{< app "No tag selected, so no earlier bearings are shown." >}}

Hold {{< app "HOLD TO SWEEP" >}} and turn across the signal; the map ignores
touches while you hold. Let go and the reading appears, for example
_115° ± 15°_. A sweep of 180° or more warns that the middle may be the wrong
way round. Then:

- {{< app "Confirm" >}} puts the bearing in the form and closes the map. _It
  does not save._ {{< app "SAVE OBSERVATION" >}} still does that.
- {{< app "Retake" >}} discards the sweep.
- {{< app "Cancel" >}} (or back) leaves the form as it was.

The button at the bottom right switches {{< app "North up" >}} and
{{< app "Facing up" >}} (the map turns with the phone), and the phone remembers
which. Dragging the map pauses the turning until you tap
{{< app "Back to me" >}}; if the compass is disturbed the map stops turning and
says so. While the map is turned a small north arrow shows; tap it to return
to north up. The {{< app "Terrain" >}} / {{< app "Street" >}} /
{{< app "Satellite" >}} switch is shared with the Map tab. Like RANGE, the
button is hidden on a device with no compass.

## Say how good it was

Three wheels under the bearing, one flick each:

- {{< app "QUALITY" >}}: how much you trust the direction.
  {{< app "✓ Good" >}}, {{< app "Fair" >}}, or {{< app "Bounce?" >}} for one you
  think came off a ridge or a building. Weeks later this tells you which ray to
  doubt.
- {{< app "MODE" >}}: which of the tag's pulse modes you heard. The modes are
  whatever was named when the tag was entered; the line under the wheels spells
  out the one picked, with its rate.
- {{< app "STRENGTH" >}}: how loud, from {{< app "Faint" >}} to
  {{< app "V. strong" >}}. It is about distance, not direction quality: a faint
  signal can give a clean bearing and a strong one can bounce.

_When the tag itself sounds wrong_, for example an irregular pulse, tick
{{< app "Malfunctioning" >}} beside the mode line. {{< app "Bounce?" >}} means
_I do not trust this direction_; {{< app "Malfunctioning" >}} means _I do not
trust this tag_. Several on different days are what would justify replacing it.
The box does not take the bearing out of estimates; that is done on the
[Position tab or in the Log](../estimating-a-position/).

## Where you were

The row above the notes shows the GPS position the record will carry, or that
there is no fix yet. {{< app "Preview/Set" >}} shows it on the map and lets you
place the pin by hand, for example under a canyon wall.

## Notes and Advanced

{{< app "Notes (optional)" >}} is free text. {{< app "Advanced" >}} folds away
the bearing method, antenna type and receiver gain, which most people set once
a season.

## Writing a note

On a {{< app "Note" >}} the text is the record, so the box fills the screen.
It carries only the position and time besides, and saves with
{{< app "SAVE NOTE" >}}.

{{< shot "record-note" "A Note before you start typing. The box takes every pixel left between the position row and the save bar." >}}

Once you type, the box settles to eight lines above the keyboard and the form
scrolls. (No picture: the screenshot tool cannot raise a keyboard.) Tapping
away keeps every word.

## Save it

Tap {{< app "SAVE OBSERVATION" >}}. On a bearing it stays gray until a bearing
is taken, which is why it is gray in the picture above. With no position it
does not guess:
{{< app "No GPS fix yet — use manual pin instead." >}}

The screen keeps your unsaved entry if you leave and come back. A saved record
is on this phone at once; [sync](../sync/) sends it to the team when there is a
connection.

## The compass tab

{{< shot "compass" "The compass tab. The bubble at the top right turns green when the phone is level. The heading here is a fixed 47°, because the simulator that makes these pictures has no compass." >}}

It is for pointing, not recording:
{{< app "To capture and save a bearing, use the Record tab." >}}

- {{< app "LEVEL" >}} turns green when the phone is flat enough. A tilted phone
  reads a wrong heading.
- {{< app "True North" >}} and {{< app "Declination" >}} need a position fix
  and show a dash until one arrives. {{< app "Adjust" >}} overrides the
  declination, for example to match a published value or an older dataset.
  Recorded bearings stay magnetic either way.
- {{< app "⟲ Calibrate (figure-8)" >}}: wave the phone in a figure of eight
  when the heading drifts or the app warns of interference (a truck, a metal
  gate, a radio).

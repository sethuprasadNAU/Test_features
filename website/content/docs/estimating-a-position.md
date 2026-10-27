---
title: "Estimating a position"
description: "Turning a collar's bearings into an estimated location on the Position tab: choosing bearings, reading the ellipse and the cautions, and saving."
weight: 37
---

<!--
Every behavior on this page is read from
lib/features/position_estimation/screens/position_estimation_screen.dart
unless another file is named beside it. The six-hour window is
kTriangulationDefaultWindow and the 50 km range is _defaultRangeMeters, both in
that file. The calculation itself is lib/localization/; see the theory page.
-->

With two or more bearings on one tag from different places, the
{{< app "Position" >}} tab estimates where the animal is, with an ellipse for
the uncertainty. It runs on the phone and needs no cell or wifi coverage.

For the mathematics, see
[how the estimate is calculated](../how-the-estimate-is-calculated/).

{{< shot "position" "The Position tab. Every bearing is listed with its time, direction, uncertainty and quality; unticking one recalculates the estimate." >}}

## Choose the animal

The bar at the top names the animal, its tag and frequency. Tap it, spin to
another, and tap {{< app "Select" >}}. An estimate always uses one tag's
bearings.

## Choose the bearings

The list holds every bearing on that tag from everyone on the project, newest
first: who (initials), when, direction ± uncertainty, strength and quality. A
warning triangle means someone ticked {{< app "Malfunctioning" >}}; it does not
remove the bearing.

- _A ticked bearing is in the estimate._ Untick one, or tap its ray on the map,
  and the estimate recalculates.
- _On arrival_, bearings within six hours and 50 km of the tag's newest one are
  ticked; older or farther ones are listed unticked. {{< app "All" >}} and
  {{< app "None" >}} tick or untick everything.
- _Unticking lasts for this estimate only._ To leave a bearing out of every
  estimate, an owner uses {{< app "Exclude from estimates…" >}} in the Log;
  excluded and superseded bearings do not appear here.
- The sort button orders the list by {{< app "Time" >}},
  {{< app "Member" >}} or {{< app "Distance" >}} (needs a GPS fix). Sorting
  never changes the estimate.

## Read the map

Solid rays are in the estimate, faint rays are left out, and each pale wedge is
that bearing's recorded uncertainty. The dot is the estimate and the shaded
ellipse its uncertainty; your own position is a green dot.

{{< shot "position-legend" "The legend, opened from the button under the layers button. It names the three marks (an included bearing, an excluded bearing, the estimated position) and says that tapping a ray includes or excludes it." >}}

_The ellipse is a 95% confidence region._ A long thin one means the bearings
fix the animal in one direction only, usually because they came from one side;
take the next bearing from across its long axis. With five bearings or fewer
it usually contains the animal less often than 95%, and a caution says so
(below): take more bearings if you can.
Why, and how often, is on [how the estimate is calculated](../how-the-estimate-is-calculated/#how-often-does-the-95-ellipse-contain-the-animal).

_What the ellipse does not catch._ It ignores the ± you recorded (that is only
drawn), and a bad bearing that roughly agrees with the others is not flagged.
In the worked example from the paper the method comes from, one reflected
bearing among seven good ones moved the estimate more than five times farther
from the truth. Untick a doubtful bearing and watch what changes.

_Two bearings give a point with no ellipse_: two lines always cross exactly,
so there is no spread to measure. A caution says so, the Map's card says
{{< app "No error ellipse" >}}, and Past estimates shows _no ellipse_ where
the size would be. Take a third bearing.

## The cautions

A caution button in the panel's top row counts anything worth a second look;
tap it for the list. {{< app "They do not stop you saving the estimate." >}}

- _{{< app "animal may have moved" >}}_: the selected bearings span more than
  six hours (only if you tick older ones yourself).
- {{< app "Bearings near-parallel — try a different angle" >}}.
- {{< app "Poor geometry — try a different observer position" >}}: the ellipse
  is over ten times longer than wide, or reaches more than 5 km out.
- {{< app "All observers are nearly at the same point — no triangulation information" >}}:
  all taken within about a meter of each other.
- {{< app "Some observations have low-accuracy GPS fixes — reported error may understate true error" >}}:
  at least one position was uncertain by more than 20 m, and the ellipse
  assumes positions are exact.
- {{< app "Few bearings — the 95% ellipse usually understates the uncertainty. Add bearings if you can. See “How the estimate is calculated” in the TriTrack guide." >}}:
  the ellipse rests on three, four or five bearings, and
  [that page](../how-the-estimate-is-calculated/#how-often-does-the-95-ellipse-contain-the-animal)
  is the one it names. In TriTrack's simulation
  such ellipses contained the animal 40–70% of the time, not 95%. The same
  line shows under the estimate on the Map and in Past estimates.
- {{< app "No ellipse — two bearings can't measure their own spread. Add a third." >}}
  With more than two bearings this is rare, and reads
  {{< app "No ellipse — these bearings can't measure their own spread." >}}
- {{< app "Solver did not fully converge — treat this estimate as provisional" >}}.
- {{< app "Only one bearing selected — showing the ray only, no estimate" >}}.
- {{< app "Geometry too degenerate to estimate — adjust which observations are included" >}}:
  for example, two exactly parallel bearings.

{{< shot "position-cautions" "The cautions sheet, opened from the amber caution button in the panel's top row. These five bearings carry one caution: with so few, the 95% ellipse usually understates the uncertainty." >}}

## Make room

Drag the handle at the top of the panel up for more list or down for more map.
All the way down closes it to a bar; tap the bar to reopen. A caution keeps a
warning triangle on the bar.

## Save it

{{< app "SAVE POSITION" >}} keeps the location, ellipse, time and the bearings
used, and confirms {{< app "Position saved" >}}. It is gray when there is no
estimate. A viewer sees
{{< app "Viewers cannot save a position estimate — ask an owner to change your role." >}}

The clock button lists the animal's saved estimates, each with its ellipse
size; delete one with the bin, and {{< app "UNDO" >}} brings it back. Saved
estimates also show on the Map tab.

{{< shot "position-past-estimates" "The past-estimates sheet, behind the clock button, listing one saved estimate: when it was saved, the size of its ellipse in meters, and how many bearings went into it. The bin at the end of the row deletes it." >}}

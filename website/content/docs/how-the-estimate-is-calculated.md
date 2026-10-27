---
title: "How the estimate is calculated"
description: "How the Position tab turns bearings into a location and a 95% ellipse, explained in pictures: Lenth's (1981) maximum-likelihood estimator, White and Garrott's (1990) chi-square ellipse, how often that ellipse contains the animal, and what to do about it."
weight: 38
---

<!--
Written by tasks /w-31, /w-36 and /w-37, published by /w-38.

TWO PAGES (/w-37). This one explains the method in pictures and says how far
to trust the ellipse. The full equations, the cautions' thresholds, the check
against Lenth's worked example and where TriTrack differs from the paper are
on docs/the-mathematics-of-the-estimate.md. Publish the two together: each
links to the other. Task 11.338's caution links to this page's
#how-often-does-the-95-ellipse-contain-the-animal; keep that heading's words.
The numbered references are shared: data/theory_references.toml.

Every equation and number here is read from the code, not from the paper
(the file list is on the mathematics page).

THE FIGURES (/w-36) are drawn by website/tools/theory_figures.dart from the
app's own numbers in test/localization/ellipse_coverage_data/ (task 11.336),
and the script refuses to draw if its copy of the method disagrees with them.
Every number quoted beside a figure below comes from those files or from that
script; regenerate with `dart website/tools/theory_figures.dart` and re-read
the captions if the data changes. The coverage percentages are from
coverage_chi_square.csv.

THE SOURCES, read for this page (copies in CLAUDE_DOCS/, not in the repository):
  Lenth (1981); White and Garrott (1990) chapter 4 (pp. 59, 62-63, 68-72) and
  chapter 5's title; the LOAS manual dated 1/1/2005, p. 11 ("Error Ellipses").
-->

The {{< app "Position" >}} tab finds the place that best explains the
bearings you selected and draws an ellipse around it labeled 95%. It uses
Russell Lenth's 1981 method [[1]](#ref-1), the standard one for
radio-telemetry triangulation, and the 95% ellipse that White and Garrott
(1990) [[2]](#ref-2) construct from it. This page explains it in pictures and
says how far to trust the ellipse. _The full equations_, how each caution is
measured, a check against Lenth's own worked example and where TriTrack
differs from the paper are on
[the mathematics of the estimate](../the-mathematics-of-the-estimate/).

## The idea in one paragraph

Each bearing is a line from where you stood toward the animal. Every bearing
has some error, so the lines never all cross at one point. The method asks:
_for which position would this set of bearings be most likely?_ Taking each
error as random, independent and usually small, it finds the position that
makes the observed errors most plausible: a _maximum-likelihood estimate_.
How much the bearings disagree then sets the size of the ellipse.

## What the method assumes

The estimate is only as good as these assumptions.

1. _The animal did not move_ while the bearings were taken. The app warns
   when they span more than six hours.
2. _Each bearing points at the animal, plus a random error_, with no
   systematic lean. A bounce off a ridge breaks this, and nothing in the
   calculation can tell
   ([an example](../the-mathematics-of-the-estimate/#validation-against-lenths-own-example)).
3. _Every bearing's error has the same spread._ So the plus-or-minus, quality
   and signal strength you record are drawn on the map and listed, but no
   bearing is trusted more than another because of them.
4. _Where you stood is known exactly._ The app warns when the phone's position
   was uncertain by more than 20 m, because that error is not in the ellipse.
5. _The study area is small enough to treat as flat_, as Lenth
   [[1]](#ref-1) assumes. Over a few kilometers the error is far below a meter.

## The method in pictures

Seven steps, each in words, a picture, its equation and what it means in the
field. Pictures and equations share colors: a _bearing_ is blue, the
_estimate_ red, the _spread of the bearings_ (κ, kappa) magenta, the
_ellipse_ green, and gray shows _how likely_ each place is; every picture
also names them in words. The examples are simulated, so the animal's true
position is known (a star); the app never knows it.

### 1. One bearing is a range of likely directions, not a line

When you take a bearing of 270°, the animal is probably close to 270°, less
probably at 260°, and very unlikely at 230°. So a bearing is better pictured
as a fan of directions, darkest along the bearing and fading to either side.
It says which way, not how far. How wide the fan is depends on how good your
bearings are, and the method measures it with one number, κ: the larger κ, the
narrower the fan.

{{< fig name="bearing-fan" alt="Three shaded wedges drawn upward from a station triangle, each darkest along its bearing line and fading to either side and at its far end. With a scatter of 5 degrees the wedge is a thin sliver, labeled kappa 132; at 10 degrees it is wider, kappa 33.3; at 15 degrees wider still, kappa 15.1. Dotted guide lines mark 10 and 20 degrees either side. Under each wedge is its von Mises curve, with the error from minus 40 to plus 40 degrees across and the same dotted guides: tall and narrow for kappa 132, lower and wider for 33.3, lowest and widest for 15.1." caption="The same bearing at three qualities. Each fan's shading follows the curve beneath it: how likely each error is, from −40° to +40°. A bearing usually within about 5° of the truth is a narrow fan with a tall, narrow curve (κ = 132); one that wanders by about 15° is a wide fan with a low, wide curve (κ = 15). The curves share one vertical scale and each encloses the same area, a total chance of one." >}}

The curve is the von Mises distribution, the circular equivalent of a
bell curve. The chance of an error of $\varepsilon$ between the bearing
$\textcolor{#306afc}{\theta}$ and the true direction $\mu$ is

$$
f(\varepsilon) = \frac{e^{\textcolor{#c13b9e}{\kappa} \cos \varepsilon}}{2\pi I_0(\textcolor{#c13b9e}{\kappa})},
\qquad \varepsilon = \textcolor{#306afc}{\theta} - \mu ,
$$

where $I_0$ only makes the total chance add up to one. White and Garrott
draw the same fans around three towers (1990, Figs. 4.11 and 4.12) [[2]](#ref-2).

_In the field:_ κ is your bearing accuracy written another way. About ±5° is
κ near 130, ±10° near 33, ±15° near 15.

### 2. Each bearing makes a ridge; together they make a hill

Spread each bearing's fan out over the map and it becomes a ridge of likely
places along its line. Multiply the ridges of all your bearings together and
only the places that every bearing finds likely stay high: one hill. _The top
of the hill is the estimate._

{{< anim name="hill-build" alt="A map with three stations to the east and their three blue bearing lines. Frame by frame, gray shading appears: first a wedge along bearing 1, then a smaller patch where bearings 1 and 2 cross, then one rounded hill where all three cross. A red dot marks the top of the hill, the estimate; a star southwest of it is the animal." caption="Three bearings, each in error by 6° to 17°. Each one alone allows a long strip of places; together they leave one hill, and its top (red) is the estimate. Drawn with the bearings' true scatter, 15°." >}}

Multiplying the chances and taking logarithms gives the
_log-likelihood_, the hill's height:

$$
\textcolor{#5c5c60}{\ell(x, y)} = \textcolor{#c13b9e}{\kappa} \sum_{i=1}^{n}
  \cos\bigl(\textcolor{#306afc}{\theta_i} - \mu_i(x, y)\bigr)
  \;-\; n \ln\bigl(2\pi I_0(\textcolor{#c13b9e}{\kappa})\bigr),
$$

where $\mu_i(x, y)$ is the direction from where bearing $i$ was taken to the
place $(x, y)$. Only the sum depends on the place, and κ only stretches it,
so _the top is in the same place whatever κ is_.

_In the field:_ a bearing that disagrees with the others pulls the top toward
its own ridge. That is why unticking a doubtful bearing can move the
estimate a long way.

### 3. Finding the top of the hill

There is no formula for the top, so the app climbs to it. It starts where the
bearing lines come closest to crossing, then takes steps by Lenth's rule
[[1]](#ref-1) until a step moves less than a tenth of a millimeter. A far
bearing weighs less than a near one: the same angle misses by more meters at
1 km than at 100 m.

{{< anim name="solver" alt="A close-up of a broad gray hill with contour lines; four of the ten faint blue bearing lines cross it. A hollow red circle on the right is the start. A long red arrow, step 1, crosses the top and lands on the far side; step 2 comes back; steps 3 to 5 are short; a red dot marks the top, reached after 17 steps." caption="Ten bearings with 15° of scatter, the app's own search. This is a close-up of the hilltop, so only a few of the ten bearing lines cross it; the rest pass outside the picture. The first step overshoots the top but still lands higher than it started, so it is kept; the next steps settle in. Steps 6 to 17 are too small to see." >}}

TriTrack adds one safeguard to Lenth's rule [[1]](#ref-1): _a step that
would land lower on the hill is cut in half_, and again if need be. About 3%
of simulated fixes need it.

{{< fig name="solver-shortened" alt="A narrow gray hill running north to south with contour lines. From a hollow red circle at the bottom, a dashed gray arrow runs past the top to a point on the far slope labeled whole step: lower. A solid red arrow covers half that distance and is labeled half a step: higher. A red dot below it is the top, the estimate." caption="Three real bearings (5° scatter) where the first whole step would have gone past the top and down the other side. The app took half of it instead, then climbed on to the top." >}}

How does the search know it has reached the top? At the top the hill is
flat: its slope is zero both east-west and north-south. Those slopes are the
derivatives of the hill's height $\textcolor{#5c5c60}{\ell}$ with respect to
$x$ and $y$, so the search stops where both derivatives are zero. Written out
(with the common factor κ dropped), the two conditions are

$$
\sum_{i=1}^{n} \frac{\sin\mu_i}{d_i}\,\sin(\textcolor{#306afc}{\theta_i} - \mu_i) = 0,
\qquad
\sum_{i=1}^{n} \frac{\cos\mu_i}{d_i}\,\sin(\textcolor{#306afc}{\theta_i} - \mu_i) = 0 ,
$$

with $d_i$ the distance from where bearing $i$ was taken.

_In the field:_ you never see this, but if the climb cannot settle the app
says so with
{{< app "Solver did not fully converge — treat this estimate as provisional" >}}.

### 4. How spread out the bearings are: κ from the residuals

The app does not know your bearing accuracy; it works it out from the
bearings. Once the top is found, it measures each bearing's _residual_: the
angle between the bearing and the line from where it was taken to the
estimate. (It is the same word as in a regression: what is left once the
fitted value is taken away.) Small residuals mean the bearings agree with each
other, all passing close to one point: a large κ and a small ellipse.

_The catch_, and the main reason the ellipse can mislead. The residuals are
measured from the estimate, and the estimate is the point that makes them
smallest. The bearings' true errors are measured from the animal, which is
somewhere else. So, taken together, the residuals are always smaller than the
true errors, in every fix; single residuals can be larger, as in the figure
below. How much smaller depends on how many bearings there are.

Two bearings show why. Any two lines that are not parallel cross somewhere, so
the estimate sits exactly on both, and both residuals are zero however far off
each bearing was. Two bearings cannot show their own error at all, which is
why the app draws no ellipse for them. A third bearing will usually miss that
crossing, and only that miss shows. The estimate still uses all three
bearings, but by choosing where it sits, east-west and north-south, it can
always cancel as much disagreement as two bearings carry. So three bearings
leave about one bearing's worth of disagreement to measure the spread from,
and ten leave about eight, which is why ten give residuals close to the true
errors. White and Garrott make the same point for their goodness-of-fit test:
2 degrees of freedom are lost because the location is estimated from the same
bearings (1990, p. 69) [[2]](#ref-2).

{{< fig name="residual-angles" alt="A dot chart of angles from minus 40 to plus 40 degrees. For 3 bearings the true errors are about 6, 17 and 6 degrees but the residuals are only about minus 4, plus 3 and plus 4; the header says kappa from the residuals is 228, as if the scatter were 3.8 degrees, though the true scatter is 15. For 10 bearings the residuals are spread about as widely as the true errors, some larger and some smaller, and kappa from the residuals is 14.2, as if 15.5 degrees." caption="The same 15° scatter twice. With 3 bearings the residuals (magenta) are far smaller than the true errors (open circles), so κ comes out 228 instead of 15. With 10 bearings some residuals are larger and some smaller, and κ comes out 14.2." >}}

The residual of bearing $i$ is
$\textcolor{#c13b9e}{r_i} = \textcolor{#306afc}{\theta_i} - \mu_i(\textcolor{#da210c}{\hat x}, \textcolor{#da210c}{\hat y})$,
where $(\textcolor{#da210c}{\hat x}, \textcolor{#da210c}{\hat y})$ is the
estimate (a hat always means a value estimated from the bearings). The app
averages their cosines. The cosine is how circular statistics measures how
close an angle is to zero: 1 at 0°, 0.996 at 5°, 0.966 at 15°, 0 at 90°, and
the same for +10° as for −10° or 350°, which a plain average of angles would
get wrong. For small angles $1 - \cos r$ is about $r^2/2$, so it works like a
squared error. It is also the quantity in the von Mises formula of step 1,
which is why the likelihood uses it.

$$
\textcolor{#c13b9e}{\bar C} = \frac{1}{n}\sum_{i=1}^{n} \cos \textcolor{#c13b9e}{r_i},
\qquad A(\textcolor{#c13b9e}{\hat\kappa}) = \textcolor{#c13b9e}{\bar C},
$$

Each κ comes with the average cosine its bearings would show in the long
run: about 0.996 for κ = 132 (5° of scatter), 0.985 for κ = 33 and 0.966 for
κ = 15. That expected value is $A(\kappa)$. The app takes the κ whose
expected average cosine equals the one it measured, $\textcolor{#c13b9e}{\bar C}$:
the κ most likely to have produced these residuals (Lenth 1981, section 2)
[[1]](#ref-1). The formula it uses is on the mathematics page.

_In the field:_ when three bearings cross in a small triangle, that does not
show your bearings are accurate. The estimate can always sit right on two of
the lines, so a small triangle can come from poor bearings, as it did in the
figure above. Only more bearings can show how good they are.

### 5. From the hill's shape to the ellipse

A steep, narrow hilltop gives a small ellipse; a broad one a large ellipse.
The app fits an oval to the hilltop (the covariance
$\textcolor{#1d7852}{Q}$, Lenth's Eqs. 2.7 to 2.9 [[1]](#ref-1)). Drawn at one
standard deviation, that oval is the inner, dashed ellipse in the second
figure below. The app then enlarges it by 2.45 on each axis to make the 95%
ellipse. That is White and Garrott's construction (1990, pp. 62–63,
Eq. 4.6) [[2]](#ref-2).

_Why 2.45, and not the 1.96 of a bell curve?_ In one direction, 95% of a
normal distribution lies within 1.96 standard deviations of its center. A
position has two directions, east-west and north-south, and the animal has to
be close enough in both at once. Taking the estimate's errors as roughly
normal, as the method does, the squared distance from the center, counted in
standard deviations and added over the two directions, follows a chi-square
distribution with two degrees of freedom. 95% of that distribution lies below
5.991, so the 95% ellipse reaches $\sqrt{5.991} = 2.45$ standard deviations
in every direction. The one-standard-deviation oval holds only 39%.

{{< fig name="chi-square-scale" alt="Two panels. Left, one direction: a bell curve, with the area within plus or minus 1 standard deviation shaded darker and labeled 68 percent, and dashed lines there; solid lines at plus and minus 1.96 mark the edge of a lighter shaded 95 percent. Right, two directions: a round gray hill seen from above, with a small dashed green circle at 1 standard deviation labeled 39 percent and a large solid green circle at 2.45 standard deviations, 95 percent." caption="Left: in one direction, ±1 standard deviation holds 68% of a bell curve and ±1.96 holds 95%. Right: in two directions at once, the one-standard-deviation circle holds only 39%, and holding 95% takes 2.45 standard deviations. An ellipse is this circle stretched to the hill's shape." >}}

{{< fig name="hill-to-ellipse" alt="Top panel: a sharp gray hill with a red estimate at its top, a dashed green inner ellipse, and a solid green 95 percent ellipse with its semi-axes labeled a equals 230 meters and b equals 126 meters; a dotted gray outline, the hill's own 95 percent outline where it falls to 5 percent of its top, runs close to the green ellipse but bulges past it at one end. Bottom panel, at a larger scale: the same bearings with the true kappa give a wide hill and a 95 percent ellipse about four times larger that contains the star marking the animal, while the app's small ellipse, dashed, does not." caption="Top: the three bearings from step 4. The gray shading is the hill itself, the likelihood from step 2: how well each place fits the bearings. The dotted line is the hill's own 95% outline, where it falls to 5% of its top; that is exactly where the 95% ellipse would lie if the hill were a perfect oval. The green ellipses are the app's oval fitted to the hilltop. A hill from three bearings is not a perfect oval: it is lopsided toward one end, and the oval cannot be, so the two differ a little. Bottom: the same bearings with their true scatter, κ = 15 rather than 228. The hill is wider, the 95% ellipse about 3.9 times larger, and it contains the animal." >}}

The ellipse's semi-axes $\textcolor{#1d7852}{a}$ and $\textcolor{#1d7852}{b}$
(half its length and half its width) come from $\textcolor{#1d7852}{Q}$
(White and Garrott 1990, pp. 62–63 [[2]](#ref-2)):

$$
\textcolor{#1d7852}{Q} = \bigl(\textcolor{#c13b9e}{\hat\kappa}\,\hat I\bigr)^{-1},
\qquad
\textcolor{#1d7852}{a} = \sqrt{\textcolor{#1d7852}{k}\,\lambda_1}, \quad
\textcolor{#1d7852}{b} = \sqrt{\textcolor{#1d7852}{k}\,\lambda_2}, \quad
\textcolor{#1d7852}{k} = 5.991 ,
$$

where $\hat I$ is what the bearings tell you about the position (next step),
$\lambda_1$ and $\lambda_2$ (the eigenvalues of $\textcolor{#1d7852}{Q}$) are
the oval's squared semi-axes at one standard deviation, and $\textcolor{#1d7852}{k}$ is chi-square's 95% point
($\sqrt{5.991} = 2.45$).

_In the field:_ the ellipse is only as large as κ says. _If κ is too large,
as it usually is with three to five bearings, the ellipse is too small._

### 6. Geometry matters

A bearing pins the animal down _across_ its line and hardly at all _along_
it. Bearings from well-spread directions pin it down every way; bearings all
from one side leave it free along their common direction.

{{< fig name="geometry" alt="Two maps at the same scale with the same three bearing errors. Top: stations to the north-east, south-east and west of the animal; the 95 percent ellipse is nearly round, semi-axes 384 by 315 meters. Bottom: three stations close together to the east; the bearing lines are nearly parallel and the ellipse is long and thin east to west, 1,331 by 268 meters." caption="Same errors (+5°, −4°, +3°), same spread, different stations. From around the animal the ellipse is nearly round; from one side it is about five times longer than wide, along the bearings. Both are drawn with the spread known (10°), so only the geometry differs." >}}

The ellipse's shape comes from how sharply the hill curves at its top in each
direction, which statisticians call the _information_, $\hat I$ (Lenth's
Eqs. 2.8 and 2.9 [[1]](#ref-1)); step 5's covariance is its inverse, scaled by
κ. Each bearing adds to it: a lot _across_ its own line, because a step
sideways changes the angle that bearing would read, and nothing _along_ it,
because a step toward or away from where it was taken does not. It adds less
the farther away the animal is, because a sideways step of so many meters
changes the angle less at a distance. Approximately:

$$
\hat I \approx \sum_{i=1}^{n} \frac{1}{d_i^{2}}
\begin{bmatrix} \sin^2\mu_i & -\sin\mu_i\cos\mu_i \\ -\sin\mu_i\cos\mu_i & \cos^2\mu_i \end{bmatrix}.
$$

Bearings that all share one direction $\mu$ add up to almost nothing in the
other.

_In the field:_ take the next bearing from across the ellipse's long axis. The
app cautions
{{< app "Poor geometry — try a different observer position" >}} when the
ellipse is more than ten times longer than wide.

### 7. Does the 95% ellipse contain the animal?

A 95% ellipse promises that 95 of every 100 contain the animal. A simulation
can check, because it knows where the animal is. Below are 24 simulated fixes
with three bearings and 24 with ten, all with 10° of scatter, each computed
exactly as the app computes it. They are the first fixes of two of the
simulations described in the next section.

{{< anim name="coverage-build" alt="Two grids of 24 small squares, filled in one at a time. Each square shows one simulated fix: a green 95 percent ellipse, a red estimate and a star for the animal, with a tick if the ellipse contains the star (solid ellipse) or a cross if it does not (dashed ellipse). A running count beside each grid ends at 11 of 24 for 3 bearings and 22 of 24 for 10 bearings." caption="Fixes with a scatter of 10°. With 3 bearings fewer than half the ellipses contain the animal (11 of these 24; 43% of 2,000); with 10, most do (22 of 24; 83% of 2,000). Neither reaches 95%." >}}

To decide whether an ellipse contains the animal, the simulation measures how
far the animal's true position $(x, y)$ is from the estimate in standard
deviations, allowing for the ellipse's shape and direction. Squared, that
distance is the expression on the left below. The ellipse contains the animal
when it is at most 5.991, the chi-square 95% point from step 5:

$$
\begin{bmatrix} x - \textcolor{#da210c}{\hat x} & y - \textcolor{#da210c}{\hat y} \end{bmatrix}
\textcolor{#1d7852}{Q}^{-1}
\begin{bmatrix} x - \textcolor{#da210c}{\hat x} \\ y - \textcolor{#da210c}{\hat y} \end{bmatrix}
\le \textcolor{#1d7852}{k} = 5.991 .
$$

## How often does the 95% ellipse contain the animal?

TriTrack uses the standard method: Lenth's (1981) maximum-likelihood estimate
[[1]](#ref-1) with White and Garrott's (1990) chi-square 95% ellipse
[[2]](#ref-2). That method has a known limitation, and this section measures
it so you can allow for it. Its 95% factor assumes κ is known in advance.
When κ is estimated from the same few bearings, as TriTrack does, the ellipse
comes out too small; the LOAS manual reports the same shortfall
[[3]](#ref-3).

_So the ellipse contains the animal less often than 95%, and much less with
few bearings._ What to do about it:

- _Take more bearings._ In TriTrack's simulation the 95% ellipse contained
  the animal about 40% of the time with three bearings, about 70% with five,
  and about 85% with ten.
- _With five or fewer, the app says so._ Every estimate with an ellipse made
  from three, four or five bearings carries the caution
  {{< app "Few bearings — the 95% ellipse usually understates the uncertainty. Add bearings if you can." >}}
- _Read a three- to five-bearing ellipse as a minimum,_ not a boundary: the
  animal is often outside it.
- _Spread your stations around the animal_ (step 6), and _untick a bearing
  you doubt_ and watch what changes: no ellipse can see a reflected signal.

_Why it happens._ The 95% factor (step 5) is exact only when κ is known.
White and Garrott take κ from a bearing standard deviation measured
beforehand by system testing (1990, Eq. 4.4, p. 59) [[2]](#ref-2). TriTrack
estimates κ from the same bearings, and with few of them it comes out too
large (step 4), so the ellipse is too small.

_Three sources, three measurements:_

1. _The LOAS manual_ (Ecological Software Solutions; LOAS implements Lenth's
   estimators): ellipses scaled by chi-square "will only represent a true
   accuracy of about 45-85% when the anticipated accuracy was set to 95%"
   (manual dated 1/1/2005, p. 11) [[3]](#ref-3).
2. _White and Garrott's field test_ (1990, Table 4.1, p. 70 [[2]](#ref-2),
   from Garrott and others, 1986 [[4]](#ref-4)): three-tower fixes on
   transmitters at surveyed spots, where reflected signals were common.
   Maximum-likelihood ellipses under 0.6 ha contained the true location 41% of
   the time. Their κ was not estimated from each fix's bearings; it was
   measured beforehand by system testing, so the few-bearings problem of
   step 4 does not explain this shortfall. The likely cause is bounce:
   reflected signals that make some bearings wrong by far more than κ allows.
   In the field both problems can happen at once, and their effects add up.
3. _TriTrack's own simulation_, below, of the app's own calculation. For each
   number of bearings (3 to 10) and each scatter (5°, 10° or 15°) it made
   2,000 fixes. In each fix the animal is at a known spot, and each station is
   placed at random on one side of it (anywhere in a half circle), 500 m to
   2 km away. Each bearing is the true direction plus a random error drawn
   from a von Mises distribution (step 1). The _scatter_ is that
   distribution's circular standard deviation: about two bearings in three
   fall within ±scatter of the truth, as with an ordinary standard deviation.
   There is no bounce. The app's calculation then makes the estimate and its
   95% ellipse, and the simulation counts how often the ellipse contains the
   animal.

{{< fig name="coverage-by-bearings" alt="A line chart. Horizontal axis: bearings in the estimate, 3 to 10. Vertical axis: percent of the app's 95 percent ellipses containing the animal, 30 to 100. Three green lines, one per bearing scatter of 5, 10 and 15 degrees, rise together from about 40 percent at 3 bearings to about 70 at 5, 75 at 6, 80 at 8 and 83 to 86 at 10. A dashed line marks 95 percent. A gray band near the top, 87 to 95 percent, shows the same ellipses with the true kappa. The region of 5 bearings or fewer is shaded and labeled the app cautions." caption="The app's ellipse falls short of 95% at every count, most with few bearings. With the true κ (gray band) the same ellipses come close, so the shortfall is almost all from estimating κ." >}}

Contained the animal, by how much the bearings scatter:

| Bearings | 5° | 10° | 15° | True κ |
| --- | --- | --- | --- | --- |
| 3 | 42% | 43% | 40% | 87–94% |
| 4 | 60% | 59% | 55% | 88–94% |
| 5 | 70% | 68% | 68% | 90–94% |
| 6 | 76% | 75% | 72% | 90–95% |
| 8 | 82% | 80% | 80% | 91–94% |
| 10 | 86% | 83% | 83% | 92–95% |

_True κ_ is the same fixes with the ellipse drawn from the κ the simulation
actually used, instead of the κ estimated from the bearings. The app cannot do
this, since it never knows the true κ; the column shows how much of the
shortfall comes from estimating κ. It falls a little short too: the factor
also assumes the hilltop is an exact oval, which it is only roughly (step 5). Fixes with no
ellipse (at most 142 of 2,000, three bearings at 15°) are left out.

_Two worked examples_, as the app computed them:

{{< fig name="worked-examples" alt="Two maps. Top: three stations to the east, three blue bearing lines crossing; the red estimate sits in a small dashed green ellipse, and the star marking the animal is about 360 meters to the southwest, outside it. Bottom: five stations to the north and east; the solid green ellipse is long and narrow, running north-north-east, and contains both the estimate and the animal." caption="Top: 3 bearings, 15° scatter, the example from steps 2 to 5. The estimate is 360 m from the animal and the 95% ellipse (semi-axes 230 × 126 m) misses it, as it does for 60% of such fixes. Bottom: 5 bearings, 15° scatter. The ellipse contains the animal, as it does for 68% of such fixes." >}}

## What TriTrack does not do (yet)

Published methods that would make the ellipse more trustworthy, recorded for
a later version. _Your export already holds what they need_: every bearing,
where it was taken, and any truth points.

- _System testing._ Bearings toward transmitters at known spots measure your
  system's bearing standard deviation, and so one κ for every fix (White and
  Garrott 1990, chapter 5, and Eq. 4.4, p. 59) [[2]](#ref-2). With κ known the
  chi-square ellipse is the right size, and a compass bias shows up, which no
  single fix can reveal. LOAS accepts such a standard deviation (manual,
  p. 11) [[3]](#ref-3).
- _A goodness-of-fit test for bounce:_ with a known standard deviation, a
  fix's squared residuals against chi-square on $n - 2$ degrees of
  freedom flag bearings that disagree more than the system allows (White and
  Garrott 1990, pp. 68–69) [[2]](#ref-2).
- _A maximum ellipse size_ beyond which an estimate is not used: White and
  Garrott chose 0.6 ha for their system, and say each system needs its own
  test (1990, p. 72) [[2]](#ref-2).
- _The Andrews robust estimator_ (Lenth 1981, section 4) [[1]](#ref-1), which
  gives a stray bearing little weight. In White and Garrott's bounce-prone
  test its ellipses under 0.6 ha contained the true location 78% of the time
  against 41% for maximum likelihood, though it gave no estimate for 154 of
  400 locations (1990, pp. 70–71) [[2]](#ref-2).
- _F-based ellipses:_ LOAS's _F_ and _Adjusted F_ scales, "usually providing
  a true accuracy of greater than 90%" (manual, p. 11) [[3]](#ref-3). The
  manual gives no formula, so TriTrack cannot cite one yet.

## For a methods section

A sentence you can adapt:

> Animal locations were estimated from radio-telemetry bearings, corrected to
> true north, using the maximum-likelihood estimator of Lenth (1981) as
> implemented in TriTrack, which assumes independent von Mises bearing errors
> with a common concentration parameter estimated from each location's bearing
> residuals. Uncertainty is reported as 95% confidence ellipses from the
> estimated covariance and the chi-square distribution with two degrees of
> freedom (White and Garrott 1990).

Add the TriTrack version, how many bearings went into each location, and how
you chose which to include. Because κ is estimated from each location's own
bearings, say that these ellipses contain the true location less often than
95% when few bearings are used
([above](#how-often-does-the-95-ellipse-contain-the-animal)).

## References

Shared with [the mathematics of the estimate](../the-mathematics-of-the-estimate/),
and numbered in the order each source is first cited, reading this page first.

{{< theory-references >}}

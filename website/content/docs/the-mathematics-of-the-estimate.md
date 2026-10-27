---
title: "The mathematics of the estimate"
description: "The full equations behind the Position tab's estimate and 95% ellipse: the projection, Lenth's (1981) likelihood and iteration, κ by Fisher's approximation, the covariance and the ellipse's axes, what each caution measures, a check against Lenth's own worked example, and where TriTrack differs from the paper."
weight: 39
---

<!--
Split from docs/how-the-estimate-is-calculated.md (task /w-37), which explains
the same method in pictures; published with it by /w-38. Each links to the other.

Every equation and number here is read from the code, not from the paper:
  lib/localization/lenth_mle.dart            the solver, its thresholds (LenthConfig)
  lib/localization/localization_geographic.dart  the meter-scale settings the app uses
  lib/localization/coordinate_projection.dart    the flat-earth projection
  lib/localization/angles.dart               compass <-> math angles, wrapping
  lib/localization/bearing_intersections.dart    pairwise crossings (not on any screen)
  lib/localization/few_bearings_caution.dart  the few-bearings caution (five or fewer)
  lib/features/position_estimation/screens/position_estimation_screen.dart
                                             which bearings are fed in, the cautions,
                                             the six-hour window, what is saved
The validation numbers were computed by running LenthSolver.solve on exactly
the inputs test/localization/lenth_mle_test.dart uses, on 2026-10-01. The
published column is what that test file records from Lenth's Tables 1 and 2.

The numbered references are shared with the first page:
data/theory_references.toml. Fisher (1993) is cited only for the
approximation the code uses.
-->

This page is the full mathematics behind
[how the estimate is calculated](../how-the-estimate-is-calculated/), which
explains the same method in pictures and says how often the 95% ellipse
contains the animal. Start there if you have not read it. The colors are the
same on both pages: a bearing is blue, the estimate red, the spread of the
bearings κ magenta, the ellipse green and the likelihood gray. So are the
reference numbers.

## Coordinates and angles

The calculation works on a flat map in meters. TriTrack takes the average
latitude and longitude of the places the selected bearings were taken from as
the origin, and converts each place to meters east and north of it:

$$
x_i = R\,(\lambda_i - \lambda_0)\cos\varphi_0, \qquad
y_i = R\,(\varphi_i - \varphi_0)
$$

where $(\varphi_i, \lambda_i)$ is the latitude and longitude, in radians, of the
place bearing $i$ was taken from; $(\varphi_0, \lambda_0)$ is the origin; and
$R = 6\,371\,008.8$ m is the earth's mean radius. The finished estimate is
converted back to latitude and longitude the same way.

Bearings are stored as compass directions from true north, already corrected
for magnetic declination when they were recorded. The mathematics is simpler
with angles measured counterclockwise from east, so each bearing $\beta_i$ (in
degrees) becomes

$$
\textcolor{#306afc}{\theta_i} = 90^\circ - \beta_i .
$$

The symbols used from here on:

- $n$ is the number of selected bearings, numbered $i = 1, \dots, n$.
- $(x_i, y_i)$ is where bearing $i$ was taken, and $\textcolor{#306afc}{\theta_i}$ is its direction.
- $(x, y)$ is a candidate position for the animal, and
  $(\textcolor{#da210c}{\hat x}, \textcolor{#da210c}{\hat y})$ is the
  estimate. A hat always means an estimated value.
- $\mu_i(x, y)$ is the direction from where bearing $i$ was taken to the point
  $(x, y)$, and $d_i$ is the distance between them:

$$
\mu_i(x, y) = \operatorname{atan2}(y - y_i,\; x - x_i), \qquad
d_i = \sqrt{(x - x_i)^2 + (y - y_i)^2}.
$$

## The model and its likelihood

In words: the direction you read is the true direction to the animal plus an
error. In symbols,

$$
\textcolor{#306afc}{\theta_i} = \mu_i(x, y) + \varepsilon_i ,
$$

where the errors $\varepsilon_i$ are independent and follow a von Mises
distribution centered on zero:

$$
f(\varepsilon) = \frac{e^{\textcolor{#c13b9e}{\kappa} \cos \varepsilon}}{2\pi I_0(\textcolor{#c13b9e}{\kappa})} .
$$

Here $\textcolor{#c13b9e}{\kappa} \ge 0$ is the _concentration_: the larger it
is, the more tightly bearings cluster around the true direction. It plays the
part of one over the variance. $I_0$ is a modified Bessel function, there only
to make the curve integrate to one.

Multiplying the densities of all $n$ bearings and taking the logarithm gives
the log-likelihood:

$$
\textcolor{#5c5c60}{\ell(x, y, \kappa)} = \textcolor{#c13b9e}{\kappa} \sum_{i=1}^{n} \cos\bigl(\textcolor{#306afc}{\theta_i} - \mu_i(x, y)\bigr)
  \;-\; n \ln\bigl(2\pi I_0(\textcolor{#c13b9e}{\kappa})\bigr).
$$

Only the first term depends on the position, and $\textcolor{#c13b9e}{\kappa}$
only scales it. So the best position is the one that makes
$\textcolor{#5c5c60}{\sum \cos(\theta_i - \mu_i)}$ as large as possible: the
point the bearings, taken together, point at most nearly. That is true
whatever $\textcolor{#c13b9e}{\kappa}$ turns out to be, which is why the
position can be found first and $\textcolor{#c13b9e}{\kappa}$ afterward.

## Finding the position

There is no formula that gives the best position directly, so it is found by
repeated improvement. In words: start from the point that best fits the
bearing lines, then refit, giving each bearing a weight that depends on how
far it is from the current estimate, and repeat until the answer stops
changing. A far bearing gets less weight because the same angular error misses
by more meters at a kilometer than at a hundred meters.

At the best position, the slope of the log-likelihood is zero in both
directions:

$$
\sum_{i=1}^{n} \frac{\sin\mu_i}{d_i}\,\sin(\textcolor{#306afc}{\theta_i} - \mu_i) = 0,
\qquad
\sum_{i=1}^{n} \frac{\cos\mu_i}{d_i}\,\sin(\textcolor{#306afc}{\theta_i} - \mu_i) = 0 .
$$

Lenth's trick (his Eq. 2.6 [[1]](#ref-1)) is to write these so they are straight-line
equations in $x$ and $y$ once some terms are held fixed. With

$$
s_i = \sin\textcolor{#306afc}{\theta_i}, \quad c_i = \cos\textcolor{#306afc}{\theta_i}, \quad z_i = s_i x_i - c_i y_i,
$$

and, evaluated at the current estimate $(\textcolor{#da210c}{\hat x}, \textcolor{#da210c}{\hat y})$,

$$
s_i^{*} = \frac{\textcolor{#da210c}{\hat y} - y_i}{\hat d_i^{\,3}}, \qquad
c_i^{*} = \frac{\textcolor{#da210c}{\hat x} - x_i}{\hat d_i^{\,3}},
$$

the next estimate is the solution of

$$
\begin{bmatrix}
  \sum s_i^{*} s_i & -\sum s_i^{*} c_i \\[2pt]
  \sum c_i^{*} s_i & -\sum c_i^{*} c_i
\end{bmatrix}
\begin{bmatrix} x \\ y \end{bmatrix} =
\begin{bmatrix} \sum s_i^{*} z_i \\[2pt] \sum c_i^{*} z_i \end{bmatrix},
$$

with every sum running over $i = 1, \dots, n$. (The quantity
$s_i x - c_i y - z_i$ is the perpendicular distance from $(x, y)$ to the line of
bearing $i$, which is where the straight lines come from.)

_The starting point_ is the same system with every $s_i^{*}$ replaced by $s_i$
and every $c_i^{*}$ by $c_i$: the point that minimizes the sum of squared
perpendicular distances to the bearing lines.

_A step that would make the fit worse is shortened._ This is TriTrack's
addition to Lenth's plain iteration ([step 3](../how-the-estimate-is-calculated/#3-finding-the-top-of-the-hill)). If the new estimate makes
$\textcolor{#5c5c60}{\sum \cos(\theta_i - \mu_i)}$ smaller than at the current
one, the app takes half the step instead, halving up to 30 times. Lenth's own
example never needs it, so its answer and step count are unchanged.

_When it stops._ TriTrack repeats the step until a whole step moves both
coordinates by less than 0.1 mm, or until 200 steps have been taken, or until
no part of a step improves the fit. In the last two cases the estimate is
shown with the caution
{{< app "Solver did not fully converge — treat this estimate as provisional" >}}.
If the system of equations cannot be solved at any step (for example, exactly
parallel bearings), no estimate is made at all. The stopping rule is
TriTrack's own.

## How spread out the bearings are

In words: once the position is found, each bearing's _residual_
([step 4](../how-the-estimate-is-calculated/#4-how-spread-out-the-bearings-are-κ-from-the-residuals))
is how far, in angle, it misses the estimate. The closer
the residuals are to zero, the larger the concentration
$\textcolor{#c13b9e}{\hat\kappa}$, and the smaller the ellipse.

The residual of bearing $i$ is
$\textcolor{#c13b9e}{r_i} = \textcolor{#306afc}{\theta_i} - \mu_i(\textcolor{#da210c}{\hat x}, \textcolor{#da210c}{\hat y})$,
taken the short way round the circle, so it lies between $-180^\circ$ and
$180^\circ$. Their average cosine is

$$
\textcolor{#c13b9e}{\bar C} = \frac{1}{n}\sum_{i=1}^{n} \cos \textcolor{#c13b9e}{r_i} ,
$$

which is 1 when every bearing passes exactly through the estimate and falls as
they spread. The cosine is the circular measure of closeness to zero: for
small angles $1 - \cos r \approx r^2/2$, so it acts as a squared error, and it
is the quantity in the von Mises density. $A(\kappa)$ below is the average
cosine that bearings with concentration κ show in the long run (the von Mises
distribution's mean resultant length). The maximum-likelihood
$\textcolor{#c13b9e}{\hat\kappa}$ is the κ whose $A(\kappa)$ equals the
measured $\textcolor{#c13b9e}{\bar C}$ (Lenth 1981, section 2) [[1]](#ref-1):

$$
A(\textcolor{#c13b9e}{\hat\kappa}) = \textcolor{#c13b9e}{\bar C}, \qquad A(\kappa) = \frac{I_1(\kappa)}{I_0(\kappa)} .
$$

_Where TriTrack departs from the paper._ This equation has no exact solution
in closed form. Lenth gives an approximation (his Eq. 2.10); TriTrack instead
uses the standard approximation from Fisher (1993) [[5]](#ref-5):

$$
\textcolor{#c13b9e}{\hat\kappa} \approx
\begin{cases}
  2\bar C + \bar C^{3} + \tfrac{5}{6}\bar C^{5}, & \bar C < 0.53,\\[4pt]
  -0.4 + 1.39\,\bar C + \dfrac{0.43}{1 - \bar C}, & 0.53 \le \bar C < 0.85,\\[8pt]
  \dfrac{1}{\bar C^{3} - 4\bar C^{2} + 3\bar C}, & \bar C \ge 0.85.
\end{cases}
$$

If $\textcolor{#c13b9e}{\bar C} \le 0$, $\textcolor{#c13b9e}{\hat\kappa}$ is taken
as 0, and if $\textcolor{#c13b9e}{\bar C}$ is exactly 1 it is infinite. In
either case there is no ellipse.

_One consequence worth knowing._ The residuals are measured from a position
that was chosen to make them small, and nothing corrects for that: taken
together they are always smaller than the true errors. By choosing its two
coordinates the estimate can cancel as much disagreement as two bearings carry,
leaving $n - 2$ bearings' worth to measure the spread from (the two degrees of
freedom White and Garrott say are lost, 1990, p. 69 [[2]](#ref-2)). With many
bearings it makes little difference. With three to five it tends to make
$\textcolor{#c13b9e}{\hat\kappa}$ too large and the ellipse too small;
[step 4](../how-the-estimate-is-calculated/#4-how-spread-out-the-bearings-are-κ-from-the-residuals)
explains it, shows an example, and
[the coverage section](../how-the-estimate-is-calculated/#how-often-does-the-95-ellipse-contain-the-animal)
measures the effect. With exactly two bearings that cross, both residuals are
zero, $\textcolor{#c13b9e}{\hat\kappa}$ is infinite, and there is no ellipse.

## The ellipse

In words: each bearing tells you a lot about the animal's position _across_
its line, and almost nothing _along_ it. Bearings from different directions
together pin the position down. A bearing tells you more the closer the
animal is to where it was taken and the more concentrated the bearings are.
Adding that up gives the uncertainty in each direction, and the ellipse draws
it.

The information the bearings carry about $(x, y)$ is summarized in a two-by-two
matrix (Lenth's Eqs. 2.7 to 2.9 [[1]](#ref-1)), evaluated at the estimate:

$$
\hat I_{xx} = \sum_{i=1}^{n} s_i\, s_i^{*}, \qquad
\hat I_{yy} = \sum_{i=1}^{n} c_i\, c_i^{*}, \qquad
\hat I_{xy} = -\tfrac{1}{2}\sum_{i=1}^{n} \bigl(s_i\, c_i^{*} + c_i\, s_i^{*}\bigr).
$$

Since $s_i^{*} \approx \sin\mu_i / d_i^{2}$, the term $\hat I_{xx}$ is roughly
$\sum \sin^2\mu_i / d_i^2$: a bearing pointing north or south says the most
about the east-west coordinate, and less the farther away the animal is.

The _covariance matrix_ of the estimate is the inverse of the information
scaled by the concentration:

$$
\textcolor{#1d7852}{Q} = \bigl(\textcolor{#c13b9e}{\hat\kappa}\,\hat I\bigr)^{-1}
  = \frac{1}{\textcolor{#c13b9e}{\hat\kappa}\,\bigl(\hat I_{xx}\hat I_{yy} - \hat I_{xy}^{2}\bigr)}
  \begin{bmatrix} \hat I_{yy} & -\hat I_{xy} \\ -\hat I_{xy} & \hat I_{xx} \end{bmatrix}.
$$

Its diagonal gives the standard errors and its off-diagonal the correlation:

$$
\operatorname{SE}(\textcolor{#da210c}{\hat x}) = \sqrt{Q_{xx}}, \qquad
\operatorname{SE}(\textcolor{#da210c}{\hat y}) = \sqrt{Q_{yy}}, \qquad
\rho = \frac{Q_{xy}}{\operatorname{SE}(\hat x)\,\operatorname{SE}(\hat y)} .
$$

_The ellipse's size and direction_ come from the two eigenvalues of
$\textcolor{#1d7852}{Q}$,

$$
\lambda_{1,2} = \frac{Q_{xx} + Q_{yy}}{2} \pm
  \sqrt{\Bigl(\frac{Q_{xx} - Q_{yy}}{2}\Bigr)^{2} + Q_{xy}^{2}},
$$

which give the semi-major and semi-minor axes (White and Garrott 1990,
pp. 62–63 [[2]](#ref-2))

$$
\textcolor{#1d7852}{a} = \sqrt{\textcolor{#1d7852}{k}\,\lambda_1}, \qquad
\textcolor{#1d7852}{b} = \sqrt{\textcolor{#1d7852}{k}\,\lambda_2}, \qquad
\textcolor{#1d7852}{k} = -2\ln(1 - p),
$$

and the major axis points at the angle
$\psi = \tfrac12\operatorname{atan2}\bigl(2Q_{xy},\, Q_{xx} - Q_{yy}\bigr)$
counterclockwise from east, which the map draws as the compass direction
$90^\circ - \psi$.

_The confidence level._ TriTrack sets $p = 0.95$, so
$\textcolor{#1d7852}{k} = 5.991$ and each semi-axis is 2.448 standard
deviations long in its own direction. $\textcolor{#1d7852}{k}$ is the 95th
percentile of a chi-square distribution with two degrees of freedom: if the
estimate's errors are normal with covariance $\textcolor{#1d7852}{Q}$, the
squared distance from the estimate in standard deviations,
$\mathbf{d}^{\mathsf T} \textcolor{#1d7852}{Q}^{-1} \mathbf{d}$, is a sum of
two squared standard normal variables, which is chi-square with two degrees of
freedom. In one direction the same reasoning gives the familiar 1.96, since
$1.96^2 = 3.84$ is chi-square's 95% point with one degree of freedom. This is
the standard construction: White and Garrott build the 95% ellipse from
Lenth's covariance and the same chi-square value, relying on the estimate's
errors being approximately normal (1990, pp. 62–63; their Eq. 4.6 gives its
area, $\pi\,|\textcolor{#1d7852}{Q}|^{1/2}\,\chi^2_2(0.95)$) [[2]](#ref-2). It is the right
size when $\textcolor{#c13b9e}{\kappa}$ is known, as it is in their
construction, where κ comes from system testing. TriTrack estimates it from
the bearings and does not widen the ellipse to allow for that (see
[how often the ellipse contains the animal](../how-the-estimate-is-calculated/#how-often-does-the-95-ellipse-contain-the-animal)).
The axes and direction are what {{< app "SAVE POSITION" >}} stores.

## Why not just average where the bearings cross?

It is the obvious alternative, and Lenth's paper explains why it is a poor
one (his section 1) [[1]](#ref-1). Three reasons are easy to see. With $n$ bearings there
are $n(n-1)/2$ crossing points, but each bearing is in $n - 1$ of them, so one
bad bearing moves many points at once. Two nearly parallel bearings cross
very far away, and that one point can drag the average a long way. And a
pair of lines can cross behind where one of the bearings was taken, which
says nothing about the animal at all. The maximum-likelihood estimate uses
each bearing once and weights it by what it actually tells you. TriTrack does
not show the crossing points.

## When it goes wrong

The app checks each estimate and lists cautions in words. What each one
measures:

- _Time span over six hours._ The earliest and latest selected bearings are
  more than 360 minutes apart. [Assumption 1](../how-the-estimate-is-calculated/#what-the-method-assumes) may not hold.
- _Near-parallel bearings._ The bearings' directions are almost the same. The
  test is the circular standard deviation of the compass bearings,
  $\sqrt{-2\ln \bar R}$, where $\bar R$ is the length of the average of their
  unit vectors; under $2^\circ$ triggers it. Lines that nearly coincide cross
  at a poorly defined place.
- _Poor geometry._ The 95% ellipse is more than ten times as long as it is
  wide, or reaches more than 5 km from the estimate along its long axis. This usually means every bearing came from one
  side of the animal ([step 6](../how-the-estimate-is-calculated/#6-geometry-matters)).
- _Few bearings._ The ellipse rests on five bearings or fewer, where the
  simulation found it contains the animal 70% of the time or less:
  {{< app "Few bearings — the 95% ellipse usually understates the uncertainty. Add bearings if you can." >}}
- _No ellipse._ There is an estimate but no spread to measure, always with two
  bearings:
  {{< app "No ellipse — two bearings can't measure their own spread. Add a third." >}}
  With more than two it is rare, and the caution
  reads {{< app "No ellipse — these bearings can't measure their own spread." >}}
- _Observers at the same point._ Every bearing was taken within 1 m of every
  other. No estimate is made.
- _Low-accuracy GPS._ At least one bearing's recorded position accuracy is
  worse than 20 m. The estimate is unchanged; the warning is that the ellipse
  does not include this error ([assumption 4](../how-the-estimate-is-calculated/#what-the-method-assumes)).
- _Did not converge._ See [finding the position](#finding-the-position).
- _One bearing_, or a set that cannot be solved: the ray only, or nothing.

_What no caution catches._ A bearing that is wrong but agrees well enough
with the others: a reflection, a misidentified frequency, a misread dial. It
pulls the estimate and, by adding to the residuals, also enlarges the ellipse,
but nothing on screen points at it. The next section shows how large that
effect can be.

## Validation against Lenth's own example

Lenth's paper works through an example: seven bearings
toward a source whose true location is known, (7.5, 2.2) on his map grid
(his Tables 1 and 2) [[1]](#ref-1). A test
in TriTrack's code feeds those seven bearings to the same calculation the
Position tab uses and checks the answer against the published one. It also
adds the eighth bearing from the paper, taken at 250° from (5.6, 9.0), which
is a signal reflected from the west. The test runs with the rest of
the app's test suite before every change to the code is committed.

The units are the paper's map units, not meters. TriTrack's values are what
the calculation produces on those inputs today.

_Seven good bearings_

| Quantity | Published | TriTrack | Difference |
| --- | --- | --- | --- |
| Estimate, east | 7.23 | 7.228 | −0.002 |
| Estimate, north | 1.98 | 1.981 | +0.001 |
| Standard error, east | 0.156 | 0.156 | 0.000 |
| Standard error, north | 0.156 | 0.156 | 0.000 |
| Correlation | 0.664 | 0.664 | 0.000 |
| Distance from the true location | 0.349 | 0.349 | 0.000 |
| Steps to converge | 7 | 8 | +1 |

TriTrack takes one more step than the paper reports. The two stopping rules
differ (TriTrack stops when both coordinates move by less than 0.000 000 1 map
units in a step), and the answer agrees to the published precision. No step
is shortened.

_The same seven, plus the reflected bearing_

| Quantity | Published | TriTrack | Difference |
| --- | --- | --- | --- |
| Estimate, east | 5.87 | 5.871 | +0.001 |
| Estimate, north | 1.13 | 1.134 | +0.004 |
| Standard error, east | about 1.49 | 1.507 | about +0.02 |
| Standard error, north | about 1.73 | 1.753 | about +0.02 |
| Distance from the true location | not recorded | 1.947 | |

_What the test checks:_ for the seven bearings, each coordinate and each
standard error to within 0.01 of the published value, the correlation to
within 0.03, and no more than 15 steps; for the eight, each coordinate to
within 0.05, and a standard error above 1.

_Why this is the case for unticking a doubtful bearing._ One reflected
bearing out of eight moved the estimate from 0.35 to 1.95 units from the
true location, more than five times farther, and made the standard errors
about ten times larger. The estimate did not fail and no caution fired: the
ellipse simply grew to cover a wrong answer. On the Position tab, untick the
bearing you doubt and watch the estimate. If it jumps and the ellipse
shrinks, that bearing was disagreeing with all the others.

## Where TriTrack differs from the paper

- _The concentration_ κ uses Fisher's (1993) [[5]](#ref-5) approximation rather than
  Lenth's Eq. 2.10 [[1]](#ref-1).
- _Only the maximum-likelihood estimator._ Lenth's paper also describes robust
  versions that give a stray bearing less weight. TriTrack does not implement
  them, which is why unticking matters.
- _A step that would make the fit worse is halved_ ([step 3](../how-the-estimate-is-calculated/#3-finding-the-top-of-the-hill)). Lenth's
  iteration takes every step whole.
- _The stopping rule_ (0.1 mm, at most 200 steps) is TriTrack's choice.
- _The flat map_ is a local projection centered on the observers, which is
  how TriTrack meets the paper's flat-earth assumption on a real map.
- _The cautions and their thresholds_ (six hours, 2°, ten to one, 5 km, five
  bearings, 1 m, 20 m) are TriTrack's own.

The 95% ellipse itself is not a difference: it is Lenth's covariance scaled by
chi-square, as White and Garrott (1990, pp. 62–63) [[2]](#ref-2) construct it.

## References

Shared with [how the estimate is calculated](../how-the-estimate-is-calculated/),
and numbered in the order each source is first cited, reading that page first.

{{< theory-references >}}

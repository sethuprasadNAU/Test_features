# Ellipse coverage data

Two files the guide's figures about the 95% ellipse are drawn from (task `/w-36`).
Both come from the app's own solver, with the **chi-square** 95% scale the app uses.
The F-scaled columns task 11.334 measured are **not** here; they are printed, as a
labeled record, by `ellipse_coverage_simulation_test.dart`.

## Regenerate

One command, from the repository root:

```
flutter test test/localization/ellipse_coverage_data_test.dart \
    --dart-define=WRITE_ELLIPSE_COVERAGE_DATA=true
```

Running it twice writes identical files. Without the flag the same test **fails when
a committed file differs** from what the solver now produces, so a change to the
solver, κ or the ellipse cannot leave the guide describing the old app. Numbers are
rounded to 6 decimals when written, so another machine's last-bit differences cannot
show up as a diff.

## `coverage_chi_square.csv`

How often the app's 95% ellipse contained the animal. 2,000 simulated fixes per row;
the stations, the bearing scatter and the seed are task 11.323's, so this reproduces
its table to the digit (see `ellipse_simulation.dart` for the setup).

| Column | Meaning |
|---|---|
| `bearings` | how many bearings the fix used |
| `spread_sd_deg` | circular standard deviation of the bearing errors, degrees |
| `runs` | simulated fixes |
| `fixes_with_ellipse` | fixes that produced an ellipse (the rest are `no_ellipse`) |
| `covered_chi_square`, `coverage_chi_square` | fixes whose 95% ellipse contained the true point, and that as a fraction of `fixes_with_ellipse` |
| `covered_chi_square_true_kappa`, `coverage_chi_square_true_kappa` | the same, with the **true** κ in place of the one estimated from the bearings: the reference the gap is measured against |

A fix with no ellipse is counted apart, not as a miss.

## `worked_examples.json`

Six single fixes: 3, 5 and 10 bearings at 5° and 15° of scatter. Each takes the first
fix in its own random stream (seed `11336 + its position`) with the stated outcome:
**a miss at 3 bearings, where it is the usual result, and a fix that contains the
animal at 5 and 10 bearings, where that is.** Each example records its cell's own
coverage (`this_cells_coverage_chi_square`) so a caption can say which is usual.

Coordinates are meters on a plane: x east, y north, the animal at the origin. Angles
are **compass** degrees (clockwise from north) unless the name says `math` (radians,
counterclockwise from east, the solver's own).

| Field | Meaning |
|---|---|
| `stations[]` | each station's position, its reading (`bearing_compass_deg`, `theta_math_rad`), the true bearing, the error it was given, and its **leftover angle** — how far the reading is from the line to the final estimate. Positive `leftover_angle_deg` means the reading points clockwise of that line. `leftover_angle_math_rad` is the solver's own θᵢ − μᵢ. |
| `estimate` | the point, its distance from the true point, the solver's iteration count and warnings |
| `solver_path` | where the search started (the least-squares intersection of the bearing lines) and each step: where it began, where Eq. 2.6 pointed (`full_step_to`), how much of it was taken (`fraction`), where it ended, and the fit `sum_cosine` = Σ cos(θᵢ − μᵢ). **A step cut back because the whole step made the fit worse has `shortened: true`.** `shortened_steps` lists them. The last step of a converged search is whole and has `converged: true`. |
| `kappa` | κ, and the `mean_cosine` of the leftover angles it is computed from (κ is the inverse of the von Mises mean-resultant function at that number); `mean_resultant_length` is the solver's other agreement measure |
| `covariance_m2` | the covariance of the estimate, with standard errors and correlation |
| `ellipses.one_sd`, `ellipses.ninety_five` | semi-axes and rotation. The **1-SD ellipse** is the set of points at Mahalanobis distance 1 (`scale_k` 1); the **95% ellipse** is the app's, at `scale_k` 5.9915 (chi-square, 2 degrees of freedom), so its axes are √5.9915 ≈ 2.45 times the 1-SD ones. |
| `true_point_mahalanobis_squared`, `covered_by_95_ellipse` | the true point is covered when the first is at most 5.9915 |

**None of the six examples needed a shortened step.** The marking is exercised by two
real fixes pinned in `lenth_mle_test.dart`; in the whole simulation about 3% of fixes
(1,049 of 36,000) shorten at least one step.

`/w-36`'s figure script recomputes likelihood surfaces itself and checks them against
these numbers.

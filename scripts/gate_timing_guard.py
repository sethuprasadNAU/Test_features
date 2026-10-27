#!/usr/bin/env python3
# gate-instrument: gate_timing_guard_selftest
"""Task 11.90 (Security Model §22.4.1, finding R-3): the decision rule for
`gate_c_adversarial_pass.py`'s `Cg` timing check, and its self-test.

**Why this is its own file.** The rule it holds is the part of `Cg` that was
wrong, and the only way to be sure a *second* guard is right is to be able to
break it on purpose cheaply. `Cg` itself needs a live stack, three project ids
and about a minute of requests; this function needs a list of numbers. Run

    python3 scripts/gate_timing_guard.py --selftest

and every branch below is exercised in about a second, including the exact
shape of the run that produced R-3.

---

**What R-3 was.** `Cg` asks whether a real foreign project and a fictional one
can be told apart by how long `/sync/pull` takes to refuse them. It measures
two differences per trial:

  * the **between** difference, `real - fictional`, which is the effect being
    hunted; and
  * the **null** difference, `fictional - fictional`, whose true value is
    exactly zero, because both ids are equally non-existent.

The old rule failed the check when the between difference had the same sign in
every trial, and declared the run INCONCLUSIVE when the *null* also had the same
sign in every trial — the idea being that a host whose drift never changes sign
cannot resolve anything.

**That guard tested the null's sign and not its size**, and on 2026-08-31 a run
sharing a laptop with seventeen other gate instruments produced a null that was
positive in 5 of 7 trials — not unanimous, so the guard stayed quiet — while
load pushed the between difference to `+0.125 ms`, positive in 7 of 7. It was
scored as a real finding and blocked Gate C. Three re-runs on the same quiet
host put it at `+0.030`, `-0.036`, `+0.028 ms` with the sign flipping. The real
residual, measured on a quiet Linux runner by task 11.72, is `+5 µs`.

**The repair, and it is §22.4.1's rather than a fresh invention: compare the
between difference against the null distribution the run already collected,
instead of against zero.** The null is the run's own answer to "how far apart
can two identical things measure on this machine, right now" — so it is a
resolution, measured at the same moment, on the same host, through the same
socket, by the same code. A between difference no bigger than that is not a
difference this run is entitled to report.

**The resolution is `max(|null|)`** — the largest gap this run opened between
two ids that are the same in truth. Not a standard deviation and not a
multiplier on one: with seven trials a dispersion estimate is itself noisy, and
any constant factor chosen on top of it would be a threshold somebody picked,
which is the thing this finding is about. `max(|null|)` is a fact the run
produced and can be quoted in one sentence.

**What this deliberately is not.** It is not a wider tolerance. A real oracle
stays red on a loaded machine: load inflates the null, and the check fails
whenever the effect is larger than the null however large both are — case 2 of
the self-test measures exactly that. What changes is only the verdict on an
effect the run **cannot resolve**: that is now INCONCLUSIVE, where before a
stable sign alone was enough to call it a finding.
"""
import sys

#: Fewest trials this rule will speak about at all. Below this, `max(|null|)`
#: is one or two numbers and a unanimous sign means almost nothing — three
#: coin flips agree one time in four.
MIN_TRIALS = 3

HELD = "HELD"
FAILED = "FAILED"
INCONCLUSIVE = "INCONCLUSIVE"


class TimingGuardError(ValueError):
    """The inputs cannot be judged — a bug in the caller, not a verdict."""


def _median(values):
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def verdict(between, null):
    """Judge one `Cg` run. Returns `(verdict, detail)`.

    `between` and `null` are per-trial differences in milliseconds:
    `real - fictional` and `fictional - fictional`. Same length, one entry per
    trial, in trial order.

    * `FAILED` — the effect has the same sign in every trial **and** is larger
      than any difference this run produced between two identical ids. Both
      halves are required: a stable sign says the difference is one-sided, the
      magnitude says the run could see it.
    * `INCONCLUSIVE` — the run measured nothing it is entitled to report.
    * `HELD` — the trials disagree in sign at a magnitude within the run's own
      noise, which is what a server with no timing oracle looks like.
    """
    if len(between) != len(null):
        raise TimingGuardError(
            f"{len(between)} between-pair differences and {len(null)} null "
            "differences: the two are collected one per trial and must match")
    if len(between) < MIN_TRIALS:
        raise TimingGuardError(
            f"{len(between)} trials is fewer than {MIN_TRIALS}; a sign is not "
            "evidence at that count and max(|null|) is not a resolution")

    trials = len(between)
    between_pos = sum(1 for d in between if d > 0)
    null_pos = sum(1 for d in null if d > 0)
    effect = _median(between)
    resolution = max(abs(d) for d in null)
    detail = (f"real-minus-fictional median {effect:+.3f}ms, positive in "
              f"{between_pos}/{trials} trials; the fictional-minus-fictional "
              f"null, which is zero in truth, positive in {null_pos}/{trials} "
              f"and reaching {resolution:.3f}ms at its largest — so this run "
              f"resolves {resolution:.3f}ms and the effect is "
              f"{abs(effect):.3f}ms")

    sign_is_stable = between_pos in (0, trials)
    resolved = abs(effect) > resolution

    if null_pos in (0, trials):
        return INCONCLUSIVE, (
            "the null's own sign never changed, so this host's drift is "
            f"one-directional and larger than the experiment. {detail}")
    if sign_is_stable and resolved:
        return FAILED, detail
    if sign_is_stable:
        return INCONCLUSIVE, (
            "the effect has a stable sign but is no larger than the gap this "
            "run opened between two identical ids, which is what a loaded "
            f"machine looks like and not what an oracle looks like. {detail}")
    if resolved:
        return INCONCLUSIVE, (
            "the trials disagree in sign yet the median is larger than the "
            "null, so the spread between trials exceeds both the effect and "
            f"the run's own noise: nothing here is a measurement. {detail}")
    return HELD, detail


def _legacy_verdict(between, null):
    """The rule R-3 is about, kept only so the self-test can show the change.

    Sign of the between pair decides; sign of the null guards. No magnitude
    is consulted anywhere, which is the defect.
    """
    trials = len(between)
    if sum(1 for d in null if d > 0) in (0, trials):
        return INCONCLUSIVE
    return FAILED if sum(1 for d in between if d > 0) in (0, trials) else HELD


def _selftest():
    ok_all = True

    def report(name, condition, detail=""):
        nonlocal ok_all
        print(("  PASS  " if condition else "  ***FAILED***  ") + name
              + (f"  {detail}" if detail else ""))
        ok_all = ok_all and condition

    print("gate_timing_guard self-test — the rule, broken on purpose.\n")

    print("1. The run that produced R-3: load pushed both pairs positive, the "
          "null's sign was 5/7 so the old guard stayed quiet, and a "
          "0.125ms bias was reported as a Gate C blocker.")
    # Between: the reported +0.125ms mean, positive in 7/7. Null: positive in
    # 5 of 7, at magnitudes a loaded laptop produces between two ids that do
    # not exist — which is the fact the old rule never looked at.
    r3_between = [0.121, 0.140, 0.098, 0.133, 0.109, 0.152, 0.122]
    r3_null = [0.088, -0.061, 0.170, 0.052, -0.043, 0.131, 0.096]
    v, d = verdict(r3_between, r3_null)
    report("the repaired rule calls it INCONCLUSIVE", v == INCONCLUSIVE, d)
    report("and the rule it replaces called it a finding",
           _legacy_verdict(r3_between, r3_null) == FAILED,
           "if this line ever fails, the self-test is no longer demonstrating "
           "the defect it was written for")

    print("\n2. A real oracle stays red, and stays red on a machine loaded "
          "hard enough to triple its own noise. This is the case that would "
          "prove the repair had been a widened tolerance in disguise.")
    oracle_between = [41.2, 38.9, 44.0, 39.5, 42.7, 40.1, 43.3]
    quiet_null = [0.03, -0.02, 0.04, -0.05, 0.01, 0.02, -0.03]
    loaded_null = [3.1, -2.4, 5.0, -1.9, 2.2, 4.4, -3.0]
    report("40ms one-sided, quiet host -> FAILED",
           verdict(oracle_between, quiet_null)[0] == FAILED)
    report("the same effect with a null five hundred times larger -> still "
           "FAILED", verdict(oracle_between, loaded_null)[0] == FAILED)

    print("\n3. A quiet run against a server with no oracle: signs disagree, "
          "magnitudes at the noise floor.")
    v, d = verdict([0.030, -0.036, 0.028, -0.011, 0.019, -0.024, 0.008],
                   quiet_null)
    report("HELD", v == HELD, d)

    print("\n4. The old guard's own case is kept, not dropped: a null whose "
          "sign never changes is still a drift-dominated run.")
    v, d = verdict(oracle_between, [0.9, 1.4, 0.7, 2.2, 1.1, 0.6, 1.8])
    report("INCONCLUSIVE even with a large one-sided effect",
           v == INCONCLUSIVE, d)

    print("\n5. The verdict moves with the magnitude, which is the whole "
          "repair: the same null, an effect scaled until it clears it.")
    base_null = [0.10, -0.08, 0.12, -0.06, 0.09, -0.11, 0.07]
    below = [0.05, 0.06, 0.04, 0.05, 0.07, 0.05, 0.06]
    above = [0.50, 0.60, 0.40, 0.50, 0.70, 0.50, 0.60]
    report("effect under max(|null|) -> INCONCLUSIVE",
           verdict(below, base_null)[0] == INCONCLUSIVE)
    report("the same shape scaled ten times -> FAILED",
           verdict(above, base_null)[0] == FAILED)
    report("and the old rule could not tell those two apart",
           _legacy_verdict(below, base_null)
           == _legacy_verdict(above, base_null) == FAILED)

    print("\n6. Trials that cannot be judged are an error, never a verdict — "
          "a guard that answers HELD when its inputs are broken is the "
          "defect this file exists to fix, one door along.")
    for name, args in (
            ("mismatched lengths", ([0.1, 0.2, 0.3], [0.1, 0.2])),
            ("two trials", ([0.1, 0.2], [0.1, -0.2]))):
        try:
            verdict(*args)
            report(f"{name} raises", False, "it returned a verdict instead")
        except TimingGuardError as exc:
            report(f"{name} raises", True, str(exc))

    print()
    if ok_all:
        print("SELFTEST PASSED: the guard tests the magnitude of its own "
              "control, R-3's run is INCONCLUSIVE, and a real oracle is still "
              "FAILED on a loaded host.")
        return 0
    print("SELFTEST FAILED: see ***FAILED*** lines above.")
    return 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print(__doc__)
    sys.exit(0)

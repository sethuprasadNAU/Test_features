#!/usr/bin/env python3
# gate-instrument: none - run on every commit by test/documentation/broken_control_trigger_test.dart, which needs no Docker.
"""Does every broken-control harness still know how to break the server?

## The defect this exists for, and it had already happened

A `*_broken_control.py` harness proves an instrument can **detect** — it
deletes a real control from a throwaway copy of the tree, rebuilds the server,
and requires the instrument to notice. It names the control by quoting the
source line that implements it.

**That makes a harness coupled to code it does not own, and the coupling is
invisible from the owning side.** On 2026-09-02 task 11.89 replaced the person
-name denylist with an allowlist and deleted a line that
`verify_11_85_broken_control.py`'s `grant` variant patches. It was a good
change and there was nothing wrong with the refactor. The consequence was
that **the bidi-name detection proof stopped existing** — while the instrument
it vouches for went on running and went on reporting clean, and nothing that
read that output could have known its ability to report anything else had gone.

The harnesses do check their own patch text before trusting a run
(`verify_round8_broken_control.py:248` and the same guard in the other two).
**That check runs at harness time**, which is a ten-minute Docker run fired by
a path filter. **Nothing ran when the target changed.** This does.

## What it asserts

Given every `scripts/*_broken_control.py` — derived from the filename, so a
fourth harness is covered by existing rather than by being added to a list:

  1. At least one harness was found, and each one exposes `VARIANTS`. **An
     empty derivation fails**: a glob that matches nothing and a project with
     no harnesses are indistinguishable from the inside, and only one of them
     is true.
  2. Every variant has at least one patch, and every patch names a file that
     exists.
  3. **Every patch's `old` text appears exactly once** in the file it names.
     Zero means the control moved or was deleted and this variant now
     sabotages nothing; more than one means the harness would edit a place it
     did not mean to.
  4. `new` differs from `old`. A variant that patches text to itself builds an
     unmodified server and requires an instrument to notice a change that was
     never made — which fails in the *loud* direction, but is still a variant
     that measures nothing.

## What it cannot see

It asks whether the harness can still **apply** its sabotage. It says nothing
about whether the sabotage still removes a *control* — that judgement is
`must_flip`, and only the Docker run can settle it. So this is the cheap half:
it catches a patch target that was renamed, moved or deleted, on the commit
that does it, in a suite with no Docker in it. **A control that is still there
and no longer load-bearing is out of its reach.**

Usage:

    python3 scripts/check_broken_control_patch_targets.py

Exits non-zero naming the harness, the variant, the file and the first line of
the text it could not find. Run on every commit by
`test/documentation/broken_control_trigger_test.dart`.
"""
import glob
import importlib.util
import io
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT_GLOB = os.path.join(ROOT, "scripts", "*_broken_control.py")


def load(path):
    name = "broken_control_" + os.path.basename(path)[:-3]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def first_line(text):
    line = text.strip().splitlines()[0] if text.strip() else "(empty)"
    return line if len(line) <= 72 else line[:69] + "..."


def main():
    failures = []
    harnesses = sorted(glob.glob(SCRIPT_GLOB))

    if not harnesses:
        print(f"NOTHING TO CHECK: no harness matched {SCRIPT_GLOB}.")
        print(
            "Either every broken-control harness was deleted — in which case "
            "no instrument in this project is known to be able to detect "
            "anything — or this derivation stopped matching, and a derivation "
            "that matches nothing reports full coverage of nothing."
        )
        return 1

    variants = 0
    patches = 0
    for path in harnesses:
        relative = os.path.relpath(path, ROOT)
        try:
            module = load(path)
        except Exception as error:  # noqa: BLE001 — the message is the point
            failures.append(f"{relative}: will not import — {error!r}")
            continue

        declared = getattr(module, "VARIANTS", None)
        if not declared:
            failures.append(
                f"{relative}: no non-empty `VARIANTS` list. Either the harness "
                f"stopped declaring its variants where this check reads them, "
                f"or it has none — and a harness with no variants breaks "
                f"nothing and proves nothing."
            )
            continue

        for variant in declared:
            variants += 1
            name = variant.get("name", "(unnamed)")
            edits = variant.get("patches") or []
            if not edits:
                failures.append(
                    f"{relative}: variant '{name}' has no patches, so it "
                    f"builds an unmodified server and requires an instrument "
                    f"to notice a control that was never removed."
                )
                continue
            for target, old, new in edits:
                patches += 1
                full = os.path.join(ROOT, target)
                if not os.path.exists(full):
                    failures.append(
                        f"{relative}: variant '{name}' patches {target}, which "
                        f"does not exist. The file moved and the variant went "
                        f"with it."
                    )
                    continue
                if old == new:
                    failures.append(
                        f"{relative}: variant '{name}' patches {target} to "
                        f"identical text, so it changes nothing."
                    )
                    continue
                found = io.open(full, encoding="utf-8").read().count(old)
                if found != 1:
                    failures.append(
                        f"{relative}: variant '{name}' patches text that "
                        f"appears {found} times in {target}, not once — "
                        f"starting `{first_line(old)}`.\n"
                        f"      {'The control this variant deletes is gone, so this variant now sabotages nothing.' if found == 0 else 'The text is ambiguous, so this variant would edit a place it did not mean to.'}\n"
                        f"      Until it is re-authored, whatever this variant "
                        f"proves about {variant.get('instrument', 'its instrument')} "
                        f"is not being proved."
                    )

    print(
        f"Checked {patches} patch target(s) across {variants} variant(s) in "
        f"{len(harnesses)} broken-control harness(es): "
        + ", ".join(os.path.basename(p) for p in harnesses)
    )
    if failures:
        print()
        print("A DETECTION PROOF HAS STOPPED EXISTING:")
        for failure in failures:
            print("  ! " + failure)
        print()
        print(
            "The instrument each of these vouches for still runs and still "
            "reports clean. Nothing reading that output would know it can no "
            "longer report anything else."
        )
        return 1
    print(
        "Every one was found exactly once, so every variant can still apply "
        "the sabotage it was written to apply."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

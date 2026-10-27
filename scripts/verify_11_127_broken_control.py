#!/usr/bin/env python3
# gate-instrument: none - a detection proof, run by .github/workflows/broken-control-check.yml, which is where a deliberately broken server exists.
"""Task 11.127 — watch the C-1 reproduction and the every-table oracle sweep
fail.

## Why this file exists

Task 11.119's survey counted **eight wire-speaking instruments with no
detection proof of any kind**, and named the distinction nobody had been
making: `gate_smoke_test.sh`'s self-test proves every instrument **aborts**
when the world is wrong, and abortion is not detection. *"An instrument that
fails loudly when the world is wrong may still be unable to notice the thing
it exists for"* — task 11.71's finding, and the reason a Gate C round's
criterion 1 was once met on an instrument that had reported clean for two
rounds without being able to report anything else.

Michael chose the top two of the ranked eight on 2026-09-05. They are here
because of what a gate verdict rests on:

  * **`verify_h3_existence_oracle_sweep.py`** makes the widest claim in the
    project — *no table in `sync_tables.dart` lets a stranger learn whether a
    record exists* — which is what §4.13's residual rests on. Five of the eight
    at least record a hand demonstration in their headers; this one records
    none, and has no positive control either. **Widest claim, weakest
    evidence.**
  * **`verify_c1_row_naming.py`** is the only live reproduction of C-1 — a
    contributor writing records attributed to somebody else — which is the
    finding the whole gate was built around. Its header says it was watched
    failing once against a build with task 10.20's invariant removed. That
    sentence is three months old, names no commit, and nothing re-establishes
    it.

## What it does

The same shape as the three harnesses before it. For each variant it brings up
a **separate compose project** built from a throwaway git worktree with a real
control deleted, runs the instrument against it, and requires the instrument's
verdict to change. **The pairing is what makes it evidence**: the same
instruments, in the same run, must also come back clean against the unmodified
server. Either half alone proves nothing — a clean run could be blindness, and
a red run could be a broken probe.

Nothing here touches the working tree.

## The one thing this harness does that the earlier three do not

**The oracle sweep's required set is derived from its own healthy run, not
written down here.** A hand-written list of "the tables that must flip" would
be wrong the day a table is added — the exact defect the sweep's own derived
`PRIMARY_KEYS` closed one layer down, when a hardcoded list of eleven tables
missed the twelfth for four months. So: **every table the sweep calls
indistinguishable against the real server must become distinguishable against
the broken one.** Nine tables on 2026-09-05.

**That number moved on 2026-09-10 and nothing here had to change, which is the
point of deriving it.** Task 11.219 retired `Project_Tags` (one probe gone) and
made `Tags` and `Tag_Versions` project-scoped, which closed finding H-3 and took
both off the sweep's accepted-findings list — so they now report
*indistinguishable* rather than *finding*, and this harness requires both to
flip. Ten tables. Nobody edited a list.

Usage, with the healthy e2e stack already up:

    python3 scripts/verify_11_127_broken_control.py

Takes roughly ten minutes — each variant is a fresh `dart compile exe`. Exits
non-zero if a healthy run is not clean, if any required verdict fails to
change, or if a variant will not build.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Task 11.310: before this drill sends a single request, `port_holder` asks
# Docker which compose project owns the port it is about to attack. See
# `refuse_unless_stack` in main() for why.
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
from port_holder import check_free, check_stack, refuse_unless_stack  # noqa: E402
# Task 11.69, same reason as every other instrument: without these the magic
# link lands `root:root 0600` on a Linux host and every sign-in below dies on
# `Errno 13`. `setdefault` so an outer script that already set them wins.
os.environ.setdefault("TRITRACK_DEV_UID", str(os.getuid()))
os.environ.setdefault("TRITRACK_DEV_GID", str(os.getgid()))

HEALTHY_BASE = os.environ.get("BASE", "http://localhost:8080")
HEALTHY_LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")
HEALTHY_COMPOSE = os.environ.get(
    "COMPOSE",
    "docker compose -p tritrack-gate "
    "-f docker-compose.yml -f docker-compose.e2e.yml",
)
# 8090 is free: 8091 is the server-reads harness's and 8092 the join-surface
# one's, and two harnesses on one port would fight if a runner ever ran them
# together.
BROKEN_PORT = os.environ.get("BROKEN_PORT", "8090")

ROW_AUTHORIZER = "server/lib/src/authz/row_authorizer.dart"
SYNC_SERVICE = "server/lib/src/sync/sync_service.dart"

#: Which instrument scores each variant, and the environment variable it writes
#: its per-check verdicts to.
NAMING = "verify_c1_row_naming.py"
ORACLE = "verify_h3_existence_oracle_sweep.py"
JSON_ENV = {NAMING: "VERIFY_C1_JSON", ORACLE: "VERIFY_H3_JSON"}


def patch(path, old, new):
    return (path, old, new)


#: Checks that exist to prove the *server still works*, not that an attack was
#: refused. A broken server is expected to break these, so they are reported
#: apart from everything else rather than counted as an interesting flip.
POSITIVE_CONTROLS = {
    "attacker's own observation is inserted",
    "baseline pull returns only the attacker",
    "the caller's own observations still sync (publish is not broken)",
}


def naming_flips(healthy, broken):
    """Which C-1 reproductions must go from refused to reproduced.

    Returns `(required, flipped, also, controls)` — the names required to flip,
    the required ones that did, the ones that flipped without being required,
    and the positive controls the broken server also broke.

    **The required list is the reproductions whose flip is certain from the
    edit**, not everything that happens to change. Deleting the naming
    invariant also lets several *consequences* through — the victim's profile
    becoming reachable, a forged note landing, an owner column being
    rewritten — and those are printed rather than required, because a
    consequence that does not appear is a fact about the fixture rather than
    about the instrument.
    """
    required = {
        # B1a — an observation the attacker never made, filed under the
        # victim's `user_id`.
        "forged insert is refused",
        # B1b — the same forgery on the table that records an absence.
        "forged non-detection is refused",
        # B1d — taking authorship of a row that is already the victim's.
        "rewriting the author is refused",
        # The 10.29 regression: naming somebody this project cannot reach is
        # attribution as well as disclosure, and both halves converge on the
        # refusal.
        "an imported colleague's Users row is refused (10.29's converged rule)",
        "their observation is refused with it",
    }
    was_passing = {k for k, v in healthy["checks"].items() if v}
    now_failing = set(broken["failed"])
    flipped = was_passing & now_failing
    return (required, flipped & required,
            sorted(flipped - required - POSITIVE_CONTROLS),
            sorted(flipped & POSITIVE_CONTROLS))


def oracle_flips(healthy, broken):
    """Which tables must go from indistinguishable to distinguishable.

    **Derived from the healthy run**, so a table added to `sync_tables.dart`
    tomorrow is required to flip the day it lands and nobody has to remember
    to add it here.
    """
    required = set(healthy["covered"])
    unexpected = set(broken["unexpected"])
    return required, required & unexpected, sorted(unexpected - required), []


#: Each variant: a name, the edits that break it, which instrument scores it,
#: and how its verdict is compared against the healthy run's.
VARIANTS = [
    {
        "name": "naming",
        "instrument": NAMING,
        "score": naming_flips,
        "why": "the row-naming invariant (task 10.20, Gate C finding C-1) "
               "stops refusing. `_authorizeNaming` still runs and still "
               "reaches its verdict; the verdict is simply not acted on, so "
               "a row may name anybody. This is the control whose absence "
               "this instrument's header claims to have been watched for "
               "once, by hand, three months ago.",
        "patches": [
            # A field the compiler cannot fold into dead code, so the refusal
            # branch still compiles and only its condition changes — the same
            # idiom the three earlier harnesses use, for the same reason.
            patch(ROW_AUTHORIZER,
                  "class RowAuthorizer {",
                  "final bool _brokenControlAllowAnyName =\n"
                  "    DateTime.now().year > 2000;\n\n"
                  "class RowAuthorizer {"),
            patch(ROW_AUTHORIZER,
                  "    if (naming != null) return naming;",
                  "    if (naming != null && !_brokenControlAllowAnyName) "
                  "return naming;"),
        ],
    },
    {
        "name": "oracle",
        "instrument": ORACLE,
        "score": oracle_flips,
        "why": "the two controls that jointly close the key-claiming "
               "oracle are removed together: a row is looked up by its key "
               "**without** the project scope (task 10.35, undone), and a "
               "refusal then says whether that lookup found anything — "
               "`lost_to_server` where the row existed, `unauthorized` where "
               "it did not. §4.13's rule is that a refusal must not disclose "
               "the existence of what it refused, and this is finding H-3 put "
               "back on every table at once, which makes it a test of the "
               "sweep's breadth as well as of its sight.\n"
               "  **Two patches because the first run measured that one was "
               "not enough** (2026-09-05): with only the outcome change, one "
               "table of nine flipped. The other eight are project-scoped, so "
               "a stranger's claimed key is a *different* key and the server "
               "finds nothing to disclose. Knowing which of the two is "
               "load-bearing for which tables is worth more than the flip.\n"
               "  **Task 11.219 moved two more tables into that second "
               "group** (`Tags` and `Tag_Versions`, now project-scoped), so "
               "as of 2026-09-10 it is one table of ten by the outcome patch "
               "and nine by the scope patch. The ratio is the fact worth "
               "keeping: project scoping, not the refusal vocabulary, is what "
               "closes this oracle almost everywhere.",
        "patches": [
            # **Two patches, because two controls jointly hold this shut and
            # the first run proved it.** With only the outcome patch below,
            # exactly one table of nine flipped — `Users`, the global one.
            # For a project-scoped table the stranger's push carries their own
            # `project_id`, which is *part of the primary key* since task
            # 10.35, so the server looks up a key that genuinely does not
            # exist and there is nothing for a refusal to disclose. **Those
            # eight tables are indistinguishable by construction rather than
            # by any refusal**, which is worth knowing about what the sweep
            # proves. Nine of ten since task 11.219 gave `Tags` and
            # `Tag_Versions` a `project_id` too; `Users` is still the only
            # table the outcome patch alone can flip. So the first patch takes the scope column back out of
            # the lookup — task 10.35's fix, undone the way the server sees
            # it — and the second lets the refusal say what the lookup found.
            patch(SYNC_SERVICE,
                  "    final predicate = [\n"
                  "      for (var i = 0; i < table.primaryKey.length; i++)\n"
                  "        '${table.primaryKey[i]} = \\$${i + 1}',\n"
                  "    ].join(' AND ');\n"
                  "    final result = await session.execute(\n"
                  "      'SELECT * FROM ${quoted(table.name)} WHERE "
                  "$predicate',\n"
                  "      parameters: [for (final column in table.primaryKey) "
                  "row[column]],\n"
                  "    );",
                  # `length > 1` because `Projects` is keyed by the scope
                  # column *alone*; dropping it there would leave an empty
                  # predicate and a syntactically broken SELECT, which breaks
                  # the server rather than deleting a control. Measured on
                  # 2026-09-05: without this the victim's own first publish
                  # answered 403 and the sweep aborted before probing
                  # anything.
                  "    final lookupKey = table.primaryKey.length > 1\n"
                  "        ? table.primaryKey\n"
                  "              .where((c) => c != table.projectScopeColumn)\n"
                  "              .toList()\n"
                  "        : table.primaryKey;\n"
                  "    final predicate = [\n"
                  "      for (var i = 0; i < lookupKey.length; i++)\n"
                  "        '${lookupKey[i]} = \\$${i + 1}',\n"
                  "    ].join(' AND ');\n"
                  "    final result = await session.execute(\n"
                  "      'SELECT * FROM ${quoted(table.name)} WHERE "
                  "$predicate',\n"
                  "      parameters: [for (final column in lookupKey) "
                  "row[column]],\n"
                  "    );"),
            patch(SYNC_SERVICE,
                  "      if (!verdict.isAllowed) {\n"
                  "        outcomes['${item.table.name}/${item.key}'] =\n"
                  "            SyncRowOutcome.unauthorized;\n"
                  "        continue;\n"
                  "      }",
                  "      if (!verdict.isAllowed) {\n"
                  "        outcomes['${item.table.name}/${item.key}'] =\n"
                  "            existing != null\n"
                  "                ? SyncRowOutcome.lostToServer\n"
                  "                : SyncRowOutcome.unauthorized;\n"
                  "        continue;\n"
                  "      }"),
        ],
    },
]


def run(argv, **kwargs):
    return subprocess.run(argv, cwd=ROOT, text=True, **kwargs)


def wait_for(base, seconds=180):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/health", timeout=3) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, urllib.error.HTTPError, OSError):
            pass
        time.sleep(1)
    return False


def instrument(name, base, link_dir, out, compose=None):
    # Task 11.312: `gate_wire.preflight` — which every instrument this drives
    # calls before its first request — now refuses unless `COMPOSE` names the
    # stack actually holding `base`'s port (reusing task 11.310's
    # `port_holder`, the same guard the four `_broken_control.py` drills
    # already put in front of themselves). This file's own `check_stack` call
    # before the BROKEN call below already proved that; passing `COMPOSE`
    # through lets `preflight` reach the same answer for both phases instead
    # of trusting its default `tritrack-gate`, which the BROKEN phase is not.
    env = dict(os.environ, BASE=base, LINK_DIR=link_dir)
    if compose is not None:
        env["COMPOSE"] = compose
    env[JSON_ENV[name]] = out
    return subprocess.run(
        [sys.executable, os.path.join(ROOT, "scripts", name)],
        cwd=ROOT, env=env, capture_output=True, text=True,
    )


def main():
    failures = []
    healthy_runs = {}

    # ---- task 11.310: is the thing on the healthy port the throwaway stack?
    # The healthy half runs each instrument it drives — the full attack suite —
    # at HEALTHY_BASE, and until 2026-09-23 it did that to **whatever answered
    # there**. CI always has the `tritrack-gate` stack on 8080 and nothing else,
    # so it never mattered; on the Ubuntu VM, which also serves TriTrack, 8080 is
    # the real server holding real field data. So Docker is asked first, and
    # anything other than `tritrack-gate`'s own server — including Docker not
    # answering, and a COMPOSE line naming another project — ends the run here,
    # before any request is sent.
    refuse_unless_stack(
        HEALTHY_BASE, "tritrack-gate", compose=HEALTHY_COMPOSE,
        before=("running each instrument this drill drives at it, full "
                "attack suite included (the healthy phase)"),
    )

    # ---- half one: each instrument must come back clean against the real
    # server. Without this, "it went red on a broken build" is compatible with
    # an instrument that goes red on everything.
    print("=" * 72)
    print("HEALTHY RUN — the unmodified server. Must be clean.")
    print("=" * 72)
    for name in sorted({v["instrument"] for v in VARIANTS}):
        out = os.path.join(tempfile.gettempdir(), f"tt11127-healthy-{name}.json")
        result = instrument(name, HEALTHY_BASE, HEALTHY_LINK_DIR, out,
                            compose=HEALTHY_COMPOSE)
        if result.returncode != 0 or not os.path.exists(out):
            print(result.stdout[-3000:])
            print(result.stderr[-2000:])
            raise SystemExit(
                f"The healthy run of {name} is not clean, so nothing below "
                f"would mean anything. Fix that first — either the server or "
                f"the instrument."
            )
        healthy_runs[name] = json.load(open(out))
    for name, healthy in healthy_runs.items():
        if name == NAMING:
            print(f"  {name}: {len(healthy['checks'])} checks, "
                  f"{len(healthy['failed'])} failed.")
        else:
            print(f"  {name}: {len(healthy['covered'])} table(s) "
                  f"indistinguishable, {len(healthy['findings'])} recorded "
                  f"finding(s), {len(healthy['unexpected'])} unrecorded.")
    print()

    work = tempfile.mkdtemp(prefix="tt11127-broken-")
    tree = os.path.join(work, "tree")
    run(["git", "worktree", "add", "--detach", tree, "HEAD"], check=True,
        capture_output=True)
    link_dir = os.path.join(tree, ".e2e_magic_links")
    os.makedirs(link_dir, exist_ok=True)
    base = f"http://localhost:{BROKEN_PORT}"

    try:
        for variant in VARIANTS:
            project = f"tritrack-11127-{variant['name']}"
            compose = (
                f"docker compose -p {project} --env-file {ROOT}/.env "
                f"-f {tree}/docker-compose.yml "
                f"-f {tree}/docker-compose.e2e.yml"
            )
            print("=" * 72)
            print(f"BROKEN RUN — {variant['name']}: {variant['why']}")
            print("=" * 72)

            run(["git", "-C", tree, "checkout", "--", "."], check=True,
                capture_output=True)
            ok = True
            for path, old, new in variant["patches"]:
                full = os.path.join(tree, path)
                source = open(full).read()
                if source.count(old) != 1:
                    failures.append(
                        f"{variant['name']}: the text this variant patches "
                        f"appears {source.count(old)} times in {path}, not "
                        f"once. The server moved; update this file rather "
                        f"than letting a variant silently patch nothing."
                    )
                    ok = False
                    break
                open(full, "w").write(source.replace(old, new))
            if not ok:
                continue

            run(compose.split() + ["down", "-v"], capture_output=True)
            # Task 11.310: the broken stack is about to claim BROKEN_PORT.
            # Its own leftover stack (if a run died) is gone after the
            # `down` above; if anything else still holds the port, `up`
            # would fail and be reported as a variant that "would not
            # build" — say who holds it instead.
            held = check_free(BROKEN_PORT)
            if held:
                failures.append(f"{variant['name']}: {held}")
                continue
            built = run(compose.split() + ["up", "--build", "-d",
                                           "postgres", "server"],
                        capture_output=True,
                        env=dict(os.environ, SERVER_PORT=BROKEN_PORT))
            if built.returncode != 0:
                print(built.stdout[-3000:])
                print(built.stderr[-3000:])
                failures.append(
                    f"{variant['name']}: the broken variant would not build. "
                    f"A variant that does not compile measures nothing."
                )
                run(compose.split() + ["down", "-v"], capture_output=True)
                continue
            if not wait_for(base):
                print(run(compose.split() + ["logs", "server", "--tail", "30"],
                          capture_output=True).stdout)
                failures.append(
                    f"{variant['name']}: the broken server never became "
                    f"healthy at {base}."
                )
                run(compose.split() + ["down", "-v"], capture_output=True)
                continue

            # Task 11.310: attack only the stack this loop just built.
            # `wait_for` proves something answers at `base`; this proves
            # it is this variant's own compose project.
            not_ours = check_stack(base, project, compose=compose)
            if not_ours:
                failures.append(
                    f"{variant['name']}: not attacked — {not_ours}")
                run(compose.split() + ["down", "-v"], capture_output=True)
                continue

            name = variant["instrument"]
            out = os.path.join(work, f"{variant['name']}.json")
            result = instrument(name, base, link_dir, out, compose=compose)
            if not os.path.exists(out):
                print(result.stdout[-3000:])
                print(result.stderr[-2000:])
                print("---- the broken server's own log ----")
                print(run(compose.split() + ["logs", "server", "--tail", "30"],
                          capture_output=True).stdout)
                failures.append(
                    f"{variant['name']}: {name} did not finish against the "
                    f"broken server, so nothing was scored."
                )
                run(compose.split() + ["down", "-v"], capture_output=True)
                continue
            broken = json.load(open(out))
            required, flipped, extra, controls = variant["score"](
                healthy_runs[name], broken)
            missed = sorted(required - flipped)

            # A derivation that ends up requiring nothing agrees with itself
            # and proves nothing. Same rule as everywhere else: refuse an
            # empty subject rather than reporting full coverage of it.
            if not required:
                failures.append(
                    f"{variant['name']}: the required set came out empty, so "
                    f"this variant would pass whatever the instrument did. "
                    f"Either the healthy run found nothing to require, or the "
                    f"scoring function has stopped matching."
                )
                run(compose.split() + ["down", "-v"], capture_output=True)
                continue

            print(f"  {len(flipped)} of {len(required)} required verdict(s) "
                  f"changed")
            for what in sorted(flipped):
                print(f"  flipped   {what}")
            for what in missed:
                print(f"  BLIND     {what}")
            for what in extra:
                print(f"  also      {what}")
            if controls:
                print("  (positive controls that also failed, which a broken "
                      "server is expected to break:)")
                for what in controls:
                    print(f"    - {what}")
            if missed:
                failures.append(
                    f"{variant['name']}: {len(missed)} verdict(s) were "
                    f"unchanged against a server with that control removed — "
                    f"{missed}"
                )
            run(compose.split() + ["down", "-v"], capture_output=True)
            print()
    finally:
        run(["git", "worktree", "remove", "--force", tree],
            capture_output=True)
        shutil.rmtree(work, ignore_errors=True)

    print("=" * 72)
    if failures:
        print("THESE INSTRUMENTS ARE NOT KNOWN TO WORK:")
        for f in failures:
            print("  ! " + f)
        print("=" * 72)
        return 1
    print("Every required verdict changed against a server with that control "
          "removed, and the same instruments came back clean against the real "
          "one.")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# gate-instrument: none - a helper the suite runners hand a test report to; it has no subject of its own.
"""Did that test run actually reach the tests it was supposed to reach?

## Why this exists

Task 11.150 found `no_committed_secrets_test.dart` walking **one commit**
instead of 652, for weeks, green, because `actions/checkout@v4` with no
`fetch-depth` is a one-commit clone and a one-commit clone is silent. Task
11.155 audited the rest of this project's continuous-integration jobs for the
same shape — **a job narrowed by its environment or its invocation, reporting
success about a subject it never saw** — and found two more, neither of which
is about clone depth:

  * **`flutter test test/network --tags network` without `--run-skipped`
    skips every test and exits 0.** Measured on 2026-09-04, from the
    repository root: it prints "All tests skipped." and returns success.
    `dart_test.yaml` says the same thing in its own comment. So
    `tile-credit-freshness.yml` — the weekly job that asks three tile
    providers whether they still publish the credit strings this app is
    legally required to show — would be green having asked nobody, if that one
    flag were ever dropped.

  * **`dart test` exits 0 when every test it loaded was skipped, and when it
    loaded only some of the files it should have.** Measured on 2026-09-04.
    (It does *not* exit 0 having loaded nothing at all: a package with no
    tests, or a `--tags` selector matching none, exits 79. That half is loud,
    and an earlier draft of this file asserted otherwise before it was
    measured.) So `server-suite.yml`'s exit code distinguishes "the server
    suite passed" from "the server suite blew up", but not from "the server
    suite ran eleven of its fifty-five files".

Both are the fourth verdict `UNEXERCISED_CONTROLS.md` already names: *executed
constantly, by the right mechanism, against almost none of its subject.*

## What it asserts, and why none of it is a number somebody chose

Given a `package:test` JSON report (`--file-reporter=json:<path>`) and the
directory the tests live in, it asserts:

  1. The report parses and is not empty.
  2. **The set of suites the run loaded equals the set of `*_test.dart` files
     on disk under the test directory** — in both directions. A file that
     exists and did not run is the vacuity case; a suite in the report with no
     file on disk means the paths were resolved against the wrong root and the
     comparison proves nothing. The one exemption is a file whose own
     `@TestOn` annotation excludes the host this run is on: the runner never
     loads it and the report cannot mention it. That exemption is **read out
     of the file** rather than listed anywhere, and it is **per platform in
     both directions** — the same file is demanded again on the platform its
     annotation names. See the horizon note above `OS_SELECTORS` for exactly
     which `@TestOn` forms this understands and what it does with the rest.
  3. No suite failed to load.
  4. At least one test actually ran.
  5. With `--no-skips`, that nothing was skipped — for a job whose entire
     purpose is the tests that the default configuration skips.
  6. With `--declared-skips <file>`, that **the set of tests this run skipped
     is exactly the set somebody declared, with a reason, in that file** — in
     both directions. A skip nobody declared fails the run; a declared skip
     that nothing matched any more fails it too.

## Why the skips are a set and not a count (task 11.156)

The offline suite has a standing population of legitimate skips — every test
under `test/e2e/` and `test/network/`, which `dart_test.yaml` skips by tag so
that a bare `flutter test` needs no server and no network. The obvious guard
is to assert how many there are. **That is the same mistake as task 11.150's
`greaterThan(100)`**: a number a person chose, which stops describing anything
the moment the population changes and which cannot tell "one legitimate skip
was removed and one illegitimate one added" from "nothing happened".

The skips here are *nameable*, so they are declared instead. Each entry says
which suite (or suite prefix) is skipped and why, and both directions are
enforced. Nothing in the check is a magnitude.

The threshold in 11.150's original guard ruled out *zero* and let *vacuity*
through. There is no threshold here: every expectation is derived from the
filesystem the check is pointed at.

## And it says what it reached, every run

The last line is the finding, not the name of the check — CI keeps the tail of
a log, and a name in the tail has never told anybody anything. The counts print
on success as well as failure, so the number is where a person will see it
change.

Usage:
  python3 scripts/assert_suite_scope.py --report r.json --test-dir server/test \\
      --report-cwd server [--no-skips] [--declared-skips test/declared_skips.json]

`--test-dir` is relative to the repository root. `--report-cwd` is the
directory the test runner was invoked from, which is what the suite paths
inside the report are relative to; it defaults to the repository root.

Exit 0 = the run reached its whole subject. Exit 1 = it did not, or the check
could not tell — which is not the same as passing, and both must fail CI.
"""

import argparse
import json
import os
import re
import sys


def fail(*lines):
    for line in lines:
        print(line, file=sys.stderr)
    sys.exit(1)


def load_declared_skips(path):
    """Read the declaration file, or fail loudly. Never returns an empty set.

    A declaration that cannot be read, or that declares nothing, must not be
    treated as "nothing is allowed to skip" — it is a broken check, and a
    broken check is not a passing run.
    """
    if not os.path.isfile(path):
        fail(f"FAIL: {path} does not exist, so there is nothing to compare this",
             "run's skips against. That is a broken check, not a passing run.")
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except (json.JSONDecodeError, OSError) as err:
        fail(f"FAIL: {path} could not be read as JSON ({err}). A declaration",
             "nobody can parse declares nothing.")
    rules = doc.get("skips")
    if not isinstance(rules, list) or not rules:
        fail(f"FAIL: {path} has no non-empty \"skips\" list. An empty declaration",
             "would silently mean 'this run may skip nothing', which is a claim",
             "nobody made on purpose.")
    for index, rule in enumerate(rules):
        if not isinstance(rule, dict):
            fail(f"FAIL: {path} entry {index} is not an object.")
        if not str(rule.get("reason", "")).strip():
            fail(f"FAIL: {path} entry {index} has no reason. The point of declaring",
                 "a skip is the reason; an entry without one is a count with extra",
                 "punctuation.")
        if not (rule.get("suite_prefix") or rule.get("suite")):
            fail(f"FAIL: {path} entry {index} names neither \"suite_prefix\" nor",
                 "\"suite\", so it can never match anything.")
        if rule.get("suite_prefix") and rule.get("suite"):
            fail(f"FAIL: {path} entry {index} sets both \"suite_prefix\" and",
                 "\"suite\". Pick one — a rule that means two things matches by",
                 "accident.")
        if "runs_under_tz" in rule and not (
                isinstance(rule["runs_under_tz"], str) and rule["runs_under_tz"]):
            fail(f"FAIL: {path} entry {index} has a \"runs_under_tz\" that is not",
                 "a zone name, so it could never be compared with the run's zone.")
    return rules


def describe_rule(rule):
    where = (f"everything under {rule['suite_prefix']}"
             if rule.get("suite_prefix") else rule["suite"])
    if rule.get("test"):
        return f"{where} :: {rule['test']}"
    return where


def rule_matches(rule, suite_path, test_name):
    """Does this declared rule cover this one skipped test?

    A rule names a suite (exactly, or by prefix) and optionally the test within
    it. **`test` is what keeps a prefix rule honest**: `suite_prefix: "e2e/"`
    with `test: "(suite)"` declares "whole files under test/e2e/ are skipped by
    their tag" and nothing else, so somebody adding `skip:` to an individual
    test in that same directory is still an undeclared skip. A prefix with no
    `test` would declare the directory a place where skips need no reason.
    """
    prefix = rule.get("suite_prefix")
    if prefix is not None:
        if not (suite_path == prefix.rstrip("/") or suite_path.startswith(prefix)):
            return False
    elif suite_path != rule["suite"]:
        return False
    wanted = rule.get("test")
    return wanted is None or wanted == test_name


# --- @TestOn: a file that cannot load here (task 11.174) ----------------------
#
# `flutter test` does not *skip* a file whose `@TestOn` excludes the host — it
# never loads it at all, and the JSON report carries no `suite` event for it.
# That is a third category beside "ran" and "skipped", and until task 11.174 it
# read here as "a file went missing", which is the same shape as the vacuity
# this whole check exists to catch.
#
# **Derived, not declared.** The truth is one annotation inside the file, so a
# list of allowed-to-be-missing files would be a hand-kept copy of it — the
# defect this project has hit more often than any other. And it is derived
# **per platform in both directions**: `test/features/more/
# server_config_screen_macos_test.dart` is excused on Linux and *demanded* on
# macOS, where it can load.
#
# ## The parser's horizon, stated
#
# `@TestOn` takes a `package:boolean_selector` expression: identifiers, `!`,
# `&&`, `||`, parentheses, `x ? y : z`, and runtime variables beyond the
# operating system (`vm`, `browser`, `js`, `chrome`, `node`, …). **This parser
# understands exactly one form: a single bare identifier naming an operating
# system**, from OS_SELECTORS below. That is what this repository uses — one
# file, `@TestOn('mac-os')` — and every other form **fails the run loudly**
# rather than being guessed at. A `@TestOn` misread here would make a genuinely
# missing file look excused, which is the defect this check exists to refuse,
# one level down.
#
# Two further limits worth naming. The annotation is only looked for in the
# file's header — everything before the first `import`/`part`/`library`, which
# is where a library annotation must live — and comments are stripped before
# the search, because this very file's subject carries "`@TestOn`" in its own
# doc comment three times. And the host platform is taken from the machine
# running *this script*, which is the machine that ran the tests: both suite
# runners invoke it in the same shell, immediately after.

# The operating-system variables `package:test` defines, mapped to the set of
# them that is true on a given host. `posix` is true on every OS here except
# Windows. `android` and `ios` are never true of a `flutter test` host run;
# they are listed so that a file restricted to one is understood to be excluded
# rather than rejected as unparseable.
OS_SELECTORS = {"linux", "mac-os", "windows", "android", "ios", "posix"}

_HOST_BY_SYS_PLATFORM = {
    "linux": {"linux", "posix"},
    "darwin": {"mac-os", "posix"},
    "win32": {"windows"},
}

_TESTON_RE = re.compile(r"@TestOn\s*\(([^)]*)\)")
_BARE_STRING_RE = re.compile(r"""^\s*(['"])([^'"]*)\1\s*$""")


def host_selectors():
    """Which `@TestOn` operating-system names are true on this machine."""
    names = _HOST_BY_SYS_PLATFORM.get(sys.platform)
    if names is None:
        fail("FAIL: this check does not know which @TestOn platform names are",
             f"true on sys.platform={sys.platform!r}, so it cannot tell a file",
             "that cannot load here from one that went missing. Teach",
             "_HOST_BY_SYS_PLATFORM about it rather than assuming.")
    return names


def strip_dart_comments(text):
    """Remove `//` and `/* */` comments so a split/search cannot read prose.

    The file this was written for says "`@TestOn`" three times in its own doc
    comment before saying it once for real.
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end == -1 else end
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end == -1 else end + 2
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def platform_restriction(path, rel):
    """The OS name this file's `@TestOn` names, or None if it is unrestricted.

    Fails the whole run on any `@TestOn` form this parser does not understand —
    see the horizon note above.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as err:
        fail(f"FAIL: could not read {rel} to look for a @TestOn annotation",
             f"({err}). A file this check cannot read is a file it cannot",
             "reason about, which is not a passing run.")

    header = strip_dart_comments(text)
    # A library annotation must precede every directive, so the header is
    # everything before the first one. Stopping there also keeps a `@TestOn`
    # inside some later string literal out of the search.
    cut = len(header)
    for match in re.finditer(r"^\s*(import|export|part|library)\b", header,
                             re.MULTILINE):
        cut = match.start()
        break
    header = header[:cut]

    found = _TESTON_RE.findall(header)
    if not found:
        return None
    if len(found) > 1:
        fail(f"FAIL: {rel} has {len(found)} @TestOn annotations in its header.",
             "This check reads one; two mean something it does not model.")

    inner = found[0]
    bare = _BARE_STRING_RE.match(inner)
    if not bare:
        fail(f"FAIL: {rel} has a @TestOn this check cannot parse: @TestOn({inner.strip()}).",
             "It understands exactly one form -- a single quoted platform name,",
             f"one of: {', '.join(sorted(OS_SELECTORS))}. Everything else in",
             "package:boolean_selector's grammar (&&, ||, !, parentheses, ?:,",
             "and the non-OS variables vm/browser/js/chrome/node) is refused",
             "rather than guessed at, because a misread @TestOn makes a",
             "genuinely missing test file look excused. Widen this parser --",
             "and its horizon note -- deliberately.")

    name = bare.group(2)
    if name not in OS_SELECTORS:
        fail(f"FAIL: {rel} is @TestOn({name!r}), which is not an operating-system",
             f"name this check knows ({', '.join(sorted(OS_SELECTORS))}). It may",
             "be a valid package:test platform variable -- but this check can",
             "only decide 'that file cannot load on this host' for an OS, so it",
             "refuses rather than excusing a file it does not understand.")
    return name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", required=True)
    ap.add_argument("--test-dir", required=True)
    ap.add_argument("--report-cwd", default=".")
    ap.add_argument("--no-skips", action="store_true")
    ap.add_argument("--declared-skips", default=None,
                    help="JSON file declaring which tests this run is allowed to "
                         "skip, and why. Asserted as a set in both directions.")
    ap.add_argument("--label", default=None,
                    help="What this run is, for the log line. Defaults to --test-dir.")
    ap.add_argument("--tz", default=os.environ.get("TZ") or None,
                    help="The zone the suite was launched under (defaults to $TZ). "
                         "A declared skip with \"runs_under_tz\" equal to it is not "
                         "in force: that test must run here.")
    args = ap.parse_args()

    label = args.label or args.test_dir

    if not os.path.isdir(args.test_dir):
        fail(f"FAIL: {args.test_dir} is not a directory, so this check has no",
             "subject to compare the run against. That is a broken check, not a",
             "passing run.")

    on_disk = set()
    for root, _dirs, files in os.walk(args.test_dir):
        for name in files:
            if name.endswith("_test.dart"):
                on_disk.add(os.path.relpath(os.path.join(root, name), args.test_dir))
    if not on_disk:
        fail(f"FAIL: no *_test.dart under {args.test_dir}. A check that derives its",
             "expectation from an empty directory expects nothing and can never",
             "refuse anything.")

    # Which of those files this host cannot load at all (task 11.174), derived
    # from each file's own `@TestOn`. Platform-aware in both directions: on a
    # macOS run this set is empty and every one of them is demanded again.
    here = host_selectors()
    cannot_load_here = {}   # rel path -> the OS its @TestOn names
    for rel in sorted(on_disk):
        name = platform_restriction(os.path.join(args.test_dir, rel), rel)
        if name is not None and name not in here:
            cannot_load_here[rel] = name

    if not os.path.isfile(args.report):
        fail(f"FAIL: {args.report} does not exist. The run was asked for a JSON",
             "report and did not produce one, so nothing is known about what it",
             "reached.")

    suites = {}          # suite id -> path relative to --test-dir
    ran = 0
    skipped = 0
    load_errors = []
    test_ids_of_suite = {}   # test id -> suite id
    test_names = {}          # test id -> test name
    skipped_ids = []         # test ids whose testDone said skipped
    seen_any_line = False

    dir_from_cwd = os.path.relpath(args.test_dir, args.report_cwd)

    with open(args.report, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            seen_any_line = True
            kind = event.get("type")
            if kind == "suite":
                suite = event["suite"]
                path = suite.get("path")
                if not path:
                    continue
                rel = os.path.relpath(path, os.path.join(args.report_cwd, dir_from_cwd)) \
                    if os.path.isabs(path) else os.path.relpath(path, dir_from_cwd)
                suites[suite["id"]] = rel
            elif kind == "testStart":
                test = event["test"]
                test_ids_of_suite[test["id"]] = test.get("suiteID")
                test_names[test["id"]] = test.get("name", "<unnamed>")
            elif kind == "testDone":
                if event.get("hidden"):
                    continue
                if event.get("skipped"):
                    skipped += 1
                    skipped_ids.append(event.get("testID"))
                else:
                    ran += 1
            elif kind == "error":
                # A suite that fails to load reports an error against a test
                # whose suite never started properly; keep the message.
                load_errors.append(event.get("error", "").splitlines()[:1])

    if not seen_any_line:
        fail(f"FAIL: {args.report} held no JSON events at all. The reporter did not",
             "run, so this check cannot say anything about what the suite reached.")

    loaded = set(suites.values())
    # A file whose own `@TestOn` excludes this host is not missing — the runner
    # never loads it, so the report holds no `suite` event for it. Excused here
    # and nowhere else: the same file is in `missing` on the platform it names.
    missing = sorted(on_disk - loaded - set(cannot_load_here))
    unexpected = sorted(loaded - on_disk)
    # The parser said "this cannot load here" and it loaded. That is the parser
    # being wrong, and a wrong parser excuses genuinely missing files.
    loaded_anyway = sorted(set(cannot_load_here) & loaded)

    problems = []
    if missing:
        problems.append(
            f"{len(missing)} test file(s) under {args.test_dir} were never loaded by "
            f"the run: {', '.join(missing[:10])}"
            + (" …" if len(missing) > 10 else ""))
    if loaded_anyway:
        problems.append(
            f"{len(loaded_anyway)} file(s) whose @TestOn this check read as "
            f"excluding this host ({'/'.join(sorted(here))}) were loaded anyway: "
            + ", ".join(f"{rel} (@TestOn '{cannot_load_here[rel]}')"
                        for rel in loaded_anyway)
            + ". This check's @TestOn parser is wrong, and a wrong parser here "
              "excuses a genuinely missing test file. Fix the parser before "
              "trusting any other line of this report.")
    if unexpected:
        problems.append(
            f"{len(unexpected)} suite(s) in the report do not exist under "
            f"{args.test_dir}: {', '.join(unexpected[:10])}"
            + (" …" if len(unexpected) > 10 else "")
            + ". The paths were resolved against the wrong root, so the "
              "comparison above proves nothing either way — check --report-cwd.")
    if ran == 0:
        problems.append(
            "no test actually ran. `dart test` and `flutter test` both exit 0 "
            "when every test they loaded was skipped, so a green run here is "
            "not evidence that anything was executed.")
    if args.no_skips and skipped:
        problems.append(
            f"{skipped} test(s) were skipped, and this run exists to execute "
            "exactly the tests the default configuration skips. Check that "
            "--run-skipped is still on the command line.")

    # The skips as a declared set, in both directions (task 11.156). Not a
    # count: see this file's header for why a count is the defect, not the fix.
    declared_note = ""
    if args.declared_skips:
        rules = load_declared_skips(args.declared_skips)
        # **Task 11.326: a rule can be zone-shaped.** A test that skips itself
        # unless the process started under one zone (the clock matrix in
        # animals_screen_test.dart) is a declared skip everywhere else and a
        # demanded run there. Both directions stay enforced: under that zone a
        # skip of it is undeclared, and elsewhere a run of it leaves the rule
        # matching nothing. The match is on the zone's name and the test checks
        # its UTC offset, so a different zone that happens to share the offset
        # that day fails loudly as a stale rule rather than passing quietly.
        not_in_force = [r for r in rules if r.get("runs_under_tz")
                        and r["runs_under_tz"] == args.tz]
        rules = [r for r in rules if r not in not_in_force]
        matched_by_rule = [0] * len(rules)
        undeclared = []
        for test_id in skipped_ids:
            suite_path = suites.get(test_ids_of_suite.get(test_id))
            test_name = test_names.get(test_id, "<unnamed>")
            if suite_path is None:
                undeclared.append(f"<unknown suite> :: {test_name}")
                continue
            hit = False
            for index, rule in enumerate(rules):
                if rule_matches(rule, suite_path, test_name):
                    matched_by_rule[index] += 1
                    hit = True
            if not hit:
                undeclared.append(f"{suite_path} :: {test_name}")

        if undeclared:
            problems.append(
                f"{len(undeclared)} skipped test(s) that nobody declared in "
                f"{args.declared_skips}: " + "; ".join(sorted(undeclared)[:10])
                + (" …" if len(undeclared) > 10 else "")
                + ". A skip is a test that did not run; if these are meant to "
                  "be skipped, add them there with a reason, and if they are "
                  "not, that is the finding.")

        stale = [describe_rule(rules[i]) for i, n in enumerate(matched_by_rule) if n == 0]
        if stale:
            problems.append(
                f"{len(stale)} declared skip(s) in {args.declared_skips} matched "
                "nothing in this run: " + "; ".join(stale)
                + ". Either the tests they name are gone, or they are no longer "
                  "being skipped — in both cases the declaration is now a "
                  "description of something that does not exist and must be "
                  "deleted.")

        declared_note = (f"; {len(rules)} declared skip rule(s), "
                         f"{len(undeclared)} undeclared skip(s), "
                         f"{len(stale)} stale rule(s)")
        if not_in_force:
            declared_note += (f", {len(not_in_force)} rule(s) not in force under "
                              f"TZ={args.tz} (those tests had to run)")

    excluded_note = ""
    if cannot_load_here:
        excluded_note = ("; " + str(len(cannot_load_here))
                         + " not loadable on this host by its own @TestOn ("
                         + ", ".join(f"{rel} needs {name}"
                                     for rel, name in sorted(cannot_load_here.items()))
                         + ")")

    print(f"suite scope [{label}]: {len(loaded)} suite(s) loaded of "
          f"{len(on_disk)} *_test.dart on disk{excluded_note}; {ran} test(s) ran, "
          f"{skipped} skipped{declared_note}; report {args.report}, "
          f"test dir {args.test_dir}, runner cwd {args.report_cwd}, "
          f"host {'/'.join(sorted(here))}")
    sys.stdout.flush()

    if problems:
        print("SUITE SCOPE FAILED: " + problems[0], file=sys.stderr)
        for extra in problems[1:]:
            print("  also: " + extra, file=sys.stderr)
        sys.exit(1)

    demanded = len(on_disk) - len(cannot_load_here)
    print(f"suite scope PASS: the run reached all {demanded} test file(s) "
          f"under {args.test_dir} that can load on this host"
          + (f" ({len(cannot_load_here)} of {len(on_disk)} cannot, by their own "
             "@TestOn, and are demanded on the platform they name)"
             if cannot_load_here else "")
          + f" and executed {ran} test(s)"
          + (f", skipping {skipped}" if skipped else ", skipping none") + ".")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
# gate-instrument: verify_instrument_unchecked_returns verify_instrument_unchecked_returns_selftest
"""Detects `Cf`'s unchecked-return class across every gate instrument
(`TriTrack_Security_Model.md` §12.7, §11.12; task 10.65).

The class, stated precisely: a command's exit status is discarded (bash
`... || true` inside a captured `$(...)`), and the resulting empty/blank
output is then treated the SAME WAY a genuine "nothing found" result would
be — so "I could not run the check at all" and "I ran the check and it
confirmed the safe case" become indistinguishable. `gate_c_adversarial_pass.py`'s
`Cf` had this shape (task 10.54 fixed it there). `verify_tls_termination.sh`'s
step 6 had it independently, reintroduced by the very 10.54 commit that fixed
`Cf` elsewhere in the same file (task 10.65's finding — see the fix at that
line, tagged with this file's name).

Not every `|| true` is this defect — most in this directory are best-effort
teardown (`docker compose down ... || true`) where nothing downstream reads
the result at all, and `backup_restore_drill.sh`'s `live_canary()` swallows
deliberately BUT every one of its ten callers compares the result against the
literal `"1"`, so a swallowed failure (which yields "") still reads as a
failure, not a false pass — see that function's own comment. The dangerous
combination specifically is: output captured via a swallowed exit status,
then tested with `-z` (or `= ""`) — "empty means pass" is exactly what turns
"couldn't tell" into "confirmed clear."

This is a static check, deliberately: cheap enough to run on every commit
(no Docker, no server), which is the point — the class should be caught by
a run, not re-discovered at the next gate by a human re-reading every
instrument line by line.

**Scope, stated rather than implied (task 10.78, finding K-11a).** Bash only,
and only the two directory names listed in [DEFAULT_DIRS] below — a prior
version scanned `scripts/*.sh` alone, non-recursively, so `server/backup/
backup.sh` and `restore.sh` (the exact files task 10.78 found the
check-then-`CREATE ROLE` race in, finding K-9) were never read, and neither
was any Python instrument, including `gate_c_adversarial_pass.py` — the file
`Cf` (the defect this detector exists for) was originally found in. Its own
"0 findings" line used to claim a clean sweep while only ever having read a
subset; [run] now names exactly which directories it read, and this docstring
says plainly what kind of file and what idiom it does not cover, rather than
leaving either to be discovered as a gap by the next gate.

Usage:
    python3 scripts/verify_instrument_unchecked_returns.py [DIR ...]

Exits non-zero if any instrument file is flagged, if any DIR does not exist
or is not readable, or if the argument list is empty and none of the
default directories can be found (the tool's own machinery failing, rather
than the thing it inspects — see `--selftest`).

Run with --selftest to prove both halves live: that this detects the exact
defect shape when present (against a fixture, including the inverted
`[ -n "$VAR" ] && fail` spelling), and that it fails loudly — not silently
reports "0 findings" — when its own inputs are broken (an unreadable/missing
target).
"""
import re
import sys

# `VAR="$(... || true)"` (or `2>/dev/null || true` inside the substitution),
# single logical line — every real instance found in this repo is written
# this way. Captures the assigned variable name.
SWALLOW_ASSIGN = re.compile(
    r'^\s*(?:export\s+)?(\w+)=\$?"\$\([^\n]*\|\|\s*true\s*\)"'
)

# "empty means pass" tests against that variable: `[ -z "$VAR" ]` or
# `[ "$VAR" = "" ]` / `[ "$VAR" == "" ]`.
EMPTY_IS_PASS = re.compile(
    r'-z\s+"?\$\{?%(var)s\}?"?'
    r'|"\$\{?%(var)s\}?"\s*==?\s*""'
)

# The same "empty means pass" defect, spelled the other way round: fails
# only when the variable is NON-empty (`[ -n "$VAR" ] && fail ...`), which
# leaves emptiness — including "the command never ran" — to pass through
# unnoticed exactly like the `-z`/`==""` shape above. Task 10.78, finding
# K-11a: named explicitly as the spelling the original regex missed, and
# called "the dominant idiom in this directory" for `-n` generally — which is
# why this pattern requires the `&&` (or `; then`) chained straight to
# `fail`/`exit` rather than flagging every bare `-n "$VAR"`. The safe, common
# idiom in this same directory is `[ -n "$VAR" ] || fail ...` (fails on
# EMPTY, the correct direction) — a bare-`-n` match would flag that
# legitimate pattern on every occurrence.
NONEMPTY_AND_FAIL_IS_PASS = re.compile(
    r'-n\s+"?\$\{?%(var)s\}?"?\s*\]?\s*(?:&&|;\s*then)\s*'
    r'(?:\S+\s+)*(?:fail|exit)\b'
)

# L-4 / task 10.95 (L-13): the same defect with no intermediate variable at
# all — `[ -z "$(cmd || true)" ] || fail ...` — which SWALLOW_ASSIGN cannot
# see because there is nothing named to search a later line for. This is the
# exact shape `backup_restore_drill.sh:764` had (task 10.91's own .part
# check): pointed at a nonexistent directory, `ls -A "$DIR"/*.part 2>/dev/null
# || true` produces "", and `-z ""` reads "confirmed clear" — one physical
# line, no variable, and the old detector's "0 findings" said nothing about
# it. Matches `-z "$(... || true ...)"` and `"$(... || true ...)" == ""` on a
# single line, whether or not the substitution is itself assigned to a
# variable first.
INLINE_EMPTY_IS_PASS = re.compile(
    r'-z\s+"\$\([^\n]*?\|\|\s*true\s*\)"'
    r'|"\$\([^\n]*?\|\|\s*true\s*\)"\s*==?\s*""'
)

# An explicit, adjacent justification suppresses the finding — the same
# "either fixed or named" discipline task 10.66 requires of remediations,
# applied to this linter's own false-positive path.
REVIEWED_TAG = "swallow-reviewed:"


def scan_file(path, text):
    findings = []
    lines = text.splitlines()
    for i, line in enumerate(lines):
        m = SWALLOW_ASSIGN.match(line)
        if not m:
            continue
        var = m.group(1)
        dangerous_patterns = (
            ("`-z`/`= \"\"`",
             re.compile(EMPTY_IS_PASS.pattern % {"var": re.escape(var)})),
            ("`-n \"$%s\" && fail`" % var,
             re.compile(NONEMPTY_AND_FAIL_IS_PASS.pattern % {"var": re.escape(var)})),
        )
        # Search the rest of the file (bash has no block scoping) for a
        # dangerous "empty means pass" use of this variable, in either
        # spelling.
        for j in range(i + 1, len(lines)):
            matched_spellings = [
                label for label, pattern in dangerous_patterns
                if pattern.search(lines[j])
            ]
            if not matched_spellings:
                continue
            window = "\n".join(lines[max(0, i - 6):j + 2])
            if REVIEWED_TAG in window:
                continue
            spelling = " / ".join(matched_spellings)
            findings.append((
                path, i + 1, j + 1, var,
                f"line {i + 1} discards {var}'s command's exit status "
                f"(`|| true`), and line {j + 1} treats an empty {var} as "
                f"PASS ({spelling}). A broken command (wrong project, "
                f"missing file, docker unreachable) also produces an empty "
                f"{var} and would pass identically to a genuine negative "
                f"result. Capture the exit status separately and check it, "
                f"or tag the site `# {REVIEWED_TAG} <why this can't happen "
                f"here>` if it is genuinely safe."
            ))

    for i, line in enumerate(lines):
        if not INLINE_EMPTY_IS_PASS.search(line):
            continue
        window = "\n".join(lines[max(0, i - 3):i + 1])
        if REVIEWED_TAG in window:
            continue
        findings.append((
            path, i + 1, i + 1, "<inline>",
            f"line {i + 1} both discards a command's exit status (`|| true`) "
            f"inside `$(...)` and treats that substitution's emptiness as "
            f"PASS, on one line with no intermediate variable. A broken "
            f"command (missing directory, docker unreachable) also produces "
            f"empty output and would pass identically to a genuine negative "
            f"result. Capture the exit status separately and check it, or "
            f"tag the site `# {REVIEWED_TAG} <why this can't happen here>` "
            f"if it is genuinely safe."
        ))
    return findings


# Task 10.78, finding K-11a: the two real bash directories a gate instrument
# lives in. `server/backup/` was entirely unread before this task — the
# check-then-`CREATE ROLE` race (K-9) sat in a file this detector's own class
# exists to help catch classes of shell defect in, and never saw it because
# nothing ever asked it to look there.
DEFAULT_DIRS = ("scripts", "server/backup")


def run(paths):
    if not paths:
        sys.exit("verify_instrument_unchecked_returns.py: no paths given")
    all_findings = []
    for p in paths:
        if not p.is_dir():
            sys.exit(f"verify_instrument_unchecked_returns.py: {p} is not a "
                      f"directory — cannot scan it. This is the tool's own "
                      f"input being broken, not a clean codebase; a run "
                      f"that cannot read its target must not report 0 "
                      f"findings.")
        sh_files = sorted(p.glob("*.sh"))
        if not sh_files:
            sys.exit(f"verify_instrument_unchecked_returns.py: {p} contains "
                      f"no *.sh files — expected at least the gate "
                      f"instruments. A zero-file scan reporting 0 findings "
                      f"is indistinguishable from a clean one; refusing to "
                      f"call that a pass.")
        for f in sh_files:
            try:
                text = f.read_text()
            except OSError as e:
                sys.exit(f"verify_instrument_unchecked_returns.py: could not "
                          f"read {f}: {e}")
            all_findings.extend(scan_file(f, text))
    return all_findings


def main():
    import pathlib
    args = sys.argv[1:]
    if args and args[0] == "--selftest":
        selftest()
        return

    root = pathlib.Path(__file__).resolve().parent.parent
    paths = [pathlib.Path(a) for a in args] or [root / d for d in DEFAULT_DIRS]
    findings = run(paths)
    scanned = ", ".join(str(p) for p in paths)
    if findings:
        print(f"{len(findings)} UNCHECKED-RETURN FINDING(S):")
        for path, assign_line, use_line, var, detail in findings:
            print(f"  {path}:{assign_line}  {detail}")
        sys.exit(1)
    # Named explicitly (task 10.78, finding K-11a) rather than "N
    # directories": a count invites exactly the "0 findings ... claims the
    # set" over-reading the finding named. Bash only — no Python instrument
    # (gate_c_adversarial_pass.py included) is read by this check.
    print(f"0 findings in *.sh files under: {scanned} — no instrument in "
          f"those bash scripts swallows a command's exit status and then "
          f"reads the resulting emptiness as a pass. Python instruments are "
          f"out of this check's scope.")


def selftest():
    """Both halves, demonstrated: (1) this detects the defect shape when
    it's genuinely present, against a fixture reproducing the exact
    verify_tls_termination.sh / Cf shape; (2) this fails loudly rather than
    silently passing when ITS OWN input is broken (missing directory, empty
    directory)."""
    import pathlib
    import tempfile

    ok = True

    # Half 1: subject broken — the detector must flag a real instance of
    # the class.
    with tempfile.TemporaryDirectory() as d:
        bad = pathlib.Path(d) / "verify_fixture_bad.sh"
        bad.write_text(
            'PUBLISHED="$(docker compose port server 8080 2>/dev/null || true)"\n'
            '[ -z "$PUBLISHED" ] || fail "published"\n'
        )
        findings = run([pathlib.Path(d)])
        if findings:
            print("PASS  half 1 (subject broken): flagged the known-bad "
                  f"fixture — {findings[0][4]}")
        else:
            print("FAIL  half 1 (subject broken): the known-bad fixture "
                  "(the exact verify_tls_termination.sh shape) was not "
                  "flagged — this detector cannot catch the class it exists "
                  "for.")
            ok = False

    # Half 1b (task 10.78, finding K-11a): the inverted spelling —
    # `[ -n "$VAR" ] && fail` — is the same defect and must be caught too,
    # not just the `-z`/`==""` spelling half 1 already proves.
    with tempfile.TemporaryDirectory() as d:
        inverted = pathlib.Path(d) / "verify_fixture_inverted.sh"
        inverted.write_text(
            'PUBLISHED="$(docker compose port server 8080 2>/dev/null || true)"\n'
            '[ -n "$PUBLISHED" ] && fail "published"\n'
        )
        findings = run([pathlib.Path(d)])
        if findings:
            print("PASS  half 1b (inverted spelling): flagged "
                  f"`-n ... && fail` — {findings[0][4]}")
        else:
            print("FAIL  half 1b (inverted spelling): "
                  "`[ -n \"$VAR\" ] && fail` was not flagged — the same "
                  "empty-means-pass defect, spelled the other way round, "
                  "which finding K-11a named as a live gap.")
            ok = False

    # Half 1c (task 10.95, L-13): the inline shape with no intermediate
    # variable at all — the exact bug backup_restore_drill.sh:764 had.
    with tempfile.TemporaryDirectory() as d:
        inline = pathlib.Path(d) / "verify_fixture_inline.sh"
        inline.write_text(
            '[ -z "$(ls -A "$TRITRACK_BACKUP_DIR"/*.part 2>/dev/null '
            '|| true)" ] \\\n'
            '  || fail "a .part file survived a failed run"\n'
        )
        findings = run([pathlib.Path(d)])
        if findings:
            print("PASS  half 1c (inline, no variable): flagged the "
                  f"backup_restore_drill.sh:764 shape — {findings[0][4]}")
        else:
            print("FAIL  half 1c (inline, no variable): the exact "
                  "pre-fix backup_restore_drill.sh:764 shape was not "
                  "flagged.")
            ok = False

    # A clean/reviewed variant must NOT be flagged — the detector must not
    # cry wolf on the safe patterns already in this repo (live_canary's
    # sentinel-comparison shape, an explicitly reviewed swallow, and the
    # `-n ... || fail` idiom — fails on EMPTY, the correct direction, and is
    # the dominant `-n` usage in scripts/ per finding K-11a).
    with tempfile.TemporaryDirectory() as d:
        clean = pathlib.Path(d) / "verify_fixture_clean.sh"
        clean.write_text(
            'OUT="$(psql_drill ... 2>/dev/null || true)"\n'
            '[ "$(printf %s "$OUT")" = "1" ] || fail "canary gone"\n'
            'REVIEWED="$(risky_cmd 2>/dev/null || true)"\n'
            '# swallow-reviewed: best-effort probe, only ever used for a log line\n'
            '[ -z "$REVIEWED" ] || echo "note: $REVIEWED"\n'
            'RECIPIENT="$(derive_recipient 2>/dev/null || true)"\n'
            '[ -n "$RECIPIENT" ] || fail "could not derive a recipient"\n'
        )
        findings = run([pathlib.Path(d)])
        if not findings:
            print("PASS  clean fixture (sentinel comparison, explicit "
                  "review tag, and the safe `-n ... || fail` idiom): "
                  "correctly not flagged")
        else:
            print(f"FAIL  clean fixture was flagged incorrectly: {findings}")
            ok = False

    # Half 2: the detector's OWN tooling broken — a target it cannot read
    # must fail loudly, not report "0 findings, clean."
    import subprocess
    script = str(pathlib.Path(__file__).resolve())
    missing = subprocess.run(
        [sys.executable, script, "/nonexistent/path/for/selftest"],
        capture_output=True, text=True)
    if missing.returncode != 0:
        print("PASS  half 2a (own tooling broken): a nonexistent target "
              f"directory exits non-zero (exit {missing.returncode}), not "
              "0 findings")
    else:
        print("FAIL  half 2a (own tooling broken): a nonexistent target "
              "directory exited 0 — indistinguishable from a genuinely "
              "clean scan of a real directory.")
        ok = False

    with tempfile.TemporaryDirectory() as d:
        empty = subprocess.run(
            [sys.executable, script, d],
            capture_output=True, text=True)
        if empty.returncode != 0:
            print("PASS  half 2b (own tooling broken): a directory with no "
                  f"*.sh files exits non-zero (exit {empty.returncode}), not "
                  "0 findings")
        else:
            print("FAIL  half 2b (own tooling broken): an empty directory "
                  "exited 0 — indistinguishable from a genuinely clean scan.")
            ok = False

    print()
    if ok:
        print("SELFTEST PASSED: both halves demonstrated.")
        sys.exit(0)
    print("SELFTEST FAILED — see above.")
    sys.exit(1)


if __name__ == "__main__":
    main()

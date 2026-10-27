#!/usr/bin/env python3
# gate-instrument: none - derives the words gate_smoke_test.sh greps a failing
# instrument's log for; it reads source and runs nothing itself.
"""Which words mean "this is the line that explains the failure" (task 11.312,
item 4).

`gate_smoke_test.sh`'s `run_instrument` used to grep a failing instrument's
log for the hand-typed literal `fail|error|admitted|traceback`. The
Deployments existence-oracle sweep's own refusal starts with `ABORT:`
(`verify_h3_existence_oracle_sweep.py`), which was never in that list, so a
red run's summary reported "no FAIL/ERROR/ADMITTED line found" and fell back
to the log's last 40 lines — the right lines reached the screen anyway, by
the fallback, not by being found. Task 11.310 found the instance; this
derives the class, per entry 1 of `CLAUDE_DOCS/DEFECT_VOCABULARY.md`
("an instrument's last words must be a finding, not a name") — a fifth word
picked by hand today is a sixth missed word tomorrow, from whichever
instrument is added next.

**What is derived, and how.** Every Python instrument this gate runs
concludes a failure the same, reliable way: `raise SystemExit("...")` or
`sys.exit("...")` with a **string** argument — which is not a convention this
project invented, it is what the two calls *mean* in Python: a string
argument is printed to stderr and the process exits 1, always. So scanning
every `scripts/*.py` file for exactly that shape and reading the ALL-CAPS
word each message opens with (`ABORT:`, `INSTRUMENT DEFECT:`, `REFUSED:`, …)
finds every word one of these scripts uses to open a failure message,
without needing to know in advance what a future instrument will call its
own. `PREFLIGHT ABORT:` contributes `PREFLIGHT` as well as `ABORT`; harmless
— the two are ORed into the same regex either way.

**Three instruments have no `scripts/*.py` of their own to scan — task 11.312
round 2, item 3.** `audit_retention_status.sh`, `project_destruction_status.sh`
and `tombstone_retention_status.sh` each run one compiled Dart entrypoint
(`server/bin/audit_retention.dart`, `server/bin/project_destruction.dart`,
`server/bin/tombstone_retention.dart` — read from `server/Dockerfile`'s own
`dart compile exe` lines and the `entrypoint:` each names in
`docker-compose.yml`) and print through it, not through a Python
`SystemExit`. Read start to finish, every `stderr.writeln(...)` call in these
three files opens a failure conclusion — the connection-failed and
query-failed branches of `--check`, and the loop's own `SWEEP FAILED` —
there is no other use of `stderr.writeln` in any of the three. Dart has no
single-call contract as tight as Python's, so this is read by hand once,
here, rather than guessed at again the next time one of these three grows a
new failure line: every leading run of ALL-CAPS words a `stderr.writeln`
message opens with (`AUDIT RETENTION UNKNOWN`, `PROJECT DELETION UNKNOWN`,
`TOMBSTONE RETENTION UNKNOWN`, `PURGE FAILED`, `SWEEP FAILED`, …) is derived
the same way, from these three named files only — not every `server/bin/
*.dart`, since nothing here has read whether that convention holds
elsewhere.

**What is a fixed floor instead, and why it cannot be derived the same way:**

  - `FAIL` — the dominant convention in every `scripts/*.sh` instrument
    (`gate_drill_stack_up.sh`, `verify_deployment_refusal_matrix.sh`,
    `verify_merged_manifest_capabilities.sh`, and `gate_smoke_test.sh`
    itself all open a failure with `echo "FAIL: ..."`). Bash has no
    equivalent of Python's "a string argument to exit always means failure"
    contract — a plain `echo` can print anything on any path — so scanning
    `scripts/*.sh` the same way this file scans `scripts/*.py` finds `PASS`
    and `COVERAGE ONLY` and `SELFTEST PASSED` right alongside `FAIL`
    (measured while writing this: `grep -noE 'echo +"[A-Z][A-Z ]{2,}:'
    scripts/*.sh`), because they are the same shape of line and bash cannot
    tell them apart the way Python's own `exit` semantics can. Deriving from
    that shape would put `PASS` in a regex meant to find failures. `FAIL`
    stays a fixed word instead of a guess at a shape that would separate the
    two reliably.
  - `ERROR` — never spelled out in full caps by any of these scripts' own
    source (`grep -rn '"ERROR' scripts/*.py scripts/*.sh` finds nothing);
    it catches an uncaught `*Error` exception's class name in a traceback,
    which Python spells in mixed case, not this project's own convention.
  - `ADMITTED` — the wire instruments' own outcome word for an attack that
    should have been refused and was not, printed inside a per-check
    reporting loop (`print(f"{'  refused ' if refused else '  ADMITTED'} …")`
    in `verify_11_49_server_reads.py`, `verify_11_9_team_surface.py`, and
    the same shape in `verify_11_24_attribution.py` and
    `verify_11_85_broken_control.py`'s required-attack lists) rather than at
    a `SystemExit`/`sys.exit` call, so the derivation below does not reach
    it. Kept as a fixed word for the reason C-2's whole existence argues for
    in the first place: this is the one outcome a red gate must never fail
    to surface.
  - `TRACEBACK` — the literal banner the Python interpreter itself prints
    above an uncaught exception ("Traceback (most recent call last):"). It
    is not a string in any of these scripts' own source at all; it is
    Python's, always spelled exactly that way, so there is nothing to derive
    it from and no way for it to drift.

Usage:

    python3 scripts/lib/gate_log_markers.py            # one word per line
    python3 scripts/lib/gate_log_markers.py --regex     # lowercase, `|`-joined
"""
import glob
import io
import os
import re
import sys
import tokenize

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# See the module docstring for why each of these four is a fixed floor
# rather than derived the same way as the Python `SystemExit`/`sys.exit` set
# below.
FIXED_FLOOR = frozenset({"FAIL", "ERROR", "ADMITTED", "TRACEBACK"})

_LEADING_WORD = re.compile(r"^\s*([A-Z][A-Z]{3,})\b")


def _exit_call_words(path):
    """ALL-CAPS words opening a string given to `raise SystemExit(...)` or
    `sys.exit(...)` in one `scripts/*.py` file.

    A string argument to either always means the process prints that string
    and exits non-zero — that is Python's own contract for the two calls,
    not a convention this project chose — so every word found this way names
    a real failure conclusion, never a pass.
    """
    words = set()
    try:
        source = open(path, encoding="utf-8").read()
        tokens = list(tokenize.generate_tokens(io.StringIO(source).readline))
    except (OSError, SyntaxError, tokenize.TokenizeError, UnicodeDecodeError):
        return words
    for i, tok in enumerate(tokens):
        is_system_exit = tok.type == tokenize.NAME and tok.string == "SystemExit"
        is_sys_exit = (
            tok.type == tokenize.NAME and tok.string == "exit"
            and i >= 2 and tokens[i - 1].string == "."
            and tokens[i - 2].string == "sys"
        )
        if not (is_system_exit or is_sys_exit):
            continue
        depth = 0
        started = False
        for t in tokens[i:i + 60]:
            if t.type == tokenize.OP and t.string == "(":
                depth += 1
                started = True
            elif t.type == tokenize.OP and t.string == ")":
                depth -= 1
                if started and depth == 0:
                    break
            elif started and t.type == tokenize.STRING:
                try:
                    message = eval(t.string)  # noqa: S307 — a literal from our own source
                except Exception:
                    break
                match = _LEADING_WORD.match(message)
                if match:
                    words.add(match.group(1))
                break
    return words


# The three compiled entrypoints `audit_retention_status.sh`,
# `project_destruction_status.sh` and `tombstone_retention_status.sh` each
# run — see the module docstring for how this list was read, not guessed.
DART_STDERR_SOURCES = (
    "server/bin/audit_retention.dart",
    "server/bin/project_destruction.dart",
    "server/bin/tombstone_retention.dart",
)

# A `stderr.writeln(` call whose arguments are one or more adjacent
# single-quoted string literals (Dart's implicit string concatenation),
# with or without a trailing comma before the closing `)`.
_DART_WRITELN = re.compile(r"stderr\.writeln\(\s*((?:'[^'\n]*'\s*)+),?\s*\)")
_DART_STRING = re.compile(r"'([^']*)'")
_DART_LEADING_RUN = re.compile(r"^([A-Z][A-Z ]*[A-Z])(?:\s|$)")


def _dart_stderr_words(path):
    """ALL-CAPS words opening a `stderr.writeln(...)` message in one Dart file.

    See the module docstring: every `stderr.writeln` in the three files this
    is called on is a failure conclusion, read by hand rather than derived
    from a language-level contract the way Python's `SystemExit` is.
    """
    words = set()
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return words
    for match in _DART_WRITELN.finditer(text):
        message = "".join(_DART_STRING.findall(match.group(1)))
        leading = _DART_LEADING_RUN.match(message)
        if leading:
            words.update(w for w in leading.group(1).split() if len(w) >= 3)
    return words


def marker_words():
    """The full set: the fixed floor plus every derived exit word."""
    derived = set()
    for path in sorted(glob.glob(os.path.join(ROOT, "scripts", "*.py"))):
        derived |= _exit_call_words(path)
    for rel in DART_STDERR_SOURCES:
        derived |= _dart_stderr_words(os.path.join(ROOT, rel))
    return FIXED_FLOOR | derived


def _main(argv):
    words = sorted(marker_words())
    if "--regex" in argv:
        print("|".join(w.lower() for w in words))
    else:
        for w in words:
            print(w)
    return 0


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))

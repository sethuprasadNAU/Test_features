#!/usr/bin/env python3
# gate-instrument: none - the recorded Gate C baseline, imported by gate_c_adversarial_pass.py rather than run.
"""Task 10.91 (repaired by task 10.95, L-4): the committed baseline for
gate_c_adversarial_pass.py.

10.51 said "any red item stops the gate run," which is right for the four
suites that expect zero failures and wrong for the adversarial pass, whose
expected-failure set has never been empty since Sec10. Four consecutive gates
read the same four failures (`Ce2`, `Dc`, `Dh`, `Eb`), confirmed no new ones,
and moved on — but nothing made that comparison a mechanism instead of a
belief. This module is that mechanism, and it is written specifically so it
cannot become a way to make findings quiet:

  - A failure not listed in the baseline is red.
  - A baseline entry whose cited TriTrack_Security_Model.md section does not
    exist, or does not itself say — by name, not just by keyword — that this
    specific finding is accepted / non-blocking, is red. The baseline is
    downstream of the security model, never a parallel truth a baseline file
    can assert on its own say-so.
  - A baselined check that now PASSES is red, loudly — that is a control
    fixed and the baseline gone stale, which is exactly how a real regression
    would hide later if this file only ever watched for new failures.
  - A run whose total check count (held + failed + skipped) does not match
    the count this baseline was written against is red — a check lost or
    added in a refactor must not pass silently.

L-4 (task 10.95): the original version of this file keyed a baseline entry on
`check_name.split(" ", 1)[0]` — the *leading token* of a held_check() name.
That token space already collides in gate_c_adversarial_pass.py (`Cd` names
three distinct checks; `Ea`, `A1`, `A2` name two each), so a second `Dc …`
check failing for a genuinely new reason would have been silently absorbed by
the `Dc` baseline entry. `check_id` now means the **entire, exact**
held_check() name string, which is unique by construction (every held_check
call site in the script carries different text). The citation check also used
to be a bare keyword search over the whole cited section body — six words
like "accepted" anywhere in a ~500-line section was enough to bless a
citation for an unrelated finding. It now additionally requires the entry's
own finding_id (or, when the finding has no formal code, its significant
words) to appear in that section, so a citation can no longer ride on some
other finding's accepted verdict.

Run `python3 scripts/gate_c_baseline.py --selftest` to prove those four
behaviours fire, against the real committed baseline and the real security
model file, with no live server required.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BASELINE_PATH = os.path.join(ROOT, "scripts", "gate_c_adversarial_baseline.json")
DEFAULT_SECURITY_MODEL_PATH = os.path.join(ROOT, "CLAUDE_DOCS", "TriTrack_Security_Model.md")

_ACCEPTED_RE = re.compile(r"non-blocking|not blocking|none blocking|accepted",
                           re.IGNORECASE)
_HEADER_RE = re.compile(r"^(#{1,6})\s+")
#: A formal finding code like "D-2" or "H-3" — checked first because it is
#: unambiguous. Findings with no formal code (e.g. "revision unbounded") fall
#: back to their significant words, below.
_CODE_RE = re.compile(r"\b[A-Za-z]+-\d+\b")


class BaselineError(Exception):
    """The baseline itself is invalid — never a live-run result."""


def check_id_of(check_name):
    """The full, exact held_check()/skipped_check() name. Kept as a function
    (rather than inlined identity everywhere) so the one place this baseline
    keys a check is named and cannot silently drift back to a substring."""
    return check_name


def _finding_tokens(finding_id):
    """Token(s) that must all appear in a citation's section body for the
    citation to be about *this* finding, not merely some other accepted
    finding sharing the section. Prefers the finding's formal code
    ("D-2", "G-4", "H-3"); falls back to its significant words when it has
    none (e.g. "revision unbounded" -> ["revision", "unbounded"])."""
    code = _CODE_RE.search(finding_id)
    if code:
        return [code.group(0)]
    words = [w for w in re.findall(r"[A-Za-z]+", finding_id) if len(w) >= 5]
    return words or [finding_id]


def load_baseline(path=DEFAULT_BASELINE_PATH):
    with open(path) as f:
        data = json.load(f)
    entries = data.get("entries", [])
    seen = set()
    for e in entries:
        for field in ("check_id", "finding_id", "section", "note"):
            if not e.get(field):
                raise BaselineError(f"baseline entry missing required field {field!r}: {e}")
        if e["check_id"] in seen:
            raise BaselineError(f"duplicate baseline entry for check_id {e['check_id']!r}")
        seen.add(e["check_id"])
    return entries


def load_expected_check_count(path=DEFAULT_BASELINE_PATH):
    """The total (held + failed + skipped) events gate_c_adversarial_pass.py
    should produce on a run. A check added, removed, or lost in a refactor
    changes this number, which `evaluate()` treats as red — L-4's third
    defect: `evaluate()` was never told how many checks ran at all."""
    with open(path) as f:
        data = json.load(f)
    count = data.get("expected_check_count")
    if not isinstance(count, int):
        raise BaselineError(
            "baseline is missing an integer 'expected_check_count' — "
            "evaluate() cannot detect a check silently added or lost "
            "without it")
    return count


def _find_section(text, section):
    """Return the body of the markdown section whose heading starts with
    `section` (e.g. "9.4"), from that heading up to (not including) the next
    heading at the same or shallower depth. None if no such heading exists.

    The lookahead `(?![\\d.])` matters: without it, section "10.7" would also
    match the heading "### 10.7.1 H-8 ...", silently accepting a citation
    against the wrong (deeper, differently-scoped) subsection.
    """
    lines = text.splitlines()
    pattern = re.compile(r"^(#{1,6})\s+" + re.escape(section) + r"(?![\d.])")
    start = level = None
    for i, line in enumerate(lines):
        m = pattern.match(line)
        if m:
            start, level = i, len(m.group(1))
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        m = _HEADER_RE.match(lines[j])
        if m and len(m.group(1)) <= level:
            end = j
            break
    return "\n".join(lines[start:end])


def validate_baseline(entries, security_model_path=DEFAULT_SECURITY_MODEL_PATH):
    """Raise BaselineError on the first entry whose citation does not hold.

    Checked independently of any live run — this can and should be wrong
    (red) even when the adversarial pass was never executed, because the
    defect it catches is in the paperwork, not in the server.
    """
    text = open(security_model_path).read()
    for e in entries:
        section = e["section"]
        body = _find_section(text, section)
        if body is None:
            raise BaselineError(
                f"{e['check_id']}: cited section {section!r} does not exist in "
                f"{os.path.basename(security_model_path)} — the baseline is "
                f"downstream of the security model, not a parallel truth")
        if not _ACCEPTED_RE.search(body):
            raise BaselineError(
                f"{e['check_id']}: {os.path.basename(security_model_path)} "
                f"section {section!r} exists but never records this finding as "
                f"accepted or non-blocking — citing it is a documentation "
                f"failure, not a nit")
        missing = [t for t in _finding_tokens(e["finding_id"]) if t not in body]
        if missing:
            raise BaselineError(
                f"{e['check_id']}: {os.path.basename(security_model_path)} "
                f"section {section!r} has accepted/non-blocking language "
                f"somewhere in it, but never mentions this entry's own "
                f"finding_id {e['finding_id']!r} (missing: {missing}) — the "
                f"section is about *some* accepted finding, not provably "
                f"this one")


def evaluate(held, failed, entries, skipped=None, expected_check_count=None):
    """Compare one adversarial-pass run against the baseline.

    `held` / `failed` are the lists of check-name strings
    gate_c_adversarial_pass.py collects (its own `held` / `failed` globals).
    `skipped`, if given along with `expected_check_count`, lets this function
    catch a check silently added, removed, or lost in a refactor (L-4's third
    defect) — omit both to skip that comparison (e.g. from callers that don't
    track skips).

    Returns (ok, problems) — ok is False if the run should be red for a
    baseline-related reason (independent of whatever gate_c_adversarial_pass.py
    itself already treats as failure).
    """
    baseline_ids = {e["check_id"] for e in entries}
    held_set = set(held)
    failed_set = set(failed)

    problems = []

    for name in failed:
        cid = check_id_of(name)
        if cid not in baseline_ids:
            problems.append(
                f"UNBASELINED FAILURE: {name!r} is not in the committed "
                f"baseline — a new finding, not one of the accepted four. "
                f"This is what stops the gate.")

    for e in entries:
        cid = e["check_id"]
        if cid in held_set:
            problems.append(
                f"BASELINE REGRESSION: {cid} ({e['finding_id']}) "
                f"now PASSES. Something was fixed — narrow "
                f"gate_c_adversarial_baseline.json to remove this entry "
                f"deliberately (citing the section that now records the fix), "
                f"do not leave it to rot into cover for a future regression.")
        elif cid not in failed_set:
            problems.append(
                f"BASELINE STALE: {cid} ({e['finding_id']}) is in "
                f"the baseline but no check with that exact name ran this "
                f"pass — the instrument changed under the baseline's feet.")

    if expected_check_count is not None and skipped is not None:
        total = len(held) + len(failed) + len(skipped)
        if total != expected_check_count:
            problems.append(
                f"CHECK COUNT MISMATCH: expected {expected_check_count} "
                f"checks to run (held + failed + skipped), got {total} — a "
                f"check was added, removed, or lost in a refactor without "
                f"updating gate_c_adversarial_baseline.json's "
                f"expected_check_count.")

    return (len(problems) == 0, problems)


def _selftest():
    """Prove the four behaviours above actually fire, against the real
    committed baseline and the real security model file. No live server."""
    import shutil
    import tempfile

    ok_all = True

    def report(label, condition, detail=""):
        nonlocal ok_all
        print(("  PASS  " if condition else "  ***FAILED***  ") + label
              + (f"  {detail}" if detail else ""))
        ok_all = ok_all and condition

    print("1. The real committed baseline validates against the real "
          "security model.")
    entries = load_baseline()
    try:
        validate_baseline(entries)
        report("real baseline validates", True)
    except BaselineError as exc:
        report("real baseline validates", False, str(exc))

    expected_count = load_expected_check_count()

    print("\n2. A run matching exactly the four baselined findings, with the "
          "right total count, is green.")
    matching_failed = [
        "Ce2 a denial flood cannot grow the audit store without bound",
        "Dc a User_Emails key another user holds is indistinguishable "
        "from a free one",
        "Dh a row cannot be pinned at the maximum revision",
        "Eb a Tags key another project holds is indistinguishable from a free one",
    ]
    matching_held = [
        f"X{i} filler held check" for i in range(expected_count - len(matching_failed))
    ]
    ok, problems = evaluate(matching_held, matching_failed, entries,
                             skipped=[], expected_check_count=expected_count)
    report("exact-baseline run is green", ok and not problems, str(problems))

    print("\n3. A deliberately introduced fifth failure turns it red.")
    fifth_failed = matching_failed + ["Zz a manufactured probe for this selftest"]
    ok, problems = evaluate(matching_held, fifth_failed, entries)
    report("fifth failure is red",
           not ok and any("UNBASELINED FAILURE" in p and "Zz" in p for p in problems),
           str(problems))

    print("\n3b. A second, textually distinct check sharing a leading token "
          "with a baselined one (e.g. a new 'Cd ...' check) is not absorbed "
          "by the 'Cd' — now full-name — baseline logic (regression guard "
          "for the exact defect L-4 found).")
    colliding_prefix_failed = matching_failed + [
        "Dc a wholly different finding that happens to start with the same "
        "leading token as the baselined Dc check"
    ]
    ok, problems = evaluate(matching_held, colliding_prefix_failed, entries)
    report("leading-token collision is not silently absorbed",
           not ok and any("UNBASELINED FAILURE" in p and "wholly different" in p
                          for p in problems),
           str(problems))

    print("\n4. A baselined check that now passes turns it red.")
    promoted_held = matching_held + [
        "Dc a User_Emails key another user holds is indistinguishable "
        "from a free one"]
    promoted_failed = [f for f in matching_failed if not f.startswith("Dc ")]
    ok, problems = evaluate(promoted_held, promoted_failed, entries)
    report("a baselined check passing is red",
           not ok and any("BASELINE REGRESSION" in p and p.startswith("BASELINE REGRESSION: Dc")
                          for p in problems),
           str(problems))

    print("\n5. Deleting a cited security-model section turns validation red.")
    real_text = open(DEFAULT_SECURITY_MODEL_PATH).read()
    section_to_kill = entries[0]["section"]
    body = _find_section(real_text, section_to_kill)
    assert body is not None, "setup bug: section should exist in the real file"
    mutated = real_text.replace(body, "", 1)
    tmp_dir = tempfile.mkdtemp(prefix="gate-c-baseline-selftest-")
    try:
        mutated_path = os.path.join(tmp_dir, "TriTrack_Security_Model.md")
        with open(mutated_path, "w") as f:
            f.write(mutated)
        try:
            validate_baseline(entries, security_model_path=mutated_path)
            report("deleted-section citation is red", False,
                   "validate_baseline did not raise")
        except BaselineError as exc:
            report("deleted-section citation is red",
                   entries[0]["check_id"] in str(exc), str(exc))
    finally:
        shutil.rmtree(tmp_dir)

    print("\n6. A section that has accepted/non-blocking language but never "
          "names this entry's own finding_id is red (the L-4 citation-check "
          "defect: six unrelated 'accepted' hits used to be enough).")
    unrelated_body = (
        "### 99.9 A section about something else entirely\n\n"
        "This finding is accepted. That finding is not blocking. A third "
        "finding is also accepted, and a fourth is none blocking either.\n")
    mutated2 = real_text + "\n" + unrelated_body
    tmp_dir2 = tempfile.mkdtemp(prefix="gate-c-baseline-selftest2-")
    try:
        mutated_path2 = os.path.join(tmp_dir2, "TriTrack_Security_Model.md")
        with open(mutated_path2, "w") as f:
            f.write(mutated2)
        fake_entry = dict(entries[0])
        fake_entry["section"] = "99.9"
        try:
            validate_baseline([fake_entry], security_model_path=mutated_path2)
            report("citation without the finding's own id is red", False,
                   "validate_baseline did not raise")
        except BaselineError as exc:
            report("citation without the finding's own id is red",
                   "never mentions this entry's own finding_id" in str(exc),
                   str(exc))
    finally:
        shutil.rmtree(tmp_dir2)

    print("\n7. A check silently lost from the run (count mismatch) is red.")
    short_held = matching_held[:-1]  # one fewer than expected_count demands
    ok, problems = evaluate(short_held, matching_failed, entries,
                             skipped=[], expected_check_count=expected_count)
    report("a missing check is red",
           not ok and any("CHECK COUNT MISMATCH" in p for p in problems),
           str(problems))

    print()
    if ok_all:
        print("SELFTEST PASSED: the baseline mechanism cannot be used to "
              "make a new finding, a stale citation, a fixed control, or a "
              "lost check quiet.")
        return 0
    print("SELFTEST FAILED: see ***FAILED*** lines above.")
    return 1


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        sys.exit(_selftest())
    print(__doc__)
    sys.exit(0)

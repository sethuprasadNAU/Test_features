#!/usr/bin/env python3
# gate-instrument: verify_c1_row_naming
"""Re-runs Security Gate C's four C-1 reproductions (`TriTrack_Security_Model.md`
§7.3, B1a-B1d) against a live stack over raw HTTP — no client code, no mocks,
no in-process shortcuts, which is the only way this class of finding surfaced
in the first place.

`server/test/authz/authorization_test.dart` pins the same four at the service
layer and is what CI runs. This exists because the gate's own conclusion was
that C-1 was invisible to two scoped code reviews and 309 passing tests, and
appeared only under a live adversarial pass. Task 10.25 re-runs the whole gate;
this is the part of it that is cheap to repeat.

Usage (with the e2e stack up — see the README's "End-to-end integration suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -f docker-compose.yml -f docker-compose.e2e.yml up --build -d
    python3 scripts/verify_c1_row_naming.py

Exits non-zero if any reproduction succeeds. Verified to fail loudly against a
build with the task 10.20 invariant removed, which is the only evidence that it
is testing anything at all.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import ENVELOPE, outcome_for, preflight  # noqa: E402

BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")

T = "2026-08-01T12:00:00.000Z"
# Primary keys are global, and this database is not reset between runs — a
# literal id would be found as an *existing* row from an earlier run and
# refused as a cross-project capture, which looks like the fix working.
RUN = uuid.uuid4().hex[:8]


def call(path, body, token=None):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def sign_in(label):
    """Magic-link sign-in, reading the token off the bind-mounted directory."""
    email = f"c1-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
    status, _ = call("/auth/magic-link", {"email": email})
    assert status == 202, f"magic-link {status}"
    path = os.path.join(LINK_DIR, email + ".link")
    for _ in range(50):
        if os.path.exists(path):
            break
        time.sleep(0.1)
    token = open(path).read().split("token=")[1].strip()
    device = "device-" + uuid.uuid4().hex[:8]
    status, body = call("/auth/redeem", {"token": token, "device_id": device})
    assert status == 200, f"redeem {status} {body}"
    # The account address comes back too: since task 10.55 a `Users` row may
    # only claim an address this server authenticated for that id, so a fixture
    # that made one up is a fixture the server correctly refuses.
    return body["session_token"], body["user_id"], device, email


def user_row(uid, first, email=None):
    return {
        "user_id": uid, "first_name": first, "last_name": "Person",
        "email": email or f"{first.lower()}-{uid[:8]}@example.org",
        "created_at": T, "updated_at": T, "revision": 1,
        "last_modified_by": uid, "origin_device_id": "device-x",
    }


def project_row(pid, owner):
    return {
        "project_id": pid, "project_name": "Field", "owner_user_id": owner,
        "creation_date": T, "datum": "WGS84", "created_at": T, "updated_at": T,
        "revision": 1, "last_modified_by": owner, "origin_device_id": "device-x",
        "coordinate_format": "dd", "triangulation_window_minutes": 15,
    }


def observation(oid, pid, uid, revision=1, notes=None):
    return {
        "observation_id": oid, "project_id": pid, "user_id": uid,
        "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
        "latitude": 35.19, "longitude": -111.65, "position_source": "gps_fix",
        "elevation": 2100.0, "altitude_agl": 0.0,
        "observation_type": "directional", "signal_type": "regular_pulse",
        "signal_strength": "strong", "notes": notes,
        "created_at": T, "updated_at": T, "revision": revision,
        "last_modified_by": uid, "origin_device_id": "device-x",
    }


def push(token, device, pid, rows):
    return call("/sync/push", {**ENVELOPE, "project_id": pid,
                               "device_id": device, "rows": rows}, token)


def pull(token, device, pid):
    return call("/sync/pull", {**ENVELOPE, "project_id": pid,
                               "device_id": device, "cursor": 0,
                               "batch_size": 500}, token)


failures = []

#: Every check's verdict, keyed by the name typed at the call site.
#:
#: `VERIFY_C1_JSON` names a path to write this to, which is how
#: `verify_11_127_broken_control.py` decides whether a reproduction flipped
#: from refused to reproduced. The mechanism is `verify_11_9_team_surface.py`'s,
#: unchanged — an exit code says the run went red and cannot say *which* check
#: went red, and a run that went red for an unrelated reason is not evidence
#: that this instrument can see the thing it is for.
CHECKS = {}


def check(name, condition, detail=""):
    # A structure keyed by a string somebody types must make a duplicate key a
    # hard error rather than a last-write-wins — task 11.88 found exactly that
    # in `attack()`, where a genuinely flipped check was reported as blind
    # because a later call reused its description.
    if name in CHECKS:
        print(f"\nFATAL: two checks in this file are both called {name!r}. "
              f"One would silently overwrite the other's verdict, and a "
              f"flipped check would be reported as held.")
        sys.exit(2)
    CHECKS[name] = bool(condition)
    print(("  PASS  " if condition else "  FAIL  ") + name + (f"  {detail}" if detail else ""))
    if not condition:
        failures.append(name)


def write_summary():
    """Write [CHECKS] to `$VERIFY_C1_JSON`, if a path was given."""
    path = os.environ.get("VERIFY_C1_JSON")
    if not path:
        return
    with open(path, "w") as fh:
        json.dump({
            "checks": CHECKS,
            "passed": sorted(k for k, v in CHECKS.items() if v),
            "failed": sorted(k for k, v in CHECKS.items() if not v),
        }, fh, indent=2)
    print(f"summary written to {path}")


preflight(BASE, LINK_DIR)
print("Signing in two unrelated users over the real auth flow...")
victim_tok, victim_id, victim_dev, victim_email = sign_in("victim")
attacker_tok, attacker_id, attacker_dev, attacker_email = sign_in(
    "attacker")

# The victim publishes a project, which is what puts their Users row — name and
# email — on the server. This is the asset C-1 disclosed.
vproj = str(uuid.uuid4())
status, body = push(victim_tok, victim_dev, vproj, {
    "Users": [user_row(victim_id, "Victim", victim_email)],
    "Projects": [project_row(vproj, victim_id)],
})
assert status == 200 and body["applied"] == 2, (status, body)

# The attacker publishes a project of their own — a completely legitimate one.
aproj = str(uuid.uuid4())
status, body = push(attacker_tok, attacker_dev, aproj, {
    "Users": [user_row(attacker_id, "Attacker", attacker_email)],
    "Projects": [project_row(aproj, attacker_id)],
})
assert status == 200 and body["applied"] == 2, (status, body)

print("\nB1a — identity disclosure by forged authorship (Observations.user_id)")
_, before = pull(attacker_tok, attacker_dev, aproj)
users_before = [r["user_id"] for r in before.get("rows", {}).get("Users", [])]
check("baseline pull returns only the attacker", users_before == [attacker_id],
      str(users_before))

forged = observation(f"obs-forged-{RUN}", aproj, victim_id)
status, body = push(attacker_tok, attacker_dev, aproj, {"Observations": [forged]})
outcome = outcome_for(body, "Observations", forged)
check("forged insert is refused", outcome == "unauthorized", f"got {outcome}")

_, after = pull(attacker_tok, attacker_dev, aproj)
users_after = [r["user_id"] for r in after.get("rows", {}).get("Users", [])]
emails_after = [r["user_id"] for r in after.get("rows", {}).get("User_Emails", [])]
check("victim's Users row is not disclosed", victim_id not in users_after,
      str(users_after))
check("victim's address history is not disclosed", victim_id not in emails_after)

print("\nB1b — the same through Non_Detections.user_id")
nd = {
    "non_detection_id": f"nd-forged-{RUN}", "project_id": aproj, "user_id": victim_id,
    "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
    "latitude": 35.19, "longitude": -111.65, "position_accuracy_m": None,
    "position_source": "gps_fix", "elevation": 2100.0, "altitude_agl": 0.0,
    "tag_ids_listened_for": "[]", "notes": None,
    "created_at": T, "updated_at": T, "revision": 1,
    "last_modified_by": victim_id, "origin_device_id": "device-x",
}
status, body = push(attacker_tok, attacker_dev, aproj, {"Non_Detections": [nd]})
outcome = outcome_for(body, "Non_Detections", nd)
check("forged non-detection is refused", outcome == "unauthorized", f"got {outcome}")

print("\nB1d — authorship forgery, one-way and irrevocable")
own = observation(f"obs-own-{RUN}", aproj, attacker_id)
status, body = push(attacker_tok, attacker_dev, aproj, {"Observations": [own]})
check("attacker's own observation is inserted",
      outcome_for(body, "Observations", own) == "inserted", str(body.get("outcomes")))

rewritten = observation(
    f"obs-own-{RUN}", aproj, victim_id, revision=2,
    notes="FABRICATED: victim reported this animal at this location")
status, body = push(attacker_tok, attacker_dev, aproj, {"Observations": [rewritten]})
outcome = outcome_for(body, "Observations", rewritten)
check("rewriting the author is refused", outcome == "unauthorized", f"got {outcome}")

_, after = pull(attacker_tok, attacker_dev, aproj)
stored = [r for r in after.get("rows", {}).get("Observations", [])
          if r["observation_id"] == f"obs-own-{RUN}"]
check("server's authoritative copy still names the attacker",
      len(stored) == 1 and stored[0]["user_id"] == attacker_id,
      str([(r["user_id"], r["notes"]) for r in stored]))
check("the fabricated notes never landed",
      len(stored) == 1 and stored[0]["notes"] is None)

print("\nB1c — project handover to a stranger (Projects.owner_user_id)")
seized = project_row(aproj, victim_id)
seized["revision"] = 99
status, body = push(attacker_tok, attacker_dev, aproj, {"Projects": [seized]})
outcome = outcome_for(body, "Projects", seized)
check("rewriting owner_user_id is refused", outcome == "unauthorized", f"got {outcome}")
# **Both halves of this were wrong until task 11.127's detection proof ran.**
#
# `after["rows"]` was a bare subscript, and the pull it reads is the one the
# attacker makes on a project they have just handed away. Against a server with
# the naming invariant deleted the handover succeeds, so the attacker is no
# longer a member, so the pull is refused and carries no `rows` at all — and
# this instrument died on a `KeyError` in the middle of its own reproduction,
# before the 10.29 regression checks below had run and before it could write
# its summary. **An instrument that cannot survive the finding it exists to
# find reports nothing about it.**
#
# And `owner == []` was accepted as "unchanged", which reads an empty answer as
# a clean one. That is the found-nothing/could-not-look confusion this project
# has already closed in the backup drill and in `verify_c5_denial_audit.py`:
# the attacker's own `Projects` row was inserted at the top of this script, so
# on a healthy server it comes back, and an empty list means something went
# wrong rather than nothing did.
status_after, after = pull(attacker_tok, attacker_dev, aproj)
rows = after.get("rows")
if rows is None:
    check("stored owner is unchanged", False,
          f"the pull that would answer this was refused ({status_after}), so "
          f"the owner cannot be confirmed unchanged — which on this build is "
          f"because it changed and locked the caller out")
else:
    owner = [r["owner_user_id"] for r in rows.get("Projects", [])]
    check("stored owner is unchanged", owner == [attacker_id], str(owner))

print("\nRegression — 10.29 converged the unknown-user branch on the refusal")
colleague = str(uuid.uuid4())
colleague_row = user_row(colleague, "Colleague")
imported = observation(f"obs-imported-{RUN}", aproj, colleague)
status, body = push(attacker_tok, attacker_dev, aproj, {
    "Users": [colleague_row],
    "Observations": [imported],
})
# Task 10.29 (D-1) converged both branches of the unknown-user case on the
# refusal: naming a user this project does not reach is attribution as well as
# disclosure, and the first-publish replication seam was the price. So the
# expectation here is the *opposite* of what C-1's own remediation left, and
# that inversion is the finding's resolution rather than a regression.
check("an imported colleague's Users row is refused (10.29's converged rule)",
      outcome_for(body, "Users", colleague_row) == "unauthorized",
      str(body.get("outcomes")))
check("their observation is refused with it",
      outcome_for(body, "Observations", imported) == "unauthorized",
      str(body.get("outcomes")))

own_again = observation(f"obs-own-2-{RUN}", aproj, attacker_id)
status, body = push(attacker_tok, attacker_dev, aproj, {"Observations": [own_again]})
check("the caller's own observations still sync (publish is not broken)",
      outcome_for(body, "Observations", own_again) == "inserted",
      str(body.get("outcomes")))

print()
write_summary()
if failures:
    print(f"{len(failures)} CHECK(S) FAILED: {failures}")
    sys.exit(1)
print(f"All {len(CHECKS)} C-1 reproductions refused; the caller's own publish "
      f"is unaffected.")

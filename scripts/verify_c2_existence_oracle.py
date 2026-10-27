#!/usr/bin/env python3
# gate-instrument: verify_c2_existence_oracle
"""Re-runs Security Gate C's C-2 reproduction (`TriTrack_Security_Model.md`
§7.3 B2) against a live stack over raw HTTP — no client code, no mocks.

The finding: a project id the server has never seen answered `200` with an
empty row set, while a real project the caller may not touch answered `403`.
That difference is a working existence oracle, and §4.13 names it as its first
`Violated by:` case.

Every check below sends the *same* request twice — once naming a real project
owned by someone else, once naming a fabricated id — and asserts the two
answers cannot be told apart. It compares the responses to each other rather
than to expected text, so it keeps holding if the refusal is reworded.

Usage (with the e2e stack up — see the README's "End-to-end integration suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -f docker-compose.yml -f docker-compose.e2e.yml up --build -d
    python3 scripts/verify_c2_existence_oracle.py

Since task 11.60 it also covers **inventory entry 28**, the closed-membership
disclosure: `/sync/pull` deliberately answers one caller it otherwise refuses,
and the checks at the end ask whether that branch is observable to anybody who
is not its subject. Same file, because it is the same question.

Exits non-zero if any pair is distinguishable. Verified to fail loudly against
a build with the task 10.21 seam removed, which is the only evidence that it is
testing anything at all.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import (  # noqa: E402
    ENVELOPE,
    join_by_code,
    outcome_key,
    preflight,
)

BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")

T = "2026-08-01T12:00:00.000Z"
# Primary keys are global and this database is not reset between runs.
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
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def sign_in(label):
    email = f"c2-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
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
    parsed = json.loads(body)
    # Task 10.55: a `Users` row may only claim the address its account
    # authenticated with, so every fixture below pushes the real one.
    return parsed["session_token"], parsed["user_id"], device, email


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


def observation(oid, pid, uid):
    return {
        "observation_id": oid, "project_id": pid, "user_id": uid,
        "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
        "latitude": 35.19, "longitude": -111.65, "position_source": "gps_fix",
        "elevation": 2100.0, "altitude_agl": 0.0,
        "observation_type": "directional", "signal_type": "regular_pulse",
        "signal_strength": "strong", "notes": None,
        "created_at": T, "updated_at": T, "revision": 1,
        "last_modified_by": uid, "origin_device_id": "device-x",
    }


failures = []


def indistinguishable(name, real, fake):
    same = real == fake
    print(("  PASS  " if same else "  FAIL  ") + name)
    if not same:
        print(f"          real project -> {real[0]} {real[1][:160]}")
        print(f"          fabricated   -> {fake[0]} {fake[1][:160]}")
        failures.append(name)


def check(name, condition, detail=""):
    print(("  PASS  " if condition else "  FAIL  ") + name + (f"  {detail}" if detail else ""))
    if not condition:
        failures.append(name)


preflight(BASE, LINK_DIR)
print("Signing in an owner and an unrelated stranger...")
owner_tok, owner_id, owner_dev, owner_email = sign_in("owner")
stranger_tok, stranger_id, stranger_dev, stranger_email = sign_in(
    "stranger")

real_project = str(uuid.uuid4())
fake_project = str(uuid.uuid4())  # never published, by construction

status, body = call("/sync/push", {
    **ENVELOPE, "project_id": real_project, "device_id": owner_dev,
    "rows": {
        "Users": [user_row(owner_id, "Owner", owner_email)],
        "Projects": [project_row(real_project, owner_id)],
        "Observations": [observation(f"obs-{RUN}", real_project, owner_id)],
    },
}, owner_tok)
assert status == 200, (status, body)

# The stranger's own Users row, so their pushes are not refused for an
# unrelated reason.
call("/sync/push", {
    **ENVELOPE, "project_id": str(uuid.uuid4()), "device_id": stranger_dev,
    "rows": {"Users": [user_row(stranger_id, "Stranger", stranger_email)]},
}, stranger_tok)

print("\nB2 — a real foreign project versus one that has never existed")

indistinguishable(
    "pull answers both the same",
    call("/sync/pull", {**ENVELOPE, "project_id": real_project,
                        "device_id": stranger_dev, "cursor": 0,
                        "batch_size": 500}, stranger_tok),
    call("/sync/pull", {**ENVELOPE, "project_id": fake_project,
                        "device_id": stranger_dev, "cursor": 0,
                        "batch_size": 500}, stranger_tok),
)

indistinguishable(
    "push answers both the same",
    call("/sync/push", {**ENVELOPE, "project_id": real_project,
                        "device_id": stranger_dev,
                        "rows": {"Observations": [
                            observation(f"probe-{RUN}", real_project, stranger_id)]}},
         stranger_tok),
    call("/sync/push", {**ENVELOPE, "project_id": fake_project,
                        "device_id": stranger_dev,
                        "rows": {"Observations": [
                            observation(f"probe-{RUN}", fake_project, stranger_id)]}},
         stranger_tok),
)

indistinguishable(
    "ack answers both the same",
    call("/sync/ack", {**ENVELOPE, "project_id": real_project,
                       "device_id": stranger_dev, "cursor": 0}, stranger_tok),
    call("/sync/ack", {**ENVELOPE, "project_id": fake_project,
                       "device_id": stranger_dev, "cursor": 0}, stranger_tok),
)

# A malformed establishing row is the cheap, non-destructive variant of the
# probe: it must not answer "500 because the write began" for a free id and
# "403 because it never did" for a taken one.
broken = {k: v for k, v in project_row(fake_project, stranger_id).items()
          if k != "project_name"}
indistinguishable(
    "a malformed first publish answers both the same",
    call("/sync/push", {**ENVELOPE, "project_id": real_project,
                        "device_id": stranger_dev,
                        "rows": {"Projects": [
                            {**broken, "project_id": real_project}]}},
         stranger_tok),
    call("/sync/push", {**ENVELOPE, "project_id": fake_project,
                        "device_id": stranger_dev,
                        "rows": {"Projects": [broken]}}, stranger_tok),
)

indistinguishable(
    "a push carrying no rows of that project answers both the same",
    call("/sync/push", {**ENVELOPE, "project_id": real_project,
                        "device_id": stranger_dev,
                        "rows": {"Users": [user_row(stranger_id, "Stranger", stranger_email)]}},
         stranger_tok),
    call("/sync/push", {**ENVELOPE, "project_id": fake_project,
                        "device_id": stranger_dev,
                        "rows": {"Users": [user_row(stranger_id, "Stranger", stranger_email)]}},
         stranger_tok),
)

print("\nRegression — the publish that ProjectAccess.absent used to permit")
new_owner_tok, new_owner_id, new_owner_dev, new_owner_email = sign_in(
    "newowner")
brand_new = str(uuid.uuid4())

# The shipped publisher's shape: global rows first, before the project exists.
status, body = call("/sync/push", {
    **ENVELOPE, "project_id": brand_new, "device_id": new_owner_dev,
    "rows": {"Users": [user_row(new_owner_id, "Newowner", new_owner_email)]},
}, new_owner_tok)
check("a publisher's global-rows-first request still works", status == 200,
      f"got {status}")

status, body = call("/sync/push", {
    **ENVELOPE, "project_id": brand_new, "device_id": new_owner_dev,
    "rows": {"Projects": [project_row(brand_new, new_owner_id)]},
}, new_owner_tok)
outcomes = json.loads(body).get("outcomes", {}) if status == 200 else {}
check("the establishing request creates the project",
      outcomes.get(outcome_key("Projects", project_row(brand_new, new_owner_id)))
      == "inserted",
      f"got {status} {outcomes}")

own_obs = observation(f"own-{RUN}", brand_new, new_owner_id)
status, body = call("/sync/push", {
    **ENVELOPE, "project_id": brand_new, "device_id": new_owner_dev,
    "rows": {"Observations": [own_obs]},
}, new_owner_tok)
outcomes = json.loads(body).get("outcomes", {}) if status == 200 else {}
check("and the project's own rows then push normally",
      outcomes.get(outcome_key("Observations", own_obs)) == "inserted",
      f"got {status} {outcomes}")

status, body = call("/sync/pull", {
    **ENVELOPE, "project_id": brand_new, "device_id": new_owner_dev,
    "cursor": 0, "batch_size": 500,
}, new_owner_tok)
check("and its owner can pull it", status == 200, f"got {status}")

# =========================================================================
# Task 11.60 — the closed-membership disclosure (§4.27, inventory entry 28)
#
# `/sync/pull` now answers one caller it otherwise refuses: somebody whose
# stint on the project has ended gets their own closed membership row. A read
# that answers a refused caller is the shape B2 was, so the question here is
# whether the *branch* is observable to anybody who is not its subject.
#
# The prober is deliberately somebody who CAN reach the disclosure — a person
# with a closed stint on one project — because a caller who could never take
# that branch under any input cannot detect a leak in it.
print("\n11.60 — the removed member's disclosure must not be a probe")

member_tok, member_id, member_dev, member_email = sign_in("departed")
call("/sync/push", {
    **ENVELOPE, "project_id": str(uuid.uuid4()), "device_id": member_dev,
    "rows": {"Users": [user_row(member_id, "Departed", member_email)]},
}, member_tok)

shared = str(uuid.uuid4())
status, body = call("/sync/push", {
    **ENVELOPE, "project_id": shared, "device_id": owner_dev,
    "rows": {"Projects": [project_row(shared, owner_id)]},
}, owner_tok)
check("a project to be removed from exists", status == 200, f"got {status}")

# **Task 11.85.** This fixture used to invite the member; task 11.81 deleted
# the invitation routes and this check went `404`, along with three sibling
# instruments. It is not a finding — it is an instrument that could no longer
# reach the thing it checks. The flow now is the real one: the owner turns
# joining on, the member asks with the code, the owner approves.
#
# `join_by_code` speaks the shared helper's calling convention (a parsed body),
# so it gets an adapter rather than this file's raw-text `call`.
def json_call(path, body, token=None, method="POST"):
    status, raw = call(path, body, token)
    try:
        return status, (json.loads(raw) if raw else {})
    except json.JSONDecodeError:
        return status, {"raw": raw[:200]}


joined = True
try:
    join_by_code(json_call, owner_tok, shared, member_tok, "contributor")
except AssertionError as e:
    joined = False
    print(f"    join failed: {e}")
check("the member can join with the project's code and be approved", joined,
      "see the line above")

# The owner ends the stint, exactly as the members screen does.
status, body = call("/sync/pull", {
    **ENVELOPE, "project_id": shared, "device_id": owner_dev,
    "cursor": 0, "batch_size": 500,
}, owner_tok)
their_row = next(
    (r for r in (json.loads(body).get("rows", {}).get("Project_Memberships") or [])
     if r.get("user_id") == member_id), None) if status == 200 else None
check("the owner's pull carries the member's row", their_row is not None,
      f"got {status}")

if their_row:
    ended = dict(their_row)
    ended["end_date"] = "2026-09-01T00:00:00.000Z"
    ended["updated_at"] = "2026-09-01T00:00:00.000Z"
    ended["revision"] = int(ended.get("revision") or 0) + 1
    ended["last_modified_by"] = owner_id
    status, body = call("/sync/push", {
        **ENVELOPE, "project_id": shared, "device_id": owner_dev,
        "rows": {"Project_Memberships": [ended]},
    }, owner_tok)
    check("the removal lands",
          json.loads(body).get("outcomes", {}).get(
              outcome_key("Project_Memberships", ended)) == "updated",
          f"got {status} {body[:160]}")

    # 1. The disclosure does what it is for, and no more.
    status, body = call("/sync/pull", {
        **ENVELOPE, "project_id": shared, "device_id": member_dev,
        "cursor": 0, "batch_size": 500,
    }, member_tok)
    rows = json.loads(body).get("rows", {}) if status == 200 else {}
    disclosed = rows.get("Project_Memberships") or []
    check("a removed member is answered at all", status == 200, f"got {status}")
    check("...with nothing but Project_Memberships",
          [t for t in rows if rows.get(t)] == ["Project_Memberships"],
          f"got {[t for t in rows if rows.get(t)]}")
    check("...only their own row, and it is closed",
          len(disclosed) == 1
          and disclosed[0].get("user_id") == member_id
          and disclosed[0].get("end_date"),
          f"got {len(disclosed)} rows")

    # 2. And it is invisible to anybody who is not its subject — including to
    #    this same caller, for ids they hold no row for. This is the check that
    #    would catch the disclosure leaking the *existence* of a project.
    indistinguishable(
        "a caller who can reach the disclosure still cannot tell a real "
        "foreign project from a fabricated one",
        call("/sync/pull", {**ENVELOPE, "project_id": real_project,
                            "device_id": member_dev, "cursor": 0,
                            "batch_size": 500}, member_tok),
        call("/sync/pull", {**ENVELOPE, "project_id": str(uuid.uuid4()),
                            "device_id": member_dev, "cursor": 0,
                            "batch_size": 500}, member_tok),
    )
    indistinguishable(
        "and the project they were removed from reads, to a stranger, like "
        "one that never existed",
        call("/sync/pull", {**ENVELOPE, "project_id": shared,
                            "device_id": stranger_dev, "cursor": 0,
                            "batch_size": 500}, stranger_tok),
        call("/sync/pull", {**ENVELOPE, "project_id": str(uuid.uuid4()),
                            "device_id": stranger_dev, "cursor": 0,
                            "batch_size": 500}, stranger_tok),
    )

    # 3. It opened a read, not the project.
    probe_row = observation(f"after-{RUN}", shared, member_id)
    status, _ = call("/sync/push", {
        **ENVELOPE, "project_id": shared, "device_id": member_dev,
        "rows": {"Observations": [probe_row]},
    }, member_tok)
    check("the removed member still cannot push", status == 403, f"got {status}")
    status, _ = call("/sync/ack", {
        **ENVELOPE, "project_id": shared, "device_id": member_dev,
        "cursor": 1}, member_tok)
    check("...nor acknowledge a cursor", status == 403, f"got {status}")

print()
if failures:
    print(f"{len(failures)} CHECK(S) FAILED: {failures}")
    sys.exit(1)
print("Existence is not observable on any sync route; publish unaffected.")

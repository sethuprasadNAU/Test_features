#!/usr/bin/env python3
# gate-instrument: verify_i4_email_forgery
"""Re-runs Security Gate C's I-4 reproduction (`TriTrack_Security_Model.md`
§11.8) against a live stack over raw HTTP — no client code, no mocks.

The finding: the row-naming invariant (C-1, task 10.20) makes `user_id`
unforgeable and says nothing about the column beside it. On the client an
identity email *is* an identity — `ProjectMerger._buildUserRemap` dedups
incoming users onto local ones by normalized address, *"tier 1 always wins
outright"*, and then rewrites `user_id`, `owner_user_id` and `last_modified_by`
on every row of the page. So an attacker who pushes their **own** `Users` row,
naming nobody but themselves, carrying a colleague's address, gets that
colleague's local id substituted for their own on the victim's next pull: C-1's
harm exactly, reached one column over. Live against the build before task
10.55, that push answered `200 'updated'`.

Task 10.55's fix is server-side and has one permitting branch: the address on
the row must be the one `auth_accounts` holds for that `user_id` — the mailbox
somebody proved control of at sign-in. Everything else refuses, and the
refusals converge deliberately, so this script checks both halves:

1. **The forgery is refused** — a colleague's address on the attacker's own
   row, and the victim's stored profile is unchanged afterwards.
2. **It cannot become a registration oracle** — an address belonging to a
   registered user and one belonging to nobody must answer identically, which
   is `verify_d1_per_row_oracle.py`'s method applied to this column. If the
   two ever diverge, "is this person registered here?" is answerable off the
   outcome map.
3. **A prior address is refused too, including your own** — it is unverifiable
   by construction (a new address is a new account here), and the merger's
   prior-email tiers are the same remap tier 1 is. The one `User_Emails` row
   that still lands is one naming the caller's current authenticated address,
   which asserts nothing their `Users` row does not already say.
4. **The ordinary case still works** — the caller's own profile syncs on their
   authenticated address, case and whitespace notwithstanding. A refusal that
   also refused this would be a broken sync wearing a security fix's clothes.

Usage (with the e2e stack up — see the README's "End-to-end integration suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -f docker-compose.yml -f docker-compose.e2e.yml up --build -d
    python3 scripts/verify_i4_email_forgery.py

Exits non-zero if any check fails. Verified to fail loudly against a build with
task 10.55's `RowAuthorizer._authorizeEmailClaim` removed, which is the only
evidence that it is testing anything at all.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import ENVELOPE, preflight  # noqa: E402

BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")

T = "2026-08-01T12:00:00.000Z"
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
    email = f"i4-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
    status, _ = call("/auth/magic-link", {"email": email})
    assert status == 202, f"magic-link {status}"
    path = os.path.join(LINK_DIR, email + ".link")
    for _ in range(50):
        if os.path.exists(path):
            break
        time.sleep(0.1)
    else:
        raise SystemExit(f"no magic link appeared at {path}")
    token = open(path).read().split("token=")[1].strip()
    device = "device-" + uuid.uuid4().hex[:8]
    status, body = call("/auth/redeem", {"token": token, "device_id": device})
    assert status == 200, f"redeem {status} {body}"
    parsed = json.loads(body)
    return {"token": parsed["session_token"], "uid": parsed["user_id"],
            "device": device, "email": email}


def user_row(uid, first, email):
    return {"user_id": uid, "first_name": first, "last_name": "Person",
            "email": email, "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def user_email_row(email_id, uid, email):
    return {"user_email_id": email_id, "user_id": uid, "email": email,
            "recorded_at": T, "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def project_row(pid, owner):
    return {"project_id": pid, "project_name": "Field", "owner_user_id": owner,
            "creation_date": T, "datum": "WGS84", "created_at": T,
            "updated_at": T, "revision": 1, "last_modified_by": owner,
            "origin_device_id": "device-x", "coordinate_format": "dd",
            "triangulation_window_minutes": 15}


def push(actor, project, rows):
    status, body = call("/sync/push", {
        **ENVELOPE, "project_id": project, "device_id": actor["device"],
        "rows": rows,
    }, actor["token"])
    try:
        return status, json.loads(body)
    except json.JSONDecodeError:
        return status, {"raw": body[:200]}


def outcomes(body):
    """The answers, stripped of the ids that keyed them — two probes
    necessarily name different rows, so only the values may be compared."""
    return sorted(body.get("outcomes", {}).values())


failures = []


def check(name, condition, detail=""):
    print(("  PASS  " if condition else "  FAIL  ") + name +
          (f"  {detail}" if detail else ""))
    if not condition:
        failures.append(name)


def indistinguishable(name, registered, nobody):
    same = registered == nobody
    print(("  PASS  " if same else "  FAIL  ") + name)
    if not same:
        print(f"          a registered address -> {registered}")
        print(f"          an address nobody holds -> {nobody}")
        failures.append(name)


preflight(BASE, LINK_DIR)
print("Signing in a victim and an attacker with no relationship to them...")
victim = sign_in("victim")
attacker = sign_in("attacker")

victim_project = str(uuid.uuid4())
attacker_project = str(uuid.uuid4())

status, body = push(victim, victim_project, {
    "Users": [user_row(victim["uid"], "Victim", victim["email"])],
    "Projects": [project_row(victim_project, victim["uid"])],
})
assert status == 200 and "unauthorized" not in json.dumps(body), (
    f"the victim's own publish must land cleanly, or nothing below proves "
    f"anything: {status} {body}")

status, body = push(attacker, attacker_project, {
    "Users": [user_row(attacker["uid"], "Attacker", attacker["email"])],
    "Projects": [project_row(attacker_project, attacker["uid"])],
})
assert status == 200 and "unauthorized" not in json.dumps(body), (
    f"the attacker's own publish must land cleanly too: {status} {body}")

print("\nI-4 — the attacker's own Users row, carrying the victim's address")
# Revision 2, so this is a genuine mutation rather than a row that merely
# loses last-write-wins — a stale clock answers `lost_to_server` and writes
# nothing, which is a real defence but not the one under test here.
status, body = push(attacker, attacker_project, {
    "Users": [{**user_row(attacker["uid"], "Attacker", victim["email"]),
               "revision": 2}],
})
check("the forged address is refused", outcomes(body) == ["unauthorized"],
      f"got {status} {outcomes(body)}")

# The whole harm is what a *pull* would then deliver, so the check that matters
# is the stored state, not the answer. The attacker's own row must still carry
# the attacker's own address.
status, body = push(attacker, attacker_project, {
    "Users": [{**user_row(attacker["uid"], "Attacker", attacker["email"]),
               "revision": 3}],
})
check("the attacker's stored profile still carries their own address",
      outcomes(body) == ["updated"],
      "a re-push of the genuine row is an update, so the forgery never landed")

print("\nCase and whitespace are normalized on both sides, not compared raw")
status, body = push(attacker, attacker_project, {
    "Users": [{**user_row(attacker["uid"], "Attacker",
                          f"  {attacker['email'].upper()} "),
               "revision": 4}],
})
check("the caller's own address survives case and padding",
      outcomes(body) == ["updated"], f"got {status} {outcomes(body)}")
status, body = push(attacker, attacker_project, {
    "Users": [{**user_row(attacker["uid"], "Attacker",
                          f"  {victim['email'].upper()} "),
               "revision": 5}],
})
check("but the victim's does not sneak through in a different case",
      outcomes(body) == ["unauthorized"], f"got {status} {outcomes(body)}")

print("\nThe refusal must not become a registration oracle (D-1's method)")
registered = push(attacker, attacker_project, {
    "Users": [{**user_row(attacker["uid"], "Attacker", victim["email"]),
               "revision": 6}],
})
nobody = push(attacker, attacker_project, {
    "Users": [{**user_row(attacker["uid"], "Attacker",
                          f"never-{uuid.uuid4().hex[:8]}@example.invalid"),
               "revision": 6}],
})
indistinguishable(
    "an address a registered user holds and one nobody holds answer the same",
    (registered[0], outcomes(registered[1])), (nobody[0], outcomes(nobody[1])))

print("\nUser_Emails — a prior address is unverifiable, so it is refused")
own = push(attacker, attacker_project, {
    "User_Emails": [user_email_row(f"ue-own-{RUN}", attacker["uid"],
                                   f"old-{RUN}@example.invalid")],
})
check("a prior address for yourself is refused",
      outcomes(own[1]) == ["unauthorized"], f"got {own[0]} {outcomes(own[1])}")
theirs = push(attacker, attacker_project, {
    "User_Emails": [user_email_row(f"ue-theirs-{RUN}", attacker["uid"],
                                   victim["email"])],
})
check("and so is the victim's current address as your 'prior' one",
      outcomes(theirs[1]) == ["unauthorized"],
      "this is tier 2b — the merger matches an incoming user's claimed prior "
      "address against a local user's current one, same remap, same harm")
current = push(attacker, attacker_project, {
    "User_Emails": [user_email_row(f"ue-current-{RUN}", attacker["uid"],
                                   attacker["email"])],
})
check("but your own current address still lands — the boundary is what the "
      "server authenticated, not the table",
      outcomes(current[1]) == ["inserted"],
      f"got {current[0]} {outcomes(current[1])}")

print("\nThe flows the strictness must not break")
status, body = push(victim, victim_project, {
    "Users": [{**user_row(victim["uid"], "Victim", victim["email"]),
               "first_name": "Renamed", "revision": 2}],
})
check("the victim can still edit and sync their own profile",
      outcomes(body) == ["updated"], f"got {status} {outcomes(body)}")

print()
if failures:
    print(f"{len(failures)} check(s) FAILED: {', '.join(failures)}")
    sys.exit(1)
print("The email column is not a way to name someone else; publish is "
      "unaffected.")

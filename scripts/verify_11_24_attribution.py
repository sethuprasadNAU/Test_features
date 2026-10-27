#!/usr/bin/env python3
# gate-instrument: verify_11_24_attribution
"""Task 11.24 — attribution, and the owner-only rules the server was never told.

Two questions, one live stack, because they share every fixture:

**N-1 (Security Model §18.3).** May a contributor put a teammate's name on a
record that teammate never made? The row-naming invariant (§4.17) permits
naming *anyone this project already reaches*, and since task 11.2 every
teammate is inside that set. Task 11.9 measured it on two tables. **This
instrument does not carry a table list.** It derives the affected set from
`tableMutationRules` — every table whose rule names an author — so the third
table task 11.23 found (`Non_Detections`) and the fourth nobody has written yet
are covered by construction. `gate_wire.author_naming_tables()` is the
derivation; `ROW_BUILDERS` below must cover whatever it returns, and the run
aborts if it does not.

**Task 11.26's class, merged here (2026-08-22).** *"The app asserts a rule the
server does not enforce."* The known instance: only a project owner may take a
tag out of a project, and `RowAuthorizer` was never told. Every owner-only cell
in `CLAUDE_DOCS/PERMISSIONS_MATRIX.md` is probed here against a real socket.

Every attack is paired with the nearest legitimate request that must be
**accepted**. An instrument whose attacks are all refused proves nothing on its
own — a server that refused everything would report an identical clean sweep,
which is what task 10.40 found three of this project's instruments doing.

Usage (with the e2e stack up — see the README's "End-to-end integration suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -p tritrack-e2e -f docker-compose.yml -f docker-compose.e2e.yml \\
        up --build -d
    python3 scripts/verify_11_24_attribution.py

Exits non-zero if any attack succeeded or any positive control failed.
"""
import inspect
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import (  # noqa: E402
    ENVELOPE,
    MUTATION_RULES,
    author_naming_tables,
    join_by_code,
    outcome_for,
    preflight,
)

BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")

T = "2026-08-01T12:00:00.000Z"
T2 = "2026-08-02T12:00:00.000Z"


# ---------------------------------------------------------------- wire helpers


def call(path, body, token=None, method="POST"):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        BASE + path,
        data=data,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": raw[:200].decode("utf-8", "replace")}


class Person:
    """One signed-in account: session token, server-chosen user id, device."""

    def __init__(self, label):
        self.label = label
        self.email = f"t1124-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
        status, _ = call("/auth/magic-link", {"email": self.email})
        assert status == 202, f"magic-link for {label}: {status}"
        path = os.path.join(LINK_DIR, self.email + ".link")
        import time

        for _ in range(80):
            if os.path.exists(path):
                break
            time.sleep(0.1)
        else:
            raise SystemExit(f"no magic link for {label} at {path}")
        token = open(path).read().split("token=")[1].strip()
        self.device = "dev-" + uuid.uuid4().hex[:8]
        status, body = call(
            "/auth/redeem", {"token": token, "device_id": self.device}
        )
        assert status == 200, f"redeem for {label}: {status} {body}"
        self.token = body["session_token"]
        self.id = body["user_id"]

    def __repr__(self):
        return f"<{self.label} {self.id[:8]}>"


def push(who, pid, rows):
    return call(
        "/sync/push",
        {**ENVELOPE, "project_id": pid, "device_id": who.device, "rows": rows},
        who.token,
    )


# ------------------------------------------------------------------ row shapes


def sync_meta(uid, revision=1, updated=T):
    return {
        "created_at": T,
        "updated_at": updated,
        "deleted_at": None,
        "revision": revision,
        "last_modified_by": uid,
        "origin_device_id": "dev-x",
    }


def user_row(who):
    return {
        "user_id": who.id,
        "first_name": who.label.capitalize(),
        "last_name": "Person",
        "email": who.email,
        **sync_meta(who.id),
    }


def project_row(pid, owner_id):
    return {
        "project_id": pid,
        "project_name": "Field season",
        "description": None,
        "notes": None,
        "owner_user_id": owner_id,
        "creation_date": T,
        "bbox_min_lat": None,
        "bbox_min_lon": None,
        "bbox_max_lat": None,
        "bbox_max_lon": None,
        "datum": "WGS84",
        **sync_meta(owner_id),
        "coordinate_format": "dd",
        "triangulation_window_minutes": 15,
    }


def membership_row(mid, pid, uid, role, actor, revision=1, end_date=None):
    return {
        "membership_id": mid,
        "project_id": pid,
        "user_id": uid,
        "join_date": T,
        "end_date": end_date,
        "role": role,
        **sync_meta(actor, revision),
    }


def tag_row(pid, tid, uid, revision=1, name=None, status="active",
            deleted_at=None):
    """A tag. **`pid` and `deleted_at` are new in task 11.219.** A tag belongs to
    one project, so the row is keyed `(tag_id, project_id)` — and the tombstone
    route that `project_tag_row` used to carry is now a `deleted_at` on the tag
    itself, which is what probe 3 below pushes."""
    return {
        "tag_id": tid,
        "project_id": pid,
        "lineage_id": tid,
        "copied_at": None,
        "frequency_mhz": 150.5,
        "pulse_rate": 60.0,
        "pulse_pattern": None,
        "tag_name": name or ("Collar " + tid[:4]),
        "date_put_on": T,
        "date_removed": None,
        "status": status,
        "capture_date": None,
        "notes": None,
        **sync_meta(uid, revision),
        # After the spread, deliberately: `sync_meta` sets `deleted_at` to None
        # and would otherwise silently undo the tombstone this parameter exists
        # to send. Watched failing that way first.
        "deleted_at": deleted_at,
        "color_hex": "#3366CC",
    }


# `project_tag_row` is gone with `Project_Tags` (task 11.219): a tag is created
# inside the project that holds it, so `tag_row`'s `pid` is what the link row
# used to say, and its `deleted_at` is the tombstone route.


def observation(oid, pid, uid, tid=None, revision=1, bearing=90.0,
                modified_by=None):
    return {
        "observation_id": oid,
        "project_id": pid,
        "user_id": uid,
        "tag_id": tid,
        "timestamp_local": T,
        "timestamp_utc": T,
        "timezone_offset": "+00:00",
        "latitude": 35.19,
        "longitude": -111.65,
        "position_source": "gps_fix",
        "position_accuracy_m": 5.0,
        "elevation": 2100.0,
        "altitude_agl": 0.0,
        "magnetic_bearing": bearing,
        "true_north_bearing": bearing,
        "bearing_uncertainty": 5.0,
        "observation_type": "directional",
        "bearing_capture_method": "single_point",
        "bearing_method": "peak",
        "signal_type": "regular_pulse",
        "signal_strength": "strong",
        "bearing_quality": "good",
        "notes": None,
        **sync_meta(modified_by or uid, revision),
        "tag_version_id": None,
    }


def exclusion(xid, pid, observation_id, uid, kind="superseded",
              superseded_by=None, reason=None, revision=1, deleted_at=None,
              modified_by=None):
    row = {
        "exclusion_id": xid,
        "project_id": pid,
        "observation_id": observation_id,
        "user_id": uid,
        "kind": kind,
        "superseded_by_observation_id": superseded_by,
        "reason": reason,
        **sync_meta(modified_by or uid, revision),
    }
    row["deleted_at"] = deleted_at
    return row


def non_detection(nid, pid, uid, tid, revision=1):
    return {
        "non_detection_id": nid,
        "project_id": pid,
        "user_id": uid,
        "tag_ids_listened_for": tid,
        "timestamp_local": T,
        "timestamp_utc": T,
        "timezone_offset": "+00:00",
        "latitude": 35.2,
        "longitude": -111.6,
        "position_source": "gps_fix",
        "position_accuracy_m": 5.0,
        "elevation": 2100.0,
        "altitude_agl": 0.0,
        "notes": None,
        **sync_meta(uid, revision),
    }


def user_email_row(eid, uid, address):
    return {
        "user_email_id": eid,
        "user_id": uid,
        "email": address,
        "recorded_at": T,
        **sync_meta(uid),
    }


# ------------------------------------------------------------------- reporting


ATTACK_FAILURES = []
CONTROL_FAILURES = []
NOTES = []
_current = {"name": None}


def probe(name):
    _current["name"] = name
    print(f"\n=== {name}")


#: **The duplicate-name guard, added by task 11.220 — copied from
#: `verify_11_49_server_reads.py`, which already had it.**
#:
#: `CLAUDE.md`'s rule from task 11.88: *if a structure is keyed by a string
#: somebody types, a duplicate key must be a hard error, not a last write wins.*
#: 11.88 found `attack()` called with the same description for unrelated checks
#: and a genuinely flipped attack reported as blind. **The guard it prompted was
#: written into `verify_c1_row_naming.py`'s `check()` and into
#: `verify_11_49_server_reads.py` — not into the `attack()` implementations where
#: the defect actually lives.** This file was one of them. `attack()` and
#: `control()` here append to shared failure lists keyed by their `what`
#: string, and this file also has no `RESULTS` dict to overwrite — so the harm
#: here is a *reader* seeing two identically-named lines and being unable to
#: tell which probe each belongs to, plus the same hazard the day this file
#: grows a results dict like its three siblings.
#:
#: Task 11.220 then recorded `verify_round8_server_surface.py` as the last one
#: without it. **That was wrong, and task 11.221 measured it (2026-09-10):**
#: round8 has carried the same guard under the name `_claim` since its first
#: commit (task 11.64), and both of its `RESULTS` writes go through it. All
#: four `attack()` implementations are guarded.
_REGISTERED = {}


def _register(key):
    caller = inspect.stack()[2]
    site = f"{os.path.basename(caller.filename)}:{caller.lineno}"
    prior = _REGISTERED.get(key)
    if prior is not None:
        raise SystemExit(
            f"\nDUPLICATE CHECK NAME: {key!r} is registered twice — first "
            f"at {prior}, again at {site}. attack()/control() names key a "
            f"shared results dict; the second call silently overwrites the "
            f"first one's verdict, so a genuinely flipped check would be "
            f"reported as held. Give one of these two call sites a different, "
            f"more specific description."
        )
    _REGISTERED[key] = site


def attack(what, refused, detail=""):
    _register(what)
    print(f"{'  refused ' if refused else '  ADMITTED'}  {what}"
          + (f"   [{detail}]" if detail else ""))
    if not refused:
        ATTACK_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def control(what, accepted, detail=""):
    _register("control: " + what)
    print(f"{'  control ' if accepted else '  BLIND   '}  {what}"
          + (f"   [{detail}]" if detail else ""))
    if not accepted:
        CONTROL_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def note(text):
    print(f"  note      {text}")
    NOTES.append(f"{_current['name']}: {text}")


# ------------------------------------------------------------------- the stack


preflight(BASE, LINK_DIR)

owner = Person("owner")
contrib = Person("contrib")
stranger = Person("stranger")

P = str(uuid.uuid4())
TAG_A = str(uuid.uuid4())
TAG_B = str(uuid.uuid4())
OBS_OWNER = str(uuid.uuid4())

status, body = push(owner, P, {
    "Users": [user_row(owner)],
    "Projects": [project_row(P, owner.id)],
    # A real device writes the founding owner's membership row when the
    # project is created (task 8.4) and pushes it with the rest. Modelled
    # here because it is load-bearing: `resolveProjectOwners` falls back to
    # `Projects.owner_user_id` only while a project has *no* open owner
    # membership, so a fixture that omits it stops resolving the founder as
    # an owner the moment a co-owner is invited.
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), P, owner.id, "owner", owner.id)
    ],
    "Tags": [tag_row(P, TAG_A, owner.id), tag_row(P, TAG_B, owner.id)],
    "Observations": [observation(OBS_OWNER, P, owner.id, TAG_A)],
})
assert status == 200, f"publish: {status} {body}"

# The contributor joins through the real join-code flow, because that is the
# only thing that puts a membership row in place — and the membership row is
# what put every teammate inside the vouching set in the first place.
#
# **Task 11.85 rewrote these three lines.** They used to invite; task 11.81
# deleted `POST /projects/<id>/invites` and this instrument died at `404`
# before scoring a single probe. Not a finding — an instrument that could no
# longer reach the check.
join_by_code(call, owner.token, P, contrib.token, "contributor")
status, body = push(contrib, P, {"Users": [user_row(contrib)]})
assert status == 200, f"contributor profile: {status} {body}"


# =================================================================== probe 1 ===

probe("1. Attribution — derived from the rule, not from a list of tables")

DERIVED = author_naming_tables()
note("tables whose MutationRule names an author, parsed from "
     f"mutation_rules.dart: {sorted(DERIVED)}")

#: One forged row per derived table: the contributor building a record that
#: names the **owner** as its author. Keyed by table so a table with no builder
#: aborts the run rather than being silently skipped — which is exactly how
#: `Non_Detections` went three findings without being probed.
ROW_BUILDERS = {
    "Observations":
        lambda uid: observation(str(uuid.uuid4()), P, uid, TAG_A,
                                bearing=270.0),
    "Observation_Exclusions":
        lambda uid: exclusion(str(uuid.uuid4()), P, OBS_OWNER, uid,
                              reason="not my words"),
    "Non_Detections":
        lambda uid: non_detection(str(uuid.uuid4()), P, uid, TAG_A),
    # Global, and closed by a different rule (§4.18's authenticated-address
    # requirement). Probed anyway: "closed by another rule" is a claim, and an
    # unprobed claim is how this project's last five findings started.
    "Users":
        lambda uid: {**user_row(owner), "first_name": "Forged",
                     "user_id": uid, "revision": 9},
    "User_Emails":
        lambda uid: user_email_row(str(uuid.uuid4()), uid, owner.email),
}

uncovered = sorted(set(DERIVED) - set(ROW_BUILDERS))
if uncovered:
    raise SystemExit(
        f"ABORT: {uncovered} name an author and this instrument has no row "
        f"builder for them, so it would report a clean sweep having never "
        f"probed them. Add a builder to ROW_BUILDERS. This abort is the "
        f"coverage assertion — do not remove it."
    )
stale = sorted(set(ROW_BUILDERS) - set(DERIVED))
if stale:
    raise SystemExit(
        f"ABORT: this instrument builds rows for {stale}, which no longer "
        f"name an author. Either the rule changed or the builder is stale; "
        f"decide which, rather than leaving a probe measuring nothing."
    )

for table in sorted(DERIVED):
    row = ROW_BUILDERS[table](owner.id)
    status, body = push(contrib, P, {table: [row]})
    got = outcome_for(body, table, row)
    attack(f"a contributor filing a {table} row under the owner's name",
           got == "unauthorized", f"{MUTATION_RULES[table]} / {got!r}")

# POSITIVE CONTROL (must accept): the contributor's own record on each of the
# project-scoped tables. If these were refused the sweep above would be
# measuring a server that refuses everything.
for table in ("Observations", "Observation_Exclusions", "Non_Detections"):
    row = ROW_BUILDERS[table](contrib.id)
    status, body = push(contrib, P, {table: [row]})
    got = outcome_for(body, table, row)
    control(f"a contributor filing their own {table} row",
            got == "inserted", repr(got))

# POSITIVE CONTROL (must refuse): naming someone the project cannot reach was
# already closed, and must stay closed.
row = observation(str(uuid.uuid4()), P, stranger.id, TAG_A)
status, body = push(contrib, P, {"Observations": [row]})
control("naming a stranger the project cannot reach is still refused",
        outcome_for(body, "Observations", row) == "unauthorized",
        repr(outcome_for(body, "Observations", row)))

# Re-attributing a **stored** row was never open and must stay shut.
OWN = str(uuid.uuid4())
row = observation(OWN, P, contrib.id, TAG_A)
push(contrib, P, {"Observations": [row]})
row = observation(OWN, P, owner.id, TAG_A, revision=2)
status, body = push(contrib, P, {"Observations": [row]})
attack("re-attributing a stored observation to the owner",
       outcome_for(body, "Observations", row) == "unauthorized",
       repr(outcome_for(body, "Observations", row)))


# =================================================================== probe 2 ===

probe("2. The audit column — who a record says last touched it")

# `last_modified_by` is a user column like any other, and it is what task
# 11.18's "…then withdrawn by *name*" sentence in the Team log reads.
row = observation(str(uuid.uuid4()), P, contrib.id, TAG_A,
                  modified_by=owner.id)
status, body = push(contrib, P, {"Observations": [row]})
attack("a contributor stamping the owner as the last person to touch "
       "their own record",
       outcome_for(body, "Observations", row) == "unauthorized",
       repr(outcome_for(body, "Observations", row)))

# The update arm: a mark the contributor authored, withdrawn by the owner —
# who leaves the contributor's name in the audit column. Task 11.15 makes this
# update legitimate; the question is whose name the log then shows.
MARK = str(uuid.uuid4())
row = exclusion(MARK, P, OBS_OWNER, contrib.id, reason="superseded by mine")
status, body = push(contrib, P, {"Observation_Exclusions": [row]})
control("the contributor's mark lands, so the withdrawal below has "
        "something to act on",
        outcome_for(body, "Observation_Exclusions", row) == "inserted",
        repr(outcome_for(body, "Observation_Exclusions", row)))

row = exclusion(MARK, P, OBS_OWNER, contrib.id, reason="superseded by mine",
                revision=2, deleted_at=T2, modified_by=contrib.id)
status, body = push(owner, P, {"Observation_Exclusions": [row]})
attack("an owner withdrawing a mark while leaving the contributor's name "
       "in the audit column (task 11.18's \"withdrawn by\" sentence)",
       outcome_for(body, "Observation_Exclusions", row) == "unauthorized",
       repr(outcome_for(body, "Observation_Exclusions", row)))

# POSITIVE CONTROL: the same withdrawal, stamped honestly, must still work —
# task 11.15's whole purpose is that a mark whose author left is withdrawable.
row = exclusion(MARK, P, OBS_OWNER, contrib.id, reason="superseded by mine",
                revision=3, deleted_at=T2, modified_by=owner.id)
status, body = push(owner, P, {"Observation_Exclusions": [row]})
control("an owner withdrawing a contributor's mark under their own name",
        outcome_for(body, "Observation_Exclusions", row) == "updated",
        repr(outcome_for(body, "Observation_Exclusions", row)))


# =================================================================== probe 3 ===

probe("3. Owner-only rules the app claims — checked at the server "
      "(task 11.26's class)")

# T3. **Retranslated by task 11.220, and one of these four flipped.**
#
# What stood here measured `Project_Tags`: the app's
# `project_tag_repository.dart` required an owner before deactivating a project's
# tag link, and the row carrying that change was an ordinary `Project_Tags`
# update. Task 11.219 retired that table and folded
# `DenialReason.removeTagRequiresOwner` into `changeTagRequiresOwner` — its doc
# comment says why: a tag belongs to one project now, so taking it out of the
# project *is* changing it, and one rule covers both routes.
#
# So the two attacks move onto `Tags` and keep their answers. **The positive
# control below does not**, and it is the interesting half — see its own note.
row = tag_row(P, TAG_B, contrib.id, revision=2, status="recovered")
status, body = push(contrib, P, {"Tags": [row]})
attack("a contributor removing a tag from the project (status → recovered)",
       outcome_for(body, "Tags", row) == "unauthorized",
       repr(outcome_for(body, "Tags", row)))

# The same subtraction by the other route the schema allows: a tombstone. The
# app has no method for this one, so it is reachable only by a crafted push or by
# a device editing its own SQLite file, which §4.23 says is always possible.
row = tag_row(P, TAG_B, contrib.id, revision=3, deleted_at=T2)
status, body = push(contrib, P, {"Tags": [row]})
attack("a contributor tombstoning the project's tag",
       outcome_for(body, "Tags", row) == "unauthorized",
       repr(outcome_for(body, "Tags", row)))

# POSITIVE CONTROL: creating a tag stays contributor-level (matrix T2 —
# additive, unblocking). A fix that refused this would break field work: a tech
# in a canyon with no signal could not record a bearing against a collar they
# just fitted.
#
# **One row where there were two (task 11.219)** — "creating a tag and adding it
# to the project" was a `Tags` insert plus a `Project_Tags` link, and creating a
# tag inside a project is the whole operation now.
TAG_C = str(uuid.uuid4())
rows = {"Tags": [tag_row(P, TAG_C, contrib.id)]}
status, body = push(contrib, P, rows)
control("a contributor creating a tag in the project",
        outcome_for(body, "Tags", rows["Tags"][0]) == "inserted",
        repr(outcome_for(body, "Tags", rows["Tags"][0])))

# POSITIVE CONTROL: an owner may still remove a tag from the project — the
# operation the matrix says is owner-only must actually work for an owner.
#
# On its own tag, deliberately. Run against TAG_B it would only pass while the
# attacks above were refused (they advance the revision), so one regression would
# show up as two failures and the control would have stopped being independent
# evidence of anything.
TAG_D = str(uuid.uuid4())
rows = {"Tags": [tag_row(P, TAG_D, owner.id)]}
status, body = push(owner, P, rows)
control("the owner's own tag exists to remove",
        outcome_for(body, "Tags", rows["Tags"][0]) == "inserted",
        repr(outcome_for(body, "Tags", rows["Tags"][0])))
row = tag_row(P, TAG_D, owner.id, revision=2, status="recovered")
status, body = push(owner, P, {"Tags": [row]})
control("an owner removing a tag from the project",
        outcome_for(body, "Tags", row) == "updated",
        repr(outcome_for(body, "Tags", row)))

# **THE ONE THAT FLIPPED, and it is a narrowing of what a contributor may do.**
#
# A check stood here that is deleted: *"a contributor may still put a tag back —
# only the subtraction is reserved"*, matrix T2's other half. Reactivating a
# `Project_Tags` link was additive and unblocking, on the same rung as creating a
# tag, so it deliberately did not inherit the owner-only removal rule.
#
# Task 11.219 moved the asymmetry from *add versus remove* to **create versus
# change**: `RowAuthorizer._authorizeTagLifecycle` lets a contributor create a
# tag and reserves every change to an existing one for an owner. Un-retiring a
# tag is a change, so it is now owner-only in both directions.
#
# **Measured here rather than asserted, and reported as a `note` rather than an
# `attack`, because nobody has decided it is wanted.** It is not a refusal this
# instrument exists to demand; it is a consequence somebody should look at. What
# it costs a person: a contributor who finds a tag an owner retired cannot put it
# back — they create a new tag, or wait for an owner. See Discovered Scope under
# task 11.220.
row = tag_row(P, TAG_D, contrib.id, revision=3, status="active")
status, body = push(contrib, P, {"Tags": [row]})
put_back = outcome_for(body, "Tags", row)
note(f"a contributor putting a retired tag back: {put_back!r} — matrix T2's "
     f"reactivation half was contributor-level while a tag was linked rather "
     f"than owned, and task 11.219 made it owner-only. Nobody has decided "
     f"whether that narrowing is wanted.")

# T4/T5 — editing or retiring a tag the project holds is owner-only.
# **`_authorizeTagReferences` used to enforce it and is deleted (task 11.219);
# `_authorizeTagLifecycle` does now.** Re-measured, not assumed.
row = tag_row(P, TAG_A, contrib.id, revision=2,
              name="Renamed by a contributor")
status, body = push(contrib, P, {"Tags": [row]})
attack("a contributor renaming a tag the project uses",
       outcome_for(body, "Tags", row) == "unauthorized",
       repr(outcome_for(body, "Tags", row)))

row = tag_row(P, TAG_A, contrib.id, revision=2, status="recovered")
status, body = push(contrib, P, {"Tags": [row]})
attack("a contributor retiring a tag the project uses",
       outcome_for(body, "Tags", row) == "unauthorized",
       repr(outcome_for(body, "Tags", row)))

# O5/O6 — excluding a bearing is owner-only, and already enforced.
row = exclusion(str(uuid.uuid4()), P, OBS_OWNER, contrib.id, kind="excluded")
status, body = push(contrib, P, {"Observation_Exclusions": [row]})
attack("a contributor excluding a bearing from the analysis",
       outcome_for(body, "Observation_Exclusions", row) == "unauthorized",
       repr(outcome_for(body, "Observation_Exclusions", row)))

# P2 — project settings are owner-only.
row = {**project_row(P, owner.id), "project_name": "Renamed",
       "revision": 2, "last_modified_by": contrib.id}
status, body = push(contrib, P, {"Projects": [row]})
attack("a contributor renaming the project",
       outcome_for(body, "Projects", row) == "unauthorized",
       repr(outcome_for(body, "Projects", row)))

# P6 — deleting the project is owner-only.
row = {**project_row(P, owner.id), "revision": 3,
       "last_modified_by": contrib.id, "deleted_at": T2}
status, body = push(contrib, P, {"Projects": [row]})
attack("a contributor deleting the project for everybody",
       outcome_for(body, "Projects", row) == "unauthorized",
       repr(outcome_for(body, "Projects", row)))


# ---------------------------------------------------------------------- report

print("\n" + "=" * 72)
if NOTES:
    print("Observations (not pass/fail — read them):")
    for n in NOTES:
        print(f"  - {n}")
    print()
if CONTROL_FAILURES:
    print("BLIND CONTROLS — this run measured nothing it claims to have:")
    for f in CONTROL_FAILURES:
        print(f"  - {f}")
if ATTACK_FAILURES:
    print("ATTACKS THAT SUCCEEDED:")
    for f in ATTACK_FAILURES:
        print(f"  - {f}")
if not (CONTROL_FAILURES or ATTACK_FAILURES):
    print("Every attack refused; every positive control fired.")
print("=" * 72)

sys.exit(1 if (CONTROL_FAILURES or ATTACK_FAILURES) else 0)

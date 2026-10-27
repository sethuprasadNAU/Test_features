#!/usr/bin/env python3
# gate-instrument: verify_h3_existence_oracle_sweep
"""Probes **every** table in `sync_tables.dart` for a key-claiming existence
oracle (`TriTrack_Security_Model.md` §4.13's residual, §10.7 finding H-3,
task 10.45).

**Why this script exists, in one sentence.** Three straight gates fixed the
table that had a reproduction and then wrote the result up as a rule that was
believed to cover the rest of the tables — C-2 became "closed" and D-1 arm (c)
turned up on `Observations`, the fix for that became "closed by project
scoping" and G-4 turned up on `User_Emails`, and the restatement of *that*
became "`Tags` is covered by the reachability rule" and H-3 turned up on
`Tags`. Every one of those beliefs was produced by reading `RowAuthorizer` or
`sync_tables.dart`, not by asking the server. This script asks the server,
once, about every table, so the next belief about which tables are covered is
a probe result instead of an inference.

**The table list is derived, not carried (task 11.21).** As first written this
script hardcoded its own list of eleven tables, and task 11.7 added a twelfth
(`Observation_Exclusions`) without it. So for the four months between, §4.13's
"probes every table" claim was true of the script's list and false of the
schema — the same shape as the beliefs above, one level up: an instrument
asserting completeness it did not have. The list now comes from
`gate_wire.PRIMARY_KEYS`, which is parsed out of `sync_tables.dart`, and a
table with no probe registered below **aborts the run** rather than going
unmentioned. Row *shapes* are still hand-written, because a minimal-but-valid
row needs semantics no descriptor carries (which enum value `kind` accepts,
that a latitude must be a real number); what is derived is the thing that
silently rotted, which is the list.

**The question, for every table.** From an ordinary session with no
relationship to the victim or their project: does claiming a primary-key value
another caller already used answer differently than claiming a value nobody
has used? For the tables task 10.35 made project-scoped, the key includes
`project_id`, which the prober cannot set to someone else's project — so the
expected result is "no", mechanically, rather than assumed from the one or two
that happened to get a reproduction. For the **two** tables left globally keyed
(`Users`, `User_Emails`), a genuine collision is possible and the answer is
table-specific:

  - `Users` — covered by §4.17's naming invariant: an unsolicited write naming
    someone else is refused whether or not that user id exists, so existence
    is not what the outcome reports.
  - `User_Emails` — **not covered.** Reproduces G-4: a self-owned
    `user_email_id` another user already holds answers differently than a free
    one.

**`Tags` and `Tag_Versions` were on that list and are not (task 11.219, this
instrument retranslated by task 11.220).** They were global, so a `tag_id`
another project held answered `lost_to_server` where a free one answered
`inserted` — H-3, and its `Tag_Versions` sibling from task 11.32, both accepted
as disclosure-only findings on the strength of the key being an unguessable
122-bit UUIDv4. **Both are now keyed `(id, project_id)`**, so the prober cannot
form the victim's whole key at all and the collision is gone, which is exactly
how task 10.35 closed arm (c) of D-1 for the six tables before them. The
accepted-findings list went from four tables to two, and `RECORDED_FINDINGS`
below says what that costs if either key is ever un-scoped again.

`Projects` is a third, older, and already-documented case: its id **is** its
scope, so 10.35's project-scoping could not reach it the way it reached the
other data tables. §4.13 states and bounds this one explicitly — a successful
first publish is inherently distinguishable from a refusal, because a
create-if-absent operation on a client-chosen key cannot exist without that
asymmetry. It is recorded in `RECORDED_FINDINGS` below beside the two gaps so
the sweep proves it is *still* only these three, not because it is the same
kind of gap.

**`Deployments` aborted this sweep from 2026-09-13 to 2026-09-23 (task
11.311)**, because it was synced without a probe — `check_coverage` doing
exactly what it is for. The verdict was decided and written into §4.13 first
(indistinguishable by construction, with the reasons located in the code),
and `_deployments` below tests it. It is also the first probe to declare
`free_must_answer`, because it is the first table whose server-side rules could
refuse one arm *because of the other* — see its docstring.

`User_Emails` is accepted as a non-blocking finding, unchanged from G-4's own
reasoning (`§4.13`, `§9.5`): the key is a client-generated UUIDv4 that appears
in no share payload, so exploiting it means guessing 122 bits for one bit of an
answer about a key nobody can predict, and the victim's row is left untouched
either way. **Accepting it is recorded here, not decided here.**

**The second `schemaMajor` bump that sentence used to speculate about has been
spent, and not on this.** Task 10.45's entry framed closing `User_Emails` and
`Tags` as one design call awaiting a major bump; task 11.219 spent major 3 on
making tags project-scoped for an unrelated product reason, and closed the
`Tags` half as a side effect. `User_Emails` is what is left of that call, and it
is now a smaller question than the one that was deferred — one table rather
than three. This script's job is unchanged: keep the decision honest by
re-proving, every run, that this is still the complete list of what is open.

Usage (with the e2e stack up — see the README's "End-to-end integration
suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -p tritrack-e2e -f docker-compose.yml \\
        -f docker-compose.e2e.yml up --build -d
    python3 scripts/verify_h3_existence_oracle_sweep.py

Exits non-zero if a table **outside** the recorded, accepted findings turns out
distinguishable — that is a new finding, not a known one — or if any table in
`syncTables` has no probe. The recorded findings themselves are printed loudly
but do not fail the run; delete them from `RECORDED_FINDINGS` below the day
they are closed for real, and this script will start failing until it is.
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
    PRIMARY_KEYS,
    outcome_for,
    preflight,
    row_key,
)

BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")

T = "2026-08-01T12:00:00.000Z"
# Global keys are not reset between runs, so every id below is a fresh UUIDv4 —
# a literal collision with an earlier run's row would look exactly like the
# oracle this script is trying to detect.
RUN = uuid.uuid4().hex[:8]

PROJECTS = "Projects"

#: Table -> one-line reason it is accepted rather than fixed. These are the
#: ONLY tables this run may report as distinguishable without failing.
#: Anything else that comes back distinguishable is new and the run exits
#: non-zero.
RECORDED_FINDINGS = {
    "User_Emails": "G-4 (§9.5) — accepted, 122-bit UUIDv4 key, disclosure only",
    "Projects": "§4.13's stated, bounded residual — a project's id IS its "
                "scope, so this is the one collision that cannot be removed "
                "without removing the ability to create a project; the "
                "victim's row is verified untouched below regardless",
}

# **`Tags` and `Tag_Versions` came off this list on 2026-09-10 (task 11.220),
# because task 11.219 closed them for real.** This module's docstring has always
# said to delete an entry the day its finding closes, and this is that day:
# both tables are keyed `(id, project_id)` now, so a stranger claiming the
# victim's id inside their own project names a different row and there is no
# collision left to be uniform about. Closed the same way arm (c) of D-1 was —
# by project-scoping the key, not by adding a check.
#
# **Removing the entries is the load-bearing half, not tidying.** While a table
# sits on this list, a distinguishable result for it prints `FINDING` and the
# run still exits 0. Off the list, the same result prints `***NEW***` and fails
# the run. So if a future schema change un-scopes either key, this instrument
# now says so loudly instead of quietly accepting a finding that was closed
# fifteen months earlier.
#
# The list was four tables and is two. If the `User_Emails` design call is ever
# reopened, it is reopened for `User_Emails` alone plus `Projects`' stated
# residual — the sentence that used to say "reopen it for all four together" is
# gone with the two that no longer belong to it.


def nid():
    return str(uuid.uuid4())


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
    email = f"h3sweep-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
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


def push(actor, project, rows):
    """Pushes `rows` as `actor` into `project`, returning the response dict."""
    status, body = call("/sync/push", {
        **ENVELOPE, "project_id": project, "device_id": actor["device"],
        "rows": rows,
    }, actor["token"])
    try:
        return status, json.loads(body)
    except json.JSONDecodeError:
        return status, {"_raw": body[:200]}


# --- Row builders, one per table, minimal-but-valid ------------------------

def user_row(uid, first, email=None):
    return {"user_id": uid, "first_name": first, "last_name": "Person",
            "email": email or f"{first.lower()}-{uid[:8]}@example.org",
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def user_email_row(email_id, uid, email):
    # The pusher's own authenticated address (task 10.55): any other is refused
    # for the address, which would make the probe below agree with itself for a
    # reason that has nothing to do with the key.
    return {"user_email_id": email_id, "user_id": uid,
            "email": email,
            "recorded_at": T, "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def project_row(pid, owner, name="Field"):
    return {"project_id": pid, "project_name": name, "owner_user_id": owner,
            "creation_date": T, "datum": "WGS84", "created_at": T,
            "updated_at": T, "revision": 1, "last_modified_by": owner,
            "origin_device_id": "device-x", "coordinate_format": "dd",
            "triangulation_window_minutes": 15}


def membership_row(mid, pid, uid, role="owner"):
    return {"membership_id": mid, "project_id": pid, "user_id": uid,
            "join_date": T, "role": role, "created_at": T, "updated_at": T,
            "revision": 1, "last_modified_by": uid, "origin_device_id": "device-x"}


def tag_version_row(vid, pid, tid, uid, name="Tag"):
    """Task 11.32: what a tag read at a moment.

    Both arms name a tag the pusher's own project holds, so the project scope
    check passes identically in each and the only difference left between the
    two pushes is the `tag_version_id` being claimed — which is what the probe
    has to isolate. Both are inserts, which is the contributor-level rung; the
    owner-only rung is on *rewriting* a version and would put a check in front
    of the key comparison, making the arms agree for a reason that has nothing
    to do with the key. Probe the most permissive route to a write, not the
    most restricted one.

    **`pid` is new in task 11.219** — a version is a version of one project's
    tag, and the row is keyed `(tag_version_id, project_id)`.
    """
    return {"tag_version_id": vid, "project_id": pid, "tag_id": tid,
            "effective_from": T, "frequency_mhz": 150.1, "pulse_rate": None,
            "pulse_pattern": None, "tag_name": name,
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def individual_row(pid, iid, uid, name="Animal"):
    """An animal (task 11.240, schema v16). Keyed `(individual_id,
    project_id)` like a tag, and for the same reason; `lineage_id` is its own
    id, which is what the v16 backfill writes for an animal nobody copied, and
    nothing on the server reads it."""
    return {"individual_id": iid, "project_id": pid, "name": name,
            "color_hex": "#FF0000", "status": "alive", "species": None,
            "sex": None, "notes": None, "lineage_id": iid, "copied_at": None,
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def tag_row(pid, tid, uid, name="Tag"):
    """A tag. **`pid` is new in task 11.219**: a tag belongs to one project,
    the column is `NOT NULL`, and the row is keyed `(tag_id, project_id)`.
    `lineage_id` is the tag's own id, which is what both migrations write for a
    tag nobody copied, and nothing on the server reads it."""
    return {"tag_id": tid, "project_id": pid, "lineage_id": tid,
            "copied_at": None,
            "frequency_mhz": 150.1, "tag_name": name,
            "date_put_on": T, "status": "active", "color_hex": "#FF0000",
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


# `project_tag_row` is gone with `Project_Tags` (task 11.219): a tag is created
# inside the project that holds it, so `tag_row`'s `pid` is what the link row
# used to say.


def deployment_row(did, pid, tid, iid, uid):
    """Which collar was on which animal, from when (task 11.243, schema v17).

    Keyed `(deployment_id, project_id)`. Both ends are same-project composite
    foreign keys, so `tid` and `iid` must name a tag and an animal the pushing
    project holds — or that the same push creates, which is how the victim's
    seed satisfies them. Open-ended (`removed_date` null), which is the widest
    interval the interlock can be asked about; the probe's two arms are kept
    apart by naming different ends, not by their dates.
    """
    return {"deployment_id": did, "project_id": pid, "tag_id": tid,
            "individual_id": iid, "attached_date": T, "removed_date": None,
            "notes": None, "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def triangulation_session_row(sid, pid, tid, uid):
    return {"session_id": sid, "project_id": pid, "tag_id": tid,
            "label": "Probe", "started_at_local": T, "started_at_utc": T,
            "started_at_offset": "+00:00", "notes": None,
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def observation_row(oid, pid, uid, tid=None):
    return {"observation_id": oid, "project_id": pid, "user_id": uid,
            "tag_id": tid, "timestamp_local": T, "timestamp_utc": T,
            "timezone_offset": "+00:00", "latitude": 35.19, "longitude": -111.65,
            "position_source": "gps_fix", "elevation": 2100.0, "altitude_agl": 0.0,
            "observation_type": "directional", "signal_type": "regular_pulse",
            "signal_strength": "strong", "notes": None,
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def observation_exclusion_row(eid, pid, uid, oid, replacement):
    """A task 11.7 supersede mark: "this bearing is replaced by that one".

    **`kind` is `superseded`, not `excluded`, and that is the whole of the
    probe's design.** `RowAuthorizer._authorizeExclusionKind` refuses an
    `excluded` row from anyone who is not the project's owner, and it runs
    *before* the row is looked up — so an `excluded` probe would have a check
    in front of the key comparison that can only make the two arms agree more
    often. `superseded` is the contributor-level kind with nothing in front of
    it, which makes it the arm where a key-dependent difference would actually
    show. A sweep should always probe the most permissive route to a write, not
    the most restricted one.
    """
    return {"exclusion_id": eid, "project_id": pid,
            "observation_id": oid, "user_id": uid,
            "kind": "superseded", "superseded_by_observation_id": replacement,
            "reason": None,
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def non_detection_row(nd_id, pid, uid):
    return {"non_detection_id": nd_id, "project_id": pid, "user_id": uid,
            "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
            "latitude": 35.19, "longitude": -111.65, "position_accuracy_m": None,
            "position_source": "gps_fix", "elevation": 2100.0, "altitude_agl": 0.0,
            "tag_ids_listened_for": "[]", "notes": None,
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def estimated_position_row(pos_id, pid, tid, uid):
    return {"position_id": pos_id, "project_id": pid, "tag_id": tid,
            "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
            "latitude": 35.19, "longitude": -111.65, "semi_major_axis": 50.0,
            "semi_minor_axis": 20.0, "rotation_angle": 10.0,
            "method": "lenth_mle", "observation_ids_used": "[]", "notes": None,
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def actual_tag_location_row(loc_id, pid, tid, uid):
    return {"location_id": loc_id, "project_id": pid, "tag_id": tid,
            "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
            "latitude": 35.19, "longitude": -111.65, "uncertainty_radius": 5.0,
            "notes": None, "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


# --- The probe registry ----------------------------------------------------

#: table -> builder. A builder takes the run context and returns a dict with
#: three entries:
#:
#:   seed  — the row the *victim* publishes, which is what makes the claimed
#:           key genuinely held. Without it the "held" arm claims a key nobody
#:           owns and the comparison silently becomes free-versus-free, which
#:           reports COVERED for a table nobody tested. `check_probe` below
#:           refuses to let that happen.
#:   held  — (project to push into, row) — the stranger claiming the victim's id
#:   free  — (project to push into, row) — the stranger claiming a fresh id
#:
#: and optionally a fourth:
#:
#:   free_must_answer — the outcome the free arm is *required* to get. Task
#:           11.311. A `COVERED` verdict means "both arms answered the same",
#:           and two arms refused for one shared reason — a malformed row, a
#:           rule neither arm was meant to meet — answer the same too, which
#:           is defect vocabulary entry 65's comparison between two things
#:           that fail identically. A probe whose free arm is a push the
#:           stranger is fully entitled to make declares so here, and a run in
#:           which that push is not accepted scores the table `blind` and fails.
#:           Declared only where the free arm's answer is known from the code,
#:           not guessed: `Users`' free arm, for one, is refused by design.
PROBES = {}


def probe_for(table):
    def register(fn):
        PROBES[table] = fn
        return fn
    return register


def keys_are_scope_separated(table):
    """True when the prober cannot even *form* this table's key inside the
    victim's project, because `project_id` is part of the key and the only
    project the prober can write is their own (task 10.35, schema major 2).

    Derived from the parsed primary key rather than listed, so a table added
    tomorrow is classified by what its key actually is. `Projects` is the one
    exception the derivation has to name: `project_id` is its whole key, so
    the scope and the id are the same column and separating them is not
    possible — which is exactly §4.13's stated residual.
    """
    return table != PROJECTS and "project_id" in PRIMARY_KEYS[table]


@probe_for("Users")
def _users(ctx):
    # Global key; §4.17's naming invariant is what is expected to cover it.
    return {
        "seed": user_row(ctx["victim"]["uid"], "Victim", ctx["victim"]["email"]),
        "held": (ctx["stranger_project"], user_row(ctx["victim"]["uid"], "Impostor")),
        "free": (ctx["stranger_project"], user_row(nid(), "Nobody")),
    }


@probe_for("User_Emails")
def _user_emails(ctx):
    # Global key; G-4. Self-named (the stranger names themselves) so naming is
    # not what refuses this — the key collision is the whole of the answer,
    # which is the point. Since task 10.55 both rows must also carry the
    # stranger's *own* authenticated address, or the refusal is about the
    # address rather than about the key and the arm proves nothing.
    return {
        "seed": user_email_row(ctx["vid"]["User_Emails"], ctx["victim"]["uid"],
                               ctx["victim"]["email"]),
        "held": (ctx["stranger_project"],
                 user_email_row(ctx["vid"]["User_Emails"], ctx["stranger"]["uid"],
                                ctx["stranger"]["email"])),
        "free": (ctx["stranger_project"],
                 user_email_row(nid(), ctx["stranger"]["uid"],
                                ctx["stranger"]["email"])),
    }


@probe_for("Projects")
def _projects(ctx):
    # The id is its own scope; §4.13's stated, bounded residual.
    free_pid = nid()
    return {
        "seed": project_row(ctx["victim_project"], ctx["victim"]["uid"]),
        "held": (ctx["victim_project"],
                 project_row(ctx["victim_project"], ctx["stranger"]["uid"],
                             "Hostile takeover")),
        "free": (free_pid, project_row(free_pid, ctx["stranger"]["uid"], "Fresh")),
    }


@probe_for("Project_Memberships")
def _project_memberships(ctx):
    return {
        "seed": membership_row(ctx["vid"]["Project_Memberships"],
                               ctx["victim_project"], ctx["victim"]["uid"]),
        "held": (ctx["stranger_project"],
                 membership_row(ctx["vid"]["Project_Memberships"],
                                ctx["stranger_project"], ctx["stranger"]["uid"],
                                role="contributor")),
        "free": (ctx["stranger_project"],
                 membership_row(nid(), ctx["stranger_project"],
                                ctx["stranger"]["uid"], role="contributor")),
    }


@probe_for("Individuals")
def _individuals(ctx):
    # Task 11.240: scope-separated from the day it landed, keyed
    # `(individual_id, project_id)` exactly as `Tags` is — the stranger
    # claims the victim's `individual_id` inside their *own* project, the two
    # keys differ in `project_id`, and no collision is possible.
    # `keys_are_scope_separated` derives that from the parsed primary key.
    return {
        "seed": individual_row(ctx["victim_project"],
                               ctx["vid"]["Individuals"],
                               ctx["victim"]["uid"], "Victim's animal"),
        "held": (ctx["stranger_project"],
                 individual_row(ctx["stranger_project"],
                                ctx["vid"]["Individuals"],
                                ctx["stranger"]["uid"], "Claimed")),
        "free": (ctx["stranger_project"],
                 individual_row(ctx["stranger_project"], nid(),
                                ctx["stranger"]["uid"], "Free")),
    }


@probe_for("Tags")
def _tags(ctx):
    # **Scope-separated since task 11.219, which is what closed H-3.** The
    # stranger claims the victim's `tag_id` inside their *own* project, so the
    # two keys differ in their `project_id` and no collision is possible —
    # `keys_are_scope_separated` derives that from the parsed primary key, and
    # `check_probe` aborts if the held arm somehow reproduces the victim's whole
    # key. Written the same way as every other scoped table's probe.
    return {
        "seed": tag_row(ctx["victim_project"], ctx["victim_tag"],
                        ctx["victim"]["uid"], "Victim's tag"),
        "held": (ctx["stranger_project"],
                 tag_row(ctx["stranger_project"], ctx["victim_tag"],
                         ctx["stranger"]["uid"], "Claimed")),
        "free": (ctx["stranger_project"],
                 tag_row(ctx["stranger_project"], nid(),
                         ctx["stranger"]["uid"], "Free")),
    }


@probe_for("Deployments")
def _deployments(ctx):
    """Task 11.311 — the table the sweep aborted on from 2026-09-13.

    **The verdict was written before this probe existed**, in Security Model
    §4.13 ("`Individuals` and `Deployments`, decided before either was
    measured"): indistinguishable by construction, because the key carries
    `project_id`, a row naming the victim's project is refused before the
    stored row is consulted, and the collar interlock — the one rule this
    table has that reads *other* rows — reads only the pushing project's.

    **The two arms name different collars and different animals, and that is
    the design, not tidiness.** Both are inserts into the stranger's own
    project, pushed one after the other. Given the same collar or animal over
    the same dates, the second push would meet the first in the interlock and
    be refused *because of the stranger's own row* — a difference between the
    arms that the prober manufactured, which this sweep would print as a new
    oracle on the victim. With disjoint ends neither arm overlaps anything, so
    the interlock answers both the same and the only difference left is the
    claimed `deployment_id`.

    `free_must_answer` is what stops the opposite mistake: if both arms were
    refused (by the interlock, a reference, a malformed row) they would agree,
    and agreeing is all `COVERED` checks.
    """
    return {
        "seed": deployment_row(ctx["vid"]["Deployments"],
                               ctx["victim_project"], ctx["victim_tag"],
                               ctx["vid"]["Individuals"],
                               ctx["victim"]["uid"]),
        "held": (ctx["stranger_project"],
                 deployment_row(ctx["vid"]["Deployments"],
                                ctx["stranger_project"], ctx["stranger_tag"],
                                ctx["stranger_animal"],
                                ctx["stranger"]["uid"])),
        "free": (ctx["stranger_project"],
                 deployment_row(nid(), ctx["stranger_project"],
                                ctx["stranger_tag_2"],
                                ctx["stranger_animal_2"],
                                ctx["stranger"]["uid"])),
        "free_must_answer": "inserted",
    }


@probe_for("Tag_Versions")
def _tag_versions(ctx):
    # Scope-separated since task 11.219, like Tags. Both arms name a tag the
    # stranger's own project holds, so the reference resolves either way and the
    # only thing varying is the `tag_version_id`.
    return {
        "seed": tag_version_row(ctx["vid"]["Tag_Versions"],
                                ctx["victim_project"], ctx["victim_tag"],
                                ctx["victim"]["uid"], "Victim's version"),
        "held": (ctx["stranger_project"],
                 tag_version_row(ctx["vid"]["Tag_Versions"],
                                 ctx["stranger_project"],
                                 ctx["stranger_tag"], ctx["stranger"]["uid"],
                                 "Claimed")),
        "free": (ctx["stranger_project"],
                 tag_version_row(nid(), ctx["stranger_project"],
                                 ctx["stranger_tag"],
                                 ctx["stranger"]["uid"], "Free")),
    }


# **The `Project_Tags` probe is deleted (task 11.219).** It proved that a
# composite key always including the caller's own project structurally cannot
# collide across callers — by linking the SAME `tag_id` from both projects and
# checking both inserted clean. `Tags` itself has exactly that shape now and its
# probe above makes exactly that claim, so nothing is lost. And this is not a
# deletion anybody has to remember: `check_coverage` derives the table list from
# `sync_tables.dart` and **aborts** on a probe for a table that is gone —
# "the schema moved under this instrument" — which is how this was found.


@probe_for("Triangulation_Sessions")
def _triangulation_sessions(ctx):
    return {
        "seed": triangulation_session_row(ctx["vid"]["Triangulation_Sessions"],
                                          ctx["victim_project"], ctx["victim_tag"],
                                          ctx["victim"]["uid"]),
        "held": (ctx["stranger_project"],
                 triangulation_session_row(ctx["vid"]["Triangulation_Sessions"],
                                           ctx["stranger_project"],
                                           ctx["stranger_tag"],
                                           ctx["stranger"]["uid"])),
        "free": (ctx["stranger_project"],
                 triangulation_session_row(nid(), ctx["stranger_project"],
                                           ctx["stranger_tag"],
                                           ctx["stranger"]["uid"])),
    }


@probe_for("Observations")
def _observations(ctx):
    return {
        "seed": observation_row(ctx["vid"]["Observations"], ctx["victim_project"],
                                ctx["victim"]["uid"], ctx["victim_tag"]),
        "held": (ctx["stranger_project"],
                 observation_row(ctx["vid"]["Observations"], ctx["stranger_project"],
                                 ctx["stranger"]["uid"], ctx["stranger_tag"])),
        "free": (ctx["stranger_project"],
                 observation_row(nid(), ctx["stranger_project"],
                                 ctx["stranger"]["uid"], ctx["stranger_tag"])),
    }


@probe_for("Observation_Exclusions")
def _observation_exclusions(ctx):
    """Task 11.7's supersede/exclude marks — the twelfth table, added by 11.21.

    Both arms name the *stranger's own* observation and the stranger
    themselves, so nothing about the row is a claim the prober is not entitled
    to make: §4.17's naming invariant, the role gradient and the owner-only
    `excluded` rung all pass, and the only difference left between the two
    pushes is the `exclusion_id` being claimed.
    """
    return {
        "seed": observation_exclusion_row(
            ctx["vid"]["Observation_Exclusions"], ctx["victim_project"],
            ctx["victim"]["uid"], ctx["vid"]["Observations"],
            ctx["vid"]["Observations"]),
        "held": (ctx["stranger_project"], observation_exclusion_row(
            ctx["vid"]["Observation_Exclusions"], ctx["stranger_project"],
            ctx["stranger"]["uid"], ctx["stranger_obs"], ctx["stranger_obs"])),
        "free": (ctx["stranger_project"], observation_exclusion_row(
            nid(), ctx["stranger_project"], ctx["stranger"]["uid"],
            ctx["stranger_obs"], ctx["stranger_obs"])),
    }


@probe_for("Non_Detections")
def _non_detections(ctx):
    return {
        "seed": non_detection_row(ctx["vid"]["Non_Detections"],
                                  ctx["victim_project"], ctx["victim"]["uid"]),
        "held": (ctx["stranger_project"],
                 non_detection_row(ctx["vid"]["Non_Detections"],
                                   ctx["stranger_project"], ctx["stranger"]["uid"])),
        "free": (ctx["stranger_project"],
                 non_detection_row(nid(), ctx["stranger_project"],
                                   ctx["stranger"]["uid"])),
    }


@probe_for("Estimated_Positions")
def _estimated_positions(ctx):
    return {
        "seed": estimated_position_row(ctx["vid"]["Estimated_Positions"],
                                       ctx["victim_project"], ctx["victim_tag"],
                                       ctx["victim"]["uid"]),
        "held": (ctx["stranger_project"],
                 estimated_position_row(ctx["vid"]["Estimated_Positions"],
                                        ctx["stranger_project"],
                                        ctx["stranger_tag"],
                                        ctx["stranger"]["uid"])),
        "free": (ctx["stranger_project"],
                 estimated_position_row(nid(), ctx["stranger_project"],
                                        ctx["stranger_tag"],
                                        ctx["stranger"]["uid"])),
    }


@probe_for("Actual_Tag_Locations")
def _actual_tag_locations(ctx):
    return {
        "seed": actual_tag_location_row(ctx["vid"]["Actual_Tag_Locations"],
                                        ctx["victim_project"], ctx["victim_tag"],
                                        ctx["victim"]["uid"]),
        "held": (ctx["stranger_project"],
                 actual_tag_location_row(ctx["vid"]["Actual_Tag_Locations"],
                                         ctx["stranger_project"],
                                         ctx["stranger_tag"],
                                         ctx["stranger"]["uid"])),
        "free": (ctx["stranger_project"],
                 actual_tag_location_row(nid(), ctx["stranger_project"],
                                         ctx["stranger_tag"],
                                         ctx["stranger"]["uid"])),
    }


# --- Coverage: the list comes from `syncTables`, not from this file --------

def check_coverage():
    """Aborts unless every table `sync_tables.dart` declares has a probe.

    **This is the check task 11.21 exists to add.** `Observation_Exclusions`
    shipped in task 11.7 and this sweep did not learn about it for four
    months, while §4.13 went on claiming the sweep covered every table. A
    hand-carried list cannot notice its own omission; a derived one aborts.

    It fails in the other direction too: a probe for a table `syncTables` no
    longer declares means the schema moved under the instrument, and a probe
    firing at a dropped table is not measuring the shipped system.
    """
    declared = set(PRIMARY_KEYS)
    unprobed = sorted(declared - set(PROBES))
    stale = sorted(set(PROBES) - declared)
    if unprobed:
        raise SystemExit(
            f"ABORT: {len(unprobed)} synced table(s) have no probe: "
            f"{', '.join(unprobed)}.\n"
            f"A new synced table needs a *decision* about whether claiming its "
            f"primary key is distinguishable, not a list edit — see this "
            f"script's docstring and Security Model §4.13. Add a builder under "
            f"@probe_for and record the verdict; do not delete this check."
        )
    if stale:
        raise SystemExit(
            f"ABORT: probes exist for table(s) sync_tables.dart no longer "
            f"declares: {', '.join(stale)}. The schema moved under this "
            f"instrument — a probe aimed at a table that is gone measures "
            f"nothing. Remove the probe and correct §4.13's table count."
        )
    unrecorded = sorted(set(RECORDED_FINDINGS) - declared)
    if unrecorded:
        raise SystemExit(
            f"ABORT: RECORDED_FINDINGS names table(s) that are not synced "
            f"tables: {', '.join(unrecorded)}. An accepted finding against a "
            f"table that no longer exists would silently excuse a real one."
        )


def check_probe(table, plan):
    """Aborts unless this table's probe actually probes what it claims to.

    Two ways a probe can be vacuous and still print `COVERED`, both of which
    have real precedent in this repo's instruments:

    1. The "held" arm does not claim the victim's id at all — a typo, or a
       table whose seed was forgotten — so the comparison is free-versus-free
       and agrees for a reason that has nothing to do with authorization.
    2. The "free" arm accidentally reuses the victim's id, so both arms
       collide and the table looks distinguishable when it is not.

    So: every key column other than `project_id` must be *equal* to the seed's
    on the held arm and *different* on the free arm. Then the derived
    expectation is asserted rather than assumed — on a scope-separated table
    the two full keys must genuinely differ (that separation is the whole
    mechanism), and on a globally keyed one they must genuinely be identical
    (or there is no collision to be uniform about).
    """
    seed = plan["seed"]
    held, free = plan["held"][1], plan["free"][1]
    id_columns = [c for c in PRIMARY_KEYS[table] if c != "project_id"]
    if not id_columns and table != PROJECTS:
        raise SystemExit(
            f"ABORT: {table}'s primary key is project_id alone, which only "
            f"{PROJECTS} may be. keys_are_scope_separated cannot classify it."
        )
    for column in id_columns:
        if held.get(column) != seed.get(column):
            raise SystemExit(
                f"ABORT: {table}'s held arm claims {column}="
                f"{held.get(column)!r} but the victim holds {seed.get(column)!r}. "
                f"This probe compares two unheld keys and would report COVERED "
                f"without testing anything."
            )
        if free.get(column) == seed.get(column):
            raise SystemExit(
                f"ABORT: {table}'s free arm reuses the victim's {column}. "
                f"Both arms collide, so a difference could not be observed."
            )
    if row_key(table, free) == row_key(table, seed):
        raise SystemExit(
            f"ABORT: {table}'s free arm has the victim's exact row key. "
            f"There is no free key in this probe."
        )
    separated = keys_are_scope_separated(table)
    same_key = row_key(table, held) == row_key(table, seed)
    if separated and same_key:
        raise SystemExit(
            f"ABORT: {table} is keyed with project_id, so the held arm should "
            f"not be able to reproduce the victim's row key — but it did "
            f"({row_key(table, held)}). Either the probe pushes into the "
            f"victim's project, or project scoping is not doing what §4.13 says."
        )
    if not separated and not same_key:
        raise SystemExit(
            f"ABORT: {table} is globally keyed, so the held arm must claim the "
            f"victim's exact row key — but it claims {row_key(table, held)!r} "
            f"against the victim's {row_key(table, seed)!r}. Nothing collides, "
            f"so a COVERED verdict here would mean nothing."
        )


# --- Reporting ---------------------------------------------------------

results = []  # (table, verdict) — {"held", "finding", "unexpected", "blind"}


def probe(table, resp_held, held_outcome, resp_free, free_outcome,
          free_must_answer=None):
    """Compares the outcome for a claimed-held key against a claimed-free key.

    `held_outcome`/`free_outcome` are the specific outcome strings looked up
    by `outcome_for` — comparing the exact string, not just presence, so a
    silently-changed vocabulary cannot slip past as "still equal".

    A probe that declared `free_must_answer` is scored `blind` when its free
    arm got anything else, **before** the two arms are compared — because the
    comparison is the thing a failed free arm makes meaningless (task
    11.311)."""
    if free_must_answer is not None and (
            resp_free[0] != 200 or free_outcome != free_must_answer):
        print(f"  BLIND       {table:<24} free arm answered "
              f"{resp_free[0]}/{free_outcome!r}, and this probe requires "
              f"{free_must_answer!r} — a push the stranger is entitled to make "
              f"was not accepted, so held={held_outcome!r} agreeing or "
              f"disagreeing with it measures nothing")
        results.append((table, "blind"))
        return
    same = (resp_held[0] == resp_free[0] and held_outcome == free_outcome
            and held_outcome is not None)
    if same:
        print(f"  COVERED     {table:<24} held={held_outcome!r} "
              f"free={free_outcome!r} — indistinguishable")
        results.append((table, "held"))
    elif table in RECORDED_FINDINGS:
        print(f"  FINDING     {table:<24} held={resp_held[0]}/{held_outcome!r} "
              f"free={resp_free[0]}/{free_outcome!r}  ({RECORDED_FINDINGS[table]})")
        results.append((table, "finding"))
    else:
        print(f"  ***NEW***   {table:<24} held={resp_held[0]}/{held_outcome!r} "
              f"free={resp_free[0]}/{free_outcome!r}  — UNRECORDED, investigate")
        results.append((table, "unexpected"))


check_coverage()
preflight(BASE, LINK_DIR)
print(f"Probing {len(PROBES)} table(s), derived from sync_tables.dart.")
print("Signing in a victim and a stranger with no relationship to them...")
victim = sign_in("victim")
stranger = sign_in("stranger")

ctx = {
    "victim": victim,
    "stranger": stranger,
    "victim_project": nid(),
    "stranger_project": nid(),
    "victim_tag": nid(),
    "stranger_tag": nid(),
    "stranger_obs": nid(),
    # Task 11.311: the `Deployments` probe's second collar and its two animals.
    # Two of each because its arms must not share an end — see `_deployments`.
    # The victim's animal is `vid["Individuals"]`, which the `Individuals`
    # seed already publishes.
    "stranger_tag_2": nid(),
    "stranger_animal": nid(),
    "stranger_animal_2": nid(),
    # One victim-held id per table, for the tables keyed by a surrogate id.
    "vid": {table: nid() for table in PRIMARY_KEYS},
}

plans = {table: PROBES[table](ctx) for table in PRIMARY_KEYS}
for table, plan in plans.items():
    check_probe(table, plan)

# The victim publishes one row of everything, fully linked, so every table
# below has a genuinely "held" key to claim. Assembled from the probes
# themselves — a table whose seed were forgotten could not have got past
# `check_probe`.
status, body = push(victim, ctx["victim_project"],
                    {table: [plan["seed"]] for table, plan in plans.items()})
assert status == 200, (status, body)
assert not any(v == "unauthorized" for v in body.get("outcomes", {}).values()), (
    "the victim's own project must publish cleanly, or nothing below proves "
    f"anything: {body}"
)

# The stranger's own project, tag and observation, so every claim below is a
# push the stranger is fully entitled to make — the outcome being probed is
# the primary-key collision, never an unrelated authorization refusal.
status, body = push(stranger, ctx["stranger_project"], {
    "Users": [user_row(stranger["uid"], "Stranger", stranger["email"])],
    "Projects": [project_row(ctx["stranger_project"], stranger["uid"])],
    "Project_Memberships": [
        membership_row(nid(), ctx["stranger_project"], stranger["uid"])],
})
assert status == 200, (status, body)
status, body = push(stranger, ctx["stranger_project"], {
    "Individuals": [
        individual_row(ctx["stranger_project"], ctx["stranger_animal"],
                       stranger["uid"], "Stranger's animal"),
        individual_row(ctx["stranger_project"], ctx["stranger_animal_2"],
                       stranger["uid"], "Stranger's second animal"),
    ],
    "Tags": [tag_row(ctx["stranger_project"], ctx["stranger_tag"],
                     stranger["uid"], "Stranger's tag"),
             tag_row(ctx["stranger_project"], ctx["stranger_tag_2"],
                     stranger["uid"], "Stranger's second tag")],
    "Observations": [observation_row(ctx["stranger_obs"], ctx["stranger_project"],
                                     stranger["uid"], ctx["stranger_tag"])],
})
assert status == 200, (status, body)
# Every row above is one the probes lean on as a legitimate referent; a refusal
# here would surface later as a probe arm refused for a reason that has nothing
# to do with its key.
assert set(body.get("outcomes", {}).values()) == {"inserted"}, (
    f"the stranger's own fixture must land cleanly: {body}")

print("\nProbing every table in sync_tables.dart — held key vs free key:\n")

for table, plan in plans.items():
    held_project, held_row = plan["held"]
    free_project, free_row = plan["free"]
    rh = push(stranger, held_project, {table: [held_row]})
    rf = push(stranger, free_project, {table: [free_row]})
    probe(table, rh, outcome_for(rh[1], table, held_row),
          rf, outcome_for(rf[1], table, free_row),
          free_must_answer=plan.get("free_must_answer"))

# --- The bound, verified rather than assumed: the victim's rows are ---------
# untouched by every claim above, still in their own project, still theirs.
status, body = call("/sync/pull", {
    **ENVELOPE, "project_id": ctx["victim_project"], "device_id": victim["device"],
    "cursor": 0, "batch_size": 500,
}, victim["token"])
pulled = json.loads(body).get("rows", {})
# Only the project-scoped tables are certain to come back in this project's
# pull; the global ones arrive by reachability, which is a different property
# with its own tests. **`Tags` used to be named here as a special case**, because
# it was global and H-3's whole claim was that the victim's tag survived being
# claimed. It is project-scoped now, so `keys_are_scope_separated` already
# includes it and the special case is gone rather than being kept as a no-op.
checked = [t for t in plans if keys_are_scope_separated(t)]
missing = [
    table for table in checked
    if not any(row_key(table, r) == row_key(table, plans[table]["seed"])
               for r in pulled.get(table, []))
]
victim_rows_ok = not missing
print(f"\n  {'PASS' if victim_rows_ok else 'FAIL'}  "
      f"the victim's rows are untouched and still theirs after every claim "
      f"above ({len(checked) - len(missing)} of {len(checked)} re-read; the "
      f"{len(plans) - len(checked)} globally-keyed rows arrive by reachability "
      f"rather than by this project's pull and are not checked here)")
if not victim_rows_ok:
    print(f"        missing from the victim's own pull: {', '.join(missing)}")
    results.append(("victim data integrity", "unexpected"))

print()

#: `VERIFY_H3_JSON` names a path to write this run's per-table verdicts to,
#: which is how `verify_11_127_broken_control.py` decides whether this sweep
#: can see an oracle at all.
#:
#: **The harness compares this run against its own healthy one rather than
#: carrying a list of tables** — a hand-written list of "the tables that must
#: flip" would rot the day a table is added, which is the defect the derived
#: `PRIMARY_KEYS` above already closed one layer down. Every table this sweep
#: calls indistinguishable against the real server has to become
#: distinguishable against a server whose refusals say whether the row was
#: already there.
summary_path = os.environ.get("VERIFY_H3_JSON")
if summary_path:
    verdicts = {}
    for table, verdict in results:
        # Same rule as everywhere else a structure is keyed by a name: a
        # duplicate must be loud. Two entries for one table would silently
        # report whichever came last.
        if table in verdicts:
            print(f"FATAL: {table!r} was scored twice by this run, so one "
                  f"verdict would silently overwrite the other.")
            sys.exit(2)
        verdicts[table] = verdict
    with open(summary_path, "w") as fh:
        json.dump({
            "results": verdicts,
            "covered": sorted(t for t, v in verdicts.items() if v == "held"),
            "findings": sorted(t for t, v in verdicts.items()
                               if v == "finding"),
            "unexpected": sorted(t for t, v in verdicts.items()
                                 if v == "unexpected"),
            # Task 11.311. Kept out of `covered` on purpose: the 11.127
            # harness derives the tables that must flip from `covered`, and a
            # table this run could not measure has not earned a place there.
            "blind": sorted(t for t, v in verdicts.items() if v == "blind"),
        }, fh, indent=2)
    print(f"summary written to {summary_path}")

findings = [t for t, v in results if v == "finding"]
unexpected = [t for t, v in results if v == "unexpected"]
covered = [t for t, v in results if v == "held"]
blind = [t for t, v in results if v == "blind"]
print(f"{len(covered)} table(s) indistinguishable, "
      f"{len(findings)} recorded finding(s), {len(unexpected)} unrecorded, "
      f"{len(blind)} blind.")
if findings:
    print("Recorded, accepted findings (see the module docstring for why):")
    for t in findings:
        print(f"  - {t}: {RECORDED_FINDINGS[t]}")
if blind:
    print("\nFAILED — table(s) whose probe measured nothing (the free arm was "
          "refused, so held and free agreeing or not says nothing about the "
          "key):")
    for t in blind:
        print(f"  - {t}")
if unexpected:
    print("\nFAILED — unrecorded distinguishable table(s):")
    for t in unexpected:
        print(f"  - {t}")
if blind or unexpected:
    sys.exit(1)
print(f"\nNo table outside the recorded findings is a key-claiming oracle "
      f"({len(plans)} of {len(PRIMARY_KEYS)} synced tables probed).")

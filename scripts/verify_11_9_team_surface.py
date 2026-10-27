#!/usr/bin/env python3
# gate-instrument: verify_11_9_team_surface
"""Task 11.9 — live adversarial pass over Phase 11's *team* trust boundaries.

`SECURITY_SCOPE_AND_EXIT.md` §3 items **21–26**, added to that inventory
*before* anything here was attacked:

  21 — teammates' rows arriving through pull, now authored by people with
       different rights rather than by the same user on another device
  22 — `Observation_Exclusions`, the one write in this app where one person
       acts on somebody else's record
  23 — join-code and join-request administration: the owner's seven routes
  24 — join request creation: the one route where an authenticated stranger
       asks to join a project they cannot otherwise see
  25 — membership and role mutation on the push path
  26 — cross-project isolation and the role gradient across every new endpoint

and, since task 11.311 (2026-09-23), item **30** — destroying a project, the
two deletion routes. Probe 8's sweep reaches them with everybody else's owner
routes; probe 8a asks them the rest of entry 27's questions.

Each probe below names the entry it attacks. Verdicts are in
`TriTrack_Security_Model.md` §18 for the original round and **§22 for round 9**,
which rewrote entries 23 and 24 wholesale.

**Round 9 (task 11.85, 2026-08-31) rewrote a third of this file.** Task 11.81
replaced the per-address invitation routes with one shared join code and an
owner's approval, and entries 23 and 24 lost their verdicts — *a verdict does
not transfer to a replacement because it kept the row number.* Probes 8, 9 and
15 are new; the fixture builds its team through the join code (the flow lives
in `gate_wire.py`, once, for all four instruments that need it); and two
findings are baselined below rather than left to fail the run silently.

Everything here speaks raw HTTP against a live stack. No client code, no mocks:
eight consecutive gates found that this class of finding is invisible to
in-process tests, and §6's exit criteria require a **failed live attack** per
inventory entry rather than a passing unit test.

**Every probe carries a positive control that fires in the same run.** A probe
whose attack is refused proves nothing on its own — a server that refused
*everything* (a stale envelope, a dead route, a typo in the row shape) would
report an identical clean sweep, which is exactly what task 10.40 found three of
this project's instruments doing. So each attack is paired with the nearest
legitimate request that must be *accepted*, and a control that fails is a
failure of the run, not a curiosity.

Usage (with the e2e stack up — see the README's "End-to-end integration suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -p tritrack-e2e -f docker-compose.yml -f docker-compose.e2e.yml \
        up --build -d
    python3 scripts/verify_11_9_team_surface.py

Exits non-zero if any attack succeeded or any positive control failed.
"""
import inspect
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import (  # noqa: E402
    ENVELOPE,
    MAX_JOIN_REQUESTS_RETURNED,
    enable_joining,
    join_by_code,
    outcome_for,
    preflight,
    request_to_join,
)

BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")

T = "2026-08-01T12:00:00.000Z"


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
        self.email = f"t119-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
        status, _ = call("/auth/magic-link", {"email": self.email})
        assert status == 202, f"magic-link for {label}: {status}"
        path = os.path.join(LINK_DIR, self.email + ".link")
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


def get(path, who, headers=()):
    """A `GET` as `who`. Hoisted out of probe 8 by task 11.85 — six of this
    file's probes now read a route rather than write one."""
    req = urllib.request.Request(BASE + path, method="GET")
    req.add_header("Authorization", "Bearer " + who.token)
    for name, value in headers:
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, {"raw": raw[:200].decode("utf-8", "replace")}


def strip_trace(b):
    """A response body minus the per-request trace id, which differs by design.

    Hoisted with `get` for the same reason: §4.13's "reads byte-identical" is
    now asserted across six routes rather than one."""
    return {k: v for k, v in b.items() if k != "trace_id"}


def pull(who, pid, cursor=0, batch=500):
    return call(
        "/sync/pull",
        {
            **ENVELOPE,
            "project_id": pid,
            "device_id": who.device,
            "cursor": cursor,
            "batch_size": batch,
        },
        who.token,
    )


# ------------------------------------------------------------------ row shapes


def sync_meta(uid, revision=1):
    return {
        "created_at": T,
        "updated_at": T,
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


def project_row(pid, owner_id, revision=1):
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
        **sync_meta(owner_id, revision),
        "coordinate_format": "dd",
        "triangulation_window_minutes": 15,
    }


def membership_row(mid, pid, uid, role, actor, end_date=None, revision=1,
                   deleted_at=None):
    row = {
        "membership_id": mid,
        "project_id": pid,
        "user_id": uid,
        "join_date": T,
        "end_date": end_date,
        "role": role,
        **sync_meta(actor, revision),
    }
    row["deleted_at"] = deleted_at
    return row


def tag_row(pid, tid, uid, revision=1):
    """A tag. **`pid` is new in task 11.219** — a tag belongs to one project and
    the row is keyed `(tag_id, project_id)`. `lineage_id` is the tag's own id,
    which is what both migrations write for a tag nobody copied; nothing on the
    server reads it, which `assertSealedColumnsFeedNoReachability` enforces."""
    return {
        "tag_id": tid,
        "project_id": pid,
        "lineage_id": tid,
        "copied_at": None,
        "frequency_mhz": 150.5,
        "pulse_rate": 60.0,
        "pulse_pattern": None,
        "tag_name": "Collar " + tid[:4],
        "date_put_on": T,
        "date_removed": None,
        "status": "active",
        "capture_date": None,
        "notes": None,
        **sync_meta(uid, revision),
        "color_hex": "#3366CC",
    }


# `project_tag_row` is gone with `Project_Tags` (task 11.219): a tag is created
# inside the project that holds it, so `tag_row`'s `pid` is what the link row
# used to say.


def observation(oid, pid, uid, tid=None, revision=1, bearing=90.0):
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
        **sync_meta(uid, revision),
    }


def exclusion(xid, pid, observation_id, uid, kind="superseded",
              superseded_by=None, reason=None, revision=1, deleted_at=None,
              modified_by=None):
    """A mark authored by `uid`.

    `modified_by` defaults to the author, which is right for an insert. **On
    an update it must name whoever is pushing** — task 11.24 bound the audit
    column to the caller, so a withdrawal that leaves the author's name on it
    is refused as `unattributedChange`. That is deliberate: it is the sentence
    task 11.18 shows in the Team log, and leaving the name as found was how a
    false one got written.
    """
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


# ------------------------------------------------------------------- reporting


ATTACK_FAILURES = []
CONTROL_FAILURES = []
BASELINE_DRIFT = []
NOTES = []
#: Every scored check, keyed by its `what` string. Written out as JSON when
#: `VERIFY_119_JSON` names a path, which is how
#: `verify_11_85_broken_control.py` decides whether a probe flipped. Task
#: 11.85; the mechanism is `verify_11_49_server_reads.py`'s, unchanged.
RESULTS = {}
_current = {"name": None}
_seen_attacks = set()

#: Attacks this build is **known** not to refuse, each with the register entry
#: that disposes of it.
#:
#: This is `gate_c_baseline.py`'s mechanism, in miniature and for the same
#: reason: an instrument that simply printed "one attack succeeded" would go red
#: forever and stop being run, while one that quietly dropped the check would
#: stop measuring. A baselined entry is reported, does not fail the run — and
#: **fails the run if it starts being refused**, because that means somebody
#: closed it and the register entry is now a lie.
#:
#: Keyed by the exact `what` string passed to `attack()`.
#: **Empty since task 11.24 (2026-08-22), and that is the point.** It held
#: N-1's two entries — a contributor filing an observation, and a mark, under
#: the owner's name. Both are now refused, so both were removed rather than
#: left as "known": a baselined attack that starts being refused already fails
#: this run by design (see [attack]'s `CLOSED?` branch), which is what makes
#: closing a finding and forgetting the register a red run rather than a quiet
#: one. Task 11.24's own instrument,
#: `scripts/verify_11_24_attribution.py`, is where the refusal is asserted
#: across the whole derived table set; what this file keeps is the *regression*
#: bar — these two attacks now go through `attack()` unbaselined, so a build
#: that admits either fails here.
#:
#: **Empty again since task 11.89 (2026-09-01).** R-1 was the one finding round
#: 9 landed on this instrument, and it is closed: `isWellFormedPersonName` is
#: now an allowlist -- letters, marks, digits, dashes, spaces and a short list
#: of name punctuation -- so the two line separators are refused along with
#: every other character nobody thought to name. **The two attacks below are
#: therefore unbaselined again**, which means a build that readmits either
#: fails this run rather than passing it quietly.
#:
#: Keeping the entries and marking them CLOSED was the alternative and is the
#: wrong one: a baseline is a record of what is *accepted*, and leaving a closed
#: finding in it is how a register comes to describe a system nobody is running.

BASELINE = {}


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
#: `control()` here write into the shared `RESULTS` dict keyed by their `what`
#: string, so before this a second call with the same description silently
#: overwrote the first's verdict.
#:
#: `verify_round8_server_surface.py` is the last one without it; see Discovered
#: Scope under task 11.220.
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


def probe(name):
    _current["name"] = name
    print(f"\n=== {name}")


def attack(what, refused, detail=""):
    """`refused` must be True unless `what` is in [BASELINE]."""
    _register(what)
    _seen_attacks.add(what)
    RESULTS[what] = "refused" if refused else "ADMITTED"
    baselined = what in BASELINE
    if baselined:
        if refused:
            mark = "  CLOSED? "
            BASELINE_DRIFT.append(
                f"{_current['name']}: {what} — is now refused, but the "
                f"register still records it as open ({BASELINE[what]}). "
                f"Close the register entry or remove the baseline."
            )
        else:
            mark = "  known   "
    else:
        mark = "  refused " if refused else "  ADMITTED"
    print(f"{mark}  {what}" + (f"   [{detail}]" if detail else ""))
    if not refused and not baselined:
        ATTACK_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def control(what, accepted, detail=""):
    """`accepted` must be True: the legitimate twin of the attack worked.

    A control that fails means the probe was measuring nothing.
    """
    _register("control: " + what)
    mark = "  control " if accepted else "  BLIND   "
    RESULTS[what] = "control" if accepted else "BLIND"
    print(f"{mark}  {what}" + (f"   [{detail}]" if detail else ""))
    if not accepted:
        CONTROL_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def note(text):
    print(f"  note      {text}")
    NOTES.append(f"{_current['name']}: {text}")


# ============================================================== the fixture ===
#
# A real team, built through the real flows: a published project, an owner, a
# contributor and a viewer who each joined by redeeming a real invitation, and
# an unrelated stranger with a project of their own. Nothing below is inserted
# behind the server's back.

preflight(BASE, LINK_DIR)

print("\nBuilding the fixture over the real auth, publish and invite flows...")
owner = Person("owner")
contrib = Person("contrib")
contrib2 = Person("contrib2")
viewer = Person("viewer")
stranger = Person("stranger")

P = str(uuid.uuid4())          # the team project
Q = str(uuid.uuid4())          # the stranger's project, which P must not reach
TAG_A = str(uuid.uuid4())      # a tag P references
TAG_B = str(uuid.uuid4())      # a tag only Q references
OBS_P = str(uuid.uuid4())      # an observation in P, authored by the owner
OBS_Q = str(uuid.uuid4())      # an observation in Q, authored by the stranger

status, body = push(owner, P, {
    "Users": [user_row(owner)],
    "Projects": [project_row(P, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), P, owner.id, "owner", owner.id)
    ],
    "Tags": [tag_row(P, TAG_A, owner.id)],
    "Observations": [observation(OBS_P, P, owner.id, TAG_A)],
})
assert status == 200, f"publish P: {status} {body}"
assert set(body["outcomes"].values()) == {"inserted"}, body["outcomes"]

status, body = push(stranger, Q, {
    "Users": [user_row(stranger)],
    "Projects": [project_row(Q, stranger.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), Q, stranger.id, "owner", stranger.id)
    ],
    "Tags": [tag_row(Q, TAG_B, stranger.id)],
    "Observations": [observation(OBS_Q, Q, stranger.id, TAG_B)],
})
assert status == 200, f"publish Q: {status} {body}"
assert set(body["outcomes"].values()) == {"inserted"}, body["outcomes"]


# **Task 11.85 rewrote everything below this line's fixture onto the join
# code.** Until 2026-08-31 this instrument built its team by *inviting* people,
# and task 11.81 deleted `POST /projects/<id>/invites`. Every probe here then
# died on one line with `404`, along with three sibling instruments — not a
# finding, but the class named *the attack corpus cannot reach the check*: a
# tool that can no longer get to the thing it tests. The flow itself lives in
# `gate_wire.py` so the four repaired instruments share one definition of what
# a fixture is, rather than the four copies of "invite, redeem" that made this
# a four-file repair.

#: The project's join code, minted the first time somebody joins P.
#:
#: **Never printed.** A live join code is a credential for the right to ask,
#: and `CLAUDE.md`'s rule about secret-shaped strings covers it.
P_CODE = None


def join(person, role, claimed_name=None):
    """Puts `person` on project P the way a real crew does: ask, then approve.

    **The owner now has to act**, which is the substantive difference from the
    flow this replaces. Redemption was one call by the joiner against a code
    that already carried their role; joining is a request by the joiner and a
    separate approval by the owner, who chooses the role at that moment.
    """
    global P_CODE
    P_CODE, request_id = join_by_code(
        call, owner.token, P, person.token, role,
        code=P_CODE, claimed_name=claimed_name,
    )
    # The joiner pushes their own profile, exactly as a real device does.
    status, pb = push(person, P, {"Users": [user_row(person)]})
    assert status == 200, f"{person.label} profile: {status} {pb}"
    return request_id


join(contrib, "contributor")
join(contrib2, "contributor")
join(viewer, "viewer")
print(f"  fixture ready: project {P[:8]} with owner, 2 contributors, 1 viewer;"
      f" stranger project {Q[:8]}")


def outcomes(body):
    return body.get("outcomes") or {}


def rows_of(body, table):
    return (body.get("rows") or {}).get(table) or []


def pull_all(who, pid):
    """Every row a pull delivers, following the cursor to exhaustion."""
    collected = {}
    cursor = 0
    for _ in range(50):
        status, body = pull(who, pid, cursor=cursor, batch=500)
        if status != 200:
            return status, collected
        any_row = False
        for table, rows in (body.get("rows") or {}).items():
            if rows:
                any_row = True
            collected.setdefault(table, []).extend(rows)
        nxt = body.get("cursor")
        if not any_row or nxt is None or nxt == cursor:
            break
        cursor = nxt
    return 200, collected


# ================================================================== probe 1 ===
# INVENTORY 22 — `Observation_Exclusions`, the reference question.
#
# An exclusion row names the observation it applies to, and there is
# deliberately no foreign key on either side of the wire tying that name to an
# observation the writer may see. Nothing checks it. So: can a mark name an
# observation in another project, and if it can, what happens to the analysis
# of the project that owns that observation?

probe("1. Observation_Exclusions — can a mark name an observation "
      "its writer cannot reach?")

X_FOREIGN = str(uuid.uuid4())
status, body = push(contrib, P, {
    "Observation_Exclusions": [
        exclusion(X_FOREIGN, P, OBS_Q, contrib.id, reason="reaching into Q")
    ],
})
foreign_named = outcome_for(body, "Observation_Exclusions",
                            exclusion(X_FOREIGN, P, OBS_Q, contrib.id))
note(f"a mark in P naming project Q's observation: {foreign_named!r}")

X_NOWHERE = str(uuid.uuid4())
GHOST = str(uuid.uuid4())
status, body = push(contrib, P, {
    "Observation_Exclusions": [
        exclusion(X_NOWHERE, P, GHOST, contrib.id, reason="names nothing")
    ],
})
ghost_named = outcome_for(body, "Observation_Exclusions",
                          exclusion(X_NOWHERE, P, GHOST, contrib.id))
note(f"a mark in P naming an observation that exists nowhere: {ghost_named!r}")

# What the answer has to be about is the *consequence*, not the acceptance.
# Three questions, each with its own measurement.

# (a) Does the mark reach project Q at all?
status, qrows = pull_all(stranger, Q)
q_marks = rows_of({"rows": qrows}, "Observation_Exclusions")
attack(
    "a mark aimed at project Q's observation is not delivered into project Q",
    status == 200 and not any(m.get("observation_id") == OBS_Q
                              for m in q_marks),
    f"Q holds {len(q_marks)} mark(s)",
)

# (b) Is project Q's observation still there, unmarked?
q_obs = [o for o in rows_of({"rows": qrows}, "Observations")
         if o.get("observation_id") == OBS_Q]
attack(
    "project Q's observation is untouched by the foreign mark",
    len(q_obs) == 1 and q_obs[0].get("deleted_at") is None,
    f"{len(q_obs)} row(s)",
)

# (c) Does the foreign mark disclose anything about Q to project P's members?
status, prows = pull_all(owner, P)
p_obs_ids = {o.get("observation_id")
             for o in rows_of({"rows": prows}, "Observations")}
attack(
    "naming Q's observation does not deliver Q's observation into P",
    status == 200 and OBS_Q not in p_obs_ids,
    f"P delivers {len(p_obs_ids)} observation(s)",
)
p_users = {u.get("user_id") for u in rows_of({"rows": prows}, "Users")}
attack(
    "naming Q's observation does not deliver the stranger's Users row into P",
    stranger.id not in p_users,
    f"P delivers {len(p_users)} user row(s)",
)

# POSITIVE CONTROL. The same request aimed at an observation the writer *can*
# reach must be accepted and must be delivered — otherwise "not delivered into
# Q" above would be measuring a server that refuses every mark.
X_REAL = str(uuid.uuid4())
status, body = push(contrib, P, {
    "Observation_Exclusions": [
        exclusion(X_REAL, P, OBS_P, contrib.id, reason="bearing was a bounce")
    ],
})
real_named = outcome_for(body, "Observation_Exclusions",
                         exclusion(X_REAL, P, OBS_P, contrib.id))
control("a contributor may supersede an observation inside their own project",
        real_named == "inserted", repr(real_named))

status, prows = pull_all(owner, P)
p_marks = rows_of({"rows": prows}, "Observation_Exclusions")
control(
    "that mark IS delivered to the project owner's pull "
    "(so the delivery probe above can see one)",
    any(m.get("exclusion_id") == X_REAL for m in p_marks),
    f"P delivers {len(p_marks)} mark(s)",
)

# The cross-project *claim* — a mark whose own project_id is Q, pushed in a
# request scoped to P — is the check that does exist, and it must fire.
X_CLAIM = str(uuid.uuid4())
status, body = push(contrib, P, {
    "Observation_Exclusions": [exclusion(X_CLAIM, Q, OBS_Q, contrib.id)],
})
attack(
    "a mark claiming project Q inside a push scoped to P",
    outcome_for(body, "Observation_Exclusions",
                exclusion(X_CLAIM, Q, OBS_Q, contrib.id)) == "unauthorized",
    repr(outcome_for(body, "Observation_Exclusions",
                     exclusion(X_CLAIM, Q, OBS_Q, contrib.id))),
)

# And a push aimed straight at Q by somebody with no relationship to it.
status, body = push(contrib, Q, {
    "Observation_Exclusions": [exclusion(str(uuid.uuid4()), Q, OBS_Q,
                                         contrib.id)],
})
attack("a non-member pushing a mark straight into project Q",
       status == 403, f"HTTP {status}")


# ================================================================== probe 2 ===
# INVENTORY 22 — the owner-only rung inside a contributor-writable table.

probe("2. Observation_Exclusions — the exclude/supersede rung on the wire")

X_C_EXCL = str(uuid.uuid4())
row = exclusion(X_C_EXCL, P, OBS_P, contrib.id, kind="excluded")
status, body = push(contrib, P, {"Observation_Exclusions": [row]})
attack("a contributor creating an `excluded` mark",
       outcome_for(body, "Observation_Exclusions", row) == "unauthorized",
       repr(outcome_for(body, "Observation_Exclusions", row)))

X_V = str(uuid.uuid4())
row = exclusion(X_V, P, OBS_P, viewer.id, kind="superseded")
status, body = push(viewer, P, {"Observation_Exclusions": [row]})
attack("a viewer creating a `superseded` mark",
       outcome_for(body, "Observation_Exclusions", row) == "unauthorized",
       repr(outcome_for(body, "Observation_Exclusions", row)))

# Promotion by update: the contributor's own accepted `superseded` mark,
# re-pushed as `excluded`.
row = exclusion(X_REAL, P, OBS_P, contrib.id, kind="excluded", revision=2,
                modified_by=contrib.id)
status, body = push(contrib, P, {"Observation_Exclusions": [row]})
attack("a contributor promoting their own mark from superseded to excluded",
       outcome_for(body, "Observation_Exclusions", row) == "unauthorized",
       repr(outcome_for(body, "Observation_Exclusions", row)))

# POSITIVE CONTROL: the owner may do exactly what the contributor could not.
X_O_EXCL = str(uuid.uuid4())
row = exclusion(X_O_EXCL, P, OBS_P, owner.id, kind="excluded",
                reason="instrument fault")
status, body = push(owner, P, {"Observation_Exclusions": [row]})
control("an owner creating an `excluded` mark",
        outcome_for(body, "Observation_Exclusions", row) == "inserted",
        repr(outcome_for(body, "Observation_Exclusions", row)))


# ================================================================== probe 3 ===
# INVENTORY 22 — withdrawal (tasks 11.15, 11.18): author or owner, and the
# rung survives the undo.

probe("3. Observation_Exclusions — who may withdraw a mark")

row = exclusion(X_REAL, P, OBS_P, contrib.id, revision=3,
                deleted_at="2026-08-02T00:00:00.000Z",
                modified_by=contrib2.id)
status, body = push(contrib2, P, {"Observation_Exclusions": [row]})
attack("a second contributor withdrawing someone else's mark",
       outcome_for(body, "Observation_Exclusions", row) == "unauthorized",
       repr(outcome_for(body, "Observation_Exclusions", row)))

row = exclusion(X_O_EXCL, P, OBS_P, owner.id, kind="excluded", revision=2,
                deleted_at="2026-08-02T00:00:00.000Z",
                modified_by=contrib.id)
status, body = push(contrib, P, {"Observation_Exclusions": [row]})
attack("a contributor withdrawing an owner's `excluded` mark",
       outcome_for(body, "Observation_Exclusions", row) == "unauthorized",
       repr(outcome_for(body, "Observation_Exclusions", row)))

# POSITIVE CONTROL: the owner withdraws a contributor's mark (task 11.15's
# whole purpose — a mark whose author has left must not be permanent).
row = exclusion(X_REAL, P, OBS_P, contrib.id, revision=4,
                deleted_at="2026-08-02T00:00:00.000Z", modified_by=owner.id)
status, body = push(owner, P, {"Observation_Exclusions": [row]})
control("an owner withdrawing a contributor's mark",
        outcome_for(body, "Observation_Exclusions", row) == "updated",
        repr(outcome_for(body, "Observation_Exclusions", row)))


# ================================================================== probe 4 ===
# INVENTORY 21 — teammates' rows, now authored by people with different rights.
# The row-naming invariant's clause 2 ("this project already reaches them")
# was written when a project's reach was one person's own devices. Membership
# rows now put every teammate inside it.

probe("4. Attribution — may a teammate's name be put on a record "
      "they did not make?")

FORGED = str(uuid.uuid4())
row = observation(FORGED, P, owner.id, TAG_A, bearing=270.0)
status, body = push(contrib, P, {"Observations": [row]})
forged_outcome = outcome_for(body, "Observations", row)
attack("a contributor inserting an observation attributed to the owner",
       forged_outcome == "unauthorized", repr(forged_outcome))

FORGED_MARK = str(uuid.uuid4())
row = exclusion(FORGED_MARK, P, OBS_P, owner.id, reason="not my words")
status, body = push(contrib, P, {"Observation_Exclusions": [row]})
forged_mark_outcome = outcome_for(body, "Observation_Exclusions", row)
attack("a contributor inserting a mark attributed to the owner",
       forged_mark_outcome == "unauthorized", repr(forged_mark_outcome))

# POSITIVE CONTROL (must refuse): naming somebody the project does NOT reach.
row = observation(str(uuid.uuid4()), P, stranger.id, TAG_A)
status, body = push(contrib, P, {"Observations": [row]})
control("naming a stranger the project cannot reach is still refused "
        "(so the check above is running at all)",
        outcome_for(body, "Observations", row) == "unauthorized",
        repr(outcome_for(body, "Observations", row)))

# POSITIVE CONTROL (must accept): the contributor's own record.
OWN = str(uuid.uuid4())
row = observation(OWN, P, contrib.id, TAG_A)
status, body = push(contrib, P, {"Observations": [row]})
control("a contributor recording their own observation",
        outcome_for(body, "Observations", row) == "inserted",
        repr(outcome_for(body, "Observations", row)))

# Rewriting an existing row's author must be refused in every build.
row = observation(OWN, P, owner.id, TAG_A, revision=2)
status, body = push(contrib, P, {"Observations": [row]})
attack("re-attributing a stored observation to the owner",
       outcome_for(body, "Observations", row) == "unauthorized",
       repr(outcome_for(body, "Observations", row)))

if forged_outcome == "inserted":
    status, prows = pull_all(owner, P)
    delivered = [o for o in rows_of({"rows": prows}, "Observations")
                 if o.get("observation_id") == FORGED]
    note("the forged observation IS delivered to the person it names: "
         f"{len(delivered)} row(s), user_id={delivered[0]['user_id'][:8] if delivered else '-'}")


# ================================================================== probe 5 ===
# INVENTORY 26 — the role gradient over the wire. "A viewer who can write
# because only the UI stopped them is not a viewer."

probe("5. The role gradient — a viewer writes nothing")

SESSION = str(uuid.uuid4())
NEW_TAG = str(uuid.uuid4())
viewer_batch = {
    # **`Project_Tags` was here and its slot is taken by `Tag_Versions` (task
    # 11.219).** The claim this probe makes is *"a viewer writes nothing into
    # any table the rule table lets everyone write"*, so the retired table's
    # place belongs to another such table rather than to nothing — and
    # `Tag_Versions` is the one that was global when this list was written and
    # so could not be in it.
    "Tags": [tag_row(P, NEW_TAG, viewer.id)],
    "Tag_Versions": [{
        "tag_version_id": str(uuid.uuid4()), "project_id": P,
        "tag_id": TAG_A, "effective_from": T, "frequency_mhz": 150.5,
        "pulse_rate": None, "pulse_pattern": None, "tag_name": "Collar",
        **sync_meta(viewer.id),
    }],
    "Triangulation_Sessions": [{
        "session_id": SESSION, "project_id": P, "tag_id": TAG_A,
        "label": "viewer session", "started_at_local": T,
        "started_at_utc": T, "started_at_offset": "+00:00", "notes": None,
        **sync_meta(viewer.id),
    }],
    "Observations": [observation(str(uuid.uuid4()), P, viewer.id, TAG_A)],
    "Estimated_Positions": [{
        "position_id": str(uuid.uuid4()), "project_id": P, "tag_id": TAG_A,
        "session_id": None, "latitude": 35.2, "longitude": -111.6,
        "semi_major_axis": 100.0, "semi_minor_axis": 50.0,
        "rotation_angle": 30.0, "method": "lenth_mle",
        "observation_ids_used": OBS_P, "timestamp_local": T,
        "timestamp_utc": T, "timezone_offset": "+00:00", "notes": None,
        **sync_meta(viewer.id),
    }],
    "Actual_Tag_Locations": [{
        "location_id": str(uuid.uuid4()), "project_id": P, "tag_id": TAG_A,
        "latitude": 35.2, "longitude": -111.6, "uncertainty_radius": 10.0,
        "timestamp_local": T, "timestamp_utc": T,
        "timezone_offset": "+00:00", "notes": None, **sync_meta(viewer.id),
    }],
    "Non_Detections": [{
        "non_detection_id": str(uuid.uuid4()), "project_id": P,
        "user_id": viewer.id, "tag_ids_listened_for": TAG_A,
        "timestamp_local": T, "timestamp_utc": T,
        "timezone_offset": "+00:00", "latitude": 35.2, "longitude": -111.6,
        "position_source": "gps_fix", "position_accuracy_m": 5.0,
        "elevation": 2100.0, "altitude_agl": 0.0, "notes": None,
        **sync_meta(viewer.id),
    }],
}
status, body = push(viewer, P, viewer_batch)
viewer_outcomes = outcomes(body)
refused = {k: v for k, v in viewer_outcomes.items() if v != "unauthorized"}
attack(
    "a viewer pushing one row into every project-scoped table, plus a new tag",
    status == 200 and len(viewer_outcomes) == 7 and not refused,
    f"HTTP {status}, {len(viewer_outcomes)} outcomes, non-refusals: {refused}",
)

# POSITIVE CONTROL (must accept): a viewer's own profile row is theirs, not the
# project's — a blanket 403 on push would have taken this with it.
row = user_row(viewer)
row["first_name"] = "Renamed"
row["revision"] = 2
status, body = push(viewer, P, {"Users": [row]})
control("a viewer may still fix their own name",
        outcome_for(body, "Users", row) == "updated",
        repr(outcome_for(body, "Users", row)))

# POSITIVE CONTROL (must accept): the identical batch from a contributor.
contrib_batch = json.loads(json.dumps(viewer_batch))
CTAG = str(uuid.uuid4())
contrib_batch["Tags"][0] = tag_row(P, CTAG, contrib.id)
contrib_batch["Tag_Versions"][0]["tag_version_id"] = str(uuid.uuid4())
contrib_batch["Tag_Versions"][0]["tag_id"] = CTAG
for table, rows in contrib_batch.items():
    for r in rows:
        r["last_modified_by"] = contrib.id
        if "user_id" in r:
            r["user_id"] = contrib.id
        if table in ("Triangulation_Sessions", "Observations",
                     "Estimated_Positions", "Actual_Tag_Locations",
                     "Non_Detections"):
            for key in ("session_id", "observation_id", "position_id",
                        "location_id", "non_detection_id"):
                if key in r and r[key] is not None:
                    r[key] = str(uuid.uuid4())
status, body = push(contrib, P, contrib_batch)
c_outcomes = outcomes(body)
bad = {k: v for k, v in c_outcomes.items()
       if v not in ("inserted", "updated")}
control("the same seven rows from a contributor are accepted",
        status == 200 and len(c_outcomes) == 7 and not bad,
        f"HTTP {status}, {len(c_outcomes)} outcomes, refusals: {bad}")


# ================================================================== probe 6 ===
# INVENTORY 25 — membership and role mutation over the wire. The insert IS the
# grant, so a device that pushes the row directly is the boundary case.

probe("6. Membership and role mutation pushed directly")

status, prows = pull_all(owner, P)
memberships = {m["user_id"]: m
               for m in rows_of({"rows": prows}, "Project_Memberships")}
control("the owner's pull actually delivers the membership rows "
        "(so the probes below have real ids to attack)",
        {owner.id, contrib.id, contrib2.id, viewer.id} <= set(memberships),
        f"{len(memberships)} membership row(s)")

row = membership_row(str(uuid.uuid4()), P, contrib.id, "owner", contrib.id)
status, body = push(contrib, P, {"Project_Memberships": [row]})
attack("a contributor inserting a second membership making themselves owner",
       outcome_for(body, "Project_Memberships", row) == "unauthorized",
       repr(outcome_for(body, "Project_Memberships", row)))

if contrib.id in memberships:
    row = dict(memberships[contrib.id])
    row["role"] = "owner"
    row["revision"] = int(row.get("revision") or 0) + 1
    row["last_modified_by"] = contrib.id
    status, body = push(contrib, P, {"Project_Memberships": [row]})
    attack("a contributor promoting their own stored membership to owner",
           outcome_for(body, "Project_Memberships", row) == "unauthorized",
           repr(outcome_for(body, "Project_Memberships", row)))

    row = dict(memberships[contrib.id])
    row["end_date"] = "2026-08-02T00:00:00.000Z"
    row["revision"] = int(row.get("revision") or 0) + 1
    row["last_modified_by"] = contrib.id
    status, body = push(contrib2, P, {"Project_Memberships": [row]})
    attack("a contributor ending another contributor's membership",
           outcome_for(body, "Project_Memberships", row) == "unauthorized",
           repr(outcome_for(body, "Project_Memberships", row)))

row = membership_row(str(uuid.uuid4()), P, stranger.id, "contributor",
                     contrib.id)
status, body = push(contrib, P, {"Project_Memberships": [row]})
attack("a contributor adding an outsider to the project",
       outcome_for(body, "Project_Memberships", row) == "unauthorized",
       repr(outcome_for(body, "Project_Memberships", row)))

row = membership_row(str(uuid.uuid4()), P, viewer.id, "contributor",
                     viewer.id)
status, body = push(viewer, P, {"Project_Memberships": [row]})
attack("a viewer granting themselves a contributor membership",
       outcome_for(body, "Project_Memberships", row) == "unauthorized",
       repr(outcome_for(body, "Project_Memberships", row)))

row = membership_row(str(uuid.uuid4()), P, contrib2.id, "owner", owner.id)
status, body = push(owner, P, {"Project_Memberships": [row]})
attack("even the OWNER cannot push a membership row for somebody else "
       "(adding a member is redemption, not a push)",
       outcome_for(body, "Project_Memberships", row) == "unauthorized",
       repr(outcome_for(body, "Project_Memberships", row)))

# POSITIVE CONTROL: an owner may change an existing member's role, which is
# the legitimate operation all the refusals above are shaped around.
if contrib2.id in memberships:
    row = dict(memberships[contrib2.id])
    row["role"] = "viewer"
    row["revision"] = int(row.get("revision") or 0) + 1
    row["last_modified_by"] = owner.id
    status, body = push(owner, P, {"Project_Memberships": [row]})
    control("an owner demoting a contributor to viewer",
            outcome_for(body, "Project_Memberships", row) == "updated",
            repr(outcome_for(body, "Project_Memberships", row)))
    row = dict(row)
    row["role"] = "contributor"
    row["revision"] = int(row["revision"]) + 1
    status, body = push(owner, P, {"Project_Memberships": [row]})
    control("and restoring them",
            outcome_for(body, "Project_Memberships", row) == "updated",
            repr(outcome_for(body, "Project_Memberships", row)))


# ================================================================== probe 7 ===
# INVENTORY 25 — the last-owner guard, on its own project so the fixture above
# survives.

probe("7. The last-owner guard")

R = str(uuid.uuid4())
R_OWNER_ROW = str(uuid.uuid4())
status, body = push(owner, R, {
    "Projects": [project_row(R, owner.id)],
    "Project_Memberships": [
        membership_row(R_OWNER_ROW, R, owner.id, "owner", owner.id)
    ],
})
assert status == 200 and set(body["outcomes"].values()) == {"inserted"}, body

row = membership_row(R_OWNER_ROW, R, owner.id, "owner", owner.id,
                     end_date="2026-08-02T00:00:00.000Z", revision=2)
status, body = push(owner, R, {"Project_Memberships": [row]})
attack("the sole owner ending their own membership (end_date)",
       outcome_for(body, "Project_Memberships", row) == "unauthorized",
       repr(outcome_for(body, "Project_Memberships", row)))

row = membership_row(R_OWNER_ROW, R, owner.id, "owner", owner.id,
                     revision=2, deleted_at="2026-08-02T00:00:00.000Z")
status, body = push(owner, R, {"Project_Memberships": [row]})
attack("the sole owner tombstoning their own membership (deleted_at)",
       outcome_for(body, "Project_Memberships", row) == "unauthorized",
       repr(outcome_for(body, "Project_Memberships", row)))

row = membership_row(R_OWNER_ROW, R, owner.id, "contributor", owner.id,
                     revision=2)
status, body = push(owner, R, {"Project_Memberships": [row]})
attack("the sole owner demoting themselves to contributor",
       outcome_for(body, "Project_Memberships", row) == "unauthorized",
       repr(outcome_for(body, "Project_Memberships", row)))

# POSITIVE CONTROL: once a second owner exists, the first may leave.
#
# **The role is chosen at approval, not carried in the code** (task 11.81), so
# "a second owner" is now the owner approving somebody *as* an owner rather
# than issuing an owner-shaped invitation. There is no such thing as a leaked
# owner code, which is probe 9's subject.
r_code, r_request = join_by_code(call, owner.token, R, contrib.token, "owner")
status, rmine = get("/projects/join-requests/mine", contrib)
r_row = [x for x in rmine.get("requests", []) if x["request_id"] == r_request]
control("a second owner can join project R through the code and be approved",
        status == 200 and len(r_row) == 1
        and r_row[0].get("decision") == "approved",
        f"{status} {r_row}")

row = membership_row(R_OWNER_ROW, R, owner.id, "owner", owner.id,
                     end_date="2026-08-02T00:00:00.000Z", revision=2)
status, body = push(owner, R, {"Project_Memberships": [row]})
control("with two owners, one may end their own membership",
        outcome_for(body, "Project_Memberships", row) == "updated",
        repr(outcome_for(body, "Project_Memberships", row)))

# ...and the *former* owner is now outside the project entirely.
#
# **Since task 11.60 "outside" is measured by what comes back, not by the
# status code** (§4.27, inventory entry 28). A departed owner is a departed
# member, so the closed-membership disclosure answers them with their own
# closed row — and the property that matters, here as in probe 10, is that
# nothing of the project comes with it. Checking `403` would fail on the
# intended behaviour while passing a build that handed the whole project back.
status, body = pull(owner, R)
leaked = [t for t in (body.get("rows") or {})
          if t != "Project_Memberships" and (body.get("rows") or {}).get(t)]
mine = rows_of(body, "Project_Memberships")
attack("the departed owner still reading project R",
       status == 200 and not leaked, f"HTTP {status}, tables {leaked}")
attack("the departed owner reading a membership row not their own",
       all(m.get("user_id") == owner.id for m in mine), f"{len(mine)} rows")
status, _ = pull(contrib, R)
control("the remaining owner still can",
        status == 200, f"HTTP {status}")


# ================================================================== probe 8 ===
# INVENTORY 23 -- join-code and join-request administration: who may reach the
# owner's routes, and whether a forbidden project reads differently from a
# fictional one. **Every owner route on the router since task 11.311**, which
# brought the deletion pair (inventory 30) into the same sweep -- the set is
# derived from `project_routes.dart` below, so this comment names no count.
#
# **Rewritten wholesale by task 11.85.** What stood here attacked the per-address
# invitation routes and earned entry 23 a `Hardened` verdict on 2026-08-30. Task
# 11.81 deleted those routes, so the verdict was withdrawn rather than carried
# over: **a verdict does not transfer to a replacement because it kept the row
# number.** Every attack below is one of the seven entry 23 names, re-landed on
# the routes that replaced them.

probe("8. Join administration - the owner's routes (inventory 23)")

# A pending request on P for the approve/reject routes to name. Left undecided
# until the last block of this probe, which is what decides it.
pending_person = Person("pending")
status, body = request_to_join(call, pending_person.token, P_CODE)
assert status == 200, f"pending request on P: {status} {body}"
PENDING_REQUEST = body["request_id"]

FICTION = str(uuid.uuid4())


#: Every owner-only route on this router, as (label, method, path, body).
#:
#: **Derived once and swept over, rather than five routes attacked by hand and
#: two forgotten** -- task 10.66's standing rule. `_requireOwner` is one function
#: and this is the whole set of its callers; a new owner route that is not added
#: here is a route this probe would silently not attack, so the count is
#: asserted against the router source below rather than trusted.
def owner_routes(pid, request_id):
    return [
        ("read join settings", "GET", f"/projects/{pid}/join-settings", None),
        ("write join settings", "POST", f"/projects/{pid}/join-settings",
         {"joining_enabled": True}),
        ("rotate the join code", "POST", f"/projects/{pid}/join-code/rotate",
         {"clear_pending": False}),
        ("list join requests", "GET", f"/projects/{pid}/join-requests", None),
        ("approve a request", "POST",
         f"/projects/{pid}/join-requests/{request_id}/approve",
         {"role": "contributor"}),
        ("reject a request", "POST",
         f"/projects/{pid}/join-requests/{request_id}/reject", {}),
        ("readmit a past member", "POST", f"/projects/{pid}/members/readmit",
         {"user_id": pending_person.id, "role": "contributor"}),
        # Task 11.311. The deletion pair (task 11.290) went unswept from
        # 2026-09-20 until the control below went red on it. The `POST` is sent
        # as `schedule`, never `immediate`: this sweep aims at P, which every
        # later probe stands on, and against a build whose owner gate is gone
        # an `immediate` here would destroy it. `immediate` is attacked in
        # probe 8a, on projects nothing else uses.
        ("read deletion standing", "GET", f"/projects/{pid}/deletion", None),
        ("schedule deletion", "POST", f"/projects/{pid}/deletion",
         {"action": "schedule"}),
    ]


def as_caller(who, method, path, body):
    if method == "GET":
        return get(path, who)
    return call(path, body, who.token)


# The set this probe sweeps must be the set the server actually has. Reading it
# off the router source means a route added later fails this instrument rather
# than being quietly unattacked -- the defect that let entry 23 keep a verdict
# earned against routes that no longer existed.
#
# **Compared as a set of (method, path) since task 11.311, not as a count.** A
# count agrees whenever one route is added and another dropped, and the regex
# used to name only `get` and `post`, so a `put` or `delete` route would not
# have been counted at all. Calling `owner_routes` with the router's own
# parameter names makes its paths the templates themselves.
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_router_src = open(os.path.join(
    REPO, "server", "lib", "src", "projects", "project_routes.dart")).read()
_declared = {(m.upper(), p) for m, p in re.findall(
    r"router\.(\w+)\('(/projects/<projectId>[^']*)'", _router_src)}
_swept = {(m, p) for _, m, p, _ in owner_routes("<projectId>", "<requestId>")}
control("the swept route set is the whole owner-only surface",
        _declared and _declared == _swept,
        f"{len(_declared)} declared in project_routes.dart, "
        f"{len(_swept)} swept here; unswept {sorted(_declared - _swept)}, "
        f"swept but not declared {sorted(_swept - _declared)}")

# ---- a non-owner reaching every route ---------------------------------------
for who, who_label in ((stranger, "an outsider"), (contrib, "a contributor"),
                       (viewer, "a viewer")):
    for what, method, path, rbody_in in owner_routes(P, PENDING_REQUEST):
        status, rbody = as_caller(who, method, path, rbody_in)
        attack(f"{who_label} reaching '{what}' on project P", status == 403,
               f"HTTP {status} {strip_trace(rbody)}")

# ---- a fictional project reads the same as a forbidden one ------------------
for what, method, path, rbody_in in owner_routes(P, PENDING_REQUEST):
    _, forbidden = as_caller(stranger, method, path, rbody_in)
    fstatus, fictional = as_caller(
        stranger, method, path.replace(P, FICTION), rbody_in)
    attack(f"'{what}' telling a fictional project from a forbidden one",
           fstatus == 403
           and strip_trace(fictional) == strip_trace(forbidden),
           f"{strip_trace(fictional)} vs {strip_trace(forbidden)}")

# ---- and what the two sweeps above left behind on P -------------------------
# **Task 11.311.** For a route that writes, a `403` is the server's account of
# what it did, and the account is the thing under test. So P's owner reads the
# consequence back: nobody above may have left P scheduled for destruction.
status, p_standing = get(f"/projects/{P}/deletion", owner)
control("the owner may read project P's deletion standing",
        status == 200 and isinstance(p_standing.get("grace_days"), int),
        f"HTTP {status} {strip_trace(p_standing)}")
attack("a non-owner's request leaving project P scheduled for destruction",
       status == 200 and p_standing.get("destroy_at") is None,
       f"destroy_at={p_standing.get('destroy_at')!r}")
if p_standing.get("destroy_at") is not None:
    # Only a broken build gets here. Put P back as it was, so the probes after
    # this one measure their own controls rather than this one's failure.
    call(f"/projects/{P}/deletion", {"action": "cancel"}, owner.token)

# ---- an owner of A naming B's request id ------------------------------------
# The stranger owns Q. Q's owner names P's request id against their own
# project, in both directions somebody would actually try.
status, body = call(
    f"/projects/{Q}/join-requests/{PENDING_REQUEST}/approve",
    {"role": "owner"}, stranger.token)
attack("project Q's owner approving a request that belongs to project P",
       status == 409, f"HTTP {status} {strip_trace(body)}")
status, body = call(
    f"/projects/{Q}/join-requests/{PENDING_REQUEST}/reject", {},
    stranger.token)
attack("project Q's owner rejecting a request that belongs to project P",
       status == 409, f"HTTP {status} {strip_trace(body)}")
status, body = get("/projects/join-requests/mine", pending_person)
still_pending = [x for x in body.get("requests", [])
                 if x["request_id"] == PENDING_REQUEST]
control("and the request P's owner is looking at is still undecided",
        len(still_pending) == 1 and still_pending[0].get("decision") is None,
        f"{still_pending}")

# ---- a role value outside the enum ------------------------------------------
for role in ("admin", "OWNER", "owner ", "", "superuser", 1, None,
             ["owner"], {"role": "owner"}, "contributor "):
    status, body = call(
        f"/projects/{P}/join-requests/{PENDING_REQUEST}/approve",
        {"role": role}, owner.token)
    attack(f"approval with role {role!r}", status == 400,
           f"HTTP {status} {strip_trace(body)}")
    status, body = call(f"/projects/{P}/members/readmit",
                        {"user_id": pending_person.id, "role": role},
                        owner.token)
    attack(f"readmission with role {role!r}", status == 400,
           f"HTTP {status} {strip_trace(body)}")

# ---- readmission cannot add a stranger --------------------------------------
# The route exists to reverse a removal the owner made. Somebody with no closed
# membership here is not a past member, whatever the owner types.
status, body = call(f"/projects/{P}/members/readmit",
                    {"user_id": stranger.id, "role": "owner"}, owner.token)
attack("readmitting somebody who was never a member of project P",
       status == 409, f"HTTP {status} {strip_trace(body)}")
status, body = call(f"/projects/{P}/members/readmit",
                    {"user_id": pending_person.id, "role": "owner"},
                    owner.token)
attack("readmitting somebody whose only tie to P is a pending request",
       status == 409, f"HTTP {status} {strip_trace(body)}")

# ---- the team-size limit at the boundary and one past it --------------------
LIMITED = str(uuid.uuid4())
status, body = push(owner, LIMITED, {
    "Projects": [project_row(LIMITED, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), LIMITED, owner.id, "owner",
                       owner.id)
    ],
})
assert status == 200, body
# Limit 2: the owner plus exactly one more.
limited_code = enable_joining(call, owner.token, LIMITED, team_size_limit=2)
at_limit = Person("atlimit")
past_limit = Person("pastlimit")
status, body = request_to_join(call, at_limit.token, limited_code)
control("with the limit at 2, the second person may ask", status == 200,
        f"HTTP {status} {strip_trace(body)}")
# **Pending requests count**, so the third is refused before anybody approves.
status, body = request_to_join(call, past_limit.token, limited_code)
attack("a third person asking while the limit is 2 and one request is pending",
       status == 409 and body.get("error") == "team_is_full",
       f"HTTP {status} {strip_trace(body)}")
at_limit_rid = None
status, listed = get(f"/projects/{LIMITED}/join-requests", owner)
for r in listed.get("requests", []):
    if r["email"] == at_limit.email:
        at_limit_rid = r["request_id"]
control("the owner can see the one pending request", at_limit_rid is not None,
        f"{len(listed.get('requests', []))} listed")
status, body = call(
    f"/projects/{LIMITED}/join-requests/{at_limit_rid}/approve",
    {"role": "contributor"}, owner.token)
control("and approving it is allowed - the total does not change",
        status == 200, f"HTTP {status} {strip_trace(body)}")
status, body = request_to_join(call, past_limit.token, limited_code)
attack("and the third person is still refused once the second is a member",
       status == 409 and body.get("error") == "team_is_full",
       f"HTTP {status} {strip_trace(body)}")
# One past the boundary: raise the limit by one and the same person gets in.
status, _ = call(f"/projects/{LIMITED}/join-settings", {"team_size_limit": 3},
                 owner.token)
status, body = request_to_join(call, past_limit.token, limited_code)
control("raising the limit to 3 lets exactly that person ask",
        status == 200, f"HTTP {status} {strip_trace(body)}")
for bad in (0, -1, 1001, 2 ** 31, "5", 2.5, True):
    status, body = call(f"/projects/{LIMITED}/join-settings",
                        {"team_size_limit": bad}, owner.token)
    attack(f"a team-size limit of {bad!r}", status == 400, f"HTTP {status}")
status, body = call(f"/projects/{LIMITED}/join-settings",
                    {"team_size_limit": None}, owner.token)
control("a null team-size limit means 'leave it alone', by design",
        status == 200 and body.get("team_size_limit") == 3,
        f"HTTP {status} {body.get('team_size_limit')}")

# ---- rotation, with clear_pending both ways ---------------------------------
ROT = str(uuid.uuid4())
status, body = push(owner, ROT, {
    "Projects": [project_row(ROT, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), ROT, owner.id, "owner", owner.id)
    ],
})
assert status == 200, body
rot_code = enable_joining(call, owner.token, ROT)
keep_me = Person("keepme")
status, body = request_to_join(call, keep_me.token, rot_code)
assert status == 200, body
status, rotated = call(f"/projects/{ROT}/join-code/rotate",
                       {"clear_pending": False}, owner.token)
control("rotation without clear_pending keeps the queue",
        status == 200 and rotated.get("cleared_pending") == 0,
        f"HTTP {status} cleared={rotated.get('cleared_pending')}")
rot_code_2 = rotated["code"]
status, body = request_to_join(call, Person("afterrot").token, rot_code)
attack("the code the rotation replaced still working", status == 403,
       f"HTTP {status} {strip_trace(body)}")
status, body = request_to_join(call, Person("afterrot2").token, rot_code_2)
control("and the code it minted works", status == 200, f"HTTP {status}")
status, rotated = call(f"/projects/{ROT}/join-code/rotate",
                       {"clear_pending": True}, owner.token)
control("rotation with clear_pending empties the queue",
        status == 200 and rotated.get("cleared_pending") == 2,
        f"HTTP {status} cleared={rotated.get('cleared_pending')}")
rot_code_3 = rotated["code"]
status, body = get("/projects/join-requests/mine", keep_me)
cleared = [x for x in body.get("requests", [])
           if x.get("decision") == "cleared"]
control("a cleared requester is told, rather than left reading 'pending'",
        len(cleared) == 1, f"{body.get('requests')}")
for bad in ("yes", 1, [], {}):
    status, body = call(f"/projects/{ROT}/join-code/rotate",
                        {"clear_pending": bad}, owner.token)
    attack(f"rotation with clear_pending={bad!r}", status == 400,
           f"HTTP {status}")

# ---- approving something already decided ------------------------------------
status, body = call(
    f"/projects/{P}/join-requests/{PENDING_REQUEST}/approve",
    {"role": "contributor"}, owner.token)
control("the owner approves the pending request on P", status == 200,
        f"HTTP {status} {strip_trace(body)}")
status, body = call(
    f"/projects/{P}/join-requests/{PENDING_REQUEST}/approve",
    {"role": "owner"}, owner.token)
attack("approving the same request a second time, at a higher role",
       status == 409, f"HTTP {status} {strip_trace(body)}")
status, body = call(
    f"/projects/{P}/join-requests/{PENDING_REQUEST}/reject", {}, owner.token)
attack("rejecting a request that was already approved", status == 409,
       f"HTTP {status} {strip_trace(body)}")
status, prows = pull_all(pending_person, P)
mine_rows = [m for m in rows_of({"rows": prows}, "Project_Memberships")
             if m.get("user_id") == pending_person.id
             and not m.get("end_date")]
attack("the second approval leaving a second, higher membership row",
       len(mine_rows) == 1 and mine_rows[0].get("role") == "contributor",
       f"{[(m.get('role'), m.get('end_date')) for m in mine_rows]}")
# **Labelled rather than truncated, and task 11.220's duplicate-name guard is
# what found out why.** This loop used to describe each case as
# `f"approving request id {bogus[:24]!r}"`. Two of the eight inputs are the real
# request id with something appended — a trailing space and a `%00` — so **both
# truncated to the same 24 characters and produced the same description**, and
# the second silently overwrote the first's verdict in `RESULTS`. Seven verdicts
# were reported for eight probes, every run, and the missing one was the
# trailing-space case. That is `CLAUDE.md`'s task-11.88 rule reproduced live in
# the same function it was first found in. **A label says what the case is; a
# truncated value says what happens to fit.**
bogus_request_ids = {
    "the nil UUID": "00000000-0000-0000-0000-000000000000",
    "a path traversal prefix": "../" + PENDING_REQUEST,
    "the real id with a trailing space": PENDING_REQUEST + " ",
    "an encoded space alone": "%20",
    "300 characters": "x" * 300,
    "the real id with an encoded NUL": PENDING_REQUEST + "%00",
    "a bare asterisk": "*",
    "a SQL fragment": "' OR 1=1 --",
}
for label, bogus in bogus_request_ids.items():
    # Percent-encoded, because a trailing space or a quote in a path is
    # exactly what an attacker sends and what `http.client` refuses to put on
    # the wire raw. Encoding it is what makes the attack reach the server
    # instead of dying in this instrument.
    status, body = call(
        "/projects/" + P + "/join-requests/"
        + urllib.parse.quote(bogus, safe="%") + "/approve",
        {"role": "owner"}, owner.token)
    attack(f"approving request id — {label}",
           status in (400, 403, 404, 409), f"HTTP {status} {strip_trace(body)}")

# ---- POSITIVE CONTROL: the owner reaches every one of these routes ----------
# Without this the sweep above proves nothing: a server that refused everybody,
# owner included, would report an identical clean run.
status, body = get(f"/projects/{P}/join-settings", owner)
control("the owner may read their own join settings",
        status == 200 and bool(body.get("code")), f"HTTP {status}")
status, body = get(f"/projects/{P}/join-requests", owner)
control("and list their own join requests",
        status == 200 and isinstance(body.get("requests"), list),
        f"HTTP {status}")
status, body = call(f"/projects/{P}/join-settings",
                    {"joining_enabled": False}, owner.token)
control("and switch joining off",
        status == 200 and body.get("joining_enabled") is False,
        f"HTTP {status} {body}")
status, body = request_to_join(call, Person("afteroff").token, P_CODE)
attack("the code still working once its owner has switched joining off",
       status == 403 and body.get("error") == "join_code_not_valid",
       f"HTTP {status} {strip_trace(body)}")
status, body = call(f"/projects/{P}/join-settings",
                    {"joining_enabled": True}, owner.token)
control("and switch it back on",
        status == 200 and body.get("joining_enabled") is True,
        f"HTTP {status}")


# ================================================================= probe 8a ===
# INVENTORY 30 -- destroying a project: `GET` and `POST /projects/<id>/deletion`
# (task 11.290). **Task 11.311, and the first round these routes have had.**
# They shipped on 2026-09-20, were inventoried a day later as "owed a round",
# and this instrument found the same gap on its own on 2026-09-23, when its
# derived route set came up two short of the router.
#
# Entry 27's question set, asked of the most destructive pair on the server:
#
#   - **who may reach them** -- a contributor, a viewer, an owner who has left,
#     a stranger, and nobody signed in, for every action, each answered
#     byte-identically to the same caller naming a project that does not exist;
#   - **a project id supplied anywhere but the path**, the ways entry 29's
#     probes push a user id, with the victim's standing read back by its own
#     owner. Entry 29's lesson is that a reference taken from the route under
#     test is not a reference;
#   - **the path id itself malformed**;
#   - **a destroyed id**, which must read here exactly as a fictional one does.
#     `/sync/*` names a destroyed id (Security Model §4.13's one written
#     exception), and that exception's reopen trigger is a route answering a
#     destroyed id differently *without* already holding it -- so this route
#     answering it differently would be the trigger firing;
#   - **the body** -- an action outside the three, and a date or grace period
#     the server must ignore, because the server sets the date;
#   - **the answer** -- its field set, read from the Dart that writes it;
#     searched for anybody's identifiers; and `cache-control: no-store`.
#
# **`immediate` is only ever aimed at projects made for this probe.** Against
# a broken build it succeeds -- that is what `verify_11_85_broken_control.py`
# requires of it -- and a destroyed P would take every later probe with it.

probe("8a. Destroying a project - the two deletion routes (inventory 30)")


def raw(method, path, who=None, body=None, headers=()):
    """One request: `(status, lower-cased headers, parsed body, text)`.

    `call` and `get` both throw away the headers and the raw text, and this
    probe needs the first for `cache-control` and the second to search an
    answer for identifiers that must not be in it."""
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if who is not None:
        req.add_header("Authorization", "Bearer " + who.token)
    for name, value in headers:
        req.add_header(name, value)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, hdrs, payload = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        status, hdrs, payload = e.code, e.headers, e.read()
    text = payload.decode("utf-8", "replace")
    try:
        parsed = json.loads(payload or b"{}")
    except json.JSONDecodeError:
        parsed = None
    if not isinstance(parsed, dict):
        parsed = {"raw": text[:200]}
    return status, {k.lower(): v for k, v in hdrs.items()}, parsed, text


def deletion_path(pid):
    return f"/projects/{pid}/deletion"


def instant(value):
    """A standing's timestamp as an aware datetime, or None."""
    if not isinstance(value, str):
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def pulled_ids(who, pid):
    """`(status, tag ids, observation ids)` from everything `who` can pull."""
    status, rows = pull_all(who, pid)
    return (status, {r.get("tag_id") for r in rows.get("Tags", [])},
            {r.get("observation_id") for r in rows.get("Observations", [])})


#: What a deletion answer may carry, **read from `ProjectDeletionStanding.toJson`
#: rather than written here** -- task 11.310 found a sibling instrument still
#: saying "four fields" three days after its section said five.
_standing_src = open(os.path.join(
    REPO, "packages", "tritrack_sync", "lib", "src",
    "project_destruction.dart")).read()
_to_json = re.search(r"Map<String, Object\?> toJson\(\) => \{(.*?)\};",
                     _standing_src, re.S)
STANDING_FIELDS = (set(re.findall(r"'([a-z_]+)':", _to_json.group(1)))
                   if _to_json else set())
control("the deletion answer's field set was read from "
        "ProjectDeletionStanding.toJson",
        bool(STANDING_FIELDS) and "destroy_at" in STANDING_FIELDS,
        f"{sorted(STANDING_FIELDS)}")

#: **Task 11.312 item 7.** `ACTIONS`/`DESTROY`/`RESTORE` below used to name
#: the four `POST /projects/<id>/deletion` actions by hand, the same way the
#: field set above used to be typed rather than read — and a fourth action,
#: `restore`, landed in `ProjectDeletionAction` (task 11.302) and was never
#: added to the hand-typed list. Read the same way `STANDING_FIELDS` is: the
#: enum's own value list, stopping at its first `;` (the doc comments above
#: each member have no semicolon, so nothing before the member list ends can
#: be mistaken for it).
_action_enum = re.search(r"enum ProjectDeletionAction \{(.*?);",
                         _standing_src, re.S)
ACTION_WIRE = (re.findall(r"'([a-z]+)'", _action_enum.group(1))
               if _action_enum else [])
control("the deletion action set was read from ProjectDeletionAction",
        bool(ACTION_WIRE) and "restore" in ACTION_WIRE,
        f"{ACTION_WIRE}")
#: A human label for each wire value — the vocabulary is this probe's own
#: choice, the *set* of keys is the derived one. `set(ACTION_WIRE) <=
#: set(ACTION_LABELS)` below fails loudly if a fifth action ever lands with
#: no label here, rather than KeyError-ing mid-attack.
ACTION_LABELS = {
    "schedule": "schedule",
    "cancel": "cancel",
    "immediate": "destroy now",
    "restore": "restore",
}
control("every ProjectDeletionAction wire value has a label to attack it by",
        set(ACTION_WIRE) <= set(ACTION_LABELS),
        f"unlabeled: {sorted(set(ACTION_WIRE) - set(ACTION_LABELS))}")

#: Every `200` a deletion route gave anybody in this probe, for the field-set
#: and identifier checks at the end.
ANSWERS = []


def answered(status, parsed, text):
    if status == 200:
        ANSWERS.append((parsed, text))


# ---- the fixture -------------------------------------------------------------
#
# DV -- the victim. Published by `ex_owner`, who approves `owner` as a second
# owner and then leaves, so DV has a remaining owner and an owner who has left
# (probe 7's shape). `contrib` and `viewer` join it too. One tag and one
# observation, which is what "DV survived" is checked against.
ex_owner = Person("exowner")
DV = str(uuid.uuid4())
DV_TAG = str(uuid.uuid4())
DV_OBS = str(uuid.uuid4())
DV_EX_ROW = str(uuid.uuid4())
status, body = push(ex_owner, DV, {
    "Users": [user_row(ex_owner)],
    "Projects": [project_row(DV, ex_owner.id)],
    "Project_Memberships": [
        membership_row(DV_EX_ROW, DV, ex_owner.id, "owner", ex_owner.id)],
    "Tags": [tag_row(DV, DV_TAG, ex_owner.id)],
    "Observations": [observation(DV_OBS, DV, ex_owner.id, DV_TAG)],
})
assert status == 200, f"publish DV: {status} {body}"
assert set(outcomes(body).values()) == {"inserted"}, outcomes(body)
dv_code, _ = join_by_code(call, ex_owner.token, DV, owner.token, "owner")
join_by_code(call, ex_owner.token, DV, contrib.token, "contributor",
             code=dv_code)
join_by_code(call, ex_owner.token, DV, viewer.token, "viewer", code=dv_code)
row = membership_row(DV_EX_ROW, DV, ex_owner.id, "owner", ex_owner.id,
                     end_date="2026-08-02T00:00:00.000Z", revision=2)
status, body = push(ex_owner, DV, {"Project_Memberships": [row]})
control("DV's first owner may leave it once a second owner exists",
        outcome_for(body, "Project_Memberships", row) == "updated",
        repr(outcome_for(body, "Project_Memberships", row)))

# removed_owner -- the OTHER way a membership ends (task 11.312 item 5).
# `ex_owner` above ends their OWN stint; `isSelfDeparture`
# (packages/tritrack_sync/lib/src/membership_departure.dart) only matches
# when the caller and the row's `user_id` are the same person, so a co-owner
# ending someone ELSE's stint takes a different path through `RowAuthorizer`:
# it is not self-departure at all, and falls through to the ordinary
# `MutationRule.projectOwner` rule -- the same rule that governs every other
# write to `Project_Memberships`, and it succeeds because `owner` still holds
# an open owner membership of DV.
#
# **Read in the code first, per the brief.** The two are in the SAME state
# afterwards as far as this probe's questions go: `departureMutableColumns`
# constrains what a *departure* may touch, but the ordinary owner rule that
# governs THIS write carries no such restriction of its own, so building the
# removal row the same way -- only `end_date` (plus the four sync-bookkeeping
# columns every write moves) -- lands `removed_owner`'s row in the same
# shape as `ex_owner`'s: `end_date` set, `role` and `deleted_at` unchanged,
# no open owner membership. There is no `removed_by` column or distinct
# "removed" state anywhere in the schema -- "ended" is spelled one way
# regardless of who ended it. The one real difference is `last_modified_by`:
# it names `owner` (the actor), not `removed_owner` (the subject), because
# task 11.24's naming rule requires the caller to name themselves, and
# `owner` is who actually sent this request. That difference is about who
# acted, not about `removed_owner`'s own standing, so it has no bearing on
# whether the deletion routes below still refuse them identically to
# `ex_owner`.
removed_owner = Person("removedowner")
# Approved by `owner`, not `ex_owner` -- `ex_owner` has already left DV by
# this point (the departure above), so their token can no longer approve
# anything on it.
join_by_code(call, owner.token, DV, removed_owner.token, "owner",
             code=dv_code)
# The row's `membership_id` is server-assigned at approval time -- unlike
# `ex_owner`'s row, which this fixture inserted directly and so already knew
# the id of. Pulled rather than guessed, the same way probe 6 finds a
# member's stored row before mutating it.
status, dv_rows = pull_all(owner, DV)
dv_memberships = {m["user_id"]: m
                  for m in rows_of({"rows": dv_rows}, "Project_Memberships")}
control("the owner's pull delivers removed_owner's membership row",
        removed_owner.id in dv_memberships,
        f"{sorted(dv_memberships)}")
removal_row = dict(dv_memberships[removed_owner.id])
removal_row["end_date"] = "2026-08-02T00:00:00.000Z"
removal_row["revision"] = int(removal_row.get("revision") or 0) + 1
removal_row["last_modified_by"] = owner.id
status, body = push(owner, DV, {"Project_Memberships": [removal_row]})
control("a co-owner may remove another owner from DV",
        outcome_for(body, "Project_Memberships", removal_row) == "updated",
        repr(outcome_for(body, "Project_Memberships", removal_row)))

# DA -- the attacker's own project. The stranger owns it outright, so every
# request they send about it is one they are entitled to make, and the only
# question is whether anything in it can reach DV.
DA = str(uuid.uuid4())
status, body = push(stranger, DA, {
    "Projects": [project_row(DA, stranger.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), DA, stranger.id, "owner",
                       stranger.id)],
})
assert status == 200, f"publish DA: {status} {body}"

# DX -- destroyed by its own owner below, to ask what a destroyed id reads as.
DX = str(uuid.uuid4())
status, body = push(owner, DX, {
    "Projects": [project_row(DX, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), DX, owner.id, "owner", owner.id)],
    "Tags": [tag_row(DX, str(uuid.uuid4()), owner.id)],
})
assert status == 200, f"publish DX: {status} {body}"

# An id nothing has ever named -- the reference every refusal is compared to.
NEVER = str(uuid.uuid4())
DV_PATH = deletion_path(DV)

# ---- POSITIVE CONTROL: the owner reaches both routes ----------------------
status, hdrs, dv_standing, text = raw("GET", DV_PATH, owner)
answered(status, dv_standing, text)
control("DV's remaining owner may read its deletion standing",
        status == 200 and dv_standing.get("destroy_at") is None
        and dv_standing.get("executed_at") is None,
        f"HTTP {status} {strip_trace(dv_standing)}")
GRACE = dv_standing.get("grace_days")
# **Not a race, checked rather than assumed.** A grace period of zero would
# let the destruction sweep carry out a schedule this probe makes while the
# probe is still reading it back -- except the sweep is a separate service,
# `project-destruction`, and every stack this probe runs against brings up
# only `postgres` and `server`: `gate_smoke_test.sh` and the CI workflow say
# so literally ("up --build -d postgres server"); the two broken-control
# drills say the same thing built as an argv list ("up", "--build", "-d",
# "postgres", "server"). Nothing polls `destroy_at` here, so a
# scheduled-but-uncanceled row is inert whatever `grace_days` reads. The
# VM's `TRITRACK_PROJECT_DELETION_GRACE_DAYS=0` is a deliberate choice for
# fast cycles, not a finding -- reopen this if the sweep service ever joins
# one of the stacks named above.
control("this probe's own reasoning about GRACE is not stale: the stack it "
        "just called still answers a grace_days it can name",
        isinstance(GRACE, int), f"grace_days={GRACE!r}")
attack("the deletion standing's GET being left cacheable",
       hdrs.get("cache-control") == "no-store",
       f"cache-control={hdrs.get('cache-control')!r}")

# ---- nobody signed in --------------------------------------------------------
for what, method, rbody in (("read the standing", "GET", None),
                            ("destroy now", "POST", {"action": "immediate"})):
    status, _, b, _ = raw(method, DV_PATH, None, rbody)
    attack(f"nobody signed in reaching '{what}' on project DV",
           status in (401, 403) and not (set(b) & STANDING_FIELDS),
           f"HTTP {status} {strip_trace(b)}")


# ---- a caller-supplied project id, everywhere but the path -------------------
#
# The stranger owns DA and asks for DA's deletion, naming DV everywhere else a
# server might be tempted to read a project from. Each one is sent as
# `schedule`, which is observable and reversible; DV's standing is then read by
# DV's owner -- **an absolute reference known from the fixture** (DV was never
# scheduled), never the stranger's own answer.
REDIRECTS = {
    "a project_id in the body": dict(body={"project_id": DV}),
    "a projectId in the body": dict(body={"projectId": DV}),
    "a list of project ids in the body": dict(body={"project_id": [DV]}),
    "a project_id in the query string": dict(query=f"?project_id={DV}"),
    "a repeated project_id, in case only the last is read":
        dict(query=f"?project_id={DA}&project_id={DV}"),
    "an array-shaped project_id in the query string":
        dict(query=f"?project_id[]={DV}"),
    "an X-Project-Id header": dict(headers=(("X-Project-Id", DV),)),
    "a bare project-id header": dict(headers=(("project-id", DV),)),
    "a project_id in a cookie": dict(headers=(("Cookie", f"project_id={DV}"),)),
    "X-Original-URL and X-Rewrite-URL naming DV's route":
        dict(headers=(("X-Original-URL", DV_PATH), ("X-Rewrite-URL", DV_PATH))),
    "an On-Behalf-Of header naming DV's owner":
        dict(headers=(("On-Behalf-Of", owner.id), ("X-User-Id", owner.id))),
}
for label, how in REDIRECTS.items():
    status, _, b, text = raw(
        "POST", deletion_path(DA) + how.get("query", ""), stranger,
        {"action": "schedule", **how.get("body", {})}, how.get("headers", ()))
    answered(status, b, text)
    s, _, dv_now, _ = raw("GET", DV_PATH, owner)
    attack(f"redirecting 'schedule' with {label}",
           s == 200 and dv_now.get("destroy_at") is None and DV not in text,
           f"HTTP {status}; DV destroy_at={dv_now.get('destroy_at')!r}")
    if dv_now.get("destroy_at") is not None:
        # Only a broken build gets here. Put DV back, so the next variant is
        # scored on its own request rather than on this one's.
        raw("POST", DV_PATH, owner, {"action": "cancel"})
status, _, da_standing, _ = raw("GET", deletion_path(DA), stranger)
control("and those requests reached a route that writes: DA, the stranger's "
        "own project, is scheduled",
        status == 200 and da_standing.get("destroy_at") is not None,
        f"HTTP {status} {strip_trace(da_standing)}")

# The path, as opposed to beside it. `urllib` sends these as written; whether
# the server resolves the dot segments or not, DV's owner must not find it
# scheduled.
for label, path in {
    "the victim's id behind a traversal segment":
        f"/projects/{DA}/../{DV}/deletion",
    "the same traversal percent-encoded":
        f"/projects/{DA}%2F..%2F{DV}/deletion",
}.items():
    status, _, b, text = raw("POST", path, stranger, {"action": "schedule"})
    s, _, dv_now, _ = raw("GET", DV_PATH, owner)
    attack(f"redirecting 'schedule' with {label}",
           s == 200 and dv_now.get("destroy_at") is None,
           f"HTTP {status} {strip_trace(b)}; "
           f"DV destroy_at={dv_now.get('destroy_at')!r}")
    if dv_now.get("destroy_at") is not None:
        raw("POST", DV_PATH, owner, {"action": "cancel"})

# ---- the owner schedules DV, and the server sets the date -------------------
status, hdrs, b, text = raw("POST", DV_PATH, owner, {"action": "schedule"})
answered(status, b, text)
DV_DESTROY_AT = b.get("destroy_at")
control("DV's owner may schedule its deletion",
        status == 200 and DV_DESTROY_AT is not None
        and b.get("executed_at") is None, f"HTTP {status} {strip_trace(b)}")
attack("the deletion POST's answer being left cacheable",
       hdrs.get("cache-control") == "no-store",
       f"cache-control={hdrs.get('cache-control')!r}")
scheduled, destroy = instant(b.get("scheduled_at")), instant(DV_DESTROY_AT)
control("and the date it sets is the server's grace period from the moment "
        "of scheduling",
        isinstance(GRACE, int) and scheduled is not None and destroy is not None
        and destroy - scheduled == timedelta(days=GRACE),
        f"scheduled_at={b.get('scheduled_at')!r} destroy_at={DV_DESTROY_AT!r} "
        f"grace_days={GRACE!r}")


# ---- everybody who is not DV's owner, for every action -----------------------
#
# Each answer is compared with the same caller's answer for NEVER, an id
# nothing has named. **Byte-identical** is the requirement, not "also a 403":
# a refusal that differs by one field says the project is real.
OUTSIDERS = ((contrib, "a contributor of DV"), (viewer, "a viewer of DV"),
             (ex_owner, "DV's owner who has left"),
             (removed_owner, "DV's owner removed by a co-owner"),
             (stranger, "an outsider to DV"))
# `immediate` is DESTROY, run separately and last (see its own section
# below — a broken control that lets it through takes DV with it). `restore`
# only means anything on an already-deleted project, so it is attacked in
# its own fixture (DR, below) rather than against DV, which this whole probe
# depends on staying alive.
ACTIONS = (("read the standing", "GET", None),) + tuple(
    (ACTION_LABELS[w], "POST", {"action": w})
    for w in ACTION_WIRE if w not in ("immediate", "restore"))
DESTROY = (ACTION_LABELS["immediate"], "POST", {"action": "immediate"})
RESTORE = (ACTION_LABELS["restore"], "POST", {"action": "restore"})


def refused_like_fiction(who, pid, method, rbody):
    s, _, b, text = raw(method, deletion_path(pid), who, rbody)
    answered(s, b, text)
    fs, _, fb, _ = raw(method, deletion_path(NEVER), who, rbody)
    return (s == 403 and fs == 403 and strip_trace(b) == strip_trace(fb),
            f"HTTP {s} {strip_trace(b)} vs never-named HTTP {fs} "
            f"{strip_trace(fb)}")


for who, label in OUTSIDERS:
    for what, method, rbody in ACTIONS:
        ok, detail = refused_like_fiction(who, DV, method, rbody)
        attack(f"{label} reaching '{what}' on project DV", ok, detail)
s, _, dv_now, _ = raw("GET", DV_PATH, owner)
attack("a non-owner's 'cancel' withdrawing DV's scheduled deletion",
       s == 200 and dv_now.get("destroy_at") == DV_DESTROY_AT,
       f"destroy_at {dv_now.get('destroy_at')!r}, was {DV_DESTROY_AT!r}")

# ---- the body: only the three actions, and never a date ----------------------
for label, value in {
    "upper-case": "SCHEDULE",
    "capitalized": "Immediate",
    "a synonym, 'delete'": "delete",
    "a synonym, 'destroy'": "destroy",
    "empty": "",
    "null": None,
    "a number": 1,
    "a boolean": True,
    "a list": ["immediate"],
    "an object": {"action": "immediate"},
    "'immediate' with a trailing space": "immediate ",
    "'cancel' with an embedded NUL": "cancel\u0000",
}.items():
    status, _, b, _ = raw("POST", DV_PATH, owner, {"action": value})
    attack(f"a deletion action that is {label}", status == 400,
           f"HTTP {status} {strip_trace(b)}")
status, _, b, _ = raw("POST", DV_PATH, owner, {})
attack("a deletion request naming no action", status == 400,
       f"HTTP {status} {strip_trace(b)}")
status, _, b, _ = raw("POST", DV_PATH, owner, "immediate")
attack("a deletion body that is a bare string rather than an object",
       status == 400, f"HTTP {status} {strip_trace(b)}")
s, _, dv_now, _ = raw("GET", DV_PATH, owner)
attack("any malformed deletion request changing DV's standing",
       s == 200 and dv_now.get("destroy_at") == DV_DESTROY_AT
       and dv_now.get("executed_at") is None,
       f"destroy_at {dv_now.get('destroy_at')!r}, "
       f"executed_at {dv_now.get('executed_at')!r}")

# The server sets the date: the body carries an action and nothing else, so no
# device clock can move anybody's deadline. Cancel, then schedule again with
# every field a hostile or wrong-clocked device might send.
status, _, b, _ = raw("POST", DV_PATH, owner, {"action": "cancel"})
control("DV's owner may cancel its deletion",
        status == 200 and b.get("destroy_at") is None,
        f"HTTP {status} {strip_trace(b)}")
before = datetime.now(timezone.utc)
status, _, b, text = raw("POST", DV_PATH, owner, {
    "action": "schedule",
    "destroy_at": "2026-01-01T00:00:00.000Z",
    "scheduled_at": "2020-01-01T00:00:00.000Z",
    "grace_days": 0, "days": 0, "executed_at": None,
})
answered(status, b, text)
scheduled, destroy = instant(b.get("scheduled_at")), instant(b.get("destroy_at"))
# Refused either way: a `400` moves no deadline, and a `200` must carry the
# server's own arithmetic. An hour's tolerance on "now" because the stack's
# clock and this script's are one machine's, not one process's.
attack("a date or grace period in the body moving DV's deadline",
       status == 400 or (
           status == 200 and scheduled is not None and destroy is not None
           and isinstance(GRACE, int)
           and destroy - scheduled == timedelta(days=GRACE)
           and abs(scheduled - before) < timedelta(hours=1)),
       f"HTTP {status} scheduled_at={b.get('scheduled_at')!r} "
       f"destroy_at={b.get('destroy_at')!r}")
_, _, first, _ = raw("POST", DV_PATH, owner, {"action": "schedule"})
_, _, second, _ = raw("POST", DV_PATH, owner, {"action": "schedule"})
attack("a second 'schedule' moving the date",
       first.get("destroy_at") is not None
       and second.get("destroy_at") == first.get("destroy_at"),
       f"{first.get('destroy_at')!r} then {second.get('destroy_at')!r}")
status, _, b, _ = raw("POST", DV_PATH, owner, {"action": "cancel"})
control("and cancel it again, leaving DV as this probe found it",
        status == 200 and b.get("destroy_at") is None,
        f"HTTP {status} {strip_trace(b)}")


# ---- the path id itself, malformed -------------------------------------------
# Sent by DX's owner as `immediate`, so a value the server trimmed or
# normalized back to DX would destroy DX here and fail the positive control
# below -- the loudest way this can go wrong, on a project nothing else uses.
for label, bogus in {
    "the nil UUID": "00000000-0000-0000-0000-000000000000",
    "a path traversal prefix": "../" + DX,
    "the real id with a trailing space": DX + " ",
    "an encoded space alone": "%20",
    "300 characters": "x" * 300,
    "the real id with an encoded NUL": DX + "%00",
    "a bare asterisk": "*",
    "a SQL fragment": "' OR 1=1 --",
}.items():
    status, _, b, _ = raw(
        "POST", "/projects/" + urllib.parse.quote(bogus, safe="%")
        + "/deletion", owner, {"action": "immediate"})
    attack(f"'destroy now' naming project id — {label}",
           status in (400, 403, 404), f"HTTP {status} {strip_trace(b)}")


# ---- a destroyed id reads as a fictional one here ----------------------------
status, _, b, text = raw("POST", deletion_path(DX), owner,
                         {"action": "immediate"})
answered(status, b, text)
control("DX's owner may destroy it now",
        status == 200 and b.get("executed_at") is not None,
        f"HTTP {status} {strip_trace(b)}")
status, body = pull(owner, DX)
control("and DX is gone: its former owner's own sync of it is refused as "
        "destroyed",
        status == 403 and body.get("error") == "project_destroyed",
        f"HTTP {status} {strip_trace(body)}")
for who, label in ((owner, "DX's former owner"), (stranger, "an outsider")):
    for what, method, rbody in ACTIONS + (DESTROY,):
        ok, detail = refused_like_fiction(who, DX, method, rbody)
        attack(f"{label} telling destroyed project DX from a never-named one "
               f"on '{what}'", ok, detail)


# ---- `immediate`, last ----------------------------------------------------
# **Last in this probe on purpose.** Against a broken build the first of
# these succeeds and DV is gone, and every check after it would fail for
# that reason rather than its own -- noise in the drill's report that hides
# which attacks the broken control actually let through.

for who, label in OUTSIDERS:
    ok, detail = refused_like_fiction(who, DV, DESTROY[1], DESTROY[2])
    attack(f"{label} reaching 'destroy now' on project DV", ok, detail)
s, _, dv_now, _ = raw("GET", DV_PATH, owner)
ps, tags, obs = pulled_ids(owner, DV)
attack("project DV surviving every non-owner's 'destroy now'",
       s == 200 and dv_now.get("executed_at") is None and ps == 200
       and DV_TAG in tags and DV_OBS in obs,
       f"standing HTTP {s} executed_at={dv_now.get('executed_at')!r}; "
       f"pull HTTP {ps}, tag {'present' if DV_TAG in tags else 'GONE'}, "
       f"observation {'present' if DV_OBS in obs else 'GONE'}")


# And `immediate`, with every redirection at once. DA is destroyed -- that is
# the stranger's right -- and DV must come through with its rows.
status, _, b, text = raw(
    "POST", deletion_path(DA) + f"?project_id={DV}", stranger,
    {"action": "immediate", "project_id": DV},
    (("X-Project-Id", DV), ("X-Original-URL", DV_PATH)))
answered(status, b, text)
control("the stranger may destroy their own project DA now",
        status == 200 and b.get("executed_at") is not None,
        f"HTTP {status} {strip_trace(b)}")
s, _, dv_now, _ = raw("GET", DV_PATH, owner)
ps, tags, obs = pulled_ids(owner, DV)
attack("project DV surviving 'destroy now' sent with every redirection at once",
       s == 200 and dv_now.get("executed_at") is None and ps == 200
       and DV_TAG in tags and DV_OBS in obs and DV not in text,
       f"standing HTTP {s} executed_at={dv_now.get('executed_at')!r}; "
       f"pull HTTP {ps}, tag {'present' if DV_TAG in tags else 'GONE'}, "
       f"observation {'present' if DV_OBS in obs else 'GONE'}")


# ---- restore: the fourth action, gated narrower than the rest (task 11.312
# item 7) ------------------------------------------------------------------
#
# `restore` (task 11.302) undoes an owner's own in-app delete of their
# project. `_restore` (server/lib/src/projects/project_routes.dart) does not
# stop at `_requireOwner` the way every other action here does: it narrows
# further, via `ProjectDirectoryService.isDeletedBy` — **only the owner who
# performed the delete** (read from `Projects.last_modified_by` at the
# moment `deleted_at` was set) may restore it. A co-owner is an owner of the
# project and `_requireOwner` alone would admit them; this is the gate that
# must not.
#
# **Its own project, DR, not DV.** DV has to stay alive for the checks above
# and below, and `restore` only means anything once a project is deleted.
restore_co_owner = Person("restoreco")
DR = str(uuid.uuid4())
status, body = push(owner, DR, {
    "Projects": [project_row(DR, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), DR, owner.id, "owner", owner.id)],
})
assert status == 200, f"publish DR: {status} {body}"
dr_code, _ = join_by_code(call, owner.token, DR, restore_co_owner.token,
                          "owner")
join_by_code(call, owner.token, DR, contrib.token, "contributor",
             code=dr_code)
join_by_code(call, owner.token, DR, viewer.token, "viewer", code=dr_code)
join_by_code(call, owner.token, DR, ex_owner.token, "owner", code=dr_code)
status, dr_rows = pull_all(owner, DR)
dr_memberships = {m["user_id"]: m
                 for m in rows_of({"rows": dr_rows}, "Project_Memberships")}
control("the owner's pull delivers DR's membership rows",
        {restore_co_owner.id, contrib.id, viewer.id, ex_owner.id}
        <= set(dr_memberships),
        f"{sorted(dr_memberships)}")
dr_ex_row = dict(dr_memberships[ex_owner.id])
dr_ex_row["end_date"] = "2026-08-02T00:00:00.000Z"
dr_ex_row["revision"] = int(dr_ex_row.get("revision") or 0) + 1
dr_ex_row["last_modified_by"] = ex_owner.id  # self-departure
status, body = push(ex_owner, DR, {"Project_Memberships": [dr_ex_row]})
control("DR's third owner may leave it too",
        outcome_for(body, "Project_Memberships", dr_ex_row) == "updated",
        repr(outcome_for(body, "Project_Memberships", dr_ex_row)))

# The delete itself: a tombstone on DR's own Projects row, `owner` as
# `last_modified_by` — the same shape `server/test/integration/
# deleted_project_directory_test.dart`'s fixture builds, and what
# `isDeletedBy` reads.
dr_row = project_row(DR, owner.id, revision=2)
dr_row["deleted_at"] = "2026-09-27T00:00:00.000Z"
status, body = push(owner, DR, {"Projects": [dr_row]})
control("DR's owner may delete it (a tombstone, not destruction)",
        outcome_for(body, "Projects", dr_row) == "updated",
        repr(outcome_for(body, "Projects", dr_row)))


def deleted_listed_for(who, pid):
    """Whether `GET /projects/deleted/mine` lists `pid` for `who`.

    Not passed to `answered`: this is the listing route, whose answer is a
    `DeletedProjectDirectoryResponse` and carries project ids by design --
    it is not a deletion answer, and counting it as one reported the listing's
    own envelope and ids as leaks (VM run, 2026-09-27)."""
    status, _, body, _ = raw("GET", "/projects/deleted/mine", who)
    ids = {p.get("project_id") for p in (body.get("projects") or [])}
    return status, pid in ids


status, dr_still_deleted = deleted_listed_for(owner, DR)
control("DR reads as deleted to its owner right after the delete",
        status == 200 and dr_still_deleted, f"HTTP {status}")

# The five callers `restore` must refuse identically to a fictional project —
# every one of them but `restore_co_owner` is refused by the same
# `_requireOwner` gate every other action here is; `restore_co_owner` is an
# owner of DR and is the caller that reaches `_restore`'s own, narrower
# refusal.
DR_OUTSIDERS = (
    (restore_co_owner, "DR's co-owner who did not delete it"),
    (contrib, "a contributor of DR"),
    (viewer, "a viewer of DR"),
    (ex_owner, "DR's owner who has left"),
    (stranger, "an outsider to DR"),
)
for who, label in DR_OUTSIDERS:
    ok, detail = refused_like_fiction(who, DR, RESTORE[1], RESTORE[2])
    attack(f"{label} restoring project DR", ok, detail)

status, dr_still_deleted = deleted_listed_for(owner, DR)
attack("DR still reading as deleted after every non-deleting caller's "
       "'restore'", status == 200 and dr_still_deleted, f"HTTP {status}")

# A body `project_id` naming a DIFFERENT deleted project must not restore
# that one. `ProjectDeletionStanding.toJson` carries no `project_id` (it is
# STANDING_FIELDS above, read the same way) so the evidence is not the
# answer body -- it is which project the `/projects/deleted/mine` listing
# still names afterward, for each owner. DS: its own project, deleted by its
# own (different) owner, so it has nothing to do with DR at all -- the only
# thing that could touch it is the redirection itself.
#
# The caller is `restore_co_owner`, not DR's real owner: they are already
# refused a plain 'restore' of DR above, so this asks the narrower question
# -- does naming DS *in addition* change that refusal, or reach DS instead.
# A caller who could legitimately restore something is not needed to answer
# "not this other project"; using one who can legitimately restore nothing
# here keeps this attack from being read as evidence about DR at all.
ds_owner = Person("dsowner")
DS = str(uuid.uuid4())
status, body = push(ds_owner, DS, {
    "Users": [user_row(ds_owner)],
    "Projects": [project_row(DS, ds_owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), DS, ds_owner.id, "owner",
                       ds_owner.id)],
})
assert status == 200, f"publish DS: {status} {body}"
ds_row = project_row(DS, ds_owner.id, revision=2)
ds_row["deleted_at"] = "2026-09-27T00:00:00.000Z"
status, body = push(ds_owner, DS, {"Projects": [ds_row]})
control("DS's owner may delete it",
        outcome_for(body, "Projects", ds_row) == "updated",
        repr(outcome_for(body, "Projects", ds_row)))
status, _, b, text = raw(
    "POST", deletion_path(DR) + f"?project_id={DS}", restore_co_owner,
    {"action": "restore", "project_id": DS},
    (("X-Project-Id", DS), ("X-Original-URL", deletion_path(DS))))
answered(status, b, text)
fs, _, fb, _ = raw("POST", deletion_path(NEVER), restore_co_owner,
                   {"action": "restore", "project_id": DS})
attack("'restore' on DR naming DS in the body, query and headers, from a "
       "caller who may restore neither, refused byte-identically to a "
       "never-named project",
       status == 403 and fs == 403 and strip_trace(b) == strip_trace(fb),
       f"HTTP {status} {strip_trace(b)} vs never-named HTTP {fs} "
       f"{strip_trace(fb)}")
status, dr_still_deleted = deleted_listed_for(owner, DR)
status2, ds_still_deleted = deleted_listed_for(ds_owner, DS)
attack("DR and DS both surviving every redirection sent at a restore "
       "neither caller was entitled to",
       status == 200 and dr_still_deleted and status2 == 200
       and ds_still_deleted,
       f"DR HTTP {status} listed={dr_still_deleted}; "
       f"DS HTTP {status2} listed={ds_still_deleted}")

# POSITIVE CONTROL, last: the owner who actually deleted DR may restore it,
# and DR leaves this probe as it was found for every reader after this line.
# No redirection noise here -- that question was just asked, of a caller who
# could not act on either project either way.
status, _, b, text = raw("POST", deletion_path(DR), owner,
                         {"action": "restore"})
answered(status, b, text)
control("DR's actual deleting owner may restore it",
        status == 200 and b.get("executed_at") is None,
        f"HTTP {status} {strip_trace(b)}")
status, dr_still_deleted = deleted_listed_for(owner, DR)
control("and DR no longer reads as deleted",
        status == 200 and not dr_still_deleted, f"HTTP {status}")
status, ds_still_deleted = deleted_listed_for(ds_owner, DS)
control("and DS -- never touched by any of this -- still does",
        status == 200 and ds_still_deleted, f"HTTP {status}")


# ---- what the answers carried -------------------------------------------------
UUID_SHAPE = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I)
control("this probe collected deletion answers to search",
        len(ANSWERS) >= 4, f"{len(ANSWERS)} answers")
extra = set().union(*[set(p) for p, _ in ANSWERS]) - STANDING_FIELDS \
    if ANSWERS else set()
attack("a deletion answer carrying a field ProjectDeletionStanding.toJson "
       "does not declare", not extra,
       f"extra {sorted(extra)}; declared {sorted(STANDING_FIELDS)}")
leaks = sorted({m for _, t in ANSWERS for m in UUID_SHAPE.findall(t)}
               | {"an email address" for _, t in ANSWERS if "@" in t})
attack("an identifier or an email address in a deletion answer", not leaks,
       f"{len(leaks)} found")

# The rate limit, measured rather than read. Not pass/fail: no owner route on
# this router is limited, and inventory entry 30 records why that was left so.
codes = [raw("GET", DV_PATH, owner)[0] for _ in range(70)]
note(f"70 consecutive reads of DV's deletion standing by its owner: "
     f"{codes.count(429)} answered 429, {codes.count(200)} answered 200")


# ================================================================== probe 9 ===
# INVENTORY 24 -- join request creation. **The code is now shared rather than
# bound to one address**, which is a deliberate weakening of the credential and
# a deliberate strengthening of what it can do: holding it buys the right to
# ask, never membership.

probe("9. Asking to join - the code buys the right to ask (inventory 24)")

thief = Person("thief")

# ---- everything that is not a live code draws one answer --------------------
OFF = str(uuid.uuid4())
status, body = push(owner, OFF, {
    "Projects": [project_row(OFF, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), OFF, owner.id, "owner", owner.id)
    ],
})
assert status == 200, body
off_code = enable_joining(call, owner.token, OFF)
call(f"/projects/{OFF}/join-settings", {"joining_enabled": False},
     owner.token)

GONE = str(uuid.uuid4())
status, body = push(owner, GONE, {
    "Projects": [project_row(GONE, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), GONE, owner.id, "owner", owner.id)
    ],
})
assert status == 200, body
gone_code = enable_joining(call, owner.token, GONE)
gone_row = project_row(GONE, owner.id, revision=2)
gone_row["deleted_at"] = "2026-08-03T00:00:00.000Z"
status, body = push(owner, GONE, {"Projects": [gone_row]})
assert outcome_for(body, "Projects", gone_row) in ("updated", "deleted"), body

refusals = {}
for what, code in (
    ("a guessed code", "AAAAAAAA"),
    ("a code for a project whose owner switched joining off", off_code),
    ("a code for a project that has been deleted", gone_code),
    ("a code a rotation replaced", rot_code_2),
    ("a malformed code", "!!!"),
    ("an over-length code", "A" * 64),
    ("a code of the right shape naming no project", "ZZZZZZZZ"),
):
    status, body = request_to_join(call, thief.token, code)
    refusals[what] = (status, json.dumps(strip_trace(body), sort_keys=True))
    attack(what, status == 403 and body.get("error") == "join_code_not_valid",
           f"HTTP {status} {strip_trace(body)}")
distinct = set(refusals.values())
attack("any of those refusals telling a real project from a fictional one",
       len(distinct) == 1, f"{len(distinct)} distinct answers: {distinct}")

# The canonicalisation is not a second oracle: O/0 and I/L/1 fold together by
# design, so a code written either way must draw the same answer.
status, before = request_to_join(call, thief.token, "0123456Z")
status2, after = request_to_join(call, thief.token, "O123456Z")
attack("the O/0 folding answering differently",
       (status, strip_trace(before)) == (status2, strip_trace(after)),
       f"{status} vs {status2}")

# ---- the live code buys exactly one thing -----------------------------------
newcomer = Person("newcomer")
status, body = request_to_join(call, newcomer.token, P_CODE)
control("the live code lets a stranger ask", status == 200, f"HTTP {status}")
newcomer_request = body.get("request_id")
control("and the response carries the request id and the project name, "
        "and nothing else",
        sorted(body) == ["project_name", "request_id"], f"{sorted(body)}")

status, body = pull(newcomer, P)
leaked = [t for t in (body.get("rows") or {})
          if (body.get("rows") or {}).get(t)]
attack("a pending requester pulling the project they asked about",
       not leaked, f"tables {leaked}")
row = membership_row(str(uuid.uuid4()), P, newcomer.id, "contributor",
                     newcomer.id)
status, body = push(newcomer, P, {"Project_Memberships": [row]})
# Refused at the envelope, not row by row: a caller with no membership at all
# never reaches `RowAuthorizer`. Both shapes are a refusal and the assertion
# accepts either, because which layer says no is the server's business and
# pinning it here would make this probe fail on a correct change.
attack("a pending requester writing themselves the membership",
       status != 200
       or outcome_for(body, "Project_Memberships", row) == "unauthorized",
       f"HTTP {status} "
       f"{outcome_for(body, 'Project_Memberships', row)!r}")

status, body = request_to_join(call, newcomer.token, P_CODE)
attack("the same person holding two pending requests on one project",
       status == 409 and body.get("error") == "already_requested",
       f"HTTP {status} {strip_trace(body)}")

# **Nothing in the request body shapes the grant.** The role is chosen by the
# owner at approval and is not in the code, so there is no such thing as a
# leaked owner code -- the property that makes a shared code safe to share.
status, body = call("/projects/join-requests",
                    {"code": P_CODE, "role": "owner",
                     "project_id": Q, "user_id": owner.id},
                    thief.token)
control("a request carrying role, project_id and user_id is still accepted",
        status == 200, f"HTTP {status} {strip_trace(body)}")
thief_request = body.get("request_id")
status, listed = get(f"/projects/{P}/join-requests", owner)
thief_rows = [r for r in listed.get("requests", [])
              if r["request_id"] == thief_request]
attack("the extra fields reaching the owner's screen",
       len(thief_rows) == 1
       and sorted(thief_rows[0]) == ["claimed_name", "decided_at", "decision",
                                     "email", "project_id", "request_id",
                                     "requested_at"],
       f"{sorted(thief_rows[0]) if thief_rows else thief_rows}")
control("the address on the owner's screen is the one the server "
        "authenticated",
        bool(thief_rows) and thief_rows[0]["email"] == thief.email,
        f"{thief_rows[0]['email'] if thief_rows else '-'}")
status, body = call(f"/projects/{P}/join-requests/{thief_request}/approve",
                    {"role": "viewer"}, owner.token)
control("the owner approves as a viewer", status == 200, f"HTTP {status}")
status, prows = pull_all(thief, P)
thief_memberships = [m for m in rows_of({"rows": prows},
                                        "Project_Memberships")
                     if m.get("user_id") == thief.id and not m.get("end_date")]
attack("the role the requester asked for beating the one the owner chose",
       len(thief_memberships) == 1
       and thief_memberships[0].get("role") == "viewer",
       f"{[m.get('role') for m in thief_memberships]}")

# **Asked as `contrib`, not as the thief**, and the reason is a measurement in
# its own right: the thief has by now spent the whole per-account bucket probe
# 15 measures, so a request from them draws `429` and this check would report a
# refusal it never earned. **A bucket small enough to constrain the instrument
# is a bucket worth knowing the size of** -- see probe 15.
status, body = request_to_join(call, contrib.token, P_CODE)
attack("a member asking again with the same code",
       status == 409 and body.get("error") == "already_a_member",
       f"HTTP {status} {strip_trace(body)}")

# ---- the claimed name as untrusted text -------------------------------------
#
# **This is the one screen in this app where a person decides whether to trust
# somebody by reading a string** -- `_RequestTile` in
# `project_members_screen.dart`. A test that only checks the string is stored
# intact has not asked the question; the question is what it *renders* as, to a
# person, at the moment they tap Approve. The rendering half of that question
# is a widget test (`test/features/more/join_request_name_rendering_test.dart`)
# because it needs a real text layout; what is asserted here is which strings
# the server ever lets reach it.
NAME_ATTACKS = [
    ("over-length by one", "A" * 201),
    ("a NUL byte", "Ali\x00ce"),
    ("a newline", "Alice\nmichael.w.shafer@nau.edu"),
    ("a carriage return", "Alice\rmichael.w.shafer@nau.edu"),
    ("a DEL", "Alice\x7f"),
    ("a C1 control (NEL)", "Alice\x85michael.w.shafer@nau.edu"),
    ("a right-to-left override (U+202E)", "Alice\u202emichael"),
    ("a left-to-right override (U+202D)", "Alice\u202dmichael"),
    ("a right-to-left embedding (U+202B)", "Alice\u202bmichael"),
    ("a pop-directional-formatting (U+202C)", "Alice\u202cmichael"),
    ("a right-to-left mark (U+200F)", "Alice\u200fmichael"),
    ("a left-to-right mark (U+200E)", "Alice\u200emichael"),
    ("an Arabic letter mark (U+061C)", "Alice\u061cmichael"),
    ("a first-strong isolate (U+2068)", "\u2068Alice\u2069michael"),
    ("a left-to-right isolate (U+2066)", "Alice\u2066michael"),
    ("a pop-directional isolate (U+2069)", "Alice\u2069michael"),
    # **These two were the finding round 9 landed** (R-1, task 11.85), and they
    # are closed by task 11.89. They are line-terminating separators rather
    # than bidirectional controls, so neither of the old rule's two denylists
    # contained them, and a stranger could put a second line -- an address --
    # in the owner's approval tile. No longer baselined: they must be refused.
    ("a line separator (U+2028)",
     "Alice\u2028michael.w.shafer@nau.edu"),
    ("a paragraph separator (U+2029)",
     "Alice\u2029michael.w.shafer@nau.edu"),
    # **Everything below is refused by task 11.89 without having been named.**
    # That is the whole argument for the change: the previous rule was a list
    # of forbidden characters, written deliberately three days before R-1 by
    # somebody thinking about exactly this attack, and it was already
    # incomplete. These are here as *witnesses* to the allowlist rather than as
    # a new list to maintain -- a rule stated as what a name may contain does
    # not need to have heard of any of them.
    ("a word joiner (U+2060)", "Alice\u2060michael"),
    ("a soft hyphen (U+00AD)", "Alice\u00admichael"),
    ("a byte-order mark (U+FEFF)", "Alice\ufeffmichael"),
    # R-1's payload with the line break taken out. One line of forgery is the
    # same forgery, which is why the allowlist goes wider than the finding did.
    ("an email address on one line", "Alice michael.w.shafer@nau.edu"),
    ("a parenthesised claim", "Alice Field (project owner)"),
    ("an emoji", "Alice \U0001f985"),
]
for what, name in NAME_ATTACKS:
    who = Person("nm" + uuid.uuid4().hex[:4])
    status, body = request_to_join(call, who.token, P_CODE, name)
    attack(f"a claimed name containing {what}",
           status == 400 and body.get("error") == "invalid_name",
           f"HTTP {status} {strip_trace(body)}")

# POSITIVE CONTROL: an ordinary name, and a name in a right-to-left script,
# both get through. A validator that refused every name would pass every line
# above and be useless.
# **Task 11.89 widened this list, and that is the more important half.** The
# attacks above establish that a rule refuses things; only these establish that
# it is a rule about names and not merely a rule that says no. An allowlist's
# characteristic failure is refusing a real person -- and unlike an admitted
# attack, nobody discovers it by testing, because the person it refuses is not
# in the room. Each entry below is a name shape the allowlist had to be widened
# to keep, and every one of them was a live possibility to leave out.
for what, name in (("an ordinary name", "Alice Field"),
                   ("a Hebrew name", "\u05d0\u05dc\u05d9\u05e1"),
                   ("an Arabic name", "\u0639\u0644\u064a"),
                   # U+3000 IDEOGRAPHIC SPACE is the ordinary word space in
                   # Japanese. A rule allowing only U+0020 would have refused a
                   # great many Japanese names while reading as entirely
                   # reasonable to somebody writing it in English.
                   ("a Japanese name with an ideographic space",
                    "\u7530\u4e2d\u3000\u82b1\u5b50"),
                   # U+30FB, how Japanese separates a foreign given name from a
                   # family name.
                   ("a transliterated name with a katakana middle dot",
                    "\u30b8\u30e7\u30f3\u30fb\u30b9\u30df\u30b9"),
                   # U+00A0 NO-BREAK SPACE: what a paste from a web page or a
                   # document leaves behind. It is a space, not a break.
                   ("a name pasted with a no-break space",
                    "Dana\u00a0Reyes"),
                   # U+200C ZERO WIDTH NON-JOINER: required for correct
                   # rendering of a range of Persian and Indic names. The one
                   # format character the allowlist lets in, argued rather than
                   # overlooked.
                   ("a Persian name with a zero-width non-joiner",
                    "Ali\u200cReza"),
                   # Combining marks, without which these are refused outright.
                   ("a Vietnamese name with combining marks",
                    "\u0110\u1eb7ng Th\u1ecb"),
                   ("a hyphenated name", "Ana Mar\u00eda Fern\u00e1ndez-L\u00f3pez"),
                   # The apostrophe a phone keyboard actually produces.
                   ("a name with a curly apostrophe", "O\u2019Brien"),
                   ("a name with initials and a suffix", "J. R. Smith, Jr."),
                   ("a name at the length bound", "B" * 200),
                   ("no name at all", None)):
    who = Person("ok" + uuid.uuid4().hex[:4])
    status, body = request_to_join(call, who.token, P_CODE, name)
    control(f"{what} is accepted", status == 200,
            f"HTTP {status} {strip_trace(body)}")
    if status == 200:
        status, listed = get(f"/projects/{P}/join-requests", owner)
        stored = [r for r in listed.get("requests", [])
                  if r["request_id"] == body["request_id"]]
        expected = name.strip() if name else None
        control(f"{what} is stored exactly as sent",
                len(stored) == 1
                and stored[0].get("claimed_name") == expected,
                f"{stored[0].get('claimed_name')!r} vs {expected!r}"
                if stored else "not listed")

status, body = call("/projects/join-requests",
                    {"code": P_CODE, "claimed_name": 42},
                    Person("nonstring").token)
attack("a claimed name that is not a string at all", status == 400,
       f"HTTP {status} {strip_trace(body)}")


# ================================================================= probe 10 ===
# INVENTORY 26 — §2.3's removed member. Ending a membership must bind from the
# next request, not the next sign-in.

probe("10. A removed member loses access immediately")

status, _ = pull(viewer, P)
control("the viewer can pull before removal", status == 200, f"HTTP {status}")

status, prows = pull_all(owner, P)
vrow = next((m for m in rows_of({"rows": prows}, "Project_Memberships")
             if m["user_id"] == viewer.id and not m.get("end_date")), None)
control("the owner's pull delivers the viewer's membership row",
        vrow is not None, repr(vrow is not None))

if vrow:
    row = dict(vrow)
    row["end_date"] = "2026-08-03T00:00:00.000Z"
    row["revision"] = int(row.get("revision") or 0) + 1
    row["last_modified_by"] = owner.id
    status, body = push(owner, P, {"Project_Memberships": [row]})
    control("the owner ends the viewer's membership",
            outcome_for(body, "Project_Memberships", row) == "updated",
            repr(outcome_for(body, "Project_Memberships", row)))

    # **Since task 11.60 the pull answers 200, and what it answers *with* is
    # the property** (Security Model §4.27, inventory entry 28). A removed
    # member is handed their own closed membership row and nothing else, so
    # their device can say "you were removed" and delete its copy. Checking the
    # status code alone would now be checking the wrong thing in both
    # directions: it would fail on the intended behaviour, and it would pass a
    # build that had widened the disclosure to the whole project.
    status, body = pull(viewer, P)
    disclosed = rows_of(body, "Project_Memberships") if status == 200 else []
    other_tables = [t for t in (body.get("rows") or {})
                    if t != "Project_Memberships"
                    and (body.get("rows") or {}).get(t)]
    attack("the removed member reading anything of the project itself",
           status == 200 and not other_tables,
           f"HTTP {status}, tables {other_tables}")
    attack("the removed member reading a membership row not their own",
           all(m.get("user_id") == viewer.id for m in disclosed),
           f"{len(disclosed)} rows")
    control("...and their own closed row is what they do get",
            len(disclosed) == 1 and disclosed[0].get("end_date"),
            f"{len(disclosed)} rows, end_date "
            f"{disclosed[0].get('end_date') if disclosed else None!r}")
    row = observation(str(uuid.uuid4()), P, viewer.id, TAG_A)
    status, body = push(viewer, P, {"Observations": [row]})
    attack("the removed member pushing project data", status == 403,
           f"HTTP {status} {outcomes(body)}")
    # A push carrying only *global* rows is deliberately not a project request
    # at all (`_touchesProject`), so it still answers 200 — and must disclose
    # nothing about the project, which is what the reachability probe below
    # measures.
    status, body = push(viewer, P, {"Users": [user_row(viewer)]})
    note(f"a removed member's global-rows-only push still answers "
         f"HTTP {status} — by design; it names a project it no longer reaches")
    status, body = push(viewer, P, {"Observations": [
        observation(str(uuid.uuid4()), P, viewer.id, TAG_A)]})
    attack("...and that push does not restore their write access",
           status == 403, f"HTTP {status}")
    status, body = pull(viewer, P)
    widened = [t for t in (body.get("rows") or {})
               if t != "Project_Memberships" and (body.get("rows") or {}).get(t)]
    attack("...nor widen what they may read",
           status == 200 and not widened, f"HTTP {status}, tables {widened}")
    status, body = get("/projects/mine", viewer)
    listed = [p for p in body.get("projects", [])
              if p.get("project_id") == P]
    attack("the removed member still seeing the project in their directory",
           status == 200 and not listed, f"{len(listed)} entry")


# ================================================================= probe 11 ===
# CARRIED FROM 11.3 (§5.9(a)) — and **§5.9(a)'s subject stopped existing on
# 2026-09-10 (task 11.219).** What survives from this probe is task 11.11's
# owner-only rung for changing a tag the project holds; what is gone is the
# orphan clause and its accepted residual. See below.

probe("11. Tags — a tag lives in one project, and the change rung")

# **Four checks were deleted here (task 11.220), and this is what they proved.**
#
# §5.9(a) said a tag on *no* project was nobody's, so whoever `last_modified_by`
# named could maintain it — `"None (unlinked)"` was an offered choice in the old
# tag dialog. Three checks measured that clause: a contributor creating an
# unlinked tag, an outsider who knew its id being refused, and the person the row
# named still being able to rename it. A fourth was a `note()` re-measuring the
# clause's **accepted residual**: an orphan could be *linked* into any project by
# anyone holding its id, and thereby adopted.
#
# **All four are unexpressible now.** `Tags.project_id` is `NOT NULL` and
# `RowAuthorizer._decide`'s scope check refuses any row not claiming the request's
# project, so there is no orphan; and `Project_Tags` is not a table, so there is
# no adoption. The successor to a personal tag list is `Tag_Library`, which
# **never crosses the wire** — `kTagLibraryTable` in `lib/data/db/schema.dart`
# says so and is in neither `syncTables` nor `tableSpecs` — so this instrument,
# which speaks only to the server, has nothing left to measure there.
#
# **The residual is closed, not merely unmeasured, and that is worth an explicit
# check rather than a sentence.** The two below are what replaced the four: a
# contributor may still create a tag (the half of the old clause that survives),
# and an outsider holding a tag's id gets a row of their own and cannot touch the
# original.

OWN_NEW = str(uuid.uuid4())
status, body = push(contrib, P, {"Tags": [tag_row(P, OWN_NEW, contrib.id)]})
control("a contributor may create a tag in their own project",
        outcome_for(body, "Tags", tag_row(P, OWN_NEW, contrib.id)) == "inserted",
        repr(outcome_for(body, "Tags", tag_row(P, OWN_NEW, contrib.id))))

# The outsider's push is *accepted* — it is a different row, in their own
# project — so what is asserted is the harm, not a verdict. Asserting a refusal
# here would be asserting that two people can never use the same tag id.
row = tag_row(Q, OWN_NEW, stranger.id, revision=9)
row["tag_name"] = "Stolen"
status, body = push(stranger, Q, {"Tags": [row]})
outsider = outcome_for(body, "Tags", row)
status, prows = pull_all(owner, P)
original = next((t for t in rows_of({"rows": prows}, "Tags")
                 if t.get("tag_id") == OWN_NEW), None)
attack("an outsider who knows a tag's id reaching the project's copy of it",
       original is not None
       and original.get("project_id") == P
       and original.get("tag_name") != "Stolen",
       f"outsider push {outsider!r}; "
       f"the project's copy reads {original and original.get('tag_name')!r}")
note(f"an outsider claiming the same tag id in their own project: "
     f"{outsider!r} — a row of their own, which is correct. §5.9(a)'s "
     f"adoption residual is closed by construction: there is no link row to "
     f"push and no orphan to adopt.")

status, qrows = pull_all(stranger, Q)
delivered = {t.get("project_id") for t in rows_of({"rows": qrows}, "Tags")}
attack("the outsider's pull carrying any tag row from another project",
       delivered <= {Q}, f"projects delivered: {sorted(delivered)}")

# Task 11.11: changing a tag the project already references is owner-only.
row = tag_row(P, TAG_A, contrib.id, revision=2)
row["tag_name"] = "Contributor rename"
row["frequency_mhz"] = 151.5
status, body = push(contrib, P, {"Tags": [row]})
attack("a contributor changing a tag their project already references",
       outcome_for(body, "Tags", row) == "unauthorized",
       repr(outcome_for(body, "Tags", row)))

row = tag_row(P, TAG_A, viewer.id, revision=2)
status, body = push(viewer, P, {"Tags": [row]})
attack("a removed viewer changing that tag", status == 403 or
       outcome_for(body, "Tags", row) == "unauthorized",
       f"HTTP {status} {outcome_for(body, 'Tags', row)!r}")

row = tag_row(P, TAG_A, owner.id, revision=2)
row["tag_name"] = "Owner rename"
status, body = push(owner, P, {"Tags": [row]})
control("the project owner may change it",
        outcome_for(body, "Tags", row) == "updated",
        repr(outcome_for(body, "Tags", row)))

# **`project_id` is Q while the request names P, which is the faithful
# translation (task 11.219).** "Overwriting project Q's tag" means naming Q's
# row, and Q's row is `(TAG_B, Q)`; a copy carrying `project_id: P` would be a
# *new tag of P's own* and accepting it would be correct, which is a different
# claim. The scope check in `RowAuthorizer._decide` is what refuses this.
row = tag_row(Q, TAG_B, contrib.id, revision=2)
status, body = push(contrib, P, {"Tags": [row]})
attack("a contributor overwriting a tag belonging to project Q",
       outcome_for(body, "Tags", row) == "unauthorized",
       repr(outcome_for(body, "Tags", row)))


# ================================================================= probe 12 ===
# CARRIED FROM 11.3 (§5.9(b)) — the two unvalidated delimited-id-list columns.
# The acceptance is conditional on neither feeding reachability. Measured, not
# assumed.

probe("12. The unvalidated id-list columns feed no reachability")

POS = str(uuid.uuid4())
status, body = push(contrib, P, {"Estimated_Positions": [{
    "position_id": POS, "project_id": P, "tag_id": TAG_A,
    "session_id": None, "latitude": 35.2, "longitude": -111.6,
    "semi_major_axis": 100.0, "semi_minor_axis": 50.0,
    "rotation_angle": 30.0, "method": "lenth_mle",
    # Every id here belongs to project Q, plus the stranger's own user id.
    "observation_ids_used": f"{OBS_Q},{Q},{stranger.id}",
    "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
    "notes": None, **sync_meta(contrib.id),
}]})
listed = outcome_for(body, "Estimated_Positions", {"position_id": POS,
                                                   "project_id": P})
note(f"an estimate citing project Q's ids: {listed!r}")

ND = str(uuid.uuid4())
status, body = push(contrib, P, {"Non_Detections": [{
    "non_detection_id": ND, "project_id": P, "user_id": contrib.id,
    "tag_ids_listened_for": f"{TAG_B},{TAG_A}",
    "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
    "latitude": 35.2, "longitude": -111.6, "position_source": "gps_fix",
    "position_accuracy_m": 5.0, "elevation": 2100.0, "altitude_agl": 0.0,
    "notes": None, **sync_meta(contrib.id),
}]})
nd_outcome = outcome_for(body, "Non_Detections", {"non_detection_id": ND,
                                                  "project_id": P})
note(f"a non-detection listing project Q's tag id: {nd_outcome!r}")

status, prows = pull_all(owner, P)
p_tags = {t.get("tag_id") for t in rows_of({"rows": prows}, "Tags")}
p_users = {u.get("user_id") for u in rows_of({"rows": prows}, "Users")}
p_obs = {o.get("observation_id") for o in rows_of({"rows": prows},
                                                  "Observations")}
attack("citing project Q's tag in an id-list column does not deliver it",
       TAG_B not in p_tags, f"P delivers {len(p_tags)} tag(s)")
attack("citing the stranger's user id does not deliver their Users row",
       stranger.id not in p_users, f"P delivers {len(p_users)} user row(s)")
attack("citing project Q's observation does not deliver it",
       OBS_Q not in p_obs, f"P delivers {len(p_obs)} observation(s)")

# POSITIVE CONTROL: the same pull DOES deliver what P legitimately reaches, so
# the three refusals above are not an empty page.
control("the same pull delivers the tag P does reference",
        TAG_A in p_tags, f"{len(p_tags)} tag(s)")
control("and the Users rows of P's own members",
        {owner.id, contrib.id} <= p_users, f"{len(p_users)} user row(s)")


# ================================================================= probe 13 ===
# INVENTORY 25 — project settings and ownership itself.

probe("13. Project settings and the ownership column")

row = project_row(P, owner.id, revision=2)
row["project_name"] = "Renamed by a contributor"
row["last_modified_by"] = contrib.id
status, body = push(contrib, P, {"Projects": [row]})
attack("a contributor renaming the project",
       outcome_for(body, "Projects", row) == "unauthorized",
       repr(outcome_for(body, "Projects", row)))

row = project_row(P, contrib.id, revision=2)
row["last_modified_by"] = contrib.id
status, body = push(contrib, P, {"Projects": [row]})
attack("a contributor rewriting the project's owner_user_id to themselves",
       outcome_for(body, "Projects", row) == "unauthorized",
       repr(outcome_for(body, "Projects", row)))

row = project_row(P, owner.id, revision=2)
row["deleted_at"] = "2026-08-04T00:00:00.000Z"
row["last_modified_by"] = contrib.id
status, body = push(contrib, P, {"Projects": [row]})
attack("a contributor tombstoning the whole project",
       outcome_for(body, "Projects", row) == "unauthorized",
       repr(outcome_for(body, "Projects", row)))

# POSITIVE CONTROL: the owner may change the settings the contributor could not.
row = project_row(P, owner.id, revision=2)
row["project_name"] = "Renamed by its owner"
status, body = push(owner, P, {"Projects": [row]})
control("the owner may rename the project",
        outcome_for(body, "Projects", row) == "updated",
        repr(outcome_for(body, "Projects", row)))

# Editing somebody else's observation stays author-only for EVERYONE, owners
# included — that is why the exclude feature exists at all.
row = observation(OBS_P, P, owner.id, TAG_A, revision=2)
row["last_modified_by"] = contrib.id
row["deleted_at"] = "2026-08-04T00:00:00.000Z"
status, body = push(contrib, P, {"Observations": [row]})
attack("a contributor deleting the owner's observation",
       outcome_for(body, "Observations", row) == "unauthorized",
       repr(outcome_for(body, "Observations", row)))

row = observation(OWN, P, contrib.id, TAG_A, revision=2)
row["last_modified_by"] = owner.id
row["deleted_at"] = "2026-08-04T00:00:00.000Z"
status, body = push(owner, P, {"Observations": [row]})
attack("the OWNER deleting a contributor's observation "
       "(author-only holds in both directions)",
       outcome_for(body, "Observations", row) == "unauthorized",
       repr(outcome_for(body, "Observations", row)))


# ================================================================= probe 14 ===
# The within-batch bookkeeping sets. A push is authorized row by row against
# one pre-push snapshot, so two rows that are each legitimate alone can be
# illegitimate together.

probe("14. Two rows in one push that are only harmful together")

S = str(uuid.uuid4())
S_OWNER_A = str(uuid.uuid4())
status, body = push(owner, S, {
    "Projects": [project_row(S, owner.id)],
    "Project_Memberships": [
        membership_row(S_OWNER_A, S, owner.id, "owner", owner.id)
    ],
})
assert status == 200 and set(body["outcomes"].values()) == {"inserted"}, body
join_by_code(call, owner.token, S, contrib2.token, "owner")
status, srows_probe = pull_all(owner, S)
s_owners = [m for m in rows_of({"rows": srows_probe}, "Project_Memberships")
            if m.get("role") == "owner" and not m.get("end_date")]
control("project S has two owners to work with", len(s_owners) == 2,
        f"{len(s_owners)} owner row(s)")

status, srows = pull_all(owner, S)
s_owner_rows = [m for m in rows_of({"rows": srows}, "Project_Memberships")
                if m.get("role") == "owner" and not m.get("end_date")]
control("both owner rows are visible to build the batch from",
        len(s_owner_rows) == 2, f"{len(s_owner_rows)}")

if len(s_owner_rows) == 2:
    batch = []
    for m in s_owner_rows:
        r = dict(m)
        r["end_date"] = "2026-08-05T00:00:00.000Z"
        r["revision"] = int(r.get("revision") or 0) + 1
        r["last_modified_by"] = owner.id
        batch.append(r)
    status, body = push(owner, S, {"Project_Memberships": batch})
    result = outcomes(body)
    got = sorted(result.values())
    attack("one push ending BOTH owner memberships at once",
           got == ["unauthorized", "updated"], f"{got}")
    # Whoever's row was refused is still an owner, and is the only account that
    # can still read project S — asking the *ended* owner would draw a 403 and
    # an empty page, which would look identical to "the project lost its last
    # owner". Resolve who to ask from the outcome map rather than guessing.
    survivor = None
    for key, verdict in result.items():
        if verdict != "unauthorized":
            continue
        mid = key.split("/")[1]
        row = next((m for m in s_owner_rows
                    if m["membership_id"] == mid), None)
        if row:
            survivor = (owner if row["user_id"] == owner.id else contrib2)
    control("the refused row is identifiable, so the check below asks "
            "an account that can still read project S",
            survivor is not None, repr(survivor))
    if survivor:
        status, srows2 = pull_all(survivor, S)
        still = [m for m in rows_of({"rows": srows2}, "Project_Memberships")
                 if m.get("role") == "owner" and not m.get("end_date")
                 and not m.get("deleted_at")]
        attack("project S still has an owner afterwards",
               status == 200 and len(still) == 1,
               f"HTTP {status}, {len(still)} open owner row(s)")

# Two membership inserts for the same (project, user) in one push.
U = str(uuid.uuid4())
pair = [membership_row(str(uuid.uuid4()), U, owner.id, "owner", owner.id)
        for _ in range(2)]
status, body = push(owner, U, {
    "Projects": [project_row(U, owner.id)],
    "Project_Memberships": pair,
})
got = sorted(v for k, v in outcomes(body).items()
             if k.startswith("Project_Memberships/"))
attack("two membership rows for the same person in one publish",
       got == ["inserted", "unauthorized"], f"{got}")

# Two copies of the same tag row in one push — the duplicate-primary-key case.
#
# **A `note()` until task 11.221 defined the behaviour (2026-09-10).** What
# the note recorded was a response that contradicted itself: the first row
# landed, Postgres refused the second on the key, and the outcome map —
# keyed by the reference both rows share — kept only the second verdict, so
# the push answered `applied: 1` beside a lone `invalid`. Now the server
# detects the shared key from the push's own contents before applying
# anything, marks every row sharing it `invalid`, and applies none of them.
# So the answer is exact and it is measured: one outcome, `invalid`, and
# `applied` of zero — and nothing stored under that id, which is the half a
# count alone cannot prove.
DUP = str(uuid.uuid4())
status, body = push(owner, P, {"Tags": [tag_row(P, DUP, owner.id),
                                        tag_row(P, DUP, owner.id, revision=9)]})
dup_outcomes = outcomes(body)
dup_ref = f"Tags/{DUP}/{P}"
attack("two rows with one primary key in one push are both refused and "
       "neither is applied",
       status == 200
       and body.get("applied") == 0
       and list(dup_outcomes) == [dup_ref]
       and dup_outcomes[dup_ref] == "invalid",
       f"status {status}, applied {body.get('applied')!r}, "
       f"outcomes {dict(dup_outcomes)}")
status, prows = pull_all(owner, P)
stored = [r for r in prows.get("Tags", []) if r.get("tag_id") == DUP]
attack("and the duplicated tag id is not stored at all",
       status == 200 and stored == [],
       f"pull {status}, {len(stored)} row(s) came back under that id")


# ================================================================= probe 15 ===
# The two bounds on the join surface, **measured by hitting them** rather than
# read off a constant -- which is what inventory entries 23 and 24 ask for.
#
# **Rewritten by task 11.85.** What stood here measured invitation issuance,
# which no longer exists. Its finding (N-3: issuance unbounded, nothing prunes)
# does not carry over -- there is one code per project now, so nothing is
# issued per person -- but its *shape* does, and the second half below is that
# shape on the new surface.

probe("15. The bounds on joining, measured (inventory 23, 24)")

# ---- 1. Rate limiting on join-request creation ------------------------------
#
# **A guess is worth something now, which it was not before.** The old bucket
# was sized for redeeming a code bound to one address: a correct guess there
# would have been useless to anybody but the addressee. A correct guess here
# confirms a project exists and returns its name. So the number is measured.
sweeper = Person("sweeper")
attempts = []
t0 = time.time()
for _ in range(20):
    status, _ = request_to_join(call, sweeper.token, "ZZZZZZZZ")
    attempts.append(status)
    if status == 429:
        break
elapsed = time.time() - t0
admitted = sum(1 for s in attempts if s != 429)
control("join-request creation is rate limited at all",
        429 in attempts, f"{len(attempts)} attempts, last {attempts[-1]}")
note(f"the per-account join-request bucket admitted {admitted} guesses and "
     f"refused the next, in {elapsed * 1000:.0f} ms of wall time -- it bounds "
     f"the COUNT per account, not the rate: there is no delay between "
     f"attempts and no backoff, so an attacker's cost is one account per "
     f"{admitted} guesses")

# The bucket must be the caller's own, not one the whole server shares: a
# global bucket would make one honest crew member's mistyping lock out the
# rest. This is finding I-1's shape, asked of the newest bucket.
fresh = Person("freshsweeper")
status, _ = request_to_join(call, fresh.token, "ZZZZZZZZ")
control("a different account is not caught in the exhausted account's bucket",
        status == 403, f"HTTP {status}")
status, body = request_to_join(call, sweeper.token, P_CODE)
attack("the exhausted account slipping a REAL code past the limit",
       status == 429, f"HTTP {status} {strip_trace(body)}")

# ---- 2. Nothing prunes decided requests -------------------------------------
#
# **N-3's shape, carried over.** Entry 23 says this needs a bound before it can
# be accepted, and task 11.79 is where the bound gets built. This round's job
# is to measure it, not to fix it.
PRUNE = str(uuid.uuid4())
status, body = push(owner, PRUNE, {
    "Projects": [project_row(PRUNE, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), PRUNE, owner.id, "owner", owner.id)
    ],
})
assert status == 200, body
prune_code = enable_joining(call, owner.token, PRUNE)
decided = 0
for _ in range(6):
    who = Person("pr" + uuid.uuid4().hex[:4])
    status, rbody = request_to_join(call, who.token, prune_code)
    if status != 200:
        break
    status, _ = call(
        f"/projects/{PRUNE}/join-requests/{rbody['request_id']}/reject", {},
        owner.token)
    if status == 200:
        decided += 1
status, listed = get(f"/projects/{PRUNE}/join-requests", owner)
stored = listed.get("requests", [])
control("rejection is reachable at all (so the count below means something)",
        decided > 0, f"{decided} rejected")
note(f"{decided} requests rejected on a fresh project: {len(stored)} still "
     f"stored afterwards, {sum(1 for r in stored if r.get('decision'))} of "
     f"them decided. Nothing expires or prunes them -- the only bound is the "
     f"{MAX_JOIN_REQUESTS_RETURNED}-row cap on what the two list routes RETURN, "
     f"which bounds the response and not the table. Task 11.79 is where the "
     f"bound gets built")

# The channel that keeps open is measured where the route lives: a refused
# requester goes on reading the project's CURRENT name for as long as the row
# survives, which is forever. See `verify_11_49_server_reads.py` probe 13
# (finding R-2) -- registered there rather than asserted twice.


# ================================================================= probe 16 ===
# INVENTORY 21 — the identity rows a teammate can now see. Pull delivers every
# member's `Users` row, so a contributor holds a colleague's id AND the address
# the server authenticated for them. Both are the inputs the two identity
# invariants take.

probe("16. A teammate's identity rows")

row = user_row(owner)
row["first_name"] = "Renamed"
row["last_name"] = "ByAContributor"
row["revision"] = 9
row["last_modified_by"] = contrib.id
status, body = push(contrib, P, {"Users": [row]})
attack("a contributor rewriting the owner's name on their Users row",
       outcome_for(body, "Users", row) == "unauthorized",
       repr(outcome_for(body, "Users", row)))

row = user_row(owner)
row["email"] = contrib.email
row["revision"] = 9
row["last_modified_by"] = contrib.id
status, body = push(contrib, P, {"Users": [row]})
attack("a contributor pointing the owner's Users row at their own address",
       outcome_for(body, "Users", row) == "unauthorized",
       repr(outcome_for(body, "Users", row)))

row = {
    "user_email_id": str(uuid.uuid4()), "user_id": owner.id,
    "email": owner.email, "recorded_at": T, **sync_meta(contrib.id),
}
status, body = push(contrib, P, {"User_Emails": [row]})
attack("a contributor writing address history for the owner",
       outcome_for(body, "User_Emails", row) == "unauthorized",
       repr(outcome_for(body, "User_Emails", row)))

row = {
    "user_email_id": str(uuid.uuid4()), "user_id": contrib.id,
    "email": owner.email, "recorded_at": T, **sync_meta(contrib.id),
}
status, body = push(contrib, P, {"User_Emails": [row]})
attack("a contributor claiming the owner's address as their own prior one "
       "(the merge would then treat them as the same person)",
       outcome_for(body, "User_Emails", row) == "unauthorized",
       repr(outcome_for(body, "User_Emails", row)))

# POSITIVE CONTROL: the contributor's own profile still syncs.
row = user_row(contrib)
row["first_name"] = "Still"
row["last_name"] = "Themselves"
row["revision"] = 9
status, body = push(contrib, P, {"Users": [row]})
control("a contributor may still edit their own profile",
        outcome_for(body, "Users", row) == "updated",
        repr(outcome_for(body, "Users", row)))


# ================================================================= probe 17 ===
# A push is authorized row by row against ONE pre-push snapshot, and
# `applyPush` does not de-duplicate. So: can an earlier row in a batch put the
# authorizer into a state a later row benefits from?

probe("17. A refused row must not vouch for a later one")

# Row 1 is project Q's tag, pushed into P — refused. Row 2 is an observation
# in P naming that same tag. If row 1's refusal still recorded the tag as
# "established by this push", row 2 would sail through and the tag would be
# delivered to P on the next pull. (This is the exact shape Gate B's re-run
# against task 11.3 found live.)
row1 = tag_row(Q, TAG_B, contrib.id, revision=5)
row2 = observation(str(uuid.uuid4()), P, contrib.id, TAG_B)
status, body = push(contrib, P, {"Tags": [row1], "Observations": [row2]})
attack("a refused foreign Tags row vouching for a later observation",
       outcome_for(body, "Tags", row1) == "unauthorized" and
       outcome_for(body, "Observations", row2) == "unauthorized",
       f"{outcome_for(body, 'Tags', row1)!r} / "
       f"{outcome_for(body, 'Observations', row2)!r}")

# **The same shape through the row whose whole content is a claim about a tag.**
# That was `Project_Tags` — the one row that legitimately widened what a project
# reaches — and task 11.219 retired it, so no row widens anything any more.
# `Tag_Versions` is the surviving row of that shape, and it is worth probing for
# the same reason: a refusal on it has no other cause to hide behind.
row1 = {
    "tag_version_id": str(uuid.uuid4()), "project_id": Q, "tag_id": TAG_B,
    "effective_from": T, "frequency_mhz": 150.5, "pulse_rate": None,
    "pulse_pattern": None, "tag_name": "Collar", **sync_meta(contrib.id),
}
row2 = observation(str(uuid.uuid4()), P, contrib.id, TAG_B)
status, body = push(contrib, P, {"Tag_Versions": [row1],
                                 "Observations": [row2]})
attack("a refused foreign Tag_Versions row vouching for a later observation",
       outcome_for(body, "Tag_Versions", row1) == "unauthorized" and
       outcome_for(body, "Observations", row2) == "unauthorized",
       f"{outcome_for(body, 'Tag_Versions', row1)!r} / "
       f"{outcome_for(body, 'Observations', row2)!r}")

status, prows = pull_all(owner, P)
attack("...and project Q's tag is still not delivered to project P",
       TAG_B not in {t.get("tag_id")
                     for t in rows_of({"rows": prows}, "Tags")},
       "")

# POSITIVE CONTROL: the legitimate version of exactly this batch — a brand new
# tag, its first version, and an observation using it, all in one push — must
# work. Without it, "refused" above would be indistinguishable from a server that
# refuses every multi-row batch.
#
# **Three rows, and it used to be tag + link + observation (task 11.219).** The
# link is gone; the version is the second row now, which is also what
# `ProjectPublisher` actually sends since task 11.32 gives every new tag one.
FRESH = str(uuid.uuid4())
row1 = tag_row(P, FRESH, contrib.id)
row2 = {
    "tag_version_id": str(uuid.uuid4()), "project_id": P, "tag_id": FRESH,
    "effective_from": T, "frequency_mhz": 150.5, "pulse_rate": None,
    "pulse_pattern": None, "tag_name": "Collar", **sync_meta(contrib.id),
}
row3 = observation(str(uuid.uuid4()), P, contrib.id, FRESH)
status, body = push(contrib, P, {"Tags": [row1], "Tag_Versions": [row2],
                                 "Observations": [row3]})
control("a new tag, its first version and an observation using it, in one push",
        sorted(outcomes(body).values()) == ["inserted"] * 3,
        f"{sorted(outcomes(body).values())}")


# ================================================================= probe 18 ===
# `Observation_Exclusions.observation_id` is not a primary key, not an identity
# column and not an enum, so `RowValidator` gives it no type, shape or length
# check at all. What actually stops a hostile value?

probe("18. The unchecked reference column")

cases = {
    "an integer where an observation id belongs": 12345,
    "a nested object": {"observation_id": OBS_P},
    "a control character (K-4's class)": "obs\u0000\u001b[2J",
    "a 1 MB string": "x" * 1_000_000,
    "an empty string": "",
}
for label, value in cases.items():
    xid = str(uuid.uuid4())
    row = exclusion(xid, P, OBS_P, contrib.id)
    row["observation_id"] = value
    status, body = push(contrib, P, {"Observation_Exclusions": [row]})
    got = outcome_for(body, "Observation_Exclusions",
                      {"exclusion_id": xid, "project_id": P})
    note(f"observation_id = {label}: HTTP {status}, outcome {got!r}")

# POSITIVE CONTROL: a well-formed value on the same column still lands, so the
# outcomes above are about the value and not about the probe.
xid = str(uuid.uuid4())
row = exclusion(xid, P, OBS_P, contrib.id)
status, body = push(contrib, P, {"Observation_Exclusions": [row]})
control("a well-formed observation_id on the same column still lands",
        outcome_for(body, "Observation_Exclusions", row) == "inserted",
        repr(outcome_for(body, "Observation_Exclusions", row)))


# ==================================================================== verdict ==

print("\n" + "=" * 72)
if NOTES:
    print("Observations (not pass/fail — read them):")
    for n in NOTES:
        print("  - " + n)
    print()
# A baselined entry that no longer runs at all is the failure mode this whole
# instrument exists to avoid — a check deleted reads as a check that passed.
missing = sorted(set(BASELINE) - _seen_attacks)
if missing:
    BASELINE_DRIFT.append(
        "baselined attacks that this run never attempted: " + "; ".join(missing)
    )

if BASELINE:
    print("Known-open, registered, and re-measured this run:")
    for what, why in BASELINE.items():
        print(f"  - {what}\n      {why}")
    print()
if CONTROL_FAILURES:
    print("POSITIVE CONTROLS FAILED — this run measured nothing:")
    for f in CONTROL_FAILURES:
        print("  ! " + f)
if BASELINE_DRIFT:
    print("BASELINE DRIFT:")
    for f in BASELINE_DRIFT:
        print("  ! " + f)
if ATTACK_FAILURES:
    print("ATTACKS THAT SUCCEEDED AND ARE NOT REGISTERED:")
    for f in ATTACK_FAILURES:
        print("  ! " + f)
if not (CONTROL_FAILURES or ATTACK_FAILURES or BASELINE_DRIFT):
    print("Every unregistered attack refused; every positive control fired; "
          "every registered one is still open exactly as recorded.")
print("=" * 72)

summary_path = os.environ.get("VERIFY_119_JSON")
if summary_path:
    with open(summary_path, "w") as f:
        json.dump({
            "results": RESULTS,
            "admitted": sorted(k for k, v in RESULTS.items()
                               if v == "ADMITTED"),
            "blind": sorted(k for k, v in RESULTS.items() if v == "BLIND"),
            "attack_failures": ATTACK_FAILURES,
            "control_failures": CONTROL_FAILURES,
            "baseline_drift": BASELINE_DRIFT,
            "notes": NOTES,
        }, f, indent=2)
    print(f"summary written to {summary_path}")

# A dead server satisfies every negative assertion, so prove it is still there.
status, _ = call("/health", None, method="GET")
if status != 200:
    print(f"INCONCLUSIVE: /health answered {status} at the end of the run.")
    sys.exit(1)

sys.exit(1 if (CONTROL_FAILURES or ATTACK_FAILURES or BASELINE_DRIFT)
         else 0)

#!/usr/bin/env python3
# gate-instrument: verify_d1_per_row_oracle
"""Re-runs Security Gate C's D-1 reproduction (`TriTrack_Security_Model.md`
§8.4) against a live stack over raw HTTP — no client code, no mocks.

The finding: task 10.21 made the *HTTP status code* uniform, and did it
correctly, but a push also returns a per-row `outcomes` map inside every `200`,
and that map went on answering the question the status code no longer did.
Three arms were reproduced live — a stranger's registration status (three-way),
a tag id's existence, and a row key's existence.

**Arm (b) probes a different row than it used to (task 11.219, retranslated by
task 11.220).** It asked whether a tag id's existence showed through an
`Observations` reference *and* through a `Project_Tags` link, the row whose whole
content was a claim about a tag. That table is retired; `Tag_Versions` is the row
of that shape now and is what the second half of arm (b) pushes. **What arm (b)
asserts is unchanged, and it is stronger underneath**: `Tags` is keyed
`(tag_id, project_id)`, so the two probes name keys in the stranger's own project
and the server never looks at the victim's at all — which is also why H-3 came
off `verify_h3_existence_oracle_sweep.py`'s accepted-findings list on the same
day.

This is `verify_c2_existence_oracle.py`'s method applied one level down. Every
check sends the *same shape of push* twice, differing only in a fact about what
the server already holds, and asserts the per-row outcomes cannot be told
apart. It compares outcomes to each other rather than to expected values, so it
keeps holding if the vocabulary is reworded.

The attacker throughout is an ordinary registered user with no relationship to
anything they are asking about — which is the whole point of the finding.

Usage (with the e2e stack up — see the README's "End-to-end integration suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -f docker-compose.yml -f docker-compose.e2e.yml up --build -d
    python3 scripts/verify_d1_per_row_oracle.py

Exits non-zero if any pair is distinguishable. Verified to fail loudly against a
build with the task 10.29 changes reverted, which is the only evidence that it
is testing anything at all.

**Arm (c) is now checked as closed, not bounded.** It used to be the one arm
that deliberately did not fail this script: a primary key lifted from someone
else's export was the create-if-absent collision inherent to client-chosen
primary keys, which §4.13 stated and bounded. Task 10.35 made primary keys
project-scoped, so a key another project holds no longer collides and there is
nothing left to answer. The check below is an equivalence like every other arm,
and the victim's row is still verified untouched — the bound outlives the
residual it used to bound.
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
    email = f"d1-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
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
    # Task 10.55: a `Users` row may only claim its account's authenticated
    # address. Returned here so the fixtures below push the real one — an
    # invented address is now a refusal, which would make every arm below
    # "indistinguishable" for the wrong reason.
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


def observation(oid, pid, uid, tag=None):
    return {
        "observation_id": oid, "project_id": pid, "user_id": uid,
        "tag_id": tag,
        "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
        "latitude": 35.19, "longitude": -111.65, "position_source": "gps_fix",
        "elevation": 2100.0, "altitude_agl": 0.0,
        "observation_type": "directional", "signal_type": "regular_pulse",
        "signal_strength": "strong", "notes": None,
        "created_at": T, "updated_at": T, "revision": 1,
        "last_modified_by": uid, "origin_device_id": "device-x",
    }


def tag_row(pid, tid, uid):
    """A tag. **`pid` is new in task 11.219** — a tag belongs to one project and
    the row is keyed `(tag_id, project_id)`."""
    return {
        "tag_id": tid, "project_id": pid, "lineage_id": tid, "copied_at": None,
        "frequency_mhz": 150.1, "tag_name": "Tag",
        "date_put_on": T, "status": "active", "color_hex": "#FF0000",
        "created_at": T, "updated_at": T, "revision": 1,
        "last_modified_by": uid, "origin_device_id": "device-x",
    }


def tag_version_row(vid, pid, tid, uid):
    """What a tag read at a moment (task 11.32).

    **This row inherited `Project_Tags`' job in arm (b) below** — see the probe
    there for why the arm needs a row whose whole content is a claim about a
    tag.
    """
    return {
        "tag_version_id": vid, "project_id": pid, "tag_id": tid,
        "effective_from": T, "frequency_mhz": 150.1, "pulse_rate": None,
        "pulse_pattern": None, "tag_name": "Tag",
        "created_at": T, "updated_at": T, "revision": 1,
        "last_modified_by": uid, "origin_device_id": "device-x",
    }


# `project_tag` is gone with `Project_Tags` (task 11.219): a tag is created
# inside the project that holds it, so `tag_row`'s `pid` is the link.


def push(token, device, project, rows):
    """Returns (status, sorted outcome values) — the *answers*, stripped of the
    ids that keyed them, since two probes necessarily name different rows."""
    status, body = call("/sync/push", {
        **ENVELOPE, "project_id": project, "device_id": device, "rows": rows,
    }, token)
    try:
        outcomes = sorted(json.loads(body).get("outcomes", {}).values())
    except json.JSONDecodeError:
        outcomes = [body[:120]]
    return status, outcomes


failures = []
residuals = []


def indistinguishable(name, held, absent):
    same = held == absent
    print(("  PASS  " if same else "  FAIL  ") + name)
    if not same:
        print(f"          server holds it -> {held[0]} {held[1]}")
        print(f"          server does not -> {absent[0]} {absent[1]}")
        failures.append(name)


def check(name, condition, detail=""):
    print(("  PASS  " if condition else "  FAIL  ") + name +
          (f"  {detail}" if detail else ""))
    if not condition:
        failures.append(name)


preflight(BASE, LINK_DIR)
print("Signing in a victim, a bystander with no profile, and a stranger...")
victim_tok, victim_id, victim_dev, victim_email = sign_in("victim")
# Signs in and is never heard from again: an account with no pushed `Users`
# row. Before task 10.29 this was the middle value of the three-way.
_, quiet_id, _, _ = sign_in("quiet")
stranger_tok, stranger_id, stranger_dev, stranger_email = sign_in(
    "stranger")

# A user id this server has genuinely never seen.
unknown_id = str(uuid.uuid4())

victim_project = str(uuid.uuid4())
victim_tag = str(uuid.uuid4())
status, body = call("/sync/push", {
    **ENVELOPE, "project_id": victim_project, "device_id": victim_dev,
    "rows": {
        "Users": [user_row(victim_id, "Victim", victim_email)],
        "Projects": [project_row(victim_project, victim_id)],
        "Tags": [tag_row(victim_project, victim_tag, victim_id)],
        "Observations": [
            observation(f"vic-{RUN}", victim_project, victim_id, victim_tag)
        ],
    },
}, victim_tok)
assert status == 200, (status, body)
assert "unauthorized" not in body, ("the victim's own project must publish "
                                    "cleanly, or nothing below proves anything: "
                                    f"{body}")

# The stranger's own project, so every probe below is a push they are fully
# entitled to make. Nothing about these requests is refused for an unrelated
# reason.
stranger_project = str(uuid.uuid4())
status, body = call("/sync/push", {
    **ENVELOPE, "project_id": stranger_project, "device_id": stranger_dev,
    "rows": {
        "Users": [user_row(stranger_id, "Stranger", stranger_email)],
        "Projects": [project_row(stranger_project, stranger_id)],
    },
}, stranger_tok)
assert status == 200, (status, body)

print("\nD-1 arm (a) — does this person have an account here?")


def name_in_observation(named):
    oid = f"probe-a-{named[:8]}-{RUN}"
    return push(stranger_tok, stranger_dev, stranger_project, {
        "Observations": [observation(oid, stranger_project, named)],
    })


published = name_in_observation(victim_id)
account_only = name_in_observation(quiet_id)
never_seen = name_in_observation(unknown_id)

indistinguishable("a published user and an unknown one", published, never_seen)
indistinguishable("an account with no profile and an unknown one",
                  account_only, never_seen)


def offer_users_row(named):
    # A global-only push, naming a project id that has never existed — the
    # exact request the finding recorded. `revision` 0 so the row loses the
    # merge outright where one exists, which is how the third value
    # (`lost_to_server`) was reached.
    return push(stranger_tok, stranger_dev, str(uuid.uuid4()), {
        "Users": [{**user_row(named, "Whoever"), "revision": 0}],
    })


indistinguishable("a stale Users row for a published user and for an unknown one",
                  offer_users_row(victim_id), offer_users_row(unknown_id))
indistinguishable("a stale Users row for an account-only user and for an unknown one",
                  offer_users_row(quiet_id), offer_users_row(unknown_id))

print("\nD-1 arm (b) — does this tag id exist on this server?")


def use_tag(tid, label):
    oid = f"probe-b-{label}-{RUN}"
    return push(stranger_tok, stranger_dev, stranger_project, {
        "Observations": [
            observation(oid, stranger_project, stranger_id, tid)
        ],
    })


indistinguishable(
    "referencing another project's tag and referencing a tag that does not exist",
    use_tag(victim_tag, "held"),
    use_tag(str(uuid.uuid4()), "absent"),
)


def claim_tag(tid):
    """A row whose whole content is a claim about a tag `tid`.

    **This probe used to push a `Project_Tags` link (task 11.219 retired that
    table; retranslated by task 11.220).** The reason the arm needs such a row
    is unchanged: `Observations` above carries a bearing's own data, so its
    refusal has other causes to hide behind, while a row that is *nothing but* a
    claim about a tag has none. `Tag_Versions` is that row now.
    """
    return push(stranger_tok, stranger_dev, stranger_project, {
        "Tag_Versions": [
            tag_version_row(str(uuid.uuid4()), stranger_project, tid,
                            stranger_id),
        ],
    })


indistinguishable(
    "claiming another project's tag and claiming a tag that does not exist",
    claim_tag(victim_tag),
    claim_tag(str(uuid.uuid4())),
)

print("\nThe flows the strictness above must not break")

# A tag the stranger creates and uses — in one request, the way `SyncEngine`
# sends it, and then split across requests, the way `ProjectPublisher` does.
#
# **Two rows and two requests since task 11.219, where there were three of
# each.** The `Project_Tags` link is gone, so "create, link and use" is "create
# and use". The claim these two checks make is the one that matters and it has
# not moved: the strictness above must not cost anybody the ability to record a
# bearing against a tag they just made.
own_tag = str(uuid.uuid4())
status, outcomes = push(stranger_tok, stranger_dev, stranger_project, {
    "Tags": [tag_row(stranger_project, own_tag, stranger_id)],
    "Observations": [
        observation(f"own-{RUN}", stranger_project, stranger_id, own_tag)
    ],
})
check("a new tag and an observation using it, in one push",
      status == 200 and set(outcomes) == {"inserted"}, f"{status} {outcomes}")

split_tag = str(uuid.uuid4())
statuses = [
    push(stranger_tok, stranger_dev, stranger_project,
         {"Tags": [tag_row(stranger_project, split_tag, stranger_id)]}),
    push(stranger_tok, stranger_dev, stranger_project,
         {"Observations": [observation(f"split-{RUN}", stranger_project,
                                       stranger_id, split_tag)]}),
]
check("the same two, one table per request, as publish sends them",
      all(s == 200 and o == ["inserted"] for s, o in statuses), str(statuses))

print("\nD-1 arm (c) — closed by task 10.35's project-scoped primary keys")

taken = push(stranger_tok, stranger_dev, stranger_project, {
    "Observations": [
        observation(f"vic-{RUN}", stranger_project, stranger_id)
    ],
})
free = push(stranger_tok, stranger_dev, stranger_project, {
    "Observations": [
        observation(f"free-{RUN}", stranger_project, stranger_id)
    ],
})
check("a primary key another project already holds is indistinguishable "
      "from a free one",
      taken == free,
      f"taken answers {taken[1]}, free answers {free[1]}")

# The bound: existence is all that escapes. The victim's row is untouched, in
# the victim's project, still theirs — and the probe was told nothing about it.
status, body = call("/sync/pull", {
    **ENVELOPE, "project_id": victim_project, "device_id": victim_dev,
    "cursor": 0, "batch_size": 500,
}, victim_tok)
rows = json.loads(body).get("rows", {}).get("Observations", [])
victim_row = next((r for r in rows if r["observation_id"] == f"vic-{RUN}"), None)
check("the victim's row is untouched and still theirs",
      victim_row is not None
      and victim_row["project_id"] == victim_project
      and victim_row["user_id"] == victim_id,
      "" if victim_row else "row missing entirely")

print()
if failures:
    print(f"FAILED — {len(failures)} distinguishable pair(s):")
    for name in failures:
        print(f"  - {name}")
    sys.exit(1)
print("All D-1 probe pairs are indistinguishable.")
if residuals:
    print("Recorded residuals (stated and bounded in §4.13, not closed):")
    for name in residuals:
        print(f"  - {name}")

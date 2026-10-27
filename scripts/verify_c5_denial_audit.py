#!/usr/bin/env python3
# gate-instrument: verify_c5_denial_audit
"""Re-runs Security Gate C's C-5 reproduction (`TriTrack_Security_Model.md`
§7.3 B5) against a live stack — raw HTTP in, `psql` against the real database
out. No client code, no mocks, no in-process shortcuts.

The finding: `auditDenial` wrote on the same `Connection` the sync handler's
`runTx` already owned, `postgres` refused every such write, and `record`'s
catch swallowed the exception. `authorization_denied` was the *only* event type
that never appeared, and nothing said so. **The original evidence was a count
of zero taken from `psql` after a gate's worth of 403s** — so this script
reproduces the finding the same way it was found, by counting rows in the
database rather than by trusting a 403 to mean a row was written.

`server/test/integration/sync_audit_test.dart` pins the same behaviour at the
handler layer and is what CI runs. It builds its own two-connection wiring,
though, which is the thing under test: it would still pass if
`bin/server.dart` regressed to a single shared connection. This script is the
part that exercises the artifact people actually deploy.

Written by task 10.25, not 10.23 — C-1 through C-4 each got a live
verification script and C-5 did not, which is a gap in the evidence rather
than in the fix.

Usage (with the e2e stack up — see the README's "End-to-end integration suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml \
      up --build -d
    python3 scripts/verify_c5_denial_audit.py

This script's own `COMPOSE` default names that same `-p tritrack-gate`
project (task 10.47 / Security Model §10.7.3) — it used to default to no `-p`
at all, which resolves to whatever project name the *current directory*
implies, indistinguishable from a developer's own `docker compose up`. This
script only reads (`psql -tA ... -c`, never a write), so nothing was at risk
the way F15's `-v` teardown was — but "reads the wrong stack's data and
reports it as the gate's" is still a wrong result, not a safe one. Set
`COMPOSE` yourself if you bring the stack up under a different project name.

Exits non-zero if any check fails. Verified to fail loudly against a build
with `bin/server.dart`'s dedicated `auditConnection` reverted to share `db`,
where the denial count stays at zero exactly as the gate recorded.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import ENVELOPE, preflight  # noqa: E402
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from db_env import postgres_env  # noqa: E402

BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")
COMPOSE = os.environ.get(
    "COMPOSE",
    "docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml",
).split()

T = "2026-08-01T12:00:00.000Z"
RUN = uuid.uuid4().hex[:8]

# The coordinates the stranger's refused push carries. §4.7's never-log list
# says a coordinate may not reach any log; a denial that helpfully recorded
# "what they tried to write" would be the same finding from the other end.
BAIT_LAT = 35.987654
BAIT_LON = -111.123456
BAIT_NOTE = f"NEVERLOG-{RUN}"


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


def sql(query):
    """Straight at the database, past every route the server offers.

    The original finding was invisible from outside — the 403s looked
    correct — so reading the log through the server's own console would beg
    the question.
    """
    env = postgres_env(ROOT)
    result = subprocess.run(
        COMPOSE
        + [
            "exec", "-T", "postgres",
            "psql", "-U", env["POSTGRES_USER"], "-d", env["POSTGRES_DB"],
            "-tA", "-F", "|", "-c", query,
        ],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(f"psql failed: {query}")
    return [line for line in result.stdout.strip().splitlines() if line]


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def sign_in(label):
    email = f"c5-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
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
    return parsed["session_token"], parsed["user_id"], device, email


def user_row(uid, first, email=None):
    return {
        "user_id": uid, "first_name": first, "last_name": "Person",
        # Task 10.55: an address the server never authenticated for this id is
        # refused, so a caller's own row must carry the address it signed in
        # with. The fallback survives for rows deliberately naming someone
        # else, which are refused for naming, not for the address.
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


def observation(oid, pid, uid, lat=35.19, lon=-111.65, notes=None):
    return {
        "observation_id": oid, "project_id": pid, "user_id": uid,
        "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
        "latitude": lat, "longitude": lon, "position_source": "gps_fix",
        "elevation": 2100.0, "altitude_agl": 0.0,
        "observation_type": "directional", "signal_type": "regular_pulse",
        "signal_strength": "strong", "notes": notes,
        "created_at": T, "updated_at": T, "revision": 1,
        "last_modified_by": uid, "origin_device_id": "device-x",
    }


failures = []


def check(name, condition, detail=""):
    print(("  PASS  " if condition else "  FAIL  ") + name
          + (f"  {detail}" if detail else ""))
    if not condition:
        failures.append(name)


preflight(BASE, LINK_DIR)
print("Signing in an owner and an unrelated stranger...")
owner_tok, owner_id, owner_dev, owner_email = sign_in("owner")
stranger_tok, stranger_id, stranger_dev, stranger_email = sign_in("stranger")

project = str(uuid.uuid4())
status, body = call("/sync/push", {
    **ENVELOPE, "project_id": project, "device_id": owner_dev,
    "rows": {
        "Users": [user_row(owner_id, "Owner", owner_email)],
        "Projects": [project_row(project, owner_id)],
        "Observations": [observation(f"obs-{RUN}", project, owner_id)],
    },
}, owner_tok)
assert status == 200, (status, body)

# The stranger's own Users row, so nothing below is refused for an unrelated
# reason.
call("/sync/push", {
    **ENVELOPE, "project_id": str(uuid.uuid4()), "device_id": stranger_dev,
    "rows": {"Users": [user_row(stranger_id, "Stranger", stranger_email)]},
}, stranger_tok)

before = int(sql(
    "SELECT count(*) FROM auth_audit_log WHERE event = 'authorization_denied'"
)[0])

print("\nB5 — a stranger probes the owner's project, three ways")

status, _ = call("/sync/push", {
    **ENVELOPE, "project_id": project, "device_id": stranger_dev,
    "rows": {"Observations": [observation(
        f"hostile-{RUN}", project, stranger_id,
        lat=BAIT_LAT, lon=BAIT_LON, notes=BAIT_NOTE)]},
}, stranger_tok)
check("the push is refused", status == 403, f"got {status}")

status, _ = call("/sync/pull", {
    **ENVELOPE, "project_id": project, "device_id": stranger_dev,
    "cursor": 0, "batch_size": 500,
}, stranger_tok)
check("the pull is refused", status == 403, f"got {status}")

status, _ = call("/sync/ack", {
    **ENVELOPE, "project_id": project, "device_id": stranger_dev, "cursor": 0,
}, stranger_tok)
check("the ack is refused", status == 403, f"got {status}")

print("\nThe rows the finding said were never written")

rows = sql(
    "SELECT event, user_id, outcome, reason, source_address, request_id "
    "FROM auth_audit_log WHERE event = 'authorization_denied' "
    f"AND user_id = '{stranger_id}' ORDER BY id"
)
after = int(sql(
    "SELECT count(*) FROM auth_audit_log WHERE event = 'authorization_denied'"
)[0])

# This is the check whose recorded value was 0. Everything else here is
# detail; this line is the finding.
check("authorization_denied rows exist at all", after > before,
      f"{before} -> {after}")
check("one row per denied request, naming this caller", len(rows) == 3,
      f"got {len(rows)}")

kinds = sorted(r.split("|")[3] for r in rows)
check("all three routes audited, not just push", kinds == ["ack", "pull", "push"],
      f"got {kinds}")

# `rows` empty is the finding, so every per-row assertion below is written to
# fail on an empty list rather than pass vacuously. `all([])` is True — a
# check that reports PASS when there is nothing to check is the same silent
# success this finding was made of, and the first draft of this script had it.
def every_row(name, predicate, describe):
    check(name, bool(rows) and all(predicate(r) for r in rows),
          "no rows to check" if not rows else f"got {[describe(r) for r in rows]}")


every_row("each row names the project that was refused",
          lambda r: r.split("|")[2] == project, lambda r: r.split("|")[2])
every_row("each row records the source address",
          lambda r: r.split("|")[4], lambda r: r.split("|")[4])
every_row("each row carries the trace id the caller was given",
          lambda r: r.split("|")[5], lambda r: r.split("|")[5])

print("\n§4.7's never-log list, on the path that just started writing")

# A log that begins working is a new place for a coordinate to land. Checked
# against the whole table, not just these rows, because the point is that
# there is nowhere in this schema to put one.
leaks = sql(
    "SELECT count(*) FROM auth_audit_log WHERE "
    f"outcome LIKE '%{BAIT_NOTE}%' OR reason LIKE '%{BAIT_NOTE}%' OR "
    f"outcome LIKE '%{BAIT_LAT}%' OR reason LIKE '%{BAIT_LAT}%' OR "
    f"outcome LIKE '%{BAIT_LON}%' OR reason LIKE '%{BAIT_LON}%'"
)
check("the refused row's coordinates and notes are not in the log",
      leaks[0] == "0", f"{leaks[0]} matching rows")

columns = sql(
    "SELECT column_name FROM information_schema.columns "
    "WHERE table_name = 'auth_audit_log' ORDER BY column_name"
)
check("the table still has nowhere to put a token or a coordinate",
      not any("token" in c or "lat" in c or "lon" in c for c in columns),
      ",".join(columns))

print("\nThe other event types still record — the finding was one type, "
      "not the log")
events = dict(
    (line.split("|")[0], int(line.split("|")[1]))
    for line in sql("SELECT event, count(*) FROM auth_audit_log GROUP BY event")
)
for event in ("link_requested", "link_redeemed", "session_created"):
    check(f"{event} still recorded", events.get(event, 0) > 0,
          f"{events.get(event, 0)}")

print()
if failures:
    print(f"{len(failures)} CHECK(S) FAILED: {failures}")
    sys.exit(1)
print("C-5 closed: denials reach the audit log on the deployed wiring, "
      "and carry no row content.")

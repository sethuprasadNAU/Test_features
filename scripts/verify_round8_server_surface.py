#!/usr/bin/env python3
# gate-instrument: verify_round8_server_surface
"""Task 11.64 — round 8's server checks, committed as an instrument.

`SECURITY_SCOPE_AND_EXIT.md` §3 items **14, 15 and 20**:

  14 — `/sync/push`, and the `/sync/pull` and `/sync/ack` cursors
  15 — the auth routes (magic link, redeem) and `GET /projects/mine`
  20 — the dev magic-link sender, the server's only subprocess call

**Why this file exists, and it is the reason eight gates cost what they did.**
Round 8 (2026-08-17, Security Model §16.2) attacked these entries with about
seventy checks **written by hand during that run and never committed**. Nothing
in the repository reproduced them, so "re-run Gate C" meant "write them again"
— about half a day of Opus time, paid afresh every round — while the committed
half of the gate is three and a half minutes for sixteen instruments. §6.1
priced that gap on 2026-08-29 and task 11.64 closes it. **A round whose checks
vanish when it ends has not been run; it has been performed.**

**What these entries are, and what "held" means for them.** Unlike the
authorization instruments beside this one, most of what follows is not "can
this caller reach that row". It is **type confusion and shape confusion**: a
field that is a string where an integer is expected, a container that is a list
where a map is expected, a name that is a SQL fragment, a body with the same
key twice. The property is:

  - **No 500.** Every 500 this server emits is an unhandled exception caught by
    `errorHandlerMiddleware`. A caller who can pick the exception has steered
    the error path, which is finding J-4's class (§12.6) and the reason 10.46
    and 10.64 exist.
  - **A wrongly-typed field never counts as a valid one.** `400
    malformed_envelope` is the designed answer; silently reading a string
    `"0"` as cursor 0 is not.
  - **Nothing crosses a project boundary**, however malformed the request that
    asked. The duplicate-key probe below is exactly this question.
  - **The server is still there afterwards.** Every probe group re-checks
    `/health`, because a negative assertion is satisfied by a dead server.

**Every probe carries a positive control that fires in the same run**, per this
project's standing rule: a server that refused everything would report an
identical clean sweep. Round 8 itself produced three probes that were wrong
before they were right and each was caught by its own control rather than by
inspection (§16.1) — including a refusal matrix whose every case returned the
same exit code.

**Deliberately not widened.** This reproduces round 8's surface, and finding
P-1's questions about `/projects/mine` as a *read* live in
`verify_11_49_server_reads.py` with the other two reads, where they belong.
§6's stopping rule is what ended eight rounds of treadmill.

Usage (with the e2e stack up — see the README's "End-to-end integration
suite"):

    COMPOSE="docker compose -p tritrack-e2e -f docker-compose.yml -f docker-compose.e2e.yml" \
        python3 scripts/verify_round8_server_surface.py

`COMPOSE` defaults to the `tritrack-gate` project `gate_smoke_test.sh` brings
up, matching `verify_c5_denial_audit.py` and `verify_11_49_server_reads.py`.
It is used for one thing only: entry 20's proof that no file was written
outside the link directory, which has to be asked of the container's own
filesystem rather than of the host bind mount.

Exits non-zero if any attack succeeded or any positive control failed.
"""
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import ENVELOPE, preflight  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")
COMPOSE = os.environ.get(
    "COMPOSE",
    "docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml",
).split()

T = "2026-08-01T12:00:00.000Z"
RUN = uuid.uuid4().hex[:8]

#: `maxSyncBatchSize` from `sync_protocol.dart`, read rather than typed — the
#: same premise `gate_wire.py` is built on, one constant further down. A bound
#: this file carried its own copy of would go on passing against a server that
#: had changed it, which is precisely how four instruments spent a day
#: reporting on a server they never reached (task 10.40).
_PROTOCOL_SRC = open(
    os.path.join(ROOT, "packages", "tritrack_sync", "lib", "src",
                 "sync_protocol.dart")
).read()
_match = re.search(r"const\s+int\s+maxSyncBatchSize\s*=\s*(\d+)\s*;",
                   _PROTOCOL_SRC)
if not _match:
    raise SystemExit(
        "Could not find `const int maxSyncBatchSize` in sync_protocol.dart. "
        "Probe 2 measures the batch clamp against that declaration so it "
        "cannot go stale — fix this parser rather than hardcoding a number."
    )
MAX_BATCH = int(_match.group(1))

_HOST = urllib.parse.urlsplit(BASE)


# ---------------------------------------------------------------- wire helpers


def raw(path, body=None, token=None, method="POST", headers=None):
    """Status, headers, and body bytes.

    `body` may be a Python object (encoded as JSON) or **pre-encoded bytes**.
    The bytes form is not a convenience: several probes below send a body
    `json.dumps` cannot produce — the same key twice, two thousand levels of
    nesting — and a probe that could only send well-formed JSON could never
    ask the question those two are for.

    `http.client` rather than `urllib.request` for the same reason
    `verify_11_49_server_reads.py` uses it: `Request.add_header` stores headers
    in a dict, so "send this header twice" silently becomes "send the second
    one".
    """
    if body is None:
        data = None
    elif isinstance(body, (bytes, bytearray)):
        data = bytes(body)
    else:
        data = json.dumps(body).encode()
    conn = http.client.HTTPConnection(_HOST.hostname, _HOST.port or 80, timeout=60)
    try:
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        conn.putheader("Host", _HOST.netloc)
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(len(data or b"")))
        for name, value in (headers or {}).items():
            conn.putheader(name, value)
        if token:
            conn.putheader("Authorization", "Bearer " + token)
        conn.endheaders()
        if data:
            conn.send(data)
        response = conn.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    except (http.client.RemoteDisconnected, ConnectionError):
        # **Status 0 means "the server closed the connection without saying
        # anything".** It is reported rather than swallowed: a probe that
        # mapped a dropped connection to "refused" would score a crashed
        # server as a clean sweep, which is the vacuous pass this whole file
        # exists to avoid. Reached by exactly one attack below — a NUL byte in
        # an `Authorization` header, which the HTTP layer refuses before any
        # route sees it — and the caller there asserts on 0 explicitly.
        return 0, {}, b""
    finally:
        conn.close()


def call(path, body=None, token=None, method="POST", headers=None):
    status, _, payload = raw(path, body, token, method, headers)
    try:
        return status, json.loads(payload or b"{}")
    except json.JSONDecodeError:
        return status, {"raw": payload[:300].decode("utf-8", "replace")}


def container_sh(command):
    """Run `command` inside the *server container* and return its stdout.

    Entry 20's question is whether a caller-named file escaped the link
    directory, and the host bind mount can only show what landed inside it.
    Asked of the container because that is where the write happened — and
    asked with `find`, not with a list of paths somebody guessed, because a
    check that only looks where the attacker was expected to go finds only the
    attacks somebody already thought of.
    """
    result = subprocess.run(
        COMPOSE + ["exec", "-T", "server", "sh", "-c", command],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 1):
        raise SystemExit(
            "ABORT: could not run `%s` in the `server` container through %r "
            "(exit %d): %s\n\nEntry 20's traversal probe cannot be answered "
            "from the host bind mount alone, and reporting it as held without "
            "asking would be exactly the vacuous pass this file exists to "
            "avoid. Set COMPOSE to name the stack you brought up."
            % (command, " ".join(COMPOSE), result.returncode,
               (result.stderr or "").strip())
        )
    return result.stdout


# ------------------------------------------------------------------- reporting

ATTACK_FAILURES = []
CONTROL_FAILURES = []
NOTES = []
RESULTS = {}
_current = {"name": None}


def probe(name):
    _current["name"] = name
    print(f"\n=== {name}")


def _claim(key):
    """Refuse to let two checks share a name.

    `RESULTS` is what `verify_round8_broken_control.py` matches its
    `must_flip` lists against, so two checks with one name means the second
    silently overwrites the first — and a flip that should have failed the
    harness would be invisible. Four names really did collide when this file
    was written (`device_id as an object` on two different routes), which is
    why this is a guard rather than a convention.
    """
    if key in RESULTS:
        raise SystemExit(
            "INSTRUMENT DEFECT: two checks are both named %r. The second "
            "would overwrite the first in this run's machine-readable "
            "summary, and the broken-control harness matches on those names "
            "— so a probe that stopped working would be invisible. Rename "
            "one." % key
        )


def attack(what, refused, detail=""):
    _claim(what)
    RESULTS[what] = "refused" if refused else "ADMITTED"
    print(("  refused " if refused else "  ADMITTED") + f"  {what}"
          + (f"   [{detail}]" if detail else ""))
    if not refused:
        ATTACK_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def control(what, accepted, detail=""):
    """`accepted` must be True: the legitimate twin of the attack worked."""
    _claim("control: " + what)
    RESULTS["control: " + what] = "fired" if accepted else "BLIND"
    print(("  control " if accepted else "  BLIND   ") + f"  {what}"
          + (f"   [{detail}]" if detail else ""))
    if not accepted:
        CONTROL_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def note(text):
    print(f"  note      {text}")
    NOTES.append(f"{_current['name']}: {text}")


def typed(status, body, *, expect=None):
    """A refusal the server meant, rather than one it fell into.

    `status != 500` is the floor: every 500 here is an unhandled exception the
    catch-all middleware turned into an opaque body, and a caller who chooses
    which exception fires has steered the error path. Above that floor, a
    refusal must carry the documented machine-readable code — §4.13's shape —
    and, when `expect` names one, that exact code.
    """
    if status == 500:
        return False
    code = body.get("error")
    if not isinstance(code, str):
        return False
    if expect is not None:
        return code == expect
    return True


def refused_push(status, parsed):
    """Nothing landed, and the caller was told so.

    **Two shapes both count, and conflating them is how this check gets
    written wrongly** — the first draft of this file required a typed
    transport error and scored eleven correct refusals as failures. §16.2's
    own sentence is the rule: "malformed shapes draw `400
    malformed_envelope`; bad rows draw a per-row `invalid` outcome." Both are
    the server answering on purpose.

    What is **not** a refusal is silence: a 200 with an empty `outcomes` map
    tells a caller nothing about rows it believes it sent, and a client that
    treats "no outcome" as "fine" would then drop field data on the floor.
    That is finding H-5's shape (task 10.46) and it is why an empty map fails
    here rather than passing as "well, nothing was inserted".
    """
    if status == 500:
        return False
    outcomes = parsed.get("outcomes") or {}
    if {"inserted", "updated"} & set(outcomes.values()):
        return False
    if typed(status, parsed):
        return True
    return status == 200 and bool(outcomes)


def alive():
    status, _ = call("/health", None, method="GET")
    return status == 200


# ============================================================== the fixture ===

preflight(BASE, LINK_DIR)

print("\nBuilding the fixture over the real auth and publish flows...")


class Person:
    """One signed-in account: session token, server-chosen user id, device."""

    def __init__(self, label):
        self.label = label
        self.email = f"r8-{label}-{RUN}@example.invalid"
        status, _ = call("/auth/magic-link", {"email": self.email})
        assert status == 202, f"magic-link for {label}: {status}"
        path = os.path.join(LINK_DIR, self.email + ".link")
        for _ in range(80):
            if os.path.exists(path):
                break
            time.sleep(0.1)
        else:
            raise SystemExit(f"no magic link for {label} at {path}")
        self.link_token = open(path).read().split("token=")[1].strip()
        self.device = f"dev-{label}-{RUN}"
        status, body = call(
            "/auth/redeem", {"token": self.link_token, "device_id": self.device}
        )
        assert status == 200, f"redeem for {label}: {status} {body}"
        self.token = body["session_token"]
        self.id = body["user_id"]


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


def membership_row(mid, pid, uid, role, actor):
    row = {
        "membership_id": mid,
        "project_id": pid,
        "user_id": uid,
        "join_date": T,
        "end_date": None,
        "role": role,
        **sync_meta(actor),
    }
    row["deleted_at"] = None
    return row


def observation(oid, pid, uid, revision=1, notes=None):
    return {
        "observation_id": oid,
        "project_id": pid,
        "user_id": uid,
        "tag_id": None,
        "timestamp_local": T,
        "timestamp_utc": T,
        "timezone_offset": "+00:00",
        "latitude": 35.19,
        "longitude": -111.65,
        "position_source": "gps_fix",
        "position_accuracy_m": 5.0,
        "elevation": 2100.0,
        "altitude_agl": 0.0,
        "magnetic_bearing": 90.0,
        "true_north_bearing": 90.0,
        "bearing_uncertainty": 5.0,
        "observation_type": "directional",
        "bearing_capture_method": "single_point",
        "bearing_method": "peak",
        "signal_type": "regular_pulse",
        "signal_strength": "strong",
        "bearing_quality": "good",
        "notes": notes,
        **sync_meta(uid, revision),
    }


def push_body(pid, rows, device):
    return {**ENVELOPE, "project_id": pid, "device_id": device, "rows": rows}


def pull_body(pid, device, cursor=0, batch=500):
    return {
        **ENVELOPE,
        "project_id": pid,
        "device_id": device,
        "cursor": cursor,
        "batch_size": batch,
    }


alice = Person("alice")        # owns project P
bob = Person("bob")            # owns project Q, and has no relationship to P

P = str(uuid.uuid4())
Q = str(uuid.uuid4())
OBS_P = str(uuid.uuid4())
SECRET_NOTE = f"den site {RUN}"
SECRET_Q = f"bobs den site {RUN}"

status, body = call("/sync/push", push_body(P, {
    "Users": [user_row(alice)],
    "Projects": [project_row(P, alice.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), P, alice.id, "owner", alice.id)
    ],
    "Observations": [observation(OBS_P, P, alice.id, notes=SECRET_NOTE)],
}, alice.device), alice.token)
assert status == 200 and set(body["outcomes"].values()) == {"inserted"}, body

status, body = call("/sync/push", push_body(Q, {
    "Users": [user_row(bob)],
    "Projects": [project_row(Q, bob.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), Q, bob.id, "owner", bob.id)
    ],
    # A string that exists nowhere else in this run. Several probes below ask
    # "did anything of Bob's cross?" and a search for a marker is the only
    # form of that question that stays true when the response shape changes.
    "Observations": [observation(str(uuid.uuid4()), Q, bob.id,
                                 notes=SECRET_Q)],
}, bob.device), bob.token)
assert status == 200 and set(body["outcomes"].values()) == {"inserted"}, body

print(f"  alice owns {P[:8]}…, bob owns {Q[:8]}…, and neither is on the other's")


# ================================================================== probe 1 ===
# Entry 14. The pull cursor is an integer the caller chooses and the server
# binds into `WHERE server_seq > $n`. Everything a caller can put there that is
# not an integer, plus the integers at and past the edges of a 64-bit column.

probe("1. Entry 14 — the /sync/pull cursor, every type it is not")

status, body = call("/sync/pull", pull_body(P, alice.device), alice.token)
control("an honest cursor pulls the project",
        status == 200 and any(
            r.get("observation_id") == OBS_P
            for r in (body.get("rows") or {}).get("Observations", [])
        ),
        "HTTP %s" % status)

# Wrong JSON *type*. Each must draw the designed refusal rather than being
# coerced: reading the string "0" as the integer 0 would mean the wire type of
# a cursor is whatever the parser felt like today. `null` is deliberately NOT
# in this list — see below.
for label, value in [
    ("a string", "0"),
    ("a numeric string", "17"),
    ("a float", 1.5),
    ("a list", [0]),
    ("an object", {"cursor": 0}),
    ("a bool", True),
]:
    body = pull_body(P, alice.device)
    body["cursor"] = value
    status, parsed = call("/sync/pull", body, alice.token)
    attack("cursor as %s" % label,
           typed(status, parsed, expect="malformed_envelope"),
           "HTTP %s %s" % (status, parsed.get("error")))

# `null` is the one value that is designed to mean "absent", and
# `optionalSyncInt`'s own doc comment says so: absent means the caller said
# nothing, which a default answers correctly, while present-but-wrong-typed is
# the J-4 shape above. **The attack is therefore not "is null refused" but "can
# null mean a different position than absent"** — if it could, a client and a
# server would disagree about where a device is in the stream, which is silent
# row loss rather than a disclosure. Compared against the omitted-field
# response rather than against a status code.
omitted = pull_body(P, alice.device)
del omitted["cursor"]
_, _, omitted_bytes = raw("/sync/pull", omitted, alice.token)
explicit = pull_body(P, alice.device)
explicit["cursor"] = None
_, _, null_bytes = raw("/sync/pull", explicit, alice.token)
attack("cursor null meaning a different position than an absent cursor",
       omitted_bytes == null_bytes,
       "%d vs %d bytes" % (len(omitted_bytes), len(null_bytes)))
control("that comparison can see a difference at all",
        omitted_bytes != raw(
            "/sync/pull", dict(pull_body(P, alice.device), cursor=10 ** 9),
            alice.token)[2],
        "a far-future cursor answers differently, so byte-equality above is "
        "not vacuous")

# Integers that are integers, and are absurd. A negative cursor and one past
# `bigint` cannot be answered with rows; what they must not do is reach
# Postgres as a bound parameter it rejects mid-statement, which is a raw driver
# error and a 500 from outside (finding J-4's class).
for label, value in [
    ("negative", -1),
    ("a large negative", -(2 ** 62)),
    ("2^63 - 1, the top of bigint", 2 ** 63 - 1),
    ("2^63, one past bigint", 2 ** 63),
    ("2^70", 2 ** 70),
]:
    body = pull_body(P, alice.device)
    body["cursor"] = value
    status, parsed = call("/sync/pull", body, alice.token)
    attack("cursor %s" % label,
           status != 500 and (status == 200 or typed(status, parsed)),
           "HTTP %s %s" % (status, parsed.get("error", "ok")))

control("the server is still answering after the cursor sweep", alive())


# ================================================================== probe 2 ===
# Entry 14. `batch_size` decides how much work one request costs the server,
# which makes it the only envelope field whose *valid* values still need a
# ceiling. Zero and a billion are the two ends of that, and the contract is a
# clamp rather than a refusal — so what is measured is that the clamp holds,
# not that the value is rejected.

probe("2. Entry 14 — /sync/pull batch_size, every type and both edges")

for label, value in [
    ("a string", "10"),
    ("a float", 2.5),
    ("a list", [10]),
    ("an object", {"n": 10}),
    ("a bool", False),
]:
    body = pull_body(P, alice.device)
    body["batch_size"] = value
    status, parsed = call("/sync/pull", body, alice.token)
    attack("batch_size as %s" % label,
           typed(status, parsed, expect="malformed_envelope"),
           "HTTP %s %s" % (status, parsed.get("error")))

omitted = pull_body(P, alice.device)
del omitted["batch_size"]
_, _, omitted_bytes = raw("/sync/pull", omitted, alice.token)
explicit = pull_body(P, alice.device)
explicit["batch_size"] = None
_, _, null_bytes = raw("/sync/pull", explicit, alice.token)
attack("batch_size null meaning a different page than an absent batch_size",
       omitted_bytes == null_bytes,
       "%d vs %d bytes" % (len(omitted_bytes), len(null_bytes)))

for label, value in [("zero", 0), ("negative", -1), ("a billion", 10 ** 9),
                     ("2^63 - 1", 2 ** 63 - 1)]:
    body = pull_body(P, alice.device)
    body["batch_size"] = value
    status, parsed = call("/sync/pull", body, alice.token)
    rows = sum(len(v) for v in (parsed.get("rows") or {}).values())
    # The clamp is `1..maxSyncBatchSize`. A zero or negative request must still
    # make progress (a page of zero rows with `remaining` set is a livelock the
    # client cannot escape), and an enormous one must not hand back an
    # unbounded page.
    attack("batch_size %s" % label,
           status == 200 and 1 <= rows <= MAX_BATCH,
           "HTTP %s, %s rows, clamp is 1..%s" % (status, rows, MAX_BATCH))

control("the server is still answering after the batch_size sweep", alive())


# ================================================================== probe 3 ===
# Entry 14. `rows` is a map of table name to a list of row objects, and every
# one of those three containers is a place a caller can put something else.
# Task 10.46 (F10, H-4/H-5) and 10.64 are the findings this reproduces: an
# untyped 500, and a table the server silently dropped.

probe("3. Entry 14 — the row container, confused at all three levels")

status, parsed = call("/sync/push", push_body(P, {
    "Observations": [observation(str(uuid.uuid4()), P, alice.id)],
}, alice.device), alice.token)
control("an honest push still inserts",
        status == 200 and set(parsed.get("outcomes", {}).values()) == {"inserted"},
        "HTTP %s" % status)

for label, rows in [
    ("rows as a list", [{"Observations": []}]),
    ("rows as a string", "Observations"),
    ("rows as a number", 42),
    ("rows as null", None),
    ("a table whose value is a string", {"Observations": "obs"}),
    ("a table whose value is an object", {"Observations": {"0": {}}}),
    ("a table whose value is a number", {"Observations": 1}),
    ("a row that is a string", {"Observations": ["obs-1"]}),
    ("a row that is null", {"Observations": [None]}),
    ("a row that is a list", {"Observations": [[]]}),
    ("a row that is a number", {"Observations": [7]}),
    ("a row that is an empty object", {"Observations": [{}]}),
]:
    status, parsed = call(
        "/sync/push", push_body(P, rows, alice.device), alice.token
    )
    outcomes = (parsed.get("outcomes") or {})
    attack(label, refused_push(status, parsed),
           "HTTP %s %s" % (status,
                           parsed.get("error", sorted(set(outcomes.values())))))

control("the server is still answering after the container sweep", alive())


# ================================================================== probe 4 ===
# Entry 14. A table name is caller-supplied text that selects a code path and
# reaches a quoted identifier. The unknown-table case is the one with a
# *positive* requirement attached: task 10.46's finding H-5 was that an unknown
# table vanished silently, so "refused" here means the caller was told, not
# that the response went quiet.

probe("4. Entry 14 — table names the caller invents")

for label, table in [
    ("an unknown table", "Nope"),
    ("the right table, lowercased", "observations"),
    ("the empty string", ""),
    ("a SQL fragment", 'Observations"; DROP TABLE auth_sessions --'),
    ("a 5000-character name", "T" * 5000),
    ("a name carrying a NUL byte", "Obser" + chr(0) + "vations"),
    ("__proto__", "__proto__"),
    ("a name that is a bare number", "1"),
    ("an auth table this wire has never carried", "auth_sessions"),
]:
    rows = {table: [observation(str(uuid.uuid4()), P, alice.id)]}
    status, parsed = call(
        "/sync/push", push_body(P, rows, alice.device), alice.token
    )
    attack("%s in `rows`" % label, refused_push(status, parsed),
           "HTTP %s %s" % (status, parsed.get(
               "error", sorted(set((parsed.get("outcomes") or {}).values())))))

# The SQL fragment above proves nothing on its own — a server that refused
# every table name would score identically. This is the discriminator: the
# table the fragment was trying to reach is still there afterwards.
status, parsed = call("/auth/sessions", None, alice.token, method="GET")
control("auth_sessions still exists after the injection attempts",
        status == 200 and isinstance(parsed.get("sessions"), list),
        "HTTP %s" % status)

status, parsed = call("/sync/push", push_body(P, {
    "Nope": [{"observation_id": "x", "project_id": P}],
    "Observations": [observation(str(uuid.uuid4()), P, alice.id)],
}, alice.device), alice.token)
outcomes = parsed.get("outcomes") or {}
control("an unknown table alongside a good one does not swallow the good one",
        status == 200 and "inserted" in outcomes.values(),
        "HTTP %s %s" % (status, sorted(set(outcomes.values()))))
control("and the unknown one is named in the answer rather than dropped",
        any(not k.startswith("Observations/") for k in outcomes),
        sorted(outcomes))
control("the server is still answering after the table-name sweep", alive())


# ================================================================== probe 5 ===
# Entry 14. The four envelope fields every sync request carries. Two of them —
# `project_id` and `device_id` — are read *before* authentication for the
# traffic log (`sync_routes.dart`'s `_asString`), which is what made finding
# F10 reachable by an unauthenticated caller, and they are bounded there for
# the same reason.

probe("5. Entry 14 — the envelope's own fields")

for field, label, value in [
    ("project_id", "a number", 42),
    ("project_id", "a list", [P]),
    ("project_id", "an object", {"id": P}),
    ("project_id", "null", None),
    ("project_id", "the empty string", ""),
    ("project_id", "5000 characters", "p" * 5000),
    ("project_id", "a NUL byte", P[:8] + chr(0) + P[8:]),
    ("device_id", "an object", {"d": "x"}),
    ("device_id", "a number", 7),
    ("device_id", "the empty string", ""),
    ("device_id", "5000 characters", "d" * 5000),
    ("device_id", "a NUL byte", "dev" + chr(0) + "ice"),
    ("schema_major", "a string", "2"),
    ("schema_version", "a string", "9"),
    ("protocol_version", "a list", [1]),
    ("envelope", "the wrong name", "not_tritrack_sync"),
]:
    body = pull_body(P, alice.device)
    body[field] = value
    status, parsed = call("/sync/pull", body, alice.token)
    # Any typed refusal is correct here; which one differs by field, and
    # pinning each to a specific code would be asserting the implementation
    # rather than the property. What must never happen is a 500, a 200 that
    # answers for a project this caller cannot reach, or a 200 that answers
    # *at all* for a project id the caller did not name.
    leaked = status == 200 and SECRET_Q in json.dumps(parsed)
    attack("%s as %s" % (field, label),
           typed(status, parsed) and not leaked,
           "HTTP %s %s" % (status, parsed.get("error")))

for field in ("project_id", "device_id", "envelope", "schema_major",
              "protocol_version"):
    body = pull_body(P, alice.device)
    del body[field]
    status, parsed = call("/sync/pull", body, alice.token)
    attack("%s missing altogether" % field, typed(status, parsed),
           "HTTP %s %s" % (status, parsed.get("error")))

control("a complete envelope still works after the field sweep",
        call("/sync/pull", pull_body(P, alice.device), alice.token)[0] == 200)
control("the server is still answering after the envelope sweep", alive())


# ================================================================== probe 6 ===
# Entry 14. Shapes JSON permits and a serializer does not produce: the same key
# twice, two thousand levels of nesting, five thousand columns nobody declared,
# and a body past the transport bound. `json.dumps` cannot make the first two,
# which is why `raw` accepts pre-encoded bytes.

probe("6. Entry 14 — bodies a serializer would never emit")

# The duplicate key names a project this caller has no relationship to. Which
# one a parser keeps is an implementation detail; that neither ordering hands
# back Bob's project is the property.
for label, first, second in [
    ("mine first, then a project I am not on", P, Q),
    ("a project I am not on first, then mine", Q, P),
]:
    envelope = dict(ENVELOPE)
    body = (
        '{'
        + ','.join('"%s":%s' % (k, json.dumps(v)) for k, v in envelope.items())
        + ',"device_id":%s' % json.dumps(alice.device)
        + ',"cursor":0,"batch_size":500'
        + ',"project_id":%s' % json.dumps(first)
        + ',"project_id":%s' % json.dumps(second)
        + '}'
    ).encode()
    status, _, payload = raw("/sync/pull", body, alice.token)
    text = payload.decode("utf-8", "replace")
    attack("duplicate project_id keys — %s" % label,
           status != 500 and SECRET_Q not in text,
           "HTTP %s" % status)

# Built as text, not as an object: Python's own JSON encoder blows its
# recursion limit at this depth, which is a fact about the *instrument* and
# would otherwise have been reported as a fact about the server. The first
# draft of this probe crashed here rather than measuring anything — the same
# class as round 8's refusal matrix whose every case returned the same exit
# code because the runtime image had no Dart SDK (§16.1).
DEPTH = 2000
row = observation(str(uuid.uuid4()), P, alice.id)
deep_body = (
    '{'
    + ','.join('"%s":%s' % (k, json.dumps(v)) for k, v in ENVELOPE.items())
    + ',"project_id":%s' % json.dumps(P)
    + ',"device_id":%s' % json.dumps(alice.device)
    + ',"rows":{"Observations":[{'
    + ','.join('"%s":%s' % (k, json.dumps(v)) for k, v in row.items())
    + ',"deeply_nested":'
    + '{"a":' * DEPTH + 'null' + '}' * DEPTH
    + '}]}}'
).encode()
status, _, payload = raw("/sync/push", deep_body, alice.token)
try:
    parsed = json.loads(payload or b"{}")
except json.JSONDecodeError:
    parsed = {"raw": payload[:200].decode("utf-8", "replace")}
# Held or refused are both acceptable answers — an undeclared column is what
# `UnknownColumnStore` exists for, and this one happens to be two thousand
# maps deep. What is not acceptable is the parser going down and taking the
# process with it, which is why the assertion is "not a 500" and the check
# that means anything is the one on the next line.
attack("a row carrying 2000 levels of nesting", status != 500,
       "HTTP %s %s" % (status, parsed.get("error", "ok")))
control("/health survives the deep-nesting push", alive())

row = observation(str(uuid.uuid4()), P, alice.id)
for i in range(5000):
    row["unknown_%d" % i] = "x"
status, parsed = call(
    "/sync/push", push_body(P, {"Observations": [row]}, alice.device),
    alice.token,
)
attack("a row carrying 5000 columns nobody declared",
       status != 500,
       "HTTP %s %s" % (status, parsed.get("error", "ok")))

status, parsed = call("/sync/push", push_body(P, {
    "Observations": [observation(str(uuid.uuid4()), P, alice.id,
                                 notes="n" * (9 * 1024 * 1024))],
}, alice.device), alice.token)
attack("a body past the 8 MiB transport bound",
       status != 500 and status != 200,
       "HTTP %s %s" % (status, parsed.get("error")))

envelope_with_proto = dict(pull_body(P, alice.device))
envelope_with_proto["__proto__"] = {"cursor": 10 ** 9}
status, parsed = call("/sync/pull", envelope_with_proto, alice.token)
attack("a __proto__ key in the envelope",
       status == 200 and SECRET_Q not in json.dumps(parsed),
       "HTTP %s" % status)

control("the server is still answering after the malformed-body sweep", alive())


# ================================================================== probe 7 ===
# Entry 14. `/sync/ack` moves the server's record of where a device is, which
# makes its cursor the one caller-supplied integer that can cause **silent row
# loss** rather than a refusal: a device acknowledged past rows it never
# received would never be sent them again. Registered as M-13 (§16.3).

probe("7. Entry 14 — the /sync/ack cursor")


def ack(value, device=None):
    body = {**ENVELOPE, "project_id": P,
            "device_id": device or alice.device, "cursor": value}
    return call("/sync/ack", body, alice.token)


status, parsed = ack(0)
control("an honest ack is accepted", status == 200, "HTTP %s" % status)

for label, value in [
    ("a string", "5"),
    ("a float", 1.5),
    ("a list", [5]),
    ("an object", {"cursor": 5}),
    ("a bool", True),
    ("2^63, one past bigint", 2 ** 63),
]:
    status, parsed = ack(value)
    attack("ack cursor as %s" % label, typed(status, parsed),
           "HTTP %s %s" % (status, parsed.get("error")))

status, parsed = ack(-1)
attack("ack cursor negative", status != 500 and (status == 200
       or typed(status, parsed)), "HTTP %s %s" % (status, parsed.get("error")))

status, parsed = ack(0, device="dev" + chr(0) + "ice")
attack("ack for a device_id carrying a NUL byte", typed(status, parsed),
       "HTTP %s %s" % (status, parsed.get("error")))

# The row Alice pushed is still hers to pull after all of that. An ack sweep
# that had quietly advanced her cursor would show up here and nowhere else.
status, parsed = call("/sync/pull", pull_body(P, alice.device), alice.token)
control("the project still pulls from cursor 0 after the ack sweep",
        status == 200 and any(
            r.get("observation_id") == OBS_P
            for r in (parsed.get("rows") or {}).get("Observations", [])
        ),
        "HTTP %s" % status)
control("the server is still answering after the ack sweep", alive())


# ================================================================== probe 8 ===
# Entry 15. `POST /auth/magic-link` is unauthenticated and takes exactly one
# caller-supplied field. Everything that field is not, plus the two shapes that
# are security controls rather than shape checks: a control character (SMTP
# header injection the day a real sender lands) and a body past the 2 KiB
# bound.

probe("8. Entry 15 — /auth/magic-link, the one field it takes")

fresh = "r8-control-%s@example.invalid" % RUN
status, parsed = call("/auth/magic-link", {"email": fresh})
control("an honest address is accepted", status == 202, "HTTP %s" % status)

for label, value in [
    ("a list", ["a@b.invalid"]),
    ("an object", {"email": "a@b.invalid"}),
    ("a number", 42),
    ("a bool", True),
    ("null", None),
    ("the empty string", ""),
    ("no @ at all", "nobody"),
    ("@ at the start", "@example.invalid"),
    ("@ at the end", "nobody@"),
    ("a space inside", "no body@example.invalid"),
    # **No space in these two, deliberately.** As first written they read
    # `Bcc: attacker@...` with a space, and the boundary of the day
    # (`_looksLikeEmail`) refused any address containing a space *before* it
    # ever consulted its control-character regex — so both probes scored a
    # refusal that had nothing to do with the control they name. Caught by
    # `verify_round8_broken_control.py`: with the control-character rule
    # deleted they went on reporting "refused". A probe that passes for the
    # wrong reason is §4.24's finding, and this is the instrument's own copy
    # of it. (Since task 11.298 the boundary is `isAcceptableSignInAddress`,
    # one rule shared with the SMTP sender, and a space is refused by that
    # same rule — the probes still carry no space for the same reason.)
    ("a newline", "a@b.invalid\nBcc:attacker@example.org"),
    ("a CRLF", "a@b.invalid\r\nBcc:attacker@example.org"),
    ("a NUL byte", "a" + chr(0) + "@example.invalid"),
    ("a comma-separated recipient list", "a@b.invalid,attacker@example.org"),
    ("a semicolon-separated recipient list", "a@b.invalid;attacker@evil.org"),
    ("321 characters, one past the RFC 5321 bound", "a" * 311 + "@b.invalid"),
    ("100 KiB", "a" * (100 * 1024) + "@b.invalid"),
]:
    status, parsed = call("/auth/magic-link", {"email": value})
    attack("email as %s" % label, typed(status, parsed),
           "HTTP %s %s" % (status, parsed.get("error")))

status, parsed = call("/auth/magic-link", {})
attack("email missing altogether", typed(status, parsed),
       "HTTP %s %s" % (status, parsed.get("error")))
status, _, payload = raw("/auth/magic-link", b"not json at all")
attack("a body that is not JSON", status == 400, "HTTP %s" % status)
status, _, payload = raw("/auth/magic-link", b'["a@b.invalid"]')
attack("a body that is a JSON array", status == 400, "HTTP %s" % status)

control("the server is still answering after the address sweep", alive())


# ================================================================== probe 9 ===
# Entry 15. `POST /auth/redeem` takes a single-use token and a device id. The
# device id is the interesting half: it reaches `auth_sessions.device_id` as
# raw, unhashed caller input, which is the sink finding J-4 was found on.

probe("9. Entry 15 — /auth/redeem, both of its fields")

for label, value in [
    ("a list", ["t"]),
    ("an object", {"token": "t"}),
    ("a number", 1),
    ("null", None),
    ("the empty string", ""),
    ("a NUL byte", "tok" + chr(0) + "en"),
    ("1 KiB of rubbish", "t" * 1024),
]:
    status, parsed = call(
        "/auth/redeem", {"token": value, "device_id": "probe-device"}
    )
    attack("redeem token as %s" % label,
           typed(status, parsed) and status != 200,
           "HTTP %s %s" % (status, parsed.get("error")))

for label, value in [
    ("an object", {"d": "x"}),
    ("a number", 7),
    ("null", None),
    ("the empty string", ""),
    ("a NUL byte", "dev" + chr(0) + "ice"),
    ("1 KiB", "d" * 1024),
]:
    status, parsed = call(
        "/auth/redeem", {"token": "irrelevant", "device_id": value}
    )
    attack("redeem device_id as %s" % label,
           typed(status, parsed) and status != 200,
           "HTTP %s %s" % (status, parsed.get("error")))

# The control has to be a redemption that *works*, or every refusal above is
# equally explained by "this route refuses everything".
path = os.path.join(LINK_DIR, fresh + ".link")
for _ in range(80):
    if os.path.exists(path):
        break
    time.sleep(0.1)
link = open(path).read().split("token=")[1].strip()
status, parsed = call(
    "/auth/redeem", {"token": link, "device_id": "r8-control-device-" + RUN}
)
control("a real link still redeems into a session",
        status == 200 and isinstance(parsed.get("session_token"), str),
        "HTTP %s" % status)
control("the server is still answering after the redemption sweep", alive())


# ================================================================= probe 10 ===
# Entry 15. `GET /projects/mine` as a *route*: who may reach it at all. What a
# row of it may carry — the read's question, finding P-1 — is asked in
# `verify_11_49_server_reads.py` with the server's other two reads, where it
# belongs.

probe("10. Entry 15 — /projects/mine, who may reach it")

status, _, _ = raw("/projects/mine", None, None, method="GET")
attack("no bearer at all", status == 401, "HTTP %s" % status)
for label, header in [
    ("a garbage bearer", "Bearer not-a-token"),
    ("an empty bearer", "Bearer "),
    ("the scheme alone", "Bearer"),
    ("Basic auth", "Basic YWxpY2U6cHc="),
    ("another user's device id as a token", "Bearer " + bob.device),
    ("a session token with one character changed", "Bearer "
     + ("x" if bob.token[0] != "x" else "y") + bob.token[1:]),
]:
    status, _, _ = raw("/projects/mine", None, None, method="GET",
                       headers={"Authorization": header})
    attack(label, status == 401, "HTTP %s" % status)

# The NUL byte is its own case because it is refused a layer below the route:
# the HTTP parser will not accept the header at all, so the connection closes
# with no response. Both answers are refusals; a 200 is the only failure, and
# scoring it that way keeps the instrument honest about which layer held.
status, _, _ = raw("/projects/mine", None, None, method="GET",
                   headers={"Authorization": "Bearer tok" + chr(0) + "en"})
attack("a token carrying a NUL byte",
       status in (0, 400, 401),
       "HTTP %s%s" % (status, " (connection closed, no response)"
                      if status == 0 else ""))

status, parsed = call("/projects/mine", None, bob.token, method="GET")
listed = {p.get("project_id") for p in (parsed.get("projects") or [])}
attack("a real session listing a project it is not on",
       status == 200 and P not in listed,
       "HTTP %s, %s" % (status, sorted(x[:8] for x in listed)))
control("and that same session does list its own project",
        status == 200 and Q in listed,
        sorted(x[:8] for x in listed))
control("the server is still answering after the bearer sweep", alive())


# ================================================================= probe 11 ===
# Entry 20. The dev magic-link sender is the server's **only subprocess call**
# and the only place an unauthenticated body names a file on disk: the address
# becomes a filename. Accepted in the register as M-9 (§15.3) on three bounds —
# refused under `TRITRACK_ENV=production`, no path separator survives the
# sanitiser, and the subprocess takes an argument list rather than a shell
# string. The second is the one a live run can falsify, and this is it.

probe("11. Entry 20 — traversal addresses through the dev sender")

CONTAINER_LINK_DIR = "/e2e_magic_links"


def sanitised(email):
    """`FileEmailSender`'s own rule: anything outside [A-Za-z0-9._@-] becomes
    an underscore. Mirrored here so the expected filename is derived from the
    stated rule rather than from whatever the run happened to produce."""
    return "".join(
        c if (c.isascii() and (c.isalnum() or c in "._@-")) else "_"
        for c in email
    ) + ".link"


# **Task 11.71 — why one of these addresses is discovered rather than typed.**
# For two rounds the escape check below could not fail. The broken-control
# harness proved it: with the sanitiser deleted it stayed `refused`. It was not
# looking in the wrong place — it was looking for a file that this attack
# corpus could never produce. Of round 8's five addresses, on a Linux
# container:
#
#   - `..%2f..%2f…` and `..\..\…` never leave the directory at all. Nothing
#     URL-decodes the JSON body, and a backslash is an ordinary character in a
#     filename here, so both land *inside* the link directory whatever the
#     sanitiser does.
#   - `a/b/c-…` and `....//....//…` name subdirectories that do not exist, and
#     `FileEmailSender` creates the link directory itself (`createSync`) and
#     not the file's parents — so both fail `ENOENT`.
#   - `../../../../etc/…` is the only one that names an existing directory
#     outside, and the server cannot write to `/etc`: it runs as an
#     unprivileged user (`docker-compose.e2e.yml`'s `user:` line, task 11.69).
#     **That refusal comes from the filesystem, not from the sanitiser.**
#
# So the probe's apparent breadth was one address wide, and that address was
# being stopped by something other than the control it was written to measure.
# The sanitiser is still load-bearing — measured, not assumed: as the same
# unprivileged user this container writes freely into `/tmp` and `/var/tmp`,
# and under the `0:0` fallback anyone using the raw compose line gets `/etc`
# back. What was missing was an address aimed somewhere the write can actually
# land.
#
# It is **discovered from the container rather than typed here**, by trying the
# write, because "can this process create a file there" is the property and a
# permission bit is only a description of it. The device check is not
# decoration: the escape search below is `find / -xdev`, so a target on another
# filesystem would be an escape the search steps over — which is the same
# blindness one layer along.
def _escape_targets():
    """Directories outside the link directory that this server can write to
    *and* that the escape search can see. Empty is a control failure, not a
    pass."""
    probe_name = ".tt-escape-target-probe-%s" % RUN
    script = (
        'root_dev=$(stat -c %d /); '
        'for d in /tmp /var/tmp /dev/shm /var/log /home /etc /app /srv /opt; '
        'do '
        '  [ -d "$d" ] || continue; '
        '  case "$d" in {link}|{link}/*) continue;; esac; '
        '  [ "$(stat -c %d "$d")" = "$root_dev" ] || continue; '
        '  if (echo probe > "$d/{probe}") 2>/dev/null; then '
        '    rm -f "$d/{probe}"; echo "$d"; '
        '  fi; '
        'done'
    ).format(link=CONTAINER_LINK_DIR, probe=probe_name)
    return [line for line in container_sh(script).split() if line]


ESCAPE_TARGETS = _escape_targets()
control("the container has somewhere outside the link directory this server "
        "can write to, so the escape search below can fail at all",
        bool(ESCAPE_TARGETS),
        ", ".join(ESCAPE_TARGETS) or "none found — the escape check cannot "
        "fail on this host and this run measured nothing about it")


# **Every address carries this run's id, and the expected file is removed
# before the request.** As first written the first address was a constant, so
# a file left by an earlier run satisfied `os.path.exists` and the probe
# reported "refused" against a server whose sanitiser had been deleted —
# found by `verify_round8_broken_control.py`, which ran two variants in a row
# against the same link directory. Stale state making a check pass is task
# 10.90's finding, and this is it, inside the check written to close a
# different one.
traversals = [
    ("four levels up to /etc/passwd",
     "../../../../etc/passwd-" + RUN + "@example.invalid"),
    ("percent-encoded separators",
     "..%2f..%2fescaped-" + RUN + "@example.invalid"),
    ("a bare separator mid-address", "a/b/c-%s@example.invalid" % RUN),
    ("doubled dots and slashes", "....//....//x-%s@example.invalid" % RUN),
    ("a backslash separator", "..\\\\..\\\\windows-%s@example.invalid" % RUN),
]

# Task 11.71. The address that makes the escape search able to go red: four
# levels up into a directory this container just proved it can write to. Its
# label deliberately does not name the directory: the broken-control harness
# matches attacks by name, and a name that moved with the host would be a
# required flip that quietly stopped being required.
if ESCAPE_TARGETS:
    traversals.append(
        ("four levels up into a writable directory outside the link "
         "directory",
         "../../../..%s/escape-%s@example.invalid"
         % (ESCAPE_TARGETS[0], RUN)))

for label, email in traversals:
    stale = os.path.join(LINK_DIR, sanitised(email))
    if os.path.exists(stale):
        os.remove(stale)
    status, parsed = call("/auth/magic-link", {"email": email})
    if status != 202:
        attack("%s — %s" % (label, "refused before the sender"),
               typed(status, parsed), "HTTP %s %s" % (status,
                                                      parsed.get("error")))
        continue
    expected = sanitised(email)
    host_path = os.path.join(LINK_DIR, expected)
    for _ in range(80):
        if os.path.exists(host_path):
            break
        time.sleep(0.1)
    inside = os.path.realpath(host_path).startswith(
        os.path.realpath(LINK_DIR) + os.sep
    )
    attack("%s" % label,
           os.path.exists(host_path) and "/" not in expected and inside,
           "wrote %r" % expected)

# The comprehensive half, and the reason this probe is worth committing rather
# than re-deriving: not "is the file I predicted absent from the place I
# predicted" but "is there a `.link` file anywhere on this container's
# filesystem outside the directory it was told to use".
ESCAPE_SEARCH = ("find / -xdev -name '*.link' -not -path '%s/*' 2>/dev/null"
                 % CONTAINER_LINK_DIR)

# Task 11.71, and this is the control the check went two rounds without. The
# one below it proves `find` can see files *inside* the directory, which is a
# different search: it is not `-xdev`, it does not cross the bind mount, and it
# would keep firing on a host where the search above could never return
# anything. So plant a `.link` where an escape would land and require **this**
# search to report it, then take it away again. Planted through the container
# rather than through the sender, because a control that depends on the control
# being measured is not a control.
if ESCAPE_TARGETS:
    planted = "%s/.tt-planted-escape-%s.link" % (ESCAPE_TARGETS[0], RUN)
    container_sh("echo planted > %s" % planted)
    seen = container_sh(ESCAPE_SEARCH)
    container_sh("rm -f %s" % planted)
    control("the escape search sees a .link file planted outside the "
            "directory", planted in seen.split(), planted)

escaped = container_sh(ESCAPE_SEARCH).strip()
attack("any .link file anywhere outside the link directory",
       escaped == "",
       escaped.replace("\n", ", ") if escaped else "none, across the whole "
       "container filesystem")
if escaped:
    # Which run wrote it matters to whoever reads the red. A container is
    # per-run in CI, but a developer's gate stack outlives many runs, and
    # "escaped now" and "escaped last Tuesday" call for different next steps.
    mine = [f for f in escaped.split("\n") if RUN in f]
    note("of the escaped files, %d carry this run's id and %d predate it"
         % (len(mine), len(escaped.split("\n")) - len(mine)))

# ...and the control that keeps the line above from passing because `find`
# is broken, the sender never ran, or the directory is empty.
found = container_sh(
    "find %s -name '*.link' 2>/dev/null | wc -l" % CONTAINER_LINK_DIR
).strip()
control("that same find does see the links inside the directory",
        found.isdigit() and int(found) >= len(traversals),
        "%s link files present" % found)

modes = container_sh(
    "find %s -name '*.link' -exec stat -c '%%a' {} + 2>/dev/null | sort -u"
    % CONTAINER_LINK_DIR
).split()
control("every written link is owner-only (chmod 600)",
        modes == ["600"],
        "modes seen: %s" % (", ".join(modes) or "none"))
control("the server is still answering after the traversal sweep", alive())


# ==================================================================== verdict

print("\n" + "=" * 72)
print("Round-8 server surface — entries 14, 15 and 20")
print("%d checks: %d attacks, %d positive controls."
      % (len(RESULTS),
         sum(1 for k in RESULTS if not k.startswith("control: ")),
         sum(1 for k in RESULTS if k.startswith("control: "))))
if CONTROL_FAILURES:
    print("POSITIVE CONTROLS FAILED — this run measured nothing:")
    for f in CONTROL_FAILURES:
        print("  ! " + f)
if ATTACK_FAILURES:
    print("ATTACKS THAT SUCCEEDED:")
    for f in ATTACK_FAILURES:
        print("  ! " + f)
if not (CONTROL_FAILURES or ATTACK_FAILURES):
    print("Every attack refused; every positive control fired.")
print("=" * 72)

summary_path = os.environ.get("VERIFY_ROUND8_JSON")
if summary_path:
    with open(summary_path, "w") as f:
        json.dump({
            "results": RESULTS,
            "admitted": sorted(k for k, v in RESULTS.items() if v == "ADMITTED"),
            "blind": sorted(k for k, v in RESULTS.items() if v == "BLIND"),
            "attack_failures": ATTACK_FAILURES,
            "control_failures": CONTROL_FAILURES,
            "notes": NOTES,
        }, f, indent=2)
    print("summary written to %s" % summary_path)

# A dead server satisfies every negative assertion, so prove it is still there.
if not alive():
    print("INCONCLUSIVE: /health did not answer 200 at the end of the run.")
    sys.exit(1)

sys.exit(1 if (CONTROL_FAILURES or ATTACK_FAILURES) else 0)

#!/usr/bin/env python3
# gate-instrument: verify_11_49_server_reads
"""Task 11.49 — live adversarial pass over the server's two **reads**.

`SECURITY_SCOPE_AND_EXIT.md` §3 items **27 and 28**, both added to that
inventory *before* they were attacked, and both carrying an `Open` verdict
because no live attack had ever been run against either:

  27 — `GET /auth/sessions`, the caller's own signed-in devices (task 11.35,
       given a caller by task 11.36)
  28 — `POST /sync/pull` answering a caller whose stint on the project has
       ended: the closed-membership disclosure exemption (task 11.60, §4.27)

**Why a separate instrument rather than more probes in
`verify_11_9_team_surface.py`.** Every attack the server inventory records was
aimed at a *mutation* — can this caller write a row they should not. A read
fails differently: it corrupts nothing, it *tells somebody something*. So every
probe below is disclosure-shaped. It asks what crossed and to whom, not what
landed.

Everything here speaks raw HTTP against a live stack. Nine gates found that this
class of finding is invisible to in-process tests, and §6's exit criteria
require a **failed live attack** per inventory entry rather than a passing unit
test. `server/test/security/auth_route_security_test.dart` already asserts
entry 27's shape against a *fake* `AuthService`; that is a different claim from
"the deployed server refuses this".

**Every probe carries a positive control that fires in the same run**, per this
project's standing rule: a probe whose attack is refused proves nothing on its
own, because a server that refused everything would report an identical clean
sweep. Several probes additionally carry a **discriminator control** — proof
that the comparison used to decide "refused" can tell two different answers
apart. A byte-comparison that would report "identical" for any two responses is
not a check.

**Watched to fail.** Task 10.66's standing criterion. `scripts/
verify_11_49_broken_control.sh` builds two deliberately broken servers, runs
this file against each, and requires the named probes below to flip to
ADMITTED. Set `VERIFY_1149_JSON=<path>` to have this run write the machine-
readable summary that harness reads.

**Fixture depth is seeded through `psql`; every attack goes through the front
door.** Two probes need a state the front door cannot reach inside one day —
101 signed-in devices for one person (the per-email magic-link limit is 3 per
15 minutes, 10 per day) and a session that has already expired. Those rows are
inserted server-side and are *fixture*, not a claim that a caller can make
them. Nothing an `attack()` line measures is set up that way.

**It leaves rows behind, deliberately.** Each run creates about nine accounts
and seeds roughly 160 session rows, and it does not clean up: `gate_smoke_test.sh`
brings its stack down with `-v` before every run, so the gate always starts from
an empty database, and a run that deleted its own evidence would be a run
nobody could inspect afterwards. Against a long-lived development stack the rows
simply accumulate; `docker compose ... down -v` clears them.

Usage (with the e2e stack up — see the README's "End-to-end integration
suite"):

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -p tritrack-e2e -f docker-compose.yml -f docker-compose.e2e.yml \
        up --build -d
    COMPOSE="docker compose -p tritrack-e2e -f docker-compose.yml -f docker-compose.e2e.yml" \
        python3 scripts/verify_11_49_server_reads.py

`COMPOSE` defaults to the `tritrack-gate` project `gate_smoke_test.sh` brings
up, matching `verify_c5_denial_audit.py`.

Exits non-zero if any attack succeeded, any positive control failed, or any
discriminator proved blind.
"""
import hashlib
import http.client
import inspect
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

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
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from db_env import postgres_env  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = os.environ.get("BASE", "http://localhost:8080")
LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")
COMPOSE = os.environ.get(
    "COMPOSE",
    "docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml",
).split()

T = "2026-08-01T12:00:00.000Z"
RUN = uuid.uuid4().hex[:8]

#: `maxListedSessions` in `server/lib/src/auth/auth_service.dart`, read rather
#: than typed — a bound this file carried its own copy of would go on passing
#: against a server that had changed it, which is `gate_wire.py`'s whole
#: premise applied one level down.
_AUTH_SERVICE = open(
    os.path.join(ROOT, "server", "lib", "src", "auth", "auth_service.dart")
).read()


def _dart_const_int(name):
    match = re.search(
        r"const\s+int\s+%s\s*=\s*(\d+)\s*;" % re.escape(name), _AUTH_SERVICE
    )
    if not match:
        raise SystemExit(
            f"Could not find `const int {name}` in auth_service.dart. This "
            f"instrument derives the bound it measures from that declaration "
            f"so it cannot go stale — fix this parser rather than hardcoding "
            f"a number back into the script."
        )
    return int(match.group(1))


MAX_LISTED_SESSIONS = _dart_const_int("maxListedSessions")

#: `RateLimitPolicy.sessionListPerUser`, likewise read from the source.
_RATE_LIMITER = open(
    os.path.join(ROOT, "server", "lib", "src", "security", "rate_limiter.dart")
).read()
_session_rule = re.search(
    r"sessionListPerUser\s*=\s*const\s*\[\s*RateLimitRule\(limit:\s*(\d+)",
    _RATE_LIMITER,
)
if not _session_rule:
    raise SystemExit(
        "Could not parse `sessionListPerUser`'s limit out of "
        "rate_limiter.dart. Fix this parser — a flood probe that guesses the "
        "limit measures nothing."
    )
SESSION_LIST_LIMIT = int(_session_rule.group(1))

#: `maxListedProjects` and `RateLimitPolicy.projectListPerUser` — entry 15's
#: half of this file (task 11.64, finding P-1), read from source for the same
#: reason as the two bounds above.
_DIRECTORY_SERVICE = open(
    os.path.join(ROOT, "server", "lib", "src", "projects",
                 "project_directory_service.dart")
).read()
_projects_bound = re.search(
    r"const\s+int\s+maxListedProjects\s*=\s*(\d+)\s*;", _DIRECTORY_SERVICE
)
_project_rule = re.search(
    r"projectListPerUser\s*=\s*const\s*\[\s*RateLimitRule\(limit:\s*(\d+)",
    _RATE_LIMITER,
)
if not (_projects_bound and _project_rule):
    raise SystemExit(
        "Could not parse `maxListedProjects` out of "
        "project_directory_service.dart, or `projectListPerUser`'s limit out "
        "of rate_limiter.dart. Both are bounds task 11.64 added to "
        "GET /projects/mine and probe 12 measures them against those "
        "declarations — fix this parser rather than hardcoding a number, and "
        "if either bound was *removed*, finding P-1 is reopened."
    )
MAX_LISTED_PROJECTS = int(_projects_bound.group(1))
PROJECT_LIST_LIMIT = int(_project_rule.group(1))


def _section_428_fields(route="GET /projects/mine"):
    """The field set Security Model §4.28 permits on `route`, read from the
    section's own table.

    Task 11.310. This probe carried the set by hand — four names — and went
    red on 2026-09-23 against a server returning the fifth field task 11.290
    had added *and* written into §4.28 three days earlier. The Dart check,
    `test/documentation/project_directory_field_set_test.dart`, had followed
    the amendment automatically because it reads the table; this file had a
    copy, and the copy is what went stale. **So it reads the table too, by the
    same rules as that test:** the section runs from its heading to the next
    `### 4.29`, a table is recognized by its header row, and it belongs to
    whichever route the paragraph directly above it names — so §4.28.1's
    table for `GET /projects/deleted/mine` cannot be picked up in its place.

    Refuses an empty or missing result: a parser that found nothing would
    otherwise report every field the server sends as a disclosure — or, worse,
    be "fixed" by typing the set back in here.
    """
    path = os.path.join(ROOT, "CLAUDE_DOCS", "TriTrack_Security_Model.md")
    lines = open(path, encoding="utf-8").read().splitlines()
    heading = "### 4.28 What a row of `GET /projects/mine` may carry"
    header = "| Field | What it is | Why the caller may have it |"
    start = next((i for i, l in enumerate(lines)
                  if l.strip().startswith(heading)), None)
    if start is None:
        raise SystemExit(
            f"Could not find {heading!r} in {path}. Either §4.28 was removed "
            f"— in which case what GET /projects/mine may carry is undocumented "
            f"again and finding P-1 is reopened — or its heading changed, in "
            f"which case update this parser and "
            f"project_directory_field_set_test.dart together."
        )
    end = next((i for i in range(start + 1, len(lines))
                if lines[i].strip().startswith("### 4.29")), len(lines))
    tables = {}
    for i in range(start, end):
        if lines[i].strip() != header:
            continue
        above = i - 1
        while above > start and not lines[above].strip():
            above -= 1
        first = above
        while first - 1 > start and lines[first - 1].strip():
            first -= 1
        named = re.search(r"`(GET /projects/[a-z/]+)`",
                          " ".join(lines[first:above + 1]))
        fields = set()
        for j in range(i + 2, end):  # i + 1 is the | --- | separator row
            if not lines[j].lstrip().startswith("|"):
                break
            cell = lines[j].split("|")[1]
            fields.add(cell.replace("`", "").replace("**", "").strip())
        if named:
            tables[named.group(1)] = fields
    if not tables.get(route):
        raise SystemExit(
            f"Parsed no field table for {route} out of §4.28 in {path} (found "
            f"tables for {sorted(tables) or 'nothing'}). A derivation that "
            f"returns nothing cannot be allowed to pass — fix this parser "
            f"rather than hardcoding the field set back into the script."
        )
    return tables[route]


#: What a row of `GET /projects/mine` may carry, per §4.28's table. Probe 12
#: attacks the live response against exactly this set.
PROJECTS_MINE_FIELDS = _section_428_fields()

# Task 11.85 / inventory entry 29. Same treatment as the two bounds above:
# parsed from the declaration that enforces it, so probe 13 measures the
# server's number rather than one somebody typed here.
_join_list_rule = re.search(
    r"joinRequestListPerUser\s*=\s*const\s*\[\s*RateLimitRule\(limit:\s*(\d+)",
    _RATE_LIMITER,
)
_join_create_rule = re.search(
    r"joinRequestPerUser\s*=\s*const\s*\[\s*RateLimitRule\(limit:\s*(\d+)",
    _RATE_LIMITER,
)
if not (_join_list_rule and _join_create_rule):
    raise SystemExit(
        "Could not parse `joinRequestListPerUser` or `joinRequestPerUser` out "
        "of rate_limiter.dart. Inventory entry 29 requires the list route to "
        "be bounded and rate-limited like entry 27, and entry 24 requires the "
        "creation limit to be MEASURED rather than assumed — fix this parser "
        "rather than hardcoding a number, and if either rule was removed, say "
        "so as a finding."
    )
JOIN_LIST_LIMIT = int(_join_list_rule.group(1))
JOIN_CREATE_LIMIT = int(_join_create_rule.group(1))


# ---------------------------------------------------------------- wire helpers


_HOST = urllib.parse.urlsplit(BASE)


def raw(path, body=None, token=None, method="POST", headers=None, raw_headers=()):
    """Status, response headers, and the response body as **bytes**.

    Bytes rather than a parsed object because several probes below compare
    whole responses to each other: a refusal that differs only in key order or
    in whitespace is still a difference a caller can see.

    Built on `http.client` rather than `urllib.request` for one reason that is
    a probe rather than a style preference: `Request.add_header` stores headers
    in a dict, so "present two `Authorization` headers at once" silently
    becomes "present the second one" — an attack that would then be scored
    against whichever credential happened to survive. `putheader` sends both.
    """
    data = None if body is None else json.dumps(body).encode()
    conn = http.client.HTTPConnection(
        _HOST.hostname, _HOST.port or 80, timeout=30
    )
    try:
        conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        conn.putheader("Host", _HOST.netloc)
        conn.putheader("Content-Type", "application/json")
        conn.putheader("Content-Length", str(len(data or b"")))
        for name, value in (headers or {}).items():
            conn.putheader(name, value)
        if token:
            conn.putheader("Authorization", "Bearer " + token)
        for name, value in raw_headers:
            conn.putheader(name, value)
        conn.endheaders()
        if data:
            conn.send(data)
        response = conn.getresponse()
        return response.status, dict(response.getheaders()), response.read()
    finally:
        conn.close()


def call(path, body=None, token=None, method="POST", headers=None):
    status, _, payload = raw(path, body, token, method, headers)
    try:
        return status, json.loads(payload or b"{}")
    except json.JSONDecodeError:
        return status, {"raw": payload[:200].decode("utf-8", "replace")}


#: Headers that legitimately differ between two identical answers. Compared
#: separately rather than dropped silently: `x-trace-id` must be *present* on
#: both and *different* on both, which is what proves the comparison below is
#: looking at real, separate responses rather than a cached one.
_VOLATILE_HEADERS = {"date", "x-trace-id", "content-length"}


def comparable(status, headers, payload):
    """Everything about a response a caller can see, minus the volatile parts."""
    stable = {
        k.lower(): v
        for k, v in headers.items()
        if k.lower() not in _VOLATILE_HEADERS
    }
    return (status, tuple(sorted(stable.items())), payload)


def sql(query):
    """Straight at the database, past every route the server offers."""
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
        raise SystemExit(
            f"psql failed: {query}\n"
            f"COMPOSE is {' '.join(COMPOSE)!r} — if the stack you brought up "
            f"is a different compose project, set COMPOSE to name it. Two "
            f"probes below need database-seeded fixture depth and cannot run "
            f"without it; refusing to continue and report a partial sweep as "
            f"a clean one."
        )
    return [line for line in result.stdout.strip().splitlines() if line]


def token_hash(token):
    """`Tokens.hash` — SHA-256, hex. Mirrored so seeded sessions are real."""
    return hashlib.sha256(token.encode()).hexdigest()


class Person:
    """One signed-in account: session token, server-chosen user id, device."""

    def __init__(self, label):
        self.label = label
        self.email = f"t1149-{label}-{RUN}@example.invalid"
        status, _ = call("/auth/magic-link", {"email": self.email})
        assert status == 202, f"magic-link for {label}: {status}"
        path = os.path.join(LINK_DIR, self.email + ".link")
        for _ in range(80):
            if os.path.exists(path):
                break
            time.sleep(0.1)
        else:
            raise SystemExit(f"no magic link for {label} at {path}")
        link = open(path).read().split("token=")[1].strip()
        self.device = f"dev-{label}-{RUN}"
        status, body = call(
            "/auth/redeem", {"token": link, "device_id": self.device}
        )
        assert status == 200, f"redeem for {label}: {status} {body}"
        self.token = body["session_token"]
        self.id = body["user_id"]

    def mint(self, device_id, *, expires_in="30 days", last_seen="now()",
             created="now()"):
        """A second real session for this account, seeded server-side.

        The token is genuine — the server stores only a hash, so a row whose
        `token_hash` is the hash of a value we chose is indistinguishable from
        a redeemed one. This exists because the front door caps one address at
        three magic links per fifteen minutes and ten per day, and two probes
        below need more devices than that, or a session that has already run
        out.
        """
        secret = "seeded-" + uuid.uuid4().hex + uuid.uuid4().hex
        sql(
            "INSERT INTO auth_sessions "
            "(session_id, token_hash, user_id, device_id, created_at, "
            " last_seen_at, expires_at) VALUES ("
            f"'{uuid.uuid4()}', '{token_hash(secret)}', '{self.id}', "
            f"'{device_id}', {created}, {last_seen}, "
            f"now() + interval '{expires_in}')"
        )
        return secret

    def __repr__(self):
        return f"<{self.label} {self.id[:8]}>"


def sessions_of(token, query="", headers=None, method="GET", body=None,
                raw_headers=()):
    status, hdrs, payload = raw(
        "/auth/sessions" + query, body, token, method, headers, raw_headers
    )
    try:
        parsed = json.loads(payload or b"{}")
    except json.JSONDecodeError:
        parsed = {"raw": payload[:200].decode("utf-8", "replace")}
    return status, hdrs, payload, parsed


def device_ids(parsed):
    return {row.get("device_id") for row in (parsed.get("sessions") or [])}


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
    which is what both migrations write for a tag nobody copied."""
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


def push(who, pid, rows, token=None, device=None):
    return call(
        "/sync/push",
        {**ENVELOPE, "project_id": pid, "device_id": device or who.device,
         "rows": rows},
        token or who.token,
    )


def pull_raw(who, pid, cursor=0, batch=500, extra=None, token=None,
             device=None):
    body = {
        **ENVELOPE,
        "project_id": pid,
        "device_id": device or who.device,
        "cursor": cursor,
        "batch_size": batch,
        **(extra or {}),
    }
    return raw("/sync/pull", body, token or who.token)


def pull(who, pid, cursor=0, batch=500, extra=None, token=None, device=None):
    status, _, payload = pull_raw(who, pid, cursor, batch, extra, token, device)
    try:
        return status, json.loads(payload or b"{}")
    except json.JSONDecodeError:
        return status, {"raw": payload[:200].decode("utf-8", "replace")}


# ------------------------------------------------------------------- reporting

ATTACK_FAILURES = []
CONTROL_FAILURES = []
BASELINE_DRIFT = []
NOTES = []
_current = {"name": None}
_seen = set()
RESULTS = {}
#: Task 11.91. Every `attack()`/`control()`/`discriminator()` name is a key
#: into `RESULTS`, and a plain dict keyed on a string a person typed silently
#: discards an earlier result the second time that string is used — which is
#: exactly what happened to two genuinely-flipped attacks the round-9 "shape"
#: variant tripped: the check ran, the server was correctly caught, and the
#: instrument reported BLIND anyway because a later, unrelated check on a
#: different route reused the first one's name and overwrote it. Maps a
#: `RESULTS` key to the "file:line" of the call that first registered it, so
#: the second registration can name both.
_REGISTERED = {}


def _register(key):
    caller = inspect.stack()[2]
    site = f"{os.path.basename(caller.filename)}:{caller.lineno}"
    prior = _REGISTERED.get(key)
    if prior is not None:
        raise SystemExit(
            f"\nDUPLICATE CHECK NAME: {key!r} is registered twice — first "
            f"at {prior}, again at {site}. attack()/control()/"
            f"discriminator() names key a shared results dict; the second "
            f"call silently overwrites the first one's verdict. Give one of "
            f"these two call sites a different, more specific description."
        )
    _REGISTERED[key] = site

#: Attacks this build is **known** not to refuse, each with its register entry.
#: Same mechanism, and the same reason, as `verify_11_9_team_surface.py`'s:
#: a baselined attack that starts being refused fails the run, so closing a
#: finding and forgetting the register goes red rather than quiet.
#:
#: **Empty again since 2026-09-02 (task 11.125), and the emptying is what this
#: mechanism is for.** Round 9 registered R-2 here — entry 29's finding that
#: `myRequests` joined the LIVE `Projects` row for its `project_name`, so a
#: person the owner refused went on reading whatever the project was called.
#: **Task 11.79 closed it on 2026-09-01** by freezing `project_name` onto the
#: request row at request time (`join_schema.dart`) and sweeping a decided
#: request thirty days after its decision — and left this register saying the
#: finding was open. The next run drifted, which is the register working: the
#: instrument's red was a stale entry, not the §4.13 timing question the record
#: had been blaming for two days. The probe below is now an ordinary attack and
#: fails the run if the live join ever comes back.
BASELINE = {}


def probe(name):
    _current["name"] = name
    print(f"\n=== {name}")


def attack(what, refused, detail=""):
    """`refused` must be True unless `what` is in [BASELINE]."""
    _register(what)
    _seen.add(what)
    RESULTS[what] = "refused" if refused else "ADMITTED"
    baselined = what in BASELINE
    if baselined:
        if refused:
            mark = "  CLOSED? "
            BASELINE_DRIFT.append(
                f"{_current['name']}: {what} — is now refused, but the "
                f"register still records it as open ({BASELINE[what]})."
            )
        else:
            mark = "  known   "
    else:
        mark = "  refused " if refused else "  ADMITTED"
    print(f"{mark}  {what}" + (f"   [{detail}]" if detail else ""))
    if not refused and not baselined:
        ATTACK_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def control(what, accepted, detail=""):
    """`accepted` must be True: the legitimate twin of the attack worked."""
    _register("control: " + what)
    RESULTS["control: " + what] = "fired" if accepted else "BLIND"
    mark = "  control " if accepted else "  BLIND   "
    print(f"{mark}  {what}" + (f"   [{detail}]" if detail else ""))
    if not accepted:
        CONTROL_FAILURES.append(f"{_current['name']}: {what} — {detail}")


def discriminator(what, sensitive, detail=""):
    """The comparison used above can tell two different answers apart.

    A byte-equality check that would report "identical" for any two responses
    is not a check. This is the same idea as [control] one level down: it
    measures the *instrument*, not the server.
    """
    _register("discriminator: " + what)
    RESULTS["discriminator: " + what] = "sensitive" if sensitive else "BLIND"
    mark = "  discrim " if sensitive else "  BLIND   "
    print(f"{mark}  {what}" + (f"   [{detail}]" if detail else ""))
    if not sensitive:
        CONTROL_FAILURES.append(
            f"{_current['name']}: discriminator blind — {what} — {detail}"
        )


def note(text):
    print(f"  note      {text}")
    NOTES.append(f"{_current['name']}: {text}")


# ============================================================== the fixture ===
#
# Real accounts through the real magic-link flow. Extra *devices* are minted
# server-side (see `Person.mint`) because the front door caps one address at
# three links per fifteen minutes; extra *accounts* never are.

preflight(BASE, LINK_DIR)

print("\nBuilding the fixture over the real auth, publish and invite flows...")
alice = Person("alice")        # entry 27's caller
bob = Person("bob")            # entry 27's victim — nothing of his may cross
carol = Person("carol")        # entry 27's depth case
owner = Person("owner")        # entry 28's project owner
removed = Person("removed")    # entry 28's subject — removed from P
stayed = Person("stayed")      # entry 28: still a member of P
stranger = Person("stranger")  # entry 28: holds no closed row anywhere

ALICE_PHONE = f"alice-phone-{RUN}"
alice_phone_token = alice.mint(ALICE_PHONE)
BOB_SECRET_DEVICE = f"bob-secret-{RUN}"
bob.mint(BOB_SECRET_DEVICE)


# ================================================================== probe 1 ===
# Entry 27. `§4.11`: the `user_id` comes from the validated session and from
# nowhere else. Every place a caller could try to put one instead.

probe("1. Entry 27 — making GET /auth/sessions answer for somebody else")

status, _, _, mine = sessions_of(alice.token)
control("the caller's own listing answers at all",
        status == 200 and device_ids(mine) == {alice.device, ALICE_PHONE},
        f"HTTP {status}, {sorted(device_ids(mine))}")

status, _, _, his = sessions_of(bob.token)
control("and Bob's listing is a different answer, so 'Bob's rows did not "
        "cross' is a claim this run can actually make",
        status == 200 and BOB_SECRET_DEVICE in device_ids(his)
        and not (device_ids(his) & device_ids(mine)),
        f"HTTP {status}, {sorted(device_ids(his))}")
discriminator("the two listings differ",
              device_ids(mine) != device_ids(his),
              f"{sorted(device_ids(mine))} vs {sorted(device_ids(his))}")

BOB_MARKERS = device_ids(his)

redirects = {
    "a user_id in the query string":
        dict(query=f"?user_id={bob.id}"),
    "a user_id and a device_id in the query string":
        dict(query=f"?user_id={bob.id}&device_id={BOB_SECRET_DEVICE}"),
    "a user_id in a GET body":
        dict(body={"user_id": bob.id}),
    "a user_id in an X-User-Id header":
        dict(headers={"X-User-Id": bob.id}),
    "a user_id in an X-Forwarded-User header":
        dict(headers={"X-Forwarded-User": bob.id}),
    "a user_id in a bare user-id header":
        dict(headers={"user-id": bob.id}),
    "a user_id in a cookie":
        dict(headers={"Cookie": f"user_id={bob.id}; session={bob.token}"}),
    "an On-Behalf-Of header":
        dict(headers={"On-Behalf-Of": bob.id, "X-Impersonate": bob.id}),
    "a repeated user_id, in case only the first is read":
        dict(query=f"?user_id={alice.id}&user_id={bob.id}"),
    "an array-shaped user_id, in case a list is flattened":
        dict(query=f"?user_id[]={bob.id}"),
    "a POST instead of a GET, with the id in the body":
        dict(method="POST", body={"user_id": bob.id}),
}
for label, kwargs in redirects.items():
    status, _, _, parsed = sessions_of(alice.token, **kwargs)
    crossed = device_ids(parsed) & BOB_MARKERS
    attack(f"redirecting the listing with {label}",
           not crossed and status in (200, 400, 404, 405),
           f"HTTP {status}, crossed {sorted(crossed)}")

# A path segment is a different mechanism from a parameter: it would be a new
# route rather than an ignored input, so a 404 is the answer, not an empty list.
status, _, payload = raw(f"/auth/sessions/{bob.id}", None, alice.token, "GET")
attack("naming the victim in a path segment",
       status == 404 and b"device_id" not in payload,
       f"HTTP {status}, {payload[:60]!r}")

status, _, payload = raw(
    f"/auth/sessions/../auth/sessions?user_id={bob.id}", None, alice.token,
    "GET",
)
attack("the same id behind a traversal segment",
       b"device_id" not in payload or BOB_SECRET_DEVICE.encode() not in payload,
       f"HTTP {status}")

# Two credentials on one request. Shelf joins repeated headers with ", ", so
# the value the route parses is "<alice>, Bearer <bob>" — which must resolve to
# nobody rather than to either of them.
status, _, _, parsed = sessions_of(
    None, raw_headers=[("Authorization", "Bearer " + alice.token),
                       ("Authorization", "Bearer " + bob.token)]
)
attack("presenting two session tokens at once",
       status == 401 and not device_ids(parsed),
       f"HTTP {status}, {sorted(device_ids(parsed))}")

status, _, _, parsed = sessions_of(
    alice.token, headers={"Cookie": f"session_token={bob.token}"}
)
attack("Alice's bearer with Bob's token in a cookie",
       not (device_ids(parsed) & BOB_MARKERS),
       f"HTTP {status}, {sorted(device_ids(parsed))}")

# A forged device_id must not be able to move `is_current_device` — the one
# field on the row that is computed rather than stored.
status, _, _, parsed = sessions_of(
    alice.token, query=f"?device_id={ALICE_PHONE}"
)
current = [r["device_id"] for r in parsed.get("sessions", [])
           if r.get("is_current_device")]
attack("a forged device_id moving 'this is the device in your hand'",
       current == [alice.device], f"{current}")

# Credentials that must not resolve at all.
bad_tokens = {
    "a bit-flipped session token":
        alice.token[:-1] + ("A" if alice.token[-1] != "A" else "B"),
    "a truncated session token": alice.token[:-4],
    "an extended session token": alice.token + "AAAA",
    "an entirely invented token": "z" * len(alice.token),
    "Bob's user id used as a token": bob.id,
}
for label, value in bad_tokens.items():
    status, _, _, parsed = sessions_of(value)
    attack(f"listing with {label}",
           status == 401 and not device_ids(parsed),
           f"HTTP {status}")

for label, header in {
    "no Authorization header at all": None,
    "an empty bearer": "Bearer ",
    "a bare token with no scheme": alice.token,
    "a Basic scheme": "Basic " + alice.token,
    "a lowercased bearer scheme": "bearer " + alice.token,
}.items():
    status, _, _, parsed = sessions_of(
        None, raw_headers=[("Authorization", header)] if header else ()
    )
    attack(f"listing with {label}",
           status == 401 and not device_ids(parsed), f"HTTP {status}")

control("...while the unmodified header still works",
        sessions_of(alice.token)[0] == 200, "")


# ================================================================== probe 2 ===
# Entry 27. What the response carries. `ListedSession` records a decision — no
# source address — rather than an omission; §3's entry says to attack the claim
# rather than read it.

probe("2. Entry 27 — what a row carries, and what the design says it does not")

status, headers, payload, parsed = sessions_of(alice.token)
rows = parsed.get("sessions") or []
control("a listing to inspect at all", status == 200 and len(rows) == 2,
        f"HTTP {status}, {len(rows)} rows")

expected_keys = {"device_id", "first_signed_in_at", "last_seen_at",
                 "expires_at", "is_current_device"}
extra = set().union(*[set(r) for r in rows]) - expected_keys
attack("a field beyond the five the design names",
       not extra, f"extra {sorted(extra)}")

body_text = payload.decode("utf-8", "replace")
lowered = body_text.lower()
for label, needle in {
    "the caller's own session token": alice.token,
    "the phone's session token": alice_phone_token,
    "the SHA-256 the server stores instead": token_hash(alice.token),
    "the phone token's SHA-256": token_hash(alice_phone_token),
    "the first half of a token, in case of truncation": alice.token[:20],
    "the caller's email": alice.email,
    "the caller's user id": alice.id,
}.items():
    attack(f"the response carrying {label}, on /auth/sessions",
           needle.lower() not in lowered, "")

# Three-or-more colon groups, not two: an ISO timestamp carries exactly two
# ("22:23:52") and matched an earlier, looser pattern, which would have
# reported a finding on every run and taught the next reader to ignore it.
addresses = re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", body_text)
addresses += re.findall(r"(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}", lowered)
attack("the response carrying anything shaped like a source address, on "
       "/auth/sessions",
       not addresses, f"{addresses}")
discriminator("that address pattern can still see one, on /auth/sessions",
              bool(re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b",
                              body_text + " 192.0.2.7")
                   and re.findall(r"(?:[0-9a-f]{1,4}:){3,7}[0-9a-f]{1,4}",
                                  lowered + " 2001:db8:0:0:0:0:dead:beef")), "")


# Another person's *existence*, asked directly: a user id that names a real
# account and one that names nobody must produce the same answer.
#
# `last_seen_at` is normalised out before comparing, and that is not a
# weakening: validating a session refreshes it, so two consecutive requests
# from the same caller differ there by construction. It is the caller's own
# clock moving, not a fact about the id they named. Every other field,
# including the row count and the device ids, is compared as sent.
def without_clock(payload):
    parsed = json.loads(payload)
    for row in parsed.get("sessions", []):
        row["last_seen_at"] = "<normalised>"
    return json.dumps(parsed, sort_keys=True)


_, _, real_id_answer, _ = sessions_of(alice.token, query=f"?user_id={bob.id}")
_, _, fake_id_answer, _ = sessions_of(
    alice.token, query=f"?user_id={uuid.uuid4()}"
)
attack("naming a real account and a fictional one drawing different answers",
       without_clock(real_id_answer) == without_clock(fake_id_answer),
       f"{without_clock(real_id_answer)[:70]} vs "
       f"{without_clock(fake_id_answer)[:70]}")
discriminator("that normalised comparison still sees a real difference",
              without_clock(real_id_answer) != without_clock(
                  sessions_of(bob.token)[2]), "")

session_ids = sql(
    f"SELECT session_id FROM auth_sessions WHERE user_id = '{alice.id}'"
)
attack("the response carrying a server-side session id",
       not any(s in body_text for s in session_ids),
       f"{len(session_ids)} ids checked")
discriminator("those session ids exist to be looked for",
              len(session_ids) >= 2, f"{len(session_ids)}")

stored = sql(
    "SELECT source_address FROM auth_audit_log "
    f"WHERE user_id = '{alice.id}' AND source_address IS NOT NULL LIMIT 5"
)
note("the server does hold a source address for this caller elsewhere "
     f"({len(stored)} audit rows carry one) — the route's silence is a "
     "decision, not an absence of data")

# Another person's existence, through the one column both listings share.
# Bob signs in on a device id spelled exactly like one of Alice's, before and
# after her own row on it, so an unscoped `GROUP BY device_id` would move her
# row's `min(created_at)` earlier or its `max(expires_at)` later.
SHARED = f"shared-device-{RUN}"
bob.mint(SHARED, created="now() - interval '10 days'",
         last_seen="now() - interval '10 days'", expires_in="90 days")
alice.mint(SHARED, created="now() - interval '1 day'",
           last_seen="now() - interval '1 day'", expires_in="20 days")
status, _, _, parsed = sessions_of(alice.token)
# `.get(...) or []` throughout, not `[...]`: this file is also run against
# deliberately broken servers (`verify_11_49_broken_control.py`), and an
# instrument that raises on a malformed response scores no probe at all —
# which reads as "the check was not made" rather than "the check fired".
shared_rows = [r for r in (parsed.get("sessions") or [])
               if r.get("device_id") == SHARED]
control("Alice's own row on the shared device id is listed",
        len(shared_rows) == 1, f"{len(shared_rows)} rows")
if shared_rows:
    row = shared_rows[0]
    first = str(row.get("first_signed_in_at", ""))
    expires = str(row.get("expires_at", ""))
    attack("Bob's earlier sign-in on the same device id ageing Alice's row",
           first[:10] >= time.strftime(
               "%Y-%m-%d", time.gmtime(time.time() - 3 * 86400)),
           f"first_signed_in_at {first}")
    attack("Bob's longer-lived session on the same device id extending "
           "Alice's expiry",
           expires[:10] <= time.strftime(
               "%Y-%m-%d", time.gmtime(time.time() + 31 * 86400)),
           f"expires_at {expires}")
    attack("Bob's row appearing in Alice's listing at all",
           BOB_SECRET_DEVICE not in device_ids(parsed),
           f"{sorted(device_ids(parsed))}")

attack("the listing being left in a shared cache",
       headers.get("cache-control") == "no-store",
       f"cache-control {headers.get('cache-control')!r}")


# ================================================================== probe 3 ===
# Entry 27. "Bounded and rate-limited per authenticated user (10.56's standard
# treatment)" — the inventory's words. A bound nobody has seen refuse is not
# known to be a bound.

probe(f"3. Entry 27 — watching the {MAX_LISTED_SESSIONS}-row bound refuse")

status, _, _, before = sessions_of(carol.token)
control("Carol's short listing comes back whole first, so the bound below is "
        "a bound rather than a broken query",
        status == 200 and len(before.get("sessions") or []) == 1,
        f"{len(before.get('sessions') or [])} rows")

seeded = MAX_LISTED_SESSIONS + 50
print(f"  ...seeding {seeded} more devices for Carol (fixture, via psql)")
values = ",".join(
    f"('{uuid.uuid4()}', '{token_hash('fill-' + RUN + '-' + str(i))}', "
    f"'{carol.id}', 'carol-fill-{RUN}-{i:04d}', "
    f"now() - interval '{seeded - i} minutes', "
    f"now() - interval '{seeded - i} minutes', now() + interval '30 days')"
    for i in range(seeded)
)
sql(
    "INSERT INTO auth_sessions (session_id, token_hash, user_id, device_id, "
    f"created_at, last_seen_at, expires_at) VALUES {values}"
)
held = int(sql(f"SELECT count(*) FROM auth_sessions WHERE user_id = "
               f"'{carol.id}'")[0])
control(f"the database really holds {seeded + 1} live sessions for Carol",
        held == seeded + 1, f"{held}")

status, _, _, capped = sessions_of(carol.token)
rows = capped.get("sessions") or []
attack("an unbounded listing for a caller with more devices than the bound",
       len(rows) == MAX_LISTED_SESSIONS,
       f"{len(rows)} rows for {held} live sessions")

for label, kwargs in {
    "a limit in the query string": dict(query="?limit=1000"),
    "a limit in the body": dict(body={"limit": 1000}),
    "a negative limit, in case it is passed through":
        dict(query="?limit=-1"),
}.items():
    status, _, _, parsed = sessions_of(carol.token, **kwargs)
    got = len(parsed.get("sessions") or [])
    attack(f"raising the bound on /auth/sessions with {label}",
           got <= MAX_LISTED_SESSIONS, f"{got} rows")

# The truncation must not be able to hide the caller's own device: a person
# who cannot see the device in their hand cannot tell which row to keep.
current = [r for r in rows if r.get("is_current_device")]
attack("the bound truncating away the caller's current device",
       len(current) == 1 and current[0]["device_id"] == carol.device,
       f"{[r['device_id'] for r in current]}")


# ================================================================== probe 4 ===
# Entry 27. The per-user rate limit, watched refusing — and watched refusing
# *the right person*.

probe(f"4. Entry 27 — watching the {SESSION_LIST_LIMIT}-per-user limit refuse")

flood = Person("flood")
victim_of_flood = Person("floodvictim")

codes = []
for i in range(SESSION_LIST_LIMIT + 5):
    codes.append(sessions_of(flood.token)[0])
attack("an unbounded flood of session reads from one signed-in caller",
       429 in codes, f"{codes.count(200)} accepted, {codes.count(429)} refused")

status, _, payload, parsed = sessions_of(flood.token)
attack("the refusal still carrying a listing",
       status == 429 and not parsed.get("sessions"),
       f"HTTP {status}, {payload[:80]!r}")

status, _, _, _ = sessions_of(victim_of_flood.token)
control("a second signed-in caller is not locked out by the first's flood, "
        "on /auth/sessions",
        status == 200, f"HTTP {status}")

tripped = sql(
    "SELECT count(*) FROM auth_audit_log WHERE event = 'rate_limit_tripped' "
    f"AND user_id = '{flood.id}' AND reason = 'session_list_per_user'"
)
attack("a limit that trips without leaving an audit row",
       int(tripped[0]) > 0, f"{tripped[0]} rows")

# An unauthenticated flood must not be able to spend somebody else's bucket —
# the reason the limiter is checked after authentication rather than before.
for _ in range(SESSION_LIST_LIMIT + 5):
    sessions_of("z" * 43)
status, _, _, _ = sessions_of(victim_of_flood.token)
attack("an unauthenticated flood denying service to a named signed-in user",
       status == 200, f"HTTP {status}")


# ================================================================== probe 5 ===
# Entry 27. "A revoked device leaves the list when the revocation takes effect,
# not on a timer."

probe("5. Entry 27 — revocation, and when the row actually goes")

dave = Person("dave")
DAVE_LOST = f"dave-lost-{RUN}"
lost_token = dave.mint(DAVE_LOST)

status, _, _, parsed = sessions_of(dave.token)
control("the lost device is in the list before the revocation",
        DAVE_LOST in device_ids(parsed), f"{sorted(device_ids(parsed))}")
control("and its token works before the revocation",
        sessions_of(lost_token)[0] == 200, "")

status, body = call("/auth/sessions/revoke-device",
                    {"device_id": DAVE_LOST}, dave.token)
control("the revocation itself is accepted",
        status == 200 and body.get("sessions_revoked") == 1,
        f"HTTP {status}, {body}")

status, _, _, parsed = sessions_of(dave.token)
attack("the revoked device still listed on the very next request",
       DAVE_LOST not in device_ids(parsed), f"{sorted(device_ids(parsed))}")
attack("the revoked token still working on the very next request",
       sessions_of(lost_token)[0] == 401, "")

rows_left = sql(
    f"SELECT count(*) FROM auth_sessions WHERE user_id = '{dave.id}' "
    f"AND device_id = '{DAVE_LOST}'"
)
control("the row is still in the database, so its absence from the list is "
        "the query filtering rather than the row being gone",
        int(rows_left[0]) == 1, f"{rows_left[0]} rows")

# The selector claim: `device_id` comes from the body because it names which of
# the caller's *own* devices to end. A forged one must reach nobody else's.
status, body = call("/auth/sessions/revoke-device",
                    {"device_id": BOB_SECRET_DEVICE}, dave.token)
attack("revoking a device belonging to somebody else",
       body.get("sessions_revoked") == 0, f"{body}")
control("...and Bob's session on it still works",
        BOB_SECRET_DEVICE in device_ids(sessions_of(bob.token)[3]), "")

status, _ = call("/auth/sessions/revoke-all", {}, dave.token)
control("revoke-all is accepted", status == 200, f"HTTP {status}")
attack("the caller's own listing surviving revoke-all",
       sessions_of(dave.token)[0] == 401, "")


# ================================================================== probe 6 ===
# Entry 27. A session row that exists but is no longer live. Neither state is
# reachable through the front door inside one run, so both are seeded.

probe("6. Entry 27 — sessions the row outlives")

erin = Person("erin")
EXPIRED = f"erin-expired-{RUN}"
IDLE = f"erin-idle-{RUN}"
expired_token = erin.mint(EXPIRED, expires_in="-1 days")
idle_token = erin.mint(IDLE, last_seen="now() - interval '400 days'",
                       created="now() - interval '400 days'")

status, _, _, parsed = sessions_of(erin.token)
control("Erin's live device is listed", erin.device in device_ids(parsed),
        f"{sorted(device_ids(parsed))}")
attack("an expired session appearing in the list",
       EXPIRED not in device_ids(parsed), f"{sorted(device_ids(parsed))}")
attack("a session idle past the idle lifetime appearing in the list",
       IDLE not in device_ids(parsed), f"{sorted(device_ids(parsed))}")
attack("an expired session token still authenticating",
       sessions_of(expired_token)[0] == 401, "")
attack("an idle-expired session token still authenticating",
       sessions_of(idle_token)[0] == 401, "")

live = sql(
    f"SELECT count(*) FROM auth_sessions WHERE user_id = '{erin.id}'"
)
control("all three rows are in the database, so the two absences above are "
        "the filter and not a failed insert",
        int(live[0]) == 3, f"{live[0]} rows")


# ========================================================= entry 28 fixture ===
#
# A real project with a real owner, two members who joined through the real
# join code, and one of them removed by the owner pushing their own membership
# row back with the stint closed — the flow an owner's device runs.
#
# **Task 11.85 rewrote the joining half.** It used to redeem per-address
# invitations; task 11.81 deleted those routes and this instrument died at
# `404` before scoring a probe. Not a finding — an instrument that could no
# longer reach the check.

P = str(uuid.uuid4())          # the project `removed` is removed from
Q = str(uuid.uuid4())          # a real project neither of them was ever on
F = str(uuid.uuid4())          # a project id that names nothing
TAG_P = str(uuid.uuid4())
OBS_P = str(uuid.uuid4())

status, body = push(owner, P, {
    "Users": [user_row(owner)],
    "Projects": [project_row(P, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), P, owner.id, "owner", owner.id)
    ],
    "Tags": [tag_row(P, TAG_P, owner.id)],
    "Observations": [observation(OBS_P, P, owner.id, TAG_P)],
})
assert status == 200 and set(body["outcomes"].values()) == {"inserted"}, body

status, body = push(stranger, Q, {
    "Users": [user_row(stranger)],
    "Projects": [project_row(Q, stranger.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), Q, stranger.id, "owner", stranger.id)
    ],
})
assert status == 200 and set(body["outcomes"].values()) == {"inserted"}, body


#: P's join code. Never printed — it is a live credential for the right to ask.
P_CODE = None


def join(person, role="contributor"):
    global P_CODE
    P_CODE, request_id = join_by_code(
        call, owner.token, P, person.token, role, code=P_CODE)
    status, pb = push(person, P, {"Users": [user_row(person)]})
    assert status == 200, f"{person.label} profile: {status} {pb}"
    return request_id


REMOVED_REQUEST = join(removed)
STAYED_REQUEST = join(stayed)


def rows_of(body, table):
    return (body.get("rows") or {}).get(table) or []


def membership_of(person):
    """The membership row the server holds for `person` on P, as the owner
    sees it through an ordinary pull."""
    cursor, found = 0, None
    for _ in range(50):
        status, body = pull(owner, P, cursor=cursor, batch=500)
        assert status == 200, f"owner pull: {status} {body}"
        for row in rows_of(body, "Project_Memberships"):
            if row["user_id"] == person.id and row["end_date"] is None:
                found = row
        if not body.get("remaining"):
            break
        cursor = body["next_cursor"]
    assert found, f"no open membership row for {person.label}"
    return found


def close_stint(person, when="2026-08-20T09:00:00.000Z"):
    row = dict(membership_of(person))
    row["end_date"] = when
    row["revision"] = row["revision"] + 1
    row["last_modified_by"] = owner.id
    row["updated_at"] = when
    status, body = push(owner, P, {"Project_Memberships": [row]})
    key = f"Project_Memberships/{row['membership_id']}/{P}"
    assert status == 200 and body["outcomes"].get(key) == "updated", body
    return row


status, before = pull(removed, P)
assert status == 200, f"removed member's pull before removal: {status}"
control_rows_before = sum(len(v) for v in (before.get("rows") or {}).values())

closed_row = close_stint(removed)
print(f"  fixture ready: project {P[:8]}, {removed.label} removed, "
      f"{stayed.label} still a member; stranger project {Q[:8]}")


# ================================================================== probe 7 ===
# Entry 28. The property §4.27 states, measured rather than read: a caller who
# holds **no** closed membership on the named project cannot tell a project
# that does not exist from one that exists and is not theirs.

probe("7. Entry 28 — the exemption as an existence oracle")

# The prober is somebody who *can* reach the disclosure — on P — and therefore
# could detect a leak in that branch. A stranger who can never take it is a
# weaker probe, so both are run.
fictional = comparable(*pull_raw(removed, F))
forbidden = comparable(*pull_raw(removed, Q))
attack("a caller who can reach the disclosure telling a fictional project "
       "from somebody else's real one",
       fictional == forbidden,
       f"{fictional[0]}/{forbidden[0]} {fictional[2][:60]!r} vs "
       f"{forbidden[2][:60]!r}")

s_fictional = comparable(*pull_raw(stranger, F))
s_forbidden = comparable(*pull_raw(stranger, P))
attack("a caller who can never reach the disclosure telling the two apart",
       s_fictional == s_forbidden,
       f"{s_fictional[0]}/{s_forbidden[0]}")
attack("the two kinds of caller getting different refusals from each other",
       fictional == s_fictional, "")

# The comparison has to be able to say "different", or every line above is
# vacuous. The disclosure answer is a real, different response on the same
# route, from the same caller, one request apart.
disclosure = comparable(*pull_raw(removed, P))
discriminator("the byte comparison can tell two answers on this route apart",
              disclosure != forbidden, f"{disclosure[0]} vs {forbidden[0]}")

# ...and the responses being compared are genuinely separate round trips
# rather than one cached answer read twice.
_, h1, _ = pull_raw(removed, F)
_, h2, _ = pull_raw(removed, Q)
discriminator("each compared response is its own round trip",
              h1.get("x-trace-id") and h2.get("x-trace-id")
              and h1["x-trace-id"] != h2["x-trace-id"],
              f"{h1.get('x-trace-id')} vs {h2.get('x-trace-id')}")

# Task 11.60 equalised the *query count* between "absent" and "forbidden" and
# said plainly that it never measured whether the difference was detectable.
# Measured here, on loopback — the most favourable ground an attacker will
# ever get, since every network path adds noise on top, and `/sync/pull`
# carries no per-user rate limit, so nothing bounds how many samples they may
# take.
#
# **A threshold on two medians is not the measurement.** The first version of
# this probe compared `|median(absent) - median(forbidden)|` against a fixed
# fraction of the median and went red on a clean server roughly one run in
# three: the machine's own drift over a few seconds is larger than any effect
# here, so that test was measuring the laptop. What separates a real
# difference from drift is whether it has a **stable sign**. A branch that
# genuinely costs more is slower in nearly every trial; drift is slower in
# about half.
#
# So: nine independent trials, each a hundred interleaved rounds, with the
# three ids **rotated within each round** so no id is systematically last. Two
# of the three ids are fictional, which makes the second pair a null with a
# true difference of exactly zero — and that null is the discriminator: if its
# sign is unanimous too, the run is drift-dominated and has measured nothing.
#
# ## What this probe found, and what it is not sensitive enough to find
#
# **This is the check that found the timing oracle** (task 11.72, Security
# Model §4.13, "The clock is a channel too"). On a clean Linux runner it
# reported the refusal for a real project running ~54 microseconds slower than
# the refusal for a fictional id, sign positive 9/9 on each of three runs,
# while the null flipped every run. On a developer's Mac the same code reported
# no stable sign — the effect is a fiftieth of a millisecond and the spread
# printed below is 8–24 ms, so this probe can only see what survives a socket.
#
# **Keep it, and do not treat it as the measurement.** The far more sensitive
# instrument is `server/test/security/authorization_timing_test.dart`, which
# times `ProjectAuthorizer.resolve` directly against Postgres, resolves
# single-digit microseconds, and also measures the pair this probe cannot reach
# at all: two *real* projects of different membership counts. That pair is
# where the finding actually lived — the cost rose with the number of members,
# so what leaked was how many people are on a project the caller cannot see.
# This probe stays because it is the end-to-end view, through the router and
# the audit writes, from where an attacker really stands.

F2 = str(uuid.uuid4())
TRIALS, ROUNDS = 9, 100
print(f"  ...timing {TRIALS} trials x {ROUNDS} rotated rounds x 3 ids")


def one_time(pid):
    started = time.perf_counter()
    pull_raw(removed, pid)
    return (time.perf_counter() - started) * 1000


between_deltas, null_deltas, spread = [], [], []
for trial in range(TRIALS):
    samples = {"absent": [], "forbidden": [], "absent2": []}
    ids = [("absent", F), ("forbidden", Q), ("absent2", F2)]
    for r in range(ROUNDS):
        for label, pid in ids[r % 3:] + ids[:r % 3]:
            samples[label].append(one_time(pid))
    between_deltas.append(
        statistics.median(samples["forbidden"])
        - statistics.median(samples["absent"])
    )
    null_deltas.append(
        statistics.median(samples["absent2"])
        - statistics.median(samples["absent"])
    )
    spread.append(statistics.pstdev(samples["absent"]))

between_positive = sum(1 for d in between_deltas if d > 0)
null_positive = sum(1 for d in null_deltas if d > 0)
median_spread = statistics.median(spread)
mean_between = statistics.mean(between_deltas)
mean_null = statistics.mean(null_deltas)

note(f"per-request spread on this host is {median_spread:.2f} ms (stdev). "
     f"Across {TRIALS} trials the forbidden-minus-fictional difference "
     f"averaged {mean_between:+.3f} ms and was positive in "
     f"{between_positive}/{TRIALS}; the fictional-minus-fictional difference, "
     f"which is zero in truth, averaged {mean_null:+.3f} ms and was positive "
     f"in {null_positive}/{TRIALS}")

discriminator(
    "the null pair's sign flips, so this measurement is not just drift",
    0 < null_positive < TRIALS,
    f"{null_positive}/{TRIALS} positive")
# Task 11.88, 2026-08-31: this used to be an `attack()` -- pass/fail on whether
# the sign came out stable. Michael has now reviewed and accepted the residual
# this measures (Security Model §4.13, "the clock is a channel too": "i'm fine
# with someone learning the size of the team that way"), and a probe this
# coarse cannot enforce the accepted BOUND either way -- a stable sign at 9/9
# is the expected signature of a genuine few-microsecond difference, not
# evidence it has grown. Baselining it as an `attack()` was tried and reverted
# the same day: since the sign is only sometimes stable (it sits at this
# host's noise floor), a baseline entry just inverted which outcome counted as
# a failure instead of removing the false signal. `note()` reports what was
# measured without gating on it, matching the file's own comment above this
# probe: "Keep it, and do not treat it as the measurement." The real
# enforcement, with an actual numeric bound, is
# `server/test/security/authorization_timing_test.dart`, in the ordinary
# server suite on every commit.
note(f"a timing difference with a stable enough sign to classify a project id "
     f"by: {between_positive}/{TRIALS} trials positive, mean "
     f"{mean_between:+.3f} ms against a {median_spread:.2f} ms spread -- "
     f"accepted 2026-08-31 under task 11.88, Security Model §4.13")


# ================================================================== probe 8 ===
# Entry 28. Claim 1 of §4.27: the exemption is keyed on a row only the server
# can produce. If a caller can write themselves a closed membership on a
# project they were never on, the oracle is open by construction.

probe("8. Entry 28 — manufacturing the key the exemption is keyed on")

for label, pid in {"a real project they were never on": Q,
                   "a project id that names nothing": F}.items():
    row = membership_row(str(uuid.uuid4()), pid, removed.id, "contributor",
                         removed.id, end_date="2026-08-01T00:00:00.000Z")
    status, body = push(removed, pid, {"Project_Memberships": [row]})
    got = outcome_for(body, "Project_Memberships", row)
    attack(f"writing themselves a closed membership on {label}",
           got != "inserted", f"HTTP {status}, outcome {got!r}")

after_q = comparable(*pull_raw(removed, Q))
after_f = comparable(*pull_raw(removed, F))
attack("those attempts changing what either id answers",
       after_q == forbidden and after_f == fictional, "")

# The same attempt from a caller who is a member of a *different* project —
# a role the server does recognise — must fare no better.
row = membership_row(str(uuid.uuid4()), Q, stayed.id, "owner", stayed.id,
                     end_date="2026-08-01T00:00:00.000Z")
status, body = push(stayed, Q, {"Project_Memberships": [row]})
attack("a member of another project writing themselves in on this one",
       outcome_for(body, "Project_Memberships", row) != "inserted",
       f"outcome {outcome_for(body, 'Project_Memberships', row)!r}")

# The fail-closed leftover task 11.60 recorded rather than closed: a role
# string this build cannot interpret leaves an open row and no access. Whether
# it is reachable through the front door is a measurement, not an opinion.
row = membership_row(str(uuid.uuid4()), P, removed.id, "supervisor", owner.id)
status, body = push(owner, P, {"Project_Memberships": [row]})
got = outcome_for(body, "Project_Memberships", row)
attack("an owner planting a role string this build cannot interpret",
       got != "inserted", f"HTTP {status}, outcome {got!r}")
note("the unrecognised-role leftover therefore needs a server running a "
     "build that knows a role this one does not — it is not reachable from "
     "this side of the wire")


# ================================================================== probe 9 ===
# Entry 28. What crosses. One table, one person, only stints that are over.

probe("9. Entry 28 — what the disclosure actually hands back")

status, body = pull(removed, P)
tables = {t: len(rows) for t, rows in (body.get("rows") or {}).items() if rows}
control("the removed member is answered at all",
        status == 200 and tables.get("Project_Memberships"),
        f"HTTP {status}, {tables}")
control("...and could read the project before they were removed, so the "
        "narrowing below is a narrowing",
        control_rows_before > 1, f"{control_rows_before} rows before removal")

attack("a table other than Project_Memberships crossing",
       set(tables) <= {"Project_Memberships"}, f"{tables}")

got = rows_of(body, "Project_Memberships")
attack("somebody else's membership row crossing",
       all(r["user_id"] == removed.id for r in got),
       f"{sorted({r['user_id'][:8] for r in got})}")
attack("an open stint crossing",
       all(r["end_date"] or r["deleted_at"] for r in got),
       f"{[(r['end_date'], r['deleted_at']) for r in got]}")
attack("the page claiming more follows it",
       body.get("remaining") == 0, f"remaining {body.get('remaining')}")
attack("the page moving the caller's cursor",
       body.get("next_cursor") == 0, f"next_cursor {body.get('next_cursor')}")

for column in ("server_seq", "received_at", "clock_skew_flag"):
    attack(f"server-side bookkeeping ({column}) crossing",
           all(column not in r for r in got), "")

# The residual §4.27 names: the row says which account ended the stint. What
# must not follow it is that account's name.
attack("the Users row of the account that removed them crossing",
       not rows_of(body, "Users"), f"{len(rows_of(body, 'Users'))} rows")
if got:
    note(f"the disclosed row does name the removing account "
         f"({str(got[0].get('last_modified_by'))[:8]}...) and when the stint "
         f"ended ({got[0].get('end_date')}) — §4.27's stated residual, "
         f"confirmed live")

# Nothing about the project itself, including its name, may be inferred.
project_names = [r for r in rows_of(body, "Projects")]
attack("the project's own row crossing",
       not project_names, f"{len(project_names)} rows")

for label, extra in {
    "a huge batch_size": dict(batch=1_000_000),
    "a cursor far past the end": dict(cursor=10 ** 12),
    "a negative cursor": dict(cursor=-1),
    "a cursor of one": dict(cursor=1),
}.items():
    status, body = pull(removed, P, **extra)
    widened = {t for t, rows in (body.get("rows") or {}).items()
               if rows and t != "Project_Memberships"}
    attack(f"widening the disclosure with {label}",
           status in (200, 400) and not widened,
           f"HTTP {status}, {sorted(widened)}")

# The `user_id` on this route comes from the session too.
for label, extra in {
    "a user_id in the pull body": {"user_id": stayed.id},
    "a device_id belonging to somebody else": {"device_id": stayed.device},
}.items():
    status, body = pull(removed, P, extra=extra)
    got2 = rows_of(body, "Project_Memberships")
    attack(f"aiming the disclosure at another member with {label}",
           all(r["user_id"] == removed.id for r in got2),
           f"HTTP {status}, {sorted({r['user_id'][:8] for r in got2})}")

# A still-open member must not be able to reach the branch at all.
status, body = pull(stayed, P)
attack("a current member's ordinary pull turning into the disclosure branch",
       status == 200 and body.get("remaining") is not None
       and len(rows_of(body, "Observations")) > 0,
       f"HTTP {status}, {sum(len(v) for v in (body.get('rows') or {}).values())} rows")


# ================================================================= probe 10 ===
# Entry 28. "It does not restore any access."

probe("10. Entry 28 — the exemption is a branch after the refusal, not a hole")

status, body = push(removed, P, {
    "Observations": [observation(str(uuid.uuid4()), P, removed.id, TAG_P)]
})
attack("a removed member writing to the project they can now read one row of",
       status == 403, f"HTTP {status}")

status, body = call("/sync/ack", {**ENVELOPE, "project_id": P,
                                  "device_id": removed.device, "cursor": 0},
                    removed.token)
attack("a removed member acknowledging the page they were handed",
       status == 403, f"HTTP {status}")

status, body = call("/projects/mine", None, removed.token, method="GET")
listed = [p for p in body.get("projects", []) if p.get("project_id") == P]
attack("the project still appearing in their directory",
       status == 200 and not listed, f"{len(listed)} entries")

status, body = call(f"/projects/{P}/join-requests", None, removed.token,
                    method="GET")
attack("a removed member reading the project's join requests",
       status == 403, f"HTTP {status}")
status, body = call(f"/projects/{P}/join-settings", None, removed.token,
                    method="GET")
attack("a removed member reading the project's join code",
       status == 403, f"HTTP {status}")

# The audit trail §4.7 asks for: still a denial, and recorded as a distinct one.
kinds = sql(
    "SELECT reason, count(*) FROM auth_audit_log WHERE event = "
    f"'authorization_denied' AND user_id = '{removed.id}' GROUP BY reason"
)
control("the disclosure is audited as its own kind of denial",
        any(k.startswith("pull_membership_closed|") for k in kinds),
        f"{kinds}")


# ================================================================= probe 11 ===
# Entry 28. The disclosed page has no `LIMIT`. Every row on it is the caller's
# own, so the question is not disclosure but volume — and 10.56 made bounding
# every route the standing rule rather than bounding the ones somebody
# thought were risky.

probe("11. Entry 28 — how large the disclosed page can be made")

extra_rows = [
    membership_row(str(uuid.uuid4()), P, removed.id, "contributor", owner.id,
                   end_date="2026-07-%02dT00:00:00.000Z" % (i + 1))
    for i in range(20)
]
status, body = push(owner, P, {"Project_Memberships": extra_rows})
verdicts = {}
for r in extra_rows:
    got = outcome_for(body, "Project_Memberships", r)
    verdicts[got] = verdicts.get(got, 0) + 1
landed = verdicts.get("inserted", 0)
status, body = pull(removed, P)
count = len(rows_of(body, "Project_Memberships"))
note(f"an owner pushed {len(extra_rows)} further closed stints for the same "
     f"person; the server answered {verdicts}, so {landed} landed and the "
     f"disclosed page came back with {count} rows. The query itself carries "
     f"no LIMIT — what bounds it is what may be written, not what may be "
     f"read")
attack("the enlarged page carrying somebody else's row after all",
       all(r["user_id"] == removed.id
           for r in rows_of(body, "Project_Memberships")), "")


# ================================================================= probe 12 ===
# Entry 15's **read**, and the finding this file recorded and deliberately did
# not attack on 2026-08-29: `GET /projects/mine` (P-1).
#
# It has been on the inventory since Gate C's first run and has only ever been
# attacked as a *route* — can a stranger reach it, does a revoked session still
# work, does a removed member still see the project. All three hold and all
# three are somebody else's probes. **A read fails differently**: it corrupts
# nothing, it tells somebody something. Nobody had ever asked what the answer
# contains, which is what made "does it leak?" unanswerable rather than merely
# unanswered — there was no statement to falsify. Security Model §4.28 is now
# that statement and this group is what falsifies it.
#
# Task 11.64 also gave the route task 10.56's standard treatment, which it had
# never had: a `LIMIT`, a per-user rate limit, and `cache-control: no-store`.
# All three are measured below, watched refusing rather than read out of the
# source.

probe("12. Entry 15 — GET /projects/mine, the inventory's other read")


def directory_of(token, query="", headers=None, method="GET", body=None,
                 raw_headers=()):
    status, hdrs, payload = raw(
        "/projects/mine" + query, body, token, method, headers, raw_headers
    )
    try:
        parsed = json.loads(payload or b"{}")
    except json.JSONDecodeError:
        parsed = {"raw": payload[:200].decode("utf-8", "replace")}
    return status, hdrs, payload, parsed


def project_ids(parsed):
    return {row.get("project_id") for row in (parsed.get("projects") or [])}


status, hdrs, payload, mine = directory_of(owner.token)
control("the caller's own directory answers at all",
        status == 200 and project_ids(mine) == {P},
        f"HTTP {status}, {sorted(x[:8] for x in project_ids(mine))}")

status, _, _, theirs = directory_of(stranger.token)
control("a second caller's directory is a different, non-empty answer",
        status == 200 and project_ids(theirs) == {Q},
        f"HTTP {status}, {sorted(x[:8] for x in project_ids(theirs))}")

# §4.11: the `user_id` comes from the validated session and from nowhere else.
# Every place a caller could try to put one instead — the same list entry 27's
# probe 1 uses, because the question is the same question and a shorter list
# here would be a weaker claim for no reason.
for label, kwargs in [
    ("a user_id in the query string", {"query": f"?user_id={owner.id}"}),
    ("a user_id and a device_id in the query string",
     {"query": f"?user_id={owner.id}&device_id={owner.device}"}),
    ("a user_id in a GET body",
     {"body": {"user_id": owner.id}}),
    ("a user_id in an X-User-Id header",
     {"headers": {"X-User-Id": owner.id}}),
    ("a user_id in an X-Forwarded-User header",
     {"headers": {"X-Forwarded-User": owner.id}}),
    ("a user_id in a bare user-id header",
     {"headers": {"user-id": owner.id}}),
    ("a user_id in a cookie",
     {"headers": {"Cookie": f"user_id={owner.id}"}}),
    ("an On-Behalf-Of header",
     {"headers": {"On-Behalf-Of": owner.id}}),
    ("a repeated user_id, in case only the first is read",
     {"query": f"?user_id={owner.id}&user_id={stranger.id}"}),
    ("an array-shaped user_id, in case a list is flattened",
     {"query": f"?user_id[]={owner.id}"}),
    ("a project_id, in case the route filters rather than scopes",
     {"query": f"?project_id={P}"}),
]:
    status, _, _, parsed = directory_of(stranger.token, **kwargs)
    attack(f"redirecting the directory with {label}",
           status == 200 and project_ids(parsed) == {Q},
           f"HTTP {status}, {sorted(x[:8] for x in project_ids(parsed))}")

attack("the owner's project appearing in a stranger's directory at all",
       P not in project_ids(theirs), "")

# What a row may carry — §4.28, attacked rather than read. The permitted set
# is §4.28's own table (`PROJECTS_MINE_FIELDS`, parsed at the top of this
# file), never a copy: task 11.310 found this line still saying "four" three
# days after the section said five.
rows = mine.get("projects") or []
extra = set().union(*[set(r) for r in rows]) - PROJECTS_MINE_FIELDS
attack("a field beyond the ones §4.28's table names", not extra,
       f"extra {sorted(extra)}; §4.28 names {sorted(PROJECTS_MINE_FIELDS)}")

body_text = payload.decode("utf-8", "replace")
lowered = body_text.lower()
for label, needle in {
    "the caller's session token": owner.token,
    "the SHA-256 the server stores instead": token_hash(owner.token),
    "the caller's email": owner.email,
    "a teammate's email": removed.email,
    "the caller's device id": owner.device,
    "a membership id": membership_of(stayed)["membership_id"],
}.items():
    attack(f"the response carrying {label}, on /projects/mine",
           needle.lower() not in lowered, "")

addresses = re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", body_text)
attack("the response carrying anything shaped like a source address, on "
       "/projects/mine",
       not addresses, f"{addresses}")
discriminator("that address pattern can still see one, on /projects/mine",
              bool(re.findall(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b",
                              body_text + " 192.0.2.7")), "")

# The one identifier §4.28 does allow, checked as *present* rather than
# assumed: if it ever stops being returned, §4.28's paragraph explaining why
# it is kept is describing a field that no longer exists, and the
# documentation has drifted in the harmless direction that teaches the next
# reader to trust it less.
control("owner_user_id is present, which is what §4.28 justifies keeping",
        all(r.get("owner_user_id") == owner.id for r in rows), "")

attack("a directory listing left cacheable",
       hdrs.get("cache-control") == "no-store",
       f"cache-control: {hdrs.get('cache-control')!r}")

# The 200-row bound, watched refusing. Seeded server-side: the front door
# would need 250 separate publishes, and this is fixture rather than a claim
# that a caller can make these rows in one request — every `attack()` line
# above goes through the front door.
lister = Person("lister")
sql(
    "INSERT INTO \"Users\" (user_id, first_name, last_name, email, "
    " created_at, updated_at, revision) VALUES "
    f"('{lister.id}', 'Lister', 'Person', '{lister.email}', "
    f"'{T}', '{T}', 1) ON CONFLICT (user_id) DO NOTHING"
)
SEEDED = MAX_LISTED_PROJECTS + 50
sql(
    "INSERT INTO \"Projects\" (project_id, project_name, owner_user_id, "
    " creation_date, datum, created_at, updated_at, revision, "
    " coordinate_format, triangulation_window_minutes) "
    f"SELECT 'seed-{RUN}-' || g, 'Seeded ' || g, '{lister.id}', "
    f"'{T}', 'WGS84', '{T}', '{T}', 1, 'dd', 15 "
    f"FROM generate_series(1, {SEEDED}) g"
)
sql(
    "INSERT INTO \"Project_Memberships\" (membership_id, project_id, user_id, "
    " join_date, role, created_at, updated_at, revision) "
    f"SELECT 'seedm-{RUN}-' || g, 'seed-{RUN}-' || g, '{lister.id}', "
    f"'{T}', 'owner', '{T}', '{T}', 1 "
    f"FROM generate_series(1, {SEEDED}) g"
)
status, _, _, big = directory_of(lister.token)
listed = len(big.get("projects") or [])
control(f"the seeded account really does have {SEEDED} open memberships",
        int(sql(
            "SELECT count(*) FROM \"Project_Memberships\" WHERE user_id = "
            f"'{lister.id}' AND end_date IS NULL AND deleted_at IS NULL"
        )[0]) == SEEDED, "")
attack("an unbounded directory for a caller with more projects than the bound",
       status == 200 and listed == MAX_LISTED_PROJECTS,
       f"HTTP {status}, {listed} rows, bound is {MAX_LISTED_PROJECTS}")
_, _, _, raised = directory_of(
    lister.token, query=f"?limit={SEEDED}&batch_size={SEEDED}&count={SEEDED}"
)
attack("raising the bound on /projects/mine with a limit in the query string",
       len(raised.get("projects") or []) == MAX_LISTED_PROJECTS,
       f"{len(raised.get('projects') or [])} rows")

# The per-user limit, watched refusing, and watched refusing the right person.
flood_dir = Person("flooddir")
victim_dir = Person("flooddirvictim")
codes = [directory_of(flood_dir.token)[0]
         for _ in range(PROJECT_LIST_LIMIT + 5)]
attack("an unbounded flood of directory reads from one signed-in caller",
       429 in codes,
       f"{codes.count(200)} accepted, {codes.count(429)} refused")
status, _, _, parsed = directory_of(flood_dir.token)
attack("the refusal still carrying a directory",
       status == 429 and not parsed.get("projects"), f"HTTP {status}")
control("a second signed-in caller is not locked out by the first's flood, "
        "on /projects/mine",
        directory_of(victim_dir.token)[0] == 200, "")

# **The one thing this route does not do, recorded rather than fixed.** The
# sessions listing writes an audit row when its limit trips; the project
# router has no audit hook at all, so both of its rate-limit refusals — this
# one and invite redemption's, which predates it — are invisible to an
# operator. That is a real gap and it is below §4's bar: what it leaves
# undefended is an operator's view of a flood, not B1, B2 or B3. Recorded
# here as Q-1 so the next round finds it measured rather than argued about.
tripped = sql(
    "SELECT count(*) FROM auth_audit_log WHERE event = 'rate_limit_tripped' "
    f"AND user_id = '{flood_dir.id}'"
)
note(f"/projects/mine's rate limit left {tripped[0]} audit rows. **Half of "
     f"what this note used to say became false on 2026-08-31 and is corrected "
     f"here (task 11.85):** the project router is no longer without an audit "
     f"hook — task 11.81 gave it one and it records seven join events — but "
     f"no route in it audits a RATE-LIMIT refusal, so a flood against "
     f"/projects/mine or against join-request creation is still invisible to "
     f"an operator. Below the bar; finding Q-1, now narrower than when it was "
     f"written.")


# ================================================================= probe 13 ===
# INVENTORY 29 — `GET /projects/join-requests/mine`, the caller's own
# outstanding and recently-decided join requests. **New in task 11.81, given a
# `project_id` by task 11.83, and never attacked until now.**
#
# It is a read, like entries 27 and 28, so it is asked the same questions entry
# 27 was asked and passed: that a caller-supplied `user_id` anywhere in the
# request is ignored, that the row set is bounded and rate-limited, that
# `cache-control: no-store` is set, and that a decided request discloses the
# decision and — **on an approval only** — the `project_id`.
#
# **The `project_id` argument is the planning session's and this probe exists
# to try to break it.** The argument is that an approved requester is already a
# member and `GET /projects/mine` hands them the same id, so nobody the owner
# has not admitted learns any project identifier. Confirmed below on all four
# decision states, plus the field set, so "and nothing else arrived alongside
# it" is measured rather than asserted.

probe("13. Entry 29 — GET /projects/join-requests/mine")

MINE = "/projects/join-requests/mine"
#: Exactly what `MyJoinRequest.toJson` is allowed to carry.
MINE_FIELDS = ["decided_at", "decision", "project_id", "project_name",
               "request_id", "requested_at"]

E29 = str(uuid.uuid4())
status, body = push(owner, E29, {
    "Projects": [project_row(E29, owner.id)],
    "Project_Memberships": [
        membership_row(str(uuid.uuid4()), E29, owner.id, "owner", owner.id)
    ],
})
assert status == 200, body
e29_code = enable_joining(call, owner.token, E29)


def mine_of(who, query="", headers=None, body=None, raw_headers=()):
    req = urllib.request.Request(
        BASE + MINE + query,
        data=None if body is None else json.dumps(body).encode(),
        method="GET",
    )
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + who.token)
    for name, value in (headers or {}).items():
        req.add_header(name, value)
    for line in raw_headers:
        name, _, value = line.partition(":")
        req.add_header(name.strip(), value.strip())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, dict(r.headers), json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, dict(e.headers), json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return e.code, dict(e.headers), {
                "raw": raw[:200].decode("utf-8", "replace")}


# One requester per decision state, so each is read from its own account.
e29 = {}
for state in ("pending", "approved", "rejected", "cleared"):
    who = Person("e29" + state[:4])
    status, rbody = request_to_join(call, who.token, e29_code)
    assert status == 200, f"{state} request: {status} {rbody}"
    e29[state] = (who, rbody["request_id"])
status, _ = call(
    f"/projects/{E29}/join-requests/{e29['approved'][1]}/approve",
    {"role": "contributor"}, owner.token)
assert status == 200, status
status, _ = call(
    f"/projects/{E29}/join-requests/{e29['rejected'][1]}/reject", {},
    owner.token)
assert status == 200, status
# Rotation with `clear_pending` is what produces a `cleared` decision. It
# clears **every** undecided request, so it takes the pending one with it and
# that state is re-created afterwards against the code the rotation minted.
status, rotated = call(f"/projects/{E29}/join-code/rotate",
                       {"clear_pending": True}, owner.token)
assert status == 200, rotated
e29_code = rotated["code"]
pending_again = Person("e29pend2")
status, rbody = request_to_join(call, pending_again.token, e29_code)
assert status == 200, rbody
e29["pending"] = (pending_again, rbody["request_id"])

# ---- the field set, and where project_id may appear -------------------------
for state, (who, request_id) in e29.items():
    status, headers, rbody = mine_of(who)
    rows = [r for r in rbody.get("requests", [])
            if r["request_id"] == request_id]
    control(f"the {state} requester can read their own request",
            status == 200 and len(rows) == 1,
            f"HTTP {status}, {len(rows)} row(s)")
    if len(rows) != 1:
        continue
    row = rows[0]
    attack(f"a field beyond the six the design names, on the {state} request",
           sorted(row) == MINE_FIELDS, f"{sorted(row)}")
    if state == "approved":
        control("an approved request carries the project id, so the device "
                "can name what to download",
                row.get("project_id") == E29, f"{row.get('project_id')!r}")
    else:
        attack(f"a {state} request carrying the project id", 
               row.get("project_id") is None, f"{row.get('project_id')!r}")
    attack(f"a {state} request carrying the owner's identity or the code",
           E29 not in json.dumps(row) if state != "approved" else True,
           f"{row}")
attack("the no-store header missing from the caller's own request list",
       mine_of(e29["pending"][0])[1].get("cache-control") == "no-store",
       f"{mine_of(e29['pending'][0])[1].get('cache-control')!r}")

# The approved requester is a member, which is the whole basis of the argument
# that the id discloses nothing new. Measured, not assumed.
status, directory = call("/projects/mine", None, e29["approved"][0].token,
                         method="GET")
control("the approved requester already reads that same id from "
        "/projects/mine, which is why disclosing it is not new",
        status == 200
        and E29 in [p.get("project_id") for p in directory.get("projects", [])],
        f"HTTP {status}")
status, directory = call("/projects/mine", None, e29["rejected"][0].token,
                         method="GET")
attack("the rejected requester's directory naming the project",
       status == 200
       and E29 not in [p.get("project_id")
                       for p in directory.get("projects", [])],
       f"{[p.get('project_id') for p in directory.get('projects', [])]}")

# ---- a caller-supplied user_id, everywhere it could be put ------------------
victim, victim_request = e29["approved"]
prober = e29["rejected"][0]
#: **What the prober is entitled to, known from the fixture rather than read
#: back off the route.** The first draft of this block took its baseline from
#: `mine_of(prober)` with no injection and compared each injected read against
#: it — which `verify_11_85_broken_control.py` caught as blind on the first
#: run: against a server whose query is `WHERE (user_id = $1 OR TRUE)` the
#: baseline is *also* everybody's rows, so the comparison holds and every one
#: of these ten probes reports `refused` against a route with no scoping at
#: all. A check whose reference is taken from the thing under test is not a
#: check. This one is absolute.
own_ids = {e29["rejected"][1]}
_, _, own = mine_of(prober)
control("the prober's own list is exactly the one request they made",
        {r["request_id"] for r in own.get("requests", [])} == own_ids,
        f"{len(own.get('requests', []))} row(s)")


def redirected(what, **kwargs):
    status, _headers, rbody = mine_of(prober, **kwargs)
    ids = {r["request_id"] for r in rbody.get("requests", [])}
    attack(what, status in (200, 400) and ids == own_ids,
           f"HTTP {status}, {len(ids)} row(s), "
           f"victim's request present: {victim_request in ids}")


redirected("redirecting the list with a user_id in the query string",
           query=f"?user_id={victim.id}")
redirected("redirecting the list with a request_id in the query string",
           query=f"?request_id={victim_request}")
redirected("redirecting the list with a user_id in a GET body",
           body={"user_id": victim.id})
redirected("redirecting the list with a user_id in an X-User-Id header",
           headers={"X-User-Id": victim.id})
redirected("redirecting the list with a user_id in an X-Forwarded-User header",
           headers={"X-Forwarded-User": victim.id})
redirected("redirecting the list with a bare user-id header",
           headers={"user-id": victim.id})
redirected("redirecting the list with an On-Behalf-Of header",
           headers={"On-Behalf-Of": victim.id})
redirected("redirecting the list with a user_id in a cookie",
           headers={"Cookie": f"user_id={victim.id}"})
redirected("redirecting the list with a repeated user_id, in case only the "
           "first is read",
           query=f"?user_id={prober.id}&user_id={victim.id}")
redirected("redirecting the list with an array-shaped user_id, in case a list "
           "is flattened",
           query=f"?user_id[]={victim.id}")
status, _, rbody = mine_of(prober, headers={"Authorization": "Bearer nonsense"})
control("the route is authenticated at all", status == 401,
        f"HTTP {status}")

# ---- the bound, watched refusing --------------------------------------------
#
# **Seeded through the database, not the route**, because the creation limit
# probe 15 of `verify_11_9_team_surface.py` measures is 10 per account per 15
# minutes — an account cannot legitimately reach the row bound from outside, so
# a probe that tried would measure the creation limit a second time instead of
# this one.
#
# **The dates are relative to the database's clock, and must stay that way
# (task 11.310).** Until 2026-09-23 they were a fixed `2026-08-20`. A decided
# join request is kept for `decidedJoinRequestRetention` (30 days, counted from
# `decided_at`; `server/lib/src/security/retention.dart`), and
# `audit_retention_status.sh` runs later in the gate against this same
# database — so on 2026-09-21, 30 days plus the 48-hour grace after that fixed
# date, a database created minutes earlier began reporting *"RETENTION HAS
# STOPPED BEING APPLIED"* about rows this line had written. Nothing in the
# server changed. **A timestamp seeded under a rule that reads the clock is a
# timer.** Task 11.310 read every literal date in `scripts/` on 2026-09-23
# (`git grep -nE '20[0-9]{2}-[01][0-9]-' -- scripts/`) and found this the only
# one written into a column such a rule compares with now. What would make that
# false: a fixture seeding any `timeColumn` in `retention.dart`'s list, or a new
# rule that ages a column fixtures already fill.
bulk = Person("e29bulk")
SEED = MAX_JOIN_REQUESTS_RETURNED + 25
sql(
    "INSERT INTO project_join_requests (request_id, project_id, user_id, "
    "email, claimed_name, requested_at, decision, decided_at) SELECT "
    f"'e29-{RUN}-' || g, '{E29}', '{bulk.id}', '{bulk.email}', NULL, "
    f"now() - interval '2 hours' + (g || ' seconds')::interval, "
    f"'rejected', now() - interval '1 hour' "
    f"FROM generate_series(1, {SEED}) g"
)
control(f"the seeded account really does have {SEED} rows",
        int(sql("SELECT count(*) FROM project_join_requests WHERE user_id = "
                f"'{bulk.id}'")[0]) == SEED, "")
status, _, rbody = mine_of(bulk)
listed = len(rbody.get("requests") or [])
attack("an unbounded list for a caller with more requests than the bound",
       status == 200 and listed == MAX_JOIN_REQUESTS_RETURNED,
       f"HTTP {status}, {listed} rows, bound is {MAX_JOIN_REQUESTS_RETURNED}")
_, _, raised = mine_of(bulk, query=f"?limit={SEED}&batch_size={SEED}")
attack("raising the bound on /projects/join-requests/mine with a limit in "
       "the query string",
       len(raised.get("requests") or []) == MAX_JOIN_REQUESTS_RETURNED,
       f"{len(raised.get('requests') or [])} rows")

# ---- the per-user limit, watched refusing, and refusing the right person ----
flood_join = Person("e29flood")
victim_join = Person("e29floodvictim")
codes = [mine_of(flood_join)[0] for _ in range(JOIN_LIST_LIMIT + 5)]
attack("an unbounded flood of join-request reads from one signed-in caller",
       429 in codes,
       f"{codes.count(200)} accepted, {codes.count(429)} refused")
status, _, parsed = mine_of(flood_join)
attack("the refusal still carrying a list",
       status == 429 and not parsed.get("requests"), f"HTTP {status}")
control("a second signed-in caller is not locked out by the first's flood, "
        "on /projects/join-requests/mine",
        mine_of(victim_join)[0] == 200, "")

# ---- what a decided request keeps disclosing, for how long ------------------
#
# **Found by round 9 as finding R-2, closed by task 11.79 on 2026-09-01, and
# re-measured here as an ordinary attack since 2026-09-02 (task 11.125).** The
# `project_id` half holds exactly as ratified. What round 9 found was that
# `project_name` came from a join against the **live** `Projects` table while
# nothing pruned a decided request, so somebody the owner REFUSED went on
# reading whatever the project was called, indefinitely. `project_name` is now
# frozen onto the request row when the request is made (`join_schema.dart`) and
# a decided request is swept thirty days after its decision, so the rename
# below must no longer reach the refused reader — and this probe is what says
# so if the live join is ever restored. `verify_11_9_team_surface.py` probe 15
# measures the pruning half.
refused_reader = e29["rejected"][0]
_, _, before = mine_of(refused_reader)
name_before = (before.get("requests") or [{}])[0].get("project_name")
renamed = project_row(E29, owner.id, revision=2)
renamed["project_name"] = "Renamed after the refusal"
status, rbody = push(owner, E29, {"Projects": [renamed]})
control("the owner can rename their own project",
        outcome_for(rbody, "Projects", renamed) == "updated",
        repr(outcome_for(rbody, "Projects", renamed)))
_, _, after = mine_of(refused_reader)
name_after = (after.get("requests") or [{}])[0].get("project_name")
attack("a refused requester reading the project's name after it is renamed",
       name_after == name_before,
       f"read {name_before!r} before the rename and {name_after!r} after")

# A request whose project is gone drops out entirely — the inner join, which
# is the one place this route does close behind itself.
gone_row = project_row(E29, owner.id, revision=3)
gone_row["project_name"] = "Renamed after the refusal"
gone_row["deleted_at"] = "2026-08-25T00:00:00.000Z"
status, rbody = push(owner, E29, {"Projects": [gone_row]})
control("the owner can delete their own project",
        outcome_for(rbody, "Projects", gone_row) in ("updated", "deleted"),
        repr(outcome_for(rbody, "Projects", gone_row)))
_, _, gone = mine_of(refused_reader)
attack("a refused requester still reading a project that has been deleted",
       not [r for r in gone.get("requests", []) if r["request_id"]
            == e29["rejected"][1]],
       f"{gone.get('requests')}")

# ==================================================================== verdict ==

print("\n" + "=" * 72)
if NOTES:
    print("Observations (not pass/fail — read them):")
    for n in NOTES:
        print("  - " + n)
    print()

missing = sorted(set(BASELINE) - _seen)
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
          "every discriminator proved it could see a difference.")
print("=" * 72)

summary_path = os.environ.get("VERIFY_1149_JSON")
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
    print(f"summary written to {summary_path}")

# A dead server satisfies every negative assertion, so prove it is still there.
status, _ = call("/health", None, method="GET")
if status != 200:
    print(f"INCONCLUSIVE: /health answered {status} at the end of the run.")
    sys.exit(1)

sys.exit(1 if (CONTROL_FAILURES or ATTACK_FAILURES or BASELINE_DRIFT) else 0)

#!/usr/bin/env python3
# gate-instrument: gate_c_adversarial_pass
"""Security Gate C's adversarial pass, re-run in full (task 10.25).

**Not a spot-check of C-1..C-5** — those have their own scripts
(`verify_c1..c5`). This is the whole pass repeated, because the gate's own
most important conclusion was that C-1's class-level pattern was invisible to
two scoped code reviews and 309 passing tests and appeared only under a live
adversarial run. Repeating only the five known findings would repeat the
mistake that produced them.

Three groups:

  A. The six attempts task 10.16 names by name, re-run verbatim.
  B. The other attempts §7.3 recorded as held, re-run.
  C. **New attacks aimed at the remediation itself.** Every fix is new code
     on a security path, and the C-5 fix in particular turned a dead code
     path into one that writes attacker-influenced values to a table on every
     denial. That is new attack surface created by a security fix, which is
     exactly the shape nobody looks at.

Run against a live stack over raw HTTP — no client code, no mocks:

    # Task 11.69: sets TRITRACK_DEV_UID/GID and creates the link
    # directory owned by you. Without it, on Linux, the magic link is
    # written by root into a root-owned directory and this script
    # cannot read it — or is never written at all.
    . scripts/lib/host_user.sh
    docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml \
      up --build -d
    python3 scripts/gate_c_adversarial_pass.py

This script's own `COMPOSE` default names that same `-p tritrack-gate`
project (task 10.47 / Security Model §10.7.3) — it used to default to no `-p`
at all, which resolves to whatever project name the *current directory*
implies, indistinguishable from a developer's own `docker compose up`, and
`sql()` below runs `exec ... psql` against whatever that resolves to. Set
`COMPOSE` yourself if you bring the stack up under a different project name.

Exits non-zero if any control failed to hold.
"""
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gate_wire import ENVELOPE, SCHEMA_MAJOR, outcome_key, preflight  # noqa: E402
from gate_c_baseline import (  # noqa: E402
    evaluate, load_baseline, load_expected_check_count, validate_baseline, BaselineError,
)
from gate_timing_guard import (  # noqa: E402
    FAILED as CG_FAILED, HELD as CG_HELD, verdict as cg_verdict,
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

held = []
failed = []
#: Controls this run never actually exercised (e.g. no LAN address was
#: available to test from), kept apart from `held`. W-4
#: (TriTrack_Security_Model.md §10.7.1): A4 used to call `held_check(..., True,
#: "skipped")`, which is honest in its own line but indistinguishable from a
#: real pass in the `len(held)` total this file prints — a control that was
#: never run counts the same as one that was proven to hold.
skipped = []


# Task 11.69. What each check MEASURED, keyed by name, so that the baseline
# report at the bottom can carry it. Without this, an unbaselined failure
# reaches CI as a check name and nothing else — and `gate_smoke_test.sh` keeps
# only the last five lines of an instrument's output, because the full logs can
# hold live session tokens (§4.7). On the 2026-08-30 runs that cost a diagnosis
# twice: "Cg ... is not in the committed baseline" is a name, and whether the
# measured difference was 40 ms or 0.05 ms is the entire question of whether it
# is a real oracle or a noisy runner. The numbers are timings; there is nothing
# in them to redact.
check_details = {}


def held_check(name, condition, detail=""):
    print(("  HELD  " if condition else "  ***FAILED***  ") + name
          + (f"  {detail}" if detail else ""))
    if detail:
        check_details[name] = detail
    (held if condition else failed).append(name)


def skipped_check(name, reason):
    """For a control this run cannot exercise at all — never held, never failed."""
    print(f"  SKIPPED  {name}  {reason}")
    skipped.append(name)


def call(path, body, token=None, method="POST", raw=None, headers=None):
    data = raw if raw is not None else json.dumps(body).encode()
    req = urllib.request.Request(
        BASE + path, data=data if method != "GET" else None,
        headers={"Content-Type": "application/json", **(headers or {})},
        method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")
    except Exception as e:  # connection reset, etc — record it, don't crash
        return 0, repr(e)


def sql(query):
    env = postgres_env(ROOT)
    result = subprocess.run(
        COMPOSE + ["exec", "-T", "postgres", "psql", "-U", env["POSTGRES_USER"],
                   "-d", env["POSTGRES_DB"], "-tA", "-F", "|", "-c", query],
        cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(f"psql failed: {query}")
    return [l for l in result.stdout.strip().splitlines() if l]


def sign_in(label, email=None):
    email = email or f"adv-{label}-{uuid.uuid4().hex[:8]}@example.invalid"
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
    p = json.loads(body)
    return {"token": p["session_token"], "uid": p["user_id"],
            "device": device, "email": email, "link": token}


def user_row(uid, first, email=None):
    return {"user_id": uid, "first_name": first, "last_name": "Person",
            "email": email or f"{first.lower()}-{uid[:8]}@example.org",
            "created_at": T, "updated_at": T, "revision": 1,
            "last_modified_by": uid, "origin_device_id": "device-x"}


def project_row(pid, owner, name="Field"):
    return {"project_id": pid, "project_name": name, "owner_user_id": owner,
            "creation_date": T, "datum": "WGS84", "created_at": T,
            "updated_at": T, "revision": 1, "last_modified_by": owner,
            "origin_device_id": "device-x", "coordinate_format": "dd",
            "triangulation_window_minutes": 15}


def membership(mid, pid, uid, role="owner"):
    return {"membership_id": mid, "project_id": pid, "user_id": uid,
            "join_date": T, "role": role, "created_at": T, "updated_at": T,
            "revision": 1, "last_modified_by": uid, "origin_device_id": "device-x"}


def observation(oid, pid, uid, lat=35.19, lon=-111.65, notes=None):
    return {"observation_id": oid, "project_id": pid, "user_id": uid,
            "timestamp_local": T, "timestamp_utc": T, "timezone_offset": "+00:00",
            "latitude": lat, "longitude": lon, "position_source": "gps_fix",
            "elevation": 2100.0, "altitude_agl": 0.0,
            "observation_type": "directional", "signal_type": "regular_pulse",
            "signal_strength": "strong", "notes": notes, "created_at": T,
            "updated_at": T, "revision": 1, "last_modified_by": uid,
            "origin_device_id": "device-x"}


def publish(actor, pid, name="Field"):
    """The shipped publisher's shape: globals, then the project, then rows."""
    call("/sync/push", {**ENVELOPE, "project_id": pid, "device_id": actor["device"],
                        "rows": {"Users": [user_row(actor["uid"], "Owner",
                                                    actor["email"])]}},
         actor["token"])
    s, b = call("/sync/push", {**ENVELOPE, "project_id": pid,
                               "device_id": actor["device"],
                               "rows": {"Projects": [project_row(pid, actor["uid"], name)],
                                        "Project_Memberships": [
                                            membership(f"mem-{uuid.uuid4().hex[:8]}",
                                                       pid, actor["uid"])]}},
                actor["token"])
    assert s == 200, (s, b)


preflight(BASE, LINK_DIR)
print("Setting up: one victim with a project, one unrelated attacker.\n")
victim = sign_in("victim")
attacker = sign_in("attacker")
victim_project = str(uuid.uuid4())
publish(victim, victim_project, "Victim Elk Study")
call("/sync/push", {**ENVELOPE, "project_id": victim_project,
                    "device_id": victim["device"],
                    "rows": {"Observations": [
                        observation(f"vobs-{RUN}", victim_project, victim["uid"])]}},
     victim["token"])
call("/sync/push", {**ENVELOPE, "project_id": str(uuid.uuid4()),
                    "device_id": attacker["device"],
                    "rows": {"Users": [user_row(attacker["uid"], "Attacker",
                                                attacker["email"])]}},
     attacker["token"])

# ---------------------------------------------------------------- group A
print("A. The six attempts task 10.16 names by name")

# A1 — cross-project access with a session scoped to another project of the
# same user. Sessions are not project-scoped, so this is really: does naming
# P2 through a request about P1 move any row between them?
p1, p2 = str(uuid.uuid4()), str(uuid.uuid4())
solo = sign_in("solo")
publish(solo, p1, "P1")
publish(solo, p2, "P2")
call("/sync/push", {**ENVELOPE, "project_id": p2, "device_id": solo["device"],
                    "rows": {"Observations": [observation(f"p2obs-{RUN}", p2, solo["uid"])]}},
     solo["token"])
s, b = call("/sync/pull", {**ENVELOPE, "project_id": p1, "device_id": solo["device"],
                           "cursor": 0, "batch_size": 500}, solo["token"])
held_check("A1 a pull for P1 never discloses P2's observation",
           f"p2obs-{RUN}" not in b)
s, b = call("/sync/push", {**ENVELOPE, "project_id": p1, "device_id": solo["device"],
                           "rows": {"Observations": [
                               observation(f"smuggle-{RUN}", p2, solo["uid"])]}},
            solo["token"])
s2, b2 = call("/sync/pull", {**ENVELOPE, "project_id": p2, "device_id": solo["device"],
                             "cursor": 0, "batch_size": 500}, solo["token"])
held_check("A1 a row body claiming another project never lands there",
           f"smuggle-{RUN}" not in b2)

# A2 — reuse a consumed magic link, and guess one.
s, b = call("/auth/redeem", {"token": victim["link"], "device_id": "replay"})
held_check("A2 a consumed magic link is refused", s == 400, f"{s} {b[:60]}")
guess = "z" * len(victim["link"])
s2, b2 = call("/auth/redeem", {"token": guess, "device_id": "guess"})
held_check("A2 a guessed token is refused identically",
           (s, b) == (s2, b2), f"consumed={s} guessed={s2}")

# A3 — act on an explicitly revoked session.
revoked = sign_in("revoked")
s, _ = call("/projects/mine", {}, revoked["token"], method="GET")
before_ok = s == 200
rs, rb = call("/auth/sessions/revoke-all", {}, revoked["token"])
assert rs == 200, f"revoke-all {rs} {rb} — check the route name before "\
                  f"reading anything below as a finding"
s1, _ = call("/projects/mine", {}, revoked["token"], method="GET")
s2, _ = call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                            "device_id": revoked["device"], "cursor": 0,
                            "batch_size": 500}, revoked["token"])
held_check("A3 a revoked session is refused on every route",
           before_ok and s1 == 401 and s2 == 401, f"{s1}/{s2}")

# A4 — reach the diagnostics console off-host.
lan = socket.gethostbyname_ex(socket.gethostname())[2]
lan = [a for a in lan if not a.startswith("127.")]
if lan:
    addr = lan[0]
    reach = []
    for path in ("/health", "/diagnostics/health", "/diagnostics/projects"):
        try:
            with urllib.request.urlopen(f"http://{addr}:8080{path}", timeout=3) as r:
                reach.append((path, r.status))
        except urllib.error.HTTPError as e:
            reach.append((path, e.code))
        except Exception:
            reach.append((path, "unreachable"))
    # With 10.22's loopback publish default the whole server is unreachable
    # from the LAN, which subsumes the console check rather than replacing it.
    held_check("A4 no diagnostics route answers from the LAN address",
               all(code != 200 for path, code in reach if "diagnostics" in path),
               f"{addr} -> {reach}")
else:
    skipped_check("A4 diagnostics reachable from the LAN address",
                  "no LAN address to test from")

# A5 — enumerate registered addresses.
known = victim["email"]
unknown = f"never-{uuid.uuid4().hex}@example.invalid"
r_known = call("/auth/magic-link", {"email": known})
r_unknown = call("/auth/magic-link", {"email": unknown})
held_check("A5 registered and unregistered addresses are indistinguishable",
           (r_known[0] == r_unknown[0]
            and sorted(json.loads(r_known[1] or "{}").keys())
            == sorted(json.loads(r_unknown[1] or "{}").keys())),
           f"{r_known[0]} vs {r_unknown[0]}")

# A6 — mutate another user's observation over raw HTTP.
s, b = call("/sync/push", {**ENVELOPE, "project_id": victim_project,
                           "device_id": attacker["device"],
                           "rows": {"Observations": [
                               observation(f"vobs-{RUN}", victim_project,
                                           victim["uid"], lat=0.0, lon=0.0,
                                           notes="TAMPERED")]}},
            attacker["token"])
s2, b2 = call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                             "device_id": victim["device"], "cursor": 0,
                             "batch_size": 500}, victim["token"])
held_check("A6 a stranger cannot mutate the victim's observation",
           s == 403 and "TAMPERED" not in b2, f"push={s}")

# ---------------------------------------------------------------- group B
print("\nB. The other attempts §7.3 recorded as held")

s, _ = call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                           "device_id": "x", "cursor": 0, "batch_size": 500})
held_check("B1 unauthenticated pull is refused", s == 401, f"got {s}")

s, b = call("/sync/push", {**ENVELOPE, "project_id": victim_project,
                           "device_id": attacker["device"],
                           "rows": {"Project_Memberships": [
                               membership(f"self-{RUN}", victim_project,
                                          attacker["uid"], role="member")]}},
            attacker["token"])
s2, _ = call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                            "device_id": attacker["device"], "cursor": 0,
                            "batch_size": 500}, attacker["token"])
held_check("B2 a self-granted membership does not create access",
           s == 403 and s2 == 403, f"push={s} then pull={s2}")

s, _ = call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                           "device_id": attacker["device"], "cursor": 0,
                           "batch_size": 10 ** 9}, attacker["token"])
held_check("B3 an oversized batch_size against a foreign project is refused",
           s == 403, f"got {s}")

s, _ = call("/sync/push", {}, raw=b'{"pad":"' + b"A" * 40000 + b'"}')
held_check("B4 a 40 KB unauthenticated body is refused before it is read",
           s in (400, 401, 413), f"got {s}")

for payload in ("' OR 1=1 --", "'; DROP TABLE observations; --",
                "\" UNION SELECT * FROM auth_sessions --"):
    call("/sync/pull", {**ENVELOPE, "project_id": payload,
                        "device_id": attacker["device"], "cursor": 0,
                        "batch_size": 500}, attacker["token"])
tables = sql("SELECT count(*) FROM information_schema.tables "
             "WHERE table_schema='public'")[0]
s, b = call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                           "device_id": victim["device"], "cursor": 0,
                           "batch_size": 500}, victim["token"])
held_check("B5 SQL injection through project_id changes nothing",
           int(tables) >= 20 and s == 200 and f"vobs-{RUN}" in b,
           f"{tables} tables, legitimate pull {s}")

# ---------------------------------------------------------------- group C
print("\nC. New attacks, aimed at the remediation itself")

# C-a. The row-naming invariant (10.20) across EVERY naming column, not the
# four C-1 happened to surface in. A fix derived as a rule should hold on
# columns nobody wrote a reproduction for.
naming = []
for table, row, col in [
    ("Observations", observation(f"n1-{RUN}", victim_project, victim["uid"]), "user_id"),
    ("Projects", project_row(str(uuid.uuid4()), victim["uid"]), "owner_user_id"),
    ("Project_Memberships", membership(f"n3-{RUN}", str(uuid.uuid4()), victim["uid"]), "user_id"),
]:
    own = str(uuid.uuid4())
    publish(attacker, own)
    body = dict(row)
    if table == "Projects":
        body["project_id"] = own
        # A *winning* revision, or the merge discards this as stale before
        # authorization is ever consulted and the pass reads "held" for the
        # wrong reason. B1c was an update by the legitimate owner.
        body["revision"] = 99
    s, b = call("/sync/push", {**ENVELOPE, "project_id": own,
                               "device_id": attacker["device"],
                               "rows": {table: [body]}}, attacker["token"])
    outcomes = json.loads(b).get("outcomes", {}) if s == 200 else {}
    naming.append((table, col, s, list(outcomes.values())))
held_check("Ca naming the victim is refused on every table tested",
           # `vals` must be non-empty. Without that clause this reads an empty
           # `outcomes` map as "every table refused", because `all()` over an
           # empty sequence is True — a vacuous pass on C-1, the severest
           # finding this file tests. Found by the third re-run's own sweep
           # (§10.7 H-8); the four verify_*.py instruments were already written
           # to compare positively and this one was missed.
           all(s != 200 or (vals and all(v == "unauthorized" for v in vals))
               for _, _, s, vals in naming),
           str(naming))

# last_modified_by is a naming column too, and Gate B closed it separately —
# check the derived rule still covers what the point-fix used to.
own = str(uuid.uuid4())
publish(attacker, own)
row = observation(f"lmb-{RUN}", own, attacker["uid"])
row["last_modified_by"] = victim["uid"]
s, b = call("/sync/push", {**ENVELOPE, "project_id": own,
                           "device_id": attacker["device"],
                           "rows": {"Observations": [row]}}, attacker["token"])
s2, b2 = call("/sync/pull", {**ENVELOPE, "project_id": own,
                             "device_id": attacker["device"], "cursor": 0,
                             "batch_size": 500}, attacker["token"])
held_check("Cb last_modified_by cannot name the victim into reachability",
           victim["uid"] not in b2, f"push={s}")

# C-c. Does the naming invariant leak WHETHER a user id exists? The recorded
# seam is "a row may name a user the server has never seen" (first-publish
# replication). If a known id is refused and an unknown one accepted, that is
# a user-existence oracle of exactly C-2's shape, created by C-1's fix.
own = str(uuid.uuid4())
publish(attacker, own)
unknown_uid = str(uuid.uuid4())
r_known = call("/sync/push", {**ENVELOPE, "project_id": own,
                              "device_id": attacker["device"],
                              "rows": {"Observations": [
                                  observation(f"ko-{RUN}", own, victim["uid"])]}},
               attacker["token"])
r_unknown = call("/sync/push", {**ENVELOPE, "project_id": own,
                                "device_id": attacker["device"],
                                "rows": {"Observations": [
                                    observation(f"uo-{RUN}", own, unknown_uid)]}},
                 attacker["token"])
ko = json.loads(r_known[1]).get("outcomes", {}) if r_known[0] == 200 else {}
uo = json.loads(r_unknown[1]).get("outcomes", {}) if r_unknown[0] == 200 else {}
same = (r_known[0] == r_unknown[0]
        and sorted(ko.values()) == sorted(uo.values()))
held_check("Cc naming a real user vs a fictional one is indistinguishable",
           same, f"known={r_known[0]}/{list(ko.values())} "
                 f"unknown={r_unknown[0]}/{list(uo.values())}")

# C-d. The C-5 fix made denials write attacker-influenced values to a table.
# `project_id` is entirely caller-controlled and lands in `outcome`. Try to
# inject through it: SQL, a newline forging a second log line, and a huge
# value to see whether an attacker can bloat the log a kilobyte at a time.
before = int(sql("SELECT count(*) FROM auth_audit_log")[0])
injections = {
    "sql": "x'; INSERT INTO auth_audit_log(event) VALUES ('forged'); --",
    "newline": "real\nevent=session_created user_id=admin outcome=forged",
    "html": "<script>alert(document.cookie)</script>",
    "huge": "A" * 100000,
}
for label, value in injections.items():
    call("/sync/pull", {**ENVELOPE, "project_id": value,
                        "device_id": attacker["device"], "cursor": 0,
                        "batch_size": 500}, attacker["token"])
forged = sql("SELECT count(*) FROM auth_audit_log WHERE event = 'forged'")[0]
held_check("Cd audit-log injection through project_id does not forge a row",
           forged == "0", f"{forged} forged rows")
events = sql("SELECT DISTINCT event FROM auth_audit_log")
# `all()` over an empty sequence is True — W-5 (TriTrack_Security_Model.md
# §10.7.1): an empty `auth_audit_log` (C-5 regressing, so nothing was ever
# written) would otherwise read as "the event column still holds only the
# closed enum". `events` must be non-empty first.
held_check("Cd the event column still holds only the closed enum",
           bool(events) and all(re.fullmatch(r"[a-z_]+", e) for e in events),
           str(events))
widest = sql("SELECT coalesce(max(length(outcome)), 0) FROM auth_audit_log")[0]
held_check("Cd a caller cannot store an unbounded value in the audit log",
           int(widest) < 10000, f"widest outcome = {widest} chars")

# C-e. Audit-log flooding. Before 10.23 a denial wrote nothing; now every
# denied request writes a row, and §7.6 records that §4.7 retention is a
# mechanism nothing schedules. Two separate properties, split at task 10.25's
# second re-run because 10.30 closed one of them and not the other, and a
# single check that stays red cannot show which:
#
#   the SIZE of one denial's write   -- bounded by maxAuditFieldLength (10.30)
#   the NUMBER of denials retained   -- unbounded; /sync/pull carries no rate
#                                       limit and §4.7's retention sweep is
#                                       still a mechanism nothing schedules
n = 40
t0 = time.perf_counter()
for i in range(n):
    call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                        "device_id": attacker["device"], "cursor": 0,
                        "batch_size": 500}, attacker["token"])
elapsed = time.perf_counter() - t0
after = int(sql("SELECT count(*) FROM auth_audit_log")[0])
grew = after - before
held_check("Ce1 one denial cannot write an unbounded amount (10.30's cap)",
           int(widest) <= 500, f"widest stored field = {widest} chars")
held_check("Ce2 a denial flood cannot grow the audit store without bound",
           grew < n,
           f"{n} denied requests in {elapsed:.1f}s added {grew} audit rows; "
           f"/sync/pull is not rate-limited and §4.7's retention sweep is "
           f"unscheduled")

# C-f. Is the 10.26 rate-limit escape hatch reachable in the shipped compose?
#
# Task 10.54 / Security Model §11.5: this never checked the return code, so
# it could not fail — demonstrated live by pointing it at a non-existent
# compose file (returncode=1, empty stdout, substring absent, "Cf -> HELD").
# It also read the whole `config` text output as an undifferentiated blob;
# `--format json` and a lookup on the resolved server environment is a real
# assertion about the value, not a grep over everything docker printed.
#
# What this check does NOT do, deliberately: exercise the limiter's actual
# BEHAVIOUR. It can't, cheaply — this script attacks the already-running e2e
# stack, which sets TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED=1 on purpose
# (task 10.26, so the suite's own traffic doesn't trip a per-source rule
# designed against a botnet). The live-behaviour proof, against a stack where
# the limiter is ON, is scripts/verify_i1_source_identity.sh (task 10.52) —
# it brings up docker-compose.tls.yml instead and attacks it from two client
# containers, with a negative control. gate_smoke_test.sh runs both
# instruments in the same pass, so between them the shipped ARTIFACT and the
# limiter's ENFORCED BEHAVIOUR are each proven, by the tool suited to each.
cfg = subprocess.run(
    ["docker", "compose", "-f", "docker-compose.yml", "config", "--format", "json"],
    cwd=ROOT, capture_output=True, text=True)
cf_ok = cfg.returncode == 0
disabled_value = None
if cf_ok:
    try:
        server_env = json.loads(cfg.stdout)["services"]["server"].get("environment") or {}
        disabled_value = server_env.get("TRITRACK_RATE_LIMIT_PER_SOURCE_DISABLED")
    except (ValueError, KeyError, TypeError):
        cf_ok = False
held_check("Cf the shipped compose does not disable the per-source limiter",
           cf_ok and disabled_value in (None, ""),
           f"returncode={cfg.returncode} disabled={disabled_value!r}")

# C-g. Existence oracle by timing, on the fix that closed the status-code one.
#
# **Rewritten by task 11.49 (2026-08-29), because the first version measured
# this machine rather than this server.** It took the median of twelve
# consecutive requests to a real project, then the median of twelve to a
# fictional one, and failed if the two differed by more than half. Three things
# were wrong with that, and together they made it flaky rather than strict:
#
#   1. **No interleaving.** The two groups were measured one after the other,
#      so any drift over those few seconds — another instrument finishing, a
#      container starting, the laptop deciding to do something else — landed
#      entirely on one group.
#   2. **Twelve samples and a median.** One stall long enough to touch six of
#      the twelve moves the median all the way.
#   3. **No null.** Nothing in the check could tell "the two answers differ"
#      from "two measurements of the same answer differ", which on this host
#      they routinely do.
#
# Measured, not asserted: run under `gate_smoke_test.sh` on 2026-08-29 it
# reported `real 46.3ms vs fictional 4.3ms` and **failed the whole gate as an
# unbaselined finding**, while a rotated, interleaved measurement of the same
# two answers taken minutes later put the difference at **hundredths of a
# millisecond with no stable sign** (Security Model §20.3). Repeating the old
# check ten times by hand produced one more failure, in the run where the
# *fictional* id was measured first — the opposite of a real effect.
#
# So this now does what `scripts/verify_11_49_server_reads.py` probe 7 does,
# and for the same reason: **a real difference has a stable sign, and drift
# does not.** Three ids, two of them fictional so that pair is a null whose
# true difference is exactly zero; the three are rotated within every round so
# none is systematically last; several independent trials.
#
# **The verdict rule itself lives in `scripts/gate_timing_guard.py`, rewritten
# by task 11.90 (finding R-3, Security Model §22.4.1), and the reason it is a
# separate file is that the rule this one replaces was wrong.** The old one
# failed on a unanimous between-pair sign and declared INCONCLUSIVE only when
# the *null's* sign was unanimous too — **it tested the null's sign and never
# its size.** On 2026-08-31 a run sharing this laptop with seventeen other gate
# instruments produced a null positive in 5 of 7 trials, which is not unanimous,
# while load pushed the between pair to +0.125 ms positive in 7 of 7; that was
# scored as a Gate C blocker and three quiet re-runs could not reproduce it.
# The rule now compares the effect against **the resolution the run itself
# demonstrated** — the largest gap it opened between two ids that are identical
# in truth — so an effect the run cannot resolve is INCONCLUSIVE rather than a
# finding. It is not a wider tolerance: a real oracle is still red however
# loaded the host, because load inflates the null and the effect is compared to
# it rather than to a constant. `python3 scripts/gate_timing_guard.py
# --selftest` breaks that rule on purpose, in about a second, including on
# R-3's own numbers.
#
# **This check went red on a clean Linux runner and was right to** (task 11.72,
# Security Model §4.13, "The clock is a channel too"). It and probe 7 of
# `verify_11_49_server_reads.py` are independently written and both saw the
# same difference, which rules out one instrument being wrong — but they probe
# the same route, so it never ruled out one handler being wrong. The cause was
# `ProjectAuthorizer.resolve` reading every membership row of the project, and
# it was on all four routes that call it. Both statements now return a result
# whose size does not depend on the project. **The sensitive measurement is not
# here**: it is `server/test/security/authorization_timing_test.dart`, which
# times that function directly and can see effects a hundred times smaller than
# anything reachable through a socket.
CG_TRIALS, CG_ROUNDS = 7, 60


def _cg_one(pid):
    t0 = time.perf_counter()
    call("/sync/pull", {**ENVELOPE, "project_id": pid,
                        "device_id": attacker["device"], "cursor": 0,
                        "batch_size": 500}, attacker["token"])
    return (time.perf_counter() - t0) * 1000


cg_ids = [("real", victim_project), ("fake1", str(uuid.uuid4())),
          ("fake2", str(uuid.uuid4()))]
cg_between, cg_null = [], []
for _trial in range(CG_TRIALS):
    cg_samples = {"real": [], "fake1": [], "fake2": []}
    for _round in range(CG_ROUNDS):
        rot = _round % 3
        for label, pid in cg_ids[rot:] + cg_ids[:rot]:
            cg_samples[label].append(_cg_one(pid))
    med = {k: sorted(v)[len(v) // 2] for k, v in cg_samples.items()}
    cg_between.append(med["real"] - med["fake1"])
    cg_null.append(med["fake2"] - med["fake1"])

cg_name = ("Cg a real foreign project and a fictional one are not "
           "distinguishable by timing")
cg_state, cg_detail = cg_verdict(cg_between, cg_null)
check_details[cg_name] = cg_detail
if cg_state in (CG_HELD, CG_FAILED):
    held_check(cg_name, cg_state == CG_HELD, cg_detail)
else:
    skipped_check(cg_name, f"INCONCLUSIVE — {cg_detail}")

# C-h. Unauthenticated request steering the error path (§7.6 F10 said this
# returns 500 rather than 401 — re-check, since it is on the sync routes the
# other fixes rewrote).
s, b = call("/sync/push", {"project_id": 42})
held_check("Ch an unauthenticated malformed body is refused, not 500",
           s == 401, f"got {s} {b[:80]}")

# C-i. Does any error body leak a coordinate, an email, or a project name?
bodies = []
for pid in (victim_project, str(uuid.uuid4()), "../../etc/passwd", ""):
    bodies.append(call("/sync/pull", {**ENVELOPE, "project_id": pid,
                                      "device_id": attacker["device"],
                                      "cursor": 0, "batch_size": 500},
                       attacker["token"])[1])
blob = " ".join(bodies)
held_check("Ci no error body carries a coordinate, an address, or a name",
           not any(s in blob for s in ("35.19", "-111.65", "Victim Elk Study",
                                       victim["email"], victim["uid"])),
           blob[:120])

# ---------------------------------------------------------------- group D
print("\nD. New attacks, aimed at the SECOND round of remediation "
      "(tasks 10.28-10.36)")

# The standing lesson from both previous gates: repairing a security control is
# a change to the attack surface. D-1's fix converged two branches on a refusal,
# D-2's added a truncating write, and 10.35 changed every project-scoped table's
# primary key. None of that existed when group C was written.

# D-a. 10.35 made the primary key composite and CALLER-SUPPLIED ON BOTH HALVES.
# The row key `Observations/<observation_id>/<project_id>` now contains a
# project id that the merge has to reconcile against the envelope's. If the key
# half wins anywhere, a row lands in a project the caller never named.
own = str(uuid.uuid4())
publish(attacker, own)
smuggled = observation(f"key-smuggle-{RUN}", victim_project, attacker["uid"],
                       notes="KEY-SMUGGLED")
s, b = call("/sync/push", {**ENVELOPE, "project_id": own,
                           "device_id": attacker["device"],
                           "rows": {"Observations": [smuggled]}},
            attacker["token"])
s2, b2 = call("/sync/pull", {**ENVELOPE, "project_id": victim_project,
                             "device_id": victim["device"], "cursor": 0,
                             "batch_size": 500}, victim["token"])
held_check("Da a composite key naming another project does not land there",
           "KEY-SMUGGLED" not in b2 and f"key-smuggle-{RUN}" not in b2,
           f"push={s} {b[:80]}")

# D-b. The same, inverted: the key half names the caller's own project while
# the row's scope column names the victim's. Whichever of the two the server
# trusts, the other is an unchecked path into the pair.
crossed = observation(f"key-cross-{RUN}", own, attacker["uid"],
                      notes="KEY-CROSSED")
crossed["project_id"] = own
s, b = call("/sync/push", {**ENVELOPE, "project_id": victim_project,
                           "device_id": attacker["device"],
                           "rows": {"Observations": [crossed]}},
            attacker["token"])
s2, b2 = call("/sync/pull", {**ENVELOPE, "project_id": own,
                             "device_id": attacker["device"], "cursor": 0,
                             "batch_size": 500}, attacker["token"])
held_check("Db a push at a foreign project cannot write into the caller's own",
           s == 403 and "KEY-CROSSED" not in b2, f"push={s}")

# D-c. 10.35 scoped SIX tables. `Users`, `User_Emails` and `Tags` are still
# keyed globally, so D-1 arm (c) — "does this key exist anywhere on the
# server" — is only closed where the key was scoped. `Tags` is covered by
# verify_d1_per_row_oracle.py; `User_Emails` is covered by neither that script
# nor any test, and it is a client-chosen global uuid like the rest.
#
# **Task 10.55 narrowed what may be written here, and the probe had to follow.**
# A `User_Emails` row is now refused unless its address is one the server
# authenticated for that `user_id` — which, since a new address is a new account,
# means only the caller's *current* address is accepted and a genuine prior one
# is not. The seed and both probes therefore carry their own pusher's real
# address. Without that they would all be refused for the address and the
# equivalence would hold for a reason it was not written for: the failure mode
# §10.5 exists to catch.
own = str(uuid.uuid4())
publish(attacker, own)


def push_email_row(email_id, uid, email):
    # The attacker's *own* authenticated address (task 10.55): an invented one
    # is refused for the address, which would make both probes below agree for
    # a reason that has nothing to do with the key they are probing.
    row = {"user_email_id": email_id, "user_id": uid,
           "email": email,
           "recorded_at": T, "created_at": T, "updated_at": T, "revision": 1,
           "last_modified_by": uid, "origin_device_id": "device-x"}
    st, bd = call("/sync/push", {**ENVELOPE, "project_id": own,
                                 "device_id": attacker["device"],
                                 "rows": {"User_Emails": [row]}},
                  attacker["token"])
    out = json.loads(bd).get("outcomes", {}) if st == 200 else {}
    return st, sorted(out.values())


# Seed one, as the victim, so there is definitely a key in use by someone else.
victim_email_id = str(uuid.uuid4())
seed_status, seed_body = call("/sync/push", {**ENVELOPE, "project_id": victim_project,
                    "device_id": victim["device"],
                    "rows": {"User_Emails": [{
                        "user_email_id": victim_email_id,
                        "user_id": victim["uid"],
                        "email": victim["email"], "recorded_at": T,
                        "created_at": T, "updated_at": T, "revision": 1,
                        "last_modified_by": victim["uid"],
                        "origin_device_id": "device-x"}]}}, victim["token"])
in_use = sql('SELECT count(*) FROM "User_Emails" WHERE user_email_id = '
             f"'{victim_email_id}'")[0]
taken = push_email_row(victim_email_id, attacker["uid"], attacker["email"])
free = push_email_row(str(uuid.uuid4()), attacker["uid"], attacker["email"])
held_check("Dc a User_Emails key another user holds is indistinguishable "
           "from a free one",
           in_use == "1" and taken == free,
           f"seeded={in_use} taken={taken} free={free}")

# D-d. 10.29 converged several distinct refusal causes on one outcome string.
# If the causes are still distinguishable by anything else in the response —
# a different status, a different key set, an extra field — the oracle moved
# rather than closed, which is exactly what C-2 -> D-1 was.
own = str(uuid.uuid4())
publish(attacker, own)
refusals = {}
# (i) names a user this project does not reach
r = observation(f"ref-user-{RUN}", own, victim["uid"])
refusals["unreachable user"] = call(
    "/sync/push", {**ENVELOPE, "project_id": own, "device_id": attacker["device"],
                   "rows": {"Observations": [r]}}, attacker["token"])
# (ii) names a tag this project does not reach
r = observation(f"ref-tag-{RUN}", own, attacker["uid"])
r["tag_id"] = str(uuid.uuid4())
refusals["unreachable tag"] = call(
    "/sync/push", {**ENVELOPE, "project_id": own, "device_id": attacker["device"],
                   "rows": {"Observations": [r]}}, attacker["token"])
# (iii) names a user the server has never seen at all
r = observation(f"ref-ghost-{RUN}", own, str(uuid.uuid4()))
refusals["never-seen user"] = call(
    "/sync/push", {**ENVELOPE, "project_id": own, "device_id": attacker["device"],
                   "rows": {"Observations": [r]}}, attacker["token"])
shapes = {}
for label, (st, bd) in refusals.items():
    parsed = json.loads(bd) if bd else {}
    shapes[label] = (st, tuple(sorted(parsed.keys())),
                     tuple(sorted((parsed.get("outcomes") or {}).values())))
distinct = set(shapes.values())
held_check("Dd every refusal cause answers with the same shape",
           len(distinct) == 1, str(shapes))

# D-e. 10.35's major check is new code in front of every sync route. If it runs
# AFTER authorization it is a fresh existence oracle on routes C-2 made
# uniform; if it discloses more for a real project than a fictional one, same
# thing one field down.
stale = {**ENVELOPE, "schema_version": 1, "schema_major": SCHEMA_MAJOR - 1}
r_real = call("/sync/pull", {**stale, "project_id": victim_project,
                             "device_id": attacker["device"], "cursor": 0,
                             "batch_size": 500}, attacker["token"])
r_fake = call("/sync/pull", {**stale, "project_id": str(uuid.uuid4()),
                             "device_id": attacker["device"], "cursor": 0,
                             "batch_size": 500}, attacker["token"])
held_check("De the schema-major refusal is uniform across project existence",
           r_real == r_fake, f"real={r_real[0]} {r_real[1][:60]} "
                             f"fake={r_fake[0]} {r_fake[1][:60]}")

# D-f. And it must refuse BEFORE applying anything, or a stale client writes
# rows on its way to being told it cannot.
stale_obs = observation(f"stale-{RUN}", own, attacker["uid"], notes="STALE-MAJOR")
s, b = call("/sync/push", {**stale, "project_id": own,
                           "device_id": attacker["device"],
                           "rows": {"Observations": [stale_obs]}},
            attacker["token"])
s2, b2 = call("/sync/pull", {**ENVELOPE, "project_id": own,
                             "device_id": attacker["device"], "cursor": 0,
                             "batch_size": 500}, attacker["token"])
held_check("Df a refused-major push applies no rows",
           s == 409 and "STALE-MAJOR" not in b2, f"push={s}")

# D-g. E-2's fix (10.32), re-verified the way E-2 was found — by rendering the
# override the README tells an operator to run, with the LAN opt-in already
# taken. Reading the file is not the check; `docker compose config` is.
cfg = subprocess.run(
    ["docker", "compose", "-f", "docker-compose.yml", "-f",
     "docker-compose.e2e.yml", "config"],
    cwd=ROOT, capture_output=True, text=True,
    env={**os.environ, "SERVER_PUBLISH_ADDRESS": "0.0.0.0"})
published = re.findall(r"host_ip:\s*(\S+)", cfg.stdout)
held_check("Dg the e2e override stays on loopback even with the LAN opt-in set",
           published != [] and all(a == "127.0.0.1" for a in published),
           f"host_ip -> {published}")

# D-h. Recorded non-blocking at the last gate and untouched since: `revision`
# is unbounded, so any row the caller may write can be pinned at 2^63-1 and
# never legitimately updated again. Re-confirm rather than assume.
own = str(uuid.uuid4())
publish(attacker, own)
pinned = observation(f"pin-{RUN}", own, attacker["uid"])
pinned["revision"] = 2 ** 63 - 1
s, b = call("/sync/push", {**ENVELOPE, "project_id": own,
                           "device_id": attacker["device"],
                           "rows": {"Observations": [pinned]}}, attacker["token"])
pin_outcome = json.loads(b).get("outcomes", {}).get(
    outcome_key("Observations", pinned)) if s == 200 else None
loser = observation(f"pin-{RUN}", own, attacker["uid"], notes="LATER EDIT")
loser["revision"] = 2
s2, b2 = call("/sync/push", {**ENVELOPE, "project_id": own,
                             "device_id": attacker["device"],
                             "rows": {"Observations": [loser]}}, attacker["token"])
s3, b3 = call("/sync/pull", {**ENVELOPE, "project_id": own,
                             "device_id": attacker["device"], "cursor": 0,
                             "batch_size": 500}, attacker["token"])
held_check("Dh a row cannot be pinned at the maximum revision",
           pin_outcome != "inserted" or "LATER EDIT" in b3,
           f"insert at 2^63-1 -> {pin_outcome}; later edit applied: "
           f"{'LATER EDIT' in b3}")

print("\nE. New attacks, aimed at ground no previous group covered")

# E-a. 10.35 put a version gate in front of every sync route, and group D
# checked the case where the caller sends a major that is too OLD. The
# interesting cases for a gate are the ones a stale client never sends: the
# field missing entirely, the right value with the wrong type, and a major from
# the future. Any of those defaulting to permissive would put the whole
# project-scoped-key remediation behind a field an attacker chooses.
own_e = str(uuid.uuid4())
publish(attacker, own_e)
probe_obs = observation(f"env-{RUN}", own_e, attacker["uid"], notes="ENVELOPE-PROBE")
bad_envelopes = {
    "no schema_major": {k: v for k, v in ENVELOPE.items() if k != "schema_major"},
    "schema_major as a string": {**ENVELOPE, "schema_major": str(SCHEMA_MAJOR)},
    "a major from the future": {**ENVELOPE, "schema_major": SCHEMA_MAJOR + 1},
    "no envelope name": {k: v for k, v in ENVELOPE.items() if k != "envelope"},
}
env_results = {}
for label, env in bad_envelopes.items():
    s, b = call("/sync/push", {**env, "project_id": own_e,
                               "device_id": attacker["device"],
                               "rows": {"Observations": [probe_obs]}},
                attacker["token"])
    env_results[label] = (s, json.loads(b or "{}").get("outcomes"))
s_after, b_after = call("/sync/pull", {**ENVELOPE, "project_id": own_e,
                                       "device_id": attacker["device"],
                                       "cursor": 0, "batch_size": 500},
                        attacker["token"])
held_check("Ea a malformed or future envelope is refused, never defaulted",
           all(s != 200 for s, _ in env_results.values())
           and "ENVELOPE-PROBE" not in b_after,
           f"{ {k: v[0] for k, v in env_results.items()} }; "
           f"row landed anyway: {'ENVELOPE-PROBE' in b_after}")

# And the same refusals must not become the oracle C-2 closed: a fabricated
# project and a real foreign one have to answer identically on each of them.
env_uniform = {}


def error_shape(answer):
    """Status plus the error body with the per-request trace id removed.

    Comparing raw bodies here made this check fail on the `500` case for the
    only reason a `500` body ever differs — its trace id, which is per-request
    by design and is what §7.6 F10 wants preserved. The gate's own first draft
    of this check reported a disclosure that was not one; a check that cannot
    tell an oracle from a trace id is not a check (task 10.40's rule).
    """
    status, body = answer
    try:
        parsed = json.loads(body or "{}")
    except ValueError:
        return status, body
    return status, {k: v for k, v in parsed.items() if k != "trace_id"}


for label, env in bad_envelopes.items():
    r_real = call("/sync/pull", {**env, "project_id": victim_project,
                                 "device_id": attacker["device"], "cursor": 0,
                                 "batch_size": 10}, attacker["token"])
    r_fake = call("/sync/pull", {**env, "project_id": str(uuid.uuid4()),
                                 "device_id": attacker["device"], "cursor": 0,
                                 "batch_size": 10}, attacker["token"])
    env_uniform[label] = (error_shape(r_real) == error_shape(r_fake),
                          r_real[0], r_fake[0])
held_check("Ea the malformed-envelope refusals disclose no project existence",
           all(same for same, _, _ in env_uniform.values()),
           "; ".join(f"{k}: real={v[1]} fake={v[2]}" for k, v in env_uniform.items()))

# ...but one of those four is not the refusal it should be. Three malformed
# envelopes draw a `400 malformed_envelope`; the right value with the wrong
# JSON type draws a `500`. Same family as §9.5.1's G-5 and §7.6's F10, on the
# version gate 10.35 put in FRONT of authorization, which makes it the first
# thing an unauthenticated-adjacent caller can reach on every sync route.
held_check("Ea2 a wrongly-typed envelope field is a 400, not a 500",
           env_results["schema_major as a string"][0] != 500,
           f"schema_major=\"{SCHEMA_MAJOR}\" (string) -> "
           f"{env_results['schema_major as a string'][0]}")

# E-b. §9.5 (G-4) reasoned that of the three globally-keyed tables left after
# 10.35, `Users` is covered by §4.17's naming invariant and `Tags` by 10.29's
# reachability rule — so only `User_Emails` answers. `Users` has a probe (Cc)
# and `User_Emails` has one (Dc). `Tags` had none: the claim that covers it was
# derived by reading, which is the exact provenance G-4 exists to complain
# about. This is that probe.
victim_tag = str(uuid.uuid4())
s, b = call("/sync/push", {**ENVELOPE, "project_id": victim_project,
                           "device_id": victim["device"],
                           "rows": {"Tags": [{
                               "tag_id": victim_tag, "frequency_mhz": 150.1,
                               "tag_name": "Victim", "date_put_on": T,
                               "status": "active", "color_hex": "#FF0000",
                               "created_at": T, "updated_at": T, "revision": 1,
                               "last_modified_by": victim["uid"],
                               "origin_device_id": "device-x"}]}},
            victim["token"])
seeded_tag = s == 200 and "inserted" in b
own_e2 = str(uuid.uuid4())
publish(attacker, own_e2)


def claim_tag(tid):
    s, b = call("/sync/push", {**ENVELOPE, "project_id": own_e2,
                               "device_id": attacker["device"],
                               "rows": {"Tags": [{
                                   "tag_id": tid, "frequency_mhz": 151.2,
                                   "tag_name": "Mine", "date_put_on": T,
                                   "status": "active", "color_hex": "#00FF00",
                                   "created_at": T, "updated_at": T,
                                   "revision": 1,
                                   "last_modified_by": attacker["uid"],
                                   "origin_device_id": "device-x"}]}},
                attacker["token"])
    return s, sorted((json.loads(b or "{}").get("outcomes") or {}).values())


taken_tag = claim_tag(victim_tag)
free_tag = claim_tag(str(uuid.uuid4()))
held_check("Eb a Tags key another project holds is indistinguishable from a free one",
           seeded_tag and taken_tag == free_tag,
           f"seeded={int(seeded_tag)} taken={taken_tag} free={free_tag}")

# E-c. `rows` is a caller-supplied map of table name to row list. Every group
# so far has attacked the *contents*. Nobody has attacked the *keys*: the
# server's own auth and bookkeeping tables are in the same database, and
# `auth_audit_log` is the one C-5 exists to fill. A caller who could name it
# here could forge or flood the record of their own denials.
forbidden_before = sql("SELECT count(*) FROM auth_audit_log")[0]
forbidden = {}
for table in ("auth_audit_log", "sync_cursors", "Sync_Held_Rows",
              "pg_catalog.pg_tables", "Observations; DROP TABLE Users--"):
    s, b = call("/sync/push", {**ENVELOPE, "project_id": own_e,
                               "device_id": attacker["device"],
                               "rows": {table: [{"id": "1", "event": "forged",
                                                 "outcome": "forged"}]}},
                attacker["token"])
    parsed = json.loads(b or "{}")
    forbidden[table] = (s, parsed.get("applied"), parsed.get("outcomes"))
forbidden_after = sql("SELECT count(*) FROM auth_audit_log")[0]
tables_now = sql("SELECT count(*) FROM information_schema.tables "
                 "WHERE table_schema = 'public'")[0]
forged = sql("SELECT count(*) FROM auth_audit_log WHERE outcome = 'forged' "
             "OR event = 'forged'")[0]
# The bar here is what actually matters: nothing written, nothing forged, no
# table dropped, and nothing counted as applied. The first draft of this check
# demanded a non-200 status and reported a finding on a server that had in fact
# ignored every one of these — the same vacuous-check mistake §9.3 recorded,
# in the opposite direction.
held_check("Ec naming the server's own tables in `rows` writes nothing",
           int(forged) == 0
           and int(forbidden_after) == int(forbidden_before)
           and int(tables_now) > 10
           and all(applied in (0, None) for _, applied, _ in forbidden.values()),
           f"applied -> { {k: v[1] for k, v in forbidden.items()} }; forged "
           f"rows {forged}; audit rows {forbidden_before} -> "
           f"{forbidden_after}; {tables_now} tables intact")

# Nothing is written, but nothing is *said* either: every one of those answers
# is `200`, `applied: 0`, `outcomes: {}`. A caller learns only silence. 10.18
# decided unknown *columns* are preserved rather than dropped; an unknown
# *table* is dropped without a word, and the protocol has an `invalid` outcome
# (`HeldRowReason.forOutcome`) that this path never produces — the same gap
# §9.5.1's G-5 found from the other side. The app cannot reach it today; a
# newer client against an older server is exactly what would.
held_check("Ec2 an unknown table name is answered, not silently dropped",
           all(o not in ({}, None) for _, _, o in forbidden.values()),
           f"outcomes -> { {k: v[2] for k, v in forbidden.items()} }")

# E-d. Degenerate paging values on a route the caller IS authorized for. 10.33
# fixed a client-side stranding bug below the watermark; the server half of
# that arithmetic has never been probed with values the client cannot produce.
# A 500 here would be G-5's family on the read path, and a full dump for
# batch_size <= 0 would be the batch limit failing open.
paging = {}
for label, extra in {
    "batch_size 0": {"batch_size": 0},
    "batch_size -1": {"batch_size": -1},
    "batch_size 2**40": {"batch_size": 2 ** 40},
    "cursor -1": {"cursor": -1, "batch_size": 10},
    "cursor 2**63-1": {"cursor": 2 ** 63 - 1, "batch_size": 10},
}.items():
    body = {**ENVELOPE, "project_id": own_e, "device_id": attacker["device"],
            "cursor": 0, "batch_size": 10, **extra}
    s, b = call("/sync/pull", body, attacker["token"])
    paging[label] = (s, len(b))
held_check("Ed degenerate paging values are refused or bounded, never a 500",
           all(s != 500 for s, _ in paging.values()),
           f"{ {k: v for k, v in paging.items()} }")

print("\nEnd-of-run liveness re-check")
# `call()` returns (0, repr(e)) rather than raising on a connection-level
# failure (line ~76: "record it, don't crash"), so every *negative* assertion
# in this file — "the secret is not in the body", "the victim's id is not in
# the response", "STALE-MAJOR did not land" — is satisfied by a server that
# quietly stopped answering partway through. `preflight()` only proves the
# server was alive at the *start*. Class-level finding, TriTrack_Security_
# Model.md §10.7.1: a mid-run crash or container restart would otherwise
# silently convert the remainder of this pass into HELDs with no evidence,
# not a genuinely exercised HELD, and this file gave the reader no way to
# tell the two apart. Re-proving liveness at the end closes that gap.
liveness_status, liveness_body = call("/health", None, method="GET")
server_still_alive = liveness_status == 200
print(("  PASS  " if server_still_alive else "  ***FAILED***  ")
      + "the server is still answering after the full adversarial pass"
      + ("" if server_still_alive else f"  got {liveness_status} {liveness_body[:120]}"))

print()
print(f"{len(held)} controls held, {len(failed)} failed, {len(skipped)} skipped "
      f"(not counted as held): {skipped}" if skipped else
      f"{len(held)} controls held, {len(failed)} failed.")
if not server_still_alive:
    print(
        "LIVENESS RE-CHECK FAILED: the server stopped answering before this "
        "run finished. Every HELD result above is unproven — a dead server "
        "satisfies this file's negative assertions the same way a working one "
        "does. Treat this run as inconclusive, not passing, and re-run against "
        "a healthy stack."
    )
    sys.exit(1)

# Task 10.91 (Security Model Sec9.4/9.5/8.4/10.7): the adversarial pass's
# expected-failure set has never been empty since Sec10 — a plain "any
# failure is red" rule stops the gate on findings four consecutive gates
# already read, confirmed, and accepted. Compare against the committed
# baseline instead of against zero. See scripts/gate_c_baseline.py for what
# that comparison actually enforces (an unbaselined failure, an invalid
# citation, and a baselined check that now passes are each red on their own,
# independent of everything above).
try:
    baseline_entries = load_baseline()
    validate_baseline(baseline_entries)
    expected_check_count = load_expected_check_count()
except BaselineError as exc:
    print(f"\nBASELINE INVALID: {exc}")
    sys.exit(1)
baseline_ok, baseline_problems = evaluate(
    held, failed, baseline_entries, skipped=skipped,
    expected_check_count=expected_check_count)
if not baseline_ok:
    print("\nBASELINE CHECK FAILED:")
    for p in baseline_problems:
        print("  - " + p)
        # Task 11.69: and what it measured, on the next line, so the five lines
        # CI keeps are a diagnosis rather than a name.
        for name, detail in check_details.items():
            if repr(name) in p or name in p:
                print("    measured: " + detail)
                break
    sys.exit(1)
if failed:
    print(f"\n{len(failed)} failure(s), all baselined and accounted for "
          f"(scripts/gate_c_adversarial_baseline.json): " + "; ".join(failed))

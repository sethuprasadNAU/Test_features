# gate-instrument: none - the shared wire helper every wire-speaking instrument imports; it checks nothing on its own.
"""Shared wire constants for the `scripts/*.py` gate tools.

**Why this file exists.** Every gate script speaks the sync protocol directly
over raw HTTP — that is the whole point of them, since the findings they guard
were invisible to in-process tests. But speaking the wire directly means each
one carried its own copy of the protocol envelope and its own idea of how a row
is keyed, and task 10.35's `schemaMajor` bump invalidated all of them at once:
`verify_d1_per_row_oracle.py` started failing with a `409` and was updated,
while `verify_c1`, `verify_c2`, `verify_c5` and `gate_c_adversarial_pass` sat at
`schema_major: 1` unnoticed until the next gate run tried to use them. A gate
tool that refuses to run is loud; a *set* of them that rots quietly between
gates is how a gate ends up reporting on a server it never reached.

The fix is not another hardcoded constant in one place instead of five. These
values are **parsed out of the Dart source that defines them**, so a future bump
updates the tools by definition:

  - `latestSchemaVersion` / `schemaMajorVersion` from `schema_constants.dart`
  - `syncProtocolVersion` from `sync_protocol.dart`
  - each table's primary key from `sync_tables.dart`

Parsing Dart with regexes is normally a bad trade. It is the right one here:
the alternative is a number typed twice, and this file fails loudly (raises at
import) if the shape it expects is gone, rather than falling back to a stale
default — which is exactly the failure it exists to prevent.
"""
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SYNC_SRC = os.path.join(ROOT, "packages", "tritrack_sync", "lib", "src")
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
from port_holder import refuse_unless_stack, compose_project_of  # noqa: E402


def _read(name):
    with open(os.path.join(_SYNC_SRC, name)) as f:
        return f.read()


def _const_int(source, name, where):
    match = re.search(r"const\s+int\s+%s\s*=\s*(\d+)\s*;" % re.escape(name), source)
    if not match:
        raise RuntimeError(
            f"Could not find `const int {name}` in {where}. The gate scripts "
            f"derive the wire envelope from that declaration so they cannot go "
            f"stale across a schema bump — if it moved or was renamed, update "
            f"scripts/gate_wire.py rather than hardcoding a number back into "
            f"the scripts."
        )
    return int(match.group(1))


_SCHEMA_CONSTANTS = _read("schema_constants.dart")
_SYNC_PROTOCOL = _read("sync_protocol.dart")

SCHEMA_VERSION = _const_int(
    _SCHEMA_CONSTANTS, "latestSchemaVersion", "schema_constants.dart"
)
SCHEMA_MAJOR = _const_int(
    _SCHEMA_CONSTANTS, "schemaMajorVersion", "schema_constants.dart"
)
PROTOCOL_VERSION = _const_int(
    _SYNC_PROTOCOL, "syncProtocolVersion", "sync_protocol.dart"
)

#: The envelope every `/sync/*` request carries. Spread into a request body:
#: ``{**ENVELOPE, "project_id": pid, ...}``.
ENVELOPE = {
    "envelope": "tritrack_sync",
    "protocol_version": PROTOCOL_VERSION,
    "schema_version": SCHEMA_VERSION,
    "schema_major": SCHEMA_MAJOR,
}


def _parse_primary_keys():
    """`{table name: [key column, ...]}`, from `sync_tables.dart`.

    Task 10.35 made six tables composite (`(<id>, project_id)`), which changed
    the string a push outcome is reported under — `Observations/<id>` became
    `Observations/<id>/<project_id>`. A script still building the old key reads
    `None` out of the outcomes map for every row, which looks exactly like a
    control holding.
    """
    source = _read("sync_tables.dart")
    names = dict(
        re.findall(
            r"static\s+const\s+(\w+)\s*=\s*'([^']+)'\s*;", _SCHEMA_CONSTANTS
        )
    )
    keys = {}
    for const_name, key_list in re.findall(
        r"name:\s*Tables\.(\w+),\s*primaryKey:\s*\[([^\]]*)\]", source
    ):
        table = names.get(const_name)
        if table is None:
            raise RuntimeError(
                f"sync_tables.dart names Tables.{const_name}, which is not "
                f"declared in schema_constants.dart."
            )
        keys[table] = re.findall(r"'([^']+)'", key_list)
    # The expected count is counted from the file, not typed here. This check
    # used to read `if len(keys) < 11`, which is the hand-carried number this
    # module exists to abolish: it was written when there were eleven tables,
    # task 11.7 added a twelfth, and the bound went on passing while saying
    # nothing about whether the twelfth had been parsed. Counting the `name:
    # Tables.X` declarations and requiring the key parse to match every one of
    # them catches a per-entry parse failure, which is the failure that
    # actually happens when the declaration shape drifts.
    declared = re.findall(r"name:\s*Tables\.(\w+)", source)
    if not declared:
        raise RuntimeError(
            "Parsed no `name: Tables.X` declarations out of sync_tables.dart "
            "at all. The declaration shape changed — fix this parser rather "
            "than letting the gate scripts run against an empty table list."
        )
    if len(keys) != len(declared):
        missed = sorted(set(names.get(d, d) for d in declared) - set(keys))
        raise RuntimeError(
            f"sync_tables.dart declares {len(declared)} tables but only "
            f"{len(keys)} primary keys parsed; missed {missed}. A table whose "
            f"key does not parse is invisible to every gate script that "
            f"derives its coverage from this map — fix the parser."
        )
    return keys


PRIMARY_KEYS = _parse_primary_keys()


def _parse_mutation_rules():
    """`{table name: rule name}`, from `mutation_rules.dart`.

    **Derived rather than listed, for task 11.24's stated reason.** The
    row-naming invariant's affected set is *"every table whose rule names an
    author"* — not a list of table names. Task 11.9 named two such tables,
    task 11.23 read the code and found a third (`Non_Detections`), and a
    thirteenth table landed between the two. An instrument that carried its own
    list would have measured the same two forever and reported a clean sweep
    while the third was open. Parsing `tableMutationRules` means the next table
    is covered the day its rule is declared.
    """
    source = _read("mutation_rules.dart")
    names = dict(
        re.findall(
            r"static\s+const\s+(\w+)\s*=\s*'([^']+)'\s*;", _SCHEMA_CONSTANTS
        )
    )
    body = re.search(
        r"const\s+Map<String,\s*MutationRule>\s+tableMutationRules\s*=\s*\{"
        r"(.*?)\n\};",
        source,
        re.S,
    )
    if not body:
        raise RuntimeError(
            "Could not find `const Map<String, MutationRule> "
            "tableMutationRules` in mutation_rules.dart. The gate scripts "
            "derive the row-naming invariant's affected table set from that "
            "declaration precisely so it cannot go stale — fix this parser "
            "rather than hardcoding a table list back into a script."
        )
    rules = {}
    for const_name, rule in re.findall(
        r"Tables\.(\w+)\s*:\s*MutationRule\.(\w+)", body.group(1)
    ):
        table = names.get(const_name)
        if table is None:
            raise RuntimeError(
                f"mutation_rules.dart names Tables.{const_name}, which is not "
                f"declared in schema_constants.dart."
            )
        rules[table] = rule
    missing = sorted(set(PRIMARY_KEYS) - set(rules))
    if missing:
        raise RuntimeError(
            f"No MutationRule parsed for {missing}. Dart's own "
            f"`assertEveryTableHasAMutationRule` would fail for a table with "
            f"no rule, so this is a parser defect, not a missing decision — "
            f"and a table invisible here is a table no instrument probes."
        )
    return rules


MUTATION_RULES = _parse_mutation_rules()

#: `MutationRule.namesRowAuthor` — the rules whose row names a user the rule
#: itself permits. Mirrored from `mutation_rules.dart`'s getter of the same
#: name; the assertion below is what stops the mirror drifting.
AUTHOR_NAMING_RULES = {"author", "authorOrOwner"}

#: The column each author-naming rule anchors to, from the enum's constructor
#: argument. Both spell it `user_id` today; read rather than assumed.
_RULE_COLUMNS = dict(
    re.findall(r"\n  (\w+)\('([^']+)'\)", _read("mutation_rules.dart"))
)


def author_naming_tables():
    """Tables whose rule names an author — the row-naming fix's affected set.

    Returns `{table name: author column}`. This is the derivation, and it is
    the whole point: callers must not write a table list of their own.
    """
    missing = AUTHOR_NAMING_RULES - set(_RULE_COLUMNS)
    if missing:
        raise RuntimeError(
            f"MutationRule.{sorted(missing)} no longer declares a governing "
            f"column in mutation_rules.dart. Fix this parser."
        )
    return {
        table: _RULE_COLUMNS[rule]
        for table, rule in MUTATION_RULES.items()
        if rule in AUTHOR_NAMING_RULES
    }


def row_key(table, row):
    """The key a push outcome for `row` is reported under.

    Mirrors the server's `SyncService._rowKey` and the app's `syncRowKey`:
    primary-key columns in declaration order, `/`-joined, or `?` for a row with
    no usable key.
    """
    try:
        columns = PRIMARY_KEYS[table]
    except KeyError:
        raise RuntimeError(f"{table} is not a sync table.") from None
    parts = []
    for column in columns:
        value = row.get(column)
        if not isinstance(value, str) or not value:
            return "?"
        parts.append(value)
    return "/".join(parts)


def outcome_key(table, row):
    """The full `outcomes` map key for `row`: `<table>/<row key>`."""
    return f"{table}/{row_key(table, row)}"


def outcome_for(body, table, row):
    """The outcome a push reported for `row`, or None if it reported none.

    Returning None for a row the server *did* answer for is the one way this
    helper can lie, and it lies in the direction of "the control held" — so
    every caller should assert on a specific outcome string, never on
    `!= "inserted"`.
    """
    return (body.get("outcomes") or {}).get(outcome_key(table, row))


def preflight(base=None, link_dir=None):
    """Reachability + version-handshake self-check, run before anything else.

    Task 10.40: four of five gate instruments carried a stale `schema_major`
    for a full day after 10.35's bump, so every request they sent drew a `409`
    they never inspected, and each script read the resulting empty response as
    "control held" — a gate reporting on a server it never reached. Deriving
    `ENVELOPE` from source (above) closes the staleness itself, but a script
    that only asserts `status == 200` deep inside its own setup can still run
    dozens of lines of adversarial logic against a server it never actually
    talked to before the first assertion happens to trip. This runs a real
    sign-in and a real `/sync/pull` **first**, so a broken handshake aborts
    before any finding-specific logic executes, with the server's own error
    code in the message rather than a bare `AssertionError` a reader has to
    trace back.

    Every caller of this module should invoke it before doing anything else.
    Raises `SystemExit` with a clear, specific reason — never returns falsy.

    **Corrected by the third Gate C re-run (task 10.25, 2026-08-14, finding
    H-2.)** As first written, the handshake step asserted `status == 200` on a
    `/sync/pull` for a freshly minted account against a random `project_id`.
    The designed answer to that request is `403 forbidden` — §4.13's uniform
    denial, which is precisely what C-2's remediation made it — so the
    self-check aborted all five wire-speaking instruments before any of them
    ran a single control. A gate whose every tool refuses to start is not a
    safer gate than one whose tools are stale; it is the same failure with the
    opposite sign, and it was never caught because the check was added without
    being run against a live server.

    What the handshake actually proves is that the server *understood the
    envelope*, and both `200` and `403` prove that: 10.35's major check runs in
    front of authorization (§9.3), so a version mismatch is a `409` and never
    reaches the authorization decision. Accepting the denial therefore keeps
    the entire point of the check — a stale `schema_major` still aborts — while
    letting the instruments run.
    """
    base = base or os.environ.get("BASE", "http://localhost:8080")
    link_dir = link_dir or os.environ.get("LINK_DIR", ".e2e_magic_links")

    # **Task 11.312, same guard as the four `verify_*_broken_control.py`
    # drills (task 11.310) — reused here, not rebuilt.** Every one of the
    # eleven wire-speaking instruments that call [preflight] sends its full
    # attack suite to `base` on the next line after this one. On a CI runner
    # that is always the throwaway `tritrack-gate` stack this project's own
    # `gate_smoke_test.sh` just built, which is why nobody noticed: on a
    # machine that also serves TriTrack — the Ubuntu VM — a person typing
    # `python3 scripts/verify_c1_row_naming.py` by hand attacks whatever
    # already holds port 8080, and the drills' own port check only guards the
    # four scripts that call it directly, not the eleven scripts underneath
    # them nor a person running one alone.
    #
    # `COMPOSE`, when set, names the exact `docker compose ...` line the
    # caller would use (or just did use) to build the stack at `base` — the
    # three `_broken_control.py` drills that drive one of these eleven
    # instruments against their own throwaway BROKEN-phase stacks set it to
    # that stack's own project, never `tritrack-gate`, so the project checked
    # here is read from that line rather than assumed. With no `COMPOSE` —
    # a person running this file alone, or `gate_smoke_test.sh` itself, whose
    # own shell never exports it — the only stack anybody means is
    # `tritrack-gate`.
    compose = os.environ.get("COMPOSE")
    if compose:
        project = compose_project_of(compose)
        if project is None:
            raise SystemExit(
                f"PREFLIGHT ABORT: COMPOSE is set but names no project "
                f"(`{compose}` has no -p) — compose would fall back to the "
                f"directory's default project, which in a clone that also "
                f"serves TriTrack is the real deployment's. Refusing to "
                f"attack a server nobody has named."
            )
    else:
        project = "tritrack-gate"
    refuse_unless_stack(base, project, compose=compose,
                        before="running this instrument's controls against it")

    def parse_body(path, status, raw):
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            # Task 10.90: this used to be `json.loads(raw or b"{}")` with no
            # guard, so a non-empty, non-JSON body (exactly what a 404 from
            # shelf_router's own default handler sends: plain text, not JSON)
            # raised a bare `JSONDecodeError` here and the caller saw a
            # traceback instead of a diagnosis. A 404 on an auth route is not
            # "the route responded oddly" — `bin/server.dart` only mounts the
            # auth router `if (withAuthService != null)`, i.e. only once a
            # database connection has been opened, so a 404 here means the
            # server itself logged "No database available; serving /health
            # only" and skipped auth entirely. Say that, not a stack trace.
            snippet = raw[:200].decode("utf-8", errors="replace")
            hint = (
                "A 404 on an auth route almost always means the server has "
                "no database connection — bin/server.dart only mounts auth "
                "routes once Postgres is reachable. ASK THE SERVER RATHER "
                "THAN GUESSING: `curl -i <base>/ready` answers 503 with "
                "{\"degraded\":[\"database\"]} for exactly this state and "
                "200 otherwise (task 11.128). /health answers 200 either way "
                "and cannot tell you. Then check whether the gate server's "
                "Postgres volume is stale or its credentials don't match the "
                "current .env."
                if status == 404
                else "The server is reachable but its response is not the "
                "JSON envelope this instrument expects."
            )
            raise SystemExit(
                f"PREFLIGHT ABORT: {path} returned {status} with a non-JSON "
                f"body ({snippet!r}). {hint}"
            ) from None

    def call(path, body):
        req = urllib.request.Request(
            base + path,
            data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, parse_body(path, r.status, r.read())
        except urllib.error.HTTPError as e:
            return e.code, parse_body(path, e.code, e.read())
        except urllib.error.URLError as e:
            raise SystemExit(
                f"PREFLIGHT ABORT: cannot reach the server at {base} ({e.reason}). "
                f"Is the e2e stack up? See the README's \"End-to-end integration "
                f"suite\". Refusing to run — a script that cannot reach the "
                f"server has not tested anything."
            ) from None

    email = f"gate-preflight-{uuid.uuid4().hex[:8]}@example.invalid"
    status, body = call("/auth/magic-link", {"email": email})
    if status != 202:
        raise SystemExit(
            f"PREFLIGHT ABORT: /auth/magic-link returned {status} ({body}), "
            f"not 202. The server is reachable but not behaving as expected — "
            f"aborting rather than continuing against a server in an unknown "
            f"state."
        )
    path = os.path.join(link_dir, email + ".link")
    for _ in range(50):
        if os.path.exists(path):
            break
        time.sleep(0.1)
    else:
        # Task 11.69, second pass. This branch used to say only "no link
        # appeared", and on the 2026-08-30 CI run that sentence was all eleven
        # wire-speaking instruments had to offer. The cause was one `stat`
        # away: `.e2e_magic_links` does not exist in a clean checkout (it is
        # gitignored — it holds live credentials), Docker created the missing
        # bind-mount source as ROOT, and the server, correctly running as the
        # invoking user, could not write into it. `/auth/magic-link` still
        # answered 202, because `auth_routes.dart` swallows a delivery failure
        # on purpose so a caller cannot tell a working address from a broken
        # mailer (§4.5). So the only place the truth was visible from was here.
        #
        # The sibling branch below — the link exists but cannot be read — got
        # a full diagnosis in this task's first pass. This one did not, and the
        # fix moved the failure one step earlier into exactly the branch with
        # nothing to say. Both branches now answer the same question: **who
        # owns this directory, and who is the server?**
        detail = ""
        try:
            st = os.stat(link_dir)
            writable = os.access(link_dir, os.W_OK | os.X_OK)
            detail = (
                f" {link_dir} is owned by uid {st.st_uid}, mode "
                f"{oct(st.st_mode & 0o777)}; this process is uid "
                f"{os.getuid()} and can{'' if writable else 'NOT'} write into "
                f"it."
            )
            if st.st_uid == 0 and os.getuid() != 0:
                detail += (
                    " A root-owned link directory is what Docker leaves behind"
                    " when the bind-mount source did not exist and the stack"
                    " was brought up anyway — the server runs as the invoking"
                    " user (TRITRACK_DEV_UID) and cannot create a file in it,"
                    " and the 202 above tells you nothing because the server"
                    " must answer identically whether delivery worked or not"
                    " (§4.5). Fix the owner:"
                    f" sudo chown -R $(id -u):$(id -g) {link_dir}"
                )
        except OSError as e:
            detail = (
                f" {link_dir} could not even be inspected ({e.strerror}) —"
                f" it may not exist at all, in which case the stack was"
                f" brought up from a different working directory than this"
                f" instrument is running in."
            )
        raise SystemExit(
            f"PREFLIGHT ABORT: no magic link appeared at {path} within 5s, and "
            f"/auth/magic-link answered 202 — which it does whether or not the "
            f"link was written.{detail} Bring the stack up through a script "
            f"that sources scripts/lib/host_user.sh (scripts/gate_smoke_test.sh, "
            f"scripts/run_e2e_tests.sh); it creates this directory owned by the "
            f"user the server runs as. Aborting — the auth flow this instrument "
            f"depends on has not been proven to work."
        )
    # Task 11.69. The link exists; being unable to READ it is a different
    # problem from it never arriving, and it deserves its own sentence rather
    # than an errno. `FileEmailSender` writes mode 600 on purpose, and the
    # container writes it as whatever user the stack runs the server as — so
    # on a Linux host, a stack brought up without TRITRACK_DEV_UID lands a
    # `root:root 0600` file that nobody here can open. Docker Desktop remaps
    # that ownership, which is why this was invisible until CI first ran on
    # Linux and eleven instruments died on `Errno 13` with no explanation.
    try:
        contents = open(path).read()
    except PermissionError as e:
        owner = ""
        try:
            st = os.stat(path)
            owner = (
                f" It is owned by uid {st.st_uid}, mode "
                f"{oct(st.st_mode & 0o777)}; this process is uid {os.getuid()}."
            )
        except OSError:
            pass
        raise SystemExit(
            f"PREFLIGHT ABORT: the magic link at {path} exists but cannot be "
            f"read ({e.strerror}).{owner} The link is written mode 600 on "
            f"purpose — it is a live sign-in credential — so what has to match "
            f"is the OWNER. Bring the stack up through a script that sources "
            f"scripts/lib/host_user.sh (scripts/gate_smoke_test.sh, "
            f"scripts/run_e2e_tests.sh), or export TRITRACK_DEV_UID and "
            f"TRITRACK_DEV_GID yourself before `docker compose up`. Aborting "
            f"rather than reporting controls that never ran."
        )
    token = contents.split("token=")[1].strip()
    device = "preflight-" + uuid.uuid4().hex[:8]
    status, body = call("/auth/redeem", {"token": token, "device_id": device})
    if status != 200:
        raise SystemExit(
            f"PREFLIGHT ABORT: /auth/redeem returned {status} ({body}), not "
            f"200. Aborting before any finding-specific logic runs."
        )
    session_token = body["session_token"]

    req = urllib.request.Request(
        base + "/sync/pull",
        data=json.dumps({
            **ENVELOPE, "project_id": str(uuid.uuid4()), "device_id": device,
            "cursor": 0, "batch_size": 1,
        }).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + session_token,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            status, body = r.status, parse_body("/sync/pull", r.status, r.read())
    except urllib.error.HTTPError as e:
        status, body = e.code, parse_body("/sync/pull", e.code, e.read())

    # 200 (accepted) and 403 (§4.13's uniform denial for a project this caller
    # has no relationship to) both prove the envelope was understood, because
    # the major-version check runs in front of authorization. A mismatch is a
    # 409 and still aborts, which is the whole reason this exists.
    if status not in (200, 403):
        raise SystemExit(
            f"PREFLIGHT ABORT: the version handshake failed — /sync/pull with "
            f"this script's envelope ({ENVELOPE}) returned {status} ({body}) "
            f"instead of 200 or 403. This is the exact failure mode task 10.40 exists "
            f"to catch: every check downstream of this point would have been "
            f"reading an empty response as \"control held\" on a server this "
            f"instrument never actually reached. Update scripts/gate_wire.py's "
            f"parsed constants (or the server) so client and server agree, "
            f"then re-run."
        )


# ------------------------------------------------------- the join-code fixture
#
# **Task 11.85.** Task 11.81 deleted the per-address invitation routes and four
# instruments went red on the same line — `404` on `POST /projects/<id>/invites`
# — because each of them built its team by inviting somebody. None of those
# failures was a finding: they are the class named *the attack corpus cannot
# reach the check*, an instrument that can no longer get to the thing it tests.
#
# **The fixture flow lives here, once, rather than in each of the four.** Four
# copies of "turn joining on, take the code, request, approve" is how they come
# to disagree about what a fixture is, and the previous four copies of
# "invite, redeem" are exactly what made this a four-file repair instead of a
# one-file one. Task 10.66's standing rule: fix the class, not the instance.
#
# Every function here takes the caller's own `call(path, body, token, method)`
# so an instrument keeps its own wire helper, its own timeouts and its own
# error shaping. Nothing here asserts; callers assert, because what a failed
# fixture step should *say* differs per instrument.


#: Bounds parsed out of the server's own join code, for the same reason
#: `SCHEMA_MAJOR` is: a number typed twice is a number that drifts. An
#: instrument that reports "nothing prunes decided requests, and the only
#: bound is N rows" must read N from the source that enforces it.
def _server_const(name):
    path = os.path.join(ROOT, "server", "lib", "src", "projects",
                        "join_service.dart")
    with open(path) as f:
        source = f.read()
    match = re.search(rf"const int {name} = (\d+);", source)
    if match is None:
        raise RuntimeError(
            f"gate_wire.py could not find `const int {name}` in "
            f"join_service.dart. It was renamed or moved; fix this parse "
            f"rather than hardcoding the number, or the instruments will "
            f"report a bound the server no longer has."
        )
    return int(match.group(1))


MAX_JOIN_REQUESTS_RETURNED = _server_const("maxJoinRequestsReturned")
DEFAULT_TEAM_SIZE_LIMIT = _server_const("defaultTeamSizeLimit")


def enable_joining(call, owner_token, project_id, team_size_limit=None):
    """Switches joining on for `project_id` and returns its join code.

    One call, not two: `POST /join-settings` answers with the settings it just
    wrote, and switching joining on mints the first code, so the owner never
    has to `GET` afterwards to learn it.

    The code is a live credential for the right to *ask* — never print it, and
    never put it in a report (`CLAUDE.md`'s rule about secret-shaped strings
    applies to a join code).
    """
    body = {"joining_enabled": True}
    if team_size_limit is not None:
        body["team_size_limit"] = team_size_limit
    status, response = call(
        f"/projects/{project_id}/join-settings", body, owner_token
    )
    if status != 200:
        raise AssertionError(
            f"enable joining on {project_id[:8]}: {status} {response}"
        )
    code = response.get("code")
    if not code:
        raise AssertionError(
            f"joining was switched on for {project_id[:8]} and the settings "
            f"came back with no code — `updateSettings` is supposed to mint "
            f"one. Response keys: {sorted(response)}"
        )
    return code


def request_to_join(call, joiner_token, code, claimed_name=None):
    """Asks to join whichever project `code` names. Returns (status, body).

    Deliberately does not assert: half this instrument's probes want the
    refusal, and a helper that raised on one would make them unwritable.
    """
    body = {"code": code}
    if claimed_name is not None:
        body["claimed_name"] = claimed_name
    return call("/projects/join-requests", body, joiner_token)


def join_by_code(call, owner_token, project_id, joiner_token, role,
                 code=None, claimed_name=None):
    """Puts a joiner on `project_id` the way a real crew does.

    Turn joining on (unless the caller already has a `code`), ask, approve.
    Returns `(code, request_id)` so a caller can re-use the code for the next
    person and name the request in a later probe.

    **Two round trips per member, plus one per project** — the same two the
    invitation flow cost (issue, redeem), with the one-off cost of switching
    joining on. What is genuinely new is on the *server* side: approval writes
    a membership row and mints the new member's `Users` row in one
    transaction, where redemption only consumed a code.
    """
    if code is None:
        code = enable_joining(call, owner_token, project_id)
    status, body = request_to_join(call, joiner_token, code, claimed_name)
    if status != 200:
        raise AssertionError(f"join request on {project_id[:8]}: {status} {body}")
    request_id = body["request_id"]
    status, approval = call(
        f"/projects/{project_id}/join-requests/{request_id}/approve",
        {"role": role},
        owner_token,
    )
    if status != 200:
        raise AssertionError(
            f"approve {request_id[:8]} on {project_id[:8]}: {status} {approval}"
        )
    return code, request_id

#!/usr/bin/env python3
# gate-instrument: none - a detection proof, run by .github/workflows/broken-control-check.yml, which is where a deliberately broken server exists.
"""Task 11.49 — watch `verify_11_49_server_reads.py` fail.

Task 10.66's standing criterion, applied to the instrument that gives
inventory entries 27 and 28 their verdicts: **a check that cannot distinguish
success from its own failure is not a check.** A run in which every attack is
refused is exactly what a blind instrument produces, and this project has
shipped three of those.

So this file breaks the server on purpose — three times, each in a different
place — and requires the reads instrument to notice. For each variant it
brings up a **separate compose project** built from a throwaway git worktree,
runs the instrument against it, and asserts that a named set of attacks flips
from `refused` to `ADMITTED`. An attack that stays `refused` against a server
with that control removed is an attack that was never measuring the control.

**The pairing is what makes this evidence.** The same instrument, in the same
run of this script, is also required to come back clean against the unmodified
server. Either half alone proves nothing: a clean run could be blindness, and
a red run could be a broken probe.

Nothing here touches the working tree. The patched source lives in a git
worktree under a temporary directory, removed on the way out.

Usage:

    python3 scripts/verify_11_49_broken_control.py

Takes roughly ten minutes — each variant is a fresh `dart compile exe`. Exits
non-zero if the healthy run is not clean, if any required attack fails to
flip, or if a variant will not build.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Task 11.310: before this drill sends a single request, `port_holder` asks
# Docker which compose project owns the port it is about to attack. See
# `refuse_unless_stack` in main() for why.
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
from port_holder import check_free, check_stack, refuse_unless_stack  # noqa: E402
# Task 11.69. The development overlay this script layers on runs the server as
# the invoking user, so the magic link it writes (mode 600, deliberately — it
# is a live credential) is owned by whoever is reading it. Without these two,
# on a Linux host the file lands `root:root` and every sign-in below fails with
# `Errno 13`. `setdefault` so an outer script that already set them wins. See
# scripts/lib/host_user.sh.
os.environ.setdefault("TRITRACK_DEV_UID", str(os.getuid()))
os.environ.setdefault("TRITRACK_DEV_GID", str(os.getgid()))

HEALTHY_BASE = os.environ.get("BASE", "http://localhost:8080")
HEALTHY_LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")
# Task 11.88: this defaulted to project `tritrack-e2e`, which nothing in
# broken-control-check.yml ever brings up — the workflow brings up
# `tritrack-gate`, exactly like this file's two siblings
# (verify_round8_broken_control.py, verify_11_85_broken_control.py) already
# default to. The healthy run's `psql` exec was therefore reaching for a
# compose project that did not exist, which is what "service postgres is not
# running" meant.
HEALTHY_COMPOSE = os.environ.get(
    "COMPOSE",
    "docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml",
)
BROKEN_PORT = os.environ.get("BROKEN_PORT", "8091")

AUTH_ROUTES = "server/lib/src/auth/auth_routes.dart"
AUTH_SERVICE = "server/lib/src/auth/auth_service.dart"
RATE_LIMITER = "server/lib/src/security/rate_limiter.dart"
SYNC_ROUTES = "server/lib/src/sync/sync_routes.dart"
DISCLOSURE = "server/lib/src/authz/closed_membership_disclosure.dart"


def patch(path, old, new):
    return (path, old, new)


#: Each variant: a human name, the edits that break it, and the attacks the
#: reads instrument **must** report as ADMITTED once they are applied.
#:
#: The required lists are deliberately the attacks whose flip is *certain* from
#: the edit — not everything that happens to change. A probe that flips for a
#: reason nobody predicted is interesting and is printed; a probe that fails to
#: flip when the control it names is gone is a defect in the instrument and
#: fails this run.
VARIANTS = [
    {
        "name": "scope",
        "why": "GET /auth/sessions stops scoping the query to the caller — "
               "the §4.11 rule that a listing is the session's and nobody "
               "else's, deleted.",
        "patches": [
            patch(AUTH_SERVICE,
                  "r'WHERE user_id = $1 AND revoked_at IS NULL '",
                  "r'WHERE (user_id = $1 OR true) AND revoked_at IS NULL '"),
        ],
        "must_flip": [
            "redirecting the listing with a user_id in the query string",
            "redirecting the listing with a user_id and a device_id in the "
            "query string",
            "redirecting the listing with a user_id in a GET body",
            "redirecting the listing with a user_id in an X-User-Id header",
            "redirecting the listing with a user_id in an X-Forwarded-User "
            "header",
            "redirecting the listing with a user_id in a bare user-id header",
            "redirecting the listing with a user_id in a cookie",
            "redirecting the listing with an On-Behalf-Of header",
            "redirecting the listing with a repeated user_id, in case only "
            "the first is read",
            "redirecting the listing with an array-shaped user_id, in case a "
            "list is flattened",
            "Alice's bearer with Bob's token in a cookie",
            "Bob's row appearing in Alice's listing at all",
        ],
    },
    {
        "name": "shape",
        "why": "the row grows two fields it is documented not to have, the "
               "100-row bound and the per-user rate limit stop refusing, and "
               "revoked and expired sessions stop being filtered out.",
        "patches": [
            patch(AUTH_ROUTES,
                  "              'device_id': s.deviceId,\n",
                  "              'device_id': s.deviceId,\n"
                  "              'user_id': result.session.userId,\n"
                  "              'source_address': "
                  "sources.of(request).auditValue,\n"),
            patch(AUTH_SERVICE, "r'LIMIT $4',", "r'LIMIT $4 * 100',"),
            # `OR true` rather than deleting the clauses: a bare
            # `$2 IS NOT NULL` leaves Postgres unable to infer the parameter's
            # type, and the route then answers 500 to everything — which
            # breaks the variant rather than breaking the control it names.
            patch(AUTH_SERVICE,
                  "r'WHERE user_id = $1 AND revoked_at IS NULL '\n"
                  "      r'AND expires_at > $2 AND last_seen_at > $3 '",
                  "r'WHERE user_id = $1 AND (revoked_at IS NULL OR true) '\n"
                  "      r'AND (expires_at > $2 OR true) '\n"
                  "      r'AND (last_seen_at > $3 OR true) '"),
            patch(RATE_LIMITER,
                  "  RateLimitOutcome checkSessionList({required String "
                  "userId}) =>\n"
                  "      _admit('session-list:user:$userId', "
                  "policy.sessionListPerUser)\n"
                  "      ? RateLimitOutcome.allowed\n"
                  "      : RateLimitOutcome.sourceLimited;",
                  "  RateLimitOutcome checkSessionList({required String "
                  "userId}) =>\n"
                  "      RateLimitOutcome.allowed;"),
        ],
        "must_flip": [
            "a field beyond the five the design names",
            "the response carrying anything shaped like a source address, "
            "on /auth/sessions",
            "the response carrying the caller's user id, on /auth/sessions",
            "an unbounded listing for a caller with more devices than the "
            "bound",
            "raising the bound on /auth/sessions with a limit in the query "
            "string",
            "an unbounded flood of session reads from one signed-in caller",
            "the revoked device still listed on the very next request",
            "an expired session appearing in the list",
            "a session idle past the idle lifetime appearing in the list",
        ],
    },
    {
        "name": "disclosure",
        "why": "the closed-membership refusal becomes a 404-versus-403 "
               "existence oracle, the disclosure stops being scoped to the "
               "caller and to ended stints, and it stops stripping the "
               "server's own bookkeeping columns.",
        # The oracle is deliberately wired the *unnatural* way round — 404 for
        # a project that exists, 403 for one that does not. A real mistake
        # would be the other way, but that way `gate_wire.preflight` (which
        # pulls a random, therefore fictional, project id before anything
        # else) aborts the instrument before a single probe is scored, and a
        # variant that never runs measures nothing. Swapping the codes leaves
        # the absent branch exactly as preflight expects and still makes the
        # two answers distinguishable, which is the property under test.
        "patches": [
            patch(SYNC_ROUTES,
                  "            kind: 'pull',\n"
                  "          );\n"
                  "          return _forbidden();",
                  "            kind: 'pull',\n"
                  "          );\n"
                  "          final exists = await context.sync.session"
                  ".execute(\n"
                  "            'SELECT 1 FROM ${quoted(Tables.projects)} '\n"
                  "            r'WHERE project_id = $1',\n"
                  "            parameters: [pull.projectId],\n"
                  "          );\n"
                  "          if (exists.isNotEmpty) return _error(404, "
                  "'not_found');\n"
                  "          return _forbidden();"),
            patch(DISCLOSURE,
                  "      r'WHERE project_id = $1 AND user_id = $2 '\n"
                  "      'AND ($ended) '",
                  "      r'WHERE project_id = $1 AND (user_id = $2 OR true) '\n"
                  "      'AND (true OR $ended) '"),
            # Two of the three strips, not all three: `received_at` is a
            # `TIMESTAMPTZ`, so leaving it in makes the page fail to encode
            # and the route answers 500 to everybody — which breaks the
            # variant instead of the control. `server_seq` (bigint) and
            # `clock_skew_flag` (text) both encode, so the leak is real and
            # the response is still a response. The third strip is the same
            # line of code and the same loop in the probe.
            patch(DISCLOSURE,
                  "        Map<String, Object?>.of(row.toColumnMap())\n"
                  "          ..remove('server_seq')\n"
                  "          ..remove('received_at')\n"
                  "          ..remove('clock_skew_flag'),",
                  "        Map<String, Object?>.of(row.toColumnMap())\n"
                  "          ..remove('received_at'),"),
        ],
        "must_flip": [
            "a caller who can reach the disclosure telling a fictional "
            "project from somebody else's real one",
            "a caller who can never reach the disclosure telling the two "
            "apart",
            "somebody else's membership row crossing",
            "an open stint crossing",
            "server-side bookkeeping (server_seq) crossing",
            "server-side bookkeeping (clock_skew_flag) crossing",
        ],
    },
]


def run(argv, **kwargs):
    return subprocess.run(argv, cwd=ROOT, text=True, **kwargs)


def wait_for(base, seconds=180):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base + "/health", timeout=3) as r:
                if r.status == 200:
                    return True
        except (urllib.error.URLError, urllib.error.HTTPError, OSError):
            pass
        time.sleep(1)
    return False


def reads_instrument(base, link_dir, compose, out):
    env = dict(os.environ, BASE=base, LINK_DIR=link_dir, COMPOSE=compose,
               VERIFY_1149_JSON=out)
    result = subprocess.run(
        [sys.executable, os.path.join(ROOT, "scripts",
                                      "verify_11_49_server_reads.py")],
        cwd=ROOT, env=env, capture_output=True, text=True,
    )
    return result


def main():
    failures = []

    # ---- task 11.310: is the thing on the healthy port the throwaway stack?
    # The healthy half runs `verify_11_49_server_reads.py` — the full attack
    # suite — at HEALTHY_BASE, and until 2026-09-23 it did that to **whatever
    # answered there**. CI always has the `tritrack-gate` stack on 8080 and
    # nothing else, so it never mattered; on the Ubuntu VM, which also serves
    # TriTrack, 8080 is the real server holding real field data. So Docker is
    # asked first, and anything other than `tritrack-gate`'s own server —
    # including Docker not answering, and a COMPOSE line naming another project —
    # ends the run here, before any request is sent.
    refuse_unless_stack(
        HEALTHY_BASE, "tritrack-gate", compose=HEALTHY_COMPOSE,
        before=("running verify_11_49_server_reads.py's full attack suite at "
                "it (the healthy phase)"),
    )

    # ---- half one: the instrument must come back clean against the real
    # server. Without this, "it went red on a broken build" is compatible with
    # an instrument that goes red on everything.
    print("=" * 72)
    print("HEALTHY RUN — the unmodified server. Must be clean.")
    print("=" * 72)
    healthy_out = os.path.join(tempfile.gettempdir(), "tt1149-healthy.json")
    result = reads_instrument(HEALTHY_BASE, HEALTHY_LINK_DIR, HEALTHY_COMPOSE,
                              healthy_out)
    print(result.stdout[-3000:])
    if result.returncode != 0:
        print(result.stderr[-2000:])
        raise SystemExit(
            "The healthy run is not clean, so nothing below would mean "
            "anything. Fix that first — either the server or the instrument."
        )
    healthy = json.load(open(healthy_out))
    if healthy["blind"]:
        raise SystemExit(f"healthy run reported {len(healthy['blind'])} "
                         f"blind control(s)")
    # Task 11.88: this used to check `healthy["admitted"]`, which is every
    # attack the reads instrument marked ADMITTED — including R-2
    # (`scripts/verify_11_49_server_reads.py`'s own BASELINE), which is
    # admitted by design, already registered, and not this script's job to
    # re-litigate. Fixing the compose-project mismatch that used to abort
    # this run before it ever reached the server made that baseline
    # admission visible for the first time, and a healthy run that can never
    # be clean while a registered, already-assigned finding sits open is not
    # useful as a gate. What must be empty is the *unregistered* list,
    # exactly as verify_11_85_broken_control.py's sibling check already does
    # for the same instrument's JSON.
    if healthy["attack_failures"]:
        raise SystemExit(f"healthy run reported {healthy['attack_failures']}")
    print(f"healthy: {len(healthy['results'])} checks, "
          f"{len(healthy['admitted'])} admitted (all registered), "
          f"none blind.\n")

    work = tempfile.mkdtemp(prefix="tt1149-broken-")
    tree = os.path.join(work, "tree")
    run(["git", "worktree", "add", "--detach", tree, "HEAD"], check=True,
        capture_output=True)
    link_dir = os.path.join(tree, ".e2e_magic_links")
    os.makedirs(link_dir, exist_ok=True)
    base = f"http://localhost:{BROKEN_PORT}"

    try:
        for variant in VARIANTS:
            project = f"tritrack-1149-{variant['name']}"
            compose = (
                f"docker compose -p {project} --env-file {ROOT}/.env "
                f"-f {tree}/docker-compose.yml -f {tree}/docker-compose.e2e.yml"
            )
            print("=" * 72)
            print(f"BROKEN RUN — {variant['name']}: {variant['why']}")
            print("=" * 72)

            run(["git", "-C", tree, "checkout", "--", "."], check=True,
                capture_output=True)
            for path, old, new in variant["patches"]:
                full = os.path.join(tree, path)
                source = open(full).read()
                if source.count(old) != 1:
                    failures.append(
                        f"{variant['name']}: the text this variant patches "
                        f"appears {source.count(old)} times in {path}, not "
                        f"once. The server moved; update this file rather "
                        f"than letting a variant silently patch nothing."
                    )
                    break
                open(full, "w").write(source.replace(old, new))
            else:
                run(compose.split() + ["down", "-v"], capture_output=True)
                # Task 11.310: the broken stack is about to claim BROKEN_PORT.
                # Its own leftover stack (if a run died) is gone after the
                # `down` above; if anything else still holds the port, `up`
                # would fail and be reported as a variant that "would not
                # build" — say who holds it instead.
                held = check_free(BROKEN_PORT)
                if held:
                    failures.append(f"{variant['name']}: {held}")
                    continue
                # `postgres server` only, as the two sibling drills and the
                # gate itself do (task 11.310). A bare `up` also started the
                # backup scheduler and the three retention services, reading
                # the operator's own `.env` (`--env-file` above) — its backup
                # directory, recipients and signing key included — for a stack
                # that exists to be broken.
                built = run(
                    compose.split() + ["up", "--build", "-d",
                                       "postgres", "server"],
                    capture_output=True,
                    env=dict(os.environ, SERVER_PORT=BROKEN_PORT),
                )
                if built.returncode != 0:
                    print(built.stdout[-3000:])
                    print(built.stderr[-3000:])
                    failures.append(
                        f"{variant['name']}: the broken variant would not "
                        f"build. A variant that does not compile measures "
                        f"nothing."
                    )
                    run(compose.split() + ["down", "-v"], capture_output=True)
                    continue
                if not wait_for(base):
                    failures.append(
                        f"{variant['name']}: the broken server never became "
                        f"healthy at {base}."
                    )
                    run(compose.split() + ["down", "-v"], capture_output=True)
                    continue

                # Task 11.310: attack only the stack this loop just built.
                # `wait_for` proves something answers at `base`; this proves
                # it is this variant's own compose project.
                not_ours = check_stack(base, project, compose=compose)
                if not_ours:
                    failures.append(
                        f"{variant['name']}: not attacked — {not_ours}")
                    run(compose.split() + ["down", "-v"], capture_output=True)
                    continue

                out = os.path.join(work, f"{variant['name']}.json")
                result = reads_instrument(base, link_dir, compose, out)
                if not os.path.exists(out):
                    print(result.stdout[-3000:])
                    print(result.stderr[-2000:])
                    print("---- the broken server's own log ----")
                    print(run(compose.split() + ["logs", "server", "--tail",
                                                 "30"],
                              capture_output=True).stdout)
                    failures.append(
                        f"{variant['name']}: the instrument did not finish "
                        f"against the broken server, so no probe was scored."
                    )
                    run(compose.split() + ["down", "-v"], capture_output=True)
                    continue
                broken = json.load(open(out))
                admitted = set(broken["admitted"])
                required = set(variant["must_flip"])
                missed = sorted(required - admitted)
                extra = sorted(admitted - required)
                print(f"  {len(admitted)} attacks admitted, "
                      f"{len(required)} required to flip")
                for what in sorted(required & admitted):
                    print(f"  flipped   {what}")
                for what in missed:
                    print(f"  BLIND     {what}")
                for what in extra:
                    print(f"  also      {what}")
                if broken["control_failures"]:
                    print("  (positive controls that also failed, which a "
                          "broken server is expected to break:)")
                    for f in broken["control_failures"]:
                        print(f"    - {f}")
                if missed:
                    failures.append(
                        f"{variant['name']}: {len(missed)} attack(s) stayed "
                        f"'refused' against a server with that control "
                        f"removed — {missed}"
                    )
                run(compose.split() + ["down", "-v"], capture_output=True)
            print()
    finally:
        run(["git", "worktree", "remove", "--force", tree],
            capture_output=True)
        shutil.rmtree(work, ignore_errors=True)

    print("=" * 72)
    if failures:
        print("THE INSTRUMENT IS NOT KNOWN TO WORK:")
        for f in failures:
            print("  ! " + f)
        print("=" * 72)
        return 1
    print("Every required attack flipped to ADMITTED against a server with "
          "that control removed, and the same instrument came back clean "
          "against the real one.")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# gate-instrument: none - a detection proof, run by .github/workflows/broken-control-check.yml, which is where a deliberately broken server exists.
"""Task 11.85 (round 9) — watch the join-surface probes fail.

Task 10.66's standing criterion, applied to the probes that give inventory
entries **23, 24 and 29** their verdicts: **a check that cannot distinguish
success from its own failure is not a check.** A run in which every attack is
refused is exactly what a blind instrument produces, and this project has
shipped three of those — most recently in round 8, where an escape check
reported `refused` for two whole rounds against a server whose sanitiser had
been deleted (§3 entry 20, corrected by task 11.71).

So this file breaks the server on purpose — once per variant, each in a
different place — and requires the round-9 probes to notice. **Task 11.311
added inventory entry 30** (destroying a project): its attacks joined the
`owner` variant's list, and the `deletion-scope` variant was added for its
redirection probes. For each variant it brings
up a **separate compose project** built from a throwaway git worktree, runs
both instruments against it, and asserts that a named set of attacks flips
from `refused` to `ADMITTED`. **An attack that stays `refused` against a
server with that control removed is an attack that was never measuring the
control.**

**The pairing is what makes this evidence.** The same instruments, in the same
run of this script, are also required to come back clean against the
unmodified server. Either half alone proves nothing: a clean run could be
blindness, and a red run could be a broken probe.

Nothing here touches the working tree. The patched source lives in a git
worktree under a temporary directory, removed on the way out.

Usage, with the healthy e2e stack already up:

    python3 scripts/verify_11_85_broken_control.py

Takes roughly ten minutes — each variant is a fresh `dart compile exe`. Exits
non-zero if a healthy run is not clean, if any required attack fails to flip,
or if a variant will not build.
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
# Task 11.69, same reason as every other instrument: without these the magic
# link lands `root:root 0600` on a Linux host and every sign-in below dies on
# `Errno 13`. `setdefault` so an outer script that already set them wins.
os.environ.setdefault("TRITRACK_DEV_UID", str(os.getuid()))
os.environ.setdefault("TRITRACK_DEV_GID", str(os.getgid()))

HEALTHY_BASE = os.environ.get("BASE", "http://localhost:8080")
HEALTHY_LINK_DIR = os.environ.get("LINK_DIR", ".e2e_magic_links")
HEALTHY_COMPOSE = os.environ.get(
    "COMPOSE",
    "docker compose -p tritrack-gate "
    "-f docker-compose.yml -f docker-compose.e2e.yml",
)
BROKEN_PORT = os.environ.get("BROKEN_PORT", "8092")

PROJECT_ROUTES = "server/lib/src/projects/project_routes.dart"
JOIN_SERVICE = "server/lib/src/projects/join_service.dart"
ROW_VALIDATOR = "packages/tritrack_sync/lib/src/row_validator.dart"
POSTGRES_SCHEMA = "server/lib/src/schema/postgres_schema.dart"

#: Which instrument scores each variant. The two files own different inventory
#: entries — 23 and 24 live in the team-surface instrument, 29 in the reads
#: one — so a variant names the one whose probes it is testing.
TEAM = "verify_11_9_team_surface.py"
READS = "verify_11_49_server_reads.py"
JSON_ENV = {TEAM: "VERIFY_119_JSON", READS: "VERIFY_1149_JSON"}


def patch(path, old, new):
    return (path, old, new)


#: Each variant: a name, the edits that break it, which instrument scores it,
#: and the attacks that **must** flip to ADMITTED once the edits are applied.
#:
#: The required lists are deliberately the attacks whose flip is *certain* from
#: the edit — not everything that happens to change. A probe that flips for a
#: reason nobody predicted is interesting and is printed; a probe that fails to
#: flip when the control it names is gone is a defect in the instrument and
#: fails this run.
VARIANTS = [
    {
        "name": "owner",
        "instrument": TEAM,
        "why": "`_requireOwner` stops requiring ownership — §4.11's rule that "
               "project scope comes from the session, deleted. Every "
               "owner-only route on the join surface becomes reachable by "
               "anybody with a session, and a fictional project stops "
               "reading like a forbidden one.",
        "patches": [
            patch(PROJECT_ROUTES,
                  "  if (access != ProjectAccess.owner) {\n"
                  "    return errorResponse(403, 'forbidden', "
                  "traceId: traceIdOf(request));\n"
                  "  }",
                  "  if (access != ProjectAccess.owner && "
                  "!_brokenControlAllowAnyone) {\n"
                  "    return errorResponse(403, 'forbidden', "
                  "traceId: traceIdOf(request));\n"
                  "  }"),
            # A `const` the compiler cannot fold away into dead code, so the
            # refusal branch still compiles and only its condition changes.
            patch(PROJECT_ROUTES,
                  "/// Refuses unless the session owns [projectId], "
                  "identically for \"not yours\"",
                  "final bool _brokenControlAllowAnyone =\n"
                  "    DateTime.now().year > 2000;\n\n"
                  "/// Refuses unless the session owns [projectId], "
                  "identically for \"not yours\""),
        ],
        "must_flip": [
            "an outsider reaching 'read join settings' on project P",
            "an outsider reaching 'list join requests' on project P",
            "an outsider reaching 'rotate the join code' on project P",
            "an outsider reaching 'write join settings' on project P",
            "an outsider reaching 'readmit a past member' on project P",
            "a contributor reaching 'read join settings' on project P",
            "a contributor reaching 'list join requests' on project P",
            "a contributor reaching 'rotate the join code' on project P",
            "a contributor reaching 'write join settings' on project P",
            "a contributor reaching 'readmit a past member' on project P",
            "a viewer reaching 'read join settings' on project P",
            "a viewer reaching 'list join requests' on project P",
            "a viewer reaching 'rotate the join code' on project P",
            "a viewer reaching 'write join settings' on project P",
            "a viewer reaching 'readmit a past member' on project P",
            "'read join settings' telling a fictional project from a "
            "forbidden one",
            "'list join requests' telling a fictional project from a "
            "forbidden one",
            # Task 11.311: the deletion pair, which the owner gate is the
            # whole of. On P the sweep only ever sends `schedule`; the
            # consequence is read back by P's owner.
            "an outsider reaching 'read deletion standing' on project P",
            "an outsider reaching 'schedule deletion' on project P",
            "a viewer reaching 'schedule deletion' on project P",
            "'read deletion standing' telling a fictional project from a "
            "forbidden one",
            "'schedule deletion' telling a fictional project from a "
            "forbidden one",
            "a non-owner's request leaving project P scheduled for "
            "destruction",
            # Probe 8a, on projects made for it. `immediate` is certain to
            # succeed for the first non-owner who sends it, and the survival
            # check reads DV's rows, not the status code.
            "a contributor of DV reaching 'read the standing' on project DV",
            "DV's owner who has left reaching 'schedule' on project DV",
            # Task 11.312 item 5: the other way a membership ends. Removed by
            # a co-owner rather than self-departure, but the resulting row is
            # in the same state (open owner membership gone) — see the
            # fixture's own comment in verify_11_9_team_surface.py.
            "DV's owner removed by a co-owner reaching 'schedule' on "
            "project DV",
            "an outsider to DV reaching 'cancel' on project DV",
            "a non-owner's 'cancel' withdrawing DV's scheduled deletion",
            "a contributor of DV reaching 'destroy now' on project DV",
            "project DV surviving every non-owner's 'destroy now'",
            "an outsider telling destroyed project DX from a never-named one "
            "on 'read the standing'",
        ],
    },
    {
        "name": "deletion-scope",
        "instrument": TEAM,
        "why": "`POST /projects/<id>/deletion` checks ownership of the project "
               "in its path and then acts on a `project_id` from the body when "
               "one is present — the route trusting a caller-supplied id "
               "after the gate, which is what inventory entry 30's redirection "
               "probes exist to catch. Task 11.311. **Entry 29's lesson is why "
               "this variant exists:** that entry's ten redirection probes "
               "reported `refused` against a server with no scoping at all "
               "until a drill like this one broke it on purpose.",
        "patches": [
            patch(PROJECT_ROUTES,
                  "      final action = ProjectDeletionAction.fromWire("
                  "json['action']);",
                  "      if (json['project_id'] is String) {\n"
                  "        projectId = json['project_id'] as String;\n"
                  "      }\n"
                  "      final action = ProjectDeletionAction.fromWire("
                  "json['action']);"),
        ],
        "must_flip": [
            "redirecting 'schedule' with a project_id in the body",
            "project DV surviving 'destroy now' sent with every redirection "
            "at once",
        ],
    },
    {
        "name": "restore-any-owner",
        "instrument": TEAM,
        "why": "`_restore` (server/lib/src/projects/project_routes.dart) narrows "
               "`_requireOwner` further: only the owner who actually deleted "
               "the project — read from `ProjectDirectoryService.isDeletedBy` "
               "— may restore it (task 11.312, item 7's addition to inventory "
               "entry 30). Removing that narrowing leaves the plain owner "
               "gate, which admits every open owner, deleting or not — the "
               "exact shape `verify_11_9_team_surface.py`'s co-owner probe "
               "exists to catch.",
        "patches": [
            patch(PROJECT_ROUTES,
                  "  if (!await ProjectDirectoryService(session)"
                  ".isDeletedBy(userId, projectId)) {",
                  "  if (!await ProjectDirectoryService(session)"
                  ".isDeletedBy(userId, projectId) &&\n"
                  "      !_brokenControlAnyOwnerMayRestore) {"),
            # A `const`-shaped but non-foldable true, same trick as the
            # `owner` variant's `_brokenControlAllowAnyone` — the compiler
            # cannot optimize the branch away, so the refusal path still
            # compiles and only its condition changes.
            patch(PROJECT_ROUTES,
                  "/// The owner's *restore* (task 11.302)",
                  "final bool _brokenControlAnyOwnerMayRestore =\n"
                  "    DateTime.now().year > 2000;\n\n"
                  "/// The owner's *restore* (task 11.302)"),
        ],
        "must_flip": [
            "DR's co-owner who did not delete it restoring project DR",
        ],
    },
    {
        "name": "grant",
        "instrument": TEAM,
        "why": "approval stops honouring the role the owner chose and always "
               "grants owner; the deciding UPDATE stops requiring the request "
               "to be undecided AND the unique open-membership index stops "
               "being unique; and the person-name validator stops refusing "
               "bidirectional overrides.\n"
               "  **The index is in this variant because of what the first "
               "run measured** (2026-08-31): with only the `decided_at IS "
               "NULL` clause removed, a second approval was still refused — "
               "by `idx_memberships_one_open`, which will not admit a second "
               "open membership for the same person. So the clause is "
               "belt-and-braces and the database constraint is the "
               "load-bearing control. Both have to go for the probe to have "
               "anything to see, and knowing which one holds is worth more "
               "than the flip.",
        "patches": [
            patch(PROJECT_ROUTES,
                  "      final result = await _service(context).approve(\n"
                  "        projectId: projectId,\n"
                  "        requestId: requestId,\n"
                  "        role: role,",
                  "      final result = await _service(context).approve(\n"
                  "        projectId: projectId,\n"
                  "        requestId: requestId,\n"
                  "        role: ProjectRole.owner,"),
            patch(JOIN_SERVICE,
                  "        r\"decision = 'approved' WHERE request_id = $3 AND "
                  "project_id = $4 \"\n"
                  "        'AND decided_at IS NULL RETURNING user_id, email',",
                  "        r\"decision = 'approved' WHERE request_id = $3 AND "
                  "project_id = $4 \"\n"
                  "        'AND (decided_at IS NULL OR TRUE) RETURNING "
                  "user_id, email',"),
            # **Re-authored 2026-09-05 by task 11.127.** Until task 11.89 a
            # person's name was bounded by two denylists, and this variant
            # deleted the second of them — `!_bidiFormatting.hasMatch(value)`.
            # 11.89 replaced both with the allowlist below, so that line no
            # longer exists and this variant refused to run: the harness will
            # not patch text it cannot find, which is the only reason anybody
            # noticed that the bidi detection proof had stopped existing.
            #
            # The sabotage is the same control deleted, expressed against an
            # allowlist instead of a denylist: the ten bidirectional
            # formatting characters are **added back to the permitted set**,
            # which is exactly the set the old `_bidiFormatting` denylist
            # held. Nothing else moves — letters, marks, digits, dashes,
            # spaces and the two joiners stay permitted and `\p{Zl}`/`\p{Zp}`
            # stay refused — so a probe that flips here flipped because the
            # bidi rule went, not because the name rule collapsed.
            patch(ROW_VALIDATOR,
                  r"""    '[^\\p{L}\\p{M}\\p{Nd}\\p{Pd}\\p{Zs}.,\''"""
                  "\n"
                  r"""    '\\u2019\\u00b7\\u30fb\\u200c\\u200d]',""",
                  r"""    '[^\\p{L}\\p{M}\\p{Nd}\\p{Pd}\\p{Zs}.,\''"""
                  "\n"
                  r"""    '\\u2019\\u00b7\\u30fb\\u200c\\u200d'"""
                  "\n"
                  r"""    '\\u061c\\u200e\\u200f\\u202a-\\u202e"""
                  r"""\\u2066-\\u2069]',"""),
            patch(POSTGRES_SCHEMA,
                  "  'CREATE UNIQUE INDEX ${quoted('idx_memberships_one_open')} '",
                  "  'CREATE INDEX ${quoted('idx_memberships_one_open')} '"),
        ],
        "must_flip": [
            "the role the requester asked for beating the one the owner chose",
            "approving the same request a second time, at a higher role",
            "a claimed name containing a right-to-left override (U+202E)",
            "a claimed name containing a left-to-right override (U+202D)",
            "a claimed name containing a right-to-left embedding (U+202B)",
            "a claimed name containing a pop-directional-formatting (U+202C)",
            "a claimed name containing a right-to-left mark (U+200F)",
            "a claimed name containing a left-to-right mark (U+200E)",
            "a claimed name containing an Arabic letter mark (U+061C)",
            "a claimed name containing a first-strong isolate (U+2068)",
            "a claimed name containing a left-to-right isolate (U+2066)",
            "a claimed name containing a pop-directional isolate (U+2069)",
        ],
    },
    {
        "name": "mine",
        "instrument": READS,
        "why": "`GET /projects/join-requests/mine` stops scoping its query to "
               "the caller and hands back the `project_id` on every decision "
               "rather than on an approval only — the two properties "
               "inventory entry 29 is the record of.",
        "patches": [
            patch(JOIN_SERVICE,
                  "      r'WHERE r.user_id = $1 AND p.deleted_at IS NULL '",
                  "      r'WHERE (r.user_id = $1 OR TRUE) AND p.deleted_at "
                  "IS NULL '"),
            patch(JOIN_SERVICE,
                  "          projectId: row[3] == joinDecisionApproved "
                  "? row[5]! as String : null,",
                  "          projectId: row[5]! as String,"),
        ],
        "must_flip": [
            "a pending request carrying the project id",
            "a rejected request carrying the project id",
            "a cleared request carrying the project id",
            "redirecting the list with a user_id in the query string",
            "redirecting the list with a user_id in a GET body",
            "redirecting the list with a user_id in an X-User-Id header",
        ],
    },
]


def run(argv, **kwargs):
    return subprocess.run(argv, cwd=ROOT, text=True, **kwargs)


# Task 11.316. What a build prints when it could not reach the network — pub.dev
# for a package, a Debian mirror for apt, or the registry for a base image. A
# build that fails this way says nothing about the variant it was building, and
# the same network is down for the next four, so trying them is only waiting.
NO_NETWORK_SIGNS = (
    "Failed host lookup",
    "Could not resolve host",
    "Temporary failure in name resolution",
    "Network is unreachable",
    "Connection timed out",
    "Connection refused",
    "Could not connect to",
    "Unable to connect to",
    "Failed to fetch",
    "no such host",
    "dial tcp",
    "SocketException",
    "HandshakeException",
)

NO_NETWORK_MESSAGE = (
    "the build could not reach the network, so this variant was never "
    "compiled and the remaining ones were not tried (they need the same "
    "network). On the Ubuntu VM the usual cause is Docker's container network "
    "being down. Check with `ip -4 addr show docker0`: if it prints no `inet` "
    "line, restart Docker (see server/README.md), then run this again."
)


def looks_like_no_network(build_output):
    return any(sign in build_output for sign in NO_NETWORK_SIGNS)


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


def instrument(name, base, link_dir, compose, out):
    env = dict(os.environ, BASE=base, LINK_DIR=link_dir, COMPOSE=compose)
    env[JSON_ENV[name]] = out
    return subprocess.run(
        [sys.executable, os.path.join(ROOT, "scripts", name)],
        cwd=ROOT, env=env, capture_output=True, text=True,
    )


def main():
    failures = []
    needed = sorted({v["instrument"] for v in VARIANTS})

    # ---- task 11.310: is the thing on the healthy port the throwaway stack?
    # The healthy half runs each instrument it drives — the full attack suite —
    # at HEALTHY_BASE, and until 2026-09-23 it did that to **whatever answered
    # there**. CI always has the `tritrack-gate` stack on 8080 and nothing else,
    # so it never mattered; on the Ubuntu VM, which also serves TriTrack, 8080 is
    # the real server holding real field data. So Docker is asked first, and
    # anything other than `tritrack-gate`'s own server — including Docker not
    # answering, and a COMPOSE line naming another project — ends the run here,
    # before any request is sent.
    refuse_unless_stack(
        HEALTHY_BASE, "tritrack-gate", compose=HEALTHY_COMPOSE,
        before=("running each instrument this drill drives at it, full "
                "attack suite included (the healthy phase)"),
    )

    # ---- half one: each instrument must come back clean against the real
    # server. Without this, "it went red on a broken build" is compatible with
    # an instrument that goes red on everything.
    print("=" * 72)
    print("HEALTHY RUN — the unmodified server. Must be clean.")
    print("=" * 72)
    for name in needed:
        out = os.path.join(tempfile.gettempdir(), f"tt1185-healthy-{name}.json")
        result = instrument(name, HEALTHY_BASE, HEALTHY_LINK_DIR,
                            HEALTHY_COMPOSE, out)
        if result.returncode != 0 or not os.path.exists(out):
            print(result.stdout[-3000:])
            print(result.stderr[-2000:])
            raise SystemExit(
                f"The healthy run of {name} is not clean, so nothing below "
                f"would mean anything. Fix that first — either the server or "
                f"the instrument."
            )
        healthy = json.load(open(out))
        if healthy["blind"]:
            raise SystemExit(f"{name}: healthy run reported "
                             f"{len(healthy['blind'])} blind control(s)")
        # Baselined findings are ADMITTED by design and do not make the run
        # dirty; what must be empty is the *unregistered* list.
        if healthy["attack_failures"]:
            raise SystemExit(f"{name}: healthy run reported "
                             f"{healthy['attack_failures']}")
        print(f"  {name}: {len(healthy['results'])} checks, "
              f"{len(healthy['admitted'])} admitted (all registered), "
              f"none blind.")
    print()

    work = tempfile.mkdtemp(prefix="tt1185-broken-")
    tree = os.path.join(work, "tree")
    run(["git", "worktree", "add", "--detach", tree, "HEAD"], check=True,
        capture_output=True)
    link_dir = os.path.join(tree, ".e2e_magic_links")
    os.makedirs(link_dir, exist_ok=True)
    base = f"http://localhost:{BROKEN_PORT}"

    try:
        for variant in VARIANTS:
            project = f"tritrack-1185-{variant['name']}"
            compose = (
                f"docker compose -p {project} --env-file {ROOT}/.env "
                f"-f {tree}/docker-compose.yml "
                f"-f {tree}/docker-compose.e2e.yml"
            )
            print("=" * 72)
            print(f"BROKEN RUN — {variant['name']}: {variant['why']}")
            print("=" * 72)

            run(["git", "-C", tree, "checkout", "--", "."], check=True,
                capture_output=True)
            ok = True
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
                    ok = False
                    break
                open(full, "w").write(source.replace(old, new))
            if not ok:
                continue

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
            built = run(compose.split() + ["up", "--build", "-d",
                                           "postgres", "server"],
                        capture_output=True,
                        env=dict(os.environ, SERVER_PORT=BROKEN_PORT))
            if built.returncode != 0:
                print(built.stdout[-3000:])
                print(built.stderr[-3000:])
                run(compose.split() + ["down", "-v"], capture_output=True)
                if looks_like_no_network(built.stdout + built.stderr):
                    failures.append(f"{variant['name']}: {NO_NETWORK_MESSAGE}")
                    break
                failures.append(
                    f"{variant['name']}: the broken variant would not build. "
                    f"A variant that does not compile measures nothing."
                )
                run(compose.split() + ["down", "-v"], capture_output=True)
                continue
            if not wait_for(base):
                print(run(compose.split() + ["logs", "server", "--tail", "30"],
                          capture_output=True).stdout)
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

            name = variant["instrument"]
            out = os.path.join(work, f"{variant['name']}.json")
            result = instrument(name, base, link_dir, compose, out)
            if not os.path.exists(out):
                print(result.stdout[-3000:])
                print(result.stderr[-2000:])
                print("---- the broken server's own log ----")
                print(run(compose.split() + ["logs", "server", "--tail", "30"],
                          capture_output=True).stdout)
                failures.append(
                    f"{variant['name']}: {name} did not finish against the "
                    f"broken server, so no probe was scored."
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
                print("  (positive controls that also failed, which a broken "
                      "server is expected to break:)")
                for f in broken["control_failures"]:
                    print(f"    - {f}")
            if missed:
                failures.append(
                    f"{variant['name']}: {len(missed)} attack(s) stayed "
                    f"'refused' against a server with that control removed — "
                    f"{missed}"
                )
            run(compose.split() + ["down", "-v"], capture_output=True)
            print()
    finally:
        run(["git", "worktree", "remove", "--force", tree],
            capture_output=True)
        shutil.rmtree(work, ignore_errors=True)

    print("=" * 72)
    if failures:
        print("THE JOIN-SURFACE PROBES ARE NOT KNOWN TO WORK:")
        for f in failures:
            print("  ! " + f)
        print("=" * 72)
        return 1
    print("Every required attack flipped to ADMITTED against a server with "
          "that control removed, and the same instruments came back clean "
          "against the real one.")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())

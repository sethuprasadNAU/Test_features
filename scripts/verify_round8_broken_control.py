#!/usr/bin/env python3
# gate-instrument: none - a detection proof, run by .github/workflows/broken-control-check.yml, which is where a deliberately broken server exists.
"""Task 11.64 — watch `verify_round8_server_surface.py` fail.

Task 10.66's standing criterion, applied to the instrument that gives
inventory entries 14, 15 and 20 their verdicts: **a check that cannot
distinguish success from its own failure is not a check.** A run in which
every attack is refused is exactly what a blind instrument produces, and this
project has shipped three of those.

So this file breaks the server on purpose — twice, in different places — and
requires the round-8 instrument to notice. For each variant it brings up a
**separate compose project** built from a throwaway git worktree, runs the
instrument against it, and asserts that a named set of attacks flips from
`refused` to `ADMITTED`. An attack that stays `refused` against a server with
that control removed is an attack that was never measuring the control.

**The pairing is what makes this evidence.** The same instrument, in the same
run of this script, is also required to come back clean against the unmodified
server. Either half alone proves nothing: a clean run could be blindness, and
a red run could be a broken probe.

Nothing here touches the working tree. The patched source lives in a git
worktree under a temporary directory, removed on the way out.

**Two variants rather than three**, and the omission is deliberate rather than
economising: entry 17's matrix is a *separate* instrument
(`verify_deployment_refusal_matrix.sh`) which carries its own blindness check
inside it — if no shape refuses, or no shape starts, it fails the run and says
so. That check has already fired once for real, on the first draft, when
`docker run --rm` removed every refusing container before it could be
inspected.

Usage:

    python3 scripts/verify_round8_broken_control.py

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
HEALTHY_COMPOSE = os.environ.get(
    "COMPOSE",
    "docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml",
)
BROKEN_PORT = os.environ.get("BROKEN_PORT", "8092")

AUTH_ROUTES = "server/lib/src/auth/auth_routes.dart"
EMAIL_SENDER = "server/lib/src/auth/email_sender.dart"
SYNC_PROTOCOL = "packages/tritrack_sync/lib/src/sync_protocol.dart"


def patch(path, old, new):
    return (path, old, new)


#: Each variant: a human name, the edits that break it, and the attacks the
#: round-8 instrument **must** report as ADMITTED once they are applied.
#:
#: The required lists are deliberately the attacks whose flip is *certain*
#: from the edit — not everything that happens to change. A probe that flips
#: for a reason nobody predicted is interesting and is printed; a probe that
#: fails to flip when the control it names is gone is a defect in the
#: instrument and fails this run.
VARIANTS = [
    {
        "name": "coercion",
        "why": "the sync envelope stops telling a wrongly-typed integer from "
               "an absent one — finding J-4's exact shape (§12.6), where "
               "`cursor: \"abc\"` reached an unchecked cast. Here it is worse "
               "than a 500: the string is quietly read as a number, so a "
               "client and a server can disagree about where a device is in "
               "the stream and neither is told.",
        "patches": [
            patch(SYNC_PROTOCOL,
                  "  if (value is! int) {\n"
                  "    throw SyncProtocolException('\"$key\" must be an "
                  "integer.');\n"
                  "  }\n"
                  "  return value;\n"
                  "}",
                  "  if (value is! int) {\n"
                  "    return value is String ? (int.tryParse(value) ?? 0) : "
                  "0;\n"
                  "  }\n"
                  "  return value;\n"
                  "}"),
        ],
        "must_flip": [
            "cursor as a string",
            "cursor as a numeric string",
            "cursor as a float",
            "cursor as a list",
            "cursor as an object",
            "cursor as a bool",
            "batch_size as a string",
            "batch_size as a float",
            "batch_size as a list",
            "batch_size as an object",
            "batch_size as a bool",
            "ack cursor as a string",
            "ack cursor as a float",
            "ack cursor as a list",
            "ack cursor as an object",
            "ack cursor as a bool",
        ],
    },
    {
        "name": "sanitiser",
        "why": "the address stops being checked for control characters and "
               "the magic-link filename stops being sanitised — so a caller "
               "names a file on disk (entry 20, register entry M-9) and a "
               "newline in an address survives to whatever sender lands next "
               "(the SMTP header-injection bound §4.5 asserts).",
        "patches": [
            # Task 11.298 re-authored this edit. The boundary used to be a
            # loose shape check with a separate control-character regex, and
            # this variant deleted the regex. It is now one line applying the
            # SMTP sender's own rule (`isAcceptableSignInAddress`); the
            # equivalent sabotage is to make it admit anything with an `@`,
            # which is what a boundary with no control-character rule does to
            # the newline, CRLF, comma and semicolon probes below. (The sender
            # still refuses those itself on the SMTP path; this stack runs the
            # file sender, whose only defense is the filename sanitiser the
            # second edit deletes — so the flip is certain.)
            patch(AUTH_ROUTES,
                  "bool isAcceptableSignInAddress(String value) =>\n"
                  "    isDeliverableAddress(normalizeEmail(value));",
                  "bool isAcceptableSignInAddress(String value) =>\n"
                  "    normalizeEmail(value).contains('@');"),
            patch(EMAIL_SENDER,
                  "    final safeName = email.replaceAll("
                  "RegExp(r'[^a-zA-Z0-9._@-]'), '_');",
                  "    final safeName = email;"),
        ],
        "must_flip": [
            "email as a newline",
            "email as a CRLF",
            "email as a comma-separated recipient list",
            "email as a semicolon-separated recipient list",
            "four levels up to /etc/passwd",
            "a bare separator mid-address",
            "doubled dots and slashes",
            # Task 11.71. This one stayed `refused` for two rounds against a
            # server with the sanitiser deleted — it was required to flip and
            # did not, which is exactly what this harness is for. The cause
            # was not the check: it was the attack corpus, which contained no
            # address naming a directory the server could actually write to.
            # The instrument now discovers one from the container and aims an
            # address at it, and the line below is that address.
            "four levels up into a writable directory outside the link "
            "directory",
            "any .link file anywhere outside the link directory",
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


def round8_instrument(base, link_dir, compose, out):
    env = dict(os.environ, BASE=base, LINK_DIR=link_dir, COMPOSE=compose,
               VERIFY_ROUND8_JSON=out)
    result = subprocess.run(
        [sys.executable, os.path.join(ROOT, "scripts",
                                      "verify_round8_server_surface.py")],
        cwd=ROOT, env=env, capture_output=True, text=True,
    )
    return result


def main():
    failures = []

    # ---- task 11.310: is the thing on the healthy port the throwaway stack?
    # The healthy half runs `verify_round8_server_surface.py` — the full attack
    # suite — at HEALTHY_BASE, and until 2026-09-23 it did that to **whatever
    # answered there**. CI always has the `tritrack-gate` stack on 8080 and
    # nothing else, so it never mattered; on the Ubuntu VM, which also serves
    # TriTrack, 8080 is the real server holding real field data. So Docker is
    # asked first, and anything other than `tritrack-gate`'s own server —
    # including Docker not answering, and a COMPOSE line naming another project —
    # ends the run here, before any request is sent.
    refuse_unless_stack(
        HEALTHY_BASE, "tritrack-gate", compose=HEALTHY_COMPOSE,
        before=("running verify_round8_server_surface.py's full attack suite "
                "at it (the healthy phase)"),
    )

    # ---- half one: the instrument must come back clean against the real
    # server. Without this, "it went red on a broken build" is compatible with
    # an instrument that goes red on everything.
    print("=" * 72)
    print("HEALTHY RUN — the unmodified server. Must be clean.")
    print("=" * 72)
    healthy_out = os.path.join(tempfile.gettempdir(), "tt1164-healthy.json")
    result = round8_instrument(HEALTHY_BASE, HEALTHY_LINK_DIR, HEALTHY_COMPOSE,
                              healthy_out)
    print(result.stdout[-3000:])
    if result.returncode != 0:
        print(result.stderr[-2000:])
        raise SystemExit(
            "The healthy run is not clean, so nothing below would mean "
            "anything. Fix that first — either the server or the instrument."
        )
    healthy = json.load(open(healthy_out))
    if healthy["admitted"] or healthy["blind"]:
        raise SystemExit(f"healthy run reported {healthy['admitted']} "
                         f"admitted and {healthy['blind']} blind")
    print(f"healthy: {len(healthy['results'])} checks, none admitted, "
          f"none blind.\n")

    work = tempfile.mkdtemp(prefix="tt1164-broken-")
    tree = os.path.join(work, "tree")
    run(["git", "worktree", "add", "--detach", tree, "HEAD"], check=True,
        capture_output=True)
    link_dir = os.path.join(tree, ".e2e_magic_links")
    os.makedirs(link_dir, exist_ok=True)
    base = f"http://localhost:{BROKEN_PORT}"

    try:
        for variant in VARIANTS:
            project = f"tritrack-1164-{variant['name']}"
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
                result = round8_instrument(base, link_dir, compose, out)
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

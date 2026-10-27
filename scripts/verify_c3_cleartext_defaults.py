#!/usr/bin/env python3
# gate-instrument: none - run by verify_c3_cleartext_defaults_stack.sh, which gives it the compose lifecycle it needs; the gate runs the wrapper.
"""Re-runs Security Gate C's C-3 reproduction (`TriTrack_Security_Model.md`
§7.3 B3) against the real artifact — the compose file people run and the image
it builds — rather than against the Dart unit that was already green while the
finding was live.

The finding had two halves:

  1. `security_config.dart` implemented only the first half of §4.1's condition
     (a development build) and never the second (a loopback or private-range
     target), so `TRITRACK_ALLOW_CLEARTEXT_LAN=1` on a public address printed a
     warning and then served.
  2. `docker-compose.yml` defaulted that flag to `1` and `TRITRACK_ENV` to
     `development` behind a `0.0.0.0:8080` publish, making cleartext-on-every-
     interface the thing a clean checkout actually ran.

Check 1 is reproduced honestly: the server image is started on a Docker network
whose subnet is 203.0.113.0/24 (RFC 5737 TEST-NET-3 — publicly routable as far
as any private-range predicate is concerned), so the container genuinely holds a
public address and must refuse to start. That is a live reproduction, not an
assertion about a mock.

Usage (Docker required):

    docker compose up --build -d          # for the reachability checks
    python3 scripts/verify_c3_cleartext_defaults.py

Checks 1 and 2 do not need the stack up, but this exits non-zero regardless
if it isn't — check 3 (the LAN cannot reach it) is C-3's actual reproduction,
and a run that never exercised it must not report the same success a run
that did would (W-3, TriTrack_Security_Model.md §10.7.1). To confirm the
script tests anything at all, revert either half of task 10.22 and re-run:
checks 1 and 3 fail respectively.
"""
import http.client
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NETWORK = "tritrack_c3_public_check"
PORT = os.environ.get("SERVER_PORT", "8080")
COMPOSE_FILE = os.path.join(ROOT, "docker-compose.yml")
sys.path.insert(0, os.path.join(ROOT, "scripts", "lib"))
from port_holder import PortQuestionUnanswered, holders  # noqa: E402
from shipped_compose_settings import shipped_settings  # noqa: E402



failures = []
#: Checks this run could not exercise at all (e.g. the stack isn't up), kept
#: apart from `failures`. W-3 (TriTrack_Security_Model.md §10.7.1): this
#: script used to print "SKIP" for the live-reachability check and then exit
#: 0 claiming "C-3 closed ... the shipped compose defaults reach this host
#: only" — the one sentence that is actually C-3's reproduction — without
#: ever having checked it. A skipped check must never be indistinguishable
#: from a passed one, so it is tracked here and turns the run non-zero.
skipped = []


def check(name, condition, detail=""):
    print(("  PASS  " if condition else "  FAIL  ") + name + (f"  {detail}" if detail else ""))
    if not condition:
        failures.append(name)


def skip(name, reason):
    print(f"  SKIP  {name}  {reason}")
    skipped.append(name)


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, **kwargs)


def get(host, port, path="/health", timeout=3):
    """Returns (status, body) or None if the connection never opened."""
    try:
        conn = http.client.HTTPConnection(host, int(port), timeout=timeout)
        conn.request("GET", path)
        response = conn.getresponse()
        return response.status, response.read().decode()
    except (OSError, http.client.HTTPException):
        return None


def lan_address():
    """This machine's LAN address — the one a phone on the Wi-Fi would use."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # No packet is sent; this just asks the routing table which local
        # address would be used to reach the outside world.
        sock.connect(("8.8.8.8", 80))
        return sock.getsockname()[0]
    finally:
        sock.close()


def postgres_socket(host, port=5432, timeout=3):
    """What is listening on <host>:<port>, measured rather than looked up.

    Returns None if nothing accepts a connection at all; otherwise
    `"postgres"` or `"something else"` — told apart by the SSLRequest
    handshake, which a Postgres server answers with a single `S` or `N` byte
    and nothing else does.

    **Why a socket and not `docker compose config` (task 11.125, item 2(iii)).**
    "The database publishes no port" was asserted only by reading the resolved
    compose file, one check above. That reads the instruction; this reads the
    machine, and they are different claims — a stray `docker run -p 5432:5432`,
    a Postgres installed on the host, a leftover container from another project
    and a port opened by hand are all invisible to the file and all mean the
    same thing to somebody on the LAN.
    """
    try:
        with socket.create_connection((host, int(port)), timeout=timeout) as s:
            # SSLRequest: length 8, magic 80877103. The one Postgres message
            # that can be sent before anything is negotiated.
            s.sendall(b"\x00\x00\x00\x08\x04\xd2\x16\x2f")
            s.settimeout(timeout)
            reply = s.recv(1)
    except OSError:
        return None
    return "postgres" if reply in (b"S", b"N") else "something else"


print("1. The server refuses cleartext on a machine with a public address")
print("   (container placed on 203.0.113.0/24 — a genuinely public range)")

# Built directly from server/Dockerfile rather than via `docker compose build`,
# so this check does not depend on the compose project name — and so it is
# unmistakably the same image the compose file builds, from the same context.
image = "tritrack-c3-check"
built = run("docker", "build", "-f", "server/Dockerfile", "-t", image, ".")
if built.returncode != 0:
    print(built.stderr[-2000:])
    sys.exit("could not build the server image")

run("docker", "network", "rm", NETWORK)
created = run("docker", "network", "create", "--subnet=203.0.113.0/24", NETWORK)
if created.returncode != 0:
    print(created.stderr[-2000:])
    sys.exit("could not create the test network")

try:
    result = run(
        "docker", "run", "--rm", "--network", NETWORK,
        "-e", "TRITRACK_ALLOW_CLEARTEXT_LAN=1",
        # Deliberately NOT production: the pre-10.22 refusal covered that case
        # and would mask what is being tested here.
        "-e", "TRITRACK_ENV=development",
        image,
        timeout=60,
    )
    output = result.stdout + result.stderr
    check("the process exits rather than serving", result.returncode != 0,
          f"exit {result.returncode}")
    check("it exits EX_CONFIG (78), not by crashing", result.returncode == 78,
          f"exit {result.returncode}")
    check("the refusal is readable, not a stack trace",
          "REFUSING TO START" in output)
    check("it names the offending address", "203.0.113." in output)
    check("it names both ways out",
          "TRITRACK_TLS_CERT_PATH" in output and "SSH tunnel" in output)
    check("it did NOT serve", "listening on" not in output,
          output.strip().splitlines()[-1] if output.strip() else "")
finally:
    run("docker", "network", "rm", NETWORK)

print("\n2. The shipped compose defaults, as Docker itself resolves them")
# `docker compose config` is the resolved artifact — variable substitution
# applied — which is the thing that actually runs. Reading the file as text
# would miss a variable whose default re-opens the address. **Resolved with
# [shipped_settings], never with this machine's `.env`** (task 11.310): this
# section is about what ships. What this machine's own settings do is printed
# as a note at the end of the section, because it is worth seeing and is not
# what this section certifies.
#
# The render runs from a scratch directory holding only a copy of the compose
# file, so no `.env` is reachable by any lookup rule Compose has — the
# environment above already outranks one, and this makes the question moot.


def render(settings):
    """`docker compose config` as JSON. `None` settings = this machine's `.env`.

    For `None` the shipped settings' names are removed from the environment
    first: the stack wrapper exports them, and a render that inherited them
    would print the shipped answer under the heading of this machine's own.
    """
    if settings is None:
        own_env = {k: v for k, v in os.environ.items()
                   if k not in shipped_settings()}
        done = subprocess.run(
            ["docker", "compose", "config", "--format", "json"],
            cwd=ROOT, capture_output=True, text=True, env=own_env)
    else:
        scratch = tempfile.mkdtemp(prefix="tritrack-c3-render-")
        try:
            shutil.copy(COMPOSE_FILE, scratch)
            done = subprocess.run(
                ["docker", "compose", "-f",
                 os.path.join(scratch, "docker-compose.yml"),
                 "config", "--format", "json"],
                cwd=scratch, capture_output=True, text=True,
                env=dict(os.environ, **settings),
            )
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    if done.returncode != 0:
        print(done.stderr[-2000:])
        sys.exit("could not resolve the compose configuration")
    return json.loads(done.stdout)


def published_addresses(resolved, only=None):
    """{host address} for every published port, of one service or of all."""
    services = resolved.get("services", {})
    return {str(p.get("host_ip") or "0.0.0.0")
            for name, service in services.items() if only in (None, name)
            for p in service.get("ports", [])}


resolved = render(shipped_settings())
server = resolved["services"]["server"]
environment = server.get("environment", {})

host_ips = published_addresses(resolved, only="server")
check("the server port is published to loopback only", host_ips == {"127.0.0.1"},
      f"published on {sorted(host_ips)}")
# Task 11.310: this line used to test the server's addresses only while its
# name claimed every service. It now reads every service in the render.
every_ip = published_addresses(resolved)
check("no service publishes 0.0.0.0", "0.0.0.0" not in every_ip,
      f"every published address: {sorted(every_ip)}")
check("TRITRACK_ENV is not defaulted to development",
      (environment.get("TRITRACK_ENV") or "") != "development",
      f"TRITRACK_ENV={environment.get('TRITRACK_ENV')!r}")
check("Postgres is still not published to the host",
      not resolved["services"]["postgres"].get("ports"))
check("the diagnostics console is still off",
      environment.get("TRITRACK_DIAGNOSTICS_ENABLED") in (None, "", "false"),
      f"={environment.get('TRITRACK_DIAGNOSTICS_ENABLED')!r}")
# The render must be able to see a variable at all, or "loopback" above could
# be a renderer that ignores every setting and prints the file's defaults
# whatever it is given. The one override that matters is set, and it must show.
opened = published_addresses(
    render(shipped_settings(SERVER_PUBLISH_ADDRESS="0.0.0.0")), only="server")
check("control: the same render follows SERVER_PUBLISH_ADDRESS when it is set",
      opened == {"0.0.0.0"}, f"published on {sorted(opened)}")
own = published_addresses(render(None), only="server")
print(f"  NOTE  this machine's own .env publishes the "
      f"server on {sorted(own)}"
      + ("" if own == {"127.0.0.1"} else
         " — an operator's choice, not the shipped default; nothing above or "
         "below tests it"))

print("\n3. A running stack is reachable from this host and nowhere else")
local = get("127.0.0.1", PORT)
if local is None:
    skip("the LAN address does NOT reach the server",
         "the stack is not up — start it with `docker compose up -d` "
         "(checks 1 and 2 above do not need it; this one does). This is "
         "C-3's actual reproduction — it does not count as closed unverified.")
else:
    check("localhost reaches the server", local[0] == 200, str(local))
    # What this section is measuring, named rather than assumed (task
    # 11.310): whichever stack Docker says publishes this port. Run by
    # `verify_c3_cleartext_defaults_stack.sh` that is the stack it brought up
    # from the shipped settings, as compose project COMPOSE_PROJECT_NAME; run by
    # hand, it is whatever is there, and the line below says which.
    expected = os.environ.get("COMPOSE_PROJECT_NAME")
    try:
        serving = holders(PORT)
    except PortQuestionUnanswered as error:
        serving = None
        check("Docker can say which stack is being measured", False, str(error))
    if serving is not None:
        projects = sorted({h["project"] or "(not compose)" for h in serving})
        addresses = sorted({a for h in serving for a in h["addresses"]})
        print(f"  (measuring port {PORT}: compose project(s) {projects}, "
              f"published on {addresses})")
        if expected:
            check(f"the stack answering on {PORT} is {expected!r}, the one "
                  f"brought up for this check", projects == [expected],
                  f"{projects}")
        check(f"that stack publishes port {PORT} on loopback only, as Docker "
              f"reports it", addresses == ["127.0.0.1"], f"{addresses}")
    lan = lan_address()
    remote = get(lan, PORT, timeout=3)
    check(f"the LAN address {lan} does NOT reach it", remote is None,
          "" if remote is None else f"answered {remote[0]} — this is B3 live")

    # Task 11.125, item 2(iii). The same question as "Postgres is still not
    # published to the host" two checks above, asked of the machine instead of
    # the file. Both loopback and the LAN address, because a container
    # published to 127.0.0.1 is a different fault from one published to the
    # world and only the second is B3, but neither is what this compose file
    # says it does.
    for where, host in (("loopback", "127.0.0.1"), (f"the LAN address {lan}",
                                                    lan)):
        found = postgres_socket(host)
        check(f"nothing answers on {where} port 5432", found is None,
              "" if found is None
              else f"a socket opened and it is {found}. If another Postgres "
                   f"runs on this machine, that is what this found — this "
                   f"check cannot tell two databases apart, and a host "
                   f"answering on 5432 is the fact either way")

print("\n4. §4.1's client half, for the record")
# Not reproducible over HTTP: it is a validator inside the app. Named here so a
# reader of this script knows where the other half lives and that it is covered.
validator = open(os.path.join(ROOT, "lib/core/providers/server_config_provider.dart")).read()
check("the app's URL validator applies the private-range condition",
      "_isPrivateTarget" in validator and "isPrivateNetworkAddress" in validator)
check("it is not gated on release mode alone",
      re.search(r"scheme == 'http' && !_isPrivateTarget", validator) is not None)

print()
if failures:
    print(f"{len(failures)} CHECK(S) FAILED: {failures}")
    sys.exit(1)
if skipped:
    print(f"{len(skipped)} CHECK(S) SKIPPED, NOT VERIFIED: {skipped}")
    print("C-3 is NOT confirmed closed by this run — bring the stack up and "
          "re-run to actually exercise the live-reachability check.")
    sys.exit(1)
print("C-3 closed: cleartext is refused on a public address, and the shipped "
      "compose defaults reach this host only.")

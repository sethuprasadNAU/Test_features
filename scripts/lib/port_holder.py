#!/usr/bin/env python3
# gate-instrument: none - a helper imported by the broken-control drills and called by gate_smoke_test.sh; it asks Docker a question and attacks nothing.
"""Who is holding a TCP port on this machine — asked of Docker, never assumed.

**Task 11.310.** Two gate scripts assumed they knew what was on port 8080:

- `gate_smoke_test.sh` assumed nothing was, built images for minutes, and then
  died on Docker's *port is already allocated* with a generic "could not bring
  the stack up" — on the Ubuntu VM that also serves TriTrack, where the real
  server holds 8080.
- the four `verify_*_broken_control.py` drills assumed the thing on 8080 was the
  throwaway `tritrack-gate` stack, and ran their **healthy phase — the full
  attack suite of the instrument each one drives — at whatever answered.** On
  the VM that is the real server, holding real field data.

Both are one missing question, so it is answered once, here: *which container
publishes this host port, and which compose project does it belong to?*

**It reads Docker, not a socket.** A socket answering proves somebody is there,
not who. Docker records, for every running container, the host ports it
publishes and the compose project and service that created it (the
`com.docker.compose.*` labels), so the answer names the real server by name —
and, from the project's working directory, the exact command that stops it.

**Anything it cannot establish is a refusal**, never a pass. Docker not
answering, a port held by something outside Docker, a port held by two
projects, and a compose command that does not name its project are all answers
this module turns into "no", because the cost of a wrong "yes" in the drills is
an attack on production and the cost of a wrong "no" is a sentence to read.

Used two ways:

    # from Python (the drills)
    from port_holder import refuse_unless_stack
    refuse_unless_stack(BASE, "tritrack-gate", compose=COMPOSE, before="...")

    # from a shell (gate_smoke_test.sh), before building anything
    python3 scripts/lib/port_holder.py free 8080
    python3 scripts/lib/port_holder.py expect 8080 tritrack-gate

Both CLI forms exit 0 when the port is as required and 1 with the reason
otherwise; neither sends a request to whatever holds the port.
"""
import json
import shlex
import socket
import subprocess
import sys
import urllib.parse

LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}


class PortQuestionUnanswered(Exception):
    """Docker could not be asked, so nobody knows who holds the port."""


def holders(port):
    """Every running container publishing host `port`, as dicts.

    Each has `name`, `project`, `service`, `working_dir` (compose labels; `None`
    when the container was not made by compose) and `addresses` (the host IPs
    it publishes the port on). Raises [PortQuestionUnanswered] when Docker
    cannot be asked — callers must refuse on that, not treat it as "nobody".
    """
    port = str(port)
    try:
        ids = subprocess.run(["docker", "ps", "-q", "--no-trunc"],
                             capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PortQuestionUnanswered(f"`docker ps` could not run: {error}")
    if ids.returncode != 0:
        raise PortQuestionUnanswered(
            f"`docker ps` exited {ids.returncode}: {ids.stderr.strip()[-300:]}")
    running = ids.stdout.split()
    if not running:
        return []
    try:
        inspected = subprocess.run(["docker", "inspect", *running],
                                   capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise PortQuestionUnanswered(f"`docker inspect` could not run: {error}")
    if inspected.returncode != 0:
        # A container can exit between the two calls; inspect then fails for
        # the whole batch. Asking again is cheaper than guessing.
        raise PortQuestionUnanswered(
            f"`docker inspect` exited {inspected.returncode}: "
            f"{inspected.stderr.strip()[-300:]} — a container may have stopped "
            f"between the listing and the inspection; run again.")
    found = []
    for container in json.loads(inspected.stdout or "[]"):
        ports = ((container.get("NetworkSettings") or {}).get("Ports")) or {}
        addresses = sorted({
            (binding.get("HostIp") or "0.0.0.0")
            for bindings in ports.values() if bindings
            for binding in bindings
            if str(binding.get("HostPort")) == port
        })
        if not addresses:
            continue
        labels = ((container.get("Config") or {}).get("Labels")) or {}
        found.append({
            "name": (container.get("Name") or "").lstrip("/")
                    or container.get("Id", "")[:12],
            "project": labels.get("com.docker.compose.project"),
            "service": labels.get("com.docker.compose.service"),
            "working_dir": labels.get("com.docker.compose.project.working_dir"),
            "addresses": addresses,
        })
    return found


def listening(port, host="127.0.0.1", timeout=2):
    """Whether anything at all accepts a TCP connection on host:port.

    Only ever used to detect a holder Docker does not know about. It opens and
    closes a connection and sends nothing.
    """
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def describe(holder, port):
    who = f"container {holder['name']}"
    if holder["project"]:
        who += (f" (compose project '{holder['project']}', service "
                f"'{holder['service']}')")
    else:
        who += " (not started by docker compose)"
    return f"{who}, publishing port {port} on {', '.join(holder['addresses'])}"


def stop_hint(holder):
    """The command that frees the port — and, by swapping one word, restores it."""
    if holder["project"] and holder["service"] and holder["working_dir"]:
        command = (f"cd {holder['working_dir']} && docker compose -p "
                   f"{holder['project']} stop {holder['service']}")
    else:
        command = f"docker stop {holder['name']}"
    return (f"stop it with `{command}`, and afterwards run the same line with "
            f"`start` in place of `stop`.")


def check_free(port):
    """`None` if nothing holds `port`, else a paragraph naming what does."""
    try:
        found = holders(port)
    except PortQuestionUnanswered as error:
        return (f"Could not ask Docker what holds port {port}: {error}. "
                f"Refusing rather than assuming it is free.")
    if found:
        lines = [f"Port {port} is already taken, so this stack cannot bind it:"]
        for holder in found:
            lines.append(f"  - {describe(holder, port)}")
            lines.append(f"    {stop_hint(holder)}")
        return "\n".join(lines)
    if listening(port):
        return (f"Port {port} answers on 127.0.0.1, and no running container "
                f"publishes it — so it is a process outside Docker. On Linux "
                f"`sudo ss -ltnp 'sport = :{port}'` names it; on macOS "
                f"`lsof -nP -iTCP:{port} -sTCP:LISTEN`.")
    return None


def compose_project_of(compose):
    """The project a `docker compose ...` command line names with `-p`.

    `None` when it names none — in which case compose derives one from the
    directory, and in a clone that also serves TriTrack that is the real
    deployment's project. Callers treat `None` as a refusal.
    """
    words = shlex.split(compose) if isinstance(compose, str) else list(compose)
    for i, word in enumerate(words):
        if word in ("-p", "--project-name") and i + 1 < len(words):
            return words[i + 1]
        if word.startswith("--project-name="):
            return word.split("=", 1)[1]
    return None


def check_stack(base, project, service="server", compose=None):
    """`None` if `base` is served by `project`'s `service` and only by it.

    Otherwise a paragraph saying what is actually there. `compose`, when given,
    must name the same project with `-p`: an instrument that attacks one stack
    and reads another's database is measuring nothing, and a compose line with
    no `-p` resolves to the directory's default project — the real server's, in
    a clone that serves TriTrack.
    """
    parsed = urllib.parse.urlsplit(base)
    host, port = parsed.hostname, parsed.port
    if host not in LOOPBACK_HOSTS or port is None:
        return (f"{base} is not a port on this machine, so Docker here cannot "
                f"say who serves it. This drill only attacks a stack it can "
                f"identify; point BASE at http://localhost:<port>.")
    if compose is not None:
        named = compose_project_of(compose)
        if named is None:
            return (f"The compose command this run would use names no project "
                    f"(`{compose}` has no -p), so compose would pick the "
                    f"directory's default — in a clone that serves TriTrack, "
                    f"the real deployment's. Name `-p {project}` in COMPOSE, "
                    f"or leave COMPOSE unset.")
        if named != project:
            return (f"The compose command this run would use names project "
                    f"{named!r}, not {project!r} (`{compose}`). The instrument "
                    f"reads the database of whatever project that command "
                    f"names, so it must be the stack being attacked.")
    try:
        found = holders(port)
    except PortQuestionUnanswered as error:
        return (f"Could not ask Docker what holds port {port}: {error}. "
                f"Refusing to attack a server nobody has identified.")
    if not found:
        answering = listening(port)
        return (f"No running container publishes port {port}"
                + (", yet something answers there — a process outside Docker. "
                   if answering else ". ")
                + f"The {project!r} stack is not up, and nothing on {base} is "
                  f"it.")
    wrong = [h for h in found
             if h["project"] != project or h["service"] != service]
    if wrong:
        lines = [f"Port {port} is not held by the {project!r} stack's "
                 f"{service!r} alone:"]
        for holder in found:
            lines.append(f"  - {describe(holder, port)}")
        for holder in wrong:
            lines.append(f"  To free it: {stop_hint(holder)}")
        return "\n".join(lines)
    return None


def refuse_unless_stack(base, project, service="server", compose=None,
                        before="attacking it"):
    """Exit the process, loudly, unless [check_stack] passes.

    Call this before the first request to `base`. The message says what was
    found on the port instead, and what was *not* done because of it.
    """
    problem = check_stack(base, project, service=service, compose=compose)
    if problem is None:
        print(f"Port check: {base} is served by compose project {project!r}, "
              f"service {service!r}, and nothing else. Proceeding.")
        return
    raise SystemExit(
        "REFUSED — nothing was sent to the server.\n"
        f"{problem}\n"
        f"This run would have begun by {before}. It only does that to a "
        f"throwaway stack it can identify (task 11.310), because on a machine "
        f"that also serves TriTrack the port can belong to the real server.")


def _main(argv):
    usage = ("usage: port_holder.py free PORT\n"
             "       port_holder.py expect PORT PROJECT [SERVICE]")
    if len(argv) >= 2 and argv[0] == "free":
        problem = check_free(argv[1])
        if problem:
            print(problem)
            return 1
        print(f"Port {argv[1]}: nothing holds it.")
        return 0
    if len(argv) in (3, 4) and argv[0] == "expect":
        service = argv[3] if len(argv) == 4 else "server"
        problem = check_stack(f"http://localhost:{argv[1]}", argv[2],
                              service=service)
        if problem:
            print(problem)
            return 1
        print(f"Port {argv[1]}: held by compose project {argv[2]!r}, service "
              f"{service!r}, and nothing else.")
        return 0
    print(usage, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv[1:]))

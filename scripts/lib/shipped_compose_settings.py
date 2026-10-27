#!/usr/bin/env python3
# gate-instrument: none - a helper: prints the settings that make docker compose resolve the shipped defaults; verify_c3_cleartext_defaults(_stack) use it, and it runs nothing itself.
"""The settings under which `docker compose` resolves what ships (task 11.310).

Used by `verify_c3_cleartext_defaults.py` (imported) and
`verify_c3_cleartext_defaults_stack.sh` (run, to export the settings before its
`up`). A separate file rather than a flag on the check, because the stack
wrapper is held to naming the check on exactly one line — the one that runs it
(`server/test/security/shipped_defaults_test.dart`) — so that deleting that
line cannot leave a wrapper reporting PASS having checked nothing.

    python3 scripts/lib/shipped_compose_settings.py    # KEY=VALUE lines
"""
import os
import re
import secrets
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COMPOSE_FILE = os.path.join(ROOT, "docker-compose.yml")


def shipped_settings(**overrides):
    """The variables that make `docker compose` resolve the SHIPPED defaults.

    **Task 11.310.** Section 2 used to render the compose file with this
    machine's `.env` in play and call the result "the shipped defaults". On the
    Ubuntu VM that `.env` says `SERVER_PUBLISH_ADDRESS=0.0.0.0` — deliberately,
    so a phone can reach the development server — and the check reported B3
    live on a default that had not changed. It was measuring the operator's
    choice, not what ships.

    So every variable `docker-compose.yml` interpolates is set here, **empty**,
    and passed in the process environment, which Compose ranks above any
    `.env` file. Every one of them is written `${VAR:-default}`, `${VAR:?...}`,
    `${VAR:+...}` or bare, and in all four an empty value behaves exactly as an
    unset one — so empty is "what a clean checkout gets". The three the file
    *requires* (`POSTGRES_USER`, `_PASSWORD`, `_DB`) get throwaway values,
    because nothing about the publish address depends on them and the file
    refuses to resolve without them. `COMPOSE_PROFILES` is emptied too: a
    `.env` can switch on a profile, which is also an operator's choice.

    The variable list is read from the compose file rather than typed here, so
    a variable added to it later is neutralised without anybody remembering to.
    `overrides` sets a value on top — `verify_c3_cleartext_defaults.py` uses
    it once, to prove its render can still see a variable at all.
    """
    text = open(COMPOSE_FILE, encoding="utf-8").read()
    names = set(re.findall(r"\$\{([A-Za-z_][A-Za-z0-9_]*)", text))
    if "SERVER_PUBLISH_ADDRESS" not in names:
        sys.exit("Could not find SERVER_PUBLISH_ADDRESS among the variables "
                 "docker-compose.yml interpolates. Either the file changed how "
                 "it publishes the server — in which case this check must be "
                 "re-read against it — or this parser is broken. Either way it "
                 "must not go on rendering a file it no longer understands.")
    settings = {name: "" for name in sorted(names)}
    settings["COMPOSE_PROFILES"] = ""
    settings["POSTGRES_USER"] = "c3check"
    settings["POSTGRES_DB"] = "c3check"
    settings["POSTGRES_PASSWORD"] = secrets.token_hex(16)
    settings.update(overrides)
    return settings


if __name__ == "__main__":
    for key, value in shipped_settings().items():
        print(f"{key}={value}")

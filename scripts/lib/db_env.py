#!/usr/bin/env python3
# gate-instrument: none - a helper: the one place three instruments read
# Postgres credentials for a raw `psql` call; it runs nothing itself.
"""Postgres credentials for the instruments that go straight at the database.

`verify_c5_denial_audit.py`, `verify_11_49_server_reads.py` and
`gate_c_adversarial_pass.py` each carried a byte-identical block reading
`.env` by hand for `POSTGRES_USER`/`POSTGRES_DB`. Task 11.312 round 2: the
gate exports its own throwaway credentials
(`scripts/lib/shipped_compose_settings.py`, task 11.310) into the process
environment before running these three, and every copy of that block ignored
the environment and re-read `.env` — six of round one's seven VM reds, all
"role \"tritrack\" does not exist" against a database that only has
`c3check`. Compose itself ranks an exported variable above `.env`
(`shipped_compose_settings.py`'s own docstring); this mirrors that ranking
here, once, instead of three times.

An operator running one of these three scripts by hand, with nothing
exported, sees `.env` exactly as before — the environment only wins when
something is actually set there.

    from db_env import postgres_env
    env = postgres_env(ROOT)   # {"POSTGRES_USER": ..., "POSTGRES_DB": ...}
"""
import os


def postgres_env(root, names=("POSTGRES_USER", "POSTGRES_PASSWORD", "POSTGRES_DB")):
    env = {}
    for line in open(os.path.join(root, ".env")):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    for name in names:
        if name in os.environ:
            env[name] = os.environ[name]
    return env

#!/usr/bin/env bash
# gate-instrument: verify_c3_cleartext_defaults
# Task 10.95 (10.82 residual, K-7): gives `verify_c3_cleartext_defaults.py`
# its own compose lifecycle so it runs inside `gate_smoke_test.sh`'s
# one-command pass instead of only when someone remembers to run it by hand
# (`TriTrack_Security_Model.md`: "wiring it in means giving it its own
# compose lifecycle inside the smoke test, the way `verify_i1_source_identity.sh`
# and `verify_h6_archive_forgery.sh` already do").
#
# A dedicated project name and its own throwaway volumes, for two reasons:
#   - This check is specifically about the SHIPPED, unmodified
#     docker-compose.yml defaults (loopback-only publish, TRITRACK_ENV not
#     defaulted to development). Running it against `gate_smoke_test.sh`'s own
#     "tritrack-gate" project would mean checking the e2e overlay's rewritten
#     ports instead of the artifact this check exists to prove.
#   - Reusing (or guessing) a developer's own default-named `docker compose up`
#     project is exactly the shape F15 (task 10.27) found destructive; a
#     private project name that this script alone owns avoids it entirely.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

export COMPOSE_PROJECT_NAME="tritrack-c3-check"
# `docker-compose.yml` and `verify_c3_cleartext_defaults.py` both honor
# SERVER_PORT (defaulting to 8080), specifically so this stack can run
# alongside gate_smoke_test.sh's own already-up "tritrack-gate" e2e stack
# (also on 8080) in the same one-command pass without a port collision. The
# check itself is about the PUBLISH ADDRESS (loopback-only), not the literal
# port number, so this changes nothing about what C-3 actually verifies.
C3_PORT="${SERVER_PORT:-8180}"

# **The SHIPPED settings, not this machine's — task 11.310.** Until 2026-09-23
# the `up` below read this machine's `.env`, so on the Ubuntu VM — whose `.env`
# publishes on 0.0.0.0, deliberately, so a phone can reach its development
# server — this stack came up on every interface, and section 3 then reported
# "the LAN address reaches it — B3 live" about a setting that ships nowhere.
# `scripts/lib/shipped_compose_settings.py` prints the shipped settings (every
# variable the compose file reads, empty, which Compose ranks above `.env`;
# throwaway database credentials; no profiles); they are exported here so `up`,
# the check itself and `down` all see the same configuration. SERVER_PORT is
# then set back to this stack's own port — the only value that differs from a
# clean checkout, and not one C-3 is about.
SETTINGS="$(mktemp "${TMPDIR:-/tmp}/tritrack-c3-settings.XXXXXX")"
python3 scripts/lib/shipped_compose_settings.py >"$SETTINGS"
[ -s "$SETTINGS" ] || { echo "could not derive the shipped compose settings" >&2; exit 1; }
set -a
# shellcheck disable=SC1090  # generated just above
. "$SETTINGS"
set +a
rm -f "$SETTINGS"
export SERVER_PORT="$C3_PORT"

cleanup() {
  docker compose -f docker-compose.yml down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

# `postgres server` only, like every other stack the gate brings up (task
# 11.310). Section 3 asks what the server and the database publish; the backup
# scheduler and the three retention services publish nothing, and starting
# them here only meant a throwaway stack running a backup loop.
docker compose -f docker-compose.yml up --build -d postgres server
python3 scripts/verify_c3_cleartext_defaults.py

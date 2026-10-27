#!/usr/bin/env bash
# gate-instrument: none - needs a TLS-terminating deployment, which the gate does not stand up; see SECURITY_SCOPE_AND_EXIT.md.
# TLS termination drill (task 10.49 / Security Model §4.1, §8.6).
#
#   scripts/verify_tls_termination.sh
#
# Three straight gates swept for nginx/Caddy/Traefik/certbot/letsencrypt and
# found nothing outside CLAUDE_DOCS/. `docker-compose.tls.yml` +
# `proxy/Caddyfile` is that artifact; this is the re-runnable proof it works,
# on the same reasoning `backup_restore_drill.sh` exists for §4.9 — a control
# with no failing-path check is decoration, and "trust the comment" is
# exactly the shape that let G-2 survive one prior gate's verification.
#
# What it proves, in order:
#   1. Brings the TLS overlay up with a throwaway, self-signed origin
#      certificate and TRITRACK_TLS_DOMAIN=localhost.
#   2. `server` starts with its own TLS satisfied, not refused —
#      TRITRACK_ALLOW_CLEARTEXT_LAN=1 (hardcoded in the base file) plus
#      TRITRACK_ENV=production (which the overlay sets) is otherwise a
#      documented refusal; server/README.md's table is what this checks.
#   3. Caddy issues from its own internal CA for `localhost` — not ACME —
#      confirming the automatic-HTTPS heuristic the real-deployment path
#      also depends on, without needing a real domain to prove it.
#   4. A chain-VERIFIED request (not `-k`) through the proxy to `/health`
#      succeeds — real termination and real forwarding, not just a response.
#   5. The origin is not reachable directly: only the proxy's ports were
#      published, so a client that skipped Caddy entirely has nothing to
#      connect to.
#
# What this does NOT and cannot prove — the real-host check (DNS for a real
# domain, ports 80/443 open to the internet, Caddy issuing from ACME, an
# unmodified device trusting the result) has no host to run against. See
# server/README.md's "TLS termination" section and Security Model §8.6.
#
# Runs against its own compose project and its own volumes; everything it
# creates, including the throwaway certificate, is destroyed on exit.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROJECT="tritrack-tls-drill"
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.tls.yml)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-tls-drill.XXXXXX")"
chmod 700 "$WORK"

CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  step "Tearing down"
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$WORK"
  echo "  removed throwaway certificate and drill volumes"
}
trap cleanup EXIT

# `.env` is loaded in exactly one place — see that file for why (task
# 11.40 / 11.52). This used to be an eight-line block copied into seven
# scripts.
. scripts/lib/load_env.sh

step "1. Generating a throwaway self-signed origin certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/origin.key" -out "${WORK}/origin.crt" \
  -subj "/CN=tritrack-tls-drill" >/dev/null 2>&1
[ -s "${WORK}/origin.crt" ] && [ -s "${WORK}/origin.key" ] \
  || fail "openssl did not produce a certificate pair"
pass "generated a throwaway origin certificate, never committed"

# Drill-local overrides. Exported values beat .env in compose, so the
# operator's real POSTGRES_* and TRITRACK_TLS_DOMAIN (if they have a real
# deployment configured) do not leak into this drill, and this drill's
# throwaway values do not leak into a real run afterward.
export POSTGRES_USER="${POSTGRES_USER:-tritrack}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-drill-only-not-a-real-secret}"
export POSTGRES_DB="${POSTGRES_DB:-tritrack}"
export TRITRACK_DIAGNOSTICS_ENABLED="false"
export TRITRACK_TLS_DOMAIN="localhost"
export TRITRACK_TLS_ORIGIN_CERT="${WORK}/origin.crt"
export TRITRACK_TLS_ORIGIN_KEY="${WORK}/origin.key"
export TRITRACK_TLS_PUBLISH_ADDRESS="127.0.0.1"
# Task 10.74 (finding K-2): the overlay's allowlist now requires an answer to
# "how do callers reach the proxy?", and the server refuses to start without
# one. True here: 80/443 are published to loopback on the line above and every
# caller in this drill is this host or a container on the compose network. A
# deployment a phone can reach needs `probe-verified` and a passing
# `scripts/verify_source_identity.sh` run to earn it.
export TRITRACK_PROXY_SOURCE_IDENTITY="on-network-only"
# Task 11.287: a production server now refuses to start with no sign-in
# relay, because the alternative was a server that answered every sign-in
# request with 202 and delivered nothing. This drill has no relay and proves
# nothing about mail, so it names one that does not exist — the server starts,
# its startup probe reports the relay unreachable in the log, and every step
# below is about the proxy in front of it. `scripts/verify_smtp_delivery.sh`
# is the instrument for the relay itself.
export TRITRACK_SMTP_HOST="127.0.0.1"
export TRITRACK_SMTP_FROM="tritrack-drill@localhost"
# 443/80 are fixed in docker-compose.tls.yml, not parameterized — a real
# deployment cannot move them without every client also being told to, so
# this drill exercises the same fixed ports rather than a stand-in.

step "2. Bringing up the TLS overlay"
"${COMPOSE[@]}" up --build -d >"${WORK}/compose-up.log" 2>&1 || {
  cat "${WORK}/compose-up.log"
  fail "could not bring the stack up — see above"
}
pass "stack came up"

# Task 11.176 looked at both loops in this step and the next, and left both.
# Each reads the subject's own container log, and every failure path prints
# that log in full — the two behaviours that task existed to spread. The
# refusal branch below is the one it named as the shape worth copying.
step "3. Waiting for the server's own TLS to come up, not refuse"
UP=0
for _ in $(seq 1 60); do
  if "${COMPOSE[@]}" logs server 2>/dev/null | grep 'listening on https://' >/dev/null; then
    UP=1
    break
  fi
  if "${COMPOSE[@]}" logs server 2>/dev/null | grep -i 'REFUSING TO START' >/dev/null; then
    "${COMPOSE[@]}" logs server
    fail "the origin refused to start — TRITRACK_ALLOW_CLEARTEXT_LAN=1 plus TRITRACK_ENV=production without the origin certificate is exactly this refusal; see server/README.md's table"
  fi
  sleep 1
done
[ "$UP" = "1" ] || {
  "${COMPOSE[@]}" logs server
  fail "the origin never logged that it was listening on https://"
}
pass "server started with its own TLS satisfied, not cleartext and not refused"

step "4. Waiting for Caddy to obtain a certificate"
ISSUED=0
for _ in $(seq 1 60); do
  if "${COMPOSE[@]}" logs proxy 2>/dev/null | grep '"certificate obtained successfully"' >/dev/null; then
    ISSUED=1
    break
  fi
  sleep 1
done
[ "$ISSUED" = "1" ] || {
  "${COMPOSE[@]}" logs proxy
  fail "Caddy never logged a successfully obtained certificate"
}
"${COMPOSE[@]}" logs proxy 2>/dev/null | grep '"issuer":"local"' >/dev/null \
  || fail "certificate was NOT issued by Caddy's internal CA — TRITRACK_TLS_DOMAIN=localhost should never reach ACME; check proxy/Caddyfile's automatic-HTTPS heuristic"
pass "Caddy issued a certificate from its own internal CA for 'localhost' — not ACME, as a local domain should"

step "5. Verifying the certificate chain and end-to-end forwarding"
"${COMPOSE[@]}" exec -T proxy cat /data/caddy/pki/authorities/local/root.crt \
  > "${WORK}/caddy-root.crt" 2>/dev/null
[ -s "${WORK}/caddy-root.crt" ] || fail "could not export Caddy's local root CA"

BODY="$(curl -sS --cacert "${WORK}/caddy-root.crt" \
  "https://localhost:443/health" 2>"${WORK}/curl.err")" || {
  cat "${WORK}/curl.err" >&2
  fail "chain-verified https request to /health failed"
}
[ "$BODY" = '{"status":"ok"}' ] \
  || fail "unexpected response body: $BODY"
pass "chain-verified https request through the proxy reached the real server"

# A request trusting the WRONG anchor must still fail — proving the check
# above is a real chain verification and not an artifact of curl's defaults.
#
# Task 10.54 / Security Model §11.5: this used to pass `--cacert /dev/null`
# and treat ANY non-zero curl exit as "correctly refused", which cannot fail —
# demonstrated live against a port with nothing listening (exit 7) and an
# unresolvable name (exit 6), neither of which says anything about chain
# verification. `/dev/null` turned out to be a second problem on top of that:
# an empty CA file makes some curl/TLS-backend combinations fail to even load
# it (exit 77, "error setting certificate verify locations") before a TLS
# handshake is attempted at all — also not chain verification. A throwaway,
# genuinely unrelated CA certificate forces an actual handshake that actually
# fails verification, which is curl's exit 60 on every backend tested.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/unrelated.key" -out "${WORK}/unrelated.crt" \
  -subj "/CN=tritrack-tls-drill-unrelated" >/dev/null 2>&1
[ -s "${WORK}/unrelated.crt" ] || fail "could not generate the unrelated CA certificate"
NOTRUST_STATUS=0
curl -sS --cacert "${WORK}/unrelated.crt" "https://localhost:443/health" \
    >/dev/null 2>"${WORK}/curl-notrust.err" || NOTRUST_STATUS=$?
[ "$NOTRUST_STATUS" = "60" ] || {
  cat "${WORK}/curl-notrust.err" >&2
  fail "a request trusting an unrelated CA exited ${NOTRUST_STATUS}, not curl's SSL-verification-failed code (60) — this proves nothing about chain verification (see above for curl's stderr)"
}
pass "a request trusting an unrelated CA fails specifically on certificate verification (curl exit 60)"

step "6. Verifying the origin is not directly reachable"
# Task 10.54 / Security Model §11.5: this used to curl a hardcoded
# `localhost:8080` — wrong when `.env` sets a different SERVER_PORT, and even
# at the right port it is a bare host-level probe any OTHER stack bound to
# that port can satisfy, unrelated to whether THIS drill's own `ports:
# !override []` took effect. Demonstrated live: a false FAIL when an
# unrelated stack held 8080, and it probes http:// against a listener that,
# were it published at all, would only speak TLS — failing for the wrong
# reason either way. `docker compose port` asks Docker directly whether THIS
# project's own `server` service publishes anything, which is the only
# question this step is actually supposed to answer.
# `docker compose port` exits 0 and prints the literal string "invalid IP:0"
# for a container-port with no published mapping (verified against Docker
# Compose v5.3.1) — it is not empty output and not a non-zero exit, so both
# have to be checked for, not just one.
#
# This exact site is `Cf`'s defect (Security Model §12.7 / §11.12),
# reintroduced by 10.54 in the very step that rewrote this check to fix a
# DIFFERENT bug: `2>/dev/null || true` discards `docker compose port`'s own
# exit code, so a broken invocation — wrong project, missing compose file,
# docker itself unreachable — prints nothing and is indistinguishable from
# the genuine "not published" case, which also prints nothing. Demonstrated
# live: pointing COMPOSE at a nonexistent compose file made this step PASS
# with "the origin is not reachable" while never having asked Docker
# anything. The exit code has to be captured and checked, not discarded.
set +e
PORT_OUT="$("${COMPOSE[@]}" port server 8080 2>"${WORK}/port.err")"
PORT_STATUS=$?
set -e
if [ "$PORT_STATUS" -ne 0 ]; then
  cat "${WORK}/port.err" >&2
  fail "docker compose port exited ${PORT_STATUS} — could not ask Docker whether the origin is published (see stderr above); this is not evidence the origin is unreachable"
fi
PUBLISHED="$PORT_OUT"
[ -z "$PUBLISHED" ] || [ "$PUBLISHED" = "invalid IP:0" ] \
  || fail "docker compose reports the origin published at '$PUBLISHED' — docker-compose.tls.yml's ports: !override [] did not take effect"
pass "docker compose reports no published port for the origin in this project; the proxy is the only way in"

echo
echo "DRILL PASSED — ${CHECKS} checks"
echo "This verifies the LOCAL, self-signed path only. The real-host check —"
echo "a real domain, DNS, ports 80/443 open to the internet, Caddy issuing"
echo "from ACME, an unmodified device trusting the result — has no host in"
echo "this repository to run against. See server/README.md's \"TLS"
echo "termination\" section and Security Model §8.6."

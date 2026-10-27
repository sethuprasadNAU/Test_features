#!/usr/bin/env bash
# gate-instrument: verify_i1_source_identity
# Source-identity drill (task 10.52 / Security Model §4.4, §11.3 — finding I-1).
#
#   scripts/verify_i1_source_identity.sh
#
# **Why this exists rather than a unit test.** I-1 survived four security gates
# with a full set of green per-source rate-limit tests, because every one of
# them constructed the source address in-process and none of them ever ran
# behind the reverse proxy §4.1 mandates. The control was correct in the only
# configuration nobody deploys. §11.3 found it by attacking a live stack, so
# this proves the fix the same way — task 10.54's "a control measured in a
# configuration that disables it" is the class, and this is I-1's arm of it.
#
# What it proves, in order:
#   1. Behind Caddy, two distinct clients get two distinct rate-limit buckets:
#      a flood from one gets an honest 429, and an UNRELATED client still gets
#      its 202. That is task 10.52's acceptance criterion, verbatim.
#   2. The audit rows carry the clients' addresses and not the proxy's — C-5's
#      forensic contribution, which §11.3 measured at 158 events with one
#      distinct source_address between them.
#   3. **The negative control, which is the part §11.5 says most instruments
#      are missing.** Re-run with the allowlist pointed at the wrong address so
#      the header is (correctly) ignored, and the merged bucket must come back:
#      the innocent client must be refused. If it is NOT refused, this script
#      cannot tell a working limiter from a broken one and reports FAIL rather
#      than a reassuring PASS.
#   4. A production server with no declared posture REFUSES TO START, which is
#      the structural half of the fix — the reason the next task that ships a
#      proxy cannot repeat 10.49's omission.
#   5. **The diagnostics console still fails closed behind the proxy** (§11.3,
#      §4.10). This is a regression guard on a property that was verified, not
#      assumed, and that task 10.52 was explicitly told not to break: the
#      console's loopback gate reads the raw TCP peer and must never consult
#      the forwarding header this task taught the rate limiter to read.
#
# Runs against its own compose project, its own subnet and its own volumes;
# everything it creates, including the throwaway certificate, is destroyed on
# exit. Modelled on scripts/verify_tls_termination.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROJECT="tritrack-i1-drill"
# Step 6 appends a third file to this; see `bring_up`.
COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.tls.yml)
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-i1-drill.XXXXXX")"
chmod 700 "$WORK"

# A subnet of this drill's own, so it never collides with a real stack the
# operator may have up, and so the client containers below can take fixed
# addresses this script can assert on by name.
SUBNET="172.31.243.0/24"
PROXY_IP="172.31.243.10"
ATTACKER_IP="172.31.243.50"
INNOCENT_IP="172.31.243.51"
NETWORK="${PROJECT}_default"
CURL_IMAGE="curlimages/curl:8.11.1"

CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

stop_clients() {
  docker rm -f "${PROJECT}-attacker" "${PROJECT}-innocent" >/dev/null 2>&1 || true
}

# The backup image is built on the Postgres image, which declares its data
# directory a VOLUME; the stack's backup-scheduler mounts nothing there, so
# Docker gives every one of its containers an *anonymous* volume (a 64-hex-digit
# name). `compose down` removes the container and leaves that volume, which is
# how this drill left two behind on the VM every night (task 11.330): once at
# the mid-run `down` in step 6, which must not use `-v` because that would also
# delete the drill's named database volume between the two arms. So: read the
# anonymous volumes off the project's containers before taking them down, then
# remove exactly those. **Named volumes are never touched**, and nothing here
# uses `docker volume prune`, which would reach other projects' volumes.
project_anonymous_volumes() {
  local c
  for c in $(docker ps -aq --filter "label=com.docker.compose.project=${PROJECT}"); do
    docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$c"
  done | grep -E '^[0-9a-f]{64}$' || true
}

# compose_down [down options] — `down`, then remove the anonymous volumes it left.
compose_down() {
  local leftovers v
  leftovers="$(project_anonymous_volumes)"
  "${COMPOSE[@]}" down "$@" >/dev/null 2>&1 || true
  for v in $leftovers; do
    docker volume rm "$v" >/dev/null 2>&1 || true
  done
}

cleanup() {
  step "Tearing down"
  stop_clients
  compose_down -v --remove-orphans
  rm -rf "$WORK"
  echo "  removed throwaway certificate, client containers and drill volumes"
}
trap cleanup EXIT

# `.env` is loaded in exactly one place — see that file for why (task
# 11.40 / 11.52). This used to be an eight-line block copied into seven
# scripts.
. scripts/lib/load_env.sh

step "0. Preparing a throwaway origin certificate and drill-local settings"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "${WORK}/origin.key" -out "${WORK}/origin.crt" \
  -subj "/CN=tritrack-i1-drill" >/dev/null 2>&1
[ -s "${WORK}/origin.crt" ] || fail "openssl did not produce a certificate pair"

# Exported values beat .env in compose, so a real deployment's configuration
# does not leak into this drill and this drill's throwaway values do not leak
# back out.
export POSTGRES_USER="${POSTGRES_USER:-tritrack}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-drill-only-not-a-real-secret}"
export POSTGRES_DB="${POSTGRES_DB:-tritrack}"
export TRITRACK_TLS_DOMAIN="localhost"
export TRITRACK_TLS_ORIGIN_CERT="${WORK}/origin.crt"
export TRITRACK_TLS_ORIGIN_KEY="${WORK}/origin.key"
export TRITRACK_TLS_PUBLISH_ADDRESS="127.0.0.1"
export TRITRACK_TLS_PROXY_SUBNET="$SUBNET"
export TRITRACK_TLS_PROXY_ADDRESS="$PROXY_IP"
# Task 10.74 (finding K-2): an allowlist deployment must say how callers reach
# its proxy, and the server refuses to start until it does. `on-network-only`
# is the true answer for THIS DRILL and only for it — both clients below are
# containers on the compose network reaching Caddy directly, crossing no host
# publish path, which is exactly the shape whose identity survives by
# construction. That is also this drill's blind spot, and the reason K-2 stayed
# invisible through four gates while this script passed: a real caller crosses
# the publish path first, and `scripts/verify_source_identity.sh` is the
# instrument for that question.
export TRITRACK_PROXY_SOURCE_IDENTITY="on-network-only"
# Enabled ONLY so step 4 can tell "refused" apart from "not mounted": with the
# console off, its routes 404 like any other nonexistent path, and a 404 would
# not prove the loopback gate ran at all.
#
# **Task 10.80 made this drill's own configuration illegal, and that is the
# control working.** Security Model §4.10 has always said the console is never
# enabled on a production deployment; nothing enforced it until 10.80, and
# `docker-compose.tls.yml` hardcodes `TRITRACK_ENV: production`. So this drill
# had been proving the loopback gate in a configuration the model forbids, and
# the moment the rule became a startup refusal the whole stack stopped coming
# up — measured, not predicted. The remedy is in `bring_up` below: the stack
# runs non-production so the console can be mounted, and step 5 puts
# production back on the one-off container that actually asserts about it.
# Nothing here weakens what any step proves — **the loopback gate does not
# read TRITRACK_ENV**; it reads the raw TCP peer, which is the whole point.
export TRITRACK_DIAGNOSTICS_ENABLED="true"
export TRITRACK_DIAGNOSTICS_ALLOW_REMOTE="false"
# At least 32 characters since task 10.80: the console's token is its entire
# authentication and the server now refuses to start on a shorter one. The
# previous value here was 28, so this line and that floor are coupled — if
# this ever shortens, the whole drill fails at bring-up, loudly.
export TRITRACK_DIAGNOSTICS_TOKEN="drill-only-diagnostics-token-not-a-real-secret"
pass "drill-local settings prepared; nothing here is read from a real .env"

docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 || {
  echo "  pulling ${CURL_IMAGE}..."
  docker pull -q "$CURL_IMAGE" >/dev/null || fail "could not pull $CURL_IMAGE"
}

# Brings the stack up and waits for the origin to report TLS.
#
# With no argument the stack is exactly the two files a real deployment uses,
# TRITRACK_TRUSTED_PROXIES included — step 2 has to attack the SHIPPED
# configuration, not one this script assembled. Given an address, a third
# overlay written into $WORK replaces the allowlist for the negative control.
#
# **This indirection is itself a finding from writing the drill.** The first
# version passed the value as an environment variable, which silently did
# nothing: docker-compose.tls.yml hardcodes TRITRACK_TRUSTED_PROXIES, so the
# "negative control" arm ran the correct configuration and reported that the
# bug did not come back. Exactly the vacuous pass §11.5 catalogues — caught
# here only because the control was written to fail loudly when it proves
# nothing.
bring_up() {
  COMPOSE=(docker compose -p "$PROJECT" -f docker-compose.yml -f docker-compose.tls.yml)
  # TRITRACK_ENV is overridden on every arm, not only the control one — see the
  # settings block above. `docker-compose.tls.yml` hardcodes it to production,
  # and since task 10.80 a production server refuses to start with the
  # diagnostics console enabled (§4.10), which steps 4 needs mounted. The
  # override is named rather than blank so a reader of `docker compose config`
  # sees a deliberate value instead of wondering whether it was lost.
  {
    echo "services:"
    echo "  server:"
    echo "    environment:"
    echo "      TRITRACK_ENV: drill"
    if [ "$#" -gt 0 ]; then
      echo "      TRITRACK_TRUSTED_PROXIES: \"$1\""
    fi
  } >"${WORK}/override.yml"
  COMPOSE+=(-f "${WORK}/override.yml")
  "${COMPOSE[@]}" up --build -d \
    >"${WORK}/compose-up.log" 2>&1 || {
    cat "${WORK}/compose-up.log"
    fail "could not bring the stack up — see above"
  }
  # Task 11.176 looked at this loop and deliberately left it. It reads the
  # server's own log rather than a proxy for it, it separates "refused to
  # start" from "not up yet", and both exits print the whole log — so the
  # evidence the h6 loop threw away sixty times is already surfaced here.
  local up=0
  for _ in $(seq 1 60); do
    if "${COMPOSE[@]}" logs server 2>/dev/null | grep 'listening on https://' >/dev/null; then
      up=1
      break
    fi
    if "${COMPOSE[@]}" logs server 2>/dev/null | grep 'REFUSING TO START' >/dev/null; then
      "${COMPOSE[@]}" logs server
      fail "the origin refused to start — see the log above"
    fi
    sleep 1
  done
  [ "$up" = "1" ] || {
    "${COMPOSE[@]}" logs server
    fail "the origin never logged that it was listening"
  }
}

# Two long-lived client containers on the compose network, at fixed addresses
# this script can then assert on by name in the audit log.
#
# Long-lived rather than one `docker run --rm` per request, deliberately: with
# a fixed `--ip`, Docker's asynchronous teardown can still be holding the
# address when the next container asks for it, and the resulting failure looked
# exactly like a drill step producing no output at all. Recreated after each
# `compose down` in step 6, since that removes the network they sit on.
start_clients() {
  stop_clients
  local name ip
  for pair in "attacker:${ATTACKER_IP}" "innocent:${INNOCENT_IP}"; do
    name="${pair%%:*}"
    ip="${pair##*:}"
    docker run -d --name "${PROJECT}-${name}" --network "$NETWORK" --ip "$ip" \
      --entrypoint sh "$CURL_IMAGE" \
      -c 'while true; do sleep 30; done' >/dev/null \
      || fail "could not start the ${name} client container at ${ip}"
  done
}

# One HTTP request from a named client container, through Caddy. Prints the
# status code, having written the body to $2.
#
# `--resolve` rather than a Host header: it must be a real TLS handshake with
# SNI=localhost so Caddy serves the site it issued a certificate for, and `-k`
# because that certificate is from Caddy's internal CA (verify_tls_termination
# .sh is where the chain itself is proven; this drill is about what the origin
# sees, not about the certificate).
client_curl() {
  local name="$1"
  shift
  docker exec "${PROJECT}-${name}" curl \
    -k -sS -o /dev/null -w '%{http_code}' \
    --resolve "localhost:443:${PROXY_IP}" "$@"
}

request_link() {
  local name="$1" email="$2"
  client_curl "$name" \
    -X POST "https://localhost/auth/magic-link" \
    -H 'content-type: application/json' \
    -d "{\"email\":\"${email}\"}"
}

psql_query() {
  "${COMPOSE[@]}" exec -T postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1" 2>/dev/null | tr -d ' '
}

# The attack §11.3 ran live: a flood of distinct addresses from one client,
# then one request from an unrelated one. Echoes "<attacker_status>
# <innocent_status>".
run_attack() {
  local tag="$1" status
  for i in $(seq 1 12); do
    status="$(request_link attacker "attacker-${tag}-${i}@example.com")"
    echo "    attacker request ${i}: ${status}" >&2
  done
  local attacker_final innocent
  attacker_final="$(request_link attacker "attacker-${tag}-13@example.com")"
  innocent="$(request_link innocent "innocent-biologist-${tag}@nau.edu")"
  echo "${attacker_final} ${innocent}"
}

# ---------------------------------------------------------------------------

step "1. Bringing up the TLS stack with the proxy correctly declared"
bring_up
start_clients
pass "stack up; TRITRACK_TRUSTED_PROXIES=${PROXY_IP}, two clients at ${ATTACKER_IP} and ${INNOCENT_IP}"

# Task 10.90: this drill's own postgres volume is torn down in the EXIT trap
# above, so under normal operation `auth_audit_log` is empty here. But step 3
# and step 6 below assert on ABSOLUTE counts and fixed, non-randomized client
# IPs (ATTACKER_IP/INNOCENT_IP/PROXY_IP never change between runs) — if the
# trap ever failed to fire (host crash, `docker kill`, daemon restart mid-run)
# and this volume survived with rows from a prior successful run at those same
# addresses, those absolute checks could report HELD from old rows even if a
# regression stopped THIS run's requests from being logged at all. Snapshot
# counts now, before any of this run's traffic exists, and require growth —
# the same before/after idiom verify_c5_denial_audit.py uses — so a stale
# volume can only make this drill fail loud, never pass quiet.
BEFORE_ATTACKER_ROWS="$(psql_query "SELECT count(*) FROM auth_audit_log WHERE source_address = '${ATTACKER_IP}'")"
BEFORE_INNOCENT_ROWS="$(psql_query "SELECT count(*) FROM auth_audit_log WHERE source_address = '${INNOCENT_IP}'")"
BEFORE_PROXY_ROWS="$(psql_query "SELECT count(*) FROM auth_audit_log WHERE source_address = '${PROXY_IP}'")"

step "2. The attack from §11.3, behind Caddy"
read -r ATTACKER_STATUS INNOCENT_STATUS <<<"$(run_attack correct)"
[ "$ATTACKER_STATUS" = "429" ] \
  || fail "the flooding client was NOT refused (got $ATTACKER_STATUS) — the per-source limit is not running at all"
pass "the flooding client is refused with an honest 429"

[ "$INNOCENT_STATUS" = "202" ] \
  || fail "an UNRELATED client got $INNOCENT_STATUS — this is finding I-1: ten unauthenticated requests are denying magic-link sign-in to every user of the deployment"
pass "an unrelated client is unaffected — the buckets are genuinely per-source"

step "3. What the audit log can say about who did it (C-5, §4.7)"
DISTINCT="$(psql_query "SELECT count(DISTINCT source_address) FROM auth_audit_log")"
[ "${DISTINCT:-0}" -ge 2 ] \
  || fail "auth_audit_log holds ${DISTINCT:-0} distinct source_address values — §11.3 measured exactly this (158 events, one address) and it voids C-5's forensic contribution"
pass "audit rows carry ${DISTINCT} distinguishable source addresses"

if psql_query "SELECT count(*) FROM auth_audit_log WHERE source_address = '${PROXY_IP}'" | grep -v '^0$' >/dev/null; then
  fail "audit rows name the proxy (${PROXY_IP}) instead of the caller"
fi
pass "no audit row names the proxy — every one names a client"

AFTER_ATTACKER_ROWS="$(psql_query "SELECT count(*) FROM auth_audit_log WHERE source_address = '${ATTACKER_IP}'")"
AFTER_INNOCENT_ROWS="$(psql_query "SELECT count(*) FROM auth_audit_log WHERE source_address = '${INNOCENT_IP}'")"
# Growth since step 1's snapshot, not mere presence — a stale volume from a
# prior successful run could already hold rows at these same fixed addresses,
# which would satisfy a presence check even if THIS run's audit writes never
# happened. See the note above step 2.
[ "${AFTER_ATTACKER_ROWS:-0}" -gt "${BEFORE_ATTACKER_ROWS:-0}" ] \
  || fail "no NEW audit row names ${ATTACKER_IP} since this run's attack (before=${BEFORE_ATTACKER_ROWS:-0}, after=${AFTER_ATTACKER_ROWS:-0}), which really did send requests"
[ "${AFTER_INNOCENT_ROWS:-0}" -gt "${BEFORE_INNOCENT_ROWS:-0}" ] \
  || fail "no NEW audit row names ${INNOCENT_IP} since this run's attack (before=${BEFORE_INNOCENT_ROWS:-0}, after=${AFTER_INNOCENT_ROWS:-0}), which really did send requests"
pass "both real client addresses gained audit rows during this run's attack"

step "4. The diagnostics console still fails closed behind the proxy (§4.10)"
# Must survive task 10.52: the console's loopback gate reads the raw TCP peer,
# never the forwarding header. If it ever consulted the header, this request —
# which can set no header Caddy will not overwrite — would still be refused,
# but a future refactor routing the gate through SourceIdentity would let a
# caller claim 127.0.0.1 and walk in.
CONSOLE_BODY="$(docker exec "${PROJECT}-attacker" curl -k -sS \
  --resolve "localhost:443:${PROXY_IP}" \
  -H "authorization: Bearer ${TRITRACK_DIAGNOSTICS_TOKEN}" \
  "https://localhost/diagnostics/health" || true)"
CONSOLE_STATUS="$(client_curl attacker \
  -H "authorization: Bearer ${TRITRACK_DIAGNOSTICS_TOKEN}" \
  "https://localhost/diagnostics/health")"
[ "$CONSOLE_STATUS" = "403" ] \
  || fail "the diagnostics console answered ${CONSOLE_STATUS} through the proxy, not 403 — it is enabled in this drill, so 404 would mean the routes vanished and 200 would mean the loopback gate was defeated"
grep -q 'diagnostics_console_local_only' <<<"$CONSOLE_BODY" \
  || fail "403 came from somewhere other than the loopback gate: ${CONSOLE_BODY}"
pass "the console refuses with diagnostics_console_local_only, as §11.3 verified"

step "5. A production server with no declared posture refuses to start"
# `-e TRITRACK_ENV=production` because `bring_up` runs the stack non-production
# so that step 4 can have a console at all (task 10.80, §4.10). This is the one
# step whose claim is about production, so this is where production belongs —
# and on a one-off container, which is what `run --rm --no-deps` builds.
# TRITRACK_DIAGNOSTICS_ENABLED is unset for the same run: with production back
# on, the console's own refusal would fire first and this step would grep for a
# source-identity refusal in a diagnostics one. That is not a hypothetical —
# both refusals exit 78 and both print "REFUSING TO START".
REFUSAL="$(TRITRACK_TRUSTED_PROXIES="" "${COMPOSE[@]}" run --rm --no-deps \
  -e TRITRACK_TRUSTED_PROXIES= \
  -e TRITRACK_ENV=production \
  -e TRITRACK_DIAGNOSTICS_ENABLED=false server 2>&1 || true)"
grep -q 'REFUSING TO START — source identity' <<<"$REFUSAL" \
  || fail "a production server with TRITRACK_TRUSTED_PROXIES unset started anyway — the structural half of the fix is gone. Output was: ${REFUSAL}"
grep -q 'ONE BUCKET SHARED BY EVERY USER' <<<"$REFUSAL" \
  || fail "the refusal does not name the consequence, so the operator reading it cannot tell whether it matters"
pass "refuses to start, and the message names the denial of service"

step "6. NEGATIVE CONTROL — with the allowlist wrong, the bug must come back"
# §11.5's standing complaint about this repository's instruments is controls
# that cannot fail. Pointing the allowlist at an address that is not the proxy
# makes the origin (correctly) ignore the header, which restores exactly the
# collapsed bucket §11.3 found. If steps 2 and 3 still pass here, they were
# never measuring anything.
stop_clients
compose_down
bring_up "203.0.113.254"
start_clients
read -r CONTROL_ATTACKER CONTROL_INNOCENT <<<"$(run_attack control)"
[ "$CONTROL_ATTACKER" = "429" ] \
  || fail "the negative-control arm did not even refuse the flooder (got $CONTROL_ATTACKER); this drill is not attacking anything"
[ "$CONTROL_INNOCENT" = "429" ] \
  || fail "with the allowlist pointed at the wrong address, the innocent client got ${CONTROL_INNOCENT} instead of 429. The merged bucket did NOT come back, which means steps 2 and 3 above are not measuring the control they claim to."
pass "the collapsed bucket returns when the allowlist is wrong — steps 2-3 are real measurements"

CONTROL_PROXY_ROWS="$(psql_query "SELECT count(*) FROM auth_audit_log WHERE source_address = '${PROXY_IP}'")"
[ "${CONTROL_PROXY_ROWS:-0}" -ge 1 ] \
  || fail "the negative-control arm produced no audit row naming the proxy, so step 3's assertion is not measuring anything either"
pass "and the audit log collapses onto the proxy address, as §11.3 recorded"

echo
echo "DRILL PASSED — ${CHECKS} checks"
echo
echo "Scope: this proves the origin's behaviour behind the Caddy configuration"
echo "this repository ships. A deployment that puts a DIFFERENT proxy in front"
echo "must still ensure that proxy OVERWRITES X-Forwarded-For rather than"
echo "appending to it, and that TRITRACK_TRUSTED_PROXIES names it. The origin"
echo "parses a longer chain correctly (see request_identity.dart), but a proxy"
echo "that forwards a caller's own header unchanged is a proxy that lets the"
echo "caller pick their own rate-limit bucket."

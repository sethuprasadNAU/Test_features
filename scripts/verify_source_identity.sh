#!/usr/bin/env bash
# gate-instrument: verify_source_identity verify_source_identity_selftest_blind_filter verify_source_identity_selftest_break_machinery
# Publish-path source-identity probe (task 10.62 / Security Model §4.4.2 —
# finding J-2; rebuilt by task 10.110 after it was found unable to say yes).
#
#   scripts/verify_source_identity.sh [--report-only] [--assisted]
#                                     [--wait-seconds N]
#
# **The question.** Does a caller from OUTSIDE this host reach it with its own
# address still attached? Everything §4.4 does with a source address is
# downstream of that, and it is a property of the host's publish path — Docker's
# port forwarding, the VM boundary on Docker Desktop, iptables DNAT on Linux —
# which no amount of server-side correctness can fix and which the server cannot
# see. Finding J-2 is what happens when it is assumed: two genuinely distinct
# callers recorded ONE source_address, twelve requests from one returned 429 to
# the other.
#
# **This is the evidence that licenses `TRITRACK_TRUSTED_PROXIES=peer-verified`
# and `TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified`.** The server refuses to
# start on a reachable deployment until one of those is declared. Nothing else
# in this repository qualifies a host to be exposed.
#
# ---------------------------------------------------------------------------
# Why this file has an operator-assisted mode (task 10.110)
# ---------------------------------------------------------------------------
#
# The first version of this probe answered the question automatically, by
# standing up two containers on a second Docker network and having them dial the
# host's LAN address. That is not an off-host caller, and on Linux it measured
# something else entirely: the traffic leaves one bridge, touches the host, is
# DNAT'd back into another bridge, and the kernel masquerades that hairpin to
# the destination bridge's own gateway. Both "callers" then arrive as one
# address and the probe reported COLLAPSED — on a host measured, by hand, to
# preserve two real LAN addresses perfectly. It reported that verdict with its
# negative control passing in the same run, because the control only ever
# exercised the on-network path.
#
# The cost was not cosmetic. It failed EVERY Linux host, so no host could be
# licensed and no deployment could be exposed at all.
#
# **The constraint that shapes everything below: the question needs two real
# network endpoints, and a probe holding only containers cannot manufacture
# one.** So a fully automatic verdict is not available, and pretending otherwise
# is precisely how the defect above happened. This file therefore has two
# stages, and only one of them can say yes:
#
#   Stage A — automatic, and it can only ever say NO or NOTHING.
#             Containers on a second network dial the published ports. If they
#             collapse onto an address this host's container substrate could
#             have produced (a Docker network gateway or subnet), that is the
#             hairpin confound and the stage reports NO VERDICT — it does not
#             report COLLAPSED, which is the bug. If they collapse onto anything
#             else (Docker Desktop's 192.168.65.1, produced at the VM boundary
#             before any container exists), no innocent explanation is available
#             and the collapse is real: COLLAPSED, conclusive. Stage A has no
#             PASS branch at all. It never had the standing to issue one, and
#             the previous version's PASS branch was a latent FALSE POSITIVE on
#             any Linux host that does not masquerade the hairpin.
#
#   Stage B — operator-assisted (`--assisted`), and it is the only PASS.
#             The probe stands up its listener, prints one URL per device, waits
#             for real traffic from two genuinely off-host devices, reads its own
#             access log and issues the verdict ITSELF. The operator supplies
#             packets. The operator never supplies a conclusion: there is no flag,
#             no prompt and no environment variable anywhere in this file by
#             which a human can assert PRESERVED, and every address that arrives
#             is classified against a set of addresses this host is MEASURED to
#             be able to produce on its own.
#
# ---------------------------------------------------------------------------
# Address classes — the anti-forgery core
# ---------------------------------------------------------------------------
#
# Every address the origin records is classified before it is allowed to mean
# anything. Only `off-host` can contribute to a PASS.
#
#   loopback           127.0.0.0/8. Somebody called this host from itself.
#   container-subnet   inside a Docker network on this host. EITHER a container
#                      on this host called in, OR a real caller was rewritten to
#                      this host's bridge gateway. The probe cannot tell those
#                      apart and neither supports a PASS. This is the class the
#                      old method's own callers land in on Linux.
#   host-interface     an address configured on one of this host's interfaces.
#   rewrite-artifact   the address this host is OBSERVED to arrive as when it
#                      calls its OWN published port — measured in step 3, not
#                      assumed, not sniffed from `docker info`. On Docker Desktop
#                      that is the VM gateway, and it is what a real phone arrives
#                      as too, so an arrival in this class is positive evidence of
#                      collapse rather than an operator mistake.
#   off-host           none of the above. The only class that can license.
#
# ---------------------------------------------------------------------------
# Controls (§12.11: a control that passes beside a wrong answer is a finding)
# ---------------------------------------------------------------------------
#
# The old negative control — two on-network clients reaching Caddy directly —
# passed in the same run that produced two wrong verdicts. It could only ever
# fail if nginx, Caddy, the header or the log parser broke. It proved nothing
# about the off-host path the verdicts were describing. It is kept below, as
# control 3, with that limit stated in its own output instead of the sentence it
# used to print about the verdicts meaning something.
#
#   control 1  ATTRIBUTION — the regression control for this defect. Every
#              address produced by the probe's OWN containers (which are provably
#              on this host, and are exactly the callers the old method mistook
#              for off-host) must classify as NOT off-host. If the classifier
#              ever calls one of them off-host, the machinery that gates every
#              PASS is broken and the probe refuses to report anything.
#              Demonstrated failing: TRITRACK_PROBE_SELFTEST=blind-filter.
#   control 2  FALSIFIABILITY — the verdict engine is run over synthetic
#              off-host-shaped observations and must return PRESERVED for a
#              distinct pair, COLLAPSED for an identical pair, and NO VERDICT for
#              a pair containing a local address. This is what proves the PASS
#              branch is reachable at all, which is the property the previous
#              version silently lost.
#   control 3  MACHINERY — the on-network path. Proves the log format, the
#              proxy's X-Forwarded-For and the parser work end to end. Says
#              nothing whatsoever about the publish path.
#              Demonstrated failing: TRITRACK_PROBE_SELFTEST=break-machinery.
#
# `--report-only` prints the same findings but exits 0 for a COLLAPSED or
# no-verdict result, failing only when the probe's OWN machinery is broken. That
# is the mode `gate_smoke_test.sh` registers, and the distinction is task 10.65's:
# a smoke run asks "does this tool work", a deployment gate asks "is this host
# safe to expose".
#
# Exit codes: 0 licensed (or --report-only), 1 COLLAPSED / machinery broken,
# 2 usage, 3 no verdict (nothing is licensed, nothing is condemned).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Task 11.176 — readiness loops keep their last attempt's error. See that file.
# shellcheck disable=SC1091
. scripts/lib/wait_for.sh

REPORT_ONLY=0
ASSISTED=0
WAIT_SECONDS="${TRITRACK_PROBE_WAIT_SECONDS:-600}"
SELFTEST="${TRITRACK_PROBE_SELFTEST:-}"

usage() {
  cat >&2 <<'USAGE'
usage: verify_source_identity.sh [--report-only] [--assisted] [--wait-seconds N]

  --assisted       measure the off-host path for real: print one URL per device,
                   wait for traffic from two genuinely off-host devices, and
                   issue the verdict from what arrives. THE ONLY PATH TO A PASS.
  --report-only    Stage A only; exit 0 unless the probe's own machinery is
                   broken. What gate_smoke_test.sh runs.
  --wait-seconds N how long --assisted waits for traffic (default 600).
USAGE
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report-only) REPORT_ONLY=1 ;;
    --assisted) ASSISTED=1 ;;
    --wait-seconds) shift; [ "$#" -gt 0 ] || usage; WAIT_SECONDS="$1" ;;
    --wait-seconds=*) WAIT_SECONDS="${1#*=}" ;;
    *) usage ;;
  esac
  shift
done

case "$WAIT_SECONDS" in
  '' | *[!0-9]*) echo "--wait-seconds must be a whole number of seconds" >&2; exit 2 ;;
esac

if [ "$REPORT_ONLY" = 1 ] && [ "$ASSISTED" = 1 ]; then
  echo "--report-only and --assisted are mutually exclusive: --assisted blocks" >&2
  echo "waiting for a human, and --report-only exists so an unattended smoke" >&2
  echo "run never does." >&2
  exit 2
fi

PROJECT="tritrack-source-identity-probe"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-src-probe.XXXXXX")"
chmod 700 "$WORK"

SUBNET="172.31.246.0/24"
CLIENT_SUBNET="172.31.247.0/24"
CLIENT_NET="${PROJECT}_clients"
ORIGIN_PORT="${TRITRACK_PROBE_ORIGIN_PORT:-18086}"
PROXY_PORT="${TRITRACK_PROBE_PROXY_PORT:-18087}"
CURL_IMAGE="curlimages/curl:8.11.1"
NONCE="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"

LOG="${WORK}/access.log"
SELF_ADDRS="${WORK}/self_addrs"      # measured: what this host arrives as
IFACE_ADDRS="${WORK}/iface_addrs"    # enumerated: addresses on this host
DOCKER_CIDRS="${WORK}/docker_cidrs"  # enumerated: container substrate
: > "$SELF_ADDRS"
: > "$IFACE_ADDRS"
: > "$DOCKER_CIDRS"

CHECKS=0
FAILED=0          # a real COLLAPSED / refusal
MACHINERY_BROKEN=0 # a control failed: report nothing, fail in every mode
NO_VERDICT=0
pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { FAILED=1; printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; }
note() { printf '  \033[33m....\033[0m  %s\n' "$1"; }
info() { printf '        %s\n' "$1"; }
die() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

cleanup() {
  step "Tearing down"
  docker compose -p "$PROJECT" -f "${WORK}/compose.yml" down -v --remove-orphans >/dev/null 2>&1 || true
  docker network rm "$CLIENT_NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
  echo "  removed probe containers, networks and working directory"
}
trap cleanup EXIT

if [ -n "$SELFTEST" ]; then
  printf '\n\033[1;33m  TRITRACK_PROBE_SELFTEST=%s — this run is deliberately\n' "$SELFTEST"
  printf '  sabotaged to prove a control can fail. It exits non-zero whatever\n'
  printf '  it finds and licenses nothing.\033[0m\n'
  case "$SELFTEST" in
    blind-filter|break-machinery) ;;
    *) echo "unknown TRITRACK_PROBE_SELFTEST value: $SELFTEST" >&2; exit 2 ;;
  esac
fi

# ---------------------------------------------------------------------------
# Address arithmetic
# ---------------------------------------------------------------------------
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

ip4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

in_cidr() {
  local ip="$1" cidr="$2" base bits mask
  base="${cidr%%/*}"
  bits="${cidr##*/}"
  is_ipv4 "$ip" || return 1
  is_ipv4 "$base" || return 1
  case "$bits" in '' | *[!0-9]*) return 1 ;; esac
  [ "$bits" -le 32 ] || return 1
  [ "$bits" -eq 0 ] && return 0
  mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
  [ $(( $(ip4_to_int "$ip") & mask )) -eq $(( $(ip4_to_int "$base") & mask )) ]
}

# `off-host` is the only class that can license anything. Everything else names
# a way this host could have produced the address without any real device.
classify() {
  local addr="$1" cidr

  if [ "$SELFTEST" = "blind-filter" ]; then
    # Control 1's sabotage: the classifier that gates every PASS is disabled,
    # exactly as it effectively was when a container on this host counted as an
    # off-host caller. Control 1 must catch this and refuse to report.
    echo "off-host"
    return 0
  fi

  case "$addr" in
    '' | '-') echo "absent"; return 0 ;;
  esac
  is_ipv4 "$addr" || { echo "not-ipv4"; return 0; }
  if in_cidr "$addr" "127.0.0.0/8"; then echo "loopback"; return 0; fi

  while read -r cidr; do
    [ -n "$cidr" ] || continue
    if in_cidr "$addr" "$cidr"; then echo "container-subnet"; return 0; fi
  done < "$DOCKER_CIDRS"

  if grep -qxF "$addr" "$IFACE_ADDRS"; then echo "host-interface"; return 0; fi
  if grep -qxF "$addr" "$SELF_ADDRS"; then echo "rewrite-artifact"; return 0; fi

  echo "off-host"
}

explain_class() {
  case "$1" in
    absent) echo "no address was recorded at all" ;;
    not-ipv4) echo "not an IPv4 address; this probe measures the IPv4 publish path the compose files bind" ;;
    loopback) echo "loopback — that call came from this host, not from a caller" ;;
    container-subnet) echo "inside a Docker network ON THIS HOST — either a container here called in, or a real caller was rewritten to this host's bridge gateway; the probe cannot tell those apart and neither can license anything" ;;
    host-interface) echo "an address configured on this host — that call came from this host" ;;
    rewrite-artifact) echo "the address this host is measured to arrive as when it calls its own published port; a real caller arriving as this has had its address destroyed by the publish path" ;;
    off-host) echo "off-host" ;;
    *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# 0. The address an off-host caller would actually dial
# ---------------------------------------------------------------------------
step "0. Finding this host's LAN address"
HOST_ADDR="${TRITRACK_PROBE_HOST_ADDRESS:-}"
if [ -z "$HOST_ADDR" ]; then
  if command -v ipconfig >/dev/null 2>&1; then
    # swallow-reviewed: the `-z` below only picks a fallback command to try
    # next, not a pass/fail verdict — the actual gate is the `case` below,
    # which treats an empty HOST_ADDR (from ipconfig failing, or every
    # branch here failing) the same as a loopback address: `die`, not pass.
    HOST_ADDR="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  fi
  if [ -z "$HOST_ADDR" ] && command -v hostname >/dev/null 2>&1; then
    HOST_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
fi
case "$HOST_ADDR" in
  '' | 127.* | localhost)
    die "could not determine a non-loopback address for this host. Set TRITRACK_PROBE_HOST_ADDRESS to the address a phone on your network would dial."
    ;;
esac
pass "off-host callers will dial ${HOST_ADDR}"

# ---------------------------------------------------------------------------
# 1. What this host can produce without any real device
# ---------------------------------------------------------------------------
step "1. Enumerating addresses this host can produce by itself"
if command -v ip >/dev/null 2>&1; then
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sort -u > "$IFACE_ADDRS" || true
elif command -v ifconfig >/dev/null 2>&1; then
  ifconfig 2>/dev/null | awk '/inet /{print $2}' | sed 's/^addr://' | sort -u > "$IFACE_ADDRS" || true
fi
grep -qxF "$HOST_ADDR" "$IFACE_ADDRS" || echo "$HOST_ADDR" >> "$IFACE_ADDRS"
[ -s "$IFACE_ADDRS" ] || die "could not enumerate this host's own interface addresses; without them the probe cannot tell a caller from this machine"
info "$(wc -l < "$IFACE_ADDRS" | tr -d ' ') addresses on this host's interfaces"

for net in $(docker network ls -q 2>/dev/null || true); do
  docker network inspect "$net" \
    --format '{{range .IPAM.Config}}{{.Subnet}}
{{end}}' 2>/dev/null || true
done | grep -E '^[0-9]+\.' | sort -u > "$DOCKER_CIDRS" || true
# The probe's own two networks do not exist yet at this point; add them by
# construction so a caller can never be counted as off-host merely because the
# enumeration ran before `docker network create`.
echo "$SUBNET" >> "$DOCKER_CIDRS"
echo "$CLIENT_SUBNET" >> "$DOCKER_CIDRS"
sort -u -o "$DOCKER_CIDRS" "$DOCKER_CIDRS"
info "$(wc -l < "$DOCKER_CIDRS" | tr -d ' ') Docker network subnets on this host"
pass "this host's own address space is enumerated, not assumed"

docker image inspect "$CURL_IMAGE" >/dev/null 2>&1 || {
  echo "  pulling ${CURL_IMAGE}..."
  docker pull -q "$CURL_IMAGE" >/dev/null || die "could not pull $CURL_IMAGE"
}

# ---------------------------------------------------------------------------
# 2. The throwaway origin and proxy
# ---------------------------------------------------------------------------
step "2. Standing up a throwaway origin and proxy"

# The landing page a device opens records the DIRECT path and then fetches the
# PROXIED path from the same device, so one tap measures both shapes. Both URLs
# are printed as curl lines too, for a device with no browser.
landing_page() {
  local slot="$1"
  printf '%s' "<!doctype html><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>TriTrack source-identity probe</title><body style=\"font:16px/1.5 system-ui,sans-serif;margin:2rem;max-width:32rem\"><h2>Device ${slot} &mdash; direct path recorded</h2><p>Now loading the proxied path from this same device&hellip;</p><img src=\"http://${HOST_ADDR}:${PROXY_PORT}/probe/${NONCE}/${slot}/proxied\" alt=\"\" width=\"1\" height=\"1\"><p id=\"done\">Both paths have now been asked for. You can close this page.</p><p style=\"color:#666\">The probe in the terminal issues the verdict. This page cannot, and neither can you.</p>"
}

{
  echo 'events {}'
  echo 'http {'
  echo "  log_format probe 'PROBE remote=\$remote_addr xff=\$http_x_forwarded_for tag=\$http_x_probe_tag uri=\$request_uri';"
  echo '  access_log /dev/stdout probe;'
  echo '  server {'
  echo '    listen 80;'
  echo "    location = /favicon.ico { access_log off; return 204; }"
  for slot in a b; do
    echo "    location = /probe/${NONCE}/${slot} { default_type text/html; return 200 '$(landing_page "$slot")'; }"
    echo "    location = /probe/${NONCE}/${slot}/proxied { default_type text/plain; return 200 'recorded\n'; }"
  done
  echo '    location / { return 200 "ok\n"; }'
  echo '  }'
  echo '}'
} > "${WORK}/nginx.conf"

# `header_up X-Forwarded-For {remote_host}` — overwrite, not append, exactly as
# proxy/Caddyfile does. Copying the real directive is the point twice over: a
# probe that forwarded differently from the shipped proxy would measure a path
# nobody deploys, and the overwrite is what stops an operator forging a
# `proxied` PASS by sending their own X-Forwarded-For header.
cat > "${WORK}/Caddyfile" <<'CADDY'
{
  auto_https off
  admin off
}
:80 {
  reverse_proxy origin:80 {
    header_up X-Forwarded-For {remote_host}
  }
}
CADDY

cat > "${WORK}/compose.yml" <<COMPOSE
services:
  origin:
    image: nginx:alpine
    volumes:
      - ${WORK}/nginx.conf:/etc/nginx/nginx.conf:ro
    ports:
      - "0.0.0.0:${ORIGIN_PORT}:80"
  proxy:
    image: caddy:2-alpine
    volumes:
      - ${WORK}/Caddyfile:/etc/caddy/Caddyfile:ro
    ports:
      - "0.0.0.0:${PROXY_PORT}:80"
networks:
  default:
    ipam:
      config:
        - subnet: ${SUBNET}
COMPOSE

# Task 11.176: these three used to discard stderr, so "could not start the
# probe stack" was the whole of what a person got about a compose file, an
# image pull and a subnet that could each fail for a dozen different reasons.
docker compose -p "$PROJECT" -f "${WORK}/compose.yml" up -d \
    >"${WORK}/compose-up.log" 2>&1 \
  || { sed 's/^/    /' "${WORK}/compose-up.log" >&2
       die "could not start the probe stack — see the compose output above"; }
docker network create --subnet "$CLIENT_SUBNET" "$CLIENT_NET" \
    >"${WORK}/network-create.log" 2>&1 \
  || { sed 's/^/    /' "${WORK}/network-create.log" >&2
       die "could not create the client network on ${CLIENT_SUBNET} — see above"; }

# The probe is the subject: curl to the origin's own published port.
wait_for 30 1 -- curl -fsS --max-time 2 "http://127.0.0.1:${ORIGIN_PORT}/" \
  || die "the probe origin never answered on http://127.0.0.1:${ORIGIN_PORT}/. $(wait_for_evidence)"

PROXY_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "${PROJECT}-proxy-1" 2>/dev/null || true)"
is_ipv4 "$PROXY_IP" || die "could not read the proxy container's address; the proxied shape cannot be attributed without it"
pass "origin published on ${ORIGIN_PORT}, proxy on ${PROXY_PORT} (${PROXY_IP})"

collect() {
  docker logs "${PROJECT}-origin-1" 2>&1 | grep '^PROBE ' > "$LOG" || true
}

field_of() { # <line> <field>
  printf '%s\n' "$1" | sed -n "s/.* $2=\\([^ ]*\\).*/\\1/p"
}

# All identities recorded for a tag, in arrival order.
# `|| true` inside the function, never on the caller's assignment line: with
# `set -o pipefail` a grep that matches nothing would otherwise abort the whole
# probe, and swallowing it here keeps "no such tag" as an EMPTY RESULT that
# every caller below treats as a failure rather than as a clean bill of health.
identities_for_tag() { # <tag> <field>
  grep " tag=${1} " "$LOG" | sed -n "s/.* ${2}=\\([^ ]*\\).*/\\1/p" || true
}

# All identities recorded for an assisted URI, in arrival order. The `proxied`
# shape additionally requires the TCP peer to BE the proxy container: without
# that check an operator could curl the origin port with their own
# X-Forwarded-For header and forge a preserved pair.
identities_for_uri() { # <uri> <field>
  local uri="$1" field="$2" line
  while IFS= read -r line; do
    if [ "$field" = "xff" ]; then
      [ "$(field_of "$line" remote)" = "$PROXY_IP" ] || continue
    fi
    field_of "$line" "$field"
  done < <(grep " uri=${uri}\$" "$LOG")
}

# ---------------------------------------------------------------------------
# 3. What this host arrives as when it calls its own published port
# ---------------------------------------------------------------------------
step "3. Measuring what this host itself arrives as"
curl -s --max-time 5 -H "x-probe-tag: hostself-direct" \
  "http://${HOST_ADDR}:${ORIGIN_PORT}/" >/dev/null 2>&1 || true
curl -s --max-time 5 -H "x-probe-tag: hostself-proxied" \
  "http://${HOST_ADDR}:${PROXY_PORT}/" >/dev/null 2>&1 || true
curl -s --max-time 5 -H "x-probe-tag: hostself-loopback" \
  "http://127.0.0.1:${ORIGIN_PORT}/" >/dev/null 2>&1 || true
collect
[ -s "$LOG" ] || die "the origin logged no requests at all — the probe could not reach itself, so it cannot report on anything"

SELF_SEEN=0
for spec in "hostself-direct remote" "hostself-proxied xff" "hostself-loopback remote"; do
  # shellcheck disable=SC2086
  set -- $spec
  seen="$(identities_for_tag "$1" "$2" | sed -n 1p)"
  if [ -n "$seen" ] && [ "$seen" != "-" ] && is_ipv4 "$seen"; then
    SELF_SEEN=1
    grep -qxF "$seen" "$SELF_ADDRS" || echo "$seen" >> "$SELF_ADDRS"
    info "$1: this host arrived as ${seen}"
  fi
done
[ "$SELF_SEEN" = 1 ] || die "this host could not call its own published port, so the probe cannot establish which addresses it is able to manufacture. Nothing below could be trusted."
pass "this host's own calls arrive as: $(tr '\n' ' ' < "$SELF_ADDRS")"
info "any caller arriving as one of those has not proved it is off this host"

# ---------------------------------------------------------------------------
# 4. Stage A — the automatic screen. Can say NO. Cannot say YES.
# ---------------------------------------------------------------------------
step "4. Stage A — containers on a second network dial the published ports"
say() {
  local ip="$1" tag="$2" url="$3"
  docker run --rm --network "$CLIENT_NET" --ip "$ip" "$CURL_IMAGE" \
    -s --max-time 5 -H "x-probe-tag: ${tag}" "$url" >/dev/null 2>&1 || true
}
say 172.31.247.50 "direct-a"  "http://${HOST_ADDR}:${ORIGIN_PORT}/"
say 172.31.247.51 "direct-b"  "http://${HOST_ADDR}:${ORIGIN_PORT}/"
say 172.31.247.50 "proxied-a" "http://${HOST_ADDR}:${PROXY_PORT}/"
say 172.31.247.51 "proxied-b" "http://${HOST_ADDR}:${PROXY_PORT}/"

ONNET_B_IP=172.31.246.61
[ "$SELFTEST" = "break-machinery" ] && ONNET_B_IP=172.31.246.60
docker run --rm --network "${PROJECT}_default" --ip 172.31.246.60 "$CURL_IMAGE" \
  -s --max-time 5 -H "x-probe-tag: onnet-a" "http://proxy:80/" >/dev/null 2>&1 || true
docker run --rm --network "${PROJECT}_default" --ip "$ONNET_B_IP" "$CURL_IMAGE" \
  -s --max-time 5 -H "x-probe-tag: onnet-b" "http://proxy:80/" >/dev/null 2>&1 || true

collect
sed 's/^/    /' "$LOG"

# ---------------------------------------------------------------------------
# 5. Controls, before any verdict is read
# ---------------------------------------------------------------------------
step "5. Controls"

# --- control 1: attribution. The regression control for task 10.110. ---------
CONTROL1_OK=1
for spec in "direct-a remote" "direct-b remote" "proxied-a xff" "proxied-b xff"; do
  # shellcheck disable=SC2086
  set -- $spec
  seen="$(identities_for_tag "$1" "$2" | sed -n 1p)"
  if [ -z "$seen" ]; then
    CONTROL1_OK=0
    fail "control 1: the probe's own container caller '${1}' recorded nothing; attribution cannot be checked"
    continue
  fi
  cls="$(classify "$seen")"
  if [ "$cls" = "off-host" ]; then
    CONTROL1_OK=0
    fail "control 1: a container ON THIS HOST (${1}) arrived as ${seen} and the classifier called it off-host. That is exactly the mistake task 10.110 exists for: a container is not a caller. Refusing to report."
  else
    info "container caller ${1} -> ${seen} (${cls}) — correctly not off-host"
  fi
done
if [ "$CONTROL1_OK" = 1 ]; then
  pass "control 1 (attribution): none of the probe's own containers can pass as an off-host caller"
else
  MACHINERY_BROKEN=1
fi

# --- control 2: falsifiability of the verdict engine ------------------------
# `judge` is the ONLY place a shape becomes PRESERVED, and control 2 runs it
# over synthetic observations before any real one is read. 203.0.113.0/24 is
# TEST-NET-3: routable nowhere, and (unless someone has built a Docker network
# on it) classified off-host, which is the point — the engine must be shown able
# to return yes, no, and don't-know.
judge() { # <addr-a> <addr-b>  ->  prints PRESERVED | COLLAPSED | NO-VERDICT:<reason>
  local a="$1" b="$2" ca cb
  ca="$(classify "$a")"
  cb="$(classify "$b")"
  if [ "$ca" != "off-host" ] || [ "$cb" != "off-host" ]; then
    if [ "$ca" = "rewrite-artifact" ] && [ "$cb" = "rewrite-artifact" ]; then
      echo "COLLAPSED"
      return 0
    fi
    echo "NO-VERDICT:${ca}/${cb}"
    return 0
  fi
  if [ "$a" = "$b" ]; then echo "COLLAPSED"; else echo "PRESERVED"; fi
}

CONTROL2_OK=1
c2_expect() {
  local got want
  got="$(judge "$1" "$2")"
  want="$3"
  case "$got" in
    "$want"*) info "verdict engine: ${1} / ${2} -> ${got}" ;;
    *) CONTROL2_OK=0; fail "control 2: verdict engine returned '${got}' for ${1}/${2}, expected ${want}" ;;
  esac
}
c2_expect 203.0.113.10 203.0.113.11 PRESERVED
c2_expect 203.0.113.10 203.0.113.10 COLLAPSED
c2_expect 203.0.113.10 127.0.0.1    NO-VERDICT
c2_expect 203.0.113.10 "$HOST_ADDR" NO-VERDICT
if [ "$CONTROL2_OK" = 1 ]; then
  pass "control 2 (falsifiability): the engine can return PRESERVED, COLLAPSED and NO VERDICT — the PASS branch exists and is reachable"
else
  MACHINERY_BROKEN=1
fi

# --- control 3: machinery, and only machinery -------------------------------
ONNET_A="$(identities_for_tag onnet-a xff | sed -n 1p)"
ONNET_B="$(identities_for_tag onnet-b xff | sed -n 1p)"
if [ -n "$ONNET_A" ] && [ -n "$ONNET_B" ] && [ "$ONNET_A" != "$ONNET_B" ]; then
  pass "control 3 (machinery): the log, the proxy's X-Forwarded-For and the parser all work (${ONNET_A} / ${ONNET_B})"
  info "this control crosses no publish path. It says NOTHING about whether an"
  info "off-host caller keeps its address — the previous version of this probe"
  info "printed exactly that claim here, beside two wrong verdicts (§12.11)."
else
  MACHINERY_BROKEN=1
  fail "control 3: two on-network callers at distinct addresses recorded '${ONNET_A}' / '${ONNET_B}'. The probe's own log or proxy is broken; nothing below can be read."
fi

if [ "$MACHINERY_BROKEN" = 1 ]; then
  step "Refusing to report"
  echo "  A control failed. This probe's verdicts are only worth the machinery" >&2
  echo "  that produces them, so it reports nothing rather than reporting" >&2
  echo "  something it cannot stand behind." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 6. Stage A findings
# ---------------------------------------------------------------------------
step "6. Stage A findings (screen only — no PASS is available here)"

STAGE_A_COLLAPSE_ADDR=""
stage_a() { # <shape> <tag-a> <tag-b> <field>  -> 0 conclusive collapse, 1 no verdict
  local shape="$1" ia ib ca
  ia="$(identities_for_tag "$2" "$4" | sed -n 1p)"
  ib="$(identities_for_tag "$3" "$4" | sed -n 1p)"
  if [ -z "$ia" ] || [ -z "$ib" ]; then
    note "${shape}: the probe's own callers recorded '${ia}' / '${ib}' — no screen result"
    return 1
  fi
  if [ "$ia" != "$ib" ]; then
    note "${shape}: the probe's containers kept distinct addresses (${ia} / ${ib})."
    info "That is NOT a pass. They are containers on this host, not off-host"
    info "callers, and the previous version of this probe would have reported"
    info "PRESERVED here — a false positive that would have licensed exposure"
    info "on a host nobody had measured. Run --assisted."
    return 1
  fi
  ca="$(classify "$ia")"
  if [ "$ca" = "container-subnet" ]; then
    note "${shape}: both containers arrived as ${ia}, which is inside a Docker"
    info "network on this host. That is the hairpin the kernel masquerades when"
    info "container traffic leaves one bridge and is DNAT'd into another — it is"
    info "an artefact of the probe's own method, not a fact about off-host"
    info "callers. NO VERDICT. This is the false COLLAPSED task 10.110 fixed."
    return 1
  fi
  fail "${shape}: two callers both arrived as ${ia} (${ca}), which this host's container substrate cannot explain — it is produced upstream of every container, at the publish path itself. Source identity COLLAPSES here: a per-source rate limit is one bucket shared by every user, and every audit row names a gateway."
  STAGE_A_COLLAPSE_ADDR="$ia"
  return 0
}

DIRECT_STATE="no-verdict"
PROXIED_STATE="no-verdict"
if stage_a "direct        (README LAN walkthrough)" direct-a direct-b remote; then
  DIRECT_STATE="collapsed"
fi
if stage_a "proxied       (docker-compose.tls.yml, off-host caller)" proxied-a proxied-b xff; then
  PROXIED_STATE="collapsed"
fi

# ---------------------------------------------------------------------------
# 7. Stage B — operator-assisted. The only path to a PASS.
# ---------------------------------------------------------------------------
DIRECT_ADDRS=""
PROXIED_ADDRS=""
if [ "$ASSISTED" = 1 ]; then
  step "7. Stage B — real off-host callers"
  cat <<BANNER

  The probe is listening. It needs traffic from TWO devices that are NOT this
  host and NOT containers on it — a phone and a laptop on the same network is
  the shape the README documents.

    device 1   http://${HOST_ADDR}:${ORIGIN_PORT}/probe/${NONCE}/a
    device 2   http://${HOST_ADDR}:${ORIGIN_PORT}/probe/${NONCE}/b

  Opening the page also measures the proxied shape from the same device. With
  no browser, both shapes by hand:

    curl -s http://${HOST_ADDR}:${ORIGIN_PORT}/probe/${NONCE}/a  >/dev/null
    curl -s http://${HOST_ADDR}:${PROXY_PORT}/probe/${NONCE}/a/proxied >/dev/null

  Use ONE device per letter. Two visits from the same device look exactly like
  a collapsed publish path and this probe will refuse rather than guess.

  Waiting up to ${WAIT_SECONDS}s. The verdict below is computed from what
  arrives; there is no answer you can type here.

BANNER

  # Per-cell state. Four cells: {direct,proxied} x {device a, device b}. Held
  # in files rather than an associative array because macOS ships bash 3.2, and
  # a probe that only runs on the maintainer's newer shell is a probe that stops
  # running on the one platform whose collapse it has to keep detecting.
  mkdir -p "${WORK}/cell"
  cell_get() { cat "${WORK}/cell/${1}.${2}" 2>/dev/null || true; }

  # Reported as each cell changes, so an operator learns immediately that they
  # used the wrong device rather than after a ten-minute wait.
  cell_scan() {
    local key uri field addr cls picked pickedcls slot shape
    for slot in a b; do
      for shape in direct proxied; do
        key="${shape}-${slot}"
        [ "$(cell_get "$key" class)" = "off-host" ] && continue
        if [ "$shape" = "direct" ]; then
          uri="/probe/${NONCE}/${slot}"; field="remote"
        else
          uri="/probe/${NONCE}/${slot}/proxied"; field="xff"
        fi
        picked=""; pickedcls=""
        while IFS= read -r addr; do
          [ -n "$addr" ] || continue
          cls="$(classify "$addr")"
          if [ -z "$picked" ]; then picked="$addr"; pickedcls="$cls"; fi
          if [ "$cls" = "off-host" ]; then picked="$addr"; pickedcls="$cls"; break; fi
        done < <(identities_for_uri "$uri" "$field")
        [ -n "$picked" ] || continue
        if [ "$(cell_get "$key" addr)" != "$picked" ] || [ "$(cell_get "$key" class)" != "$pickedcls" ]; then
          printf '%s' "$picked" > "${WORK}/cell/${key}.addr"
          printf '%s' "$pickedcls" > "${WORK}/cell/${key}.class"
          if [ "$pickedcls" = "off-host" ]; then
            pass "${key}: ${picked}"
          else
            note "${key}: ${picked} — $(explain_class "$pickedcls")"
          fi
        fi
      done
    done
    return 0
  }

  # Stop early only when every cell holds something the verdict engine can act
  # on. An `off-host` set is a PASS or a refusal; an all-`rewrite-artifact` set
  # is a decisive collapse. Anything else (loopback, a container, this host's
  # own address) is an operator mistake, and the probe keeps waiting rather than
  # turning that mistake into a verdict.
  cells_settled() {
    local key cls
    for key in direct-a direct-b proxied-a proxied-b; do
      cls="$(cell_get "$key" class)"
      [ -n "$cls" ] || return 1
      [ "$cls" = "off-host" ] || [ "$cls" = "rewrite-artifact" ] || return 1
    done
    return 0
  }

  DEADLINE=$(( $(date +%s) + WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    collect
    cell_scan
    cells_settled && break
    sleep 2
  done
  collect
  cell_scan

  step "8. Verdict per deployment shape, from real off-host callers"
  # Sets ASSISTED_STATE rather than echoing it: `pass`/`fail` write the finding
  # AND set FAILED, and running this inside a command substitution would swallow
  # both. An instrument whose verdict is discarded by its own plumbing is the
  # class of defect this task is about.
  ASSISTED_STATE=""
  assisted_verdict() { # <shape-label> <cell-prefix>
    local label="$1" pfx="$2" a b v ca cb seen
    a="$(cell_get "${pfx}-a" addr)"
    b="$(cell_get "${pfx}-b" addr)"
    if [ -z "$a" ] || [ -z "$b" ]; then
      seen=0
      [ -n "$a" ] && seen=$((seen + 1))
      [ -n "$b" ] && seen=$((seen + 1))
      note "${label}: reached by ${seen} of the 2 devices. NO VERDICT — a measurement that did not happen is not a COLLAPSED, and it is certainly not a PASS."
      ASSISTED_STATE="no-verdict"
      return 0
    fi
    ca="$(classify "$a")"
    cb="$(classify "$b")"
    v="$(judge "$a" "$b")"
    case "$v" in
      PRESERVED)
        pass "${label}: two off-host callers stayed distinct (${a} / ${b}) — PRESERVED"
        ASSISTED_STATE="preserved" ;;
      COLLAPSED)
        if [ "$ca" = "off-host" ] && [ "$cb" = "off-host" ]; then
          fail "${label}: both devices arrived as ${a}. That is EITHER this host collapsing source identity OR one device used for both letters, and the probe cannot tell those apart. Nothing is licensed. Re-run from two genuinely different machines."
        else
          fail "${label}: both devices arrived as ${a} / ${b} — addresses this host produces when it calls its own published port. The publish path destroyed the caller's address before any container saw it. COLLAPSED."
        fi
        ASSISTED_STATE="collapsed" ;;
      *)
        note "${label}: ${a} (${ca}) / ${b} (${cb}) — NO VERDICT."
        info "device a: $(explain_class "$ca")"
        info "device b: $(explain_class "$cb")"
        ASSISTED_STATE="no-verdict" ;;
    esac
  }
  assisted_verdict "direct        (README LAN walkthrough)" direct
  DIRECT_STATE="$ASSISTED_STATE"
  assisted_verdict "proxied       (docker-compose.tls.yml, off-host caller)" proxied
  PROXIED_STATE="$ASSISTED_STATE"
  DIRECT_ADDRS="$(cell_get direct-a addr)"; DIRECT_ADDRS="${DIRECT_ADDRS:-none}"
  DIRECT_B_ADDR="$(cell_get direct-b addr)"
  DIRECT_ADDRS="${DIRECT_ADDRS} / ${DIRECT_B_ADDR:-none}"
  PROXIED_ADDRS="$(cell_get proxied-a addr)"; PROXIED_ADDRS="${PROXIED_ADDRS:-none}"
  PROXIED_B_ADDR="$(cell_get proxied-b addr)"
  PROXIED_ADDRS="${PROXIED_ADDRS} / ${PROXIED_B_ADDR:-none}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
render_state() {
  case "$1" in
    preserved) printf 'PRESERVED' ;;
    collapsed) printf 'COLLAPSED' ;;
    *) printf 'NO VERDICT' ;;
  esac
}

step "Summary"
printf '  direct   (base compose, published port): %s%s\n' \
  "$(render_state "$DIRECT_STATE")" "${DIRECT_ADDRS:+   [${DIRECT_ADDRS}]}"
printf '  proxied  (TLS overlay, off-host caller): %s%s\n' \
  "$(render_state "$PROXIED_STATE")" "${PROXIED_ADDRS:+   [${PROXIED_ADDRS}]}"
if [ "$ASSISTED" = 1 ]; then
  echo "  Stage B — computed from the traffic that actually arrived"
else
  echo "  Stage A screen only — no PASS is available without --assisted"
fi
echo "  ${CHECKS} checks passed"

case "$DIRECT_STATE$PROXIED_STATE" in
  *no-verdict*) NO_VERDICT=1 ;;
esac

if [ -n "$SELFTEST" ]; then
  step "Self-test"
  echo "  TRITRACK_PROBE_SELFTEST=${SELFTEST} was set. If the run reached here" >&2
  echo "  the sabotaged control did NOT fire, which is itself the failure." >&2
  exit 1
fi

if [ "$REPORT_ONLY" = 1 ]; then
  cat <<'EOF'

  --report-only: every control above passed, so this tool works. A COLLAPSED or
  NO VERDICT shape is a fact about this host, not a defect in the probe.
  Exiting 0 so the gate's instrument smoke run measures the tool; run without
  --report-only to gate a deployment.
EOF
  exit 0
fi

if [ "$FAILED" = 1 ]; then
  cat >&2 <<'EOF'

  At least one shape does not preserve source identity on this host.

  For a shape marked COLLAPSED you may NOT declare it measured:

    direct  COLLAPSED  ->  no TRITRACK_TRUSTED_PROXIES=peer-verified
    proxied COLLAPSED  ->  no TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified
                           (task 10.74 / §4.4.3 — the TLS overlay's allowlist
                           is correct and irrelevant if the publish path in
                           front of the proxy already rewrote the caller)

  That deployment has no per-source rate limit: §4.4's magic-link and
  redemption limits become one bucket shared by every user, and
  auth_audit_log.source_address names a gateway rather than a caller.

  On Docker Desktop (macOS, Windows) both published-port shapes collapse and
  there is no configuration that fixes it — the rewrite happens in the VM
  boundary, before any container sees the connection. Serve loopback only
  (the default) or deploy on a host whose publish path preserves addresses.
  Security Model §4.4.2, §4.4.3 and §12.4.
EOF
  exit 1
fi

if [ "$NO_VERDICT" = 1 ]; then
  cat >&2 <<EOF

  NO VERDICT. Nothing above licenses anything, and nothing above condemns
  anything either.

  Stage A can only screen. It has containers, and a container on this host is
  not an off-host caller — that mistake is what made this probe fail every
  Linux host it was ever run on (task 10.110). To get an answer, measure the
  real thing:

    ./scripts/verify_source_identity.sh --assisted

  It prints one URL per device, waits for you to open them from two genuinely
  different machines on your network, and issues the verdict itself from what
  arrives. You supply the packets. It supplies the judgment.
EOF
  exit 3
fi

echo
echo "  Both shapes preserve source identity on this host, measured with real"
echo "  off-host callers. You may now declare, on THIS host only:"
echo
echo "    TRITRACK_TRUSTED_PROXIES=peer-verified          # direct shape"
echo "    TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified   # proxied shape"
echo
echo "  Record the host, the OS, the virtualisation and the Docker flavour"
echo "  beside that declaration. §4.4.3 qualifies a probe RUN, not a platform."

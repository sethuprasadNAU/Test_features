#!/usr/bin/env bash
# gate-instrument: verify_deployment_refusal_matrix
# Task 11.64 — inventory entry 17's deployment refusal matrix, committed.
#
# `SECURITY_SCOPE_AND_EXIT.md` §3 item 17: deployment configuration and
# environment. The server refuses to start when it cannot tell what its
# per-source rate limit is counting (§4.4.1, §4.4.2) — findings L-1, K-2 and
# M-11 are all the same control failing in different directions, and all three
# were found by *running* the matrix rather than by reading the code.
#
# **Why this file exists.** Round 8 ran twelve deployment shapes by hand on
# 2026-08-17 (Security Model §16.2, §16.3), found M-11 among them — a `/0`
# allowlist that started — and **committed none of it**. §6.1 priced re-running
# it at one to two Opus hours, every round, forever. This is that hour, spent
# once.
#
# **What "refused" means here, and why the exit code alone is not enough.**
# EXIT 78 is `sysexits.h` EX_CONFIG. A process can reach it for the wrong
# reason — §4.24 is this project's written finding that a control holding for a
# reason other than the documented one is fragile in a specific way — so each
# refusing shape below also asserts that the printed message **names the
# variable it is refusing on**. Round 8's own matrix was wrong before it was
# right in exactly this way: every case returned the same exit code, because
# the runtime image has no Dart SDK and nothing was actually starting (§16.1).
#
# The two controls at the bottom are what make the ten refusals mean anything.
# A matrix in which nothing starts is indistinguishable from a broken harness.
#
#   scripts/verify_deployment_refusal_matrix.sh
#
# Needs Docker and nothing else. No database: every refusal below happens in
# `bin/server.dart` before a connection is opened, so a shape that gets past
# them simply serves /health with no auth mounted — which is exactly the
# "STARTS" the controls are looking for.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT="$(pwd)"
IMAGE="tritrack-refusal-matrix:$(date +%s)-$$"
OUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-refusal.XXXXXX")"

PASS=0
FAIL=0
STARTED=0
REFUSED=0

_cleanup() {
  docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
}
trap _cleanup EXIT

echo "Building the server image the matrix will run (this is the artifact a"
echo "deployment actually runs, not a source tree)."
if ! docker build -f server/Dockerfile -t "$IMAGE" . >"$OUT_DIR/build.log" 2>&1; then
  tail -n 30 "$OUT_DIR/build.log"
  echo "FAIL: the server image would not build. A matrix that cannot start"
  echo "the artifact measures nothing — see $OUT_DIR/build.log."
  exit 1
fi
echo "Built $IMAGE."

# shape <name> <expect refused|starts> <message-must-contain> <env...>
shape() {
  local name="$1" expect="$2" needle="$3"
  shift 3
  local args=()
  local kv
  for kv in "$@"; do args+=(-e "$kv"); done

  # **Not `--rm`.** The first draft of this file used it, and Docker removed
  # every refusing container the instant it exited — so `docker inspect` found
  # nothing, every refusal was scored `exit ` (empty), and the run reported
  # ten failures. It was caught by this file's own blindness check at the
  # bottom rather than by inspection, which is the point of having one.
  local cid
  # **No database variables at all, and that is deliberate twice over.**
  # Every refusal this matrix measures happens in `bin/server.dart` before a
  # connection is opened, and a server with no database still answers
  # `/health` — which is exactly the "STARTS" the two controls look for. It
  # also keeps a literal like `POSTGRES_PASSWORD=<something>` out of a
  # tracked file: §4.6's committed-secrets test flags any assignment to a
  # known secret variable, placeholder or not, and it flagged this file's
  # first draft. A rule that has to judge whether a committed secret is
  # "really" a secret is a rule that will get it wrong once.
  cid="$(docker run -d -e PORT=8080 \
    "${args[@]}" "$IMAGE" 2>"$OUT_DIR/$name.runerr")"
  if [ -z "$cid" ]; then
    echo "  FAIL   $name — docker run itself failed:"
    sed 's/^/         /' "$OUT_DIR/$name.runerr"
    FAIL=$((FAIL + 1))
    return
  fi

  # A refusal is immediate; a start is not. Poll rather than sleep a fixed
  # time so a slow machine does not turn a start into a refusal or the other
  # way round.
  #
  # Task 11.176 left this loop alone: it polls the container's own state, and
  # the container's log is captured immediately afterwards and printed on
  # every failure below. Nothing is discarded to reach a verdict.
  local state="" code="" i
  for i in $(seq 1 40); do
    state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo gone)"
    code="$(docker inspect -f '{{.State.ExitCode}}' "$cid" 2>/dev/null || echo 0)"
    [ "$state" = "exited" ] && break
    [ "$state" = "gone" ] && break
    sleep 0.25
  done
  docker logs "$cid" >"$OUT_DIR/$name.log" 2>&1 || true
  if [ "$state" = "running" ]; then
    code="running"
    docker kill "$cid" >/dev/null 2>&1 || true
  fi
  docker rm -f "$cid" >/dev/null 2>&1 || true

  local actual
  if [ "$code" = "78" ]; then
    actual="refused"
    REFUSED=$((REFUSED + 1))
  elif [ "$code" = "running" ]; then
    actual="starts"
    STARTED=$((STARTED + 1))
  else
    actual="exit $code"
  fi

  local reason_ok=1
  if [ "$expect" = "refused" ] && [ -n "$needle" ]; then
    grep -q -- "$needle" "$OUT_DIR/$name.log" || reason_ok=0
  fi

  if [ "$actual" = "$expect" ] && [ "$reason_ok" = "1" ]; then
    printf '  %-7s %-46s %s\n' "PASS" "$name" "$actual"
    PASS=$((PASS + 1))
  else
    if [ "$actual" != "$expect" ]; then
      printf '  %-7s %-46s expected %s, got %s\n' "FAIL" "$name" "$expect" "$actual"
    else
      printf '  %-7s %-46s %s, but for the wrong reason (no %s in its message)\n' \
        "FAIL" "$name" "$actual" "$needle"
    fi
    tail -n 6 "$OUT_DIR/$name.log" | sed 's/^/         | /'
    FAIL=$((FAIL + 1))
  fi
}

echo
echo "---- Entry 17: twenty deployment shapes ----"
echo "Sixteen that must refuse, four that must start. Every refusing shape"
echo "is also checked for refusing on the variable it claims to be refusing on."
echo

# The reachable precondition for shapes 1-7 and 9-10: this server is published
# on an address another machine can reach, which is what makes "what is the
# per-source limit counting?" a question at all (§4.4.2, finding J-2).
REACHABLE="TRITRACK_PUBLISH_ADDRESS=0.0.0.0"
CLEARTEXT="TRITRACK_ALLOW_CLEARTEXT_LAN=1"

# 1-2. Finding L-1 (§14.2, closed by 10.92): a value that is non-empty, is not
# `none`, and parses to ZERO ranges. It declares an allowlist naming nobody,
# and before 10.92 it fell through to "nothing in front" — the K-2 question
# never asked, every caller keyed on the proxy's address.
shape "L-1: a bare comma" refused "TRITRACK_TRUSTED_PROXIES" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=,"
shape "L-1's class: commas and spaces" refused "TRITRACK_TRUSTED_PROXIES" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=,, ,,"

# 3-5. Nothing declared, whitespace, and the unmeasured claim.
shape "nothing declared at all" refused "TRITRACK_TRUSTED_PROXIES" \
  "$REACHABLE" "$CLEARTEXT"
shape "whitespace only" refused "TRITRACK_TRUSTED_PROXIES" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=   "
shape "none, on a reachable deployment" refused "peer-verified" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=none"

# 6-7. Finding K-2 (§13.3, closed by 10.74): an allowlist answers WHICH peer
# may speak for a client and cannot answer whether the address that peer
# forwards still belongs to anybody. The second variable is that question.
shape "an allowlist with no source-identity answer" refused \
  "TRITRACK_PROXY_SOURCE_IDENTITY" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=203.0.113.4"
shape "an allowlist with a junk source-identity answer" refused \
  "TRITRACK_PROXY_SOURCE_IDENTITY" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=203.0.113.4" \
  "TRITRACK_PROXY_SOURCE_IDENTITY=probably-fine"

# 8. A publish address that is not an address. `DeploymentReach.of` treats an
# unparseable value as reachable rather than as loopback — failing closed.
shape "a publish address that is not an address" refused \
  "TRITRACK_TRUSTED_PROXIES" \
  "TRITRACK_PUBLISH_ADDRESS=not-an-address" "$CLEARTEXT"

# 9-10. Finding M-11 (§16.3, closed by 10.108): L-1 with the sign flipped — a
# value that parses to ALL ranges rather than to none. Round 8 watched both of
# these START, with the allowlist reading X-Forwarded-For from every peer on
# the internet. They are here because a closed finding with no committed check
# is a finding that can reopen quietly.
shape "M-11: an IPv4 wildcard allowlist" refused "too broad" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=0.0.0.0/0" \
  "TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified"
shape "M-11: an IPv6 wildcard allowlist" refused "too broad" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=::/0" \
  "TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified"

# 11-14. Task 10.80's diagnostics console refusals (§4.10, §4.6, §4.1).
#
# **These were watched by hand once, which is the state this whole file exists
# to replace.** Round 8 ran its matrix by hand and committed none of it; a
# refusal proven once on a developer's laptop and never again is the same
# thing one round later. Four of the five refusals `DiagnosticsConfig`
# raises are deployment shapes, so they belong in the deployment matrix.
#
# **Every one of these also needs the source-identity question answered
# first**, because `bin/server.dart` asks that before it asks about the
# console — deliberately, since it is the mandatory subsystem. A shape that
# left it out would refuse on EXIT 78 for the wrong reason, and the needle
# checks below are what would say so.
#
# The token values go through shell variables rather than appearing as
# literal assignments to TRITRACK_DIAGNOSTICS_TOKEN. Same reason this file
# already keeps POSTGRES_PASSWORD out entirely: §4.6's committed-secrets test
# flags an assignment to a known secret variable, placeholder or not, and a
# rule that has to judge whether a committed secret is "really" one is a rule
# that will get it wrong once.
LOOPBACK="TRITRACK_PUBLISH_ADDRESS=127.0.0.1"
CONSOLE_ON="TRITRACK_DIAGNOSTICS_ENABLED=true"
# 64 hex characters, generated per run: the shape the README tells an operator
# to produce, and never the same value twice, so nothing here can become a
# credential somebody recognises.
TOKEN_OK="$(openssl rand -hex 32)"
# 31 characters — one below the floor, and not a placeholder by any rule in
# `placeholder_secrets.dart`, so the shape below can only be refused by the
# length rule it is aimed at.
TOKEN_SHORT="$(openssl rand -hex 32 | cut -c1-31)"
TOKEN_PLACEHOLDER="changeme"

shape "10.80: a placeholder console token" refused "placeholder" \
  "$LOOPBACK" "$CONSOLE_ON" \
  "TRITRACK_DIAGNOSTICS_TOKEN=${TOKEN_PLACEHOLDER}"
shape "10.80: a console token below the floor" refused "at least 32" \
  "$LOOPBACK" "$CONSOLE_ON" \
  "TRITRACK_DIAGNOSTICS_TOKEN=${TOKEN_SHORT}"
shape "10.80: the console on a production deployment" refused "4.10" \
  "$LOOPBACK" "$CONSOLE_ON" "TRITRACK_ENV=production" \
  "TRITRACK_TRUSTED_PROXIES=peer-verified" \
  "TRITRACK_DIAGNOSTICS_TOKEN=${TOKEN_OK}"
shape "10.80: the console off-host without TLS" refused "TRITRACK_TLS_CERT_PATH" \
  "$LOOPBACK" "$CONSOLE_ON" "TRITRACK_DIAGNOSTICS_ALLOW_REMOTE=true" \
  "TRITRACK_DIAGNOSTICS_TOKEN=${TOKEN_OK}"

# 15-16. Task 11.287's sign-in email refusals (§4.5, §4.6). Until that task a
# production server with no relay configured STARTED, resolved the silent
# sender, and answered every sign-in request with 202 while delivering
# nothing — §4.5's identical response hiding a total outage. Both shapes
# answer the source-identity question first (`peer-verified` on a loopback
# publish) so that the refusal measured is the one claimed, as the four
# above do. TRITRACK_SMTP_PASSWORD is deliberately absent from both: the
# cleartext refusal fires on the TLS mode alone, and a literal assignment
# to that variable is what §4.6's committed-secrets test watches for.
SMTP_FROM="TRITRACK_SMTP_FROM=tritrack@localhost"
shape "11.287: production with no sign-in relay" refused "TRITRACK_SMTP_HOST" \
  "$LOOPBACK" "TRITRACK_ENV=production" \
  "TRITRACK_TRUSTED_PROXIES=peer-verified"
shape "11.287: a cleartext relay in production" refused "TRITRACK_SMTP_TLS=none" \
  "$LOOPBACK" "TRITRACK_ENV=production" \
  "TRITRACK_TRUSTED_PROXIES=peer-verified" \
  "TRITRACK_SMTP_HOST=127.0.0.1" "TRITRACK_SMTP_TLS=none" "$SMTP_FROM"

# 17-20. The controls. Without these, every line above is equally explained by
# "this image never starts", which is the shape round 8's first draft of this
# matrix actually had.
shape "CONTROL: a licensed allowlist" starts "" \
  "$REACHABLE" "$CLEARTEXT" "TRITRACK_TRUSTED_PROXIES=203.0.113.4" \
  "TRITRACK_PROXY_SOURCE_IDENTITY=probe-verified"
shape "CONTROL: loopback publish, nothing declared" starts "" \
  "TRITRACK_PUBLISH_ADDRESS=127.0.0.1"
# The control the four shapes above need specifically: a console configured
# the way server/README.md says to configure it must START. Without this line
# all four are equally explained by "the console never lets anything start",
# which would make the refusals worthless and the documented procedure wrong.
shape "CONTROL: a correctly configured console" starts "" \
  "$LOOPBACK" "$CONSOLE_ON" \
  "TRITRACK_DIAGNOSTICS_TOKEN=${TOKEN_OK}"
# The control the two 11.287 shapes need: production WITH a relay declared
# must start. Nothing listens on 127.0.0.1:587 inside the container, so the
# server's startup probe reports the relay unreachable in its log — a
# warning, by design, because a relay that is down is not a configuration
# that is wrong, and a server that will not boot until its relay answers
# cannot serve sync to people who are already signed in.
shape "CONTROL: production with a sign-in relay declared" starts "" \
  "$LOOPBACK" "TRITRACK_ENV=production" \
  "TRITRACK_TRUSTED_PROXIES=peer-verified" \
  "TRITRACK_SMTP_HOST=127.0.0.1" "$SMTP_FROM"

echo
echo "---- Matrix summary ----"
echo "  $REFUSED shapes refused with EXIT 78, $STARTED started."
echo "  $PASS of $((PASS + FAIL)) shapes behaved as the security model says."

# The discriminator, and the reason round 8's first attempt at this was
# thrown away: a matrix where everything lands on the same side measures
# nothing at all, however many rows it prints.
if [ "$REFUSED" -eq 0 ] || [ "$STARTED" -eq 0 ]; then
  echo
  echo "FAIL: this matrix is blind — $REFUSED refused and $STARTED started, so"
  echo "it never saw two different answers. Every verdict above is equally"
  echo "explained by a harness that cannot start (or cannot stop) the image."
  exit 1
fi

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "FAIL: $FAIL shape(s) did not behave as the security model says."
  echo "Full per-shape logs: $OUT_DIR"
  exit 1
fi
echo "PASS: every shape behaved as documented, and the matrix saw both answers."
echo "Full per-shape logs: $OUT_DIR"

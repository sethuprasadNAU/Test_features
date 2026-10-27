#!/usr/bin/env bash
# gate-instrument: verify_smtp_delivery
#
# Does the sign-in email sender deliver through a relay that is NOT the one its
# unit tests were written against? (task 11.287)
#
# `server/test/auth/smtp_email_sender_test.dart` proves the client against a
# fake relay written in the same file tree by the same hands, which is the
# weakest possible witness for interoperability. This drill stands up Mailpit —
# a Go SMTP server nobody on this project wrote — with STARTTLS *required* and
# authentication on, then pushes a message through `server --send-test-email`,
# the exact command an operator runs against a real relay, and reads it back
# out of the catcher's API.
#
# Broken control first (defect vocabulary 70): the same command with the wrong
# password has to FAIL and name the credentials, and the catcher has to be
# empty afterwards. A drill whose only arm is the happy one has proven that it
# does not fire, and nothing else.
#
# What this cannot prove, and says so: that a message reaches a real inbox
# through NAU's relay. Only sending one does that — see server/README.md,
# "Sign-in email", for the command.
#
# **The sender runs inside the server image, not on the host** (task 11.318 item 4). The
# gate's machines have Docker and Python and nothing else — no Dart — and this is also
# what an operator actually runs against a real relay (`docker compose run --rm --no-deps
# server --send-test-email`, server/README.md), so the drill now exercises the shipped
# artifact rather than a source tree. The sender shares the relay container's network
# (`--network container:...`), which is why the certificate's `localhost` still matches.
#
# **The relay image is pinned by digest, not by tag** — see MAILPIT_IMAGE below for what
# that buys and what it gives up. **If the image cannot be pulled, this drill FAILS and
# says "COULD NOT PULL"**; it never passes having tested nothing. The gate's VM has lost
# its network three times, and a drill that quietly skipped on that would be a check that
# is green exactly when the machine is broken.
#
# Usage: scripts/verify_smtp_delivery.sh
# Requires: Docker, openssl, curl, python3. Nothing is read from .env. No Dart SDK.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
. scripts/lib/wait_for.sh

CHECKS=0
pass() { CHECKS=$((CHECKS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tritrack-smtp-drill.XXXXXX")"
CONTAINER="tritrack-smtp-drill-$$"
SERVER_IMAGE="tritrack-smtp-drill-server:$(date +%s)-$$"
# **Pinned by digest, deliberately** (task 11.318 item 4): this is Mailpit v1.31.3, the
# multi-architecture index as `axllent/mailpit:latest` resolved on 2026-10-01. A tag moves
# under a drill without anybody touching it — `latest` is not even a version — and this
# image only has to be a relay nobody on this project wrote; it does not have to be the
# newest one. **What a digest gives up:** it never receives a fix by itself, so a Mailpit
# security advisory is for a person to notice; it is a test-only catcher bound to
# 127.0.0.1, so that cost is small. **To move it deliberately:**
# `docker buildx imagetools inspect axllent/mailpit:<tag>`, take the top-level `Digest:`
# (the index, so amd64 and arm64 both resolve), and update this line and the version above.
MAILPIT_IMAGE="axllent/mailpit@sha256:ed9b00c609e77e99c79b93f1178255ebc271868920f2c69a8d166bd5634ed10d"
API_PORT="${TRITRACK_SMTP_DRILL_API_PORT:-18025}"
# The relay listens on 1025 inside its own container; the sender joins that container's
# network, so this is the port it dials. Nothing about SMTP is published to the host.
RELAY_SMTP_PORT=1025
# Generated per run, never the same twice, so nothing here can become a
# credential somebody recognizes — and never assigned to a variable whose
# name the committed-secrets check watches.
DRILL_PASSWORD="$(openssl rand -hex 16)"
WRONG_PASSWORD="$(openssl rand -hex 16)"

cleanup() {
  local status=$?
  if [ "$status" != "0" ]; then
    # Keep the evidence on a red run (defect vocabulary 84): the catcher's
    # log is the other half of every conversation this drill had.
    if docker inspect "$CONTAINER" >/dev/null 2>&1; then
      echo
      echo "---- mailpit log (kept because the drill failed) ----" >&2
      docker logs "$CONTAINER" 2>&1 | sed 's/^/    /' >&2 || true
    fi
    echo "---- drill work directory: $WORK (not deleted) ----" >&2
  else
    rm -rf "$WORK"
  fi
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker image rm -f "$SERVER_IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

step "0. A certificate for the relay, and a relay that requires STARTTLS"
# The same extensions the unit test needs: a self-signed certificate is only
# a trust anchor when it says it is one, and macOS's verifier wants the key
# usages spelled out as well (measured 2026-09-20).
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign" \
  -addext "extendedKeyUsage=serverAuth" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" >"$WORK/openssl.log" 2>&1 \
  || { cat "$WORK/openssl.log"; fail "openssl could not make the relay's certificate"; }
chmod 644 "$WORK/key.pem" "$WORK/cert.pem"

# **Pull first, and say so if it cannot.** A copy already on this machine *by this digest*
# is the same bytes, so it is used without a pull; otherwise the pull is the first thing
# that can fail, and it fails by name rather than letting `docker run` below fail
# somewhere less legible.
if docker image inspect "$MAILPIT_IMAGE" >/dev/null 2>&1; then
  pass "the relay image is already on this machine, by its pinned digest (no pull needed)"
elif docker pull "$MAILPIT_IMAGE" >"$WORK/pull.log" 2>&1; then
  pass "pulled the relay image by its pinned digest"
else
  cat "$WORK/pull.log"
  fail "COULD NOT PULL ${MAILPIT_IMAGE} — nothing was tested. This is the network or the registry, not the sender: re-run when Docker can reach Docker Hub."
fi

if ! docker build -f server/Dockerfile -t "$SERVER_IMAGE" . >"$WORK/build.log" 2>&1; then
  tail -n 30 "$WORK/build.log"
  fail "COULD NOT BUILD the server image the sender runs in — see above and $WORK/build.log. Nothing was tested."
fi
pass "built the server image the sender runs in"

docker run -d --name "$CONTAINER" \
  -p "127.0.0.1:${API_PORT}:8025" \
  -v "$WORK:/certs:ro" \
  -e MP_SMTP_TLS_CERT=/certs/cert.pem -e MP_SMTP_TLS_KEY=/certs/key.pem \
  -e MP_SMTP_REQUIRE_STARTTLS=true \
  -e MP_SMTP_AUTH="tritrack:${DRILL_PASSWORD}" \
  "$MAILPIT_IMAGE" >"$WORK/docker-run.log" 2>&1 \
  || { cat "$WORK/docker-run.log"; fail "could not start the relay container — see above"; }

api() { curl -sf "http://127.0.0.1:${API_PORT}/api/v1/$1"; }
if ! wait_for 30 1 -- api info; then
  fail "the relay's API never answered on 127.0.0.1:${API_PORT}. $(wait_for_evidence)"
fi
pass "Mailpit is up: STARTTLS required, authentication on, loopback only"

# Everything the sender needs, and nothing from .env: this drill is about the
# client, not about anybody's deployment. The password goes in by *name* (`-e NAME`
# with no value) so it is never on a command line another process could list.
run_send() {
  local password="$1" address="$2"
  TRITRACK_SMTP_PASSWORD="$password" docker run --rm \
    --network "container:${CONTAINER}" \
    -v "$WORK:/certs:ro" \
    -e TRITRACK_SMTP_HOST=localhost \
    -e TRITRACK_SMTP_PORT="$RELAY_SMTP_PORT" \
    -e TRITRACK_SMTP_TLS=starttls \
    -e TRITRACK_SMTP_FROM=tritrack-drill@example.edu \
    -e TRITRACK_SMTP_USERNAME=tritrack \
    -e TRITRACK_SMTP_PASSWORD \
    -e TRITRACK_SMTP_CA_CERT_PATH=/certs/cert.pem \
    "$SERVER_IMAGE" --send-test-email "$address"
}
message_count() { api messages | python3 -c 'import json,sys; print(json.load(sys.stdin)["total"])'; }

step "1. Broken control — the wrong password must be refused, by name"
set +e
run_send "$WRONG_PASSWORD" drill@example.edu >"$WORK/wrong.log" 2>&1
wrong_status=$?
set -e
[ "$wrong_status" = "1" ] \
  || { cat "$WORK/wrong.log"; fail "expected exit 1 on a rejected credential, got $wrong_status"; }
grep -q "rejected the credentials" "$WORK/wrong.log" \
  || { cat "$WORK/wrong.log"; fail "the failure does not say the relay rejected the credentials"; }
grep -q "TRITRACK_SMTP_PASSWORD" "$WORK/wrong.log" \
  || { cat "$WORK/wrong.log"; fail "the failure does not name the variable to change"; }
grep -q -- "$WRONG_PASSWORD" "$WORK/wrong.log" \
  && { fail "the failure line echoed the password (Security Model §4.7 rule 5)"; }
[ "$(message_count)" = "0" ] \
  || fail "the catcher holds a message after a refused authentication — the relay is not enforcing what this drill assumes"
pass "refused with exit 1, names the credentials, never echoes the password, nothing delivered"

step "2. The right password — one message, through STARTTLS, into the catcher"
run_send "$DRILL_PASSWORD" drill@example.edu >"$WORK/right.log" 2>&1 \
  || { cat "$WORK/right.log"; fail "the send failed — see above"; }
grep -q "ACCEPTED" "$WORK/right.log" \
  || { cat "$WORK/right.log"; fail "the send did not report the relay accepting the message"; }
[ "$(message_count)" = "1" ] \
  || fail "expected exactly one message in the catcher, found $(message_count)"

MESSAGE_ID="$(api messages | python3 -c 'import json,sys; print(json.load(sys.stdin)["messages"][0]["ID"])')"
api "message/${MESSAGE_ID}" >"$WORK/message.json"
python3 - "$WORK/message.json" <<'PY' || fail "the delivered message is not the one the sender describes — see above"
import json, sys
m = json.load(open(sys.argv[1]))
problems = []
if m["To"][0]["Address"] != "drill@example.edu":
    problems.append("To is %r" % m["To"])
if m["From"]["Address"] != "tritrack-drill@example.edu":
    problems.append("From is %r" % m["From"])
if m["Subject"] != "TriTrack sign-in email test":
    problems.append("Subject is %r" % m["Subject"])
if "test message from a TriTrack server" not in m["Text"]:
    problems.append("body does not say what it is")
if "http" in m["Text"]:
    problems.append("the test message carries a link, and it must not")
for p in problems:
    print("    " + p)
sys.exit(1 if problems else 0)
PY
pass "delivered: right recipient, right sender, right subject, no link in a test message"

# Mailpit records whether each message arrived over TLS in its own log, not in
# the API. STARTTLS was *required* at start-up, so a message in the catcher is
# a message that negotiated it — but say what was measured rather than infer.
if docker logs "$CONTAINER" 2>&1 | grep -i "starttls required" >/dev/null; then
  pass "the relay was started with STARTTLS required, so the message above crossed TLS"
else
  fail "the relay's log does not confirm STARTTLS was required; the TLS claim above is unsupported"
fi

echo
echo "---- Verdict ----"
echo "  $CHECKS checks passed. The sender delivers through a relay it was not written"
echo "  against, over STARTTLS with authentication, and refuses a bad credential by"
echo "  name. NOT PROVEN HERE: that a message reaches a real inbox through the"
echo "  relay a deployment actually uses — run 'server --send-test-email' there."

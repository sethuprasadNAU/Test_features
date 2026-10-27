#!/usr/bin/env bash
# gate-instrument: none - needs a real signed iOS device, which no unattended run has.
# App Transport Security hardware verification (task 10.50 / F13,
# `TriTrack_Security_Model.md` §7.6, §8.5, §9.0, §10, §10.5.3).
#
#   scripts/verify_ats_transport_security.sh [device-id] [extra flutter test flags...]
#
# Runs `integration_test/ats_transport_security_test.dart` — see that file's
# header for the full reasoning — as the real, sandboxed app bundle on a real
# platform, which is the only way ATS is actually exercised (`flutter test`'s
# plain `flutter_tester` harness ships no `Info.plist` and cannot).
#
# With no argument, runs against every currently attached device/simulator
# this machine has (from `flutter devices`), skipping non-Apple ones loudly
# rather than silently — the test itself also refuses to report a pass on a
# platform ATS cannot apply to, so this is belt-and-suspenders, not the only
# guard. Pass a specific device id (`flutter devices` lists them) to run just
# one, plus any extra flags — e.g. `macos --profile` for the cheapest real
# run (task 10.95, L-13/10.82: `--release` cannot work here — `flutter test`
# does not build a signed release macOS bundle), or a booted iOS Simulator's
# id.
#
# Starts a throwaway HTTP responder for request #3, as its own unsandboxed
# process — never from inside the app under test, which is exactly the
# reasoning `ats_transport_security_test.dart`'s own header gives for not
# binding a socket from inside a release-sandboxed app. Bound to 0.0.0.0 (not
# just loopback), because a PHYSICAL device's own "127.0.0.1" is the phone's
# loopback, not this Mac's — reachable only via this Mac's real LAN address,
# which is what makes request #3 a LAN address for a physical device and a
# loopback address for macOS/Simulator (which share this machine's network
# stack). Torn down on exit, success or failure.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Task 11.176 — readiness loops keep their last attempt's error. See that file.
# shellcheck disable=SC1091
. scripts/lib/wait_for.sh

PORT=8123
RUNS=0
FAILED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail_run() { RUNS=$((RUNS + 1)); FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; }
pass_run() { RUNS=$((RUNS + 1)); pass "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

RESPONDER_PID=""
cleanup() {
  step "Tearing down"
  if [ -n "$RESPONDER_PID" ]; then
    kill "$RESPONDER_PID" >/dev/null 2>&1 || true
    wait "$RESPONDER_PID" 2>/dev/null || true
  fi
  echo "  stopped the responder"
}
trap cleanup EXIT

step "Starting the local responder for request #3 (0.0.0.0:${PORT})"
python3 -c "
import http.server, sys
class OK(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.end_headers()
        self.wfile.write(b'ok')
    def log_message(self, *a):
        pass
http.server.HTTPServer(('0.0.0.0', ${PORT}), OK).serve_forever()
" &
RESPONDER_PID=$!
# The probe is the subject: curl to the responder's own port. Task 11.176 added
# the two facts the failure used to withhold — what curl actually said on the
# last try, and whether the python process is even alive, which separates "the
# responder crashed" (its traceback is on this terminal, above) from "it is
# running and something else is between us and it", most often port ${PORT}
# already being held by an earlier run.
if ! wait_for 20 0.2 -- curl -fsS "http://127.0.0.1:${PORT}/"; then
  if kill -0 "$RESPONDER_PID" 2>/dev/null; then
    echo "Local responder never came up. The python process (pid ${RESPONDER_PID}) is still running, so it started and is not answering on 127.0.0.1:${PORT}." >&2
  else
    echo "Local responder never came up. The python process has already exited — any traceback it printed is above this line." >&2
  fi
  echo "$(wait_for_evidence)" >&2
  exit 1
fi
pass "local responder answering on 0.0.0.0:${PORT}"

# This machine's real LAN address, for a physical device's request #3 — its
# own 127.0.0.1 is itself, not this Mac. Best-effort across the common
# interface names; falls back to loopback (which will correctly fail request
# #3 on a physical device, loudly, rather than silently using the wrong
# address) if none resolve.
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")"

run_on() { # <device-id> <label> <extra flutter drive args...>
  local device="$1" label="$2"
  shift 2
  step "Running against ${label} (${device})"

  # Physical device vs macOS/Simulator decides which address reaches this
  # Mac's responder: a Simulator and macOS itself share this machine's
  # network stack, so 127.0.0.1 is correct for them; a physical device's own
  # loopback is the phone, not the Mac (verified live — see the task's
  # Security Model entry: the first physical-device run failed request #3
  # this exact way).
  local target="http://127.0.0.1:${PORT}/"
  local device_info
  device_info="$(flutter devices --machine 2>/dev/null | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
target = sys.argv[1] if len(sys.argv) > 1 else ""
for d in devices:
    if d.get("id") == target:
        platform = d.get("targetPlatform", "")
        emulator = d.get("emulator")
        print(platform + "\t" + str(emulator))
        break
' "$device")"
  case "$device_info" in
    ios*False*) target="http://${LAN_IP}:${PORT}/" ;;
  esac
  echo "  request #3 target: ${target}"

  # `flutter drive`, not `flutter test -d` — the latter has no build-mode
  # flag at all (verified: `flutter test -h -v` lists none) and always runs a
  # debug-equivalent configuration, so it cannot exercise
  # `macos/Runner/Release.entitlements` or a genuine release `Info.plist`.
  # `flutter drive --release` builds and installs the real app bundle.
  if flutter drive \
      --driver=test_driver/integration_test.dart \
      --target=integration_test/ats_transport_security_test.dart \
      -d "$device" "$@" \
      --dart-define=ATS_TEST_LOCAL_URL="$target"; then
    pass_run "${label}"
  else
    fail_run "${label}"
  fi
}

if [ $# -ge 1 ]; then
  DEVICE="$1"
  shift
  run_on "$DEVICE" "$DEVICE $*" "$@"
else
  step "No device given — discovering attached devices/simulators"
  DEVICES_JSON="$(flutter devices --machine 2>/dev/null)"
  # Apple platforms only — CupertinoClient/ATS do not exist elsewhere, and
  # the test itself fails loudly (never skips) if it is somehow run on one.
  APPLE_IDS="$(printf '%s' "$DEVICES_JSON" | python3 -c '
import json, sys
try:
    devices = json.load(sys.stdin)
except Exception:
    devices = []
for d in devices:
    if d.get("targetPlatform", "").startswith(("darwin", "ios")):
        print(d["id"])
')"
  if [ -z "$APPLE_IDS" ]; then
    echo "No attached macOS/iOS device or simulator found. Boot one" >&2
    echo "(\`open -a Simulator\`, or connect a Mac/iPhone) and re-run, or" >&2
    echo "pass a device id explicitly: $0 <device-id>" >&2
    exit 1
  fi
  while IFS= read -r device; do
    [ -n "$device" ] || continue
    run_on "$device" "$device"
  done <<<"$APPLE_IDS"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED — ${FAILED} of ${RUNS} run(s) did not pass. See above." >&2
  exit 1
fi
echo "ALL RUNS PASSED — ${RUNS} device/simulator run(s)."
echo "Record OS version and build mode for each in TriTrack_Security_Model.md under F13."

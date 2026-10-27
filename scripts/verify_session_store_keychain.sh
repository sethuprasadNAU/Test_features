#!/usr/bin/env bash
# gate-instrument: none - needs a real signed device, which no unattended run has.
# Secure-store hardware verification (task 11.38).
#
#   scripts/verify_session_store_keychain.sh [device-id] [extra flutter flags...]
#
# Runs `integration_test/session_store_keychain_test.dart` as the real, signed
# app bundle — the only way the platform keychain is exercised at all. See
# that file's header for why nothing under `test/` can do this: `flutter test`
# has no platform channels, so every existing sign-in test substitutes an
# in-memory store, and the line that failed on macOS had never run.
#
# With no argument this runs on macOS in debug and profile. Pass a device id to
# run somewhere else — a booted iOS Simulator, or a physical iPhone — plus any
# extra flags.
#
# **`Release.entitlements` cannot be exercised here, and pretending otherwise
# was this script's first bug.** `flutter drive` refuses to run in release mode
# at all ("Flutter Driver (non-web) does not support running in release mode"),
# and profile builds use `DebugProfile.entitlements`, so no integration test
# can reach the release entitlements file. Task 10.50 hit the same wall for App
# Transport Security. What covers it instead is
# `test/platform/macos_keychain_entitlement_test.dart`, which asserts
# `Release-Signed.entitlements` declares the keychain entitlement AND stays
# byte-identical to its debug counterpart apart from that block — so the file
# that cannot be run is at least prevented from drifting away from the one that
# can. That is a weaker guarantee than a run, and it is named here rather than
# left to be discovered.
#
# **This test fails on an ad-hoc-signed build, by design.** macOS refuses the
# data-protection keychain to an app with no team, with `-34018`. That is not
# a broken test; it is a build that genuinely cannot sign in. If that is what
# you see, you have not set up `macos/Runner/Configs/Signing.xcconfig` — see
# README.md, "Signing the macOS build".
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

RUNS=0
FAILED=0
pass_run() { RUNS=$((RUNS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail_run() { RUNS=$((RUNS + 1)); FAILED=$((FAILED + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# `flutter drive`, not `flutter test -d`: the latter has no build-mode flag at
# all and always runs a debug-equivalent configuration, so it can never reach
# `Release.entitlements`. Same reasoning, and the same comment, as
# `verify_ats_transport_security.sh`.
run_on() {
  local device="$1" label="$2"
  shift 2
  step "Running on ${label}"
  if flutter drive \
      --driver=test_driver/integration_test.dart \
      --target=integration_test/session_store_keychain_test.dart \
      -d "$device" "$@"; then
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
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "No device given and this is not a Mac. Pass a device id explicitly." >&2
    exit 1
  fi
  run_on macos "macos --debug (DebugProfile.entitlements)" --debug
  # Same entitlements file as debug; the added value is the optimized build,
  # not extra entitlement coverage. See the note at the top of this file.
  run_on macos "macos --profile (DebugProfile.entitlements, optimized)" --profile
fi

step "Result"
if [ "$FAILED" -gt 0 ]; then
  echo "FAILED — ${FAILED} of ${RUNS} run(s) did not pass. See above." >&2
  echo "If this is -34018, the build is not signed by a real team:" >&2
  echo "  README.md -> \"Signing the macOS build\"" >&2
  exit 1
fi
echo "ALL RUNS PASSED — ${RUNS} run(s)."

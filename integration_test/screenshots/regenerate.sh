#!/usr/bin/env bash
#
# Rebuild every screenshot the website uses. This is the one command.
#
#   integration_test/screenshots/regenerate.sh                 # every profile
#   integration_test/screenshots/regenerate.sh iphone-6.9      # just one
#   integration_test/screenshots/regenerate.sh iphone-6.9 --accept
#
# Without --accept nothing is written over: the run captures into a staging
# directory, compares against what is committed, and names every screen that
# moved. See review.dart, and README.md for why it works that way.
#
# Exit codes: 0 nothing to do (or accepted), 1 a screen changed and nobody has
# said yes, 2 the run could not happen. Two is not a pass.
#
# **One run at a time, and this script is where that is enforced.** The two
# lanes of work on this repository share one working tree and one `build/`
# directory, and on 2026-08-31 a second run's `rm -rf` deleted 23 finished
# images out from under the first between the capture and the review. A rule
# in a document cannot stop that, because running the harness to check a fix
# is a reasonable thing to want to do; a lock can. See take_lock below.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
here="integration_test/screenshots"
staging="build/screenshots"

# Profile -> simulator device name.
#
#   iphone-6.1  1179 x 2556   393 x 852 logical, at the 3x scale iOS renders
#   iphone-6.9  1320 x 2868   App Store "6.9-inch iPhone"
#   ipad-13     2064 x 2752   App Store "13-inch iPad"
#
# The last two are not arbitrary: their native resolutions are exactly the
# sizes App Store Connect asks for, so submission screenshots are the same
# files the guide uses.
#
# **`iphone-6.1` is not one of those, and it is here for a different reason**
# (`/w-16`, from task 11.195). 393 x 852 is exactly `phoneGeometry` in
# `test/support/app_shell_harness.dart` — the smallest screen this app
# supports, and **the geometry every space-budget assertion in this project is
# written for**. Two tasks in a row (11.193, 11.195) were about a control cut
# off on that size and neither could be checked against a picture, because the
# only phone this harness photographed was 104 logical pixels taller. 11.195
# added the profile by hand, confirmed its fix and reverted the script,
# because the baselines belong in `website/` and that is the content lane's.
#
# **The whole set is captured on it, not a subset**, and the reasoning is in
# `README.md` under "Why the 6.1-inch profile shoots everything".
#
# **The device is an iPhone 16 and it was measured, not assumed.** The obvious
# choice was an iPhone 17e — the 6.1-inch phone in the current line-up, and
# what task 11.195 used. It photographs at **1170 x 2532, which is 390 x 844
# logical**: three points narrower and eight shorter than `phoneGeometry`. That
# is a different screen from the one every space-budget assertion in this
# project is written against, and a profile whose entire justification is
# "exactly the geometry the assertions use" cannot be approximately that. An
# iPhone 16 is 393 x 852, which is the number in `phoneSize`.
#
# **`device_for` names it and `udid_for` creates it if it is missing**, because
# a profile that only works on a machine where somebody remembered to add a
# simulator by hand is a profile that quietly stops being captured.
#
# **There is no macOS profile, and it is not an oversight.** `flutter drive -d
# macos` builds and runs the app perfectly well, and then
# `takeScreenshot` fails with "No implementation found for method
# captureScreenshot" — the `integration_test` plugin does not implement it on
# macOS. The run reported "All tests passed" over an empty directory and only
# the review's refusal to call nothing green noticed. Capturing the desktop
# app needs a different mechanism (`screencapture` on the host, driven from
# `driver.dart`); until somebody builds it, there are no desktop screenshots
# rather than fake ones.
declare -a PROFILES=(iphone-6.1 iphone-6.9 ipad-13)
device_for() {
  case "$1" in
    iphone-6.1) echo "iPhone 16" ;;
    iphone-6.9) echo "iPhone 17 Pro Max" ;;
    ipad-13)    echo "iPad Pro 13-inch (M5)" ;;
    *)          echo "" ;;
  esac
}

# The invented study area, and it must agree with seed.dart. The simulator's
# own location is set here so anything asking the OS where it is gets the same
# answer the seeded data assumes.
SEED_LAT=42.7008
SEED_LON=-117.3612

accept=""
wanted=()
for arg in "$@"; do
  case "$arg" in
    --accept) accept="--accept" ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)  wanted+=("$arg") ;;
  esac
done
if [ ${#wanted[@]} -eq 0 ]; then wanted=("${PROFILES[@]}"); fi

# --------------------------------------------------------------------------
# One run at a time.
#
# **`mkdir` is the lock, because `mkdir` is atomic.** There is no portable
# `flock` on macOS, and a "does a lock file exist?" test is a race with itself.
# The directory carries an `owner` file naming the process that holds it, so a
# refusal can say *who* is running rather than only that somebody is.
# --------------------------------------------------------------------------
lockdir="$staging/.regenerate.lock"
held=""

release_lock() {
  if [ -n "$held" ]; then
    rm -rf "$held"
    held=""
  fi
}
trap 'release_lock; exit 130' INT TERM HUP
trap release_lock EXIT

take_lock() {
  mkdir -p "$staging" || return 1
  if mkdir "$lockdir" 2>/dev/null; then
    held="$lockdir"
    printf 'pid %s\nstarted %s\nprofiles %s\n' \
      "$$" "$(date '+%Y-%m-%d %H:%M:%S')" "${wanted[*]}" > "$lockdir/owner"
    return 0
  fi
  return 1
}

if ! take_lock; then
  owner_pid=$(sed -n 's/^pid //p' "$lockdir/owner" 2>/dev/null | sed -n 1p)
  owner_started=$(sed -n 's/^started //p' "$lockdir/owner" 2>/dev/null | sed -n 1p)
  owner_profiles=$(sed -n 's/^profiles //p' "$lockdir/owner" 2>/dev/null | sed -n 1p)
  if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
    echo "Another screenshot run is already going: process $owner_pid, started" >&2
    echo "${owner_started:-at an unrecorded time}, on ${owner_profiles:-an unrecorded profile}." >&2
    echo "" >&2
    echo "It owns $staging, and this run would empty that directory underneath" >&2
    echo "it. That is what destroyed 23 finished images on 2026-08-31, and the" >&2
    echo "run that lost reported it as an ordinary changed screen rather than" >&2
    echo "as a run that could not read its own output. So this one refuses to" >&2
    echo "start rather than joining in." >&2
    echo "" >&2
    echo "Wait for it to finish. If you are certain it is gone, delete" >&2
    echo "$lockdir and run this again." >&2
    exit 2
  fi
  # **A lock whose owner is dead is reclaimed, and the reclaim is announced.**
  # A crashed run that leaves the harness permanently unusable would be a
  # worse failure than the one the lock prevents, and a silent reclaim would
  # be a lock that only pretends to be one.
  echo "warning: $lockdir was left behind by process ${owner_pid:-unknown}," >&2
  echo "which is no longer running. Reclaiming it. If a run really is in" >&2
  echo "progress, stop now — its images are about to be deleted." >&2
  rm -rf "$lockdir"
  if ! take_lock; then
    echo "Could not take $lockdir even after clearing a stale one. Something" >&2
    echo "else is creating it, so this run refuses to start rather than" >&2
    echo "racing it." >&2
    exit 2
  fi
fi

# --------------------------------------------------------------------------
# **Is the harness still measuring the app?** (`/w-10`.)
#
# `preflight.dart` reads the harness's own source and refuses the run if it
# builds a `ProviderContainer` without the app's retry policy. That is not a
# hypothetical: the published `project-members.png` showed twenty seconds of
# spinner because this harness ran Riverpod's default of ten attempts where
# the app gives up in 1.6 seconds, and the picture was accepted, described in
# a readiness comment as an app defect, and filed for the code lane before
# task 11.142 found the harness.
#
# It runs before the lock is taken and before any simulator is booted: there
# is no point spending twenty minutes photographing screens with an instrument
# that is waiting on a rule the app does not have. Exit 1 is a refusal, exit 2
# is the check itself being unable to run, and neither starts a capture.
# --------------------------------------------------------------------------
dart run "$here/preflight.dart"
preflight_status=$?
if [ $preflight_status -ne 0 ]; then
  echo "" >&2
  echo "The harness preflight refused this run (exit $preflight_status). No" >&2
  echo "screens were photographed." >&2
  exit 2
fi

overall=0
started=$(date +%s)

for profile in "${wanted[@]}"; do
  device=$(device_for "$profile")
  if [ -z "$device" ]; then
    echo "No such profile: $profile (have: ${PROFILES[*]})" >&2
    exit 2
  fi

  out="$staging/$profile"
  rm -rf "$out"
  mkdir -p "$out"

  echo ""
  echo "=== $profile ($device) ==="
  profile_started=$(date +%s)

  {
    udid=$(xcrun simctl list devices available \
      | grep -F "$device (" | sed -n 1p \
      | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
    if [ -z "$udid" ]; then
      # **Created rather than demanded, when the device type is installed.**
      # Xcode ships the device types for phones it no longer sells, so the
      # only thing usually missing is somebody having clicked "add" — and a
      # profile that silently stops being captured on a machine where nobody
      # did is worse than one that provisions itself and says so.
      devicetype=$(xcrun simctl list devicetypes \
        | grep -F "$device (com.apple" | sed -n 1p \
        | sed -E 's/.*\((com\.apple[^)]*)\).*/\1/')
      if [ -n "$devicetype" ]; then
        echo "No simulator called \"$device\" yet; creating one from" >&2
        echo "$devicetype so this profile can be captured on this machine." >&2
        udid=$(xcrun simctl create "$device" "$devicetype" 2>/dev/null | tail -1)
      fi
    fi
    if [ -z "$udid" ]; then
      echo "No available simulator called \"$device\", and no device type of" >&2
      echo "that name to create one from. Install it in Xcode's component" >&2
      echo "list, or edit device_for() above." >&2
      exit 2
    fi
    xcrun simctl boot "$udid" 2>/dev/null
    # **The Simulator application has to be open, not merely booted.** A
    # headless simulator runs the app but never drives a display link, so
    # Flutter produces no frames, the driver extension never registers, and
    # `flutter drive` hangs for fifteen minutes and then reports that the test
    # app is probably missing an import. Found the hard way, 2026-08-31.
    open -a Simulator
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
    xcrun simctl location "$udid" set "$SEED_LAT,$SEED_LON" 2>/dev/null \
      || echo "warning: could not set the simulator's location; anything " \
              "reading the OS position will show the wrong place" >&2
    target_device="$udid"
  }

  # **Debug mode, and not by choice.** `flutter drive --profile` against a
  # simulator fails outright — "release/profile builds are only supported for
  # physical devices" — so every simulator screenshot is of a debug build.
  # That is not cosmetically neutral: a debug build paints a layout overflow
  # as yellow-and-black stripes that a shipped build never draws. See the
  # "What it cannot photograph honestly" section of README.md.
  TRITRACK_SHOT_DIR="$PWD/$out" flutter drive \
    --driver="$here/driver.dart" \
    --target="$here/capture_test.dart" \
    -d "$target_device"
  drive_status=$?

  profile_elapsed=$(( $(date +%s) - profile_started ))
  echo "--- $profile: capture took $((profile_elapsed / 60))m $((profile_elapsed % 60))s"

  if [ $drive_status -ne 0 ]; then
    echo "The capture run failed for $profile (exit $drive_status). No review" >&2
    echo "was attempted: a review of a half-finished run would report screens" >&2
    echo "as missing that are only missing because the run died." >&2
    exit 2
  fi

  dart run "$here/review.dart" "$out" "$profile" $accept
  review_status=$?
  # **Only the review's three documented codes are read as a verdict.**
  # Anything else is the review dying, and the old "not 2 means a screen
  # changed" reading is exactly how a `PathNotFoundException` — exit 255 —
  # was reported as ordinary drift on 2026-08-31. A crash gets investigated;
  # drift gets accepted.
  case $review_status in
    0) ;;
    1) overall=1 ;;
    2) exit 2 ;;
    *)
      echo "The review of $profile exited $review_status. Its contract is 0," >&2
      echo "1 or 2, so this is the review crashing rather than a verdict about" >&2
      echo "the images, and it is being reported as a run that could not" >&2
      echo "happen rather than as a screen that changed." >&2
      exit 2
      ;;
  esac
done

elapsed=$(( $(date +%s) - started ))
echo ""
echo "Total: $((elapsed / 60))m $((elapsed % 60))s for ${#wanted[@]} profile(s)."
exit $overall

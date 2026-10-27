#!/usr/bin/env bash
#
# Record the pilot video: one Take on map sweep (`/w-32`).
#
#   integration_test/screenshots/record_video.sh                    # iPhone 6.9
#   integration_test/screenshots/record_video.sh "Claude outputs"   # where the file goes
#
# What it does, in order:
#   1. takes the same lock `regenerate.sh` takes, so a screenshot run and a
#      recording never share the simulator or `build/` at once;
#   2. boots the iPhone 17 Pro Max simulator, opens the Simulator application
#      (a headless simulator draws no frames) and sets its location;
#   3. runs `video_test.dart` under `flutter drive`, which prints VIDEO_START
#      when the Take on map screen is ready and VIDEO_STOP when the sweep has
#      been released and held;
#   4. starts `xcrun simctl io <device> recordVideo` on VIDEO_START and stops it
#      on VIDEO_STOP, so the clip is the sweep and not the app booting;
#   5. plays the recording back four times faster and writes it as a small,
#      muted 60 fps MP4 with `retime_video.swift` (Apple's AVFoundation; there
#      is no ffmpeg on this machine). Michael chose 4x on 2026-10-01: the
#      real-time sweep was too slow to watch.
#
# **This writes a file and commits nothing.** Michael approved the 4x clip on
# 2026-10-01 and `/w-35` committed it as `website/static/videos/take-on-map.mp4`;
# after a re-run, look at the new clip and copy it over that file (the website
# README, "The video"). The poster for readers who do not play
# it is `website/static/screens/iphone-6.9/take-on-map.png`: the clip begins on
# exactly that screen, so the poster is regenerated with every other picture.
#
# **When the screen changes**, run this again. It is the only way the clip is
# made, which is the same rule the pictures live under: a video nobody can
# regenerate rots like a hand-taken screenshot.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2

here="integration_test/screenshots"
staging="build/screenshots"
out_dir="${1:-Claude outputs}"
device="iPhone 17 Pro Max"
SEED_LAT=42.7008
SEED_LON=-117.3612

mkdir -p "$staging" "$out_dir" || exit 2
lockdir="$staging/.regenerate.lock"
if ! mkdir "$lockdir" 2>/dev/null; then
  echo "A screenshot run (or another recording) holds $lockdir; wait for it." >&2
  exit 2
fi
trap 'rm -rf "$lockdir"' EXIT

udid=$(xcrun simctl list devices available | grep -F "$device (" | sed -n 1p \
  | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
if [ -z "$udid" ]; then
  echo "No available simulator called \"$device\"." >&2
  exit 2
fi
xcrun simctl boot "$udid" 2>/dev/null
open -a Simulator
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1
xcrun simctl location "$udid" set "$SEED_LAT,$SEED_LON" 2>/dev/null

raw="$out_dir/take-on-map-raw.mov"
final="$out_dir/take-on-map.mp4"
rm -f "$raw" "$final"
recpid=""
saw_start=""
saw_stop=""

# The driver's own directory is required by driver.dart even though this run
# takes no screenshot.
export TRITRACK_SHOT_DIR="$PWD/$staging/video"
mkdir -p "$TRITRACK_SHOT_DIR"

flutter drive \
  --driver="$here/driver.dart" \
  --target="$here/video_test.dart" \
  -d "$udid" 2>&1 | while IFS= read -r line; do
    echo "$line"
    case "$line" in
      *VIDEO_FAILED*) echo "$line" >&2 ;;
      *VIDEO_START*)
        xcrun simctl io "$udid" recordVideo --codec=h264 --force "$raw" \
          >/dev/null 2>&1 &
        recpid=$!
        ;;
      *VIDEO_STOP*)
        if [ -n "$recpid" ]; then
          kill -INT "$recpid" 2>/dev/null
          wait "$recpid" 2>/dev/null
          recpid=""
        fi
        ;;
    esac
  done
drive_status=${PIPESTATUS[0]}

if [ ! -s "$raw" ]; then
  echo "No recording was written (flutter drive exit $drive_status)." >&2
  exit 2
fi

# Four times faster, a steady 60 frames a second, about 3 Mbit/s: a clip of
# about 4 s and 1.5 MB. The file size is printed so a clip over its 2 MB budget
# is said out loud. The recording has no audio track at all: `simctl io
# recordVideo` does not capture any.
swift "$here/retime_video.swift" "$raw" "$final" 4 60 3000000 >/dev/null 2>&1 || {
  echo "retime_video.swift could not convert $raw; the raw recording is kept." >&2
  exit 2
}
bytes=$(stat -f %z "$final")
echo "Wrote $final ($bytes bytes; budget 2000000)."
exit 0

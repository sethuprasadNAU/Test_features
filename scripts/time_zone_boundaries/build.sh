#!/usr/bin/env bash
# gate-instrument: none - a build tool run by hand when the time-zone boundary data is updated; it downloads and encodes data and checks nothing about the server.
# Rebuild assets/time_zones/boundaries.bin — the offline map of which time zone
# covers each place on Earth, land and sea (task 11.331).
#
# **What it is built from, pinned.** timezone-boundary-builder release 2026d,
# the asset `timezones-with-oceans.geojson.zip` (Evan Siroky,
# https://github.com/evansiroky/timezone-boundary-builder; data under the Open
# Data Commons Open Database License, built from OpenStreetMap). "with oceans"
# because a project area can be at sea: territorial waters belong to the
# neighboring country's zone in this data, and beyond them each 15 degrees of
# longitude is its `Etc/GMT±N` sea zone. **Not the "-1970" or "-now"
# variants**, which merge zones that have kept the same clock since 1970 (or
# from now on): they label the open Pacific south of Hawaii `Pacific/Honolulu`
# and the mid-Atlantic `America/Cayenne`, which would tell a project at sea it
# is on an island's time. Measured by task 11.331's tests before switching. The
# archive's SHA-256 is checked below, so a changed release cannot slip in under
# the same name.
#
# **What is done to it.** mapshaper (pinned below, run through npx in a scratch
# directory, never added to the app) simplifies every boundary so that no edge
# moves more than 100 m, keeping shared edges shared so no gap or overlap
# appears between neighbors; `encode.py` then writes the compact binary. At
# 2026d that is about 4.0 MB in the app. The cost of 100 m: a project whose
# center is within about 100 m of a zone line may be offered the neighbor's
# zone — which is why the creator confirms the zone and can change it.
#
# **Updating.** Change RELEASE and SHA256 together (the release notes say which
# zones moved), run this from the repository root, run
# `flutter test test/core/time/`, and say in the commit which release it is. The
# zone names must all be known to the `timezone` package's tz database, which
# the tests check; if a new release names a zone the pinned package does not
# know, update that pin first (Security Model §3.8).
#
# Usage: scripts/time_zone_boundaries/build.sh [work-dir]
set -euo pipefail

RELEASE=2026d
ASSET=timezones-with-oceans.geojson.zip
SHA256=e391c92c7b90339c3afe8558082b4532b8d9afc9daad68da31f4569a1ca61034
MAPSHAPER=mapshaper@0.6.102
SIMPLIFY_METERS=100

repo=$(cd "$(dirname "$0")/../.." && pwd)
work=${1:-$(mktemp -d)}
mkdir -p "$work/download" "$work/tools"

archive="$work/download/$ASSET"
if [ ! -f "$archive" ]; then
  curl -sSL -o "$archive" \
    "https://github.com/evansiroky/timezone-boundary-builder/releases/download/$RELEASE/$ASSET"
fi
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
if [ "$actual" != "$SHA256" ]; then
  echo "The downloaded $ASSET does not match the pinned SHA-256." >&2
  echo "  expected $SHA256" >&2
  echo "  got      $actual" >&2
  exit 1
fi
unzip -o -q "$archive" -d "$work/download"
jsons=("$work/download"/*.json)
geojson=${jsons[0]}

(cd "$work/tools" && npm init -y >/dev/null && npm install --silent "$MAPSHAPER")
"$work/tools/node_modules/.bin/mapshaper-xl" 8gb "$geojson" \
  -simplify interval=$SIMPLIFY_METERS keep-shapes \
  -o "$work/simplified.json" precision=0.0001 format=geojson
# mapshaper-xl can print an error from the process it starts and still exit 0,
# so the file is the evidence, not the exit status.
if [ ! -s "$work/simplified.json" ]; then
  echo "mapshaper wrote no simplified boundaries; see its output above." >&2
  exit 1
fi

python3 -I "$repo/scripts/time_zone_boundaries/encode.py" \
  "$work/simplified.json" "$repo/assets/time_zones/boundaries.bin"
ls -l "$repo/assets/time_zones/boundaries.bin"

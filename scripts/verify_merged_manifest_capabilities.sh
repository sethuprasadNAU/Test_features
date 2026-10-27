#!/usr/bin/env bash
# gate-instrument: none - run by .github/workflows/build-check.yml, the only place the merged Android manifest exists.
# Task 11.76 — the capability guard, extended to what Gradle actually merges in.
# Task 11.121 — extended again: exported components, not a hand-typed element
# list.
#
# `test/platform/capability_matrix_test.dart` (task 11.40) parses only the
# three hand-written Android manifests under `android/app/src/*/`. Gradle
# merges every plugin's own library manifest into the app's before
# packaging, so the manifest Android actually enforces contains components
# nobody in this repository typed — task 11.66 found seven such additions by
# hand, from a permission implied by aapt itself to a whole
# declared-but-never-started foreground-service class. None of them are
# visible to a check that reads only what a person wrote.
#
# 11.76 checked two shapes — `<uses-permission>` and `<uses-feature>` —
# because those were what 11.66's worked example happened to use.
# `CAPABILITY_MATRIX.md` also records `<queries>`, `<service>`, `<activity>`
# and an exported `<receiver>` by hand, found the same way: someone read the
# merged manifest and typed rows for what they saw. A plugin adding a new
# exported component would merge into the built APK and nothing here would
# say so, because nothing checked for it.
#
# The six element shapes are not equally interesting, and one attribute is
# what makes any of them matter: `android:exported`. A `<uses-library>` is
# inert. An exported `<activity>`, `<service>`, `<receiver>` or `<provider>`
# is a component any other app on the phone can invoke — an attack surface
# that arrives without anybody choosing to add it. So this does not enumerate
# element names; it asks the one question that actually matters: did
# anything become reachable from outside this app? Every element that can
# carry `android:exported="true"` is checked, regardless of its tag name.
#
# `<queries>` is not an attack surface — it does not make anything in this
# app reachable from outside — but it *is* a disclosure: it declares what
# other apps this one can detect. That is worth a row too, so it is still
# checked, just under its own name rather than folded into "exported".
#
# This reads a *build artifact*, not source, so it cannot run inside
# `flutter test` — the offline suite (task 11.40) has no server, no Docker
# and no Android build either. It runs here instead, in build-check.yml's
# Android job, right after `flutter build apk --debug` produces the merged
# manifest.
#
# Usage: scripts/verify_merged_manifest_capabilities.sh [path-to-merged-manifest]
set -euo pipefail

manifest_path="${1:-build/app/intermediates/merged_manifest/debug/processDebugMainManifest/AndroidManifest.xml}"
matrix_path="CLAUDE_DOCS/CAPABILITY_MATRIX.md"

if [[ ! -f "$manifest_path" ]]; then
  echo "FAIL: $manifest_path does not exist." >&2
  echo "This reads the manifest Gradle merges during a build, not a" >&2
  echo "hand-written source file. Run 'flutter build apk --debug' first, or" >&2
  echo "pass the merged manifest's path as \$1 if Gradle's output layout has" >&2
  echo "moved." >&2
  exit 1
fi

if [[ ! -f "$matrix_path" ]]; then
  echo "FAIL: $matrix_path is missing. It is the enumeration this script" >&2
  echo "checks against." >&2
  exit 1
fi

matrix_text="$(cat "$matrix_path")"
missing=0

report_missing() {
  local kind="$1" name="$2"
  echo "FAIL: the merged manifest declares $kind \"$name\" and $matrix_path has no row mentioning it." >&2
  echo "" >&2
  echo "Gradle merged this in from a plugin, not from anything a person" >&2
  echo "typed in this repository — the exact direction task 11.66 found" >&2
  echo "seven instances of by hand. Add a row to $matrix_path stating what" >&2
  echo "it is, why it is there, and whether it needs a hardware test." >&2
  missing=1
}

# The matrix names the short form a person reads (ACCESS_FINE_LOCATION), the
# same convention test/platform/capability_matrix_test.dart uses for the
# hand-written manifests — so a fully-qualified custom permission like
# edu.nau.tritrack.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION is checked by its
# last segment too, and matches because the matrix quotes the full name.
permissions="$(grep -oE '<uses-permission[^>]*android:name="[^"]+"' "$manifest_path" \
  | sed -E 's/.*android:name="([^"]+)".*/\1/' | sed -E 's/.*\.//' | sort -u || true)"

# Feature requirements are matched on the full dotted name, since that is how
# the matrix quotes them (e.g. "uses-feature android.hardware.location").
features="$(grep -oE '<uses-feature[^>]*android:name="[^"]+"' "$manifest_path" \
  | sed -E 's/.*android:name="([^"]+)".*/\1/' | sort -u || true)"

if [[ -z "$permissions" ]]; then
  echo "FAIL: no <uses-permission> parsed out of $manifest_path at all." >&2
  echo "Either the merged manifest genuinely declares none, which would mean" >&2
  echo "the app lost network access, or this pattern no longer matches the" >&2
  echo "file. A derivation that silently matches nothing reports full" >&2
  echo "coverage of nothing." >&2
  exit 1
fi

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if ! grep -qF -- "$name" <<<"$matrix_text"; then
    report_missing "permission" "$name"
  fi
done <<<"$permissions"

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if ! grep -qF -- "$name" <<<"$matrix_text"; then
    report_missing "uses-feature" "$name"
  fi
done <<<"$features"

# Exported components: parsed with a real XML parser, not a regex, because
# the merged manifest lays each attribute on its own line — the shape that
# made the old permission/feature regexes safe to write (one attribute,
# always on the element's own line) does not hold here. Every element that
# can carry `android:exported` is checked, by its short (last-segment) name,
# the same convention the matrix already uses for permissions.
exported_names="$(python3 - "$manifest_path" <<'PY'
import sys
import xml.etree.ElementTree as ET

ns = "{http://schemas.android.com/apk/res/android}"
tree = ET.parse(sys.argv[1])
for el in tree.getroot().iter():
    if el.get(f"{ns}exported") == "true":
        name = el.get(f"{ns}name")
        if name:
            print(name.rsplit(".", 1)[-1])
PY
)"

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if ! grep -qF -- "$name" <<<"$matrix_text"; then
    report_missing "exported component" "$name"
  fi
done <<<"$exported_names"

# <queries> entries are not reachable-from-outside surface, but they are a
# disclosure — they declare what other apps this one can see — so a plugin
# adding one still gets a row, under its own report_missing kind rather than
# "exported component".
queries_names="$(python3 - "$manifest_path" <<'PY'
import sys
import xml.etree.ElementTree as ET

ns = "{http://schemas.android.com/apk/res/android}"
tree = ET.parse(sys.argv[1])
queries = tree.getroot().find("queries")
if queries is not None:
    for el in queries.iter():
        tag = el.tag
        if tag == "action" or tag == "package":
            name = el.get(f"{ns}name")
        elif tag == "provider":
            name = el.get(f"{ns}authorities")
        else:
            name = None
        if name:
            print(name.rsplit(".", 1)[-1])
PY
)"

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if ! grep -qF -- "$name" <<<"$matrix_text"; then
    report_missing "queries entry" "$name"
  fi
done <<<"$queries_names"

if [[ "$missing" -eq 1 ]]; then
  exit 1
fi

echo "PASS: every <uses-permission>, <uses-feature>, exported component and <queries> entry in $manifest_path has a row in $matrix_path."

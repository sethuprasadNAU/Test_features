#!/usr/bin/env bash
# Does the drift check still fail when it should?
#
# check_app_quotes.dart is the only thing standing between the website and
# this project's most-repeated defect — copy describing something the code
# stopped doing. A check nobody has watched fail is not a check, and a check
# watched failing once, by hand, in August, is not a check in December either.
#
# So each case below drives the checker at a fixture and asserts the exit
# code. Exit codes are the contract: 0 no drift, 1 drift or a rule violation,
# 2 the check could not run — which is not the same as passing.
#
# Run: website/tools/selftest.sh          (from the repository root)

set -u
cd "$(dirname "$0")/../.." || exit 2

REPO="$PWD"
CHECK="website/tools/check_app_quotes.dart"
FIX="website/tools/fixtures"
APPLIB="$FIX/applib"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
want_red=0
want_cannot_run=0

# expect <exit> <name> -- <args...>
expect() {
  local want="$1" name="$2"; shift 3
  local out rc
  [ "$want" = 1 ] && want_red=$((want_red + 1))
  [ "$want" = 2 ] && want_cannot_run=$((want_cannot_run + 1))
  out="$(dart run "$CHECK" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name: wanted exit $want, got $rc"
    echo "$out" | sed 's/^/      /'
  fi
}

# expect_in <dir> <exit> <name> -- <args...>
#
# The same, run from somewhere else. The default roots — `lib/` and every
# `packages/*/lib/` — are resolved against the working directory, so the only
# way to test what they resolve *to* is to run the checker in a tree built for
# the purpose. Asserting the defaults by naming them with --app-root would be
# a test of the argument parser, not of the discovery.
expect_in() {
  local dir="$1" want="$2" name="$3"; shift 4
  local out rc
  [ "$want" = 1 ] && want_red=$((want_red + 1))
  [ "$want" = 2 ] && want_cannot_run=$((want_cannot_run + 1))
  out="$(cd "$dir" && dart run "$REPO/$CHECK" "$@" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name: wanted exit $want, got $rc"
    echo "$out" | sed 's/^/      /'
  fi
}

no_waivers="$TMP/none.txt"; : > "$no_waivers"

# --- The check passes when the site and the app agree. ------------------
expect 0 "clean page matches the app" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_clean" --waivers="$no_waivers"

# --- Rule 1: a quoted string the app no longer contains. ----------------
expect 1 "quoted string absent from the app is drift" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_drift" --waivers="$no_waivers"

# The real drift shape: the app's wording changes, the page does not.
cp -R "$APPLIB" "$TMP/drifted"
sed -i.bak "s/Join a project/Join a shared project/g" "$TMP/drifted/strings.dart"
expect 1 "the app renaming a label turns the page red" -- \
  --app-root="$TMP/drifted" --content-root="$FIX/content_clean" --waivers="$no_waivers"

# --- Rule 2: quotation marks in prose, unmarked. ------------------------
expect 1 "quoting the app without the shortcode is refused" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_rawquote" --waivers="$no_waivers"

# --- Rule 3: bold in prose. ---------------------------------------------
expect 1 "a bold UI label without the shortcode is refused" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_bold" --waivers="$no_waivers"

# --- Rule 4: a quote that could never go red (/w-08). --------------------
#
# Three cases, and the second and third are the ones that make the first
# meaningful. Refusing every string inside an `enum` would be easy and wrong:
# `GroundTruthKind.animalOnly` is `('animal_only', 'Animal only')`, and the
# second of those is exactly what the record screen shows a person.
expect 1 "quoting an enum's stored database value is refused" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_enumvalue" --waivers="$no_waivers"

expect 0 "a screen label declared inside the same enum is still quotable" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_enumlabel" --waivers="$no_waivers"

expect 1 "a stored value declared second is refused too, so the position is read not assumed" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_enumreversed" --waivers="$no_waivers"

# And rule 4 must not be inert: an app root with no stored values at all is a
# root where the rule cannot refuse anything, which is a check reporting
# success from a position it cannot fail in.
NOENUM="$TMP/noenum"
mkdir -p "$NOENUM"
printf "const a = 'Join a project';\n" > "$NOENUM/app.dart"
expect 2 "an app root with no enum storage values is a failure, not a pass" -- \
  --app-root="$NOENUM" --content-root="$FIX/content_clean" --waivers="$no_waivers"

# --- Code spans and fences are not prose. -------------------------------
expect 0 "quotes inside code fences and inline code are left alone" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_codeok" --waivers="$no_waivers"

# --- The waiver list. ----------------------------------------------------
w="$TMP/w.txt"
printf 'Join a project\tnot the app speaking, this is a self-test\n' > "$w"
expect 0 "a waiver with a reason silences rule 2" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_rawquote" --waivers="$w"

printf 'Nothing uses this\ta reason\n' >> "$w"
expect 1 "a waiver that matches nothing is an error" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_rawquote" --waivers="$w"

printf 'Join a project\tone reason\nJoin a project\tanother reason\n' > "$w"
expect 2 "the same waiver written twice is a hard error, not last-write-wins" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_rawquote" --waivers="$w"

printf 'Join a project\t\n' > "$w"
expect 2 "a waiver with no reason will not load" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_rawquote" --waivers="$w"

printf 'Join a project no tab here\n' > "$w"
expect 2 "a waiver line with no tab will not load" -- \
  --app-root="$APPLIB" --content-root="$FIX/content_rawquote" --waivers="$w"

# --- The check must not pass by finding nothing to check. ---------------
expect 2 "an app directory with no Dart in it is a failure, not a pass" -- \
  --app-root="$FIX/emptylib" --content-root="$FIX/content_clean" --waivers="$no_waivers"

expect 2 "a missing app directory is a failure, not a pass" -- \
  --app-root="$FIX/does-not-exist" --content-root="$FIX/content_clean" --waivers="$no_waivers"

expect 2 "a missing content directory is a failure, not a pass" -- \
  --app-root="$APPLIB" --content-root="$FIX/does-not-exist" --waivers="$no_waivers"

# --- The roots: lib/ is not the whole app (/w-06). -----------------------
#
# The role names a member reads and the record-type buttons on the record
# screen are enum labels in `packages/tritrack_sync/lib/`, so a check that
# searched `lib/` alone was blind to the words in the guide's most-read table.
# These four cases are about the *discovery*, not the parser: a tree is built
# with a string in each root and the checker is run from inside it.
DEMO="$TMP/roots"
mkdir -p "$DEMO/lib" "$DEMO/packages/demo_sync/lib" "$DEMO/content"
# The enum is here because rule 4 refuses to run against an app root with no
# stored values at all — see the case above. It is in `lib/` rather than in the
# package so that the last case below, which deletes `packages/` entirely,
# still has one.
printf "const a = 'Sync now';\nenum E { a('a'); const E(this.db); final String db; }\n" \
  > "$DEMO/lib/app.dart"
printf "const b = 'No Signal';\n" > "$DEMO/packages/demo_sync/lib/enums.dart"
printf 'Tap {{< app "Sync now" >}} then {{< app "No Signal" >}}.\n' \
  > "$DEMO/content/page.md"

expect_in "$DEMO" 0 "the default roots include every packages/*/lib" -- \
  --content-root=content --waivers="$no_waivers"

expect 0 "--app-root may be given more than once" -- \
  --app-root="$DEMO/lib" --app-root="$DEMO/packages/demo_sync/lib" \
  --content-root="$DEMO/content" --waivers="$no_waivers"

# A packages/ directory whose packages have no lib/ would leave the check
# searching one root while its own documentation claims two. That is a check
# quietly covering less than it says, which is refused rather than skipped.
mv "$DEMO/packages/demo_sync/lib" "$DEMO/packages/demo_sync/src"
expect_in "$DEMO" 2 "packages/ with no package lib/ is a failure, not a pass" -- \
  --content-root=content --waivers="$no_waivers"

# And with packages/ gone entirely the same page must go red — which is what
# proves the case above passed *because* of the packages root and not for some
# other reason.
rm -rf "$DEMO/packages"
expect_in "$DEMO" 1 "without packages/ the enum label is drift" -- \
  --content-root=content --waivers="$no_waivers"

# --- The built-site check (`/w-35` item 3): links and raw TeX. ----------
#
# check_built_site.dart reads a site Hugo has already built. Each fixture is a
# two-page site with one thing broken, so every red below is for its own
# reason; the clean one proves the reds are not the checker failing on
# everything.
SITE_CHECK="website/tools/check_built_site.dart"
SITE_FIX="$FIX/built_site"
# expect_site <exit> <name> <dir>
expect_site() {
  local want="$1" name="$2" dir="$3" out rc
  [ "$want" = 1 ] && want_red=$((want_red + 1))
  [ "$want" = 2 ] && want_cannot_run=$((want_cannot_run + 1))
  out="$(dart run "$SITE_CHECK" --base-path=/tritrack-site/ "$dir" 2>&1)"; rc=$?
  if [ "$rc" = "$want" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "  ✗ $name: wanted exit $want, got $rc"
    echo "$out" | sed 's/^/      /'
  fi
}
expect_site 0 "a built site whose links all resolve passes" "${SITE_FIX}_clean"
expect_site 1 "a link to a page the build did not produce is red" "${SITE_FIX}_broken_link"
expect_site 1 "a link to a heading the page does not have is red" "${SITE_FIX}_broken_fragment"
expect_site 1 "TeX printed as text outside a formula is red" "${SITE_FIX}_raw_tex"
expect_site 2 "a site with no internal link at all cannot be checked" "${SITE_FIX}_no_links"
expect_site 2 "a directory that is not there cannot be checked" "$TMP/no-such-site"

# The last line is the finding, not the name of the check: CI keeps only the
# tail of a log, and a name in the tail has never told anybody anything.
if [ "$fail" -gt 0 ]; then
  echo "selftest: FAIL — $fail of $((pass + fail)) cases did not behave as stated above; the drift check is not trustworthy until they do."
  exit 1
fi
echo "selftest: PASS — all $pass cases behaved as specified, including $want_red that must go red on a violation and $want_cannot_run that must refuse to run rather than report success."

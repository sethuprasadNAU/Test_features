#!/usr/bin/env bash
# gate-instrument: none - a pre-commit guard that regenerates build_runner
# output and refuses the commit if a tracked .g.dart/.freezed.dart file
# changes.
#
# Task 11.309. A task edits a doc comment or annotation on a source file and
# does not run build_runner, so the generated file beside it keeps the old
# text. Nothing fails. The next task to run the generator finds a diff it
# did not make, and has to decide by hand whether to carry somebody else's
# change or revert it. That happened twice in two days: task 11.305
# (2026-09-21) and task 11.307 (2026-09-22), each of which reverted the
# drift and said so.
#
# **Why this forces a CLEAN build_runner run rather than an incremental
# one.** Measured while building this guard: an incremental run, against a
# pre-existing .dart_tool/build cache, reported "0 outputs" — it considered
# every file current — while two tracked .g.dart files were in fact stale
# against their sources (the exact drift this guard exists to catch). The
# incremental cache tracks input digests since its own last run; it does not
# re-verify that what is currently on disk matches what it last wrote, so a
# working tree that was checked out, stashed, or branch-switched without the
# cache along for the ride can go stale in a way the cache never notices.
# Deleting .dart_tool/build before every run costs real time (measured at
# 25-30 s typically, once as high as 104 s on this machine) but is the only
# form of this check that is actually a check.
#
# **Task 11.318 item 3: it also runs in CI, unchanged** (`offline-suite.yml`, the step
# "Generated files are current"). A guard that lives only in a hook protects one
# machine's commits and nobody else's. **In CI nothing is staged, and nothing needs to
# be:** a clean checkout's index IS the commit's content, so `before_sums` below reads
# the generated files as committed and `after_sums` reads what build_runner then writes
# over them. What CI compares is therefore *the committed generated files against
# build_runner's output from the committed sources* — the same question, with no step
# between the file and the commit. One script rather than a CI copy of it: a second
# implementation would be a second answer to the same question.
#
# Called from scripts/pre_commit_suite.sh, and only when the commit touches
# lib/ — see that file for the gate. Not run unconditionally: most commits
# in this repo (CLAUDE_DOCS/, .claude/commands/) cannot produce this drift,
# and a guard that costs 25-100 s on every commit regardless of relevance is
# a guard that invites the escape hatch.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# **Task 11.312 item 8: the STAGED content, not disk before — disk before was
# comparing the wrong thing.** Task 11.313 (`f89ba3e`) committed a stale
# `app_router.g.dart` and this guard let it through: `app_router.g.dart` on
# disk had already been regenerated (matching the new source) but was never
# re-staged, so `git ls-files | xargs shasum` — reading the WORKING TREE —
# hashed the same, already-correct content both before and after
# build_runner ran. The guard agreed with disk while the commit, built from
# the INDEX, still carried the old file. Reproduced 2026-09-27 (task
# 11.312): a provider added, regenerated on disk, only the source staged —
# the old two-disk-snapshots version of this guard passed.
#
# So `before_sums` reads what `git commit` would actually write — the INDEX
# (`git show :path`), not the working tree — and `after_sums` still reads
# disk, now holding what build_runner says the source demands. A mismatch
# means the two disagree about what should be committed, which is the
# question this guard exists to ask. A generated file with no staged content
# at all (a brand-new one nobody `git add`ed yet) hashes as empty, which
# still disagrees with build_runner's fresh output the same way a stale one
# does.
# **Task 11.325 item 3: a commit that names its paths takes the WORKING TREE
# content of those paths and ignores the index.** `git commit -- <path>` is the
# form `CLAUDE.md` requires, and for a generated file named that way the index
# holds the old text while the file on disk holds what will be committed — so
# reading the index would call a correctly regenerated file stale. The hook lists
# such files in `GENERATED_FILES_WORKTREE_PATHS` (newline-separated); for those,
# disk is what "as committed" means. Every other file keeps the index, as above.
staged_sums() {
  git ls-files -- '*.g.dart' '*.freezed.dart' | while IFS= read -r f; do
    if grep -qxF -- "$f" <<<"${GENERATED_FILES_WORKTREE_PATHS:-}"; then
      hash="$(shasum <"$f" | cut -d' ' -f1)"
    else
      hash="$(git show ":$f" 2>/dev/null | shasum | cut -d' ' -f1)"
    fi
    printf '%s  %s\n' "${hash:-<not staged>}" "$f"
  done
}

before_sums="$(staged_sums)"

# **A guard against scanning nothing (defect vocabulary 76).** With no tracked
# generated file, `before_sums` and `after_sums` are both empty and equal, and this
# script would report "current" having compared nothing — which is what a changed
# glob, or a checkout missing the files, would look like from the inside.
if [[ -z "$before_sums" ]]; then
  echo "generated-files check: git lists no tracked .g.dart or .freezed.dart" \
       "files at all, so there is nothing to compare and nothing is current." \
       "This is the check being wrong about where the files are, not a" \
       "repository with none." >&2
  exit 2
fi

rm -rf .dart_tool/build

build_log="$(mktemp "${TMPDIR:-/tmp}/tritrack-buildrunner.XXXXXX")"
if ! dart run build_runner build --delete-conflicting-outputs >"$build_log" 2>&1; then
  echo "generated-files check: build_runner itself failed. Output:" >&2
  sed 's/^/  /' "$build_log" >&2
  rm -f "$build_log"
  exit 2
fi
rm -f "$build_log"

after_sums="$(git ls-files -- '*.g.dart' '*.freezed.dart' | xargs shasum)"

if [[ "$before_sums" != "$after_sums" ]]; then
  changed="$(diff <(echo "$before_sums") <(echo "$after_sums") | grep -oE '[^[:space:]]+\.(g|freezed)\.dart' | sort -u)"
  echo "generated-files check: what is STAGED for these tracked generated" \
       "files does not match what build_runner says the source demands —" \
       "(in CI, 'staged' means 'as committed')" >&2
  sed 's/^/  /' <<<"$changed" >&2
  echo "Someone edited an annotated source (a doc comment, a provider" \
       "signature) and either did not regenerate, or regenerated without" \
       "re-staging the result. Run:" >&2
  echo "  dart run build_runner build --delete-conflicting-outputs" >&2
  echo "review the diff, and 'git add' the regenerated files with your" \
       "change before committing." >&2
  exit 1
fi

exit 0

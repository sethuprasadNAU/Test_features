#!/usr/bin/env bash
# gate-instrument: none - the local replacement for GitHub's paused checks. It starts the real gate and drills on the Ubuntu VM and the Mac's own suites; it makes no request of its own and asserts nothing about the server.
#
# **One command for the whole night, run from the Mac: `scripts/nightly_check.sh`.**
# Task 11.325. Michael (2026-10-03): "I just don't want to be copying terminal
# outputs back and forth." GitHub's checks are paused while the code changes many
# times a day, so this runs every one of them on his own machines and leaves ONE
# file for the planning session to read in the morning:
#
#     Claude outputs/local-ci/<date-time>/report.md
#
# It has three phases, and it never stops at a failure:
#
#   1. PREFLIGHT, under two minutes, while he is still awake. It checks everything
#      that would waste the night and says in plain words what to fix, then stops
#      -- or says "all clear, go to bed" and carries straight on.
#   2. THE VM HALF, through Parallels (`prlctl exec`; SSH is the fallback): the
#      same commit as the Mac (fetched from the Mac's repository through the
#      Parallels shared folder, so nothing is pushed to GitHub); stop the real
#      server; the backup image built from nothing (no cache); the gate; the
#      gate's self-test (can its instruments still fail?); the drill stack; all
#      four broken-control drills; tear the stack down; the server's own test
#      suite; put the real server back.
#   3. THE MAC HALF: analyze, the full suite, the sync package's tests, the
#      generated-files check, the clock matrix, the website checks (its tools,
#      the quote check, the theory figures, the Hugo build), the three
#      platform builds (none of them signed), the tile-credit check. (The
#      server's test suite runs in the VM half; it only runs here if the VM half
#      was skipped and Docker is up.)
#
# Sequential, never parallel: the VM shares the Mac's processors, and the gate has
# timing checks that a busy machine can fail.
#
# ## Keeping the Mac awake
#
# The first thing this does is `caffeinate -dims -w $$`: tied to this script's own
# process, so the Mac stays awake exactly as long as the script runs and is allowed
# to sleep the moment it finishes, fails or is stopped with Ctrl-C. No separate tab,
# nothing to turn off. **It cannot keep a closed lid awake**: a MacBook sleeps when
# its lid closes whatever any program asks for, so the lid stays open and the
# preflight says so every time.
#
# ## Usage
#
#   scripts/nightly_check.sh                 the whole night
#   scripts/nightly_check.sh --preflight-only   the checks while you are awake; nothing runs
#   scripts/nightly_check.sh --force         carry on past preflight problems (you read them)
#   scripts/nightly_check.sh --skip-vm       the Mac half only
#   scripts/nightly_check.sh --skip-mac      the VM half only
#   scripts/nightly_check.sh --only=mac-clock,vm-gate   just those steps, by id (the ids are in the report)
#   scripts/nightly_check.sh --self-test     show that a FAIL is reported and the run carries on
#   scripts/nightly_check.sh --setup         print the one-time setup, one step at a time
#   scripts/nightly_check.sh --vm-no-sleep   setup step 1: tell the VM never to suspend itself when idle
#   scripts/nightly_check.sh --vm-install-dart   setup step 2: put the Dart SDK (the Mac's version) in the VM user's home
#   scripts/nightly_check.sh --vm-clean      free the VM's disk the way the night does at its end: remove the images the gate and drills built, and Docker's build cache (never the real server's images or volumes)
#
# Exit status: 0 every step passed or was skipped on purpose; 1 at least one step
# failed (the report says which); 2 the preflight stopped it; 130 stopped by hand.
#
# ## One-time setup (also printed by `--setup`)
#
# With the default transport (`prlctl`) there is no SSH server, key or address to
# set up. Nothing in the night needs `sudo`. See `setup_text` below.
#
# ## Where things are configured
#
# Defaults describe Michael's machines; each can be overridden from the environment.
#   NIGHTLY_VM_TRANSPORT  prlctl (default) | ssh. `prlctl` runs commands in the VM
#                         through Parallels Tools: no SSH server, no key and no
#                         address to keep (Michael chose it, 2026-10-04). `ssh` is
#                         the fallback for a machine without Parallels Tools; it
#                         needs an SSH server on the VM, a key, and a Host entry
#                         named NIGHTLY_VM_HOST in ~/.ssh/config.
#   NIGHTLY_VM_HOST       the SSH name, for the ssh transport only (default tritrack-vm)
#   NIGHTLY_VM_NAME       the Parallels VM's name, for prlctl
#   NIGHTLY_VM_USER       the VM's user (default parallels)
#   NIGHTLY_VM_REPO       the VM's own checkout (default /home/parallels/repos/tritrack)
#   NIGHTLY_VM_SHARED_REPO  this repository as the VM sees it through the shared
#                         folder (default /media/psf/tritrack)
#
# Bash 3.2-compatible on purpose: that is what macOS ships.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

PREFLIGHT_ONLY=0; SKIP_VM=0; SKIP_MAC=0; FORCE=0; SELF_TEST=0; SHOW_SETUP=0; NO_SLEEP=0; INSTALL_DART=0; VM_CLEAN=0; ONLY=""
for arg in "$@"; do
  case "$arg" in
    --only=*) ONLY="${arg#--only=}" ;;
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    --skip-vm) SKIP_VM=1 ;;
    --skip-mac) SKIP_MAC=1 ;;
    --force) FORCE=1 ;;
    --self-test) SELF_TEST=1 ;;
    --setup) SHOW_SETUP=1 ;;
    --vm-no-sleep) NO_SLEEP=1 ;;
    --vm-install-dart) INSTALL_DART=1 ;;
    --vm-clean) VM_CLEAN=1 ;;
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//' | grep -v '^set -uo' ; exit 0 ;;
    *) echo "nightly_check: unknown option $arg (try --help)" >&2; exit 64 ;;
  esac
done

VM_TRANSPORT="${NIGHTLY_VM_TRANSPORT:-prlctl}"
case "$VM_TRANSPORT" in ssh|prlctl) ;; *) echo "nightly_check: NIGHTLY_VM_TRANSPORT must be prlctl or ssh, not '$VM_TRANSPORT'" >&2; exit 64 ;; esac
VM_HOST="${NIGHTLY_VM_HOST:-tritrack-vm}"
VM_NAME="${NIGHTLY_VM_NAME:-Ubuntu 24.04.3 ARM64}"
VM_USER="${NIGHTLY_VM_USER:-parallels}"
VM_REPO="${NIGHTLY_VM_REPO:-/home/parallels/repos/tritrack}"
VM_SHARED="${NIGHTLY_VM_SHARED_REPO:-/media/psf/tritrack}"
# The Dart SDK for the server suite. A path as the VM's shell will read it ($HOME is the VM user's).
VM_DART_DIR='$HOME/dart-sdk'

# Thresholds, in gigabytes. The VM is small (its disk was 91% full on 2026-10-02)
# and a gate build writes images; the Mac builds three platforms.
VM_DISK_STOP=4;  VM_DISK_WARN=8
MAC_DISK_STOP=15; MAC_DISK_WARN=30
# Hours the night may take, for "does the signing permission outlast it".
NIGHT_HOURS=10

STAMP="$(date +%Y-%m-%d_%H%M%S)"
RUN_DIR="$repo_root/Claude outputs/local-ci/$STAMP"
LOG_DIR="$RUN_DIR/logs"
REPORT="$RUN_DIR/report.md"

setup_text() {
  cat <<EOF
One-time setup for the nightly check. The Mac reaches the VM through Parallels itself
(prlctl), so there is no SSH server, key or address to set up. Do these in order; each is
one command or one click, and none of this is needed again.

  Step 1 -- stop the VM putting itself to sleep when idle. Overnight work started from the
  Mac does not count as activity to the VM's desktop, so it would suspend mid-night. In a
  terminal on the Mac, in this repository, run (it changes that one VM setting, nothing else):
      scripts/nightly_check.sh --vm-no-sleep
    It prints the setting back so you can see it took.

  Step 2 -- put the Dart language on the VM. The server's own tests run there and need it
  (the VM had none). This downloads the same version your Mac uses into the VM user's home
  folder; it needs no sudo and changes none of the VM's settings or files outside that folder:
      scripts/nightly_check.sh --vm-install-dart

  Step 3 -- free some room on the VM (its disk was 91% full on 2026-10-02). On the Mac:
      prlctl exec "$VM_NAME" docker image prune -f
      prlctl exec "$VM_NAME" docker builder prune -f
    Those two remove only unused leftovers and rebuild what they need. **Do not** run
    'docker volume prune', 'docker system prune --volumes' or 'docker compose down -v' on
    the real server: those delete its database.

  Step 4 -- the Xcode project file has edits that are not yours to lose or ours to commit
  (ios/Runner.xcodeproj/project.pbxproj). Open the project in Xcode, check that the change
  is one you want, and commit it -- or discard it with
      git checkout -- ios/Runner.xcodeproj/project.pbxproj
  The check warns about it every night until one of those is done.

  Step 5 -- plug the Mac in, then renew Xcode's signing permission so the Mac app opens
  from Xcode again: open ios/Runner.xcworkspace, click Runner, Signing & Capabilities, and
  let it renew (or plug the phone in and run the app once). A free team's permission lasts
  7 days. The night's own builds do not need it, so an expired one only warns.

  Step 6 -- check everything while you are awake, with nothing started; repeat until it says
  "All clear":
      scripts/nightly_check.sh --preflight-only
    Leave the Parallels window for the VM open and the VM running overnight; this VM is
    set to suspend when its window is closed.

  Step 7 -- the first night: start it before bed, with the lid OPEN (closing a MacBook's
  lid puts it to sleep whatever the script asks for):
      scripts/nightly_check.sh
    and give the planning session  Claude outputs/local-ci/<latest>/report.md  in the morning.

  If this machine has no Parallels Tools, or you would rather use SSH, set
  NIGHTLY_VM_TRANSPORT=ssh and make an entry named \$NIGHTLY_VM_HOST (default tritrack-vm)
  in ~/.ssh/config that logs in to the VM with a key and no password.
EOF
}

if [ "$SHOW_SETUP" -eq 1 ]; then setup_text; exit 0; fi

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
STEP_WHERE=(); STEP_ID=(); STEP_LABEL=(); STEP_STATUS=(); STEP_SECS=(); STEP_LOG=(); STEP_NOTE=()
PLAN_WHERE=(); PLAN_ID=(); PLAN_LABEL=(); PLAN_TMO=(); PLAN_W=(); PLAN_CMD=(); PLAN_NOTE_RE=(); PLAN_COND=()
PREFLIGHT_LINES=(); PROBLEMS=(); WARNINGS=()
TOTAL_W=0; DONE_W=0; N_DONE=0; N_TOTAL=0
START_EPOCH="$(date +%s)"; START_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"
END_HUMAN=""; RUN_STATE="running"
CAFFEINATE_PID=""; AWAKE_NOTE="not started"
MAC_SHA=""; MAC_SUBJECT=""; MAC_BRANCH=""; MAC_DIRTY_COUNT=0; MAC_DIRTY_LIST=""
TOOLCHAIN_NOTE=""
VM_ORIG_REF=""; VM_REAL_CONTAINERS=""; VM_PREPARED=0; VM_RESTORED=0; VM_CLEANED=0; VM_DISK_START_KB=""; VM_DISK_NOTE=""
CURRENT_PID=""; FINISHING=0; LOCK_DIR=""
CUR_WHERE=""; CUR_ID=""; CUR_LABEL=""; CUR_LOG=""; CUR_T0=0
TREE_HASH_BEFORE=""

say() { printf '%s\n' "$*"; }
fmt_dur() {
  local s="$1"
  if [ "$s" -ge 3600 ]; then printf '%dh %02dm' $((s/3600)) $((s%3600/60))
  elif [ "$s" -ge 60 ]; then printf '%dm %02ds' $((s/60)) $((s%60))
  else printf '%ds' "$s"; fi
}

# ---------------------------------------------------------------------------
# The VM, by one function, so the transport is one decision and not forty.
# The command travels base64-encoded: it contains quotes, $( ) and newlines, and
# three layers of shell (ssh or prlctl, the remote login shell, our own) would each
# eat some.
# ---------------------------------------------------------------------------
VM_ARGV=()
vm_argv() {
  local b64
  b64="$(printf '%s' "$1" | base64 | tr -d '\n')"
  case "$VM_TRANSPORT" in
    ssh)
      VM_ARGV=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30
               -o ServerAliveCountMax=20 "$VM_HOST"
               "bash -lc \"\$(echo $b64 | base64 -d)\"") ;;
    prlctl)
      VM_ARGV=(prlctl exec "$VM_NAME" runuser -l "$VM_USER" -c
               "bash -c \"\$(echo $b64 | base64 -d)\"") ;;
    *) echo "nightly_check: NIGHTLY_VM_TRANSPORT must be prlctl or ssh, not '$VM_TRANSPORT'" >&2; exit 64 ;;
  esac
}
vm() { vm_argv "$1"; "${VM_ARGV[@]}" </dev/null; }

# ---------------------------------------------------------------------------
# The report. Rewritten after every step, so a night that is killed leaves the
# part that happened rather than nothing.
# ---------------------------------------------------------------------------
excerpt_of() {  # excerpt_of LOG -> the lines that say why, or the last lines
  local log="$1" hits
  hits="$(grep -n -m 20 -iE 'FAIL|error|exception|refused|timed out|STOPPED|\[E\]|not found|denied' "$log" 2>/dev/null | cut -c1-240)"
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; else tail -n 15 "$log" 2>/dev/null | cut -c1-240; fi
}

# Task 11.333. The Mac's build tools, read once and kept (the report is rewritten after
# every step). On 2026-10-06 an Xcode update turned the macOS build red with no change to
# the code, and nothing in the report said a tool had changed; with this line a toolchain
# change shows up as a changed line between two nights' reports. A tool that cannot be
# read says "not found" rather than leaving a blank that looks like "unchanged".
toolchain_note() {
  [ -n "$TOOLCHAIN_NOTE" ] && return 0
  local xc fl dt os
  xc="$(xcodebuild -version 2>/dev/null | sed -n '1s/^Xcode //p;2s/^Build version /build /p' | tr '\n' ' ' | sed 's/ $//')"
  fl="$(flutter --version 2>/dev/null | sed -n '1s/^Flutter \([^ ]*\) • channel \([^ ]*\).*/\1 (\2)/p')"
  dt="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9.]*\).*/\1/p')"
  os="$(sw_vers -productVersion 2>/dev/null)"
  TOOLCHAIN_NOTE="Xcode ${xc:-not found}; Flutter ${fl:-not found}; Dart ${dt:-not found}; macOS ${os:-not found}"
}

write_report() {
  local now elapsed n fails=0 passes=0 skips=0 stops=0 verdict i
  toolchain_note
  now="$(date +%s)"; elapsed=$((now - START_EPOCH))
  n=${#STEP_ID[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    case "${STEP_STATUS[$i]}" in
      PASS) passes=$((passes+1)) ;;
      SKIPPED) skips=$((skips+1)) ;;
      STOPPED) stops=$((stops+1)) ;;
      *) fails=$((fails+1)) ;;
    esac
    i=$((i+1))
  done
  if [ "$RUN_STATE" = "running" ]; then verdict="IN PROGRESS"
  elif [ "$stops" -gt 0 ] || [ "${RUN_STATE#stopped}" != "$RUN_STATE" ]; then verdict="STOPPED EARLY ($RUN_STATE) — $fails step(s) had failed before it stopped"
  elif [ "$fails" -gt 0 ]; then verdict="$fails FAILED"
  elif [ "$RUN_STATE" != "finished" ]; then verdict="ENDED EARLY ($RUN_STATE) — nothing failed before it stopped"
  else verdict="ALL PASSED"; fi
  {
    echo "# Local CI report — $STAMP"
    echo
    echo "**Verdict: $verdict** — $passes passed, $fails failed, $stops stopped, $skips skipped, of $n steps."
    echo
    echo "- **Commit tested:** \`${MAC_SHA:-unknown}\` ${MAC_SUBJECT:+— $MAC_SUBJECT }(branch \`${MAC_BRANCH:-?}\`)."
    if [ "$MAC_DIRTY_COUNT" -gt 0 ]; then
      echo "- **Uncommitted changes: $MAC_DIRTY_COUNT tracked file(s).** The VM half tested the commit above, not these; the Mac half tested the working tree as it was. Files: $MAC_DIRTY_LIST"
    else
      echo "- **Uncommitted changes:** none; both halves tested exactly that commit."
    fi
    echo "- **Mac toolchain (task 11.333):** $TOOLCHAIN_NOTE."
    echo "- **Started:** $START_HUMAN. **Ended:** ${END_HUMAN:-still running}. **Run time:** $(fmt_dur "$elapsed"). **State:** $RUN_STATE."
    echo "- **Kept awake:** $AWAKE_NOTE"
    [ -n "$VM_DISK_NOTE" ] && echo "- **VM disk (task 11.328):** ${VM_DISK_NOTE#disk: }"
    echo "- **GitHub's checks:** paused (task 11.325); this report is the check. See \`CLAUDE_DOCS/RELEASE_CHECKLIST.md\` row B0."
    if [ "$SKIP_VM" -eq 1 ] || [ "$SKIP_MAC" -eq 1 ]; then
      echo "- **Not a full night:** run with $([ "$SKIP_VM" -eq 1 ] && echo '--skip-vm ')$([ "$SKIP_MAC" -eq 1 ] && echo '--skip-mac')."
    fi
    echo
    echo "## Steps"
    echo
    echo "| # | Where | Step | Result | Time | What it printed | Log |"
    echo "|---|---|---|---|---|---|---|"
    i=0
    while [ "$i" -lt "$n" ]; do
      printf '| %d | %s | %s | **%s** | %s | %s | `%s` |\n' "$((i+1))" "${STEP_WHERE[$i]}" "${STEP_LABEL[$i]}" \
        "${STEP_STATUS[$i]}" "$(fmt_dur "${STEP_SECS[$i]}")" "${STEP_NOTE[$i]//|/\\|}" "${STEP_LOG[$i]}"
      i=$((i+1))
    done
    if [ "$fails" -gt 0 ]; then
      echo
      echo "## Failures — the lines that say why (the full log is the path in the table)"
      i=0
      while [ "$i" -lt "$n" ]; do
        case "${STEP_STATUS[$i]}" in PASS|SKIPPED) ;; *)
          echo
          echo "### $((i+1)). ${STEP_WHERE[$i]}: ${STEP_LABEL[$i]} — ${STEP_STATUS[$i]}"
          echo
          echo '```'
          if [ -n "${STEP_LOG[$i]}" ] && [ -f "$RUN_DIR/${STEP_LOG[$i]}" ]; then excerpt_of "$RUN_DIR/${STEP_LOG[$i]}"; else echo "(no log)"; fi
          echo '```'
        ;; esac
        i=$((i+1))
      done
    fi
    echo
    echo "## What the preflight said"
    echo
    echo '```'
    local line
    for line in ${PREFLIGHT_LINES[@]+"${PREFLIGHT_LINES[@]}"}; do printf '%s\n' "$line"; done
    echo '```'
    echo
    echo "Logs are in \`$LOG_DIR\`."
  } >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
}

# ---------------------------------------------------------------------------
# Running a step
# ---------------------------------------------------------------------------
note_from_log() {  # note_from_log LOG REGEX -> the last matching line, trimmed
  local log="$1" re="$2"
  [ -n "$re" ] || return 0
  grep -E "$re" "$log" 2>/dev/null | tail -n 1 | sed 's/^[[:space:]]*//' | cut -c1-170
}

progress() {  # progress <what finished> <what is next> <next's minutes>
  local pct filled bar="" i left_min
  if [ "$TOTAL_W" -gt 0 ]; then pct=$((DONE_W * 100 / TOTAL_W)); else pct=100; fi
  filled=$((pct / 10)); i=0
  while [ "$i" -lt 10 ]; do
    if [ "$i" -lt "$filled" ]; then bar="${bar}▓"; else bar="${bar}░"; fi
    i=$((i+1))
  done
  left_min=$((TOTAL_W - DONE_W))
  say "Progress $bar ${pct}% — step $N_DONE of $N_TOTAL done: $1. Next: $2 (usually ~$3 min; about $left_min min left in all)."
}

# add_plan WHERE ID LABEL TIMEOUT_MIN TYPICAL_MIN COMMAND [NOTE_REGEX] [CONDITION_FUNCTION]
add_plan() {
  PLAN_WHERE+=("$1"); PLAN_ID+=("$2"); PLAN_LABEL+=("$3"); PLAN_TMO+=("$4"); PLAN_W+=("$5")
  PLAN_CMD+=("$6"); PLAN_NOTE_RE+=("${7:-}"); PLAN_COND+=("${8:-}")
  TOTAL_W=$((TOTAL_W + $5)); N_TOTAL=$((N_TOTAL + 1))
}

record_step() {  # record_step WHERE ID LABEL STATUS SECS LOG NOTE
  STEP_WHERE+=("$1"); STEP_ID+=("$2"); STEP_LABEL+=("$3"); STEP_STATUS+=("$4")
  STEP_SECS+=("$5"); STEP_LOG+=("$6"); STEP_NOTE+=("$7")
}

selected() {  # selected ID -> 0 if this step is to run (everything, unless --only)
  [ -z "$ONLY" ] && return 0
  grep -q ",$1," <<<",$ONLY,"
}

next_after() {  # next_after INDEX -> sets next_label and next_w to the next step that will run
  local j=$(($1 + 1))
  next_label="the end"; next_w=0
  while [ "$j" -lt "${#PLAN_ID[@]}" ]; do
    if selected "${PLAN_ID[$j]}"; then next_label="${PLAN_LABEL[$j]}"; next_w="${PLAN_W[$j]}"; return; fi
    j=$((j+1))
  done
}

run_plan_item() {  # run_plan_item INDEX
  local i="$1" where id label tmo w cmd re cond reason log rc t0 secs status note next_label next_w
  where="${PLAN_WHERE[$i]}"; id="${PLAN_ID[$i]}"; label="${PLAN_LABEL[$i]}"
  tmo="${PLAN_TMO[$i]}"; w="${PLAN_W[$i]}"; cmd="${PLAN_CMD[$i]}"; re="${PLAN_NOTE_RE[$i]}"; cond="${PLAN_COND[$i]}"
  log="logs/$(printf '%02d' $((i+1)))-$id.log"

  if [ -n "$cond" ]; then
    reason="$($cond)" || true
    if [ -n "$reason" ]; then
      record_step "$where" "$id" "$label" "SKIPPED" 0 "" "$reason"
      N_DONE=$((N_DONE+1)); DONE_W=$((DONE_W+w)); write_report
      next_after "$i"
      progress "$label — SKIPPED ($reason)" "$next_label" "$next_w"
      return
    fi
  fi

  : >"$RUN_DIR/$log"
  t0="$(date +%s)"
  # The limit is whole minutes, or seconds with an "s" (the self-test's hang).
  local limit_s limit_text
  case "$tmo" in
    *s) limit_s="${tmo%s}"; limit_text="${tmo%s} s" ;;
    *) limit_s=$((tmo * 60)); limit_text="${tmo} min" ;;
  esac
  say "[$(date +%H:%M:%S)] starting: $where: $label (limit $limit_text)"
  if [ "$where" = "VM" ]; then
    vm_argv "$cmd"
    python3 scripts/lib/run_step.py "$RUN_DIR/$log" "$limit_s" -- "${VM_ARGV[@]}" &
  else
    python3 scripts/lib/run_step.py "$RUN_DIR/$log" "$limit_s" -- bash -c "cd \"$repo_root\" && $cmd" &
  fi
  CURRENT_PID=$!
  CUR_WHERE="$where"; CUR_ID="$id"; CUR_LABEL="$label"; CUR_LOG="$log"; CUR_T0="$t0"
  wait "$CURRENT_PID"; rc=$?
  CURRENT_PID=""; CUR_ID=""
  secs=$(( $(date +%s) - t0 ))
  case "$rc" in
    0) status="PASS" ;;
    124) status="TIMEOUT" ;;
    *) status="FAIL" ;;
  esac
  note="$(note_from_log "$RUN_DIR/$log" "$re")"
  [ "$status" = "FAIL" ] && note="exit $rc${note:+; $note}"
  [ "$status" = "TIMEOUT" ] && note="killed at the $limit_text limit${note:+; $note}"
  record_step "$where" "$id" "$label" "$status" "$secs" "$log" "$note"
  N_DONE=$((N_DONE+1)); DONE_W=$((DONE_W+w)); write_report
  next_after "$i"
  progress "$label — $status in $(fmt_dur "$secs")" "$next_label" "$next_w"
}

run_plan() {
  local i=0
  while [ "$i" -lt "${#PLAN_ID[@]}" ]; do run_plan_item "$i"; i=$((i+1)); done
}

# ---------------------------------------------------------------------------
# Ending, however it ends
# ---------------------------------------------------------------------------
# Task 11.328. One night builds about 1.4 GB of Docker images and cache on the VM (task 11.327),
# and the VM is small, so the night removes what it built at its end, even after a failure or
# Ctrl-C (finish() runs this when the step did not). What it removes, and why that is safe:
#   * Images, found by Docker's own record of which compose project built them: a project named
#     tritrack-something (the gate, the drills, the server suite) goes; the project named
#     exactly "tritrack" (the real server) and the project the VM's own checkout resolves to
#     never do, and `docker rmi` without force refuses any image a container, even a stopped
#     one, still uses. The one other kind is an image a script built itself with a tritrack-
#     name and no project (it has no label to read). A new drill needs no edit here.
#   * Docker's build cache, all of it (`prune -a`: without it Docker removes only "dangling" cache
#     and left 1.8 GB behind in the first night run of this task). Docker cannot clear only one
#     project's cache. It is only a cache, so the cost is a slower next build, and the night
#     already builds from nothing.
#   * Never volumes (the real server's database is in one), containers, or pulled base images.
# The disk reading uses the filesystem the VM's checkout is on, as the preflight does.
vm_free_kb_cmd() { printf "df -Pk '%s' | awk 'NR==2{printf \"%%d\", \$4}'" "$VM_REPO"; }

vm_cleanup_script() {  # vm_cleanup_script START_KB (empty: measure when this starts)
  printf "cd '%s' || exit 1\nstart_kb='%s'\nreal_containers='%s'\n" "$VM_REPO" "$1" "$VM_REAL_CONTAINERS"
  printf 'free_kb() { %s; }\n' "$(vm_free_kb_cmd)"
  cat <<'EOF'
gb() { awk -v k="$1" 'BEGIN{printf "%.1f", k/1048576}'; }
when="when the night began"
[ -n "$start_kb" ] || { start_kb="$(free_kb)"; when="before this clean-up"; }
label() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null; }
imglabel() { docker image inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null; }
protect=" tritrack "
for c in $real_containers $(docker compose ps -a -q 2>/dev/null); do
  p="$(label "$c")"
  case "$protect" in *" $p "*) ;; *) [ -n "$p" ] && protect="$protect$p " ;; esac
done
echo "cleanup: the real server's project (never touched):$protect"
removed=0; kept=0
list="$(docker image ls -a --no-trunc --format '{{.ID}} {{.Repository}}:{{.Tag}}')"
while read -r id ref; do
  [ -n "$id" ] || continue
  proj="$(imglabel "$id")"
  case "$proj" in
    tritrack-?*) ;;
    # No compose label: a script that ran `docker build -t tritrack-...` itself (the C-3 check's
    # tritrack-c3-check, found left behind on 2026-10-05). The real server is built by compose,
    # so it always has a label and is never in this branch.
    "") case "$ref" in tritrack-*) proj="built directly" ;; *) continue ;; esac ;;
    *) continue ;;
  esac
  case "$protect" in *" $proj "*) continue ;; esac
  [ "$ref" = "<none>:<none>" ] && ref="$id"
  if docker rmi "$ref" >/dev/null 2>&1; then
    removed=$((removed+1)); echo "cleanup: removed $ref ($proj)"
  elif docker image inspect "$id" >/dev/null 2>&1; then
    kept=$((kept+1)); echo "cleanup: KEPT $ref ($proj): Docker refused, so a container still uses it"
  fi
done <<LIST
$list
LIST
echo "cleanup: removed $removed image(s) built by the gate and drills; $kept kept."
echo "cleanup: build cache: $(docker builder prune -af 2>&1 | tail -n 1) (Docker cannot clear only TriTrack's cache; it is only a cache)"
end_kb="$(free_kb)"
echo "disk: the VM had $(gb "$start_kb") GB free $when and has $(gb "$end_kb") GB free now."
[ "$kept" -eq 0 ] || { echo "FAIL: $kept image(s) of the night could not be removed; see the KEPT lines."; exit 1; }
exit 0
EOF
}

vm_restore_script() {
  cat <<EOF
cd '$VM_REPO' || exit 1
# If the night was stopped from the Mac, the command it was running in the VM may still
# be running there; it would bring the stack back up behind the teardown below.
# (The [x] in each pattern keeps pkill from matching this very script, whose own command
# line contains the pattern text: the first version of this line killed itself.)
pkill -f 'scripts/gate_smoke_tes[t].sh' 2>/dev/null; pkill -f '_broken_contro[l].py' 2>/dev/null
pkill -f 'scripts/gate_drill_stack_u[p].sh' 2>/dev/null; pkill -f 'scripts/run_server_tests_dock[e]r.sh' 2>/dev/null
sleep 2
docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml down -v >/dev/null 2>&1 || true
docker compose -p tritrack-server-test -f docker-compose.yml -f docker-compose.server-test.yml down -v >/dev/null 2>&1 || true
# Put the checkout back where the night found it: a detached head at the Mac's commit
# would make the next 'git pull' on the VM fail, and the real server's files should be
# the ones it was started from.
if [ -n '$VM_ORIG_REF' ]; then
  git checkout -f --quiet '${VM_ORIG_REF#refs/heads/}' && echo "VM checkout restored to ${VM_ORIG_REF#refs/heads/} at \$(git rev-parse --short HEAD)"
fi
if [ -z '$VM_REAL_CONTAINERS' ]; then
  echo "The real server was not running when the night began (nothing was holding port 8080), so nothing was restarted."
  exit 0
fi
for name in $VM_REAL_CONTAINERS; do docker start "\$name" || echo "COULD NOT START \$name"; done
echo -n "Waiting for the real server's /health..."
for _ in \$(seq 1 60); do
  if curl -fsS --max-time 3 http://127.0.0.1:8080/health >/dev/null 2>&1; then echo " answering."; exit 0; fi
  sleep 2; echo -n "."
done
echo " NOT ANSWERING after two minutes. The container(s) were started; read 'docker logs'."
exit 1
EOF
}

finish() {  # finish EXIT_STATUS_IF_CLEAN
  FINISHING=1
  trap '' INT TERM
  if [ "$VM_PREPARED" -eq 1 ] && [ "$VM_RESTORED" -eq 0 ]; then
    say "Putting the VM back as the night found it..."
    local log="logs/99-vm-restore-on-exit.log" rc t0
    : >"$RUN_DIR/$log"; t0="$(date +%s)"
    vm_argv "$(vm_restore_script)"
    python3 scripts/lib/run_step.py "$RUN_DIR/$log" 900 -- "${VM_ARGV[@]}"; rc=$?
    VM_RESTORED=1
    record_step "VM" "vm-restore-on-exit" "Put the VM back (the run ended before its own restore step)" \
      "$([ "$rc" -eq 0 ] && echo PASS || echo FAIL)" "$(( $(date +%s) - t0 ))" "$log" "$(note_from_log "$RUN_DIR/$log" 'restored|restarted|answering|NOT ANSWERING|COULD NOT')"
  fi
  if [ "$VM_PREPARED" -eq 1 ] && [ "$VM_CLEANED" -eq 0 ]; then
    say "Removing what the night built on the VM..."
    local clog="logs/99-vm-cleanup-on-exit.log" crc ct0
    : >"$RUN_DIR/$clog"; ct0="$(date +%s)"
    vm_argv "$(vm_cleanup_script "$VM_DISK_START_KB")"
    python3 scripts/lib/run_step.py "$RUN_DIR/$clog" 900 -- "${VM_ARGV[@]}"; crc=$?
    VM_CLEANED=1
    VM_DISK_NOTE="$(note_from_log "$RUN_DIR/$clog" '^disk:')"
    record_step "VM" "vm-cleanup-on-exit" "Remove what the night built (the run ended before its own clean-up step)" \
      "$([ "$crc" -eq 0 ] && echo PASS || echo FAIL)" "$(( $(date +%s) - ct0 ))" "$clog" "$VM_DISK_NOTE"
  fi
  END_HUMAN="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  [ "$RUN_STATE" = "running" ] && RUN_STATE="finished"
  if [ -n "$CAFFEINATE_PID" ]; then
    AWAKE_NOTE="$AWAKE_NOTE The caffeinate (pid $CAFFEINATE_PID) is tied to this script and ended with it at $END_HUMAN; the Mac may sleep now."
  fi
  write_report
  [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"
}

on_signal() {
  [ "$FINISHING" -eq 1 ] && return
  say ""
  say "Stopped by $1. Cleaning up (this puts the VM back first)..."
  [ -n "$CURRENT_PID" ] && kill -TERM "$CURRENT_PID" 2>/dev/null
  [ -n "$CURRENT_PID" ] && wait "$CURRENT_PID" 2>/dev/null
  RUN_STATE="stopped by $1"
  # The step that was running did not finish; say so rather than leave it out.
  if [ -n "$CUR_ID" ]; then
    record_step "$CUR_WHERE" "$CUR_ID" "$CUR_LABEL" "STOPPED" "$(( $(date +%s) - CUR_T0 ))" "$CUR_LOG" "interrupted by $1"
    CUR_ID=""
  fi
  finish
  say "Report so far: $REPORT"
  exit 130
}
trap 'on_signal "Ctrl-C"' INT
trap 'on_signal "a TERM signal"' TERM
trap 'on_signal "the terminal closing"' HUP

# ---------------------------------------------------------------------------
# Keeping the Mac awake — the script's first act
# ---------------------------------------------------------------------------
start_awake() {
  if ! command -v caffeinate >/dev/null 2>&1; then
    AWAKE_NOTE="NOT kept awake: caffeinate was not found on this Mac."
    return
  fi
  caffeinate -dims -w $$ &
  CAFFEINATE_PID=$!
  sleep 1
  # Read the whole output first: `grep -q` stops at its first match, which closes
  # the pipe and makes `pmset` exit 141, and under `pipefail` that reads as "not
  # found" -- the check said NOT CONFIRMED over a caffeinate it was looking at.
  local assertions
  assertions="$(pmset -g assertions 2>/dev/null)"
  if grep -q "pid ${CAFFEINATE_PID}(caffeinate)" <<<"$assertions"; then
    AWAKE_NOTE="yes — \`caffeinate -dims -w $$\` (pid $CAFFEINATE_PID), tied to this script's process, listed by \`pmset -g assertions\` at start."
  else
    AWAKE_NOTE="NOT CONFIRMED — caffeinate started (pid $CAFFEINATE_PID) but \`pmset -g assertions\` did not list it, so the Mac may sleep mid-night."
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
pf_ok()   { PREFLIGHT_LINES+=("ok    $*"); say "  ok    $*"; }
pf_warn() { PREFLIGHT_LINES+=("WARN  $*"); WARNINGS+=("$*"); say "  WARN  $*"; }
pf_stop() { PREFLIGHT_LINES+=("STOP  $*"); PROBLEMS+=("$*"); say "  STOP  $(sed -n 1p <<<"$*")"; }

gb_free() {  # gb_free PATH -> whole gigabytes free on the Mac
  df -Pk "$1" | awk 'NR==2{printf "%d", $4/1048576}'
}

pf_repo() {
  MAC_SHA="$(git rev-parse HEAD)"
  MAC_SUBJECT="$(git log -1 --format=%s | cut -c1-90)"
  MAC_BRANCH="$(git branch --show-current)"; [ -n "$MAC_BRANCH" ] || MAC_BRANCH="(detached)"
  MAC_DIRTY_LIST="$(git status --porcelain --untracked-files=no | awk '{print $2}' | sed -n 1,8p | tr '\n' ' ')"
  MAC_DIRTY_COUNT="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  if [ "$MAC_DIRTY_COUNT" -gt 0 ]; then
    pf_warn "$MAC_DIRTY_COUNT tracked file(s) have uncommitted changes ($MAC_DIRTY_LIST). The VM half will test the last commit (${MAC_SHA:0:8}), not these; the Mac half tests the working tree as it is. Commit first if you want one answer."
  else
    pf_ok "no uncommitted changes: the night tests commit ${MAC_SHA:0:8} on both machines."
  fi
}

pf_tools() {
  local missing="" t
  for t in flutter dart python3 hugo curl git; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  if [ -n "$missing" ]; then pf_stop "These tools are not on this Mac's PATH:$missing. The steps that need them cannot run. Install them, or open a terminal where they work."
  else pf_ok "flutter, dart, python3, hugo, curl and git are all installed."; fi
}

pf_port() {
  if curl -fsS --max-time 2 "http://127.0.0.1:${SERVER_PORT:-8080}/health" >/dev/null 2>&1; then
    pf_stop "Something on this Mac is answering on port ${SERVER_PORT:-8080}. The offline suite's whole claim is that the app passes with no server reachable, so it refuses to run while one is. Stop it (docker compose down, or quit the dev server) and run this again."
  else pf_ok "nothing is answering on port ${SERVER_PORT:-8080} on this Mac."; fi
}

pf_power() {
  local batt; batt="$(pmset -g batt 2>/dev/null | sed -n 1p)"
  if grep -q "AC Power" <<<"$batt"; then
    pf_ok "the Mac is on power."
  else
    pf_stop "The Mac is running on its battery. A night's work will not last on it. Plug the charger in."
  fi
}

pf_mac_disk() {
  local g; g="$(gb_free "$repo_root")"
  if [ "$g" -lt "$MAC_DISK_STOP" ]; then pf_stop "The Mac has only ${g} GB free; three platform builds need more than ${MAC_DISK_STOP} GB. Empty the trash or delete old Xcode simulators."
  elif [ "$g" -lt "$MAC_DISK_WARN" ]; then pf_warn "The Mac has ${g} GB free; enough, but not much."
  else pf_ok "the Mac has ${g} GB free."; fi
}

pf_signing() {
  # A free developer team's signing permission lasts 7 days. Read each installed
  # profile for this app and say when the last one runs out.
  local result
  result="$(python3 - "$NIGHT_HOURS" <<'PY'
import glob, os, plistlib, subprocess, sys, time, datetime
hours = float(sys.argv[1])
bundle = "edu.nau.tritrack"
dirs = [os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
        os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")]
found = {}
for d in dirs:
    for path in glob.glob(os.path.join(d, "*")):
        try:
            raw = subprocess.run(["security", "cms", "-D", "-i", path],
                                 capture_output=True, check=True).stdout
            plist = plistlib.loads(raw)
        except Exception:
            continue
        ent = plist.get("Entitlements", {})
        app_id = ent.get("application-identifier") or ent.get("com.apple.application-identifier") or ""
        if not app_id.endswith("." + bundle):
            continue
        kind = "iOS" if path.endswith(".mobileprovision") else "macOS"
        exp = plist["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
        if kind not in found or exp > found[kind]:
            found[kind] = exp
now = datetime.datetime.now(datetime.timezone.utc)
# Task 11.328: a platform with no profile at all is reported too. Xcode deletes an expired
# profile, so "none installed" is what an expired one looks like a day later.
for kind in ("macOS", "iOS"):
    if kind not in found:
        print(f"MISSING\t{kind}\t\t")
for kind, exp in sorted(found.items()):
    left = (exp - now).total_seconds() / 3600
    local = exp.astimezone().strftime("%a %b %d %H:%M")
    state = "EXPIRED" if left <= 0 else ("SOON" if left < hours else "OK")
    when = (f"{-left:.0f} hours ago" if left <= 0 else f"in {left:.0f} hours")
    print(f"{state}\t{kind}\t{local}\t{when}")
PY
)"
  if [ -z "$result" ]; then
    pf_warn "Could not read this Mac's Xcode signing profiles, so whether the signing permission is current is not known."
    return
  fi
  # One line per platform, because the two are renewed from different projects (task 11.327:
  # the macOS warning used to send Michael to ios/Runner.xcworkspace). When both lapse, both
  # lines print, each naming its own project.
  local line state kind local_time when phrase consequence renew
  while IFS=$'\t' read -r state kind local_time when; do
    [ -n "$state" ] || continue
    case "$state" in
      OK) pf_ok "the $kind signing permission runs out $local_time, $when (more than ${NIGHT_HOURS} hours away)." ;;
      *)
        case "$state" in
          EXPIRED) phrase="EXPIRED on $local_time ($when)" ;;
          MISSING) phrase="is missing: no profile for it is installed (Xcode deletes an expired one, so this is also what an expired permission looks like the next day)" ;;
          *) phrase="runs out on $local_time ($when), before the night is over" ;;
        esac
        case "$kind" in
          macOS)
            consequence="the Mac app will not open from Xcode or 'flutter run -d macos'"
            renew="in Xcode, open macos/Runner.xcworkspace, click Runner, Signing & Capabilities, let it renew, then build once with Cmd-B" ;;
          *)
            consequence="the phone app cannot be installed from Xcode or 'flutter run'"
            renew="in Xcode, open ios/Runner.xcworkspace, click Runner, Signing & Capabilities, and let it renew (or plug the phone in and run the app once)" ;;
        esac
        pf_warn "The $kind signing permission for TriTrack $phrase. This does not stop the night: its builds are unsigned. But $consequence until it is renewed: $renew." ;;
    esac
  done <<<"$result"
}

pf_backup_alpine() {
  # Task 11.327. The backup image's age and minisign are pinned by the Alpine release in
  # server/backup/Dockerfile's FROM tag, not by a version: a version pin broke on Alpine's
  # schedule twice. The cost of that choice is that the release stops getting fixes for those
  # two (its "community" repository) when the next Alpine release ships, and then the image
  # keeps building with stale packages and nothing says so. Alpine publishes that date; this
  # reads it, and warns from a month before.
  local json result state rel eol days newest
  json="$(curl -fsS --max-time 10 https://alpinelinux.org/releases.json 2>/dev/null)" || json=""
  result="$(ALPINE_RELEASES="$json" python3 - server/backup/Dockerfile <<'PY'
import datetime, json, os, re, sys
m = re.search(r'^FROM\s+\S*-alpine(\d+\.\d+)\b', open(sys.argv[1]).read(), re.M)
if not m:
    print("NOPIN"); sys.exit()
rel = m.group(1)
try:
    branches = json.loads(os.environ["ALPINE_RELEASES"])["release_branches"]
except Exception:
    print(f"NONET\t{rel}"); sys.exit()
def ver(b):
    return tuple(int(x) for x in b["rel_branch"][1:].split("."))
stable = [b for b in branches if re.fullmatch(r"v\d+\.\d+", b.get("rel_branch", ""))]
newest = ".".join(map(str, max(map(ver, stable)))) if stable else "?"
mine = next((b for b in stable if b["rel_branch"] == "v" + rel), None)
eol = next((r.get("eol_date") for r in (mine or {}).get("repos", []) if r.get("name") == "community"), None)
if not eol:
    print(f"NODATE\t{rel}\t-\t-\t{newest}"); sys.exit()
days = (datetime.date.fromisoformat(eol) - datetime.date.today()).days
state = "PAST" if days < 0 else ("SOON" if days <= 31 else "OK")
print(f"{state}\t{rel}\t{eol}\t{days}\t{newest}")
PY
)"
  IFS=$'\t' read -r state rel eol days newest <<<"$result"
  local move="ask the planning session for a task to move the FROM line in server/backup/Dockerfile to Alpine $newest"
  [ "$newest" = "$rel" ] && move="when the next Alpine release ships (each May and November), ask the planning session for a task to move the FROM line in server/backup/Dockerfile to it"
  case "$state" in
    OK) pf_ok "the backup image's Alpine release ($rel) gets fixes for age and minisign until $eol ($days days)." ;;
    SOON) pf_warn "The backup image's Alpine release ($rel) stops getting fixes for age and minisign (the encryptor and signer of every backup) on $eol, in $days days. Nothing breaks that day: the image keeps building, with packages that no longer get security fixes. Before then, $move." ;;
    PAST) pf_warn "The backup image's Alpine release ($rel) stopped getting fixes for age and minisign (the encryptor and signer of every backup) on $eol, $(( -days )) days ago. The image still builds, but those two no longer get security fixes: $move." ;;
    NOPIN) pf_warn "server/backup/Dockerfile's FROM line names no Alpine release (like postgres:16-alpine3.24), so age and minisign come from whichever release the base image moves to. That is how the backup image stopped building on 2026-10-04 (task 11.327)." ;;
    NODATE) pf_warn "alpinelinux.org/releases.json has no end date for Alpine $rel's community repository, so this cannot say how long the backup image's age and minisign keep getting fixes. Check that $rel is a real Alpine release." ;;
    *) pf_warn "Could not reach alpinelinux.org to check how long the backup image's Alpine release (${rel:-unknown}) keeps getting fixes for age and minisign. Nothing about tonight depends on it." ;;
  esac
}

pf_vm_reach() {
  local out rc why
  if [ "$VM_TRANSPORT" = "prlctl" ]; then
    # Two things have to be true before any command can run in the VM: Parallels
    # has the VM running (not suspended, not off), and Parallels Tools inside it
    # answers. They fail differently and each has its own plain message.
    if ! command -v prlctl >/dev/null 2>&1; then
      pf_stop "prlctl (Parallels' command-line tool) is not on this Mac's PATH, so the VM cannot be reached. Open Parallels Desktop once, or run with NIGHTLY_VM_TRANSPORT=ssh after setting SSH up."
      return 1
    fi
    out="$(prlctl status "$VM_NAME" 2>&1)"
    case "$out" in
      *" running"*) ;;
      *"suspended"*|*"paused"*|*"stopped"*|*"resuming"*|*"starting"*)
        pf_stop "The VM '$VM_NAME' is not running (Parallels says: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-100)). Open Parallels Desktop and start it, wait for the desktop to appear, then run this again."
        return 1 ;;
      *)
        pf_stop "Parallels has no virtual machine named '$VM_NAME' (it said: $(sed -n 1p <<<"$out" | cut -c1-120)). The names it knows are: $(prlctl list -a -o name 2>/dev/null | tail -n +2 | tr '\n' ',' | cut -c1-200) -- set NIGHTLY_VM_NAME to the right one."
        return 1 ;;
    esac
    out="$(vm 'echo reached; hostname' 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && grep -q '^reached' <<<"$out"; then
      pf_ok "the VM '$VM_NAME' is running and Parallels Tools answers (prlctl, as $VM_USER on $(printf '%s' "$out" | tail -n 1))."
      return 0
    fi
    pf_stop "The VM is running but Parallels Tools inside it did not answer (it said: $(sed -n 1,2p <<<"$out" | tr '\n' ' ' | cut -c1-140)). It is usually still starting up -- give it a minute and run this again; if it keeps happening, in Parallels choose Actions > Reinstall Parallels Tools."
    return 1
  fi
  out="$(vm 'echo reached; hostname' 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q '^reached' <<<"$out"; then
    pf_ok "the Mac can run commands in the VM ($VM_TRANSPORT, as $(printf '%s' "$out" | tail -n 1))."
    return 0
  fi
  case "$out" in
    *"Could not resolve hostname"*) why="The name '$VM_HOST' is not in ~/.ssh/config (or the VM's .local name does not resolve). The ssh transport needs an SSH server on the VM, a key, and that entry; the default transport (prlctl) needs none of them: unset NIGHTLY_VM_TRANSPORT." ;;
    *"Permission denied"*) why="The VM did not accept the key. The ssh transport needs the key installed on the VM (ssh-copy-id); the default transport (prlctl) needs none of that: unset NIGHTLY_VM_TRANSPORT." ;;
    *"Connection refused"*) why="The VM is up but its SSH server is not running ('sudo apt install -y openssh-server' and 'sudo systemctl enable --now ssh' on the VM), or unset NIGHTLY_VM_TRANSPORT to use Parallels instead." ;;
    *"Host key verification failed"*) why="The Mac does not recognize the VM's fingerprint yet. Run 'ssh $VM_HOST hostname' once by hand and answer yes." ;;
    *"timed out"*|*"No route"*|*"Operation timed out"*) why="The VM did not answer. It may be suspended or off (Parallels, 'On window close: suspend' is this VM's setting), or on a different network. Open the VM's window and check it is running." ;;
    *) why="The command in the VM failed: $(sed -n 1,3p <<<"$out" | tr '\n' ' ')" ;;
  esac
  pf_stop "The Mac cannot reach the VM. $why"
  return 1
}

# Task 11.330 round 2. The night's first VM step builds the backup image from nothing, which asks
# Docker Hub for a fresh copy of its base. On 2026-10-06 that failed three runs in a row, 25 minutes
# into the night, with "dial tcp [2a06:...]:443: connect: network is unreachable": the VM had an IPv6
# address and no IPv6 route, and Docker's builder (unlike curl) does not fall back to IPv4. So this
# asks the same builder the same question, with a one-line Dockerfile naming that same base, while
# somebody is awake to act on the answer. It prints facts for the Mac to classify, so the wording
# lives in one place (pf_docker_hub). NIGHTLY_VM_PROBE_PRELUDE is shell text the VM runs first; it
# exists only so a stand-in `docker` or `ip` can be put in front of the real ones to watch this
# check stop (leave it unset for a real run).
vm_hub_probe_script() {
  printf '%s\n' "${NIGHTLY_VM_PROBE_PRELUDE:-}"
  printf "cd '%s' || exit 1\n" "$VM_REPO"
  cat <<'EOF'
base="$(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]\{1,\}\).*/\1/p' server/backup/Dockerfile | sed -n 1p)"
echo "BASE: $base"
ctx="$(mktemp -d)"
log="$ctx/out.log"
printf 'FROM %s\n' "$base" > "$ctx/Dockerfile"
timeout 120 docker build --pull -q -t tritrack-hubprobe-nightcheck:latest "$ctx" >"$log" 2>&1; rc=$?
docker image rm tritrack-hubprobe-nightcheck:latest >/dev/null 2>&1
echo "RC: $rc"
echo "IPV6ADDRS: $(ip -6 addr show scope global 2>/dev/null | grep -c 'inet6 ')"
echo "IPV6ROUTE: $(ip -6 route show default 2>/dev/null | grep -c .)"
echo "UNREACHABLE: $(grep -ci 'network is unreachable' "$log")"
echo "ERRLINE: $(grep -i -m1 'error\|unreachable\|timeout\|denied\|refused' "$log" | awk '{print substr($0, (length($0) > 220 ? length($0) - 219 : 1))}')"
rm -rf "$ctx"
exit 0
EOF
}

pf_docker_hub() {
  local out base rc addrs route errline unreach
  out="$(vm "$(vm_hub_probe_script)" 2>&1)"
  base="$(sed -n 's/^BASE: //p' <<<"$out" | sed -n 1p)"
  rc="$(sed -n 's/^RC: //p' <<<"$out" | sed -n 1p)"
  addrs="$(sed -n 's/^IPV6ADDRS: //p' <<<"$out" | sed -n 1p)"
  route="$(sed -n 's/^IPV6ROUTE: //p' <<<"$out" | sed -n 1p)"
  errline="$(sed -n 's/^ERRLINE: //p' <<<"$out" | sed -n 1p)"
  unreach="$(sed -n 's/^UNREACHABLE: //p' <<<"$out" | sed -n 1p)"
  if [ -z "$rc" ]; then
    pf_warn "Could not ask the VM whether Docker can reach Docker Hub (it said: $(sed -n 1,2p <<<"$out" | tr '\n' ' ' | cut -c1-140)). The first VM step needs it."
  elif [ "$rc" = "0" ]; then
    pf_ok "Docker on the VM can reach Docker Hub (it fetched ${base:-the backup image base})."
  elif [ "${unreach:-0}" -gt 0 ] && [ "${addrs:-0}" -gt 0 ] && [ "${route:-0}" = "0" ]; then
    pf_stop "Docker on the VM cannot reach Docker Hub, and the cause is the VM's network: it has an IPv6 address but no IPv6 route out, and Docker's builder tries Docker Hub's IPv6 address and does not fall back to IPv4 (Docker said: ...$errline). It comes and goes, which is why a night can pass one day and fail the next. On the VM, turn IPv6 off for its network connection: the commands are in server/README.md under \"an IPv6 address with no IPv6 route\". They need your password, which is why this is checked while you are awake."
  else
    pf_stop "Docker on the VM cannot reach Docker Hub${base:+ (it asked for $base)}. Docker said: ...${errline:-no error line was captured}. The night's first VM step builds the backup image from a fresh copy of that base and would fail the same way. Check the VM's internet connection; if Docker's own network lost its address, 'sudo systemctl restart docker' is the known fix (RELEASE_CHECKLIST D5)."
  fi
}

pf_vm_rest() {
  local out sha vmsha dirty
  # --- shared folder + the VM's own checkout
  out="$(vm "git -c safe.directory='*' -C '$VM_SHARED' rev-parse HEAD 2>&1")"
  vmsha="$(printf '%s' "$out" | tail -n 1)"
  if [ "$vmsha" = "$MAC_SHA" ]; then
    pf_ok "the VM reads this repository through the shared folder ($VM_SHARED) and sees commit ${MAC_SHA:0:8}."
  else
    pf_stop "The VM cannot read this repository through the shared folder at $VM_SHARED (it said: $(printf '%s' "$out" | tail -n 1 | cut -c1-120)). In Parallels: Configure > Options > Sharing, share this folder as 'tritrack'."
  fi
  out="$(vm "cd '$VM_REPO' 2>&1 && git status --porcelain --untracked-files=no | wc -l; test -f '$VM_REPO/.env' && echo env-present || echo env-missing" 2>&1)"
  if grep -q 'No such file' <<<"$out"; then
    pf_stop "The VM has no checkout at $VM_REPO. Clone the repository there (the VM's own copy is what the gate builds from)."
  else
    dirty="$(sed -n 1p <<<"$out" | tr -d ' ')"
    if [ "${dirty:-0}" != "0" ]; then pf_stop "The VM's own checkout has $dirty file(s) with edits of its own. The night will not overwrite them: on the VM run 'git -C $VM_REPO status', then commit, stash or discard them."; fi
    grep -q env-missing <<<"$out" && pf_stop "The VM's checkout has no .env file; the gate needs one. Copy .env.example to .env in $VM_REPO."
    if [ "${dirty:-0}" = "0" ] && ! grep -q env-missing <<<"$out"; then pf_ok "the VM's own checkout is clean and has its .env."; fi
  fi
  # --- docker
  out="$(vm 'docker info >/dev/null 2>&1 && echo docker-up || echo docker-down; ip -4 addr show docker0 2>/dev/null | grep "inet " >/dev/null && echo docker0-has-address || echo docker0-no-address' 2>&1)"
  if grep -q docker-down <<<"$out"; then
    pf_stop "Docker is not running on the VM. On the VM: 'sudo systemctl start docker'. (It needs your password, which is why this is checked while you are awake.)"
  elif grep -q docker0-no-address <<<"$out"; then
    pf_stop "Docker is running on the VM but its own network (docker0) has lost its address, which is what makes builds fail at the download step. On the VM: 'sudo systemctl restart docker' (it needs your password; this is the known fix, written in RELEASE_CHECKLIST D5)."
  else
    pf_ok "the VM's Docker is running and docker0 has an address."
    pf_docker_hub
  fi
  # --- Dart, for the server's own test suite
  local macdart vmdart
  macdart="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9.]*\).*/\1/p')"
  vmdart="$(vm "$VM_DART_DIR/bin/dart --version 2>&1" | sed -n 's/^Dart SDK version: \([0-9.]*\).*/\1/p')"
  if [ -z "$vmdart" ]; then
    pf_stop "The VM has no Dart SDK where the night looks for it ($VM_DART_DIR), and the server's tests need one. One command from the Mac installs it, with no sudo: scripts/nightly_check.sh --vm-install-dart"
  elif [ -n "$macdart" ] && [ "$vmdart" != "$macdart" ]; then
    pf_warn "The VM's Dart is $vmdart but this Mac's is $macdart, so the server's tests would run on a different Dart than the one you build with. scripts/nightly_check.sh --vm-install-dart puts the Mac's version in."
  else
    pf_ok "the VM has Dart $vmdart (the same as this Mac's) for the server's tests."
  fi
  # --- disk
  out="$(vm "df -Pk '$VM_REPO' | awk 'NR==2{printf \"%d\", \$4/1048576}'" 2>&1)"
  if grep -qE '^[0-9]+$' <<<"$out"; then
    if [ "$out" -lt "$VM_DISK_STOP" ]; then pf_stop "The VM has only ${out} GB free (needs more than ${VM_DISK_STOP} GB for the gate's images). One command from the Mac frees what the gate and drills built there, usually several GB: scripts/nightly_check.sh --vm-clean. It removes only the images those builds made, and Docker's build cache (only a cache). It cannot touch the real server's images or database. NEVER run 'docker volume prune', 'docker system prune --volumes' or 'docker compose down -v' on the VM by hand: those delete the real server's database."
    elif [ "$out" -lt "$VM_DISK_WARN" ]; then pf_warn "The VM has ${out} GB free; enough, but under ${VM_DISK_WARN} GB, and it was 91% full on 2026-10-02. The night now removes what it builds when it ends, so this should not keep shrinking; if it does, the report's VM disk line and the clean-up step say why. To free room by hand: scripts/nightly_check.sh --vm-clean (never 'docker volume prune' or 'docker system prune --volumes' on the VM: they delete the real server's database)."
    else pf_ok "the VM has ${out} GB free."; fi
  else
    pf_warn "Could not read the VM's free disk space ($out)."
  fi
  # --- will the VM suspend itself?
  out="$(vm 'export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus; for k in sleep-inactive-ac-type sleep-inactive-ac-timeout sleep-inactive-battery-type sleep-inactive-battery-timeout; do echo "$k=$(gsettings get org.gnome.settings-daemon.plugins.power $k 2>&1)"; done' 2>&1)"
  local actype actime battype battime sleepy=""
  actype="$(printf '%s' "$out" | sed -n "s/^sleep-inactive-ac-type=//p" | tr -d "'")"
  actime="$(printf '%s' "$out" | sed -n "s/^sleep-inactive-ac-timeout=//p")"
  battype="$(printf '%s' "$out" | sed -n "s/^sleep-inactive-battery-type=//p" | tr -d "'")"
  battime="$(printf '%s' "$out" | sed -n "s/^sleep-inactive-battery-timeout=//p")"
  if [ -z "$actype" ] || [ -z "$battype" ]; then
    pf_warn "Could not read the VM's automatic-suspend setting ($(sed -n 1p <<<"$out" | cut -c1-100)); check it by hand: Settings > Power > Automatic Suspend must be off."
  else
    [ "$actype" != "nothing" ] && [ "${actime:-0}" != "0" ] && sleepy="on power it suspends after $((actime / 60)) minutes idle"
    [ "$battype" != "nothing" ] && [ "${battime:-0}" != "0" ] && sleepy="${sleepy:+$sleepy; }on battery it suspends after $((battime / 60)) minutes idle (the VM sees the Mac's battery state)"
    if [ -n "$sleepy" ]; then
      pf_stop "The VM puts itself to sleep when idle: $sleepy. Work started from the Mac overnight does not count as activity to the VM's desktop, so it would suspend mid-night. Setup step 1 turns this off from the Mac: run scripts/nightly_check.sh --setup"
    else
      pf_ok "the VM will not suspend itself when idle."
    fi
  fi
  # --- what the night will stop and restart
  # Task 11.328: port 8080 alone used to decide "the real server is not running", and on
  # 2026-10-05 that was said over a server whose web process had stopped but whose database,
  # backup scheduler and three retention jobs had been up for two days. The night still stops
  # and restarts only what holds port 8080 (the web process); it leaves the rest alone, and now
  # says which is which.
  local web pieces up_list down_list
  web="$(vm "docker ps --filter publish=8080 --format '{{.Names}}'" 2>&1)"
  pieces="$(vm "cd '$VM_REPO' && docker compose ps -a --format '{{.Service}} {{.State}}'" 2>&1)"
  if grep -qi 'error\|denied' <<<"$web"; then
    pf_warn "Could not ask the VM which part of the real server is running ($(sed -n 1p <<<"$web" | cut -c1-100))."
  else
    up_list="$(printf '%s\n' "$pieces" | awk 'NF==2 && $2=="running"{print $1}' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    down_list="$(printf '%s\n' "$pieces" | awk 'NF==2 && $2!="running"{print $1" ("$2")"}' | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
    if [ -n "$web" ]; then
      pf_ok "the real server's web process is running on the VM ($(printf '%s' "$web" | tr '\n' ' ' | sed 's/ *$//'))${up_list:+; also up: $up_list}. The night stops the web process and starts it again at the end; the other pieces are left running."
    elif [ -n "$up_list" ]; then
      pf_ok "the real server's web process is NOT running on the VM, but these pieces are up: $up_list${down_list:+; not running: $down_list}. The night leaves the web process stopped and leaves the rest alone."
    elif [ -n "$down_list" ]; then
      pf_ok "no part of the real server is running on the VM (not running: $down_list), so the night leaves it all stopped."
    else
      pf_ok "the real server is not set up on the VM right now (no containers found in $VM_REPO), so the night has nothing of it to stop."
    fi
  fi
  # --- the Parallels window setting
  local prl_info=""
  command -v prlctl >/dev/null 2>&1 && prl_info="$(prlctl list -i "$VM_NAME" 2>/dev/null)"
  if grep -q "On window close: suspend" <<<"$prl_info"; then
    pf_warn "This VM suspends when its window is closed (Parallels setting). Leave the VM's window open overnight."
  fi
}

run_preflight() {
  say "Preflight for $(date '+%Y-%m-%d %H:%M') — commit and tools first, then the VM."
  say "(Nothing starts until every line below is ok or a warning.)"
  pf_repo
  pf_tools
  pf_port
  pf_power
  pf_mac_disk
  pf_signing
  pf_backup_alpine
  if [ "$SKIP_VM" -eq 0 ]; then
    if pf_vm_reach; then pf_vm_rest; fi
  else
    pf_ok "VM checks skipped (--skip-vm)."
  fi
  say ""
  if [ "${#PROBLEMS[@]}" -gt 0 ]; then
    say "STOP — ${#PROBLEMS[@]} thing(s) to fix before tonight:"
    local n=1 p
    for p in "${PROBLEMS[@]}"; do say "  $n. $p"; n=$((n+1)); done
    say ""
    if [ "$FORCE" -eq 1 ]; then
      say "--force given: carrying on anyway. The report will list these."
      return 0
    fi
    say "Fix those and run this again ('scripts/nightly_check.sh --preflight-only' to check without starting)."
    return 1
  fi
  if [ "${#WARNINGS[@]}" -gt 0 ]; then say "${#WARNINGS[@]} warning(s) above; none stops the night."; fi
  say "REMINDER: leave the lid open. Closing a MacBook's lid puts it to sleep no matter what keeps it awake."
  say "All clear. Go to bed."
  return 0
}

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------
docker_on_mac_skip() {
  # The VM half runs the server's suite (task 11.325 round 2), so the Mac does not run it
  # a second time; it runs here only when the VM half is not in this night.
  if [ "$SKIP_VM" -eq 0 ]; then echo "the VM half runs this suite"; return 0; fi
  if docker info >/dev/null 2>&1; then return 0; fi
  echo "NOT RUN ANYWHERE: the VM half was skipped and Docker is not running on the Mac"
}

# Task 11.327: the backup image, built the way a new deployment builds it. Printed by a function,
# like vm_restore_script, so the script reads as the shell the VM will run.
vm_backup_image_script() {
  printf "cd '%s' || exit 1\n" "$VM_REPO"
  cat <<'EOF'
img=tritrack-backup-nightcheck:latest
docker build --no-cache --pull --progress=plain -t "$img" server/backup; rc=$?
if [ "$rc" -ne 0 ]; then
  echo "FAIL: the backup image does not build from nothing. A new server deployment would fail the same way; the ERROR lines above say why (server/backup/Dockerfile explains the pin)."
  exit "$rc"
fi
echo "installed: Alpine $(docker run --rm "$img" cat /etc/alpine-release) with $(docker run --rm "$img" apk list -I age minisign 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
docker image rm "$img" >/dev/null
exit 0
EOF
}

build_vm_plan() {
  local prep gate_env
  # The drills and the stack need the server to run as the invoking user so the
  # magic link it writes is readable (scripts/lib/host_user.sh; CI does the same).
  gate_env="export TRITRACK_DEV_UID=\$(id -u) TRITRACK_DEV_GID=\$(id -g); cd '$VM_REPO'"
  prep="set -e
cd '$VM_REPO'
if [ -n '$VM_REAL_CONTAINERS' ]; then
  echo \"stopping the real server: $VM_REAL_CONTAINERS\"
  docker stop $VM_REAL_CONTAINERS
else
  echo 'the real server was not running; nothing to stop'
fi
git -c safe.directory='*' fetch --quiet '$VM_SHARED' HEAD
got=\"\$(git rev-parse FETCH_HEAD)\"
if [ \"\$got\" != '$MAC_SHA' ]; then echo \"FAIL: the Mac's HEAD moved on while the night was starting (the VM fetched \$got, expected $MAC_SHA)\"; exit 1; fi
git checkout --quiet --detach '$MAC_SHA'
echo \"VM is now at \$(git rev-parse --short HEAD): \$(git log -1 --format=%s | cut -c1-80)\""
  add_plan VM vm-prepare "stop the real server, check out the Mac's commit" 15 2 "$prep" "VM is now at"
  # Task 11.327. The backup image installs age and minisign from Alpine's package index at build
  # time, and that index changes on Alpine's schedule, not ours: it stopped this image building on
  # 2026-09-06 (task 11.175) and again on 2026-10-04. Both times Docker's build cache hid it until
  # the cache was cleared, and a new server deployment, which has no cache, would have met it
  # first. So the night builds it the way a new deployment does -- current base image, no cache --
  # and says which versions it got, so a change inside the pinned Alpine release is visible here.
  add_plan VM vm-backup-image "the backup image builds from nothing (fresh base, no cache)" 15 3 "$(vm_backup_image_script)" "installed:|FAIL:"
  add_plan VM vm-gate "the gate (every instrument)" 90 25 "$gate_env; scripts/gate_smoke_test.sh" "PASS: all|FAIL|instrument"
  # The self-test forces a stale constant into scripts/gate_wire.py in the VM's checkout and
  # requires every wire-speaking instrument to abort. "All passed" and "all aborted before
  # running a control" look the same from outside, which is why this runs at all.
  add_plan VM vm-gate-selftest "the gate's self-test (can its instruments still fail?)" 45 4 "$gate_env; GATE_SMOKE_SELFTEST=1 scripts/gate_smoke_test.sh" "SELFTEST PASSED|SELFTEST FAILED|FAIL"
  add_plan VM vm-drill-stack "bring up the drill stack" 30 5 "$gate_env; scripts/gate_drill_stack_up.sh" "healthy|up and|answer"
  add_plan VM vm-drill-round8 "broken-control drill, round 8" 60 10 "$gate_env; python3 scripts/verify_round8_broken_control.py" "flipped|PASS|FAIL|clean"
  add_plan VM vm-drill-11-49 "broken-control drill, server reads" 60 10 "$gate_env; python3 scripts/verify_11_49_broken_control.py" "flipped|PASS|FAIL|clean"
  add_plan VM vm-drill-11-85 "broken-control drill, join surface" 60 10 "$gate_env; python3 scripts/verify_11_85_broken_control.py" "flipped|PASS|FAIL|clean"
  add_plan VM vm-drill-11-127 "broken-control drill, C-1 and the oracle sweep" 60 10 "$gate_env; python3 scripts/verify_11_127_broken_control.py" "flipped|PASS|FAIL|clean"
  add_plan VM vm-teardown "take the drill stack down" 15 1 "$gate_env; docker compose -p tritrack-gate -f docker-compose.yml -f docker-compose.e2e.yml down -v" "Removed|removed|down"
  # After the drills and the teardown, so it does not share the machine (or a port) with the
  # gate's stack, and before the real server comes back. It starts its own throwaway Postgres
  # (project tritrack-server-test, loopback port 55432) and removes it. The VM's Dart comes
  # from --vm-install-dart (a plain SDK in the user's home), put first on PATH here.
  add_plan VM vm-server-suite "the server's own test suite (its own throwaway database)" 60 8 "$gate_env; export PATH=\"$VM_DART_DIR/bin:\$PATH\"; scripts/run_server_tests_docker.sh" "suite scope \\[|suite scope PASS|All tests passed|Some tests failed|failed"
  add_plan VM vm-restore "put the checkout and the real server back" 15 2 "$(vm_restore_script)" "restored|restarted|answering|NOT ANSWERING|COULD NOT|nothing was restarted"
  # After the restore, so the gate's containers are already down (an image a container uses is
  # kept, and a kept image is a failure here).
  add_plan VM vm-cleanup "remove what the night built on the VM (images, build cache)" 15 2 "$(vm_cleanup_script "$VM_DISK_START_KB")" "disk:|FAIL:"
}

build_mac_plan() {
  add_plan Mac mac-analyze "flutter analyze" 20 2 "flutter analyze" "issues|No issues"
  add_plan Mac mac-suite "the full test suite (server offline, TZ=UTC)" 45 5 "scripts/run_offline_suite.sh" "suite scope \\[|suite scope PASS|FAILED"
  # Task 11.326. A UTC-only night cannot see a date shown through the wrong zone: the held card
  # printed every deployment day as the day before east of UTC, green here for weeks. So the same
  # suite runs east (New Zealand, which also keeps daylight time) and west (Arizona, where the first
  # users are). About 2.5 minutes each, measured 2026-10-05.
  add_plan Mac mac-suite-east "the full test suite again, east of UTC (TZ=Pacific/Auckland)" 45 3 "TRITRACK_SUITE_TZ=Pacific/Auckland scripts/run_offline_suite.sh" "suite scope \\[|suite scope PASS|FAILED"
  add_plan Mac mac-suite-west "the full test suite again, west of UTC (TZ=America/Phoenix)" 45 3 "TRITRACK_SUITE_TZ=America/Phoenix scripts/run_offline_suite.sh" "suite scope \\[|suite scope PASS|FAILED"
  add_plan Mac mac-sync "the shared package's tests" 20 2 "dart pub get --directory packages/tritrack_sync >/dev/null && cd packages/tritrack_sync && dart test" "All tests passed|Some tests failed"
  add_plan Mac mac-generated "generated files are current" 20 3 "scripts/check_generated_files_current.sh" "generated-files check"
  add_plan Mac mac-clock "the clock matrix, three zones" 30 3 "scripts/clock_matrix_test.sh" "clock_matrix_test: (every|at least)"
  add_plan Mac mac-web-tools "website: its own tools analyze, and its drift check can still fail" 15 2 "dart pub get --directory website/tools >/dev/null && dart analyze website/tools && website/tools/selftest.sh" "No issues|PASS|FAIL"
  add_plan Mac mac-web-quotes "website: the guide still quotes the app correctly" 15 1 "dart run website/tools/check_app_quotes.dart" "PASS|FAIL|quote"
  # Task 11.332 item 4. `/w-36` put this in website.yml, which since 11.325 runs only by hand, so
  # nothing ran it. It fails if a committed theory figure (website/static/figures/) is not what the
  # script draws from the app's own numbers, or if the script's copy of the method no longer
  # reproduces the app. Under a second, measured 2026-10-10.
  add_plan Mac mac-web-figures "website: the theory page's figures are still the app's" 15 1 "dart website/tools/theory_figures.dart --check" "theory_figures:"
  add_plan Mac mac-web-build "website: Hugo builds" 15 2 "hugo --source website --destination '$RUN_DIR/site' --minify --cleanDestinationDir" "Total in|Pages"
  add_plan Mac mac-android "Android debug and profile builds, merged manifest checked" 60 15 "flutter build apk --debug && scripts/verify_merged_manifest_capabilities.sh && flutter build apk --profile && scripts/verify_merged_manifest_capabilities.sh build/app/intermediates/merged_manifest/profile/processProfileMainManifest/AndroidManifest.xml" "Built build|PASS|FAIL"
  add_plan Mac mac-ios "iOS build, without signing" 60 10 "flutter build ios --no-codesign" "Built build|Error"
  # Task 11.327. `flutter build macos` has no --no-codesign, so it signed with the free team and
  # failed every week that team's 7-day permission lapsed. Flutter passes any FLUTTER_XCODE_*
  # variable to xcodebuild as a build setting for this one command only, so the project's own
  # signing settings (macos/Runner/Configs/Signing.xcconfig), which Michael's Xcode uses, are
  # untouched. The result is still linker-signed ad hoc, which needs no team.
  add_plan Mac mac-macos "macOS build, without signing" 60 8 "FLUTTER_XCODE_CODE_SIGNING_ALLOWED=NO FLUTTER_XCODE_CODE_SIGNING_REQUIRED=NO flutter build macos" "Built build|Error"
  add_plan Mac mac-server "the server suite (here only when the VM half is skipped)" 60 6 "scripts/run_server_tests_docker.sh" "All tests passed|Some tests failed|PASS|FAIL" docker_on_mac_skip
  add_plan Mac mac-tile "tile-credit freshness (asks the three map providers; needs the network)" 20 1 "flutter test test/network --tags network --run-skipped" "All tests passed|Some tests failed"
}

tree_fingerprint() {  # what a build or a regeneration could have changed
  { git status --porcelain --untracked-files=no; git diff HEAD | shasum; } | shasum | cut -d' ' -f1
}

# ---------------------------------------------------------------------------
# --self-test: the runner's own broken-control. A night that cannot report a FAIL
# is not worth leaving alone, so this runs three fake steps through the real
# machinery -- one passes, one fails, one passes after it -- plus one that hangs
# past its limit, and requires the report to say so.
# ---------------------------------------------------------------------------
run_self_test() {
  STAMP="selftest-$STAMP"
  RUN_DIR="$repo_root/Claude outputs/local-ci/$STAMP"; LOG_DIR="$RUN_DIR/logs"; REPORT="$RUN_DIR/report.md"
  mkdir -p "$LOG_DIR"
  MAC_SHA="$(git rev-parse HEAD)"; MAC_SUBJECT="self-test (no real checks run)"; MAC_BRANCH="$(git branch --show-current)"
  start_awake
  say "Self-test: a keep-awake check, two fake steps and one that hangs. Step 2 will FAIL on purpose; the run must carry on."
  # The keep-awake claim, checked from inside the run: the step passes only if
  # `pmset -g assertions` lists THIS script's caffeinate by pid.
  add_plan Mac selftest-awake "pmset lists this script's caffeinate while it runs" 1 1 "pmset -g assertions | grep -A2 'pid ${CAFFEINATE_PID:-none}(caffeinate)'" "caffeinate"
  add_plan Mac selftest-pass "fake step that passes" 1 1 "sleep 2; echo all fine" "all fine"
  add_plan Mac selftest-fail "fake step that FAILS on purpose" 1 1 "echo 'ERROR: this failure is deliberate'; echo more detail; exit 3" "ERROR"
  add_plan Mac selftest-after "fake step AFTER the failure (proves the run carried on)" 1 1 "echo still running after a failure" "still running"
  add_plan Mac selftest-hang "fake step that hangs past its limit" 3s 1 "echo 'about to hang'; sleep 600" "about to hang"
  run_plan
  finish
  say ""
  say "Report: $REPORT"
  local want_fail want_timeout
  want_fail="$(grep -c '| \*\*FAIL\*\* |' "$REPORT")"; want_timeout="$(grep -c '| \*\*TIMEOUT\*\* |' "$REPORT")"
  if [ "$want_fail" -eq 1 ] && [ "$want_timeout" -eq 1 ] && grep -q '| \*\*PASS\*\* |.*still running after a failure' "$REPORT"; then
    say "SELF-TEST PASSED: the report shows the deliberate FAIL, the hang killed at its limit, and the step after the failure still ran."
    exit 0
  fi
  say "SELF-TEST FAILED: the report does not show what it should. Read $REPORT."
  exit 1
}

# ---------------------------------------------------------------------------
# --vm-no-sleep: setup step 1, done from the Mac so nothing is typed in the VM.
# NIGHTLY_SLEEP_VALUE exists so this can be shown working by setting the value the
# VM already has; it is not meant to be set.
# ---------------------------------------------------------------------------
vm_no_sleep() {
  local v="${NIGHTLY_SLEEP_VALUE:-nothing}" out rc
  out="$(vm "export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus
for k in sleep-inactive-ac-type sleep-inactive-battery-type; do
  gsettings set org.gnome.settings-daemon.plugins.power \$k '$v' || exit 1
  echo \"\$k is now \$(gsettings get org.gnome.settings-daemon.plugins.power \$k)\"
done" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then echo "Could not change the VM's setting (is the VM running? try: scripts/nightly_check.sh --preflight-only)."; exit 1; fi
  if [ "$v" = "nothing" ]; then echo "Done. The VM will no longer suspend itself when idle."; else echo "Done (set to '$v', which is not what a real night needs)."; fi
  exit 0
}

# ---------------------------------------------------------------------------
# --vm-install-dart: setup step 2. The server's own tests need `dart` on the machine
# that runs them, and the VM had none. This puts the SAME version this Mac builds with
# into the VM user's home folder (no sudo; nothing outside that folder changes; run it
# again after upgrading Flutter on the Mac to move the VM to the new version).
# ---------------------------------------------------------------------------
vm_install_dart() {
  local want out rc
  want="$(dart --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9.]*\).*/\1/p')"
  if [ -z "$want" ]; then echo "Could not read this Mac's Dart version (is dart on the PATH?)."; exit 1; fi
  echo "This Mac builds with Dart $want; putting that version on the VM (about 200 MB to download)."
  # No `set -e` in what runs in the VM: through prlctl, `set -e` followed by `exit 0` came back
  # as exit status 1 (measured 2026-10-04), so every step says `|| exit 1` where it matters.
  out="$(vm "want='$want'; dir=\"$VM_DART_DIR\"
have=\$(\"\$dir/bin/dart\" --version 2>&1 | sed -n 's/^Dart SDK version: \([0-9.]*\).*/\1/p' || true)
if [ \"\$have\" = \"\$want\" ]; then echo \"The VM already has Dart \$want at \$dir; nothing to do.\"; exit 0; fi
case \"\$(uname -m)\" in aarch64|arm64) arch=arm64 ;; x86_64) arch=x64 ;; *) echo \"Unknown VM processor \$(uname -m)\"; exit 1 ;; esac
tmp=\$(mktemp -d)
curl -fsSL -o \"\$tmp/dart.zip\" \"https://storage.googleapis.com/dart-archive/channels/stable/release/\$want/sdk/dartsdk-linux-\$arch-release.zip\" || exit 1
unzip -q \"\$tmp/dart.zip\" -d \"\$tmp\" || exit 1
rm -rf \"\$dir.new\"; mv \"\$tmp/dart-sdk\" \"\$dir.new\" || exit 1
rm -rf \"\$dir\"; mv \"\$dir.new\" \"\$dir\" || exit 1
rm -rf \"\$tmp\"
\"\$dir/bin/dart\" --version 2>&1 || exit 1" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then echo "The install did not finish (is the VM running, and does it have internet?). Nothing else was changed."; exit 1; fi
  echo "Done."
  exit 0
}

# ---------------------------------------------------------------------------
# --vm-clean: the night's own end-of-night clean-up, run by hand. The preflight names it
# when the VM's disk is low. It removes the same things and nothing else (see the comment
# above vm_cleanup_script), so it is safe to run with the real server up or down.
# ---------------------------------------------------------------------------
vm_clean() {
  local out rc
  out="$(vm "$(vm_cleanup_script "")" 2>&1)"; rc=$?
  printf '%s\n' "$out"
  exit "$rc"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  if [ "$VM_CLEAN" -eq 1 ]; then vm_clean; fi
  if [ "$INSTALL_DART" -eq 1 ]; then vm_install_dart; fi
  if [ "$NO_SLEEP" -eq 1 ]; then vm_no_sleep; fi
  # **The first act:** keep the Mac awake for exactly as long as this script runs.
  if [ "$SELF_TEST" -eq 1 ]; then run_self_test; fi
  mkdir -p "$LOG_DIR"
  start_awake

  # One night at a time.
  LOCK_DIR="${TMPDIR:-/tmp}/tritrack-nightly.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    local other; other="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
    if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
      say "Another nightly check is already running (pid $other). Two at once would fight over the VM's port and the Mac's processors."
      LOCK_DIR=""; exit 2
    fi
    rm -rf "$LOCK_DIR"; mkdir "$LOCK_DIR"
  fi
  echo $$ >"$LOCK_DIR/pid"

  if ! run_preflight; then
    RUN_STATE="refused by the preflight"
    finish
    say "Report: $REPORT"
    exit 2
  fi
  if [ "$PREFLIGHT_ONLY" -eq 1 ]; then
    RUN_STATE="preflight only"
    finish
    say "(--preflight-only: nothing was started. Report: $REPORT)"
    exit 0
  fi

  TREE_HASH_BEFORE="$(tree_fingerprint)"

  if [ "$SKIP_VM" -eq 0 ]; then
    # What the night must put back, read before it touches anything.
    VM_ORIG_REF="$(vm "cd '$VM_REPO' && (git symbolic-ref -q HEAD || git rev-parse HEAD)" 2>/dev/null | tail -n 1)"
    VM_REAL_CONTAINERS="$(vm "docker ps --filter publish=8080 --format '{{.Names}}'" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    VM_DISK_START_KB="$(vm "$(vm_free_kb_cmd)" 2>/dev/null | tail -n 1 | tr -dc '0-9')"
    build_vm_plan
  fi
  if [ "$SKIP_MAC" -eq 0 ]; then build_mac_plan; fi
  # The honesty line: did the night itself change the tree it was testing?
  add_plan Mac mac-tree-unchanged "the night left the working tree as it found it" 1 1 "[ \"\$(cd '$repo_root' && { git status --porcelain --untracked-files=no; git diff HEAD | shasum; } | shasum | cut -d' ' -f1)\" = '$TREE_HASH_BEFORE' ] || { echo 'FAIL: tracked files changed during the night (a build or check did it -- or you edited a file while it ran):'; git status --porcelain --untracked-files=no; exit 1; }" "FAIL|changed"

  if [ -n "$ONLY" ]; then
    # Re-count so the progress lines describe what will actually run.
    local k=0 t=0 c=0
    while [ "$k" -lt "${#PLAN_ID[@]}" ]; do
      if selected "${PLAN_ID[$k]}"; then t=$((t + ${PLAN_W[$k]})); c=$((c+1)); fi
      k=$((k+1))
    done
    TOTAL_W=$t; N_TOTAL=$c
  fi
  say ""
  say "Starting the night: $N_TOTAL steps, about $TOTAL_W minutes if all goes as usual. Report: $REPORT"
  write_report

  # Run in order. The VM plan marks itself prepared at its first step.
  local i=0 first_vm_done=0
  while [ "$i" -lt "${#PLAN_ID[@]}" ]; do
    if ! selected "${PLAN_ID[$i]}"; then i=$((i+1)); continue; fi
    if [ "${PLAN_ID[$i]}" = "vm-prepare" ]; then VM_PREPARED=1; fi
    run_plan_item "$i"
    if [ "${PLAN_ID[$i]}" = "vm-restore" ]; then
      # Its own step ran, so there is nothing for the exit path to repeat -- unless it failed.
      local last=$((${#STEP_STATUS[@]} - 1))
      [ "${STEP_STATUS[$last]}" = "PASS" ] && VM_RESTORED=1
    fi
    if [ "${PLAN_ID[$i]}" = "vm-cleanup" ]; then
      VM_CLEANED=1   # it ran; the exit path does not repeat it, even if it failed
      VM_DISK_NOTE="$(note_from_log "$RUN_DIR/${STEP_LOG[$((${#STEP_STATUS[@]} - 1))]}" '^disk:')"
    fi
    i=$((i+1))
  done

  finish
  local n=${#STEP_STATUS[@]} fails=0 k=0
  while [ "$k" -lt "$n" ]; do
    case "${STEP_STATUS[$k]}" in PASS|SKIPPED) ;; *) fails=$((fails+1)) ;; esac
    k=$((k+1))
  done
  say ""
  if [ "$fails" -gt 0 ]; then say "Done: $fails of $n steps FAILED. Report: $REPORT"; exit 1; fi
  say "Done: every step passed or was skipped on purpose. Report: $REPORT"
  exit 0
}

main

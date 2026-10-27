#!/usr/bin/env bash
# gate-instrument: none - an operator report about a live deployment; the part of it the gate can answer is audit_retention_status, which the gate runs directly.
# The one command an operator runs (task 11.140 / Security Model §4.9, §4.4,
# §4.7).
#
#   scripts/operator_status.sh
#
# ## Why one command and not three
#
# Michael's decision, 2026-09-02, asked where a warning should go when
# something on this server stops: **one operator health command** — over
# accepting three separate polls, over building an email sender, and over
# surfacing the answer to a project owner in the app.
#
# The three answers already existed separately, and the record is that nobody
# remembers to run three things. This needs no mail sender, no credentials and
# no new authenticated route. It collapses three things somebody has to
# remember into one they might actually run, and it gives any future push
# notification exactly one place to read from.
#
# **What it does not do is push. Nothing tells anybody.** That limit is
# accepted, and it is printed in the output below rather than left for somebody
# to discover — see `_boundary`.
#
# ## The rule this command lives or dies by
#
# **Every one of its first three inputs has a way of being unable to answer,
# and each one must say so distinctly.** The backup age cannot be read if the
# container cannot read the directory — task 11.125 measured exactly that, and
# found the scheduler reporting *freshness unknown* while the host-side script
# said *50 hours old*, same program, different identity. The rate-limit count
# needs the database, which is the thing question 2 exists because it goes
# away.
#
# **A summary that folds "I could not check" into "nothing to report" is worse
# than the commands it replaces**, because it turns an honest silence into a
# confident lie. So every section ends in one of exactly three verdicts, and
# `COULD NOT CHECK` is never spelled the same way as `OK`:
#
#   OK              the question was answered and the answer is good news
#   PROBLEM         the question was answered and the answer is bad news
#   COULD NOT CHECK the question was not answered at all
#
# Exit status carries the same distinction for questions 1-3, because
# something reading this later will read the status and not the prose:
#
#   0  all three answered, nothing wrong
#   1  at least one PROBLEM (a known fault outranks an unknown, because it is
#      the more actionable of the two)
#   2  no PROBLEM, but at least one COULD NOT CHECK
#
# **Question 4 is exempt from all of that, deliberately, and this is where
# that decision is written down** (task 11.163). A pinned row — one whose
# `revision` no honest edit could produce — is an accepted risk of write
# access under Security Model §4.30, recorded rather than refused. Refusing
# it would need a ceiling on the value, and §4.30 rejects that: a ceiling high
# enough to be safe does not stop the pin, and one low enough to stop it
# strands a legitimate field record. So question 4 uses the same three words
# above for readability, but **its verdict never appears in `$ALL` below and
# can never change the exit status** — finding one, or being unable to check
# for one, is worth printing and never worth failing the command over.
#
# ## It has to work with the database down
#
# That is when two of the three questions matter most, so **nothing here
# connects to Postgres before asking anything.** Question 1 reads a directory
# (`--no-deps`), question 2 reads a file (`--degradation-report`, which is the
# whole point of task 11.129's record), and question 3 uses `docker compose
# exec` rather than `run` — deliberately, so that **a stopped database is
# reported as a stopped database instead of being started by the command that
# came to ask about it.** A status command that changes what it measures is not
# a status command.
#
# ## Why a command and not a screen
#
# The diagnostics console is loopback-plus-token gated and off by default
# (§4.10) because it is reachable over the network. This is not: it is run by
# whoever is already on the host, with the Docker socket, and it therefore
# needs no gate of its own and adds no authenticated route to the server. That
# is the cheaper and the smaller of the two, so it is the one that was built.
#
# ## Its last words are its finding (CLAUDE.md, established by task 11.69)
#
# The boundary paragraph is printed before the summary, not after it, so the
# last lines of this command are always the three verdicts.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

. scripts/lib/load_env.sh

# The same seam `scripts/audit_retention_status.sh` opened for the gate stack.
#
# `--progress quiet` is the one addition, and it is here rather than in
# `backup_status.sh` because it is a property of the composite: the backup
# check builds its image (cached, about a second) and Buildkit's progress
# output is forty lines of layer names. Run on its own that is fine; run as one
# of three sections it buries the sentence the section exists to print, which
# is the same failure as an instrument whose last words are its own name.
COMPOSE=${COMPOSE:-"docker compose --progress quiet"}

# How long any one probe may take before it is reported as unanswered rather
# than waited on. A `docker compose run` against a server image that predates
# the flag it is passed would otherwise start a server and sit there forever;
# an operator status command that hangs has answered nothing.
PROBE_TIMEOUT_SECONDS=${TRITRACK_STATUS_TIMEOUT:-120}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- Running a probe without letting it take the command with it -----------
#
# `timeout(1)` is GNU coreutils and is not on a stock macOS, which is the
# machine this is most often typed on, so the wait is done here. Exit 124 is
# borrowed from `timeout` and means the same thing.
PROBE_OUT=""
PROBE_RC=0
_probe() {
  local seconds="$1"
  local command_line="$2"
  local out="$WORK/probe.out"
  local rcfile="$WORK/probe.rc"
  : >"$out"
  rm -f "$rcfile"
  # The exit status goes to a file rather than through `wait`: the probe may
  # have to be killed, and a status read from disk means the killed and the
  # finished paths are read the same way instead of relying on how long the
  # shell keeps a reaped job's status around.
  { bash -c "$command_line" >"$out" 2>&1; echo $? >"$rcfile"; } &
  local pid=$!
  local waited=0
  while [ ! -f "$rcfile" ]; do
    if [ "$waited" -ge "$seconds" ]; then
      pkill -TERM -P "$pid" 2>/dev/null || :
      kill -TERM "$pid" 2>/dev/null || :
      sleep 1
      pkill -KILL -P "$pid" 2>/dev/null || :
      kill -KILL "$pid" 2>/dev/null || :
      # Reaped explicitly, with stderr closed, so the shell's own "Terminated"
      # job notice does not land in the middle of an operator's report.
      wait "$pid" 2>/dev/null || :
      PROBE_OUT="$(cat "$out" 2>/dev/null || :)"
      PROBE_RC=124
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  PROBE_RC="$(cat "$rcfile")"
  PROBE_OUT="$(cat "$out" 2>/dev/null || :)"
}

# --- Verdicts ---------------------------------------------------------------
BACKUP_VERDICT=""
DEGRADATION_VERDICT=""
RATE_LIMIT_VERDICT=""
# Reported, never included in $ALL below — see the header on why question 4
# cannot change the exit status.
PINNED_ROWS_VERDICT=""
# Set when question 2 found lost audit writes, because that changes what
# question 3's silence is allowed to mean.
AUDIT_WRITES_LOST=0

_indent() { sed 's/^/    /'; }

_section() {
  echo
  echo "$1"
  echo "${1//?/-}"
}

# =============================================================================
# 1. Is there a recent backup?  (task 11.78, §4.9)
# =============================================================================
_question_backups() {
  _section "1. BACKUPS — is there a recent archive of this server's database?"

  _probe "$PROBE_TIMEOUT_SECONDS" "COMPOSE='$COMPOSE' scripts/backup_status.sh"
  printf '%s\n' "$PROBE_OUT" | _indent

  if [ "$PROBE_RC" = 0 ]; then
    BACKUP_VERDICT="OK"
    return
  fi

  # `freshness.sh` exits 1 for all three of its bad outcomes, because Docker's
  # healthcheck has one failing value, so the sentence is what carries the
  # difference. These two literals are therefore a dependency on a file this
  # one does not own — the class CLAUDE.md records from task 11.125, where a
  # refactor deleted a line another file was patching and nothing said so.
  # `server/test/security/operator_status_test.dart` asserts both still exist
  # in `server/backup/freshness.sh`, so a rewording fails a test rather than
  # silently downgrading "I cannot read the directory" to "backups have
  # stopped".
  if grep -q 'BACKUP FRESHNESS UNKNOWN' <<<"$PROBE_OUT"; then
    BACKUP_VERDICT="COULD NOT CHECK"
    echo
    echo "    -> COULD NOT CHECK. The container cannot read the backup"
    echo "       directory, so the age of the newest archive was not measured."
    echo "       This is NOT the same as having no backups, and it is NOT the"
    echo "       same as being fine. Nothing above says whether any archive"
    echo "       exists. The usual cause is ownership: run scripts/server_up.sh,"
    echo "       which prints the scheduler's uid beside the directory's owner."
    return
  fi

  if [ "$PROBE_RC" = 124 ]; then
    BACKUP_VERDICT="COULD NOT CHECK"
    echo
    echo "    -> COULD NOT CHECK. The backup check did not finish"
    echo "       within ${PROBE_TIMEOUT_SECONDS}s and was stopped. No age was measured."
    return
  fi

  if grep -q 'NEWEST BACKUP IS\|NO BACKUP HAS EVER BEEN TAKEN' <<<"$PROBE_OUT"; then
    BACKUP_VERDICT="PROBLEM"
    return
  fi

  # An exit code with none of the sentences the check is supposed to end on.
  # That is the check failing to run — Docker absent, a build that did not
  # finish, a compose file that will not parse — and it is not evidence about
  # backups either way.
  BACKUP_VERDICT="COULD NOT CHECK"
  echo
  echo "    -> COULD NOT CHECK. The backup check itself failed to run"
  echo "       (exit $PROBE_RC) and reported no age. Nothing above is evidence"
  echo "       about whether backups are being taken."
}

# =============================================================================
# 2. Was anything refused because the database was unreachable?  (task 11.129)
# =============================================================================
_question_degradation() {
  _section "2. OUTAGES — was anyone refused because the database was unreachable?"

  # `exec` first: it is instant when the stack is up, which is the common case,
  # and it is the line server/README.md already gives. `run --no-deps` is the
  # fallback, and it is the one that matters — it answers with the server
  # container stopped and with Postgres stopped, because the record is a file
  # on a named volume and reading it needs neither.
  _probe "$PROBE_TIMEOUT_SECONDS" \
    "$COMPOSE exec -T server /app/bin/server --degradation-report \
       || $COMPOSE run --rm --no-deps -T server --degradation-report"
  printf '%s\n' "$PROBE_OUT" | _indent

  if [ "$PROBE_RC" = 124 ]; then
    DEGRADATION_VERDICT="COULD NOT CHECK"
    echo
    echo "    -> COULD NOT CHECK. The report did not finish"
    echo "       within ${PROBE_TIMEOUT_SECONDS}s and was stopped. If this deployment's"
    echo "       server image predates the --degradation-report flag, the"
    echo "       fallback container starts a server instead of answering;"
    echo "       rebuild with 'docker compose build server'."
    return
  fi

  if [ "$PROBE_RC" != 0 ]; then
    DEGRADATION_VERDICT="COULD NOT CHECK"
    echo
    echo "    -> COULD NOT CHECK. Neither the running server nor a throwaway"
    echo "       container could read the durable record (exit $PROBE_RC)."
    echo "       Nothing above says whether sign-ins were refused."
    return
  fi

  # The three states `describeDegradationRecord` distinguishes, in its own
  # words. Missing and unreadable are BOTH unanswerable: that function says so
  # itself — "this does NOT mean nothing has failed", "treat the history as
  # lost, not as empty" — and folding either into OK is the exact defect this
  # command exists to avoid.
  if grep -q 'No durable record at' <<<"$PROBE_OUT"; then
    DEGRADATION_VERDICT="COULD NOT CHECK"
    echo
    echo "    -> COULD NOT CHECK. There is no durable record to read, so"
    echo "       nothing here says whether the database has ever been"
    echo "       unreachable. The record only exists from the first healthy"
    echo "       start after task 11.129 shipped."
    return
  fi

  if grep -q 'could not be read' <<<"$PROBE_OUT"; then
    DEGRADATION_VERDICT="COULD NOT CHECK"
    echo
    echo "    -> COULD NOT CHECK. The record exists and could not be parsed."
    echo "       Treat the history as lost, not as empty."
    return
  fi

  if grep -q 'The audit log LOST' <<<"$PROBE_OUT"; then
    DEGRADATION_VERDICT="PROBLEM"
    AUDIT_WRITES_LOST=1
    return
  fi

  DEGRADATION_VERDICT="OK"
}

# =============================================================================
# 3. Is the sign-in rate limit tripping?  (task 11.130, §4.4)
# =============================================================================
#
# **This reports. It does not tune.** Michael settled the size on 2026-09-02 —
# three sign-in link requests per address per fifteen minutes, "that sounds
# about right" — so a reading here is not an argument for changing the number.
# What it is for is the situation task 11.130 found: somebody who taps resend a
# fourth time is answered "sent" and receives nothing, on purpose (§4.5 forbids
# varying that response), and the audit row is the only place that situation is
# visible to anybody at all.
#
# No address is named. The count of distinct addresses separates the two cases
# that matter — one impatient person, or a flood — without putting anybody's
# email in an operator's terminal.
_question_rate_limit() {
  _section "3. SIGN-IN — is the per-address rate limit turning people away?"

  local sql
  sql="SELECT
         count(*) FILTER (WHERE occurred_at > now() - interval '24 hours'),
         count(*) FILTER (WHERE occurred_at > now() - interval '7 days'),
         count(DISTINCT email) FILTER (WHERE occurred_at > now() - interval '7 days'),
         coalesce(max(occurred_at)::text, '')
       FROM auth_audit_log WHERE event = 'rate_limit_tripped'"
  sql="$(printf '%s' "$sql" | tr '\n' ' ')"

  # `exec`, never `run`: see the header. A status command must not start the
  # database it came to ask about.
  _probe "$PROBE_TIMEOUT_SECONDS" \
    "$COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -qAt -F '|' \
       -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"$sql\""

  if [ "$PROBE_RC" != 0 ] || [ -z "$PROBE_OUT" ]; then
    RATE_LIMIT_VERDICT="COULD NOT CHECK"
    printf '%s\n' "$PROBE_OUT" | _indent
    echo
    if [ "$PROBE_RC" = 124 ]; then
      echo "    -> COULD NOT CHECK. The query did not finish"
      echo "       within ${PROBE_TIMEOUT_SECONDS}s and was stopped."
    else
      echo "    -> COULD NOT CHECK. The database did not answer"
      echo "       (exit $PROBE_RC). This count lives in Postgres and there is no"
      echo "       honest way to give it without one — a database that is down"
      echo "       is exactly why question 2 above exists. Zero rows were NOT"
      echo "       observed; no rows were read at all."
    fi
    return
  fi

  local line day week addresses last
  line="$(printf '%s' "$PROBE_OUT" | tail -n 1)"
  day="$(printf '%s' "$line" | cut -d'|' -f1)"
  week="$(printf '%s' "$line" | cut -d'|' -f2)"
  addresses="$(printf '%s' "$line" | cut -d'|' -f3)"
  last="$(printf '%s' "$line" | cut -d'|' -f4)"

  echo "    Refusals in the last 24 hours: ${day:-0}"
  echo "    Refusals in the last 7 days:   ${week:-0} (across ${addresses:-0} address(es))"
  echo "    Most recent:                   ${last:-none}"
  echo "    The limit is 3 sign-in link requests per address per 15 minutes."
  echo "    A refused request is still answered 'sent' and no link goes out, so"
  echo "    the person sees nothing at all. That is §4.5 working as designed"
  echo "    and it is still somebody who cannot sign in."
  echo "    Rows older than 365 days are deleted by the retention sweep (§4.7)."

  if [ "$AUDIT_WRITES_LOST" = 1 ]; then
    echo
    echo "    NOTE: question 2 reported lost audit writes. During that period"
    echo "    the rows this count reads were never written, so a low number"
    echo "    here is not evidence that nobody was refused."
  fi

  if [ "${day:-0}" -gt 0 ] 2>/dev/null; then
    RATE_LIMIT_VERDICT="PROBLEM"
    echo
    echo "    -> Somebody was turned away in the last 24 hours."
  elif [ "${week:-0}" -gt 0 ] 2>/dev/null; then
    RATE_LIMIT_VERDICT="OK"
    echo
    echo "    -> Nothing in the last 24 hours. There were refusals earlier in"
    echo "       the week; if that address is a person who told you they could"
    echo "       not sign in, this is why."
  else
    RATE_LIMIT_VERDICT="OK"
  fi
}

# =============================================================================
# 4. Is any row pinned with a revision no honest edit could produce?
#    (task 11.159, Security Model §4.30)
# =============================================================================
#
# **This reports. It does not refuse, and it cannot fail the command** — see
# the header. A pinned row wins every future merge against it, so a
# teammate's later correction is reported to them as "Unchanged (local was
# newer)" forever, and the only other way to see this today is `GET
# /diagnostics/revision-anomalies`, a console kept off by default (§4.10).
# This is the fourth `_question_` function on the same `docker compose exec
# postgres psql` path question 3 already uses — no second way in.
#
# `observed_as = 'blocking'` rows are the ones that matter most here: they are
# pins that predate this detector, caught only because a later push lost to
# them (see revision_anomaly_log.dart). Counting them separately says how
# many of the total were sitting there unnoticed rather than freshly arrived.
_question_pinned_rows() {
  _section "4. PINNED ROWS — is any row's revision beyond what any honest edit could produce?"

  local sql
  sql="SELECT
         count(*),
         count(*) FILTER (WHERE observed_as = 'blocking'),
         coalesce(max(last_seen_at)::text, '')
       FROM revision_anomalies"
  sql="$(printf '%s' "$sql" | tr '\n' ' ')"

  # `exec`, never `run`: see the header. A status command must not start the
  # database it came to ask about.
  _probe "$PROBE_TIMEOUT_SECONDS" \
    "$COMPOSE exec -T postgres psql -v ON_ERROR_STOP=1 -qAt -F '|' \
       -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"$sql\""

  if [ "$PROBE_RC" != 0 ] || [ -z "$PROBE_OUT" ]; then
    PINNED_ROWS_VERDICT="COULD NOT CHECK"
    printf '%s\n' "$PROBE_OUT" | _indent
    echo
    if [ "$PROBE_RC" = 124 ]; then
      echo "    -> COULD NOT CHECK. The query did not finish"
      echo "       within ${PROBE_TIMEOUT_SECONDS}s and was stopped."
    else
      echo "    -> COULD NOT CHECK. The database did not answer"
      echo "       (exit $PROBE_RC). This count lives in Postgres and there is no"
      echo "       honest way to give it without one. Zero pinned rows were NOT"
      echo "       observed; no rows were read at all."
    fi
    return
  fi

  local line total blocking last
  line="$(printf '%s' "$PROBE_OUT" | tail -n 1)"
  total="$(printf '%s' "$line" | cut -d'|' -f1)"
  blocking="$(printf '%s' "$line" | cut -d'|' -f2)"
  last="$(printf '%s' "$line" | cut -d'|' -f3)"

  if [ "${total:-0}" -eq 0 ] 2>/dev/null; then
    PINNED_ROWS_VERDICT="OK"
    echo "    No row on this server carries a revision no honest edit could"
    echo "    produce. This is a live check, not the absence of one — the"
    echo "    server has looked and found nothing."
    return
  fi

  PINNED_ROWS_VERDICT="PROBLEM"
  echo "    Rows carrying an unexplainable revision:      ${total}"
  echo "    Of those, found only by blocking a later edit: ${blocking:-0}"
  echo "    Most recently seen:                            ${last:-none}"
  echo
  echo "    -> Each of these rows wins every future merge against it, so a"
  echo "       teammate's correction there is reported to them as 'Unchanged"
  echo "       (local was newer)' with nothing telling them why. This is an"
  echo "       accepted risk of write access (Security Model §4.30) and it"
  echo "       does NOT change the exit status below — it is worth knowing,"
  echo "       not worth failing the command over. Full detail, including"
  echo "       which table and which row, is at GET"
  echo "       /diagnostics/revision-anomalies (§4.10, off by default)."
}

# =============================================================================
# What this is not
# =============================================================================
_boundary() {
  _section "WHAT THIS COMMAND DOES NOT DO"
  cat <<'EOF'
    It does not tell anybody. There is no email, no push, no alert. It answers
    only when you type it, and a server that stops between two runs is invisible
    for as long as that gap lasts. That limit was accepted deliberately when
    this command was chosen over building a mail sender, and it is printed here
    so it is never a surprise.

    It is a snapshot of four things and not a monitor of everything: backup
    freshness, lost audit writes during a database outage, the sign-in rate
    limit, and rows carrying a revision no honest edit could produce. It says
    nothing about disk space, certificate expiry, whether the audit retention
    sweep is running (scripts/audit_retention_status.sh), whether a scheduled
    project deletion is overdue (scripts/project_destruction_status.sh),
    whether deleted records are being purged after their 24-month window and
    what the next purge would refuse (scripts/tombstone_retention_status.sh),
    whether anything has been copied off this machine (nothing has — task
    11.80), or whether the server is reachable from a phone.

    Question 4 is also the one question here that can never fail the command
    (see the header on §4.30): finding a pinned row is printed, never a
    reason for a non-zero exit.
EOF
}

# =============================================================================
# 0. Which machine is this about?  (task 11.141)
# =============================================================================
#
# Everything below is a verdict, and a verdict without a subject is useless
# once it is pasted somewhere else: a run on a laptop against a throwaway
# stack reads exactly like a run on the beta server. Task 11.140's own first
# real output proved it — a 17-day-old backup and six lost audit writes, most
# likely about a local test stack, and unprovable from the output alone.
#
# So this is read from the thing being measured, never typed. The host name
# says where the *script* ran; `docker compose config` says which stack it was
# pointed at and where the backup directory it read actually lives on that
# host — and task 11.125 already found a case where a host-side answer and a
# container's own view disagreed, same program, different identity. Nothing
# here is a config value someone could forget to change on a second machine.
_identity() {
  local host project_name backup_host_dir

  host="$(hostname 2>/dev/null || uname -n 2>/dev/null || echo "unknown")"

  # `config`, not `ps`: it answers from the compose file(s) $COMPOSE resolves
  # to whether or not the stack is currently up, which is exactly the
  # condition question 1 and question 2 above must also survive.
  _probe "$PROBE_TIMEOUT_SECONDS" "$COMPOSE config --format json"
  local config_json="$PROBE_OUT"
  local config_rc="$PROBE_RC"

  project_name=""
  backup_host_dir=""
  if [ "$config_rc" = 0 ]; then
    project_name="$(printf '%s' "$config_json" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("name", ""))
except Exception:
    pass
' 2>/dev/null)"
    # The backup and backup-scheduler services both bind-mount the same host
    # directory to /backups (docker-compose.yml); either tells the same fact.
    backup_host_dir="$(printf '%s' "$config_json" | python3 -c '
import json, sys
try:
    services = json.load(sys.stdin).get("services", {})
    for name in ("backup-scheduler", "backup"):
        for vol in services.get(name, {}).get("volumes", []) or []:
            if vol.get("target") == "/backups":
                print(vol.get("source", ""))
                raise SystemExit
except Exception:
    pass
' 2>/dev/null)"
  fi

  echo "TriTrack operator status — $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "Host:             ${host}"
  if [ -n "$project_name" ]; then
    echo "Compose project:  ${project_name} (from 'docker compose config' — the stack these answers are about, not just the machine they were asked from)"
  else
    echo "Compose project:  COULD NOT BE DETERMINED — 'docker compose config' did not answer (exit $config_rc). Everything below is still about SOME stack; this line cannot say which."
  fi
  if [ -n "$backup_host_dir" ]; then
    echo "Backup directory: ${backup_host_dir} on the host, bound to /backups inside the backup containers — this is the directory question 1 below reads."
  else
    echo "Backup directory: COULD NOT BE DETERMINED from 'docker compose config'."
  fi
  echo
  echo "Four questions, asked in one command. Each answers separately, and a"
  echo "question that could not be answered says so rather than reading as fine."
}

_identity
_question_backups
_question_degradation
_question_rate_limit
_question_pinned_rows
_boundary

_section "SUMMARY"
printf '    %-34s %s\n' "1. Recent backup?" "$BACKUP_VERDICT"
printf '    %-34s %s\n' "2. Refusals during an outage?" "$DEGRADATION_VERDICT"
printf '    %-34s %s\n' "3. Sign-in limit turning people away?" "$RATE_LIMIT_VERDICT"
# Deliberately not part of $ALL below — see the header on §4.30. Printed here
# because an operator reading the summary should see it beside the other
# three, not because it can move the exit status.
printf '    %-34s %s\n' "4. Any row pinned (revision)?" "$PINNED_ROWS_VERDICT"

# Question 4 is not in $ALL: it is a §4.30 accepted risk that reports and
# never fails the command (see the header). Its own line above already says
# so; this line is what a reader sees last, so it says so again there rather
# than letting a clean exit read as "nothing above is worth a look."
if [ "$PINNED_ROWS_VERDICT" = "PROBLEM" ]; then
  echo
  echo "Question 4 found at least one pinned row (see above). It does not"
  echo "affect the line below — §4.30 records this risk rather than refusing"
  echo "it, so it cannot change what this command exits with."
fi

ALL="$BACKUP_VERDICT|$DEGRADATION_VERDICT|$RATE_LIMIT_VERDICT"
echo
case "$ALL" in
  *PROBLEM*)
    echo "SOMETHING IS WRONG — at least one question was answered and the answer is bad."
    exit 1
    ;;
esac
case "$ALL" in
  *"COULD NOT CHECK"*)
    echo "AT LEAST ONE QUESTION COULD NOT BE ANSWERED — this is not a clean bill of health, it is a gap."
    exit 2
    ;;
esac
echo "The three questions that can fail this command were answered and none of them found a problem."
exit 0

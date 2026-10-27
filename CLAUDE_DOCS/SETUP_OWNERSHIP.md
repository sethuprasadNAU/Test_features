# One file owns each setup step

**Task 11.52, carried by task 11.40, 2026-08-29.**

A setup step is a thing a person must do to get something running: install X,
set variable Y, run command Z, generate key A. **Each one has exactly one
owning file. Every other mention points at the owner rather than repeating
it.**

**Why.** A pointer that goes stale is a broken link — annoying, and obvious.
**A copy that goes stale is wrong instructions somebody follows.** Task 11.38
replaced "copy the template and fill in your Team ID" with a command that
writes the file, and `Signing.xcconfig.example` still carried the old
instruction — *the instruction 11.38 was reported for was sitting untouched in
the one place the README believed it had closed.* Task 11.37 fixed that
instance and tested that one sentence. This file is the class.

## The guard

`test/documentation/setup_step_ownership_test.dart` reads the table below at
run time and, for each row, searches the tree for that row's **signature**. It
fails when:

- the signature appears in a file that is neither the owner nor listed under
  "Copies allowed, and why" — *a new copy has appeared*; or
- the owner does not contain its own signature — *the step has moved out of
  its owner and every pointer now points at nothing*; or
- an allowed file no longer contains it — *the exemption is stale and should be
  deleted, because an exemption nobody can justify is how the next copy gets
  waved through.*

**Watched to fail, 2026-08-29**, in all three directions, before it was
believed.

### What the guard does not read

Three files are excluded from the search because they are **append-only
records of what was said at the time**, not instructions anybody follows:
`DEVELOPMENT_PLAN.md`, `TriTrack_Security_Model.md` and `TASK_COMMS.md`.
Rewriting history in them to satisfy a guard would be falsifying the record.
This document is excluded too, since it has to quote every signature.

---

## The table

| Step | Owner | Signature | Copies allowed, and why |
| --- | --- | --- | --- |
| Run the end-to-end suite | `scripts/run_e2e_tests.sh` | `flutter test test/e2e` | `README.md` — the hand-assembled version, kept deliberately and under a heading that says to use the script; it is how a failure gets diagnosed one step at a time. `CLAUDE_DOCS/SECURITY_SCOPE_AND_EXIT.md` — quotes the broken form as the cautionary example. `test/e2e/support/e2e_env.dart` — the error a person sees when the variables are missing, which must be actionable at that moment. `test/e2e/e2e_coverage_guard_test.dart` and `dart_test.yaml` — narrative explaining why the tag configuration is what it is. |
| One-time setup for the nightly check (stop the Ubuntu VM suspending itself; SSH is no longer needed, `prlctl` is the default, task 11.325 round 2) | `scripts/nightly_check.sh` (`--setup` prints it, one step at a time) | `--vm-no-sleep` | None. Every other mention points at `scripts/nightly_check.sh --setup`; task 11.325. |
| Load `.env` in a script | `scripts/lib/load_env.sh` | `copy .env.example to .env and fill it in first` | None. This was seven byte-identical eight-line blocks until this task; there is now one. |
| Generate the backup encryption identity | `server/README.md` | `age-keygen -o` | `server/backup/backup.sh` — runs it, rather than telling anybody to. |
| Generate the backup signing key | `server/README.md` | `minisign -G -W` | `server/backup/backup.sh`, `scripts/backup_restore_drill.sh` and `scripts/verify_h6_archive_forgery.sh` — all three generate throwaway keys in code as part of a drill; none is an instruction to a person. |
| Sign the macOS build | `README.md`, "Signing the macOS build" | `find-certificate -c "Apple Development"` | None. `macos/Runner/Configs/Signing.xcconfig.example` carried a verbatim second copy of the command and now points instead. |

**Guarded rows are the ones above.** The rows below are ownership decisions
without a signature the guard can search for — usually because the step is
prose rather than a command, and a substring that matched it would also match
every sentence about it.

| Step | Owner | Why it is not guarded |
| --- | --- | --- |
| The source-identity verdict → `TRITRACK_TRUSTED_PROXIES` / `TRITRACK_PROXY_SOURCE_IDENTITY` | `scripts/verify_source_identity.sh`'s own header for *what licenses the value*; `README.md`'s "Steps that stay manual" for *why it is not automated* | Described in several operator-facing files at once — **the list is derived and printed by `server/test/security/source_identity_warning_test.dart` on every run, so read that rather than a total here.** (This cell used to say "seven files" and name six; task 11.212 removed the total, which was never maintained and named neither `docker-compose.yml` nor `proxy/Caddyfile`.) **This is the largest remaining duplication in the repository and it is deliberately not collapsed here** — every one of those copies sits next to the variable it governs, and a person editing `.env` who is sent to another file to learn that the value is a claim about their own network is a person who will set it without reading. Consolidating it is real work with a real risk of making the control easier to get wrong. Recorded as Discovered Scope rather than done badly. |
| Copy `.env.example` → `.env` | `.env.example`'s own first two lines | Every mention is already a pointer or a `${VAR:?...}` at the point of use. |
| Start the server stack | `README.md` §"Server" | — |
| Point the app at the server | `README.md` §5 | — |
| Get the LAN address | `scripts/dev_lan_address.sh` | Already converted by task 11.37; the script prints the value. |
| Get the magic link | `scripts/dev_magic_link.sh` | Same. |
| TLS termination setup | `server/README.md` §"TLS termination" | — |
| Diagnostics console | `server/README.md` §"The diagnostics console" | **Owner moved by task 10.80**, which wrote the full procedure (variables, token generation, the nine routes, the SSH tunnel, the five startup refusals) where the rest of the server's operator documentation lives. `README.md` §"Diagnostics console" is now a pointer at it. |
| ~~Schedule the audit purge and backup retention~~ | — | **No longer a setup step.** Task 11.78 made the backup a `backup-scheduler` service and task 11.79 made the purge an `audit-retention` service; `docker compose up` starts both, and each is measured by the thing it produces rather than by whether its timer exists. |
| Dependency review | `server/README.md` §"Dependency audit" | — |
| The pre-commit suite hook | `scripts/pre_commit_suite.sh`'s own header for *what it runs and what it deliberately leaves to CI*; `.claude/settings.json` for *the wiring* | **There is no install step, which is the point of the row.** The hook is a `PreToolUse` entry in `.claude/settings.json`, and that file is committed — so it arrives with a clone and there is nothing for a person to do or forget. No `core.hooksPath` is set and no `.githooks/` directory exists; **task 11.182 established the fallback was not needed** by watching the hook run rather than by arguing about it. Two things can tell you whether it is working: `test/documentation/claude_hook_scripts_test.dart` asserts the wiring and that the script refuses a payload it cannot read, and the script appends a line per commit to `${TMPDIR}/tritrack-precommit-trace.log` — **because a `PreToolUse` hook's output is not shown to the window that triggered it, and task 11.181 concluded from that silence that it was dead.** It binds commits made by this project's Claude windows only, never one typed into a terminal by hand. **Task 11.325 (2026-10-02):** it also runs `flutter analyze` for a commit that takes Dart, and `scripts/lib/commit_scope.py` works out what a `git commit -- <path>` will actually take, so an unstaged generated file is no longer committed unchecked. |

---

## The four copies this task removed

All four were **live hazards**: each could be executed and each was wrong.

1. **`server/README.md`** spelled `flutter test test/e2e --tags e2e` with
   neither environment variable and without `--run-skipped`. **This is the
   document the security gate reads, and the ninth gate round fell into it.**
   Now names the script.
2. **`dart_test.yaml`'s skip message.** The worst of the four, because
   *`package:test` prints it at the operator* at the exact moment they are
   trying to run the suite — the "error message that printed the wrong
   command" shape task 11.37 was written for, one layer down. Now names the
   script.
3. **`test/e2e/support/e2e_env.dart`** carried two copies of the invocation
   twenty-six lines apart, and **the second had already gone stale** — it
   omitted `--run-skipped`, so copying it produced "All tests skipped" and exit
   0. Now points at the script.
4. **`docker-compose.e2e.yml`** spelled the `docker compose ... up` line
   without the `-p tritrack-e2e` that finding M-12 makes load-bearing. **A copy
   that omits the part which makes it correct is worse than no copy.**

---
description: "Task 11.80 — the server's backup never leaves the machine it backs up; the design assumes it does"
model: opus
---

Implement task **11.80** from `CLAUDE_DOCS/DEVELOPMENT_PLAN.md`. **Check whether Michael
has chosen a destination before building anything** — that is his decision.

**What the archive covers and what it does not.** `backup_db.sh` dumps, encrypts, signs and
writes into a folder **on the same machine**. That covers a corrupted database, a bad
migration, a botched restore. **It does not cover losing the machine**, and the machine is
a virtual machine on one laptop.

**What is at risk, measured:** the server holds fourteen tables that also live on devices
**and ten that live nowhere else** — accounts, sessions, magic links, link requests, the
sign-in audit log, invitations, sync cursors, the sequence counter, the traffic log and the
tombstone floor. **Losing the machine does not lose field data**; it loses every account,
every session, the audit trail, outstanding invitations, and **the numbered line every
device's bookmark points into** — task 11.58's failure by a different road.

**Why it is a gap rather than a choice:** the archive is **encrypted to a key that
deliberately does not live on the server** and signed against forgery. **That only makes
sense if the file goes somewhere the server cannot read.** Something was meant to carry it;
nothing does.

## Measured on the beta host 2026-09-12, and it adds two requirements

**The scheduler had been failing every cycle for ten days.** `backup_status.sh` read *"NEWEST BACKUP
IS 10 DAYS OLD (240h) — backups have stopped being taken"*. Cause: the stack was raised with a raw
`docker compose up` instead of `scripts/server_up.sh`, so the container ran as the wrong uid — the
ownership failure 11.70 and 11.78 documented, through the one door left open. One command fixed it.

**`docker compose ps` had read `backup-scheduler (unhealthy)` the whole time, and the container's
log named the cause and the remedy.** The instruments were right and loud. **They were addressed to
a surface nobody reads on a schedule.** That is not a check that cannot fail — it is **a check that
fails correctly into a place with no reader**, and this task now has to answer it.

1. **Whatever carries the archive off the host must carry the *failure* off the host too.** A
   destination that silently receives nothing for ten days reproduces this outage with one more
   machine in it. **Where the absence arrives is a question for Michael in the same breath as the
   destination** — ask both together, do not pick one.
2. **Restate the recovery window as the age of the newest archive**, not as "nightly". §4.9 and
   `server/README.md` describe the loss on the assumption of a schedule that was not running; for
   ten days the true answer was *everything since 2 September*. `backup_status.sh` already prints the
   honest quantity.

**This does not re-scope the task.** The destination is still the resume point and still Michael's.

**Say plainly that this does not reverse Michael's 2026-08-30 decision to remove the app's
cloud backup.** That removed **unencrypted project data, on by default, to a third party.**
This is an archive encrypted to a key the destination does not hold, signed, moved
deliberately. **Different propositions — write that down so nobody reads one as undoing the
other.**

**A third, small item found on Michael's server 2026-08-31: the failure message names the
right cause and prescribes a remedy that does not fix the commonest case.** His first
backup failed with `cannot create a file in /backups`; the message correctly explained the
uid/gid mismatch and why a laptop differs from a server, then offered **one remedy — use
`scripts/server_up.sh` rather than a raw compose line. He had used it.** The directory was
root-owned from a bare `docker compose up` **predating task 11.70**, whose chosen shape
fixes new installations and **leaves existing ones stranded with no instruction.**

**Not a message naming the wrong cause — that was 11.70's finding. A message naming the
right cause with an incomplete remedy**, which is worse in one way: the reader follows it
exactly, fails again, and starts doubting the diagnosis too. **Add the missing branch** —
if the directory exists and is owned by somebody else, say so and give the one-line
`chown` — **plus a line in `server/README.md` for installations predating 11.70.**

**Two non-negotiables, both from tasks that just ran:**

- **Measure the copy, not the command** — task 11.78's lesson. Check that a recent archive
  **exists at the destination**, in 11.78's four-sentence shape: fresh, stale, absent, or
  unreachable.
- **The restore drill exercises the off-machine copy, or says it does not.** Task 11.70
  restored that link after 11.69 quietly made the drill measure a variant. **A copy nobody
  has restored from is a belief, not a backup.**

Then re-read `CLAUDE.md`'s "Reporting results" section, including appending your entry to
`CLAUDE_DOCS/TASK_COMMS.md`.

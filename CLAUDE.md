# TriTrack — Claude Code Project Instructions

This file loads automatically at the start of every Claude Code session in
this repo. Read it before starting substantial work.

## Planning/execution split

Architecture and task planning for this project happen in a separate Claude
session (Opus, via the Cowork desktop app), which reads and writes files
directly in this repo but does not run or build code here. That session
maintains **`CLAUDE_DOCS/DEVELOPMENT_PLAN.md`** as the single source of truth
for what to build next, in what order, and with what acceptance criteria.
Claude Code (this session) is the execution layer.

**Before implementing any non-trivial task:**

1. Read `CLAUDE_DOCS/DEVELOPMENT_PLAN.md` and find the task's entry (by task
   ID if invoked via a `/task-*` slash command, or the current phase's
   top not-started task otherwise).
2. Follow that entry's spec and acceptance criteria. If something in the
   plan is ambiguous or turns out to be wrong once you're in the code,
   don't silently improvise around it — note the discrepancy (see below)
   and ask, or make the smallest reasonable judgment call and flag it
   clearly in your summary.
3. **Skim the numbered defect-vocabulary index in "Reporting results" below, and
   open `CLAUDE_DOCS/DEFECT_VOCABULARY.md` at any entry close to what you are
   about to do.** Those 109 lines are the mistakes this project has already paid
   for; most of them were found the second or third time. **Read that file whole
   before a sweep, before building or changing an instrument, and before any
   change to a rule.**
4. On completion, update that task's `Status` field in the plan
   (Not started → In progress → Done, or → Blocked with a one-line reason).
5. If you discover new work that isn't in the plan (missing edge case,
   follow-up cleanup, a dependency that needs its own task), append it
   under that phase's **"Discovered Scope"** subsection rather than just
   doing it silently or leaving it undone. Don't invent new top-level
   phases yourself — that's the planning session's call.

**A dependency also belongs at the top of the task's own entry, not only in the run
table.** The planning session hands Michael a table of commands and **he runs them in
the order they appear** — that is what a table is. A row saying "after task N" in its
description column while sitting above task N is an instruction that contradicts its own
layout, and it has sent the wrong task to a fresh window twice: `/w-04` on 2026-08-31,
and `/11-89` on 2026-09-01, which was started and stopped before it wrote anything.
**So: a task that is blocked does not appear above the task blocking it, and its plan
entry says so in its `Depends on:` line where Claude Code will read it before starting.**
Rule established 2026-09-01, after the second occurrence.

## Model selection

Tasks invoked via a `.claude/commands/<task-id>.md` slash command already
pin the right model in that file's frontmatter — just run `/<task-id>`,
you don't need to set it yourself. If you're working ad hoc (no slash
command), the project default in `.claude/settings.json` applies; check
the plan doc's per-task model recommendation and switch with `/model` if
the ad hoc task is architecture-sensitive (auth/security design, the
sync/merge engine, algorithm-correctness work) rather than routine feature
wiring.

## How the planning session hands Michael a queue — the task table

**Michael, 2026-09-14: "this task table format is perfect. Please remember it
going forward."** Every time the planning session gives him the outstanding
work, it gives him this table and nothing else:

| Command | Model | Effort | Session | Goal |
|---|---|---|---|---|

- **Command** — the slash command, `/11-249`. If there is no command file, the
  row does not belong in the table yet; write the file first.
  **The case that breaks this rule is a task Claude Code filed rather than one
  the planning session wrote.** A task the planning session invents gets its
  command file in the same breath as its plan entry; a task filed out of another
  task's findings arrives as a plan entry alone, and the number in the report
  reads exactly like a number that is ready to run. **Filing a task is not making
  it runnable.** Broken on 2026-09-17: tasks 11.276 and 11.277 were put in
  Michael's table straight from task 11.275's report, and he found out by typing
  `/11-277` and being told there was no such command. Before a filed task enters
  the table, `ls .claude/commands/` — do not answer from the fact that you just
  read its entry.
  **Broken a second time on 2026-09-18, three days later, in the same table — and
  by a different route, which is why the rule needed widening rather than
  re-reading.** `/w-13` and `/w-10` had command files once and **the content lane
  deletes a command file when its task closes** (`command_file_staleness_test.dart`
  enforces it). So a number that has appeared in this table before is not evidence
  a file exists now. **The check is `ls`, every time, for every row — not only for
  rows that look new.** Michael caught it by asking why two rows had no Goal, which
  is the second tell: **an em-dash in the Goal column is a blank pretending to be a
  cell.** A row whose goal cannot be written from the plan entry is a row whose
  command file has not been read, and therefore probably does not exist.
- **Model** and **Effort** — what the command file's frontmatter pins, restated
  so he can see the cost of the queue without opening ten files.
- **Session** — **the column that earns the table**, and it is about the Claude
  Code window, not the task. Three values and they mean different things:
  - *Fresh window* — nothing from an earlier task helps; start clean.
  - *Follows `/11-245`* — the previous task's loaded context is genuinely
    useful here, so running it in the same window saves re-reading.
  - *Fresh window, **alone*** — this task is one where a half-remembered
    detail from a neighboring task is a real risk, not just noise.
- **Goal** — one line, in the plain English the reporting rules already
  require. What a person gets, not what the code does.

**Order the rows the way he should run them**, and say in a sentence below the
table what is deferred, what is waiting on a trigger, and what is on his own
list rather than Claude Code's. The content lane keeps its own separate table —
**"let's try to keep the content and programming task tables separate"**
(2026-09-07).

## Project orientation

See `README.md` for build/run instructions and architecture overview, and
`CLAUDE_DOCS/TriTrack_Technical_Context.md` / `CLAUDE_DOCS/TriTrack_Design_Document.md`
for the full data model, algorithms, and screen-level design decisions.
`CLAUDE_DOCS/DEVELOPMENT_PLAN.md` is the one to treat as authoritative for
*what to work on right now*, though — the other docs describe the whole
product's intended shape, not the current sprint.

## GitHub's checks are paused; the local batch is the check

**Since 2026-10-02 (task 11.325)** every GitHub workflow starts only when somebody presses *Run
workflow* (the website's publish still runs on a push that changes `website/**`), because the code
changes many times a day. **The check is `scripts/nightly_check.sh`, run from the Mac:** a preflight
while Michael is awake, then the VM's gate, its self-test, the drills and the server suite (reached
through `prlctl`, not SSH), then the Mac's analyze, full suite, builds and
website checks, ending in one report at `Claude outputs/local-ci/<date-time>/report.md`. A task's
"CI is green" evidence is therefore its own local run, and a green GitHub tick means nothing until the
triggers are restored (`RELEASE_CHECKLIST.md` row B0). The pre-commit hook also runs `flutter analyze`
for any commit that takes Dart, and now reads `git commit -- <path>` by what it will actually commit.
**Upgrading Flutter on the Mac has one checklist: `README.md`, "Upgrading Flutter (and the Dart that
comes with it)"** — the command, the files to expect to change, `scripts/nightly_check.sh --vm-install-dart`
so the VM's Dart matches (the preflight warns if they differ), then one night green with the tree unchanged.

## Git hygiene

Commit at the end of any working session that leaves the repo in a clean,
buildable state — don't let uncommitted work pile up. `INVENTION_DISCLOSURE/`
and any file matching `~$*` are intentionally untracked (see `.gitignore`);
don't try to add them.

## Starting a new planning session

**Read `CLAUDE_DOCS/SESSION_HANDOFF.md` first, then `CLAUDE_DOCS/TASK_COMMS.md`** —
the second carries what Claude Code has asked the planning session for and not yet
had answered, and the planning session moves each entry into that file's "Resolved"
section with one line saying what it did. The handoff is orientation rather than
authority — where it disagrees with `DEVELOPMENT_PLAN.md`, the security model, or
`SECURITY_SCOPE_AND_EXIT.md`, those win. But it carries the things a fresh session
cannot reconstruct from the files: which decisions are settled and why, the defect
classes that keep recurring on this project, and the mistakes the planning session has
already made once.

## Michael's standing design decisions — do not brief a task that reopens one

**Both sessions read this before proposing or briefing any change to an existing control.** Each
entry is a decision Michael made, in his words where he gave them. A measurement against a general
standard (contrast, size, word count) is **not** an instruction to change a control he has already
decided; report the number, and change nothing.

1. **The map-type switch (Terrain / Street / Satellite) keeps its blurred halo and its white
   unselected labels.** Its unselected labels measure 1.7–2.7 : 1 against real tiles, and that is
   accepted. **Do not add a panel, outline or other treatment, and do not treat a contrast under
   4.5 : 1 on those labels as a defect.** Michael, 2026-09-30: *"The user knows the options and
   doesn't need it to be perfectly readable because it is when the option is selected and its
   background turns green. The black outline now makes the map less visible."* Reopened twice by
   the planning session against his wishes: task 11.106 added a panel (removed by 11.190), and
   task 11.319 item 4 added an outline (reverted in `6437e53`).
2. **Screenshots are captured on all three profiles (iPhone 6.1, iPhone 6.9, iPad 13)** until he
   says otherwise (2026-09-29), although the guide shows only the 6.9.
3. **TriTrack is moving to one central server, not a server per project or per lab** (2026-10-02).
   Michael: *"We are moving to a central server not a project specific server deployment."* So
   nothing the app or the guide says should send a person to "whoever runs your server"; it sends
   them to TriTrack support. The app ships with the central server's address filled in, and it can
   still be changed (for testing).
4. **A deployment's attached and removed days are the field site's days, read in a project time zone**
   (2026-10-06, task 11.331). Each project has a time zone, defaulting to the zone at the centre of its
   area, confirmed by the creator and changeable later; each deployment row keeps the zone it was written
   in. **Do not convert deployment days to plain dates** — weighed and rejected the same day (bearing
   matching still needs a zone, old values cannot be converted without guessing, and it does not fix the
   form's "today"). Michael asked for the trade-offs to be thought through before deciding.
5. **Position estimates use citable, standard methods only; no new localization methods for now**
   (2026-10-07). Michael: *"I want citable standard methods deployed on the app for now. Remember, this is a field
   tool for quick localization first and a field data recorder. People can always export TriTrack data later and do
   all sorts of post processing … For now I want people using this to just trust it because it is aligned with the
   current standards."* So the estimate stays Lenth's (1981) maximum likelihood with the chi-square 95% ellipse White &
   Garrott (1990) use; its known weakness with few bearings is **documented and cautioned, not corrected** by a scale of
   TriTrack's own (an F × n/(n−2) scale was measured by task 11.334 and set aside). Improvements found along the way are
   recorded in task 11.337 for a later release. **Do not brief a change to the estimator, κ or the ellipse scale unless it
   is a published method that can be cited exactly, and Michael has asked for it.**

**How the planning session avoids the next one:** before briefing a change to an existing control,
search `DEVELOPMENT_PLAN.md` and this list for that control's name and its widget's name. A search
built from remembered phrasings is a sample (see "A scope exclusion is a claim about what is out
there").

## Reporting results — how every task ends

**Michael is a wildlife biologist who writes research scripts. He is not an
application or security developer, and he reads every one of these reports.** A
report he cannot act on has not been delivered, however accurate it is.

This applies to both sessions — the planning session's messages and Claude
Code's task summaries.

### Show progress while you work

**Michael starts long tasks and wants to know roughly how much time is left.** So every task, at
its start, writes its steps into its task checklist with a rough weight for each (reading is quick;
the full test suite, the screenshot run and the VM gate are slow). **After each step, print one
line:**

`Progress ▓▓▓▓▓░░░░░ 50% — step 4 of 8 done: <what>. Next: <what> (usually ~N min).`

- The percentage is by weighted steps, not by clock. **Before any step that usually takes more than
  a few minutes, say how long it usually takes**, from past runs if you know them.
- **When the plan grows, say so on the same line** ("added 2 steps: a failing test to
  investigate"), so the bar does not jump backwards without a reason.
- In a batch of tasks, prefix the task: `[/w-32 · 2 of 3] Progress ▓▓░░░…`.

### End every report with "What you need to do"

A numbered list of actions for Michael, in the order he should do them. If there
are none, write **"Nothing — this is complete."** Do not leave it out and do not
imply it.

It must cover, when true:

1. **Git** — did you commit? Does he need to push?
2. **A plan or task change** — did you find something that means a task should
   be updated, added, or re-scoped? **Say so directly: "ask the planning session
   to add X to task 11.3."** Do not describe a gap and leave him to infer that
   somebody should act on it.
3. **A decision only he can make** — name the choice and the options.
4. **Something only he can run** — a physical device, a second machine, an
   email, a network he has access to and you do not.
5. **A risk he is now carrying** — if the task leaves something knowingly open,
   say what could go wrong and to whom.

**The failure this rule exists to prevent:** task 11.1 correctly found that
membership inserts need their own permission check and correctly recorded it in
Discovered Scope — and its report described the seam without ever saying "task
11.2 and 11.3 need updating." The information was right there and the action was
invisible. That is the same shape as a finding written down as "Open" with no
task number, which cost two blocking items six weeks.

### Enumerating a derivation's implementations is not enumerating the screens that should call it

**Added 2026-09-17, on the third instance.** Task 11.251 counted **six** implementations of "which
animal was this tag on", unified them, and pointed every reader it found at one function. **What it
counted was implementations — which are greppable. What it could not count was every place that
*should* be asking the question and is not**, because that is a judgement about what a screen is
claiming, not a pattern in the source.

**The shape is always the same and it has now happened three times: the filter gets fixed and the
color does not.**

- **The Map**, task 11.247 — the animal filter moved to the per-moment derivation; `_tagColor` had
  never been per-ray at all, and the follow-up found it only because Michael's phone showed a bearing
  in the wrong animal's color.
- **The Map again**, the same week, one layer in — the legend.
- **The Log**, task 11.272 — `_SubjectFilter.admits` calls the derivation correctly; **every swatch
  on the screen still reads the collar's current owner**, and no row names the animal at all.

**So when a task unifies a derivation, the list to produce is not "who calls this function".** It is
**"what does each screen claim about this subject, and does its claim need this answer"** — a color,
a name, a sort key and a filter are four separate claims, and fixing one of them does not fix the
others. **Write that list, per screen, and say which claims you checked.**

### Name the shape, not the call site — a provider's defect may live in what it reads

**Added 2026-09-16, from task 11.236.** The brief named four providers to fix, and one of them —
`mayWriteProjectDataProvider` — **was already safe in its own body.** The `ref.watch`-after-`await`
was one level down, in `myProjectStanding`, which it depends on. The task found it and said so.

**The brief had named the provider a person meets, not the provider that is wrong.** That is the
right thing to report a defect *by* and the wrong thing to write a fix *against*: a task told to fix
four named files can fix four named files and leave the cause standing one level below.

### When a change widens what the data can say, re-read the decisions made because it could not

**Added 2026-09-16.** On 2026-09-14 Michael ruled that on a handover day the Record wheel should
list both collars — *"I guess they both should be listed for that one day"* — and task 11.249 built
it. **That was correct, and its correctness depended entirely on a deployment knowing only calendar
days.** On 2026-09-15 task 11.251 gave a swap a **time**, and nothing re-read the ruling: the Log,
the Map's filter and the Map's color all moved to asking by the moment, and **the wheel was left
asking by the day for two days, with nobody noticing.**

**This is the correct-when-written-then-silently-falsified class, applied to a decision rather than
a comment** — and it is worse there, because a stale comment misleads a reader while a stale
decision keeps being implemented.

**So when a task widens what the data can express, the decisions worth re-reading are the ones that
exist *because* it could not.** Name them in the task's report. A rule whose justification was *"the
app cannot tell"* is exactly the rule that a task making the app able to tell has just orphaned.

> **And the planning session defended the stale rule with an invented example rather than checking.**
> I argued for the whole-day rule with a bearing taken two hours after the collar came off — which is
> a bearing on the collar in somebody's bag. **Michael asked one question and it collapsed.** The
> fallback defense I would have reached for next, entering a morning bearing after lunch, **also did
> not survive contact with the code**: the Record screen stamps `DateTime.now()` and there is no
> backdating. **Check the mechanism before defending the rule that rests on it.**

### Striking a status word does not remove it — strikethrough is invisible to a scanner

**Found by the planning session 2026-09-16, and it had already happened twice, both times mine.**
`command_file_staleness_test.dart` deletes-by-failing: a command file for a `Done` task fails the
suite. **Its classifier reads a status paragraph as prose and takes the re-runnable word first** —
deliberately, because task 11.80's status says `PARTIAL` in one sentence and *"is done"* in another
about a different half.

**So a corrected status that keeps its old word inside `~~strikethrough~~` still reads as
re-runnable.** Tasks 11.245 and 11.247 were both `Done` for a day with live command files, because
I amended their Status lines in the house style — new verdict first, old one struck — and the struck
`Partial` is the word the classifier found. **The check missed them in exactly the direction its own
doc comment says it misses**, so nothing was red and nothing said anything. Both files are deleted.

**When correcting a Status line, do not leave the superseded status word in the paragraph.** Put the
history in a sentence that contains no status word at all — *"held at the device look until
2026-09-15"* rather than *"~~Partial~~"* — or delete the command file in the same edit and do not
rely on the check to notice.

**And a second correction landed on the same area the next day, from task 11.256.** Task 11.235
wrote that `await ref.watch(x.future)` is *"the safe form"*, and the planning session carried that
forward as settled. **It is safe only with respect to its own `await`** — a second one after it runs
after the first gap and *is* the hazardous shape, which is what 11.236 had already fixed in two
providers without anyone noticing the sentence was now wrong. **A phrase that was true of one case
became a rule about a family**, and nothing checked. It is pinned by fixtures now, in both readings.

**So when a brief names a suspect, name the shape and let the task locate it** — *"this shape, found
from the code, wherever it lives"* — and where a specific symbol is named, say whether it is the
site the symptom appeared at or the site the defect lives in. **They are the same thing only by
luck.**

### When a test is red, decide whether the test or the code is wrong — before touching either

**A red test and the function it exercises are two candidates for the same
defect, and only one of them can be examined afterwards.** Make the test green
first and the question stops being askable: the evidence that it was ever open
is the failure, and the fix deletes it. So the order is fixed — name which one
is wrong, in writing, with what was read to decide it, and only then edit.

**A nil finding closes it just as well as a positive one**, and is worth writing
down at the same length. "The production function is exact for every value
anything actually writes, and here is the grep" is a result; silence followed by
a fixed test is not.

**This is not a rule about tests.** It is the general shape: whenever a failure
has two plausible owners and repairing one erases the failure, the ownership
question goes first. Same reason the project watches a fix go red before it goes
green — a check that was never seen to fail has not been seen to work.

Established 2026-09-17, tasks 11.276 and 11.277. Ten tests failed under
`TZ=UTC`; the obvious read was that `deploymentDateFor`, the function that turns
*now* into a collar's date, mishandled zones. One read of its class comment and
one grep of `lib/`, `server/lib/` and `packages/*/lib/` showed **no production
code anywhere builds a deployment date any other way** — the fixtures were
writing a shape no device has ever produced. Had the ten tests been fixed first,
a correct production date function would have been changed on the strength of a
test file, and nothing would have remained to say otherwise.

### A layout defect is loud in a test and silent on the phone — so “it looks slightly off” is a test question first

**Flutter's overflow and geometry complaints live inside `assert()` blocks,
which a release build compiles out.** The same broken widget therefore has two
completely different symptoms: in `flutter test` and `flutter run` it throws a
wall of red; in the build Michael actually carries into the field it renders
**quietly wrong** — unequal widths, a squashed row, a control slightly off — and
nothing is logged, because nothing failed.

**So when a field report says something looks a bit off, the first move is to
run that screen's widget test, not to go looking on the phone.** The fastest
diagnosis for a symptom that has no error message is the build that still has
one.

**No new checklist item for this, deliberately.** The instruments already catch
it — `flutter test` is where this one was found — and asking Michael to walk a
release build hunting for subtle wrongness is asking a person to do badly what a
test does well. What was missing was the *diagnosis*, and that is what this rule
is.

Established 2026-09-17, task 11.274: three separate symptoms in two of Michael's
debug logs (the map-layers card, the info box, and scrolling) were one broken
`SegmentedToggle` subtree. The task confirmed from the Flutter SDK source that a
release build would not have crashed — it would have drawn three segments at
unequal widths and said nothing.

### A “Depends on” line is a claim about code, and it gets read before it is written

**The planning session writes the dependency line, and it is the one line in a
brief nobody verifies** — Claude Code takes it as given and opens the window it
names. Writing *“depends on 11.272 for a helper it may share”* from the memory
that 11.272 touched the same screen is the same error as writing a count from
names: **an assertion produced by recognition rather than by reading.**

**Open the file and confirm the thing exists before naming it as a dependency.**
If it cannot be confirmed, say what is actually known — *“11.272 touched this
screen; check what it left before you start”* is honest and just as useful.

Broken 2026-09-17, task 11.274. The brief named a helper from 11.272; no such
helper existed, and the answer was `Tag.individualName`, a model field that had
been there all along. **It cost nothing this time** — which is exactly why it is
worth writing down, because the version that costs something looks identical
while it is being written.

### A rule checked one row at a time cannot approve a change that is only valid as a pair

**An invariant enforced per record will refuse a correction that fixes two
records together**, because it asks about the row just written against the row
not yet written — a state that exists only between two writes and that nobody
ever intended to store. The person is then stuck: the refusal is correct about
each half and wrong about the change, and there is no order in which to make the
two edits that avoids it. **A refusal with no way forward is a trap**, which this
project already knows; this is the shape that manufactures one out of a rule that
is otherwise right.

**The fix is not to relax the rule.** It is one write that checks the invariant
once against **both rows' final values** and then stores both. Where such a write
already exists, start there rather than opening a fresh transaction beside it — a
second path through the same invariant is a second answer to it.

**And the tell, before it becomes a bug report:** whenever a screen offers a
correction that only makes sense on two rows at once, ask which rule is going to
see the halfway state. The answer is rarely "none".

Established 2026-09-17, task 11.270. Correcting a past-day collar handover where
both ends were still bare days deadlocked the deployment interlock — each row's
own check refused the pair that is fine once both land.
`DeploymentLinking.applyHandover` is the paired write, and the four screen routes
that can reach the deadlock all share one derivation
(`bareDayHandoverPartner`) rather than four copies of the question.

### A closed task's number is closed — leftover work comes back as a new number

**`command_file_staleness_test.dart` holds a command file and a task's status to
the same claim: a command exists only while its task is still runnable.** A
website task's status is read from its `WEBSITE_COMMS.md` heading, and a numbered
task's from its `Status:` line. So **writing a command file for a task whose
entry says `Done` turns the suite red**, and stays red until one of the two
changes.

**Do not fix that by re-opening the old entry or by softening its status.** Both
make the record lie about what happened. **Give the leftover work a new number**,
and let its entry carry the history — *“the analysis `/w-10` was owed and never
got”* says more than a resurrected `/w-10` ever could, and it leaves `/w-10`'s own
report true.

Broken 2026-09-18. The planning session wrote command files for `/w-13` and
`/w-10`, both of which had closed weeks earlier, **and the red landed on somebody
else**: `/w-13`'s window had to commit through the pre-commit escape hatch
(`TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1`) for a failure the planning session
had created. **A guard that fires on the right thing, at a person who cannot fix
it, is a cost this session imposed and should have foreseen** — the test's own
doc comment says exactly what it checks.

### Run `command_file_staleness_test.dart` after writing a command file, before committing

**Not “remember the format”. Run the check.** Three separate breaks of this one
guard — 2026-09-17 (`/11-277`, no file at all), 2026-09-18 (`/w-13`, `/w-10`, files
for closed tasks), 2026-09-18 again (`/w-20`, a `description:` the id regex could
not read) — and **every one of them landed as a red suite on a Claude Code window
that had to commit through the pre-commit escape hatch for a failure it did not
cause.**

Three breaks in three different ways is one missing step, not three careless
moments. The rules written after the first two both said *be careful*, and being
careful failed twice. **The command takes two seconds and has never been run
once.**

The format, since it is cheap to state: `description:` must contain the literal
word `Task` followed by the id — `Task 11.280 — …` or `Task /w-20 — …` — and it
must agree with the id encoded in the filename.

**Fourth break, 2026-09-20, and this one had nothing to do with the format.**
Task 11.289 was filed, committed, described to Michael in detail, and put at the
top of his table — **with no command file written at all.** He found out by
typing `/11-289`. That is the same failure as 2026-09-17's `/11-277`, three days
after the rule was written and two days after it was widened.

**So the step moves earlier: the command file is written in the same tool call
as the plan entry, not after it.** A plan entry is a description of work; a
command file is the only thing that can start it, and **an entry without one is a
task that exists only in this session's head.** The `ls` check catches it at the
table; writing both together means there is nothing to catch.

### “Did it happen at all” comes before “how long did it take”

**When a wait times out on a state something was supposed to reach, do not fork
the brief between a fast explanation and a slow one.** Both assume the state was
never produced. **Instrument the producer first.** A third possibility — it was
produced correctly and something else undid it — is invisible to every timing
hypothesis and to any number of re-runs.

Established 2026-09-18, task 11.280. The brief this session wrote offered *“a real
slow-down”* or *“an always-slow path”*. Neither was true: the sync round classified
the state correctly and instantly, and a different provider re-inserted a stale
row on the very next screen build. **One `print` at the classification site
settled it in a single run**; the two hypotheses in the brief would not have found
it in a hundred.

### An acceptance criterion that assumes a result is a prediction, not a criterion

**Write what the task must *establish*, not what you expect it to find.** A
criterion phrased as an outcome cannot be satisfied by the truth if the truth is
different, so it either forces a bad change or gets quietly reported as missed —
and in both cases the planning session's guess has outranked the measurement.

**The shape to write instead:** *“measure X and report it, whichever way it
comes out”*, plus a named thing to do if it comes out badly.

Broken 2026-09-18, task `/w-21`. Its acceptance said **“each diagram earned a
deletion”** — an assumption, written by this session, that a diagram always
replaces prose. Two of the three sat in front of an idea the page **had never
explained at all** (`managing-your-tags.md` used the word *deployment* once, in
passing; `sync.md` had no page-level statement of the state machine). Those pages
got **longer**, and they should have. The task reported the growth plainly rather
than rounding it away, which is the only reason the wrong criterion is visible.

**The earlier instance, same shape:** tasks 11.245 and 11.250 were given
`check_app_quotes` green as a criterion while being forbidden to edit the guide
that would make it green. **Two tasks, identical facts, different reported
statuses — that disagreement was the tell.**

**Third instance, 2026-09-18, task `/w-22`, and it is the numeric variant: a
target is a prediction too.** The brief said *“cut `rather than` by at least
two-thirds”* — a number this session picked without reading the instances. The
task read all 44, cut the two that were filler, and left the rest, because most
are real mechanism distinctions a field tech needs (`Bounce?` versus
`Malfunctioning`; a GPS fix versus a point placed by hand). **It came in at 11%
and explained why, which is the right outcome.** The same brief also said not to
chase the numbers into bad prose — so the brief contained both the target and its
own refutation, and the task obeyed the right half. **Write the diagnosis and the
judgement to apply; do not also write the answer.**

### A scope exclusion is a claim about what is out there, and it is written from a sample

**“Skip X” in a brief asserts that everything matching X is out of scope.** That is a
statement about the whole corpus, and it is usually written after looking at the
first few lines of a grep. **Count what you are excluding before you exclude it**,
or say *“I looked at N of them”* so the next reader knows what the fence is worth.

Broken 2026-09-18. Task 11.283's brief said *“`metre` is the only word in the list
where the match is usually a name rather than a sentence”* and excluded it.
**That was written from a three-line grep sample showing `aglMetres` and
`clearedFromMetres`** — two identifiers. There were **four user-visible sentences**
the sample never showed, and the task obeyed the fence correctly. Found by
`/w-24`, from the guide's side, a day later; now task 11.284. **The task did
nothing wrong, which is the point: a bad fence produces a correct task and a
wrong outcome.**

**Broken again 2026-09-21, by the planning session, and this variant is worth naming
separately: a grep written from the phrasings you expect is a sample of the document,
not a census of it.** Resolving task 11.295, I corrected three documents by hand and
reported them corrected. I had found the occurrences with a grep of three alternatives:
the number-word immediately followed by the noun, the "long-running" phrasing, and the
PDF's file name. (**None of the three is written out here** — see below.)
`NAU_infosec_review_request.md`'s
**draft email text — the actual quotable part, past the `---`** — states the old count
in a phrasing that puts one extra word between the number and the noun. **It is not
reproduced here**, for the reason entry 48 gives: `container_count_test.dart` counts
that shape wherever it appears and cannot tell a use from a quotation of one, so
writing the phrase into this rule turns the suite red. **It did** — the rule as first
written on 2026-09-21 quoted it, went red on `main`, and cost task 11.291 two commits
through the escape hatch before anybody read the failure. None of my three patterns
matched that phrasing. So the grep showed me two occurrences in a file that had three,
**I read only what it showed me, and I declared the file done.** Task 11.297 found it
while checking my corrections, which its brief told it to do.

**The tell is that I searched for the defect I had already seen rather than for the
thing the defect is about.** A pattern assembled from the phrasings you can remember
returns the occurrences you can remember. **When the subject is derivable — a count, a
file name, a version — search for the *subject* (`grep -i container` and read the
hits), or better, derive it and let a test find every copy**, which is what 11.297 then
built. Three hand corrections, two right: **the brief handing a task corrected files is
itself a claim, and this one says check them.**

### Deleting a closed task's command file: stage the deletion, do not just `rm` it

`command_file_staleness_test.dart` reads the **tracked** files under `.claude/commands/`. A plain
`rm` leaves git still listing the path, so the test tries to open a file that is no longer there
and fails with a `PathNotFoundException` — **a confusing failure that says nothing about the actual
mistake.** Use `git rm`, or `rm` followed by staging the deletion, before running the suite. Found
by task 11.309, 2026-09-22, while closing its own command file.

### Do not run `dart format` on this repository

**Nothing runs it.** Not a workflow, not a script, not the pre-commit hook — checked
2026-09-22. So the tree is not clean under the current formatter, and running it on a
file reformats that file **wholesale**: a one-line rename becomes a diff nobody can
review, and the change you actually made is invisible inside it.

**Two tasks hit this in two days and both did the right thing** — task 11.304 in
`member_authorization_test.dart` and task 11.305 in three sync test files. Each reverted
the reformat and applied its own edit by hand, and each said so in its report. That is
the behavior to repeat.

**So: format the lines you touched, to match the file around them, and leave the rest
alone.** If the repository's formatting is ever to be settled, that is a task of its own
with a deliberate one-time diff and a check added in the same commit — **not a side
effect of a task about something else.** A formatter with no check behind it is a
preference, and a preference must not be allowed to bury a finding.

### An instrument's own documentation is the one place the instrument does not look

**A guard's design document and its test file are almost always exempt from the guard**, and
for a good reason: they have to quote examples of the very shape the guard hunts, so
including them would make the instrument fail on its own explanation (entry 48). **The
consequence nobody writes down is that these two files rot faster than anything they
govern**, and they are the files a newcomer opens to learn the rule.

**Measured, 2026-09-21: the container-count guard was three days old and its own
documentation had held three stale numbers in that time** — the carve-out paragraph's
example, the prose naming today's service count, and a count in the test's doc comment.
Each was found by a person reading, never by a check, because no check can look there.

**Two things follow.**

**In an exempt file, describe the governed value instead of stating it.** "The phrasing
that puts one extra word between the number and the noun" cannot go stale; the phrase
itself can, and will. This is entry 48's discipline applied one level up — the same reason
the defect vocabulary describes a forbidden citation rather than reproducing one.

**A date stamp is not a staleness signal unless the value changes more slowly than dates
do.** *"As of 2026-09-21 that command prints six services"* was written on 2026-09-21 and
was already wrong that afternoon, because a second task added a service the same day. The
date was honest and useless. **When a value must appear in an exempt file, say where to
recompute it — the command, the derivation — so a reader who doubts it can settle it in
one step**, rather than dating a number and hoping the date is read as a warning.

**The same mechanism in source, 2026-09-21 (task 11.301), and there it is worse because the
comment reads as evidence.** `pending_departure.dart` carries *"Measured on 2026-08-29 against
the real server: a departure from a device that can reach the server is accepted on the first
attempt."* **True when written. False from 2026-09-13**, when task 11.237's new gate silenced
that push, until 11.301 restored it — and **nothing said so for eight days**, because a
measurement in a comment is never re-run. **A dated measurement certifies an instant, not an
interval**, and every reader after that instant treats it as a standing fact; a brief that
leans on "this already works, measured" is leaning on exactly this. **So: write the date, and
write beside it what would make it false** — here, "anything that changes which rows a
non-member may offer" — so the next task changing that thing meets the sentence it invalidates.

### An instrument that checks for a signature cannot hold a value that must be recomputed

**Before stretching an existing guard to cover a new case, ask what its mechanism can
express.** Task 11.52's `setup_step_ownership_test.dart` works by finding a fixed
signature substring and requiring the owning file to still contain it — presence,
checked. Task 11.297's container count is a number that must equal **what a shell
command prints today**, and no presence check can say that: the signature would have to
be rewritten every time the answer changed, which is the hand-maintained list the guard
exists to abolish.

**A value that is derivable and changes over time is a third category**, and neither of
11.52's tables has a column for it. It earns its own instrument rather than a stretched
row. Established 2026-09-21 (task 11.297), which was told to answer where 11.52's
boundary belongs and answered it in terms of mechanism rather than scope.

### The plan's `Status:` field is a claim, and it is the least maintained line in the entry

**A task is resolved in `TASK_COMMS.md`, and the plan entry's `Status:` is updated
separately — by hand, afterwards, by the same session that just wrote a long
resolution and considers the task finished.** So the field lags, and it lags in
the direction that matters: **an entry says `Partial` long after it is `Done`**,
and every survey of outstanding work counts it.

**Before reporting what is open, read each entry's status — do not parse it.**
The words `Partial`, `MERGED`, `Below the line` and `Done` all appear in bodies
as well as in fields, often about a different thing.

Caught 2026-09-20, surveying open work for Michael, **three times in one pass:**

- **11.245** — `Status: Partial`, with a resolution block directly beneath it
  settling the task as `Done` six days earlier.
- **11.225** — `Status: Partial — the phone has not run it`, while `TASK_COMMS.md`
  had recorded it `Done` nine days earlier, because the correct number of rows to
  repair on Michael's device was zero.
- **11.146 and 11.101** — both `Status: MERGED … and DONE there`, and both reported
  to Michael as *“deferred items worth promoting”* because the scan matched
  *“Below the line”* in the original text kept below the merge notice.

**The first two are the file's fault and are fixed. The third is mine** — the
status said `MERGED` and `DONE` in the line I was reading, and I classified from a
regex instead. **A survey is a measurement, and this one was a guess with a table
around it.**

### Count before deciding — including before asking Michael to decide

**Added 2026-09-11, after task 11.225.** *Count or measure before deciding* is this project's most
reliable habit; it has said "build" twice, "don't build" twice, and caught a wrong number more than
once. **It had only ever been applied to decisions the planning session took itself.**

**11.225 is what the gap costs.** A consequence of the tag fork was described to Michael in prose —
some "no signal" entries would show without their collar — and he was asked to choose. **Nobody
counted how many entries were affected on his device first. The answer was zero: he has no "no signal"
records at all.** One query would have turned the question from *"do you want this fixed?"* into
*"nothing is affected today — build it now, or when a device actually has one?"*, which is a
different question with a possibly different answer.

**The rule, extended: a decision put to Michael carries its number, or it is not ready to put to
him.** If the number is not known, the honest move is to say so and offer to get it — not to
describe the shape of a problem and let him choose in the dark. **He answers what he is asked**, so
an unmeasured question gets an unmeasured answer, and the cost lands on him.

> **The related error, same task, same day.** The planning session then told him the fix "should
> re-point 2 entries — what the fork already told you." **It had not.** The 2 came from that task's
> *test fixture*, which was built with two such rows so the repair could be watched working.
> **A number read off a test is not a measurement of anybody's data**, and handing one over as
> though it were is the failure this project spends most of its effort catching in other people's
> briefs.

### `Done` means a person has looked, when the acceptance says a person must

**Added 2026-09-11, after tasks 11.224 and 11.225 met the same situation and reported it
differently.** Both ended with work that only Michael's phone could confirm. **11.224 reported
`Partial` and named the phone as the open item. 11.225 reported `Done` while its own plan entry said
*"Michael's phone is the check and has not run this yet."*** Both were honest in their prose. Only one
was honest in its status field, and a status field that means two things is not a status field.

**The rule: if a task's acceptance names a device, a person, or a machine only Michael can reach,
the status is `Partial` until that has happened** — however green the suite is, and however complete
the code is. Write the remaining item as the last numbered entry under *"For Michael"*, and let the
planning session move it to `Done` when he reports back.

> **The suite is not the acceptance when the acceptance says otherwise.** 11.224's entire value was
> that it stopped on a real phone rather than mangling a real field season; a task in that family
> calling itself Done before anybody opened the app would be claiming exactly the thing this project
> spends its effort not claiming. **`Partial` is not a worse outcome than `Done`. It is a more
> accurate one**, and the planning session closes it in one line the moment he answers.

**And the acceptance must name a device whenever the task builds a control that destroys something,
or that undoes a destruction. ADDED 2026-09-15, and the omission was the planning session's.** Task
11.252 added a delete for a "no signal" record and an UNDO beside it; **its acceptance named no
device, so by the rule above it was entitled to report `Done` on a green suite** — and it reported
`Done` while writing, in so many words, that *"until you've looked, this task is more accurately
`Partial`"*, and offering to flip. **A task should not have to argue its way past its own
acceptance to be honest.** A widget test proves the confirmation says the right words; **only a
person proves that a mis-tap can be taken back.** So: when writing a task that adds or changes a
destructive control, put the device look in the acceptance, and when running one whose acceptance
forgot to, say so the way 11.252 did.

### A word is jargon if it only means something because of an earlier turn

**Added 2026-09-10, at Michael's request, after he said an explanation was much better than the ones
before it and asked what made the difference.**

**The failure is not technical vocabulary. It is shorthand this project coined.** Words like *the
flag*, *the mark*, *it does not stick*, *re-applied*, *the escape hatch*, *an assertion by absence*,
*a corner cluster*, *the clear band* are ordinary English, and **every one of them is opaque to
somebody who was not in the conversation where it was minted.** They feel like plain language from
the inside, which is exactly why they get through. **Test each one: would this word carry its meaning
to somebody reading this paragraph alone? If not, spend the sentence.**

**Four things made the explanation that worked:**

1. **Define the thing before using it, in his vocabulary.** Not *"the database"* but *"every bearing,
   note and estimate your team records is stored in one file on the phone."*
2. **One concrete example, carried all the way through.** *"A tech records 40 bearings in a canyon
   with no signal on Tuesday."* Then every consequence is stated about those 40 bearings — what a
   dropped phone costs, what a stolen account costs. **An example that changes between points is not
   an example, it is decoration.**
3. **State what is true today before what should change**, and separate them visibly. He cannot judge
   a proposal without knowing the starting position, and **more than once the starting position turned
   out to be the actual news** — a decision already taken on one platform that he had never been asked
   about.
4. **Say what is at stake in terms of his work**, not the system's internals: field records lost, or
   animal coordinates in somebody else's hands. **Not "an exposure" — the thing that is exposed.**

> **And the tell that this rule is being broken: the explanation gets shorter over a conversation
> while the subject does not get simpler.** That is compression into private vocabulary, not clarity.
> **Length is not the enemy. Unexplained shorthand is.**

### American spellings, in everything this project writes

**Michael, 2026-09-18:** *“you write with british spellings instead of american (color vs. color,
etc.). Please update throughout this project (website, all the md files, etc.) that you write with
american spellings, not british.”*

So: **color, behavior, center, organize, recognize, license, catalog, gray, analyze, normalize,
labeled, canceled, meter, defense, toward, while** — in app copy, on the website, in `CLAUDE_DOCS/`,
in commit messages, and in reports.

**Do not sweep by word stem — it corrupts words that share one.** The planning
session's own 2026-09-18 pass got this wrong **twice in one run**: `analys → analyz`
turned **analysis** into *analyzis* (25 times; *analysis* was already correct
American), and `centre → center` turned **centred** into *centerd*. Both were
caught by listing every word the diff introduced and reading it, **not by
spot-checking lines** — the first spot-check looked fine. **Match whole words, and
read the list of what you produced before you commit it.**

**Three exceptions, and they are about not lying rather than about style:**

- **A quote of the app's own words keeps the app's spelling.** If a string in `lib/` still says
  *license*, the guide's `{{< app >}}` quote says *license* too, and the fix is a code task. **A
  guide that misquotes the app to look tidy is worse than an inconsistent page.**
- **Identifiers, columns, keys and enum values never change for spelling.** `aglMetres` is a name,
  not a sentence; a stored value is a migration.
- **`CLAUDE_DOCS/DEVELOPMENT_PLAN.md` and `CLAUDE_DOCS/TASK_COMMS.md` were not swept**, by Michael's
  decision on 2026-09-18 — they are append-only history that only Claude reads, and 875 of the
  project's 1,221 British spellings were in those two files. **`WEBSITE_COMMS.md` was left with
  them**, being the same kind of file; say so if that should change. **New entries in all three use
  American spellings.**

### Write it in plain English

- **Lead with what changed**, in one sentence someone outside the project would
  understand. Mechanism after, not before.
- **Never use an identifier alone.** Not "L-2 is closed" but "a crafted project
  file could permanently destroy an observation by moving only its version
  counter — that is closed." Same for `§4.19`, `10.93`, `RowAuthorizer`. Name it,
  then say what it is.
- **Say what breaks for a person**, not which property was violated. "A
  teammate's correction is silently discarded" beats "the merge tiebreak is
  attacker-influenced."
- **Flag uncertainty as uncertainty.** "I could not test this" and "I am
  assuming" are useful; a confident sentence covering a guess is not.
- Jargon is fine where it is the precise word — but define it the first time in
  each report, in the same sentence.

**Being brief is not the goal; being actionable is.** A short report he has to
re-read three times is worse than a longer one he reads once.

### Then write the same two lists into `CLAUDE_DOCS/TASK_COMMS.md`

**Michael should never have to retype an action item from one Claude window into the
other.** Until 2026-08-29 he was the wire between the two sessions: he read each
task's list and copied the planning-session half across by hand. Every retyped list is
one that can be retyped wrong, or late, or not at all.

**Every task ends by appending one entry** to the top of that file's "Open — waiting
on the planning session" section:

```
### Task 11.37 — 2026-08-29 — commit a1b2c3d — Done
**For the planning session**
1. ...
**For Michael**
1. ...
```

- **This does not replace the report above.** Michael reads every report and it still
  ends with his numbered list. The file is the durable copy, because an action item
  that exists only in a chat log is one closed window from gone.
- **Every task writes an entry, including a task with nothing to ask** — say
  `**For the planning session:** nothing.` in so many words. **A missing entry is
  indistinguishable from a task that had nothing to say.** A check that cannot
  distinguish success from its own failure is not a check, and that rule applies to
  this one as much as to anything in `lib/`.
- **Status is `Done`, `Partial` or `Blocked`,** and `Partial` names the line it
  stopped at. Several tasks now carry a written stop order; which line was reached is
  the most useful thing the next task can know.
- **Include the commit hash.** It is what lets the planning session read the change
  rather than the description of the change.
- **Say the action, not the observation** — "ask the planning session to add X to task
  11.3," never a description of a gap with nobody named. Same plain English as above:
  never an identifier alone, say what breaks for a person, flag uncertainty as
  uncertainty.

### The defect vocabulary lives in `CLAUDE_DOCS/DEFECT_VOCABULARY.md`

**Every claim below is a rule this project paid for.** The evidence for each —
the task that found it, what was measured, and how often it has recurred — is in
that file under the same number. **Read the entry whose line is close to what you
are about to do**, and read the file whole before a sweep, an instrument, or any
change to a rule.

**They are here as one line each because `CLAUDE.md` was over its 150,000-character
limit on 2026-09-18 and being truncated from the end**, so the newest rules were
reaching nobody. Nothing was deleted; append new instances to the entry in that
file, and add a line here only for a genuinely new rule.

1. **An instrument's last words must be a finding, not a name.**
2. **Baselining a probabilistic signal does not remove the flake; it inverts which outcome is the flake.**
3. **A check keyed on a human-written description is a hand-maintained list wearing a different hat.**
4. **When a feature is removed, its vocabulary survives in one more sentence than anybody finds.**
5. **A screen's total is nobody's acceptance criterion, so measure it.**
6. **A suite that gets dramatically slower and still passes is reporting a defect in the only language it has.**
7. **Run a derivation across the whole corpus, including the rows you are certain of — those are the ones that can catch the instrument.**
8. **One derived section in a hand-kept document is more dangerous than none**
9. **The branch reached when the code does not know why must not assert a cause.**
10. **A hand-maintained list is wrong when it is the control. It can be fine when it is only the explanation.**
11. **A note kept so a document does not have to be re-read is a copy, and copies go stale.**
12. **In a widget test, never await the database from the test body.**
13. **A client must not hard-code a fact about a server it ships separately from.**
14. **A red with an explanation nobody re-derived is not a diagnosis.**
15. **"These two cannot disagree" is a claim about identity, not only about code.**
16. **A harness that patches a named line is coupled to code it does not own, and the coupling is invisible from the owning side.**
17. **"Nothing broke" is a result, and a brief that assumes otherwise should say so.**
18. **A check that says it reads "every file in the repository" must ask git what that means.**
19. **A test surface chosen to make one thing fit is a claim about width as well as height, and nobody re-examines it.**
20. **A pre-check may be more permissive than the write it precedes. It must never be less.**
21. **Widget-test layout numbers are measured in a font about twice Roboto's width, so some savings are exact and others are fiction.**
22. **A question that costs more to answer than to satisfy should be satisfied.**
23. **A rendering change cannot be closed by a test suite, so scope it to one change and stop.**
24. **A "Violated by" list is a rule, and shipping past one is how a model and its code drift.**
25. **A command file outlives its task, and the window it opens cannot tell.**
26. **A TODO names code it does not own, and a deletion never comes back to correct it.**
27. **A report's description of code is not the code, and the planning session keeps forgetting it.**
28. **One file naming a string another file implements — and the first time the guard caught it rather than a person.**
29. **A bound on change cannot constrain a creation, and the falsifier you name is not the only one.**
30. **A budget written for a child of a `Column` is not a budget — it is a comment.**
31. **Where a file already derives part of its own set, the repair belongs in that derivation — a guard elsewhere naming a subset is a hand-kept list wearing a guard's clothes.**
32. **A check whose only exercise is a twenty-minute Docker run is a check whose own failure modes nobody watches.**
33. **A flag that is always set in one mode carries no information in that mode.**
34. **A named instrument that reports PASS having measured nothing is worse than one that disappears, because the name is what a reader looks for.**
35. **A pin to a rolling repository's *rebuild counter* is a scheduled outage, not a pin.**
36. **Two habits of the planning session are now enforced by tests, and meeting them mid-task is not a bug.**
37. **A capability that has been removed keeps its row, struck through and dated.**
38. **A check that compares a widget's value to a theme token is keyed on the token's *name*, and passes whatever that name resolves to.**
39. **A guard finds what reports do not, and that is the argument for building one at the fifth report rather than the tenth.**
40. **The website's copy-drift check is its own workflow. A green pre-commit hook says nothing about it.**
41. **Do not animate in response to something that is itself animating — you will produce the jitter you meant to smooth.**
42. **An assertion that something is gone, made by looking for its absence, can pass for reasons that have nothing to do with the change.**
43. **Simplicity and readability beat verbosity, so long as the option is findable by exploring or by tapping an information affordance.**
44. **Color never carries a meaning on its own in this app. The word is the answer; the color is the accelerator.**
45. **A row that is out of the estimate keeps its dimming and gives its color up.**
46. **The copy-changes list is a convenience. The screenshot harness is the derivation. Do not confuse which one is the safety net.**
47. **A size that works as an annotation is not a size that works as a subject.**
48. **Seventeenth instance, 2026-09-07, and it is the planning session breaking a rule it had adopted hours earlier.**
49. **Write an exception as a coupling, not as an exemption.**
50. **A measurement that surrounds the wrong interval is not weak evidence — it is no evidence, and it travels further than a guess because it has a number on it.**
51. **A check on the *quality* of a decision is not a check on the decision.**
52. **`flutter test`'s human output cannot tell you what ran. Only `--reporter json` can.**
53. **A Markdown-only commit can turn `flutter test` red in this repository, and has.**
54. **The pre-commit hook runs `flutter test`, and `flutter test` is the client. It cannot see a change to the contract between the app and the server.**
55. **A brief's number can be right while its estimate of *containment* is wrong, and that is the more expensive half.**
56. **A check can fail correctly into a place with no reader, and that is its own defect.**
57. **A sweep that reports itself complete is a claim, and it is checkable.**
58. **When a test hangs, the harness is a suspect before the app is — and this project had the rule and did not reach for it.**
59. **The device log beats the best hypothesis, and it is cheaper than the hypothesis.**
60. **A repair that runs inside a read can be interrupted, and idempotent does not save it.**
61. **A workaround in a test is a defect nobody filed.**
62. **A wire has readers outside the program, and nobody had ever listed them.**
63. **A migration test on an empty database tests almost nothing, and two defects in one task prove it.**
64. **The pre-commit escape hatch exists, says so out loud, and obliges an entry.**
65. **A comparison between two things that fail identically is not a comparison.**
66. **A marker that is supposed to move cannot show you that it is moving wrongly.**
67. **Enforcing a written rule for the first time tells you who has been violating it — expect that, and do not weaken the rule to make the noise stop.**
68. **Poll quietly, but keep the last attempt's output and print it with the failure.**
69. **When an instrument decides "the conditions were too poor to measure", ask what quantity that decision reads. If the answer is a sign, a count or a boolean, it cannot tell a small bias from a large one — and a bias is exactly what poor conditions produce.**
70. **An instrument's behavior on a broken server is a different question from its behavior on a healthy one, and only a broken-control harness asks the first.**
71. **A budget can only say no by taking something away, so a screen with nothing it may withdraw cannot have a structural one.**
72. **A floor a test checks afterwards and a floor the layout enforces are not the same guarantee.**
73. **A reopen trigger written in prose is a hand-kept list of one, and it rots on the same schedule.**
74. **A code task may edit a planning-session document when its own brief tells it to, and it should say so in its report rather than assume the exception.**
75. **A guard that greps for a literal call cannot see through a function call — and a check written to protect a new idiom must be tested by breaking that idiom.**
76. **A guard against scanning nothing must fail when the scope is wrong, not only when it is empty.**
77. **A CI runner's environment silently narrows what a check covers, and the narrowing never announces itself.**
78. **A text measurement that ignores the ambient `DefaultTextStyle` is quietly wrong in the same direction everywhere.**
79. **Do not predict a wrapping sentence — ask the widget how tall it will be.**
80. **A screen whose furniture floats over its subject cannot fail loudly, so the only instrument that works there is a measured band.**
81. **A baseline can photograph the harness's environment instead of the app, and a diff cannot tell the difference.**
82. **An entry that answers some of a command's instructions is not an entry that answers all of them.**
83. **A scheduled job proven by a push has not proven its schedule.**
84. **A cleanup step that runs unconditionally is a decision to keep no evidence, and nobody writes it down as one.**
85. **A status command that changes what it measures is not a status command.**
86. **An answer that does not name what it measured is the same answer on two machines.**
87. **A cause proposed for an event nobody has reproduced is a hypothesis, and writing it into a comment makes it a fact.**
88. **A widget existing is not a widget drawn.**
89. **A readiness condition should return what it is still waiting for, not a boolean.**
90. **A harness that builds its own container gets the framework's defaults, not the app's — so it is measuring a different app.**
91. **A grep tells you a token appears. It does not tell you what the token means.**
92. **A health signal fed only by failures is silent during a hang.**
93. **A check that verifies the strings a page quotes can never notice a string the page ought to quote and does not.**
94. **Removing something every screen carried invalidates every number that was measured with it live — in one commit, across files, silently.**
95. **A sentence that explains a design choice is clutter; a sentence that warns the drawing may be wrong is data.**
96. **A rule applied one instance at a time, each time by a person noticing, is not being applied.**
97. **A wait that can time out must fail when it does. "It returned" is not "the condition came true."**
98. **"Does not reproduce" and "reproduces one time in twelve" are different claims, and the second one has a rate.**
99. **The copy-changes list is a hint. Deriving from the code is the step.**
100. **A wait whose condition is weaker than the assertion that follows it is a race, not a wait.**
101. **A check that can invent a false subject, which then passes, is broken in the direction nobody looks.**
102. **Rename a shared assertion and the documents that name it are now wrong — fix them, and say it was renamed.**
103. **One observation is not a flake, and calling it one is a decision you have not earned.**
104. **A new state can expose a defect that every existing ladder was blind to.**
105. **A rule written in a document is not a rule the code obeys. Before planning against one, find the thing that enforces it.**
106. **A legible color can still be the wrong color, and no contrast check will ever say so.**
107. **A gap that wants a check but does not yet earn one gets a trip-wire, not a note.**
108. **Never reproduce a secret-shaped string in a report.**
109. **If the task's own spec assumed a mechanism you did not build, say so rather than shipping the spec's words.**
110. **A script can work because of where it is run rather than because it is right — one environment is not a test of portability.**
111. **A cache that tracks its own last run is not a check on the current state — an incremental guard passes on the drift it exists to catch.**
112. **A property stated without the events it must survive is not a specification — "once" means nothing until the brief names what copies it.**
113. **Under `pipefail`, a pipeline ending in a command that stops reading early (`grep -q`, `head`, …) can report "missing" about a line it found — 49 of 300 on a real `docker logs`.**

- **Append only. Never edit or delete an existing entry, and never write in the
  "Resolved" section** — that half belongs to the planning session, and the two
  sessions share one working tree. Reading "Resolved" for context is fine and often
  useful.

## The content stream — do not touch it

**Created 2026-08-31.** A second lane of work — the public website and the user guides —
runs from `CLAUDE_DOCS/WEBSITE_PLAN.md` and reports to `CLAUDE_DOCS/WEBSITE_COMMS.md`, with
its own commands (`/w-01`, `/w-02`, …). It may run **in a separate window at the same
time** as a code task.

**It stays out of your way and you stay out of its.** A code task never edits `website/`.
The content stream never edits `lib/`, `server/`, `packages/`, `scripts/` or
`DEVELOPMENT_PLAN.md`, and never fixes the app — it files findings and the planning session
turns them into numbered tasks. **The one shared file is the source the drift check reads,
and it only reads.**

If a code task changes user-visible copy, **say so in your comms entry** — the website
quotes that copy and a check will go red.

**And `check_app_quotes` green must not be an acceptance criterion on a code task that
changes quoted copy.** **Added 2026-09-14, and the defect was in two task briefs the
planning session wrote.** Tasks 11.245 and 11.250 both changed strings the tags guide
quotes, both were forbidden by the rule above from editing that guide, and both carried
*"`check_app_quotes` green"* in their acceptance. **So each was given a criterion it was
not allowed to satisfy.** The tell was that they disagreed about their own status on
identical facts — 11.250 reported `Done`, 11.245 reported `Partial`, and neither was
wrong, because the acceptance did not say which.

**Write it as:** *`check_app_quotes` is green, or its only red lines are guide pages this
task's own copy changes made stale — each named in the comms entry, with the new wording,
for the content lane.* **A red line that is expected is only safe while somebody remembers
why**, so naming it is the whole of what makes it acceptable; a task that leaves the check
red and does not name the lines has failed this criterion, not met it.

## Staging discipline — every session stages only the files it edited

**A directory is not a file name.** `git add -- CLAUDE_DOCS/` stages every
changed file in that directory, including a Claude Code window's half-written
edits to `DEVELOPMENT_PLAN.md` — which is the same sweep `git add -A` is
forbidden for, wearing a path. **Name each file.**

Broken 2026-09-20 by the planning session, repeatedly, and caught by task 11.289
rather than by me: its commit `6b8463d` ("Plan: 11.290 …") carried 11.289's
in-progress status block and four Discovered Scope entries, **including a
`COMMIT_HASH` placeholder**, into a commit about something else. Nothing was
lost because that task's own commit replaced the placeholder. **It was luck, and
the rule already said not to do it.**

**And do not write to a file another window has open.** `git status` before
editing a shared document: `M CLAUDE_DOCS/DEVELOPMENT_PLAN.md` while a task runs
means that task is editing it, and the planning session's write either clobbers
its work or hands it a conflict.


**WIDENED 2026-08-31, from "the planning session" to every session, after the
third instance.** Task 11.99's commit swept up 191 lines of the content lane's
in-progress harness work — `capture_test.dart` and `shots.dart` — and its message
describes none of it. **The rule was written for the planning session because that
was where it had happened twice; it is not a rule about planning sessions, it is a
rule about a shared working tree**, and this project now runs two windows at once
as its standing condition rather than its exception.

**No session may run `git add -A` or `git add .`** Every session stages the
specific paths it edited, **by name**. For the planning session that is normally
`CLAUDE_DOCS/*.md`, `.claude/commands/*.md`, `CLAUDE.md`, `.gitignore`. For a code
task it is the source and test files it touched. For a content task it is
`website/` plus its named exceptions.

**If you find a file staged that you did not edit, unstage it** — it belongs to the
other window, and it is mid-thought.

**And the commit itself must name its paths: `git commit -- <the paths you edited>`.**
**AMENDED 2026-09-04, after task 11.143 came within one commit of publishing the other
window's half-finished work.** Staging by name is not enough, and this rule said only
that. **`git commit` with no pathspec commits the whole index, not the paths you added**
— so a session that staged perfectly still commits whatever the other window had already
staged before it started. That is exactly what happened: commit `4c262dd` carried seven
of the planning session's files alongside 11.143's own, and it was caught and rewritten
into `746cc16` afterwards rather than prevented. **The defect was in the commit step
while every version of this rule was policing the `add` step.**

**The matching hazard on the other side, seen the same day: restoring the other window's
staging can be worse than leaving it cleared.** 11.143 put the planning session's staged
files back exactly as it had found them — correct in itself, but the planning session had
*committed* those files in the meantime, so the restored index was a snapshot from before
that commit and **any pathless commit would have reverted work already in history.** So:
**if you must clear the other window's staging, say so in your comms entry and leave it
cleared.** A stale index is a loaded gun; an empty one costs somebody thirty seconds.
**Nobody's staged state is worth reconstructing across another session's commit.**

**Why.** The two sessions share one working tree, and Claude Code is often
mid-task while the planning session is writing a plan. Commit `e16d79b` ("Task
11.11 and Phase 12") swept up seven of Claude Code's half-finished source files
alongside two planning documents. Nothing was lost and the end state was
correct, but that commit does not build on its own and its message describes
almost none of what it contains — which makes `git bisect` lie to whoever is
hunting a bug months from now. Commit `c5d8ec9` did the same thing earlier with
five tasks' work.

If the planning session sees uncommitted source changes it did not make, the
correct move is to **say so and leave them alone**, not to bundle them.

Claude Code may continue to stage broadly — it owns the source tree during a
task, and its commits are the ones that should be buildable and bisectable.

# Session handoff — the planning session, 2026-08-28

**Written for whoever picks up the planning role next**, whether that is a new Cowork
session, a different account, or Michael a month from now. It exists because the
reasoning behind the current tasks is worth more than the tasks, and none of it lives
in a chat log.

**Authoritative files are unchanged.** `DEVELOPMENT_PLAN.md` for what to build,
`TriTrack_Security_Model.md` for findings, `SECURITY_SCOPE_AND_EXIT.md` for what a
security gate may look at and when it may stop, `PERMISSIONS_MATRIX.md` for who may do
what, `CLAUDE.md` for how every task must report. **This file is orientation, not
authority** — if it disagrees with those, they win.

---

## 1. What this session is, in one paragraph

Two Claude sessions share one repository. **The planning session** — this role — reads
and writes documents and task specifications, and never touches source. **Claude Code**
executes tasks via `/task-id` slash commands and owns the source tree. Michael runs the
commands and the planning session decides what each result means, updates the plan,
and hands back an updated command table. That loop has run roughly sixty times.
**Changed 2026-08-29:** for the first sixty of those, Michael was the wire — he
retyped each task's planning-session items into the other window by hand. Claude Code
now appends them to **`CLAUDE_DOCS/TASK_COMMS.md`** instead, and the planning session
reads that file directly when Michael says a task is done. Read it at the start of
every planning session; its "Open — waiting on the planning session" section is the
inbox, and its "Open — waiting on Michael" section is where the items only he can do
now live so they stop depending on one conversation.

**Michael is a wildlife biologist who writes research scripts.** He is not an
application or security developer, and he reads every report. `CLAUDE.md`'s "Reporting
results" section is not a style preference — it exists because a report he cannot act
on has not been delivered.

---

## 2. Where things stand, 2026-08-28

**Phase 11 (teams, roles, joining, permissions) is substantially built and
attacked.** Its security review, task 11.9, ran and reached a verdict: **Gate D passes**
— the app is clear to ship to a beta team — and **Gate C fails on the NAU
information-security review**, which no amount of engineering can close.
**Corrected again on 2026-08-30, this time in the good direction: the NAU letter *is*
now the only thing.** Task 11.49 attacked and Hardened the two surfaces that had no
verdict, and task **11.64** ran the ninth Gate C round from committed instruments —
**criterion 1 is met for the first time**, so every server entry carries a failed live
attack from the round that just ran. Gate C fails on **criterion 5 alone**.

**Why the wording matters, and why this file said the opposite for a day.** On
2026-08-29 "the letter is all that is left" was false twice over: two inventory entries
had never been attacked at all, and eleven more carried evidence from a round that had
ended. Both are closed, and the round that closed them **left its checks behind** —
round 8's ninety hand-written checks had been thrown away, which is why every previous
round cost half a day before it could start. **A round whose checks vanish when it ends
has not been run; it has been performed.** The next round's automated half is under
fifteen minutes.

**Everything before step 19 of the two-device walkthrough works on real hardware**:
sign-in, joining, roles, and sync in both directions between a Mac and an
iPhone signed in as two different people.

### Done since the last handoff-worthy point

11.9, 11.17, 11.18, 11.20–11.28, 11.32, 11.35, 11.38, 11.41, 11.43, 11.44, 11.45,
11.46, 11.47. Tasks 11.27 and 11.31 were merged into 11.25 and 11.30; 11.26 into 11.24;
11.29 was canceled outright.

### Not started

**Phase 11:** `11.30` (carries 11.31), `11.33`, `11.34`, `11.36`, `11.37`, `11.40`,
`11.49` (added 2026-08-29). `11.48` exists but is **deliberately deferred** with a
written trigger.

**Phase 10 remainder — still unscheduled, and easy to forget because it is not on the
Phase 11 list:** `10.79`, `10.80`, `10.84`, `10.85`, `10.87` (widened), `10.97`
(widened), `10.99`, `10.107`. `10.86` was deferred on Phase 11 identity and is now
actionable. **`10.97` has no `.claude/commands/` file** — every other unscheduled task
does, so it is the one that cannot be run by typing its slash command.

### Only Michael can do these

1. **Send the NAU letter.** `NAU_infosec_review_request.md` is written, current, and
   marked CLEARED TO SEND. The recipient address is deliberately blank. **This is the
   longest-standing blocking item on the project** and the only one engineering cannot
   close. It has been rated blocking at eight consecutive gates and five gates revised
   it without sending it.
2. **Finish the two-device walkthrough at step 19** — the leave-a-project checks. Sync
   now works, so the test can finally say something.
3. **Take the LAN exposure back down** when done: remove `SERVER_PUBLISH_ADDRESS=0.0.0.0`
   from the VM's `.env` and restart.

---

## 3. The two things that unstuck this project

Both are worth understanding before writing any new task.

**Gate C ran eight times and failed seven.** The diagnosis was not a failing codebase —
no fix ever regressed, and the sync interface came back clean three rounds running. It
was **an unbounded question asked repeatedly**: each round chose its own surface,
treated every finding as needing a task, and generated more work than it closed.
`SECURITY_SCOPE_AND_EXIT.md` fixed it by bounding three things — the surface (an
enumerated inventory), the bar (four clauses), and the disposition of everything below
the bar (an explicit recorded acceptance, not a task nobody scheduled). The eighth gate
reached a verdict.

**The two-device walkthrough found seven real defects on its first honest run**,
including that **sign-in had never worked on macOS since Phase 5 added desktop
support**. None would have been caught by the test suite, because every test ran on one
device. The general lesson: this project's tests were good and its *instruments* were
where the danger lived.

---

## 4. Recurring defect classes — the ones that keep paying

Quote these when writing tasks. Each was learned expensively.

- **A check that cannot distinguish success from its own failure is not a check.**
  Found five separate times before it was named as one class.
- **A check that fires and does not say what is wrong is half a check.** Standing rule
  added 2026-08-27 after four instances in three days. Its corollary is the expensive
  one: **when an instrument cannot tell you what happened, fix the instrument before
  the thing it was pointing at.**
- **A hand-maintained list of what the code already knows is already wrong.** Not
  "will drift" — *is wrong now*. Twice in one week, replacing a list with a derivation
  immediately found something the list had missed: the twelfth synced table, and three
  auth routes never tested end to end. Prefer deriving from the schema or the rules,
  and **prove the guard can fail** by breaking it and watching it go red.
- **A control that works for a reason other than the documented one is one refactor
  away from not working at all**, because whoever preserves the documented reason will
  not know to preserve the real one. Three comments in three weeks asserted a property
  that was not the one holding.
- **Wherever a control deliberately ignores something, that exemption is where the next
  problem is.** Finding N-1 came from an exemption that was correct when a project
  meant one person's two devices and silently changed meaning when membership records
  joined the query.
- **A control is only as good as the configuration it was measured in.**
- **A workflow fix is incomplete while any document still spells out the broken
  invocation.** Added 2026-08-30 after the second instance. Task 11.37 built a script to
  remove a trap and left the trapping command written in the document the security gate
  reads; the ninth gate round then fell into it. Converting a step does not remove its
  copies, and nothing looks for them.
- **The attack corpus cannot reach the check — and that is not a broken check.** Added
  2026-08-30 by task 11.71. Its blind check was correctly written, looking in the right
  place, with every control inside the instrument firing. **What was wrong sat upstream of
  all of them:** four of round 8's five traversal addresses could not, on Linux, put a
  file anywhere the check looks. **Only an outside harness that deletes the control could
  see it** — reading the instrument never would. **Suspect any check whose final assertion
  is a comprehensive search**, a `find` across a filesystem or a grep of a whole log:
  finding nothing looks identical to there being nothing to find. **And "watched to fail"
  has usually meant "watched to abort", which is a different property from "watched to
  detect."**
- **A control whose only job is to pass is not doing a job.** Added 2026-08-30 by task
  11.72, which made the mistake itself one commit after writing the task up. Its timing
  instrument carried a *null pair* — two ids that both name nothing, whose true
  difference is exactly zero — as a control that was expected to show "no stable sign".
  On a Mac it did. **On a clean runner the null pair came back unanimous at 4.1
  microseconds, which is the machine's own per-id offset** — and that number was the
  instrument's real product. **A sign test cannot say anything below its own machine's
  floor**, and the assertions had to change shape once the floor was published. **Design
  every control to publish a measurement, not to agree with you.**
- **Fix the class, not the instance.**
- **An "Open" verdict with no task number is not a record.** This cost two blocking
  items six weeks.

---

## 5. Standing rules a new planning session must honour

- **Never `git add -A` or `git add .`** Stage only the paths this session edited, by
  name — normally `CLAUDE_DOCS/*.md`, `.claude/commands/*.md`, `CLAUDE.md`,
  `.gitignore`. Two commits swept up Claude Code's half-finished source files and
  their messages described almost none of what they contained. If uncommitted source
  changes appear that this session did not make, **say so and leave them alone.**
- **`.claude/` is blocked for the Edit tool.** Write command files via shell heredocs.
- **Read `CLAUDE_DOCS/TASK_COMMS.md` before doing anything else, and write back to
  it.** Move each entry acted on into its "Resolved" section with one line saying what
  was done and the date. Never rewrite Claude Code's words and never delete an entry —
  an ask that quietly disappears is the same failure as a finding recorded with no
  task number, which cost this project six weeks.
- **Use `set -euo pipefail` and assert before writing.** Three separate times a Python
  edit's assertion failed while the shell chain continued, producing a commit whose
  message claimed work that had silently not happened.
- **Every task entry ends with acceptance criteria**, and every command file ends by
  pointing at `CLAUDE.md`'s reporting section.
- **Never use an identifier alone** in anything Michael reads. Not "L-2 is closed" but
  "a crafted project file could permanently destroy an observation by moving only its
  version counter — that is closed."

---

## 6. Mistakes this session made, so they are not repeated

Recorded because each was caught by Michael or by Claude Code rather than by the
planning session itself.

- **Wrote an unactionable instruction** — "carry the insert-check point into 11.2 and
  11.3" — which is precisely the failure this project keeps finding. Michael asked what
  it meant. Tasks must name the action.
- **Predicted a probe would "almost certainly pass"**, then doubted the instrument when
  it failed. The real answer came from measuring directly. **Do not offer predictions
  as findings.**
- **Wrote a contradiction into 11.2's tests** — "a removed member's session is revoked
  immediately" two paragraphs below the invariant that people belong to many projects.
  Sessions are per person; that would have cut somebody off from every project. Claude
  Code caught it. The same error nearly recurred in 11.23.
- **Hand-wrote a control list in 11.12 that was incomplete**; 11.14 found three more.
  The repair was to make 11.14 *derive* the set from the code rather than from another
  list written by this session.
- **Designed three things wrongly in a row and Michael caught each one**: omitted tag
  name from what an observation must remember, then wrote a rule that would have frozen
  tag color, then forbade tag edits when frequencies genuinely drift. **The pattern:
  this session reasoned about the mechanism; Michael reasoned about what the field
  means to somebody using the app.** That is the check this session cannot perform
  alone — ask him.

---

## 7. Decisions taken, with their reasons

These are settled. Reopening one wastes a round. Full reasoning is in
`PERMISSIONS_MATRIX.md` §8 and in each task entry.

| Decision | Answer | Why it matters |
| --- | --- | --- |
| Correcting a teammate's bearing | New record **supersedes**; original survives for provenance; the solver counts only the superseding row | Never overwrite a scientific record |
| Adding a tag to a project | **Owner only** | Now load-bearing: it is what stops copy-on-add multiplying duplicates |
| Editing a tag | **Allowed** — frequencies drift | Task 11.29 canceled; forbidding edits forbids recording reality |
| What a bearing remembers about its tag | A **reference to the tag as it was**, not copied fields | Copying "the fields worth copying" is a hand-kept list |
| Tag color | **Never versioned** — a recolor changes every record already drawn | Color is a display key, not a measurement |
| Editing a versioned tag field | Asks **correction or change** | Drift keeps old values; a typo propagates. Only the person knows |
| Project tags | **Copied into the project** on add (design pending, task 11.34) | Deletes the cross-project authorization question rather than answering it |
| Restored records from a colleague | **Keep their name** | Provenance beats publishability. Consequence: their bearings publish only from their device — accepted, not a defect |
| Leaving a project | **Anyone may**, no owner confirmation | |
| Merge tiebreak | **Accepted** in writing | |
| Cloud backup | **Retire it** once a server exists; default off now; **export stays** | |
| Publishing a project you only hold a copy of | **Accepted**, conditional on the publish screen naming who becomes owner | The likely path is an accident, and the share screen encourages it |
| Repository visibility | **Private, and staying private** — Michael, 2026-08-30 | It will eventually be sold, and he is guarding the source as intellectual property. Public would make all continuous-integration minutes free, which is a real cost, and he took the cost knowingly. **Do not reopen this on budget grounds.** |
| The residual timing difference on a refusal | **Accepted** — Michael, 2026-08-30 | About 6 microseconds, sitting *on* a measured 4-microsecond noise floor. The alternative is padding every refusal to a fixed delay, declined: the pad must exceed the slowest real project, it grows as teams grow, and the route has no rate limit, so a padded refusal is a resource an attacker can hold open. Reopen condition is a **check**, not a promise |
| Two-device walkthrough on a Mac | **Apple ID is an accepted prerequisite** | The alternative means macOS sign-in is never exercised — which is how it stayed broken |

**Three acceptances share one shape** — a forgeable value that is harmless *only
because nothing reads it yet*: the tag-creator stamp, the exclusion reference, and the
edited-by stamp. Each carries a written reopen condition. **If a fourth arrives, the
pattern deserves attention rather than a fourth register entry.**

---

## 8. Beyond Phase 11

**Corrected 2026-08-30 by task 11.40, which was told to settle this rather than leave
both readings alive. This paragraph used to call three tasks beta-blocking and two of
them are not.**

- **`10.84` (archive encryption and client key custody) genuinely must close before a
  beta**, and neither document was ever wrong about it: the plan's "Not blocking" is
  *gate-scoped*, while the security model's acceptance of an unencrypted archive is
  *time-bounded — only until the beta field season*. 10.84's own entry already says a
  Gate D pass does not extend that. **The date is approaching and not deciding is a
  decision.**
- **`10.99` (the unbounded archive envelope) and `10.107` (what a tile server can put
  in the field record) are NOT beta-blocking.** Security Model §15.4 registers both
  below the bar and says plainly that neither blocks either gate. **This file said
  otherwise and it was simply wrong.**
- **But 10.107 carries a question the security answer does not reach**, and it is
  Michael's rather than a gate's: a corrupt tile becomes an authoritative "surveyed
  ground elevation" in the record, is preferred over the phone's own GPS altitude by
  design, and reaches every teammate. That is a **data-quality** decision about whether
  to collect a field season that might be silently wrong. `RELEASE_CHECKLIST.md` Part 5
  item 1 has the options; the middle one is hours of work.

Newly actionable: `10.86` (signing archives and share payloads).

**`CLAUDE_DOCS/RELEASE_CHECKLIST.md` (task 11.40, 2026-08-30) is now the authority on
what a release needs** — hardware, field and deployment items included, not only tasks.
Where this section and that file disagree, the checklist wins.

Unscheduled but needed before a beta: Apple Developer enrollment and TestFlight
distribution, a privacy policy, beta exit criteria, team onboarding materials, and
feedback or crash collection. **Task 11.40 will produce the release checklist** that
several of these belong on.

Deferred by decision: `11.48` (waiting on a third consumer of the foreign-key
convention), Phase 12 (tag merge, now **narrower** — copy-on-add removes the
cross-project half), and `EXPERIMENT_ITM.md` (a Longley-Rice propagation experiment,
with a task that defines "fast enough" before anything is measured).

# The defect vocabulary — what this project has learned, one scar at a time

**Moved out of `CLAUDE.md` on 2026-09-18, because that file had reached 159,664
characters against a 150,000 limit and was being silently truncated** — which
takes the *end* of a file, so the newest rules were the ones no window was
reading. That is this project's own *a check that fails into a place with no
reader*, pointed at its own rulebook.

**Nothing was deleted.** Each entry below is verbatim. `CLAUDE.md` keeps every
one of their opening claims as a numbered index, so a window still meets every
rule; this file holds the evidence — which task found it, what was measured, and
how many times it has recurred.

**Read an entry when its index line is close to what you are about to do**, and
read the whole file when a task is a sweep, an instrument, or a rule about rules.
**Append new instances here, to the entry they belong to**, and add the index line
to `CLAUDE.md` only when the rule itself is new.

**One line was changed rather than moved verbatim, and this is it.** Entry 48
quoted the literal citation somebody had wrongly written — and
`planning_document_citations_test.dart` counts that shape wherever it appears,
because **a scanner counting a shape cannot tell a use from a quotation of one.**
Moving the entry into this directory therefore turned the suite red on the one
entry that is *about* not writing such citations. It now describes the citation
instead of reproducing it, which is exactly what that rule asks for. **Nothing
else was altered.**

**That is the eighteenth instance of entry 48's own rule**, and this time the
planning session reproduced the forbidden shape while relocating the paragraph
warning against it.

**Anything written before 2026-09-18 cites these rules as `CLAUDE.md`, and that
citation now means this file.** Several test files carry comments of the form
*“(`CLAUDE.md`, 2026-09-04)”* pointing at rules that live here — grep both files
before concluding a cited rule does not exist. **They are not corrected in place
because `test/` is not the planning session's to edit**; a task that touches one
of those files for another reason should fix its comment while it is there.

---

### 1. An instrument's last words must be a finding, not a name.

- **An instrument's last words must be a finding, not a name.** Continuous integration
  keeps only the final few lines of each check, and twice in two days the missing fact
  was **one line the instrument already had and did not print** — who owned a directory,
  and how many milliseconds sat behind a check's name. **The five-line tail is enough
  exactly when the last thing a check says is what it found.** That is an obligation on
  every instrument, not a reason to upload logs that can hold live session tokens. Rule
  established by task 11.69, 2026-08-30.

### 2. Baselining a probabilistic signal does not remove the flake; it inverts which outcome is the flake.

- **Baselining a probabilistic signal does not remove the flake; it inverts which
  outcome is the flake.** A BASELINE entry has exactly two modes — *still admitted*, or
  *now refused and therefore a regression* — so it can express a fact that is stably true
  or stably false, and cannot express one that is true most of the time. Task 11.88
  baselined a timing signal sitting at the host's noise floor, watched the very next CI
  run fail for the opposite reason, and **caught it the same day, before reporting it as
  final.** The right tool for an observation that is only sometimes stable is a `note()`,
  and the enforcement belongs where the magnitude can be bounded — in this case the
  ordinary server suite, which runs on every commit. **Before reaching for a baseline, ask
  which of the two modes the fact actually lives in; if the answer is "it depends on the
  machine", it lives in neither.** Rule established by task 11.88, 2026-08-31.

### 3. A check keyed on a human-written description is a hand-maintained list wearing a different hat.

- **A check keyed on a human-written description is a hand-maintained list wearing a
  different hat.** Task 11.88 found `attack()` called with the same description string for
  unrelated checks on different routes, so a later check silently overwrote an earlier
  one's result — and a genuinely *flipped* attack was reported as blind. **If a structure
  is keyed by a string somebody types, a duplicate key must be a hard error, not a last
  write wins.** Rule established by task 11.88, 2026-08-31.

### 4. When a feature is removed, its vocabulary survives in one more sentence than anybody finds.

- **When a feature is removed, its vocabulary survives in one more sentence than anybody
  finds.** Task 11.81 replaced invitations with a join code; a week later the one screen
  explaining removal still told people to wait for an invitation — **and the dialog next
  door carried a comment saying that exact wording had become false, so somebody knew, wrote
  it down, and fixed one of the two.** Task 11.98's answer is the reusable one: **a checked
  vocabulary.** `test/documentation/invitation_vocabulary_test.dart` scans every string
  literal under `lib/` for the dead feature's words and fails unless the occurrence is on an
  **explicit, reasoned allowlist** — so a survivor has to be argued for rather than merely
  overlooked. **Point the next "we replaced X but copy about X keeps turning up" task at that
  file rather than writing a fresh one-off grep.** Rule established by task 11.98,
  2026-08-31.

### 5. A screen's total is nobody's acceptance criterion, so measure it.

- **A screen's total is nobody's acceptance criterion, so measure it.** Task 11.109 found the
  Position screen's bearings list crowded to **83.5 logical pixels — one row — and to 42.5
  whenever a caution was showing**, by four additions each of which was justified by the task
  that made it. **No task's acceptance has ever been "and the screen still works with all of
  this on it."** Nothing was wrong with any widget; the defect was the sum. **When a task adds
  anything to a screen that already has furniture, say what the screen looks like afterwards**
  — and prefer a measured budget over a look. Two related traps: **a conditional band
  appearing is usually the variable, not a list growing** (that screen showed the same single
  row at 2 bearings and at 200); and **a widget test that pumps a screen bare gives it about a
  navigation bar's worth of height it never has in the app**, which is why this class was
  invisible to the suite. Rule established by task 11.109, 2026-08-31.

### 6. A suite that gets dramatically slower and still passes is reporting a defect in the only language it has.

- **A suite that gets dramatically slower and still passes is reporting a defect in the only
  language it has.** Task 11.103 changed one screen's default zoom; its suite got **250 times
  slower and stayed green**. The cause was live in the app before that task and needed only a
  pinch-out to reach: `estimateTileCount` **built the entire tile list in order to measure its
  length**, so "New selection" at a wide zoom asked for every tile on Earth at zooms 12–16, on
  the UI thread, and the app stopped responding. **Nothing failed, because nothing was wrong by
  any assertion anybody had written.** So: **when a suite's runtime changes by an order of
  magnitude, find out why before moving on** — green is not the only signal a test run emits,
  and it is not the most informative one. Rule established by task 11.103, 2026-09-01.

### 7. Run a derivation across the whole corpus, including the rows you are certain of — those are the ones that can catch the instrument.

- **Run a derivation across the whole corpus, including the rows you are certain of —
  those are the ones that can catch the instrument.** Task 11.84's route enumerator
  reported on its first run that a stranger's "ask to join" route was owner-gated, which is
  obviously false. The defect was in the instrument: it read each route's body as
  *everything up to the next route*, so **the last route in the file swallowed the
  definition of `_requireOwner` itself.** Two rules fall out of that. **A parser that
  delimits by "up to the next one" gets the last element wrong**, every time, and the last
  element is the one nobody pictures. And **a derivation is trustworthy because it
  disagrees with rows you already believe** — a corpus narrowed to the uncertain rows would
  have produced five real findings with nothing in it capable of casting doubt on all five.
  **A second way in, found by task 11.173 on a different file type, 2026-09-05.** The rule above is
  phrased about the *last* element; **this one is about a comment belonging to the *next* one.**
  Splitting a GitHub workflow into steps by "up to the next step" made the last step of a job
  swallow the **prose header of the job below it** — which names the variable being searched for —
  so a comment was picked up as a second step setting it. **The same bug then reappeared one level
  up, in the job split.** Both fixed by dropping comment lines before splitting, which is the rule
  `callersOf` in that same file already had and neither new split inherited.
  **So the general form is wider than the last element: a delimiter that does not know what a
  comment is will attach every element's preamble to its predecessor** — and a preamble is exactly
  where a human writes the words a parser is hunting for. **Strip comments before splitting, and
  test the split on the last element and on an element with a header above it.**
  Rule established by task 11.84, 2026-09-01.

### 8. One derived section in a hand-kept document is more dangerous than none

- **One derived section in a hand-kept document is more dangerous than none**, because it
  teaches a reader to trust the rest of the document. A task that derives part of a
  document from code **must also write down where the derivation stops — in the document,
  not only in its report.** Task 11.84 derived §4.2 of `PERMISSIONS_MATRIX.md` and said in
  its report that five other sections and three columns are still prose no test reads;
  that sentence belongs beside the tables it is about. Rule established by task 11.84,
  2026-09-01.

### 9. The branch reached when the code does not know why must not assert a cause.

- **The branch reached when the code does not know why must not assert a cause.** A
  fallback message is the one place uncertainty is guaranteed, and it is where this project
  keeps finding confident sentences. Task 11.84 found the held-row screen telling somebody
  that a refusal was *"a fault in the app... not something wrong with what you recorded"*
  and that *"nothing you can do in the app will change the answer"* — for a case where
  editing one field fixes it. **Fix the default before fixing the case:** an honest default
  is correct for every reason nobody has invented yet, and **"there is nothing you can do"
  is the one sentence that is unrecoverable when it is wrong**, because the person stops
  trying and files no report. **And an honest default costs nothing to maintain, which task
  11.122 stated better than the task that asked for it: copy asserting no cause does not
  depend on the cause still holding** — 11.122 declined to re-measure 11.84's finding and was
  right to, because the sentence it shipped is true whether or not that measurement still is.
  **A confident message has to be re-verified every time the mechanism under it changes; an
  honest one does not.** Rule established by task 11.84 and sharpened by 11.122, 2026-09-01.

### 10. A hand-maintained list is wrong when it is the control. It can be fine when it is only the explanation.

- **A hand-maintained list is wrong when it is the control. It can be fine when it is only
  the explanation.** Task 11.89 replaced a denylist of forbidden name characters with an
  allowlist of permitted ones — and then **kept a hand-written list of code-point ranges
  inside the same file**, used to decide whether a refused character is visible (quote it) or
  invisible (name its code point and say "retype it"). **That is not a relapse, and the test
  that says so is one question: does the list decide what is permitted, or only what is
  said?** This one decides only the wording, and it fails in the harmless direction — the
  worst outcome is telling somebody to retype a field when they could have seen the character
  themselves, never the reverse. **Declare the exception in the code as a choice rather than
  leaving it to be discovered and mistaken for the defect it looks like.** Rule established by
  task 11.89, 2026-09-02.

### 11. A note kept so a document does not have to be re-read is a copy, and copies go stale.

- **A note kept so a document does not have to be re-read is a copy, and copies go stale.**
  Task 11.122 wrote a summary of new app copy into `WEBSITE_PLAN.md`'s section titled *user-
  visible copy the guide must not quote from memory* — **and quoted one of the messages.**
  Task 11.89 split that message in two the next day. **The section built to stop the guide
  quoting from memory had become the memory.** So an entry there names **which file holds the
  copy and what shape it has**, and the reader opens the file. The general form: **a summary
  written to save somebody a lookup acquires its own maintenance burden the moment it exists**,
  and nothing tells you when it has fallen behind. Rule established by task 11.89, 2026-09-02.

### 12. In a widget test, never await the database from the test body.

- **In a widget test, never await the database from the test body.** A widget test runs on a
  fake clock; the database answers on real time. Awaiting one outside `runAsync` leaves that
  clock's pump loop dead, and every later `pumpWidget` hangs — **ten minutes of silence and a
  timeout, not a failure**, which a five-line CI tail cannot explain. Same trap, third
  disguise: a `Completer` built in the test body inherits the fake clock and never resumes
  what it gates. Database work goes in `setUp` or inside `runAsync`. Cost most of task 11.97;
  rule established there, 2026-09-01.
  **Second instance, 2026-09-20 (task 11.294), and it is the same trap with the opposite symptom —
  which is why nobody recognized it.** The rule above was written from a *hang*: something waits on
  the stranded work, the pump loop dies, ten minutes of silence. Here **nothing waited.** Task
  11.290 added a third database-reading provider to the Projects screen's `build`
  (`undeliveredProjectDeletionsProvider`), task 11.289's older test pre-resolved every provider but
  that one, and its first build simply advanced quietly on the fake clock to wherever the pumps took
  it. What survived was sqflite's own 10-second lock-warning `Timer` — created by every statement
  outside a transaction, cancelled in microseconds on a real clock — still pending when the tree was
  torn down. **So the failure was "A Timer is still pending", at a rate set by I/O scheduling: 5 red
  in 5 full-suite runs and 0 red in 5 runs of the file alone.**
  **Three things worth carrying.** First, **a hang is the lucky version of this bug** — it is
  unmissable, and task 11.290 fixed the two providers that hung while leaving the one it had itself
  just added to the same screen. Second, **the rate is the evidence**: four or five reds in five
  full runs and none in isolation is not a flake, it is a statement about what else is running, and
  the diagnosis here came from a print at the poll's exit across 11 runs reading `AsyncLoading` in
  every red and `AsyncData` in every green, with no exception. Third, **the check is the same for
  both symptoms and it is mechanical**: every provider a screen watches that reads the database is
  resolved inside `runAsync` before the screen is pumped. `projects_screen_test.dart` and
  `project_deletion_from_list_test.dart` both show the pattern. **A task that adds a provider to an
  existing screen's `build` has changed every existing test of that screen**, whether or not any of
  them mentions it.

### 13. A client must not hard-code a fact about a server it ships separately from.

- **A client must not hard-code a fact about a server it ships separately from.** Asked to
  make the sign-in screen say how a code actually reaches somebody, task 11.119's follow-up
  considered *"this server does not send email"* — specific, true of every deployment that
  exists today, **and false on every already-installed build the day somebody adds a mail
  sender.** It rejected it. **That is the correct-when-written-then-silently-falsified class,
  authored deliberately**, and the app cannot know the answer anyway: `/auth/magic-link`
  returns the same `202` whether the code was emailed, written to a file or discarded, because
  §4.5 requires it to. **Copy that is honest about not knowing, and names an action, outlives
  the deployment it was written on.** Rule established 2026-09-02.

### 14. A red with an explanation nobody re-derived is not a diagnosis.

- **A red with an explanation nobody re-derived is not a diagnosis.**
  `UNEXERCISED_CONTROLS.md` recorded a failing gate instrument as *"awaiting Michael's §4.13
  answer"*, and a survey repeated it to him as the one thing only he could unblock. **He had
  answered on 2026-08-31; the instrument had implemented the answer the same day; and the
  implementation is a `note()`, which cannot fail a run at all.** The label had outlived
  everything it described and nobody re-read the code. **This is the wrong-cause class turned
  on the project's own records** — and it is worse there than in app copy, because a wrong
  cause on a screen sends one person to the wrong place, while a wrong cause in a status
  document sends every future reader. **Before repeating a recorded failure reason, check it
  against the code that produces the failure.** Rule established by the planning session,
  2026-09-02.

### 15. "These two cannot disagree" is a claim about identity, not only about code.

- **"These two cannot disagree" is a claim about identity, not only about code.**
  `backup_status.sh`'s header said it and `docker compose ps` could never disagree, because they
  run the same program. On 2026-09-02 they did: the script runs as the person typing it, the
  scheduler ran as uid 70 and could not read `/backups`, so one reported *50 hours old, backups
  have stopped* and the other *freshness unknown*. **Same code, different identity, different
  answer.** Before writing that two paths must agree, ask what differs besides the code — **who
  they run as, where they run, and what they can see.** Rule established by task 11.125,
  2026-09-02.

### 16. A harness that patches a named line is coupled to code it does not own, and the coupling is invisible from the owning side.

- **A harness that patches a named line is coupled to code it does not own, and the coupling is
  invisible from the owning side.** Task 11.89 replaced a name denylist with an allowlist and
  deleted a line that `verify_11_85_broken_control.py` patches to prove it can detect anything.
  **The harness went red and the detection proof stopped existing — while the instrument it
  vouches for went on reporting clean.** The harness checking that its own patch text was found
  is what made this visible at all, and it runs at harness time; **nothing runs when the target
  changes.** So: **a detection proof's patch target is a dependency, and a refactor is exactly
  when it dies.** **The same shape appears wherever one file names a string another file
  implements** — task 11.128 found it in a compose `healthcheck:` naming a flag
  `bin/server.dart` provides, where a rename would not fail loudly but would leave a container
  reporting unhealthy forever with nothing saying why. **The guard it wrote for that is the
  group in `server/test/security/shipped_defaults_test.dart`; point the next one at that rather
  than writing a fresh one-off.** Rule established by task 11.125 and extended by 11.128,
  2026-09-02.

### 17. "Nothing broke" is a result, and a brief that assumes otherwise should say so.

- **"Nothing broke" is a result, and a brief that assumes otherwise should say so.** Task
  11.118 was asked to name which existing tests changed behavior once the fixtures got harder.
  **None did** — the end-to-end suite went 74 → 75 and stayed green with a tag on every publish
  fixture and a truth point added. **That is evidence, not an empty answer:** it means task
  11.43's ordering fix genuinely holds and the tests already passing on the tag path were
  passing for the right reason. **A brief that expects enrichment to break something must accept
  "it did not" as an answer**, or the next task quietly goes looking for a failure to report.
  Rule established by task 11.118, 2026-09-02.

### 18. A check that says it reads "every file in the repository" must ask git what that means.

- **A check that says it reads "every file in the repository" must ask git what that means.**
  Task 11.118 found one also reading `.agents/` — a directory the tooling generates for itself,
  which git ignores and no commit contains. It held a stale copy of an old task's instructions
  and failed the check on a line the real file no longer had, **so `flutter test` was red on
  Michael's machine and green in CI, over a file he could not have fixed by editing anything.**
  **"Every file on disk" and "every file in this repository" are different sets, and only one of
  them is what a guard means.** Rule established by task 11.118, 2026-09-02.

### 19. A test surface chosen to make one thing fit is a claim about width as well as height, and nobody re-examines it.

- **A test surface chosen to make one thing fit is a claim about width as well as height, and
  nobody re-examines it.** Task 11.126 pumped two screens at real 6.1-inch phone geometry for the
  first time and **all three overflows showed up in the first run** — a dialog row over by 139
  pixels, a dropdown by 5.3, and two button rows by 63 and 64, which means **"Paste from
  clipboard" has been cut off on every phone since it was written.** None was a regression. Each
  was live and invisible because the surrounding tests set 800×1600 **for an unrelated reason** —
  a dialog that overflowed *vertically* at 800×600 — and nobody went back. **This is task
  11.109's rule one layer out:** when you widen or heighten a test surface to make something fit,
  you have asserted a geometry, and the assertion outlives the reason. Rule established by task
  11.126, 2026-09-02.

### 20. A pre-check may be more permissive than the write it precedes. It must never be less.

- **A pre-check may be more permissive than the write it precedes. It must never be less.** Task
  11.126 found the tag database's create-tag button asking whether the person may write to the
  **active** project while the write asks about **whichever project the dialog offered** — so a
  viewer with no active project is offered the button and refused at Save. **That is the two-layer
  design working, not a hole:** the write is the authority and it refused. **Recorded because it
  reads exactly like a defect**, and the next person to notice it should not re-derive it as one.
  The invariant is the useful half — a pre-check that is *stricter* than the write hides a
  capability the person actually has, and nothing will ever tell them. Rule established by task
  11.126, 2026-09-02.

### 21. Widget-test layout numbers are measured in a font about twice Roboto's width, so some savings are exact and others are fiction.

- **Widget-test layout numbers are measured in a font about twice Roboto's width, so some
  savings are exact and others are fiction.** Task 11.133 found it while pricing space on the map:
  **savings from padding, margins and tap-target constants are exact** — a pixel removed is a
  pixel removed. **Savings from joining two facts onto one line are understated, sometimes to
  zero**, because the joined line wraps in the test font when it would not on a phone. So a
  layout change that reads as "no improvement" in a widget test may be a real improvement on the
  device, and **the two kinds of saving must not be reported as one number.** Rule established by
  task 11.133, 2026-09-02.

### 22. A question that costs more to answer than to satisfy should be satisfied.

- **A question that costs more to answer than to satisfy should be satisfied.** Task 11.133 could
  not settle from Esri's published pages whether "Powered by Esri" was owed at all. **The text is
  four words and their terms allow it behind a button.** Further research was the expensive
  branch and being wrong was the costly one, so the decision was to add it. **This applies wherever
  a compliance question is cheap to satisfy and slow to resolve** — and it is not license to skip
  research where the obligation is large, or to add claims that are untrue. Rule established
  2026-09-02.

### 23. A rendering change cannot be closed by a test suite, so scope it to one change and stop.

- **A rendering change cannot be closed by a test suite, so scope it to one change and stop.**
  Task 11.87 ran to **four addenda and three designs** — a smoothed vector boundary, then a single
  filled polygon, then back to a flat raster with no boundary at all — and **the only thing that
  ever decided anything was Michael looking at a phone.** The execution environment cannot run the
  app, so every judgement in between was made on test output about something whose whole purpose
  is how it looks. **Two real defects were found on the way** (a boundary built from tens of
  thousands of points, and a corner-rounding step that could move a point ~500 m), so the work was
  not wasted — **but the original complaint was never reproduced and is now unreproducible,
  because the design that had it was replaced twice.** So: **for map, layout and rendering work,
  ship one change and stop for a device look.** Iterating three designs before anybody sees one is
  how a task ends unable to say whether it fixed the thing it was for. Rule established by task
  11.87, 2026-09-02.

### 24. A "Violated by" list is a rule, and shipping past one is how a model and its code drift.

- **A "Violated by" list is a rule, and shipping past one is how a model and its code drift.**
  Task 11.124 added a field naming the offending column to the push response — a good change,
  carefully bounded — **and `TriTrack_Security_Model.md` §4.13's violated-by list already said "an
  error that names a table or column."** Nobody checked. **The change survived review because it
  is genuinely different from what that clause is about** (the caller's own field named back to
  it, on `invalid` only, never on `unauthorized`) — **but it needed an explicit exception written
  into the model, not silence.** So: **before adding anything to a response, read the violated-by
  list of the section that governs it**, and if the change is right anyway, **amend the model with
  the reasoning and a reopen trigger** rather than leaving the code and the model to contradict
  each other until a gate round finds it. Rule established by the planning session, 2026-09-02.

### 25. A command file outlives its task, and the window it opens cannot tell.

- **A command file outlives its task, and the window it opens cannot tell.** Task 11.37 was
  re-invoked on 2026-09-02 — **four days after it was finished** — and the fresh window had no
  way to know from the command alone; it re-derived all six items against the code before
  concluding nothing was needed, which is the right behavior and a wasted run. **The planning
  session then measured the directory: 122 of 152 command files were for tasks already Done,
  merged, canceled or superseded**, and deleted them. **`CLAUDE.md` already records two
  instances of the stale-command class, both about *ordering* (`/w-04`, `/11-89`); this is the
  same hazard from *completion*, which is the commoner one.** So: **the planning session deletes
  a task's command file when it resolves that task's comms entry** — the command and the Status
  field are two copies of "is this work outstanding", and this project's oldest rule is about
  exactly that. Rule established 2026-09-02.
  **Amended 2026-09-07, task 11.191, after the guard caught the habit rather than a person.**
  `command_file_staleness_test.dart` reads the plan's `Status:` field directly, so a task that
  marks itself Done and leaves its command file in place reddens `main` before the planning
  session ever resolves its comms entry — and the pre-commit hook then refuses the commit, which
  is what happened to task 11.187. **A task now deletes its own command file in the same commit
  that marks it Done.** The planning session still deletes one only when it resolves a task's
  comms entry on the task's behalf — a task that stops short (`Partial`, `Deferred`) leaves its
  command in place, because those are legitimately re-runnable and the check lets them pass.
  **This is the good failure mode: the convention above was a habit, task 11.179 built something
  that can refuse, and the sentence lost.**

### 26. A TODO names code it does not own, and a deletion never comes back to correct it.

- **A TODO names code it does not own, and a deletion never comes back to correct it.** Task
  11.138 found a permanently-grayed "Import DEM file" button whose comment said it needed
  *"re-wiring to the tiled DEM store"* and named `DemRepository` as the thing to re-wire —
  **`DemRepository` had been deleted months earlier**, so the comment sent every reader to a class
  that does not exist, and the dead button read as work-in-progress rather than as debris.
  **Same shape as a harness patching a line it does not own, and as a status document repeating a
  failure reason nobody re-derived.** So: **before repeating a TODO's stated plan, check that what
  it names still exists** — and a TODO whose named fix is gone is evidence about the feature, not
  a task description. Rule established by task 11.138, 2026-09-02.

### 27. A report's description of code is not the code, and the planning session keeps forgetting it.

- **A report's description of code is not the code, and the planning session keeps forgetting
  it.** Task 11.138's brief described three controls as bare icon buttons with no label; **two of
  them had visible labels and an on-screen reason already, and the tooltip was a pure duplicate.**
  The description came from the previous task's report and was written into a task entry without
  anybody opening the files. **This is the fifth time a brief has asserted a mechanism the code
  did not have** (11.83's design sentence, 11.105's `ProviderException`, 11.102's tag-name width,
  11.124's schema bump, and this). **A report is evidence about what its author saw; a task entry
  is an instruction about what is there.** Open the file before the entry asserts what is in it.
  And the sweep lesson underneath: **a control whose reason is already on screen a few pixels away
  is not the same defect as one whose reason exists nowhere — counting tooltips does not separate
  them.** Rule established 2026-09-02.
  **Sixth instance, 2026-09-04, and a variant worth naming separately.** Task 11.144's entry and
  `/w-10`'s report both called a crash *"task 11.95's class on a different screen"* — a side
  effect called from a widget's `build`. **It was neither**: nothing on that screen called a side
  effect from `build`, and the fault was one of its providers deriving from another. The other
  five instances were a brief describing code nobody had opened; **this one is a brief naming a
  *cause* from a matching symptom**, which is worse, because it survives being read — the fix it
  points at is plausible, applies cleanly, and would have left the real fault in place.
  **A cause inferred from a resemblance is a hypothesis and must be written as one**, with the
  measurement that would settle it named beside it. Two identical assertions was two guesses, not
  corroboration.
  **Eighth instance, 2026-09-04 — and the first one caught by its author, which is worth more
  than the rule.** Task 11.154 found what looked like a live defect: signing in adopts a server
  identity, rewriting the user column of every synced table and hard-deleting the old `Users`
  row, while `auth_provider.dart` invalidates only `currentUser`. **It wrote the fix, wrote a
  test for it, and then found the test passed with the fix removed** — `ServerIdentityAdopter`
  already announces through `DataArrival` at the end of `adopt()`, and task 11.45's own comment
  there says so. The fix was reverted; it cost about fifteen minutes. **What caught it was the
  standing requirement to watch the test go red before believing it green**, and nothing else
  would have: a passing test beside a plausible fix reads as confirmation. **So the two rules
  are one rule.** A cause inferred from a resemblance produces a fix that appears to work, and
  the only thing standing between that and a permanent wrong explanation in the codebase is
  making the check fail on purpose first.
  **Ninth instance, 2026-09-04, and this one was a count derived from a grep.** Task 11.155's
  brief named **eight** bare `actions/checkout@v4` steps. There were **seven**:
  `broken-control-check` has carried `fetch-depth: 0` since the first CI commit. The brief's
  author had counted nine checkout lines, counted two `fetch-depth` matches in a context grep,
  attributed both to the file just edited, and subtracted. **`CLAUDE.md` already says a grep tells
  you a token appears, not what it means — a *count* of grep matches is that same error with
  arithmetic on top.** The brief also asserted a *reason* it had not read: that a shallow clone
  "cannot create" a `git worktree`. **Measured false** — a depth-1 clone makes one fine, which is
  all those scripts ask of git, and the full clone that line was paying for was removed.
  **And the axis itself was wrong: no job outside `offline-suite` reads git history at all.**
  What saved the task was the half of the brief that was not an assertion — *ask each job what it
  reads from its environment, not just how deep its clone is* — **which is why a brief should
  widen a question rather than answer it.**
  **Tenth instance, 2026-09-04 — and this is the one that cost something.** Task 11.103 wired
  `currentProjectProvider` into the Offline Data Map, watched that suite go from under a second to
  minutes, **backed the improvement out**, and recorded the provider as possibly expensive on a
  phone. Task 11.120 measured it: the cost was **the tile counter building the whole tile list to
  measure its length, at the whole-planet default zoom** — *the defect 11.103 itself found and
  fixed in the same commit.* Its own report says "found because the new default zoom took this
  suite from under a second to four minutes" **four paragraphs from the sentence blaming the
  provider for the same symptom**, and nobody joined them for three days. The provider costs
  **9–21 ms once per launch and 8.8 microseconds per rebuild.** **A real feature stayed unbuilt for
  three days on the strength of a resemblance**, which none of the earlier instances did.
  **The reusable form is worth more than the instance: when a task fixes a performance defect and
  also observes a performance symptom, ask whether they are the same one before attributing the
  second to anything else.** The thing being changed at the time is the most available suspect and
  the least examined.
  **Thirteenth instance, 2026-09-05, and it was about the planning session's own tools.** Asked
  whether it could run the remaining tasks itself, this session answered *"I have a shell on your
  machine and could edit, test and commit."* **It cannot test.** `device_bash` runs in an isolated
  Linux VM with the repository mounted — `flutter`, `dart` and `docker` are all absent from it, and
  one `command -v` would have said so. **The claim was checkable in a single command and was made
  from an assumption about what a shell implies.**
  **The rule this leaves: a capability is a fact about the environment, and asserting one without
  running it is the same error as asserting a mechanism without opening the file.** It is worse in
  one respect — **the environment is the cheapest thing in this project to check.**
  **Fourteenth, the same day, and this one broke the build.** Writing task 11.171's command file,
  this session copied the e2e runner's literal invocation out of a report and into the brief.
  **`CLAUDE_DOCS/SETUP_OWNERSHIP.md` says `scripts/run_e2e_tests.sh` owns that step and every other
  mention points at the owner rather than repeating it**, and `setup_step_ownership_test.dart`
  enforces it. **So the commit that recorded "the push gate is red" made it red a second way, for a
  different reason, while writing the task to fix the first.**
  **The rule is about this session's own outputs rather than about the app: `.claude/commands/*.md`
  are repository files and the repository's guards read them.** A brief is not scratch. **When a
  brief needs to name a command a document owns, it points at the owner and describes the flags** —
  which is what the ownership rule asks of every other file, and there was never a reason to think a
  command file was exempt. Rule established 2026-09-05.
  **Twelfth instance, 2026-09-05, and it is a worse shape than the eleven before it: an unverified
  premise written as a prohibition.** Task 11.166's brief said *"the floor holds at every text size
  today"* — copied from the previous task's report rather than read — **and then added "the task
  must not report otherwise."** It does not hold: `bandHoldsThrough` has recorded **AX1** as the last
  stop since task 11.149, and the biconditional above it *requires* the band to be under the floor
  from AX2 up. Measured: **229 / 191 / 152 / 134 / 102**, then **30, 14, 14, 8**. **The refutation
  was in a file the brief itself cited.**
  **Asserting a premise is a mistake the executor can correct. Forbidding the correction is a
  mistake it has to overrule you to fix**, and only a careful one will. **So: a brief may forbid an
  *approach*; it may never forbid a *finding*.** If a sentence in a brief begins "the task must not
  report", it is describing the world rather than the work, and the world is not the brief's to
  settle.
  **Eleventh instance, 2026-09-04, and it is the planning session's own.** Task 11.145's brief
  asserted *"a sync round does not move `currentUserProvider`, `serverConfigProvider` or
  `mayWriteProjectDataProvider`"* — **an inherited sentence rather than a fresh reading.**
  `arrival_refresh.dart` had been in the tree for a day, and `refreshProjectViews` invalidates
  `mayWriteProjectDataProvider` on every `DataArrival`. **What made it visible was running the
  derivation over the whole corpus instead of the three providers the brief named** — which is the
  existing rule about deriving rather than checking the rows you already believe.
  **Sixteenth instance, 2026-09-07 — a list of four, assembled without reading the entries.** Task
  11.186's brief said four rendering tasks had ended by asking Michael to look, and named 11.177,
  11.149, 11.166 and 11.185. **Two of the four are not instances.** 11.177 measured its needle at
  10.5° and its two markers at 20.5°, fixed all three and asked nothing; 11.166's entry contains no
  device request at all. **The real count, derived under a stated inclusion rule, is 20 requests
  across 16 tasks** — and the 11.87 viewshed family alone is five of them. **The brief was wrong in
  both directions and it did not matter, because the half of it that was an instruction said
  *count this rather than trusting it*.** That instruction has now paid out four times
  (11.155's checkouts, 11.123's routes, 11.182's measurement, this). **The pattern to keep: put the
  planning session's number in the brief so the task has something to disagree with, and tell it
  in the same sentence to re-derive.** A brief with no number gives the task nothing to check; a
  brief with a number and no instruction gives it something to inherit.
  **Fourteenth instance, 2026-09-06, and it is the third quantity in a row.** Task 11.123's brief
  said §4.21.2 was missing rows for **ten** join-settings, join-code, join-request and re-admission
  routes, and that **three** of them were grants. **There were nine of those routes, and two of them
  are grants** — rotating a join code and switching joining on grant nobody anything. **The tenth
  missing row was `GET /auth/sessions`**, an auth route the brief did not know existed and that has
  been absent from that table since it was written. **The count was right by accident and its
  contents were wrong**, which is worse than a wrong number: a hand-check of the routes the brief
  named would have closed the table and left `/auth/sessions` out. **The derivation found it because
  it enumerated the routes rather than reading the list it was handed.** With the eighth (nine
  checkouts, seven real) and the seventh (a per-write cost that is per sync round), that is three
  briefs in a row whose *numbers* were the false part. **A count in a brief is an assertion about
  the code. Derive it, or say it is approximate and tell the task to derive it.**
  **Seventh instance, 2026-09-04, and this one was a *quantity* rather than a mechanism.** Task
  11.153's brief warned that refreshing permission providers on every announcement would cost
  *"including every bearing saved"*. **A bearing saved never reaches `DataArrival` at all** — it
  calls `recordingsRevisionProvider.bump()` directly. There are seven announce sites and the
  dominant one is a merged sync page, **so the real frequency is per sync round that changed rows,
  not per write** — and the measured cost turned out to be 15.4 ms. **A brief that overstates a cost
  is not the harmless direction:** it argues for caution the evidence does not support, and a task
  that believed it would have built something more complicated than the problem. **Numbers in a
  brief are assertions about the code and get checked like any other.**

  **Nineteenth instance, 2026-09-20, and the wrinkle is what makes it worth recording.** Task
  11.290's brief said *“the purge already works”* while arguing the task should reuse it. **It does
  not run at all** — `TombstoneRetentionService.purge()` is called from nowhere, which the task found
  by grepping for the call while reusing the table order beside it. Filed as task 11.291. What is new
  here is **why the sentence was believable**: the *guard* around the purge is real and well tested —
  `StaleCursorException` exists, fires, and has cases written against it — and **a mechanism whose
  boundary is carefully tested reads as a mechanism that runs.** The tests were evidence about the
  refusal, not about the sweep, and the brief's author read the one as the other. **So the check is
  not "are there tests" but "what do the tests execute".** A guard can be exercised entirely by
  tests that construct the condition themselves, and never once by the thing that would create it in
  production.

  **Twentieth instance, 2026-09-20, and all three of the brief's numbers were wrong at once.** Task
  11.296's brief, written by the planning session from task 11.294's finding, said the temp-directory
  leak came from **three test files**, that the count was **199,261**, and that the directories were
  **all empty**. The task derived each instead of inheriting it. **The real shape: one global
  `setUp` in `flutter_test_config.dart` that runs before every test in the suite**, plus 17 files
  calling the helper again mid-test — which is *why* the leak was per-test rather than per-file, a
  mechanism the brief's number had quietly denied. The real count was **1,830,039**, because 199,261
  was a sample of the first 200,000 entries. And **0.71% of a 20,000-directory sample held a small
  file**, about 130 MB in total.
  **Two of the three are the planning session losing information that was present in its source.**
  11.294's finding said *"199,261 of the first 200,000 entries"* — the sampling caveat was there, it
  survived into the plan entry, and it was **dropped from the command file and from the chat
  message to Michael**, where it became a flat count. *"All empty"* was never measured by anybody;
  it was an inherited impression restated as a property. **A caveat that survives into one
  derivative document and not the next has not survived**, and the one people act from is usually
  the shortest one.
  **What caught all three is the sentence beside the numbers**: *derive it from the directory, not
  from what this brief names.* That instruction has now paid out five times (11.155's checkouts,
  11.123's routes, 11.182's measurement, 11.186's list of four, this). **Put the number in so the
  task has something to disagree with, and tell it to re-derive in the same sentence** — and when a
  number is a sample, say so in *every* document that repeats it, not just the one where the
  sampling happened.

  **Twenty-first instance, 2026-09-21, and it is time to draw the practical conclusion.** Task
  11.303's brief said four refusal codes share the "Update needed" headline. **There are five** —
  `project_destroyed` also carries a sentence, and the classifier checks for a sentence before it
  splits on the `403`, so a project deleted by its owner was headed "Update needed" too. Derived by
  a test that runs **every code the client recognizes** through the real classifier.
  **That is the third consecutive brief of mine whose number a task had to correct** (11.296's
  three files and 199,261; 11.298's four addresses; this). Each time the instruction beside the
  number — *derive it, do not take it from here* — is what caught it, so the instruction is working
  and **the numbers are not getting better.** The conclusion is not "stop putting numbers in
  briefs": a brief with no number gives the task nothing to disagree with, which is entry 27's
  older finding. **It is to mark the number's provenance in the brief itself.** A number I derived
  and a number I counted off a report look identical on the page and are worth completely different
  amounts. So: **when a count in a brief was not derived by the person writing the brief, the brief
  says so in those words** — "read from task N's report, not derived" — and the task then knows
  whether it is checking a measurement or replacing a guess.

  **Twenty-second instance, 2026-09-21, hours after the twenty-first, and it is the rule above
  paying out the same day it was written.** Task 11.304's brief said *three* doc comments claim
  sign-out clears every project's cursor. **There are eight** — six in `lib/`, two in test comments.
  The brief's three were the ones I had seen quoted; the task found eight by **a census on the
  subject** (`grep -i` for sign-out across `lib/`, `test/` and `server/`, every hit read whole)
  rather than on the phrasings, which is exactly the fix written into the sample rule in `CLAUDE.md`
  the day before. **The rule was written on 2026-09-21 from the container-count miss and earned its
  keep on 2026-09-21 from an unrelated one.**
  **What makes this one worth its own line rather than a tally mark:** the brief's number was not
  merely low, it was **low in a way that would have left the defect in place**. Correcting three of
  eight comments leaves five files still asserting a behavior the code does not have, and the next
  task reads one of them — which is how 11.299 acquired the sign-out-then-re-join route four days
  earlier. **An undercount in a documentation sweep is not a smaller version of the fix; it is the
  fix failing quietly.**

  **Twenty-third instance, 2026-09-22, and it is the provenance rule being broken one day after it
  was written — by the person who wrote it.** Task 11.306's brief said **five** generated files were
  stale. **Three were.** The other two were already current, which the task established by running
  `build_runner` twice and getting no second output rather than by inspection. I took "five" from
  task 11.305's report, which had said five, and **passed it on without the provenance marker the
  twenty-first instance had just introduced.** The rule existed, applied exactly, and I did not
  reach for it.
  **So the rule is sharpened, because a convention I forget is not a control.** Marking a number's
  provenance still depends on remembering to mark it. **Replace the number with the derivation.**
  A brief that says *"five files are stale"* invites inheritance; a brief that says *"run
  `build_runner` and report which files it rewrites"* cannot be inherited wrongly, because there is
  no number in it to inherit. The older finding — that a brief with no number gives the task nothing
  to disagree with — is satisfied better this way: **a command gives the task something to run,
  which beats something to disagree with.** Keep a number only where no command produces it, and
  there write where it came from. — and the first time the guard caught it rather than a person.

- **One file naming a string another file implements — and the first time the guard caught it
  rather than a person.** `app_shell_harness_default_test.dart` derives *which screens live inside
  the tab shell* by finding the literal `StatefulShellRoute.indexedStack(` in `app_router.dart`.
  Task 11.160 moved to the plain constructor, **the search found nothing, and the guard refused to
  pass on an empty set** — so it went red instead of silently deriving zero screens and agreeing
  with itself. That is the third instance of this coupling (the compose `healthcheck:` line and the
  degradation-report runbook line are the others) **and the only one not found by somebody
  noticing.** The lesson is not the coupling, which is sometimes unavoidable: **it is that a
  derivation must refuse an empty result.** A search that finds nothing and a subject that contains
  nothing are indistinguishable from the inside, and only one of them is true. Rule reinforced
  2026-09-04.

### 29. A bound on change cannot constrain a creation, and the falsifier you name is not the only one.

- **A bound on change cannot constrain a creation, and the falsifier you name is not the only one.**
  Task 11.159's brief offered bounding a row's revision *increment* rather than its value — the
  server knows the current revision, so *current + N* is a guess about one push rather than about
  years. **It named one falsifier: a long offline burst.** That was true and it was not the one that
  killed it. **The structural answer is that an insert has no increment**: a row the server has
  never seen is *inserted*, so a delta bound is never consulted on the first push — **which is the
  cheapest way to plant the very thing being bounded.** The brief's whole premise assumed an
  update.
  **Two lessons, and the second is the reusable one.** A delta rule must say what it does about
  creation, always. And: **naming a falsifier is not the same as looking for them** — a brief that
  offers a candidate and one way it could fail reads as having been stress-tested when it has been
  stress-tested once. **Say "here is a candidate and here is how to try to kill it", not "here is
  the thing that would kill it."** Rule established 2026-09-05.

### 30. A budget written for a child of a `Column` is not a budget — it is a comment.

- **A budget written for a child of a `Column` is not a budget — it is a comment.** A Flutter
  `Column` hands every non-flex child **unbounded** height, so a child cannot find out how much room
  the parent has. **Task 11.149 wrote the bound "the banners get at most a quarter of the frame"
  first, and measured it doing nothing at all.** The bound is now enforced by a render object that
  lays each banner into what the budget has left; the Offline Data Map's top row was a second
  instance of the same shape. **Anywhere in this app a budget is expressed for a child of a
  `Column`, it is not being enforced** — task 11.165 sweeps for the rest.
  **The rule stands; its worked example has moved (task 11.189, 2026-09-07).** The shell's banners
  are gone — no banner slot, no shedding order, no quarter-share bound — so a reader looking for the
  enforcing render object will not find it where the sentence above points. **It is `BudgetedColumn`
  now, and its only caller is the Record screen's pinned SAVE bar.**
  **The general form, and it is the same rule as 11.162's one layer down: a constraint has to be
  imposed by something that can refuse.** A number in a comment, a number in a test, and a number a
  parent actually enforces are three different strengths, and only the third survives somebody
  adding a widget. **Ask what would say no.** Rule established by task 11.149, 2026-09-05.
  **Swept on the height axis by task 11.165, 2026-09-05: eleven distinct budgets in `lib/`, nine
  enforced, one out of the class, one inoperative** — and the inoperative one was the Record
  screen's pinned SAVE bar, whose written rule said it does not grow while nothing could refuse a
  line added to it. **A one-in-eleven hit rate is the number to quote when somebody argues this
  class is theoretical.** The width axis (`Row` children) is task 11.166 and is where this
  project's actual overflow history lives.
  **Swept on the width axis by task 11.166, 2026-09-05: seven budgets, seven enforced, zero
  inoperative — and the ranking argument that predicted otherwise was right for a reason that
  explains the zero.** Every horizontal overflow this project has seen was fixed by putting the
  child in a `Flexible` or an `Expanded`, **which is enforcement**; tasks 11.102, 11.133, 11.147,
  11.149 and 11.162 had already swept that axis one defect at a time. **A history of symptoms is
  evidence about where defects *were*, not where they remain** — and the remedy that fixed them
  each time is what makes the sweep come back empty.

### 31. Where a file already derives part of its own set, the repair belongs in that derivation — a guard elsewhere naming a subset is a hand-kept list wearing a guard's clothes.

- **Where a file already derives part of its own set, the repair belongs in that derivation — a
  guard elsewhere naming a subset is a hand-kept list wearing a guard's clothes.** Task 11.171's
  brief said *"rank before guarding — a sweep that guards everything is worse than the gap"*, and it
  ranked, and then **measured the file and found the ranking unit wrong.** `gate_smoke_test.sh`
  already derives which wire-speaking instruments must run and refuses an empty derivation — **but
  it derives from the Python files that import its wire helper, which is 11 of the 22 lines in it
  that run something.** The three the brief named sit among eleven unguarded lines, **beside two
  whole drills.** Naming three of eleven in a Dart test **would have asserted that a detection proof
  matters more than the drill it is a proof about**, and split one file's answer across two files.
  **So: before guarding N items from outside, ask whether the thing they belong to already knows how
  to enumerate itself. If it does, widen that** — the count you would have guarded is the measure of
  how wrong the outside list would have been. Rule established by task 11.171, 2026-09-06.

### 32. A check whose only exercise is a twenty-minute Docker run is a check whose own failure modes nobody watches.

- **A check whose only exercise is a twenty-minute Docker run is a check whose own failure modes
  nobody watches.** Task 11.172 gave `gate_smoke_test.sh` a `GATE_SMOKE_COVERAGE_ONLY=1` mode that
  runs its derivations and **nothing else** — no Docker, no stack, no instrument. **That is what made
  31 sabotages cost a second each instead of twenty minutes each**, and 31 sabotages is why its
  coverage claim is believable. **The obvious danger is the lying-instrument class and it is
  handled**: that mode prints *"NOTHING WAS RUN. No instrument executed, no server was reached and
  no control was exercised"* rather than anything a reader could mistake for a gate result.
  **So: when an instrument is expensive to exercise, give it a cheap mode that exercises its own
  logic and says loudly that it proved nothing about the subject.** An instrument nobody can afford
  to break on purpose is an instrument nobody has broken on purpose. Rule established by task
  11.172, 2026-09-05.

### 33. A flag that is always set in one mode carries no information in that mode.

- **A flag that is always set in one mode carries no information in that mode.**
  `gate_smoke_test.sh`'s wire derivation reported its failures through `FAILED_ANY` — **and under
  `GATE_SMOKE_SELFTEST=1` every wire instrument is *supposed* to fail, so that flag is always 1 and
  the self-test branch never read it.** The derivation could not fail a self-test run. Fixed in
  11.172 by routing both derivations through one flag the self-test checks.
  **The general form: before reporting through a shared signal, ask what that signal reads in every
  mode the program has** — a channel that is saturated in one mode is silent in it, and the mode
  where it is saturated is usually the adversarial one somebody built to find exactly this.
  Rule established 2026-09-05, at the executor's suggestion; **no sweep is scheduled, because the
  instance is fixed and the population is narrow. The trigger is the next task that touches a
  multi-mode script.**

### 34. A named instrument that reports PASS having measured nothing is worse than one that disappears, because the name is what a reader looks for.

- **A named instrument that reports PASS having measured nothing is worse than one that
  disappears, because the name is what a reader looks for.** Delete one line from
  `verify_c3_cleartext_defaults_stack.sh` and it still brings a compose stack up, tears it down,
  exits 0 — **and `gate_smoke_test.sh` prints `verify_c3_cleartext_defaults PASS`.** Same shape in
  `run_offline_suite.sh`: delete the port probe and the gate that runs on every push **still prints
  "verified: 127.0.0.1:8080 does not answer".** **A missing instrument is a hole somebody can
  notice; a lying one is a hole that answers questions.** Task 11.171 guarded both by **coupling
  rather than string-matching** — reading the address out of the sentence the script prints and
  requiring something to have probed *that* address. **Assert the claim against the act, not the
  wording.** Rule established 2026-09-06.

### 35. A pin to a rolling repository's *rebuild counter* is a scheduled outage, not a pin.

- **A pin to a rolling repository's *rebuild counter* is a scheduled outage, not a pin.**
  `server/backup/Dockerfile` pins `age=1.3.1-r5` — deliberately, under §3.8's rule that every
  dependency is pinned and reviewed. **Alpine rebuilt that package as `-r6` and removed `r5` from
  the index**, so `apk add age=1.3.1-r5` stopped resolving and three gate instruments went red at
  once. **No commit caused it: the file had not been touched since 30 August, and it broke on the
  calendar.**
  **The distinction that matters: `1.3.1` is a version and `-r5` is a *revision of the packaging*,
  which a rolling repository replaces rather than accumulates.** Pinning to it guarantees eventual
  breakage on somebody else's schedule. **So when pinning against a rolling index, pin something the
  index keeps** — the version itself, or a vendored artefact with a checksum — **and say in the file
  which of those you chose and what it gives up.** **A base-image digest is not on that list, and
  the planning session's brief wrongly offered it as one**: a digest freezes the base *image*, but
  `apk` fetches the package index over the network at build time, so a frozen base still resolves
  package names against today's rolling repository. **A reproducible base image does not give you
  reproducible packages.** Rule established 2026-09-06, after the gate went red for a reason nobody
  in this repository did.

- **Second instance, 2026-10-05 (task 11.327), and it disproves this entry's own advice.** The
  rule above said to *"pin something the index keeps — the version itself"*. **The index does not
  keep the version either.** Alpine's *stable* 3.24 branch upgraded `age` from 1.3.1 to 1.3.2 on
  2026-10-04 ("community/age: upgrade to 1.3.2" in Alpine's own history), so `age=~1.3.1` stopped
  resolving four weeks after it replaced `-r5`, taking the same three gate instruments with it.
  **The first break was caught within two days by GitHub's runners, which start with no cache. This
  one was hidden by the VM's build cache** until somebody cleared it, because GitHub's checks are
  paused and the night built on yesterday's cache; a fresh deployment would have been first to
  find out. **The corrected rule: when
  the source replaces versions, the only thing that holds still is the source's own release, so
  pin that and let versions float inside it** (here `FROM postgres:16-alpine3.24`, with floors on
  the package line so an older release is refused). **Then say what the release pin costs and
  instrument it**: Alpine stops fixing 3.24's community packages on 2026-11-01, and the nightly
  preflight reads that date from Alpine's `releases.json` rather than from a note. **And make the
  instrument rebuild from nothing**: the night now builds the image with no cache, because a check
  that reuses yesterday's build cannot see an index that changed today.

### 36. Two habits of the planning session are now enforced by tests, and meeting them mid-task is not a bug.

- **Two habits of the planning session are now enforced by tests, and meeting them mid-task is not
  a bug.** *(Task 11.179, 2026-09-06.)*
  **(a) Cite a line's content, never `path:NN`.** A ratchet counts the `path:NN` citations in each
  `CLAUDE_DOCS/*.md` and the count may fall, never rise. **`DEVELOPMENT_PLAN.md` holds 249 of the
  698 and is the document written in most often, so the planning session will meet this first.**
  The failure message says what to do and it is not "raise the ceiling."
  **(b) Every plan entry needs a parseable `**Status:**` line.** The command-staleness check reads
  a task's status from the plan, so **an entry whose opening says neither that the work is
  outstanding nor that it is finished fails the run** rather than passing. Two entries state it in
  prose today (11.50's *"STAY DEFERRED"*, 11.80's *"PARTIAL 2026-09-01"*) and both are read
  correctly; do not add a third on purpose.

### 37. A capability that has been removed keeps its row, struck through and dated.

- **A capability that has been removed keeps its row, struck through and dated.** Set as a
  convention in `PERMISSIONS_MATRIX.md` on 2026-09-07. **Deleting the row leaves the security
  model's arguments pointing at nothing**, and a later reader cannot tell *this was decided
  against* from *nobody thought about it* — the second invites somebody to build it. **The marking
  is the load-bearing part**: the two cloud-backup rows read as live for eight days after the
  commit that deleted the feature.

### 38. A check that compares a widget's value to a theme token is keyed on the token's *name*, and passes whatever that name resolves to.

- **A check that compares a widget's value to a theme token is keyed on the token's *name*, and
  passes whatever that name resolves to.** Task 11.197's test asserted the Irregular/Malfunctioning
  label's color **equalled `scheme.onSurfaceVariant`** — and `onSurfaceVariant` was never passed to
  this app's `ColorScheme`, so it resolved to full-strength body text. **The test was a good test of
  the call site and no test at all of the outcome**, and Michael's *"light gray by default"* went
  unmet with a green suite over it. **When a check compares a widget to a token, ask what it does
  when the token is wrong** — assert the *contrast*, or the actual value, or something the theme
  cannot silently redefine. This is the comparison-between-two-things-that-fail-identically rule with
  the two things being **a widget and a theme** rather than two rows. Rule established 2026-09-08.

### 39. A guard finds what reports do not, and that is the argument for building one at the fifth report rather than the tenth.

- **A guard finds what reports do not, and that is the argument for building one at the fifth
  report rather than the tenth.** Task 11.199's brief said **two** display sites were left, taken
  from five reports over nine days. **The guard it built found six, in four files — four of which
  nobody had ever reported.** The reports were an accurate record of what people happened to notice;
  **they were never a census, and no number of them becomes one.** **When a defect shape has been
  reported enough times to be called a shape, the next task is the instrument, and its first run is
  the first honest count.** Rule established 2026-09-08.
  **Second payout, the same day, and this one was not cosmetic.** Task 11.201's guard over undefined
  `ColorScheme` members found a **seventh** site nobody had reported: `onErrorContainer` fell back to
  `onError`, which this theme sets to **white in both modes**, and the Record screen draws *"Viewers
  cannot record observations — ask an owner to change your role"* in it **with no tinted box behind
  it.** **In light mode that was white text on a light form — 1.00:1, measured, and reproduced by
  removing the token again.** **A refusal sentence that is not there at all is the
  silent-write-failure class wearing a color**, and no report would ever have produced it: **nobody
  can report a sentence they cannot see.**

### 40. The website's copy-drift check is its own workflow. A green pre-commit hook says nothing about it.

- **The website's copy-drift check is its own workflow. A green pre-commit hook says nothing about
  it.** `check_app_quotes.dart` runs in `website.yml`, not in `flutter test`, so a task that renames
  a heading commits cleanly, reports honestly, and **leaves the website build red without anybody
  being told.** Task 11.197 did exactly that and its follow-up found **six** broken quotes, five of
  them from the earlier commit. **A task that changes user-visible copy runs
  `dart run website/tools/check_app_quotes.dart` before it reports. It takes about ten seconds.**
  This is the local-gate-and-push-gate-cover-different-sets rule with a third set in it. Rule
  established 2026-09-07.

### 41. Do not animate in response to something that is itself animating — you will produce the jitter you meant to smooth.

- **Do not animate in response to something that is itself animating — you will produce the jitter
  you meant to smooth.** Task 11.197's notes-box reveal animated each correction over 180 ms, and
  **the keyboard reports its height on every frame of its rise**, so every frame started a fresh
  animation that interrupted the one before it. **Jumping once per frame is what looks continuous**,
  because the smooth motion the eye sees is the keyboard's own. **Anything that reacts to
  `didChangeMetrics` has this shape.** Rule established 2026-09-07.

### 42. An assertion that something is gone, made by looking for its absence, can pass for reasons that have nothing to do with the change.

- **An assertion that something is gone, made by looking for its absence, can pass for reasons that
  have nothing to do with the change.** Task 11.197's first Note test searched for the text of an
  *unselected* record type — which **finds nothing on any record type whatever happens**, because the
  unselected segments are icons now — **and could not have worked by absence anyway**, since that
  form is a `SingleChildScrollView` and nothing in it is ever missing from the tree. **Two
  independent reasons for a green that meant nothing, in one assertion.** It was caught only because
  the numbers beside it looked too small. **Assert by position, size or order — something with a
  value in it — rather than by a thing not being found.** Rule established 2026-09-07.

### 43. Simplicity and readability beat verbosity, so long as the option is findable by exploring or by tapping an information affordance.

- **Simplicity and readability beat verbosity, so long as the option is findable by exploring or by
  tapping an information affordance.** Michael's standing instruction, 2026-09-07, after walking the
  Record screen: *"Generally in the app, we need to emphasize simplicity/readability in design over
  verbosity so long as the user can eventually figure out the options through exploration or clicking
  on an information/details icon."* **So a heading that repeats what the control obviously is comes
  out** — *Record type*, *Tag*, *Bearing* did; **a label shortens when the short form is unambiguous
  in place** — *Bearing quality* → *Quality*, *Pulse mode* → *Mode*; **and a disclosure control does
  not list its own contents** — *"Advanced: bearing method, antenna type, receiver gain"* → *Advanced*.
  **The test is whether a person can find it, not whether the screen announces it.**
  **Two things this does not license, and both matter more on this app than on most.** **It is not a
  license to drop the accessibility label** — a visual heading removed is a heading a screen reader
  still needs, and that is a `Semantics` label rather than a deletion. **And it does not override the
  rule below**: where getting it wrong writes the wrong data, the current state still has to be
  unambiguous without relying on a color or a bare glyph. Rule established 2026-09-07.

### 44. Color never carries a meaning on its own in this app. The word is the answer; the color is the accelerator.

- **Color never carries a meaning on its own in this app. The word is the answer; the color is the
  accelerator.** A colored dot with no word was the obvious reading of Michael's request for the
  Position screen's bearing rows, and it was rejected for two reasons that generalise: **there is no
  legend on that panel to teach one**, and **green and red are exactly the pair that collapses** for
  roughly one man in twelve. So the rows read `✓ Good`, `Fair`, `Bounce?` — colored, and legible
  with the color removed — and a test asserts the words are still there **so a later change cannot
  quietly trade them for a mark.** **This is the same rule as task 11.152's observer badge carrying
  initials rather than a color swap**, and it now governs both. **The exception, and it is the one
  place to watch:** the irregular-signal mark on that row is a warning triangle with no word beside
  it. **Michael approved it and it shipped; if it does not read, it becomes `⚠ irregular` at the cost
  of a longer line.** Rule established 2026-09-07.

### 45. A row that is out of the estimate keeps its dimming and gives its color up.

- **A row that is out of the estimate keeps its dimming and gives its color up.** Being excluded is
  the louder fact about that row, and **a green `✓ Good` glowing inside a grayed-out line says the
  opposite of what the row means.** Recorded because it reads like a defect the other way round, so
  the next person to "fix" it will be about to break it. Rule established 2026-09-07.

### 46. The copy-changes list is a convenience. The screenshot harness is the derivation. Do not confuse which one is the safety net.

- **The copy-changes list is a convenience. The screenshot harness is the derivation. Do not confuse
  which one is the safety net.** `WEBSITE_PLAN.md` collects the user-visible copy changes each task
  declares, so a content task meets one list instead of re-reading a month of reports. **Tasks
  11.189, 11.190 and 11.191 all landed without reaching it, because the planning session resolved
  their entries and did not append** — and `/w-14` only knew because its command file spelled the
  changes out. **The planning session appends when it resolves; that is the arrangement, and it is
  the thing that failed.** **But the conclusion is not more machinery:** the harness measured 26
  screens moving by 14-25% of their pixels and named every one, which the list could only ever have
  agreed with. **Keep the list because it makes the next content task faster. Never lean on it as
  the thing that would catch a missed change.** Rule established 2026-09-07.

### 47. A size that works as an annotation is not a size that works as a subject.

- **A size that works as an annotation is not a size that works as a subject.** Task 11.189's status
  dot was built once and used twice — the same widget at 8 pixels on the More *tab*, where it is a
  mark on a small icon and nothing else is in that corner, and on the More *screen's* Sync Status
  row, where it is a speck beside a title, a chevron and eleven neighbors. **Sharing the widget hid
  the difference rather than preventing it.** The repair kept the sharing where it belonged — one
  helper owns the severity, the visibility rule and the accessibility label — and **split the
  rendering, which is the half that is genuinely different.** **When one indicator appears in two
  places, ask which of the two things it is in each place** before deciding that one widget cannot
  drift. Rule established 2026-09-07.

### 48. Seventeenth instance, 2026-09-07, and it is the planning session breaking a rule it had adopted hours earlier.

- **Seventeenth instance, 2026-09-07, and it is the planning session breaking a rule it had adopted
  hours earlier.** Commit `088af59` wrote a `path:NN` citation naming line 69 of
  `recording-a-bearing.md` into `WEBSITE_PLAN.md` — **in the very entry about tracking documentation drift**, one day after this
  session adopted task 11.179's ratchet refusing exactly that shape. **`flutter test` went red on
  `main` and stayed red across three tasks, every one of which had to commit through
  `TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1`** — so the planning session's own slip disabled the
  pre-commit protection for everybody else until it was noticed. **Two things worth keeping.** The
  ratchet worked: it caught its author within a day, which is the whole argument for a rule that can
  refuse over a rule that is written down. **And an escape hatch used three times in a row is a
  signal, not a workaround** — each of those tasks reported it correctly and the third still had to
  use it. **If the escape is being used repeatedly for the same red, fixing that red is the priority
  over whatever task is holding it.**

### 49. Write an exception as a coupling, not as an exemption.

- **Write an exception as a coupling, not as an exemption.** §4.21.4 says every role reads
  everything inside a project it belongs to, and the members screen withholds two things from a
  non-owner. Written as prose — *"the join code and the pending-request list are excepted"* — that
  is a license a later reader can widen, and nothing goes red when they do. **Task 11.183 wrote it
  as a coupling instead:** *a screen may withhold something from a member only when the server would
  withhold it too*, checked by a test that reads `_requireOwner` out of `project_routes.dart` and
  reddens if either route opens up. **The exception now depends on the thing that justifies it**, so
  it cannot outlive its reason. **When a rule needs an exception, ask what the exception is true
  *because of*, and make the check read that.** Rule established 2026-09-07.

### 50. A measurement that surrounds the wrong interval is not weak evidence — it is no evidence, and it travels further than a guess because it has a number on it.

- **A measurement that surrounds the wrong interval is not weak evidence — it is no evidence, and it
  travels further than a guess because it has a number on it.** Task 11.181 was asked whether the
  pre-commit hook fired, timed `git commit` inside a Bash tool call, got **0.088 seconds** against a
  96-second suite, and reported the hook dead. **The number was accurate.** A `PreToolUse` hook
  completes *before* the command it guards begins, so a stopwatch around the command **cannot
  contain the hook** — and the hook's stdout on success is not shown to the session that triggered
  it, so there was nothing on screen either. **The hook had been running the whole time.**
  **Fifteenth instance of a brief asserting rather than asking, and this one is the planning
  session's own and worse than the count errors before it.** The brief did not merely repeat the
  claim: it wrote *"two hypotheses remain, and both produce exactly the 0.088 seconds"*, ranked
  them, and told the task where not to look. **The true answer was a third the brief had excluded by
  construction — the measurement itself.** **When you enumerate hypotheses, the measurement is one
  of the candidates**, and a closed list that does not include *"the number is of the wrong thing"*
  is not a list of hypotheses, it is a conclusion with alternatives attached.
  **The cheap check is the one that settled it: make the subject say so itself.** An instrument that
  reports its own execution answers "did you run" directly; a stopwatch on a neighboring process
  answers a question nobody asked. Rule established 2026-09-07.

### 51. A check on the *quality* of a decision is not a check on the decision.

- **A check on the *quality* of a decision is not a check on the decision.** Task 11.181 found a
  screen refusing a viewer something the security model says every member may read. **It hid behind
  a passing test.** `refusal_messages_rendered_test.dart` covered that refusal and covered it well:
  the sentence was clear, actionable, reachable and tested. **It answers whether a refusal is
  *worded* well; it never asks whether refusing was the right answer**, and a well-worded wrong
  refusal is the most durable kind, because everything about it looks finished. **When an instrument
  covers a behavior, say which question it answers** — *is this done well* and *should this be
  happening* are different checks, and the first one passing is not evidence about the second.
  Rule established 2026-09-07.

### 52. `flutter test`'s human output cannot tell you what ran. Only `--reporter json` can.

- **`flutter test`'s human output cannot tell you what ran. Only `--reporter json` can.** Task
  11.180 first derived a run's scope by reading test file paths out of the ordinary output, and it
  is wrong *quietly*: **the expanded reporter attributes each line to the suite it is currently
  loading**, so in one 8234-line green run **122 files that really did run never appeared at all.**
  A guard built on that would have blocked every commit and blamed the wrong file. **Anything that
  derives a fact about a run — which suites loaded, which tests ran, which were skipped — reads the
  `suite` events from `--reporter json` or `--file-reporter=json`.** Verified 2026-09-06 across
  `scripts/` and `.github/workflows/`: **every `flutter test` caller that derives a verdict already
  uses the JSON reporter**, so this is a rule preventing a regression rather than describing one.
  (`verify_ats_transport_security.sh` and `verify_session_store_keychain.sh` use `flutter drive` and
  read its exit code — **a different question, not checked here.**) Rule established 2026-09-06.

### 53. A Markdown-only commit can turn `flutter test` red in this repository, and has.

- **A Markdown-only commit can turn `flutter test` red in this repository, and has.** Task 11.170's
  second red was a `.claude/commands/*.md` file breaking `setup_step_ownership_test.dart` — the
  documentation tests read repository files, so `.md`, `.yml` and `.json` are all test inputs.
  **This kills the obvious optimisation of running the suite only when Dart changed**, which is
  worth stating once because the next person will think of it too. Rule established 2026-09-06.

### 54. The pre-commit hook runs `flutter test`, and `flutter test` is the client. It cannot see a change to the contract between the app and the server.

- **The pre-commit hook runs `flutter test`, and `flutter test` is the client. It cannot see a change
  to the contract between the app and the server.** The hook is the whole of what a code task gets
  for free, and it runs the app's suite: the sync wire format, the row validator, the server's
  Postgres schema and the authorization rules all have a server on the other side of them, and
  nothing in that suite speaks to one. **Two commands cover it and neither costs a GitHub Actions
  minute:** `scripts/run_server_tests_docker.sh` brings up a throwaway Postgres and runs the server's
  own suite, and `scripts/gate_smoke_test.sh` brings the stack up and runs every wire-speaking
  security instrument. Both need Docker running; together they take about half an hour on the Mac.
  **A change to any of those four things is not verified until both have been run**, whatever the
  hook said.
  **What this cost, so the next person can price it.** Task 11.219 made tags project-scoped —
  the second schema-major bump this project has ever spent. Its pre-commit run was green and honest;
  it was answering a narrower question than the one that mattered. Michael pushed, and **four of five
  CI workflows went red**: the server integration tests and the Python gate instruments were still
  speaking the retired tag shape, 83 server tests failed, and none of it could have been seen locally
  because CI had been off while he conserved his Actions minutes. Task 11.220 was the whole of the
  repair. **The gap is not in 11.219's care — it is in where the checks live**, and this paragraph is
  it named. Rule established 2026-09-10 (task 11.220).

### 55. A brief's number can be right while its estimate of *containment* is wrong, and that is the more expensive half.

- **A brief's number can be right while its estimate of *containment* is wrong, and that is the more
  expensive half.** Task 11.226's brief predicted one mismatch, in one group, for a reason it named —
  v9's approximating `UNIQUE (tag_id)`. **It was right that v9 would fail and right about why.** What
  it got wrong was how far the fix reached: the v6→v7 group's `setUp` strips *two* versions' additions
  rather than one, so its oracle had to replay both migrations; and the v8→v9 group drops the whole
  `Tag_Versions` table, which v12 and v14 also modify, so the comparison needed a hand-written
  catch-up replaying that table's share of two later migrations. **A one-line prediction that comes
  true does not confirm the paragraph around it.** The count-before-deciding rule stops a brief
  inventing a number; this is the failure that survives it — **a correct number attached to a wrong
  picture of the blast radius.** The tell is a brief that says *expect one* without saying *and here
  is what the fix touches*. **When you predict a failure, predict its reach too, and mark that half as
  the estimate it is**, so the task knows which sentence to distrust when the work is larger than the
  page. Rule established 2026-09-12 (task 11.226).

### 56. A check can fail correctly into a place with no reader, and that is its own defect.

- **A check can fail correctly into a place with no reader, and that is its own defect.** On
  2026-09-12 the beta server's `backup-scheduler` was found to have failed **every cycle for ten
  days**. Nothing was hidden: `docker compose ps` read `(unhealthy)` the whole time, the container's
  own log named the cause (wrong uid, from a raw `docker compose up` instead of
  `scripts/server_up.sh`) and prescribed the one command that fixed it, and `backup_status.sh` said
  *"backups have stopped being taken"* in those words. **Every instrument worked. None of them was
  addressed to anybody.** This project's catalog is full of checks that cannot fail; **this is the
  opposite and it cost the same ten days** — a check that fails loudly at a surface nobody visits on
  a schedule. **When you build a check, say where its failure arrives and who reads that place on
  what cadence.** A health color in a command nobody runs is a check with no reader, and a status
  line is not a reader either. **The related good news is worth copying:** the same run printed
  *"BACKUP FRESHNESS UNKNOWN — this container cannot read /backups … This is NOT the same as having
  no backups"* — an instrument refusing to report an absence it could not distinguish from its own
  blindness. Rule established 2026-09-12.

### 57. A sweep that reports itself complete is a claim, and it is checkable.

- **A sweep that reports itself complete is a claim, and it is checkable.** Task 11.103 fixed a
  tile-counting call that built every tile in a selection just to count them, swept for other
  callers, and **wrote in the file** that *"the only caller of the list form is the downloader,
  which is bounded by a polygon a person has confirmed."* **Both halves were false.** A second
  caller existed — the download sheet — and it runs **before** the confirmation, so at the
  whole-planet framing the first widget test to open that sheet died asking for **2.1 GB**. Found
  by task 11.230, nine days later, only because the allocation stopped its test.
  **This is the hand-maintained-list rule wearing a different coat:** the list here is a sentence
  claiming a search was exhaustive, and a sentence cannot go stale visibly. **Write what you
  searched for, not what you concluded** — *"grep for `tilesInPolygon(` on 2026-09-01 found one
  caller"* is checkable and ages honestly; *"the only caller is the downloader"* is a fact about
  the world that the next commit can falsify in silence. **And when a comment claims a call is
  bounded, name what bounds it and where that bound is enforced**, because "a person confirmed the
  polygon" was true of one caller and the other one ran first. Rule established 2026-09-12
  (task 11.230, about task 11.103).

### 58. When a test hangs, the harness is a suspect before the app is — and this project had the rule and did not reach for it.

- **When a test hangs, the harness is a suspect before the app is — and this project had the rule
  and did not reach for it.** Task 11.229 reported that a dialog's layout *"never finishes"* at large
  text: a ten-minute timeout **with the CPU idle**. Task 11.232 measured it — the dialog draws in
  **86 ms**. **The hang was the instrument eating its own failure.** `collectLayoutOverflows`
  decided what an overflow was by asking whether the error text contained `overflowed by`; 11.229's
  `expect` had a `reason:` that *quoted a stripe*, so when that `expect` failed the harness
  classified its own `TestFailure` as a rendering overflow, the binding asserted inside its
  uncaught-error path, and the test could never end. Same dialog, same scale, **the only difference
  being whether the failure message quoted the stripe**: one fails instantly, the other waits ten
  minutes. Fixed by classifying on the **act** — a `FlutterError` raised by the rendering library —
  rather than on the wording of a message.
  **Three separate rules already in this file would each have caught it.** *"The CPU was idle"* was
  written down and never asked what it meant — **a looping layout burns a core; an idle hang is an
  unfinished wait, and those are different diagnoses.** A cause was named from a resemblance (*"the
  dead-clock shape"*) with no measurement beside it. And **the instrument was not on the list of
  suspects**, which is the 11.181 rule verbatim: *when you enumerate hypotheses, the measurement is
  one of the candidates.* **A rule that exists and is not reached for is not yet a habit** — so the
  trigger is being written plainly here: **a test that hangs, a check that never returns, a probe
  that times out — suspect the instrument first, and prove it innocent before you describe the
  app's behavior at all.**
  **Two mechanical facts from the same incident, both cheap to act on.** `testWidgets` pins its own
  **ten-minute** timeout that `flutter test --timeout` does not override — which is why this cost
  thirty minutes instead of ninety seconds, so **a test walking past a known-clean size carries its
  own `timeout:`**. And **an instrument that classifies by matching words in a message is guessing**;
  classify on the type of the thing thrown, or on what raised it. Rule established 2026-09-12
  (task 11.232, about task 11.229).

### 59. The device log beats the best hypothesis, and it is cheaper than the hypothesis.

- **The device log beats the best hypothesis, and it is cheaper than the hypothesis.** Michael
  reported the tag database's **+** button doing nothing. The planning session's guess was specific
  and well-argued — Add is the only path with a project picker, Edit and read-only were both fine,
  and task 11.232 had just changed that picker. **It was wrong.** One log capture named the function
  and the line: an auto-disposing provider `ref.watch`ing after an `await`, in a helper that
  **writes** while a screen reads. **The guess cost a sentence; the log cost two minutes and settled
  it.** So: **when a phone is available and a symptom is reproducible, capture before theorising** —
  and when a theory is written down anyway, mark it a theory and let the measurement go first. Rule
  established 2026-09-13 (task 11.235).

### 60. A repair that runs inside a read can be interrupted, and idempotent does not save it.

- **A repair that runs inside a read can be interrupted, and idempotent does not save it.**
  `_ensureOwnerMembership` backfills a missing owner row — a **write** — from inside a provider whose
  job is to answer *"what projects are there"*, once per project, in a loop, in a provider that may
  be discarded at any moment. It is idempotent, which is why it looked safe. **It was still cut off
  half-way, and the screen that asked the question broke.** **Idempotent means safe to repeat, not
  safe to interrupt** — and a write hidden inside a read is interruptible by anything that causes a
  rebuild. **When a read repairs something, say where the repair runs and what happens if it stops
  half-way.** Rule established 2026-09-13 (task 11.235).

### 61. A workaround in a test is a defect nobody filed.

- **A workaround in a test is a defect nobody filed.** Task 11.235 fixed a provider that broke the
  tag database's **+** button. A test group next door had been holding a subscription to that same
  provider for the whole test's lifetime, **with a comment saying a bare read "can be disposed
  before the rebuild that write triggers finishes."** Somebody had met the defect, understood it
  precisely enough to describe the mechanism, worked around it, and written the sentence down — **in
  a place where it read as a testing detail rather than a bug report.** Months later a person's
  phone found it. **So: when a test needs a comment explaining why the app cannot be used the
  obvious way, that comment is a finding** — file it, or at minimum name the defect it is avoiding,
  because the next reader will assume the awkwardness belongs to the test. Rule established
  2026-09-13 (task 11.235).
  **WIDENED 2026-09-15, and the second instance was in shipped code rather than a test.** Task
  11.249 needed to know which collars are on an animal today and **wrote a second function rather
  than use `Deployment.covers`** — its comms entry says so plainly: *"deliberately not
  `Deployment.covers`, which is half-open and would drop the collar taken off this morning."*
  **That sentence is a bug report.** It names the defect, names the symptom and names the victim,
  and it was filed as a design note about the new function. `covers()` stayed live in three other
  readers — the Log's animal filter, the Map's animal filter, and the Map's color and legend — and
  five days later Michael's phone found it there, after two further sessions had each fixed a
  different bug next to it. **So: when you route around an existing function because it is wrong,
  that is a finding about the function, not a decision about yours.** Say so in the "For the
  planning session" list, in those words, and let the planning session decide whether it is a task.

### 62. A wire has readers outside the program, and nobody had ever listed them.

- **A wire has readers outside the program, and nobody had ever listed them.** Task 11.219 bumped
  the schema major on 2026-09-10. **For three days the backup pipeline labeled every archive of the
  beta server "schema major 2"** — in the cleartext sidecar *and in the signed comment `restore.sh`
  trusts, which is the copy a restore believes.* Nobody noticed; task 11.242 found it while doing
  something else. **The failure was not forgetting the backup scripts. It was that no list existed
  for a bump to check against**, so forgetting was the only available outcome.
  **Two rules come out of it.** First: **when a constant defines a contract, every out-of-tree tool
  that states it must read it, not repeat it** — `gate_wire.py` reads `schemaMajorVersion` from
  source and therefore needed no change at either bump, while three shell scripts that spelled the
  number went stale. **Reading the constant removes a file from the list permanently; updating the
  file only removes it until next time.** Second: **the enumeration itself is derived, not
  remembered** — `TriTrack_Technical_Context.md` §"What speaks the wire and is not the app" carries
  the grep that produces the population, and says plainly that its own table is a hand-maintained
  list and therefore already wrong. **A list with the query that regenerates it beside it is the only
  honest form of one.** Rule established 2026-09-13 (task 11.242, about task 11.219).

### 63. A migration test on an empty database tests almost nothing, and two defects in one task prove it.

- **A migration test on an empty database tests almost nothing, and two defects in one task prove
  it.** Task 11.243 found both only because its tests ran against **populated** databases.
  **First: a migration step whose idempotence check reads a column a *later* migration deletes will
  run twice.** The check asks *"have I already done this?"* by looking at something that no longer
  exists, gets the wrong answer, and repeats itself — here it minted a duplicate animal and killed a
  whole import. **An idempotence check must only read things that outlive every migration after it**,
  and the usual right answer is the schema version itself, never a column.
  **Second: deferred foreign keys make `DELETE` and `ALTER TABLE … DROP COLUMN` incompatible inside
  one transaction.** Deleting rows queues constraint checks for the end of the transaction; the
  `ALTER` then refuses while they are pending. **On an empty database neither statement has anything
  to trip over and the migration passes.** This is the second time deferred constraints have bitten
  this project — task 11.227 hit the same wall from the other side — and both times the fixture with
  rows in it was what found it.
  **So: a migration test seeds every table the migration touches, before and after, or it is a
  syntax check wearing a test's clothes.** Rule established 2026-09-14 (task 11.243).

### 64. The pre-commit escape hatch exists, says so out loud, and obliges an entry.

- **The pre-commit escape hatch exists, says so out loud, and obliges an entry.** Three windows share
  one working tree, so a red is often not the committer's. Prefixing a commit with
  `TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1` skips the suite — **and using it obliges an entry in
  `TASK_COMMS.md` saying nothing was verified and why.** An escape used silently is the hook not
  existing. Rule established 2026-09-06 (task 11.180).
  **Second instance, 2026-09-20, and it is about the hatch's shape rather than its use.** Task
  11.287 used it correctly and unusually well: five full runs, three isolated runs, and a diff
  showing no file under `lib/`, `test/` or `packages/` had changed — proof that the red it was
  stepping over was somebody else's. **It was carrying a second red it had introduced itself.** Its
  own comms entry contained a `path:NN` citation, which `planning_document_citations_test.dart`
  counts, and **the hatch does not step over one red: it skips the whole run.** So the variable is
  named for a judgement about *a* failure and licenses a commit past *all* of them. The second red
  then sat on `main` for a day, invisible to the window that wrote it and met by every later commit
  on that machine, and task 11.294 had to dig it out from behind the failure it was actually filed
  for.
  **The rule this leaves: proving one red pre-existing is not proving the run pre-existing.** Before
  the hatch, read the refusal's list of failing tests and account for **each** of them, not the one
  you recognize. A red you cannot name is a red you are introducing. **And a corollary about who can
  see what:** the planning session's own commits do not pass through this hook at all, so a red it
  introduces into a planning document is invisible until a Claude Code window commits — and that
  window meets a failure it did not cause, in a file it is told never to edit. **That is now two
  ways this hook's blind spot lands on the wrong person.**

### 65. A comparison between two things that fail identically is not a comparison.

- **A comparison between two things that fail identically is not a comparison.** Task 11.178's
  sibling wrote a wrap guard that laid out a long tag row beside a short one and asserted the long
  one was no taller. **In `flutter_test`'s fallback font — about twice Roboto's width — both rows
  wrap**, so the guard passed with wrapping deliberately switched back on. It was measuring the
  difference between two failures. **The instrument that works compares each row against *itself*
  laid out in unlimited width**, which cannot be satisfied by both sides breaking the same way.
  `test/features/disabled_reason_geometry_test.dart` is the pattern; **point the next "prove this
  text did not wrap" task at it rather than at a fresh threshold.** This is the
  cannot-distinguish-success-from-its-own-failure rule with a control group: **when a check compares
  A to B, ask what happens when A and B are both broken.** Rule established 2026-09-06.

### 66. A marker that is supposed to move cannot show you that it is moving wrongly.

- **A marker that is supposed to move cannot show you that it is moving wrongly.** Task 11.177 fixed
  the compass needle Michael reported within days — it swung up to 10.5° during a turn and is meant
  to sit still. **The true-north tick and the navigation line had the same defect at twice the
  magnitude, 20.5°, and nobody could ever have seen it**, because both are *supposed* to swing as
  the phone turns and the intended motion hides the error. **The still markers are the only ones
  that will ever complain.** So where a widget mixes an eased display value with raw data, **the
  absence of a report about the moving parts is not evidence about the moving parts** — measure
  them, and do not let the one visible symptom bound the sweep. Rule established 2026-09-06.

### 67. Enforcing a written rule for the first time tells you who has been violating it — expect that, and do not weaken the rule to make the noise stop.

- **Enforcing a written rule for the first time tells you who has been violating it — expect that,
  and do not weaken the rule to make the noise stop.** §4.10 has said *never enabled in a production
  deployment* since the security model was written, and until task 10.80 nothing read
  `TRITRACK_ENV`. The moment the refusal existed, it made `verify_i1_source_identity.sh` illegal —
  **a gate instrument that had been proving a security control in a configuration the security
  model forbids, for as long as it had existed, invisibly, because the rule was prose.** The right
  repair was the drill, not the rule: the drill's claim never depended on `TRITRACK_ENV` (the
  console's loopback gate reads the raw network peer), so declaring the stack non-production costs
  the drill nothing and keeps §4.10 unconditional. **An exception written into a rule is a hole a
  later reader can widen; a fixed caller is not.** Rule established 2026-09-06.

### 68. Poll quietly, but keep the last attempt's output and print it with the failure.

- **Poll quietly, but keep the last attempt's output and print it with the failure.** A harness
  that knows why it failed and does not say is worse than one that never knew. This is `CLAUDE.md`'s
  *an instrument's last words must be a finding, not a name* one layer earlier — **the readiness
  loop's final attempt IS the finding.** `verify_h6_archive_forgery.sh` waited sixty times for
  Postgres with `>/dev/null 2>&1`, threw away the `ERROR: unable to select packages` that named the
  real cause on every pass including the last, and then printed `postgres never came up` — **costing
  a diagnosis rather than a line of log**, because the failure had to be carried as a hypothesis
  through a whole task. **One file owns this now: `scripts/lib/wait_for.sh`. Point the next such
  task at it rather than letting it write a fresh loop.**
  **The other half does not generalise and must not be pretended into a mechanism.** h6's probe was
  also *compound* — its success needed the image to build and the network to work and the database
  to be up, and its message named one of the three. **Only the caller knows what its probe touches**,
  so that stays a judgement each script makes: **a failure message names what was measured, and a
  probe that cannot separate its causes says so.** Rule established 2026-09-06 (task 11.176), which
  found h6 was the only real instance among seven and left three loops deliberately untouched.

### 69. When an instrument decides "the conditions were too poor to measure", ask what quantity that decision reads. If the answer is a sign, a count or a boolean, it cannot tell a small bias from a large one — and a bias is exactly what poor conditions produce.

- **When an instrument decides "the conditions were too poor to measure", ask what quantity that
  decision reads. If the answer is a sign, a count or a boolean, it cannot tell a small bias from a
  large one — and a bias is exactly what poor conditions produce.** Task 11.90's timing guard was
  wrong for a year's worth of gates for precisely that reason: it asked which *direction* the
  machine's own wobble pointed, never how *big* it was, so an ordinary busy laptop could produce a
  Gate C blocker that three re-runs could not reproduce.
  **The repair pattern is the one §22.4.1 named: make the run measure its own resolution and compare
  against that**, so the threshold is a fact the run produced rather than a number somebody picked.
  **A guard is a claim about whether a measurement is admissible, and admissibility is a magnitude
  question.** Rule established by task 11.90, 2026-09-06, at the executor's suggestion.

### 70. An instrument's behavior on a broken server is a different question from its behavior on a healthy one, and only a broken-control harness asks the first.

- **An instrument's behavior on a broken server is a different question from its behavior on a
  healthy one, and only a broken-control harness asks the first.** Task 11.127 built detection
  proofs for two wire-speaking instruments and **each proof immediately found a defect nothing else
  had:** `verify_c1_row_naming.py` crashed halfway through its own reproduction, and one of its
  checks read *"I was refused"* as *"nothing changed"* — **a refusal scored as a clean result.**
  Both had been green for weeks against a healthy server.
  **The general form: a green instrument has demonstrated that it does not fire, and nothing else.**
  Whether it *can* fire is a separate experiment, it needs the subject deliberately broken, and
  **this project has now found a defect on two of the two instruments where that experiment was
  first run.** Rule established by task 11.127, 2026-09-05, at the executor's suggestion.

### 71. A budget can only say no by taking something away, so a screen with nothing it may withdraw cannot have a structural one.

- **A budget can only say no by taking something away, so a screen with nothing it may withdraw
  cannot have a structural one.** Task 11.166 was asked to make the Main Map's clear-band floor
  structural the way 11.162 did on the Offline Data Map, and declined **with a better reason than
  the one the brief offered.** Not "because it is a `Stack`" — a render object owning all six
  anchors could be written. **Because every overlay on that screen is a license condition (the
  map-source credit), a control (the "+", the layer and location buttons, the north arrow), or a
  warning about state.** 11.165's Record bar had a reassurance note to spend; here **the cheapest
  thing to withdraw is a warning, and a warning withdrawn silently is a worse failure than the one
  the budget prevents.**
  **So before asking for a budget to be enforced, ask what it is allowed to take.** Where the answer
  is nothing, **an assertion is the honest ceiling** and saying so beats building a mechanism that
  must choose between bad withdrawals. Rule established by task 11.166, 2026-09-05.

### 72. A floor a test checks afterwards and a floor the layout enforces are not the same guarantee.

- **A floor a test checks afterwards and a floor the layout enforces are not the same guarantee.**
  Task 11.110 set a 96-pixel clear band on the Offline Data Map and a test asserted it; **the screen
  then went under that floor anyway**, and it took task 11.157 — a task about something else,
  required to measure a sum — to notice. Task 11.162's remedy was not a better assertion: it made
  the floor **a `SizedBox` of 96 logical pixels in the screen's own layout**, with the download
  cards scrolling inside whatever is left. **A fifth thing added to that screen now finds the map
  protected and the cards squeezed, which is the intended order and cannot be forgotten.**
  **The general form: where a budget can be expressed as structure, expressing it as an assertion
  leaves the structure free to violate it between runs.** This is the same move as mechanising a
  reopen trigger — **put the rule where it is obeyed, not where it is checked.** Rule established by
  task 11.162, 2026-09-04.

### 73. A reopen trigger written in prose is a hand-kept list of one, and it rots on the same schedule.

- **A reopen trigger written in prose is a hand-kept list of one, and it rots on the same
  schedule.** Task 11.144 recorded a condition — *"the day a sync round starts changing any of
  those three providers, these four become live"* — as a paragraph in
  `TriTrack_Technical_Context.md`. **Task 11.153 made that condition true the next day**, and the
  planning session resolved 11.153 itself without connecting the two. **The trigger fired in under
  twenty-four hours and nobody noticed for two days.** It was not a bad trigger; it was well
  written, specific, and addressed to exactly the right person. **It was prose, and prose waits to
  be remembered.**
  **So: if a reopen condition can be expressed as a check, it must be, and the prose points at the
  check rather than standing in for it.** Task 11.145's derived guard —
  `test/routing/shell_provider_chain_test.dart`, which asks the corpus which providers are watched
  from inside other providers — **is that same trigger mechanised, and it would have gone red the
  day the condition became true.** A sentence that says "reopen this when X" and a test that fails
  when X are the same claim; **only one of them tells anybody.** Rule established 2026-09-04.
  **The honest exception, added the same day by task 11.161 so the rule stays usable: some
  conditions can only be observed by a person.** *"If a field day shows GPS is the dominant
  drain"* cannot be a test — nothing in this repository can spend a day outdoors. **Prose is
  correct there, and the requirement changes rather than disappearing: it must name who observes
  it, when, and what they would see.** A trigger addressed to nobody in particular is the one that
  rots; a trigger written into `TASK_COMMS.md`'s "waiting on Michael" beside the field measurement
  it depends on is a trigger with an owner.

### 74. A code task may edit a planning-session document when its own brief tells it to, and it should say so in its report rather than assume the exception.

- **A code task may edit a planning-session document when its own brief tells it to, and it should
  say so in its report rather than assume the exception.** Task 11.160 was told not to touch
  `TriTrack_Technical_Context.md`; task 11.161 was told to extend a rule *where it lives* rather
  than write a second one beside it, **which is the opposite instruction and produced the right
  outcome** — one rule extended instead of two rules to keep true. 11.161 flagged the exception and
  asked whether the planning session wanted to own the words instead. **That is the correct
  behavior: take the exception, then declare it.** The standing default is unchanged — a code task
  does not edit these documents uninvited. Rule established 2026-09-04.

### 75. A guard that greps for a literal call cannot see through a function call — and a check written to protect a new idiom must be tested by breaking that idiom.

- **A guard that greps for a literal call cannot see through a function call — and a check written
  to protect a new idiom must be tested by breaking that idiom.** Task 11.151 moved three screens'
  announcements into a helper, `refreshTagViews`, and `data_arrival_announced_test.dart` went red
  because those screens no longer contained the literal call. **That failure was correct.** The
  instructive half is what happened next: **the first self-check written for the new idiom scanned
  the whole file and passed with the helper gutted**, because a second entry point's bump satisfied
  it. It is now scoped per function, and **both gutting directions were confirmed red.** A guard for
  an indirection has to be aimed at the indirection; **scanning the file the indirection lives in
  proves the file, not the call.** Rule established by task 11.151, 2026-09-04.

### 76. A guard against scanning nothing must fail when the scope is wrong, not only when it is empty.

- **A guard against scanning nothing must fail when the scope is wrong, not only when it is
  empty.** `no_committed_secrets_test.dart` scans `git rev-list --objects --all` and protects
  itself with `expect(historicalBlobs.length, greaterThan(100))` — **written for exactly the
  failure it then let through.** `offline-suite.yml` checks out with a bare `actions/checkout@v4`,
  whose default is a single commit, so in CI the "whole history" is one tree — **which holds far
  more than a hundred blobs, so the guard passes and the run is green in five minutes while the
  same check needs twelve locally.** The threshold ruled out *zero*; the failure was *vacuity*,
  and those are not the same. **So: a self-check on scope asserts the scope** — a count of
  reachable commits, the presence of a known old object, something derived from what the scan is
  supposed to reach. **Picking a bigger number is the same mistake with more digits.** Rule
  established 2026-09-04. **Worked example, added by task 11.150:** the group
  `the history scan reached the whole history` in `no_committed_secrets_test.dart` is what this
  looks like implemented — **four assertions, not one of them a number a person chose** (the clone
  is not shallow; the walk reached every commit; it reached a parentless one; every requested blob
  came back), and the shallow-clone case was watched going red. **Point the next such task there
  rather than letting it invent a fresh threshold.**

### 77. A CI runner's environment silently narrows what a check covers, and the narrowing never announces itself.

- **A CI runner's environment silently narrows what a check covers, and the narrowing never
  announces itself.** `actions/checkout@v4` with no `fetch-depth` is a **one-commit** clone, so a
  test written to walk 652 commits walked one, for weeks, green. **Depth is only the instance.**
  The class is anything a developer's machine has that a runner does not: full history, submodules,
  LFS objects, a populated cache, network access, a real filesystem. **A check that reads its
  subject from the environment must assert that the environment gave it the subject** — and the
  cheapest form of that is to print what it actually scanned, every run, so the number is in the
  log where a person will see it change. Rule established by task 11.150, 2026-09-04.
- **The time zone is part of the environment, and pinning it to make a check deterministic narrowed
  it to the one zone that hides a whole class.** Task 11.325 pinned the night's suite to `TZ=UTC` so
  that four zone-dependent skips had one answer everywhere — a good reason. But a deployment day is
  local midnight, and a screen that prints it through UTC shows the right day in UTC and everywhere
  west of it, and the day before everywhere east of it. **So UTC and Phoenix, the only two zones the
  suite had ever run in, are exactly the two that cannot see it.** The held card on the Sync Status
  screen named the wrong days in London and New Zealand for weeks, green; it surfaced only because
  Michael's Mac happened to be on British time and the pre-commit hook runs in the Mac's own zone.
  Task 11.326 (2026-10-05) adds an east and a west run to the night, and makes the skip declarations
  zone-shaped rather than pinning the zone away. **The determinism argument was right about the
  skips and wrong about the coverage, and nothing announced the second half.**

### 78. A text measurement that ignores the ambient `DefaultTextStyle` is quietly wrong in the same direction everywhere.

- **A text measurement that ignores the ambient `DefaultTextStyle` is quietly wrong in the same
  direction everywhere.** Task 11.148's first `heightFor` laid out the bare `TextStyle` written at
  each call site and came out **~16 pixels short per column**, because a `Text` merges its style
  onto the ambient default — **the theme's font family, line height and leading are part of the
  answer.** It failed loudly that time and the next one will not: an under-measure is invisible
  until something just barely does not fit. **So a height helper measures with the same ambient
  style the widget will build under, and lives beside the widget it measures** — 11.148's
  `MapBottomReadoutColumn.heightFor` shares its `static` metrics with its own `build`, so the two
  cannot drift without failing to compile. Rule established by task 11.148, 2026-09-04.

### 79. Do not predict a wrapping sentence — ask the widget how tall it will be.

- **Do not predict a wrapping sentence — ask the widget how tall it will be.** Task 11.138
  measured its disabled-reason sentence once at the default text size, wrote **52** into a fixed
  box, and was right — at one text size. **A sentence that wraps gains a whole line at a width
  nobody can predict**, so no arithmetic on 52 could have been correct; 11.139's fix was
  `DisabledReasonNote.heightFor`, which asks. **This is the measure-don't-reason rule applied
  where the thing being reasoned about looks like a constant** — which is exactly where it gets
  skipped, because 52 does not look like a guess. Rule established by task 11.139, 2026-09-04.

### 80. A screen whose furniture floats over its subject cannot fail loudly, so the only instrument that works there is a measured band.

- **A screen whose furniture floats over its subject cannot fail loudly, so the only instrument
  that works there is a measured band.** Nothing on the Main Map is in a box that can overflow —
  every overlay simply covers more map as its labels grow — so the screen reports itself perfectly
  healthy at every text size **while the band of map with nothing drawn over it falls from 229
  logical pixels to 46 at AX1 and to 0 at AX4.** The absence of a stripe is not evidence; it is
  the absence of anything able to produce one. **Where a layout has no container to burst, assert
  the clear space directly.** Rule established by task 11.139, 2026-09-04.

### 81. A baseline can photograph the harness's environment instead of the app, and a diff cannot tell the difference.

- **A baseline can photograph the harness's environment instead of the app, and a diff cannot
  tell the difference.** `/w-12` reported `ipad-13/truth-point-edit` drifted 13.24% and offered
  *"something about how the simulator or its window was sized"* as a guess. Measuring it gave a
  different answer: identical dimensions, an identical top quarter, and two opposite shifts —
  down 51 device pixels above, up 40 below. **The published image had iOS's floating-keyboard pill
  sitting over the app's own tab bar, and the new one did not**; the dialog's text field is
  focused, so a keyboard inset moved a centered dialog down and lifted the bottom bar.
  **The baseline was the contaminated one and the "regression" was a repair.** Two consequences.
  **First, a percentage is a symptom and never a cause** — `/w-12` had the number and stopped, and
  the number pointed the wrong way. **Second, replacing a baseline must say which of the two things
  it is**: the app changed, or the picture of the app was wrong. A diff shows the same pixels
  either way, and a commit that does not say which one teaches every future reader to trust the
  wrong image. Rule established 2026-09-04.

### 82. An entry that answers some of a command's instructions is not an entry that answers all of them.

- **An entry that answers some of a command's instructions is not an entry that answers all of
  them.** The standing rule says a missing comms entry is indistinguishable from a task with
  nothing to say. **The same is true one instruction at a time**, and it is harder to notice:
  `/w-12` was asked in its own acceptance list to report what the terrain readout showed either
  way, and its entry does not mention terrain. **A silence inside a full-looking entry reads as
  "nothing happened" and it means "nobody knows".** So: **answer every instruction that asked for
  an observation, including the ones whose answer is "it behaved normally"** — that is the answer,
  not the absence of one. Rule established 2026-09-04.

### 83. A scheduled job proven by a push has not proven its schedule.

- **A scheduled job proven by a push has not proven its schedule.** Task 11.135 reported the
  tile-credit freshness job green on a GitHub runner — **fired by its `push` paths filter, not by
  the Monday schedule, which has still never run.** That is the honest state and it is a fourth
  verdict beside task 11.119's three: not *never executed*, not *executed only on one machine by
  hand*, but **executed, and never by the mechanism that is supposed to execute it.** A `cron:`
  line nobody has watched fire is a claim, and the failure mode is silence rather than a red.
  **So when moving a job off a never-run list, say which trigger ran it.** Rule established by
  task 11.135, 2026-09-02.

### 84. A cleanup step that runs unconditionally is a decision to keep no evidence, and nobody writes it down as one.

- **A cleanup step that runs unconditionally is a decision to keep no evidence, and nobody
  writes it down as one.** Task 11.130 went looking for why six sign-in links never arrived. **The
  instrument that would have answered it had already run and printed a decisive verdict for each
  of the six** — task 11.40 built exactly that reader — **and the verdict was destroyed twice
  over: by `run_e2e_tests.sh`'s `EXIT` trap running `docker compose down -v`, and by the
  scrollback.** **An instrument that diagnoses at failure time is worth nothing if the run that
  fails is also the run that deletes its own evidence.** So: **a teardown that does not
  distinguish a green run from a red one has quietly chosen that no failure will ever be
  diagnosable**, and that choice belongs in the open where somebody can disagree with it. Rule
  established by task 11.130, 2026-09-02.

### 85. A status command that changes what it measures is not a status command.

- **A status command that changes what it measures is not a status command.** Task 11.140 chose
  `docker compose exec` and never `run` for the database question, because **`run` would start
  Postgres in order to answer whether Postgres is up.** The cost is that the count is unavailable
  on a merely-stopped stack, **which is the honest answer anyway.** General form: **an instrument
  that can bring its own subject into existence cannot report on that subject's absence.** Rule
  established by task 11.140, 2026-09-02.

### 86. An answer that does not name what it measured is the same answer on two machines.

- **An answer that does not name what it measured is the same answer on two machines.**
  `operator_status.sh` prints backup ages, lost audit writes and rate-limit counts and **names
  neither the host, the compose project, nor the directory it read** — so a run on a developer
  laptop against a throwaway stack is textually indistinguishable from a run on the beta server.
  **Not hypothetical: its first real output reported a 17-day-old backup and six lost audit
  writes, and both are most likely about a local test stack rather than the server they would be
  alarming about.** **Any instrument whose answer is about a *deployment* must name the deployment
  in its own output.** Rule established 2026-09-02 (task 11.141).

### 87. A cause proposed for an event nobody has reproduced is a hypothesis, and writing it into a comment makes it a fact.

- **A cause proposed for an event nobody has reproduced is a hypothesis, and writing it into a
  comment makes it a fact.** One row overflowed once, on Michael's phone. **Four causes have since
  been named and all four were wrong** — tag-name length, device width, bearing count, and the
  screenshot fixture — and the second of them was written into a test's comment as the measured
  threshold, where `/w-09` found it on 2026-09-03 and disproved it by pulling the pre-fix
  screenshot out of git and looking at it: **the row fit, with room to spare.** The threshold was
  real and measured **in `flutter_test`'s fallback font, roughly twice Roboto's width.** So:
  **when the event is a single unreproduced observation, the cause goes in the report as a guess
  and never into the code as a comment** — a comment is read as something somebody established.
  Rule established by `/w-09`, 2026-09-03. **Sixth instance, 2026-09-03: `/w-09` blamed a
  72-tile terrain fetch on its own richer fixture. The count does not depend on the fixture at
  all** — the map fetches a disc sized by a fixed 35 km viewshed range, 8 rows × 9 columns at the
  seeded coordinates, whatever the seed holds; going from eight bearings to five changed it by
  **zero tiles**. **And `README.md` item 8 had written the real explanation down a month
  earlier.** The cause was not merely unverified; **it was contradicted by a document in the same
  repository that nobody re-read.**

### 88. A widget existing is not a widget drawn.

- **A widget existing is not a widget drawn.** `/w-11`'s first readiness condition for the map
  asked whether `flutter_map`'s overlay layer was in the widget tree. **It was — and the map
  photographed with no viewshed on it, twice, byte-identically**, because the layer's image had
  not finished decoding. **A readiness check must assert the observable outcome, not the mechanism
  that ought to produce it**, or it certifies the presence of the thing that was going to do the
  work. **And it caught itself only because it was watched failing**: with the map's ceiling cut
  to 8 seconds it named four unready states, two of which nobody suspected, where the same run had
  previously said *"26 of 26 photographed, no screen threw."* Rule established by `/w-11`,
  2026-09-03.

### 89. A readiness condition should return what it is still waiting for, not a boolean.

- **A readiness condition should return what it is still waiting for, not a boolean.** `/w-11`'s
  conditions answer with the phrase the run prints when it gives up — *"the status bar still says
  Downloading terrain… 9/72"* — so a timeout is a diagnosis instead of a duration. **A check that
  can only say "no" makes the person who reads the log guess**, and this project has spent several
  tasks on exactly that guess. Rule established by `/w-11`, 2026-09-03.

### 90. A harness that builds its own container gets the framework's defaults, not the app's — so it is measuring a different app.

- **A harness that builds its own container gets the framework's defaults, not the app's — so it
  is measuring a different app.** Task 11.142 was written to fix two spinners that never stop on
  the Members screen. **They do not.** Both providers fail immediately with `not_configured`, and
  under the app's own `appRetryPolicy` the error text renders in 1.6 seconds. **What spins for
  twenty seconds is the screenshot harness**, whose `ProviderContainer` was constructed with no
  `retry:` and therefore ran Riverpod's default — ten attempts over 38.2 seconds, which is task
  11.105's finding resurfacing in a place its guard cannot see (`retry_policy_applied_test.dart`
  scans `lib/` for `ProviderScope(`). **Whenever a harness assembles the app's environment itself,
  it must be assembled from the app's configuration**, and anything it observes before that is
  evidence about the harness. Rule established by task 11.142, 2026-09-03.

### 91. A grep tells you a token appears. It does not tell you what the token means.

- **A grep tells you a token appears. It does not tell you what the token means.** Task 11.61's
  brief said four `.timeout()` call sites "already time out by hand" and should be replaced by the
  policy. **The grep was accurate and the sentence was not: only one of the four was about a
  request, and even that one bounded a queue rather than a request.** The other three were a GPS
  fix, an isolate computation, and a doc comment saying no timeout existed. **This is the specific
  way the planning session keeps going wrong** — a search returns matches, and a task entry is
  then written about their meaning without opening any of them. **Matches are a list of places to
  look, never a finding.** Rule established by task 11.61, 2026-09-03.

### 92. A health signal fed only by failures is silent during a hang.

- **A health signal fed only by failures is silent during a hang.** Task 11.61 found a fifth
  unbounded request nobody had listed — `cached_tile_provider.dart`'s `http.get`, **every basemap
  tile the map draws** — and it was worse than an ordinary hang, because task 11.135's
  tile-health band is only ever told about a *failure*. A request that never fails never reports,
  **so the band designed to say "tiles are not arriving" stayed quiet in exactly the case where
  nothing was arriving.** Bounding the request fixed both. **When a signal is driven by an error
  path, ask what it does when there is no error and no result either.** Rule established by task
  11.61, 2026-09-03.

### 93. A check that verifies the strings a page quotes can never notice a string the page ought to quote and does not.

- **A check that verifies the strings a page quotes can never notice a string the page ought to
  quote and does not.** `/w-10` carried three sets of app copy into the guide and **the drift
  check would not have caught any of them** — because the guide had *no sentence at all* about
  signing in and *no sentence at all* about what a name may contain. **There was nothing to drift,
  and green was the correct answer.** This is the opposite of the eight holes
  `website/README.md` already lists, all of which are about something going stale. **What worked
  instead was the standing obligation on both lanes to say in a comms entry when user-visible copy
  changes** — every one of the three arrived that way rather than through a red build. **Not every
  gap wants a check; some want a habit, and it is worth knowing which is which.** Rule established
  by `/w-10`, 2026-09-03.

### 94. Removing something every screen carried invalidates every number that was measured with it live — in one commit, across files, silently.

- **Removing something every screen carried invalidates every number that was measured with it live
  — in one commit, across files, silently.** Task 11.189 deleted the shell's two banners. Three weeks
  later an unrelated sweep found the Main Map's space-budget doc block still opening *"measured (both
  shell banners live)"* and reporting nine numbers from a configuration the app no longer has,
  **with a verdict that contradicts its own test.** The numbers were correct when written and nothing
  falsified them out loud. **The measurements live in prose, and no test reads prose.** So: **a task
  that removes a global greps for the measurements that cite it**, and a task that finds stale ones
  **re-measures rather than editing the sentence until it agrees with the test** — deriving nine
  numbers from the test's one is a guess, and a guess written as a measurement is worse than the
  stale text it replaced. Rule established by tasks 11.205 and 11.206, 2026-09-09.

### 95. A sentence that explains a design choice is clutter; a sentence that warns the drawing may be wrong is data.

- **A sentence that explains a design choice is clutter; a sentence that warns the drawing may be
  wrong is data.** Task 11.206 derived the class of "sentences explaining why the app draws what it
  draws" and found four candidates. **Only one was in breach** — the estimate card's note about
  hidden wedges, which explained a rendering decision in permanent space. The others stayed:
  `kPartialTerrainCaveat` warns that **ground with no elevation is drawn as not visible, which may be
  wrong**, and that is not an explanation of a design, it is a statement about how far the picture can
  be trusted. **The map credit is a license condition.** The delete-project dialog is about the user's
  own data. **When trimming for simplicity, the test is not "does this describe the app" but "would
  somebody act differently if they had not read it."** Rule established 2026-09-09.

### 96. A rule applied one instance at a time, each time by a person noticing, is not being applied.

- **A rule applied one instance at a time, each time by a person noticing, is not being applied.**
  Michael has flagged the same simplicity-over-verbosity rule three times in three weeks — the Record
  screen's headings, the Position header row's jargon, and a card explaining why the map hides its own
  wedges. **Each was fixed as an instance and the class was never derived.** When the same standing
  instruction is invoked a third time, **stop fixing the instance and go find the others**; report the
  list with a proposed disposition rather than acting, so one decision covers all of them. Rule
  established 2026-09-09.

### 97. A wait that can time out must fail when it does. "It returned" is not "the condition came true."

- **A wait that can time out must fail when it does. "It returned" is not "the condition came
  true."** Task 11.209's flaky test used a helper that polled for ten seconds of real wall-clock time
  and then **simply returned** — no throw, no warning — so every one of its 15 call sites could not
  tell *the thing I waited for happened* from *I gave up waiting for it.* **This is the founding
  defect of this project in its purest form**, and a polling wait is where it hides best, because the
  happy path looks identical. **The correct pattern is already in this repository twice** —
  `pumpInAppShell` throws a `TestFailure` naming the screen and the budget; `map_with_no_position_test`
  asserts after its loop with *"the map never built"*. **Copy one of them.** And note the sting in the
  tail: **a real-clock budget is exhausted first on a busy machine, which is the machine least able to
  say so.** Rule established 2026-09-09.

### 98. "Does not reproduce" and "reproduces one time in twelve" are different claims, and the second one has a rate.

- **"Does not reproduce" and "reproduces one time in twelve" are different claims, and the second one
  has a rate.** Task 11.209 reported two failures as *"do not reproduce"* and gave, in the same
  sentence, the count that contradicts it: 11 of 12. **The report was right to give the number** —
  that is why the wording could be corrected at all — but the word closes a question the number opens.
  **Write the rate, not the impression.** *"It passed"* is not evidence that something was fixed;
  **1-in-12 becoming 0-in-50 is.** Rule established 2026-09-09.

### 99. The copy-changes list is a hint. Deriving from the code is the step.

- **The copy-changes list is a hint. Deriving from the code is the step.** The arrangement is that
  the planning session appends to `WEBSITE_PLAN.md`'s list when it resolves a task that changed
  user-visible wording. **It failed eight times running** — every task from 11.202 to 11.209 — and
  `/w-10` had to derive them from the commits instead. **That derivation is what found the defect**: it
  turned out task 11.205 had made a paragraph of the guide false, because the Position screen stopped
  being the one map that says nothing when tiles stop arriving. **A quote check could never have caught
  it — no quote drifted, a description did.** So: **a content task derives what changed from the code
  since the last content task, and reads the list only as a hint about where to look.** Keep appending
  to it — a hint that is usually right is worth having — **but never treat it as the mechanism, and
  never let a green quote check stand in for having looked.** Rule established by `/w-10`, 2026-09-10.

### 100. A wait whose condition is weaker than the assertion that follows it is a race, not a wait.

- **A wait whose condition is weaker than the assertion that follows it is a race, not a wait.**
  Task 11.212 found the elevation-panel flake: the wait asked only that the header contain `km`, and
  the assertion four lines later needed the climb and descent totals. **Those are two different paths
  in the same header and only one is synchronous** — the distance arrives with the fix, the totals
  wait on async terrain sampling — **so machine load decided the outcome.** *(Task 11.210's loud-wait
  fix neither caused nor cured it; this was never a timeout.)* **And the same weak wait was found
  failing in the other direction beside it**: a later condition satisfiable by the totals *arriving*
  rather than by the distance following a new fix — **a green that measured nothing about the thing
  the test exists to check, which nobody reported because it never went red.**
  > **This is the third face of a family this project already has two rules for** — a readiness check
  > must assert the observable outcome rather than the mechanism that ought to produce it, and a wait
  > that can time out must fail when it does. **This is the one that produces an intermittent red
  > rather than a hang or a false green.** The check is mechanical: **for every wait, ask whether the
  > next assertion needs anything the condition does not require.** Rule established by task 11.212,
  > 2026-09-10.

### 101. A check that can invent a false subject, which then passes, is broken in the direction nobody looks.

- **A check that can invent a false subject, which then passes, is broken in the direction nobody
  looks.** Task 11.212 found its own guard's declaration parser reading `return resolveProjectRole(`
  as a *declaration*, because a call at that indentation looks like a class member. **Fourteen
  phantom methods were invented across the widened scope and thirteen cleared themselves silently**,
  because they named classes that really are constructed all over `lib/`. **The one that did not clear
  itself is the only reason anybody looked** — and the planning session had relayed the broken
  parser's figures (109 candidates, 4 uncalled) into the next task's brief as fact. The true numbers
  were 95 and 3. **A false positive costs somebody an argument; a false subject that clears itself
  costs nothing and buys silence**, which is why the parser's shape went unquestioned. **Exercise a
  finder against a fixture with a known answer, not against whatever the codebase happens to contain
  today.** Rule established by task 11.212, 2026-09-10.

### 102. Rename a shared assertion and the documents that name it are now wrong — fix them, and say it was renamed.

- **Rename a shared assertion and the documents that name it are now wrong — fix them, and say it was
  renamed.** Task 11.219 renamed `assertUnvalidatedIdListColumnsFeedNoReachability` to
  `assertSealedColumnsFeedNoReachability`, **because the old name described the two columns it happened
  to guard rather than the property it enforces** — which is the right reason to rename something.
  Three planning documents named the old one. **All three now carry the new name *and a note saying it
  was renamed and why*, which is the part that is easy to skip**: a reader following the old name out
  of an older report finds a trail rather than nothing. **A rename with no forwarding note turns every
  earlier report into a dead end.** Rule established 2026-09-10.

### 103. One observation is not a flake, and calling it one is a decision you have not earned.

- **One observation is not a flake, and calling it one is a decision you have not earned.** Task
  11.204 saw `map_screen_test.dart` fail once in a full-suite run and pass on the re-run and in
  isolation, and said plainly *"I do not know which it is"* — **which is the correct report.** The
  next step after a single unexplained red is **never a hypothesis**; it is to make the thing
  reproducible, with a stated number of attempts, and to say what happened. **A test that fails only
  in a full suite is a claim about the suite, not about the test**, and until it reproduces there is
  nothing to reason from. **And the cost of shrugging is specific here**: the pre-commit suite gates
  every commit, and a red nobody trusts is how three tasks in a row came to use the escape hatch in
  September. Rule established 2026-09-09.
  **Two additions, 2026-09-15, from tasks 11.246 and 11.253.**
  **First: this rule is not permission, and it was read as permission.** 11.246 saw two *different*
  tests fail in two consecutive full runs and filed it as *"the known full-suite-only flake class
  this project already has a rule about"* — citing this paragraph, whose whole point is that you may
  not do that. **It was the most careful report of the week otherwise, which is what makes it worth
  naming: a rule that can be read as its own exemption will be.** There is no "known flake class"
  here. There is a rule saying reproduce it, and `scripts/repeat_suite.sh N` now does the running.
  **Second, and it is the part that costs the most: record what else was touching the machine and
  the repository.** This project runs **two windows on one working tree** as its standing condition,
  and one of them commits — **which runs `scripts/pre_commit_suite.sh`, a second full `flutter
  test`.** So a suite can meet a busy `.git` and a loaded machine through no fault of the code.
  Both of 11.246's failures have that shape and neither has the shape of a defect: one died in a
  `setUpAll` that walks every git blob, the other is six `pumpAndSettle()` calls, which fail on a
  *timeout*. **11.253 then ran ten clean passes on a quiet tree — the right way to measure a suite
  and the wrong way to reproduce that**, and the planning session is the one who asked for quiet.
  **So: when a suite goes red, write down what else was running before writing down which test
  failed**; and do not start a full suite in one window while the other is committing.

### 104. A new state can expose a defect that every existing ladder was blind to.

- **A new state can expose a defect that every existing ladder was blind to.** Task 11.204's closed
  panel made the Position map large enough to show that the observer markers had been clipping their
  initials from xxxLarge upward — **22 of 38 pixels at AX1, for as long as the markers have
  existed.** No text-size ladder could see it, because at every split those ladders had ever measured
  the map was too small for the marker to clip. **The third defect found on that same badge in ten
  days.** When a task adds a state, the existing tests are not evidence about it. Rule established
  2026-09-09.
  **Second instance, 2026-09-21 (task 11.301), and this one is a gate rather than a ladder — the
  same rule with the blindness on the other side.** Task 11.237 added a *snapshot / not-a-member*
  standing and a gate, `offersNothingFor`, that silences every row such a device might offer. Task
  11.57's departure delivery closes the membership row **locally first and then pushes it**, so from
  2026-09-13 the gate read that local closure, concluded "this device is not a member, offer
  nothing," and **silenced the very row whose whole job was to tell the server the person had
  left.** Every self-departure's push offered zero rows for eight days. Nothing was red: 11.237's
  tests cover 11.237's states, 11.57's cover 11.57's, and **no test existed for the intersection,
  which is where the defect lived.**
  **The shape to carry forward, because it will recur: a gate built to stop one thing can silence an
  unrelated feature's *exit path*.** A standing that means "you may no longer write about this
  project" is exactly the standing under which a person most needs to write the one row that says
  they are leaving it. **When a task adds a standing that suppresses writes, enumerate what that
  standing is still entitled to write** — and note that this instance was found only because a task
  happened to put a live fake transport in the loop and count the pushes, which is a stronger test
  than asserting on state.

### 105. A rule written in a document is not a rule the code obeys. Before planning against one, find the thing that enforces it.

- **A rule written in a document is not a rule the code obeys. Before planning against one, find the
  thing that enforces it.** The planning session read the Position screen's MAP SPACE BUDGET rule 4
  — *"a control that fits in a corner cluster costs the clear band nothing extra"* — and predicted
  from it that task 11.203's two stacked squares would cost nothing. **They cost the map more than
  half its clear band**, because the instrument that measures that band charges every overlay the
  subject's full width whatever its own width, and **says so in its own doc comment, on purpose**:
  a budget that lets furniture accumulate along one edge for free is the budget that produced the
  defect it exists to catch.
  > **Neither text was wrong when it was written and neither had gone stale. They contradicted each
  > other, and nothing could tell until a case arrived that separated them** — every overlay on
  > every screen really had been full width until 11.203 built the first one that was not. **That is
  > the shape to watch for: two documents each defensible on its own, disagreeing about a case
  > neither had seen.** The fix is never to quietly follow one; it is to notice the pair and settle
  > it in writing, deleting the losing text. Rule established by task 11.203, 2026-09-09.

### 106. A legible color can still be the wrong color, and no contrast check will ever say so.

- **A legible color can still be the wrong color, and no contrast check will ever say so.** The
  Position screen's tag label reads in the brand green because it is a bare `TextButton` and that is
  Material's default foreground — **nobody chose it**, which is the same class as the six
  `ColorScheme` fallbacks tasks 11.200 and 11.201 found. **But `theme_contrast_test.dart` cannot
  catch this one: the green is perfectly readable.** The guard measures whether a person can see the
  ink, and this defect is that the ink means something it should not. **When a color arrives by
  default rather than by decision, the question is not only "can it be read" but "was it picked".**
  Rule established 2026-09-09.

### 107. A gap that wants a check but does not yet earn one gets a trip-wire, not a note.

- **A gap that wants a check but does not yet earn one gets a trip-wire, not a note.** Task 11.192
  measured Dart's `comment_references` lint at **169 violations across 90 files**, sampled them,
  found almost all were live symbols the file simply had not imported, and **decided not to enable
  it — recorded, so the question is not re-opened at the next dead reference.** That left a real
  hole standing: **a prose or backtick reference to a file or a symbol is checked by nothing in
  this repository**, and the lint never covered it. **Do not write "we should watch this."** Write
  the count, the threshold and the action: **this class stands at two instances, and the third one
  buys a repository-wide checker for backtick-quoted filenames rather than another look at this
  lint.** A note asks a future reader to exercise judgement they will not have the context for; a
  trip-wire tells them what to do and when. Rule established by task 11.192, 2026-09-08.

### 108. Never reproduce a secret-shaped string in a report.

- **Never reproduce a secret-shaped string in a report.** Write about it — "the
  placeholder password in the workflow file" — rather than quoting the literal. Task
  11.68 found the committed-secrets check red on a placeholder, and by then the planning
  session's own reports had quoted that literal often enough to become part of why it
  could not simply be removed. **A report is a committed file too.**

### 109. If the task's own spec assumed a mechanism you did not build, say so rather than shipping the spec's words.

- **If the task's own spec assumed a mechanism you did not build, say so rather than
  shipping the spec's words.** Task 11.54's brief wrote a delete warning describing a
  destructive delete; the implementation was a soft one, so the sentence "you get back
  what the server holds, not what this device held" was false as shipped. **Copy that
  describes a mechanism the code does not have is the same defect as a message naming
  the wrong cause** — which is what that task existed to fix. The spec is not the
  authority on what you built; you are.
- **Second instance, from the planning session's side (task 11.335, 2026-10-07).** The brief asked for a fix
  to be "watched red with a test where `_weHaveLeft` fails". `_weHaveLeft` catches everything and answers
  "no", so it cannot fail; the brief assumed a failure path the code does not have. The task said so, made the
  failure exist temporarily to show the guard works, and removed it. **Before briefing "watched red where X
  fails", the planning session checks that X can fail; if it cannot, the brief asks for a guard on the promise
  and says why.**

### 110. A script can work because of where it is run rather than because it is right.

- **A script can work because of where it is run rather than because it is right.** Task 11.308
  went to exercise `scripts/server_up.sh` on the Mac and could not: under `set -u` — which the
  script has always had — expanding an **empty** array as `"${PRE[@]}"` is an `unbound variable`
  error on bash 3.2.57, the newest bash macOS ships. **The line was in the original script and had
  always been broken there.** Nobody knew, because the only machine anybody ran it on was a Linux
  VM with bash 5, where the same line is fine.
  **What makes this an entry rather than a footnote is how it was found: by accident, and only
  because the brief was ambiguous about which machine to use.** The planning session named no
  machine; the task picked the Mac; the script refused to start. **A brief that had said "run this
  on the VM" would have produced a clean report and left the bug in place** — and the planning
  session, watching the task struggle, advised stopping it on the grounds that the brief had sent
  it to the wrong machine. **That advice was wrong, and the ambiguity was the useful part.**
  **The rule: a script that has only ever run in one environment has been tested for that
  environment, not for correctness.** Before treating one as portable — or before telling somebody
  it is safe to run somewhere new — either run it there, or say plainly that nobody has. `set -u`
  plus an empty array is this instance; the class is every shell feature whose behavior differs
  between the bash a developer has and the bash a server has. Established 2026-09-22.
- **Instance, task 11.316 (2026-09-29): a build checked from the working tree, not a clean
  checkout.** The new Dockerfile copied `packages/tritrack_sync/pubspec.lock`, which `.gitignore`
  excludes. It existed on the Mac only as an untracked leftover, so the Mac build passed, and the
  VM's clean checkout had nothing to copy. **The same rule, one step earlier:** a build is proven
  only from what git would hand another machine. The fix's re-check used a clean `git worktree`
  of HEAD.

### 111. A cache that tracks its own last run is not a check on the current state.

- **A cache that tracks its own last run is not a check on the current state.** Task 11.309 set out
  to build a guard that runs `build_runner` and fails if anything generated changed. Run against the
  existing incremental cache, `build_runner` reported **"634 skipped, 0 outputs"** — it believed
  everything was current — **while two tracked generated files were genuinely stale**, which a
  clean run with the cache deleted found immediately.
  **The reason is the shape, not the tool.** The incremental cache records input digests as of its
  own last run; it never re-verifies that what is on disk matches what it last wrote. So a tree that
  was checked out, stashed, or branch-switched without the cache travelling with it desyncs
  silently, and the cache reports agreement with a state that no longer exists.
  **What makes this an entry: an incremental guard would have passed on the exact drift it was
  built to catch** — the cannot-distinguish-success-from-its-own-failure family, wearing a
  performance optimization. The guard therefore deletes `.dart_tool/build` before every run and pays
  25–31 s for it, gated to commits that touch `lib/`. **The general rule: when a check's job is to
  answer "does the output match the input *right now*", any cache between it and the answer is part
  of what it must not trust.** Established 2026-09-22.

### 112. A property stated without the events it must survive is not a specification.

- **The brief for task 11.58 said the server's database identifier is "minted once at schema
  creation", and a restore would have defeated it.** A backup copies every table, so a database
  restored from `backup.sh` would have come back with the *old* identifier, and devices would have
  trusted it. A restore is the exact event the task existed for. Claude Code caught it: `backup.sh`
  now dumps the table without its row, `restore.sh` empties it, and the server mints a fresh one.
  **The planning session wrote the property and not the event.**
  **The shape:** a value meant to be unique, permanent or "once" lives *inside* the thing that
  gets copied, so every copy carries it. **The rule, for whoever writes a brief:** when a brief
  says a value is unique, stable or minted once, name the events it must survive (a restore, a
  snapshot rollback, a clone, a migration) and say where the value lives relative to what each of
  those copies. The same brief also said a release-checklist line existed that did not (entry 27's
  provenance rule). Established 2026-09-29.

### 113. Under `pipefail`, a pipeline that ends in a command that stops reading early can say "missing" about a line it found.

- **The server-email drill printed "the relay's log does not confirm STARTTLS was required" beside a
  log that contained exactly that line, and passed the next five times.** The check was
  `docker logs "$C" 2>&1 | grep -qi "starttls required"`. `grep -q` leaves at its first match; if
  `docker logs` has anything left to write, that write finds nobody reading and the program is killed
  (SIGPIPE, status 141). Without `pipefail` the pipeline reports only the last command's status, so
  nothing shows; **with it, the first failure wins, and a *found* line reads as a failed check.**
  Task 11.330 (2026-10-06) reproduced it on the gate VM against a real four-line `docker logs`:
  **49 runs in 300 reported a present line as missing**, and 0 in 300 when the output was captured
  first. A six-line log written one line at a time failed 199 in 200.
  **Why it hid for so long:** whether it fires depends on how much the producer still has to write
  when the consumer leaves, so it is intermittent by construction, and an intermittent red gets
  re-run (entry 103). **A check that can read "found" as "missing" trains everybody to re-run reds.**
  **The shape is wider than `grep -q`.** `grep -m`, `grep -l`, `head`, `sed …q`, `awk …exit` and
  `read` all stop early. Sixty pipelines of that shape were found in fourteen scripts that set
  `pipefail`; only a few were fed by a producer large or slow enough to lose the race today, but
  **"short" is a property of the data, not of the line**, so the rule is the shape. The forms that
  cannot misread are `grep -q X <<<"$value"` (no pipeline at all), `… | grep X >/dev/null` (reads
  to the end), and `sed -n 1p` for `head -n1`.
  **The instrument:** `test/documentation/pipefail_early_exit_test.dart` derives the scripts from
  git, finds those that set `pipefail`, and fails on the shape. It carries a broken control for each
  consumer it claims to catch and was watched red against the unfixed tree first. **What it cannot
  see, and says so:** a shell function that wraps `grep -q` at the end of a pipe (none exist today),
  a consumer in another language that returns early, and a pipeline inside a string handed to
  another shell.
  **And the habit it corrects:** the 11.328 report said "cause not established" and listed the
  suspect, which was right, and asked for a task that would *make it fail on demand* — which is
  what turned a one-in-five shrug into a number. A suspect that costs ten lines to reproduce should
  be reproduced before it is filed. Established 2026-10-06.

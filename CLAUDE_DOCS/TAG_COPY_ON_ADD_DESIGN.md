# Copy-on-add for project tags — measurement and design

**Task 11.34, 2026-09-09. No production code was changed by this task.**

Michael decided on 2026-08-22 that **when a tag is added to a project it is copied
into that project**, so the project's tag is its own: editing it changes neither the
person's own tag log nor any other project. This document is the measurement that
decision needs before anybody writes the code, and a migration plan.

**Everything in §1 was read out of the code on 2026-09-09.** Where I could not
establish something, §1 says so in those words rather than guessing. §2 is design and
is argued rather than measured. §5 lists what this task deliberately did not settle.

---

## Michael's decisions, 2026-09-10 — both taken, both as recommended

- **Design B, the structural version, and now.** The tag table comes off the wire, `Project_Tags`
  retires, and the machinery that polices cross-project tag sharing is deleted rather than kept. **It
  costs a schema major bump to 3, and that is affordable exactly once — while nobody is in the
  field.** That window closes the day a beta team installs.
- **The provenance value is a lineage identifier**, as §2.3 proposes, not the pointer the brief asked
  for. **The departure is confirmed; §2.3's three reasons stand.**

> **And one thing Michael asked when he chose it, answered here so nobody re-derives it wrongly.** He
> asked whether the lineage identifier also gives a way to track a collar whose frequency or pulse
> rate is later changed. **Partly, and the part it does not do is the important one.**
>
> - **Within one project this is already solved and better than a lineage id could solve it.** Task
>   11.32's `Tag_Versions` means every bearing remembers the tag as it was when the bearing was taken.
>   Changing a frequency does not rewrite history.
> - **Across projects the lineage id lets you *find* the same collar. It does not update it, and that
>   is the whole point of copy-on-add** — editing one project's copy deliberately leaves the others
>   alone. Two projects' copies drifting apart is the intended behavior, not a defect.
> - **It cannot become an in-app prompt.** *"This collar's frequency changed in another project"*
>   would breach the standing rule that no message about a tag may reveal another project exists.
>   **So the realistic use is in exported data and cross-project analysis, not on a screen.**

---

## 0. The shortest version

- **Yes, the tag table syncs today.** `Tags` and `Tag_Versions` are two of the four
  *global* tables on the wire, alongside `Users` and `User_Emails`. Copy-on-add can
  take both of them off the global list, retire `Project_Tags` entirely, and leave
  the wire with **twelve tables instead of thirteen and one global reach set instead
  of two**.
- **Nothing in the app reads a tag across project boundaries for a *result*.** The
  map, the legend, the Log, the exports, the pickers and the position estimator are
  already narrowed to one project. Four things read the device's whole tag list, and
  all four are *choosing* screens rather than analysis: the Tag Database screen, the
  "Link existing tag" dialog, the near-duplicate warning, and the shared-bearing
  paste screen. **Two of those four are live defects today** — see §1.3.
- **The server already refuses to let two projects share a tag.** It has done since
  task 11.3. The app offers the operation anyway, and the row is held forever with a
  message that says the server would not say why. Copy-on-add does not change the
  server's answer; it makes the app agree with it.
- **A migration has almost nothing to move.** A tag that belongs to exactly one
  project — which is every tag the server will accept — keeps its own identifier and
  gains a `project_id`, exactly as schema v6 did. Only a tag linked to two or more
  projects *on one device* needs real duplication.
- **The brief's load-bearing premise is false.** Adding a tag to a project is
  **contributor-level, not owner-only**, on all three layers, deliberately, since
  2026-08-21. Phase 12's scoping argument rests on that sentence and needs rewriting.
  See §1.4.

---

## 1. The measurements

### 1.1 Does the tag table sync today? — **Yes. Measured.**

`syncTables` in `package:tritrack_sync` declares thirteen tables. Derived from that
declaration rather than read off by eye:

| Table | How it narrows to one project | Carries `tag_id`? |
| --- | --- | --- |
| `Users` | global, reached by `users` | no |
| `User_Emails` | global, reached by `users` | no |
| `Projects` | scoped by `project_id` | no |
| `Project_Memberships` | scoped by `project_id` | no |
| **`Tags`** | **global, reached by `tags`** | **yes** |
| `Project_Tags` | scoped by `project_id` | yes |
| **`Tag_Versions`** | **global, reached by `tags`** | **yes** |
| `Triangulation_Sessions` | scoped by `project_id` | yes |
| `Observations` | scoped by `project_id` | yes |
| `Observation_Exclusions` | scoped by `project_id` | no |
| `Non_Detections` | scoped by `project_id` | no |
| `Estimated_Positions` | scoped by `project_id` | yes |
| `Actual_Tag_Locations` | scoped by `project_id` | yes |

So: **four global tables, two of them tags; seven tables carry a `tag_id`.**

**What "global" costs on the wire.** A global table has no `project_id`, so neither
side can decide what a project may see by looking at the row. Both sides instead
compute *reachability* — the set of tag ids named by that project's scoped rows — and
narrow the table to it. That machinery exists on both sides of the wire and is
tag-specific in four places:

- `ProjectReachability.resolve` on the server (the pull filter), and
  `reachableIdsFor`, which turns a `GlobalScope` into that set.
- `_globalReachClause` in the client's `sync_engine.dart` (which rows a device may
  *offer*), added by task 11.41 after a device with a second local project offered
  that project's tag to the first project's server and got a permanent red bar.
- `RowAuthorizer._authorizeTagReferences` on the server — **161 lines of code under
  about 200 lines of argument**, plus `_tagIsClaimedElsewhere` (24 lines),
  `_tagRowExists` (8) and `_noteEstablishedTag` (5) with its `_establishedThisPush`
  set.
- `offer_order.dart` in the shared package (224 lines), which exists because a tag
  reference in HTTP request *n* can only be vouched for by a `Project_Tags` row
  committed in request *n−1*.

**Under copy-on-add all four collapse.** A tag becomes an ordinary project-scoped row
and `Observations.tag_id` becomes an ordinary same-project reference — the identical
shape as `Observations.(session_id, project_id) → Triangulation_Sessions`, which
`RowAuthorizer._authorizeReferences` has handled since task 11.46. `GlobalReachSet`
drops from two members to one. **That is the reduction in attack surface the brief
asked me to state if it was real: it is real, and it is larger than one table.**

### 1.2 What reads a tag across project boundaries today?

Taken one by one, as the brief asks. **"Stops needing a cross-project answer"** means
the reader is already project-scoped and copy-on-add simplifies it; **"changes"**
means somebody has to decide something.

| Reader | Today | Under copy-on-add |
| --- | --- | --- |
| **Map rendering** (rays, estimates, truth points, colors) | Reads this project's `Project_Tags` links, then looks each tag up by id in the global table | **Stops needing a cross-project answer.** One project-scoped read replaces a link-then-lookup. Nothing breaks. |
| **Map legend** | Built from the same per-project tag rows | **Stops needing one.** Nothing breaks. |
| **Log screen** | Collects the tag ids this project's own rows name, then looks each up | **Stops needing one.** Nothing breaks. |
| **Position estimation, Record screen tag wheel, Pre-trip checklist, Data Export's tag filter** | All read `projectActiveTags(projectId)` — the project's links, then the tags | **Stop needing one.** Nothing breaks. |
| **Project export / backup archive** | Collects the tags a project's rows reference *by reachability*, plus their whole version history | **Stops needing one** — tags become an ordinary scoped table like the other nine. The archive also starts carrying the provenance value (§2.3), which is what makes cross-project analysis possible from files. |
| **Server pull** | Narrows `Tags` and `Tag_Versions` by reachability | **Stops needing one.** Both tables move into the ordinary `WHERE project_id = ?` path. |
| **Server push authorization** | `_authorizeTagReferences` and friends | **Stops needing one**, as §1.1 describes. |
| **Tag Database screen** (the personal tag log) | Lists **every tag on the device** | **Changes.** It becomes the person's own library, and it is the screen that has to say plainly that a project's tag is a copy. See §2.5. |
| **"Link existing tag" on Project Setup** | Offers **every tag on the device** that is not already active on this project | **Changes**, and this is where a live defect is fixed. It becomes "copy a tag from your library into this project". See §1.3(a). |
| **Near-duplicate warning** (`NearDuplicateTags`) | Compares against **every tag on the device**, and its wording distinguishes "already on this project" from "in the tag database, not on this project" | **Changes.** It compares against the destination project's tags and the library. It also acquires a new trap: a copy *is* a duplicate of its library entry, so the check must not fire on the copy itself. See §2.6. |
| **Shared-bearing paste screen** | Matches the pasted payload against **every tag on the device** | **Changes**, and this is the second live defect. See §1.3(b). |
| **Tag color round-robin** | Counts **every tag on the device** to pick the next palette color | **Changes.** See §2.7. |
| **Tag CSV export / import** | Exports whatever the Tag Database screen is showing; imports into the global table plus an optional link | **Changes** — two lists to export from instead of one. §2.8. |
| **Archive import (`ProjectMerger`)** | A `Tags` row from a file is written over the local row with the same id, last-write-wins, with **no project check**, because the table declares no project column | **Stops needing a cross-project answer**, and this closes a live behavior nobody has listed. See §1.3(c). |
| **Phase 12's merge** | Would have had to reconcile duplicates across projects and within them | **Shrinks to within-project only**, which is what the plan already says. The *reason* the plan gives for duplicates staying rare is wrong — §1.4. |

**Nothing in the app computes a scientific result from more than one project's tags.**
I looked for one and did not find one: every analysis path — the estimator, the
exclusion marks, the exports, the map — is keyed on a single `project_id`. The
observation-sharing payload deliberately carries a tag **key** (frequency, pulse rate,
name) rather than a `tag_id`, with a comment saying tag ids are per-device UUIDs and
the receiving device must relabel the record onto its own tag. **That path already
assumes the model copy-on-add is proposing.**

### 1.3 Three things that are wrong today, found while measuring

**(a) The app offers an operation the server has been refusing since task 11.3, and
the person is never told why.**

`RowAuthorizer._tagIsClaimedElsewhere` asks whether any project *other than the one in
the push envelope* references this tag. If one does, the link is refused. There is no
exception for the same person: the comparison is against the envelope's project, not
against every project the caller owns. **So a tag cannot be linked to two projects on
the server, by anybody, including the person who owns both.**

The "Link existing tag" dialog on Project Setup offers every tag on the device. Pick
one that another project already uses and the link is written locally, appears to
work, and is refused on the next sync — permanently. The held-row screen cannot
explain this one: its tag branch asks whether the *record's* tag has been added to
this project, and for the link row itself the answer is yes locally. The person gets
the honest fallback — *"The server would not take this record and did not say why"* —
and a "Try again" that will never succeed.

**Read from the code; I did not reproduce it against a running server.** The refusal
for a *stranger* doing this is asserted in the server suite; the same-owner case is
not, and the code has no branch that would treat it differently.

**(b) The shared-bearing paste screen can attach an imported record to another
project's tag.** `_parse` walks `localTagsProvider`, which is every tag on the device,
and stops at the first whose frequency and name match the payload. Save, and an
`Observations` row lands in the current project naming a tag that project does not
reach — refused by the server, held. The held-row screen *does* explain this one
correctly. Read from the code, not reproduced.

**(c) Importing a colleague's archive can rewrite a row in your own tag log.**
`ProjectMerger` scopes every incoming row to the archive's manifest project — except
that the check is skipped for tables with no project column, which is exactly `Users`,
`User_Emails` and `Tags`. So an incoming `Tags` row with an id you already hold is
merged into your row by last-write-wins, whatever project of yours that tag belongs
to. Identifiers are random UUIDs, so this needs the two devices to genuinely be
talking about the same tag row — which is precisely what happens when two people
worked from one shared tag. **This is canceled task 11.29's problem on the import
path, and copy-on-add removes it by construction.**

### 1.4 The brief's premise about who may add a tag is false, and Phase 12 depends on it

Both this task's entry and Phase 12's scoping paragraph say: *"adding a tag to a
project is owner-only, so one person does the adding… that decision is now
load-bearing."*

**Measured: adding a tag to a project is contributor-level, on all three layers, and
deliberately.** `ProjectTagRepository`'s own comment settles it — *"Deactivating is
owner-only; activating is not (task 11.12, decision 2026-08-21)… additive,
unblocking, contributor-level, same as creating a tag."* The server agrees: the
`Project_Tags` case in `_authorizeGrantingInsert` defers to the ordinary role gradient,
and `anyUser` means a member with write rights. `PERMISSIONS_MATRIX.md` §7 row T2 says
so too, and says in as many words that the owner-only note *"was about T3, not T2."*

**What is owner-only is *removing* a tag from a project**, enforced since task 11.24
after a contributor's device pushed the removal directly and the tag disappeared for
the whole team. That rule is load-bearing for something else entirely and has nothing
to do with duplicates.

**So what actually holds within-project duplicates down is the near-duplicate
warning, and a warning is something a person clicks past.** All four creation paths
call it; its buttons are "Go back" and "Create anyway"; it refuses nothing, on purpose,
because a field tech who cannot create a tag cannot record the observation.

This does **not** weaken the brief's other claim. Copy-on-add still makes Phase 12
smaller, because cross-project duplicates stop mattering by definition and no analysis
ever spanned projects. It weakens the claim that the remaining duplicates will be
**rare** — and that was the argument for deferring Phase 12 past the beta. **Somebody
should decide whether that deferral still holds.**

### 1.5 An orphan tag does not replicate today, and that is what makes the library free

`TriTrack_Security_Model.md` §5.9(a) keeps the orphan-tag write path open with this
reason: *"the tag database is a lab's global list of transmitters, so a tag not yet on
any project still has to replicate between one person's phone and their laptop.
Refusing that would hold somebody's own tag hostage on their own device."*

**Measured: that flow does not work today, in either direction.**

- **The device will not offer it.** `_pendingClause` narrows a global table by
  `_globalReachClause`, which requires the tag id to appear in a project-scoped row of
  the project being synced. A tag in no project appears in none, so it is never queued
  for any project's push.
- **The server would not return it.** Pull narrows `Tags` to `ProjectReachability`'s
  tag set, computed the same way. A tag in no project is in nobody's set.

Sync is per-project on both sides, and an unlinked tag belongs to no project, so there
is no request that could carry it.

**Two consequences.** First, §5.9(a)'s stated justification is currently unmet — the
residual is being kept open to protect a flow that does not exist. That is the
*"a recorded failure reason nobody re-derived"* class turned on the project's own
records, and it should be corrected whatever happens to this task. Second, and this is
what unblocks the design: **making the personal tag library a device-local table costs
nothing that works today.** §2.1's biggest apparent cost turns out to be free.

I also checked the route the security model's finding F4 gives for how an outsider
gets an orphan tag's identifier — *"tag ids travel in Phase 6 share payloads."*
**They do not.** The share payload carries a tag key and no id, deliberately, and the
tag CSV export has no `tag_id` column either. The only shipped artefact carrying tag
ids is the project backup archive, and an archive only collects tags its project
references — which makes them claimed, not orphaned. **I could not find a shipped path
that puts an orphan tag's identifier in anybody else's hands.**

### 1.6 What I could not determine

- **Whether Michael's own devices hold any tag linked to more than one project.** I
  cannot read his SQLite file. §3.1 gives him the query, and the migration must not be
  written to assume the answer.
- **Whether the server's Postgres holds such a tag.** It cannot have been created
  through the app (§1.3(a)), but a hand-crafted push or a dev fixture could have. §3.4.
- **Whether §1.3(a) and (b) reproduce against a running stack.** Both are read from
  the code. Neither has a test today.
- **How much of the 101 test files that touch tags would need changing.** That is the
  count of files mentioning `Tables.tags`, `Tables.projectTags`, `Tables.tagVersions`,
  `TagRepository` or `ProjectTagRepository` across `test/`, `server/test/`,
  `packages/tritrack_sync/test/` and `integration_test/`. It is the honest size signal
  for the implementation task; it is not a count of files that will actually change.

---

## 2. The design

### 2.1 Two designs, and they buy very different things

**Design A — copy-on-add as a behavior.** The copy gets a fresh `tag_id`; the schema
keeps `Tags` global and keeps `Project_Tags`; each tag ends up linked to exactly one
project because nothing ever links an existing one twice. Additive schema change,
minor version bump, `schemaMajorVersion` stays at 2, no device is stranded.

**Design B — copy-on-add as a structure.** `Tags` gains `project_id` and becomes
project-scoped and keyed `(tag_id, project_id)`; `Tag_Versions` follows it;
`Project_Tags` retires; the personal library becomes a device-local table that never
crosses the wire. Minor bump **and a major bump to 3**.

**A deletes the question for honest users and keeps every line of code that exists for
dishonest ones.** Under A the server still cannot know the invariant: `Tags` is still
global, so a hostile device can still push a link claiming another project's tag, and
`_tagIsClaimedElsewhere`, the orphan clause, the reachability machinery, the
offer-order constraint and the "linking is a grant" flag all stay, all load-bearing.
The brief's argument for this task is *"it deletes an authorization question."* **Only
B collects on that.**

**B also closes §5.9(a) and finding F4 by construction** — there is no such thing as
an unlinked synced tag, because a tag row cannot exist without a project. §1.5 shows
the only thing that stood in the way of taking the library off the wire is a flow that
does not work.

**Recommended: B, and before the beta.** A major bump strands every device in the
field until it updates, which is why the technical context calls it a last resort — but
**there are no devices in the field.** The security model records the same argument for
the only previous bump: it was spent while nothing was deployed, *"which is the only
time it is cheap."* That window is still open and will close the day a beta team
installs the app.

**The honest cost of B, stated so it can be argued with:** a schema major bump, a
migration on two databases and the archive reader, and work across a set of files whose
outer bound is the 101 in §1.6. If Michael would rather not spend that now, A is a real
option — but it should be taken knowing it buys the product decision and not the
security one, and that B gets *more* expensive the moment anybody is in the field.

**Everything below describes B.**

### 2.2 What B changes in the schema

`Tags` gains three columns and a new primary key:

- `project_id TEXT NOT NULL REFERENCES Projects(project_id)` — the scope.
- `lineage_id TEXT NOT NULL` — provenance; see §2.3.
- `copied_at TEXT` — when this copy was made, null on a tag created in place.
- Primary key becomes `(tag_id, project_id)`, id first, scope second — the order
  schema v6 argues for and for the same reason: by-id lookup is the query this schema
  runs most.

`Tag_Versions` gains `project_id` the same way and its foreign key into `Tags` becomes
composite. **Task 11.32's design is untouched.** A bearing still holds a *reference to
the tag's state as it was* rather than a copy of selected fields; the version rows
simply live inside the project like everything else. The brief's question — where do
those versions live once a tag is project-local — is answered: **beside their tag, one
chain per project copy.**

**A new device-local table holds the personal library.** Same columns as `Tags` minus
`project_id` and `copied_at`, plus `lineage_id`. It is **not** in `syncTables`, so it
never appears on the wire, in an archive, or in any reachability computation. It is the
thing you copy *from*, and it is the answer to "what is my lab's transmitter list".

`Project_Tags` comes off `syncTables` but **stays in the local schema, unused**. It is
the record of which projects once shared a tag, which is the only durable evidence of
what the migration in §3 did, and an old backup archive still carries its rows.

**Three columns forces three decisions, and the code already demands them.**
`tagColumnKinds` declares what every `Tags` column means to a record already taken
against that tag, `assertEveryTagColumnDeclaresItsKind` makes an undeclared column a
failing test, and the enum has no default on purpose. `project_id` is `identity`.
`lineage_id` and `copied_at` are neither identity, display, collar-life nor
bookkeeping — **they want a new `TagColumnKind.provenance`**, whose whole meaning is
*never copied onto a version row and never read by anything live.*

### 2.3 The provenance value — and a departure from the brief I want confirmed

The brief asks for **"copied from this tag on this date"** — a pointer to the source
row, explicitly non-authoritative, never read by anything live. I want to propose a
variant, and say plainly why, because the difference matters and the choice is not
mine to make.

**Proposed: a lineage identifier rather than a pointer.** A random UUID minted when a
tag is first created and **carried unchanged by every copy of it, forever**, plus
`copied_at`. Two projects' tags are the same physical collar exactly when their
`lineage_id` values are equal.

**Why a lineage id is better than a pointer, in three ways.**

1. **It cannot dangle.** A pointer names a row, and the row it names is either in a
   device-local library the reader does not have, or in a project the reader cannot
   see. A lineage id names nothing, so there is nothing to resolve and nothing to be
   missing.
2. **It is transitive without ever referring to another project.** Copy the library
   entry into A and into B, and both carry the library entry's lineage. Copy A's tag
   into B directly and B **inherits A's lineage rather than pointing at A** — so a
   project's tag never holds a reference into another project at all. A pointer would.
3. **It survives the case a pointer cannot.** A tag created inside a project and later
   copied elsewhere has no source row to point at. A lineage id is already there,
   because it was minted at creation.

**The disclosure constraint, discharged.** Canceled task 11.29 left the rule that *no
message about a tag may reveal that another project exists*, and the brief keeps it
precisely because a provenance value is a link to something the reader may not have
access to. Under this design:

- **Nothing renders it.** No screen resolves a lineage id or a `copied_at` into words
  about another project, because there is nothing to resolve.
- **What a member of one project can learn from it is nothing the tag's own fields do
  not already say.** Two projects' copies of one collar share a lineage id — and they
  also share a frequency and usually a name, which are in both projects' data already.
  Comparing lineage ids across two exports tells you two projects hold the same collar;
  so does comparing the frequencies.
- **A project's tag never names a row outside that project**, by rule 2 above. That is
  the property the constraint actually wants, and it is structural rather than a
  promise about copy.

**"Never read by anything live" needs a mechanism, not a comment.** The precedent is
already in the codebase: `assertUnvalidatedIdListColumnsFeedNoReachability` fails if
`Non_Detections.tag_ids_listened_for` or `Estimated_Positions.observation_ids_used` is
ever declared in `userColumns`, `tagColumns` or `emailColumns` — the three declared sets
every reachability and naming computation walks. **The implementation task should
extend that assertion to `lineage_id`** rather than write a fresh one-off guard, and
should carry a positive control that fires in the same run.

> **Built, task 11.219, 2026-09-10 — and the assertion has a different name now.** It is
> `assertSealedColumnsFeedNoReachability`, in `packages/tritrack_sync/lib/src/sync_tables.dart`.
> The old name said *unvalidated id list*, which described the two columns it happened to
> guard rather than the property it enforces; `lineage_id` is neither a list nor unvalidated,
> and keeping the name would have made every future reader ask whether the widening was a
> mistake. **A reader following the old name from this paragraph will not find it** — which is
> why this note exists rather than a silent rename. The provenance columns it now also seals
> are declared in `provenanceColumns` beside it, and the positive control lives in that
> package's `sync_tables_test.dart`.

**The one thing a lineage id loses**, said out loud: it does not tell you *which*
library entry a copy came from. Nothing needs that — the library is device-local and
may not exist on the reader's device at all — and on the device that made the copy the
library entry is right there. If Michael wants the literal source identifier anyway, it
belongs in a device-local column that never crosses the wire, because that is the only
place it is both useful and safe.

**This is the one design decision in this document I would like confirmed before
implementation.**

### 2.4 What B changes in authorization

`Tags` and `Tag_Versions` become ordinary project-scoped tables:

- **Pull** narrows them with `WHERE project_id = ?` like the other nine.
- **Push** judges them with the ordinary role gradient plus `_authorizeReferences`'
  existing same-project composite-key check. `_authorizeTagReferences`,
  `_tagIsClaimedElsewhere`, `_tagRowExists`, `_noteEstablishedTag` and
  `_establishedThisPush` all retire.
- **The one rule that must survive is the create/edit asymmetry**, and it is the only
  thing in that 161-line method that is about the product rather than about globality:
  *a contributor may create a tag; only an owner may change an existing one*, because
  creating is additive and recoverable while changing rewrites what every already-
  recorded bearing means. Same for a `Tag_Versions` row: appending is contributor-level
  and forward-only, rewriting one is the owner-only correction path. **Both keep their
  reasons and both keep their tests.** Under B they become an ordinary per-table rule
  over a scoped row instead of a special case for a global one.
- `insertIsAGrant` loses its `Project_Tags` entry. Copying a tag into a project is no
  longer a read grant over a global row; it is creating a row inside a project the
  caller is already in.
- `TagRepository.assertMayEdit` loses its whole "any project this tag belongs to" walk
  and becomes a single role question about one project.

### 2.5 Telling the user it is a copy — in both directions

Michael's decision names this explicitly, and the direction that will actually confuse
people is **editing the library and expecting the project to follow.** So:

- **On the library screen (Tag Database)**, where a tag is used by at least one
  project, the screen has to say that changes here do not reach those projects. The
  count is a device-local fact — how many of *this device's* projects hold a copy —
  and stating a count is safe. **Naming the projects is not**, for a device that holds
  a project the reader is only a viewer on; the count alone is what the constraint
  permits everywhere.
- **On a project's tag**, that it was copied from the library on a date, and that
  editing it here changes this project only.
- **At the moment of copying**, in the confirmation, that this makes a separate copy —
  because that is the one moment the person is definitely reading.

**Following Michael's standing simplicity instruction of 2026-09-07** — emphasise
readability over verbosity so long as the option is findable by exploring or by tapping
an information affordance — the long form of each of these belongs behind an
information icon, not permanently on the screen. What stays on screen is the short
fact. **The exception the same instruction names applies here:** getting this wrong
writes the wrong data, so the current state must be unambiguous without relying on a
color or a bare glyph.

### 2.6 The near-duplicate warning, and the trap in it

Today it compares against every tag on the device and its wording distinguishes
"already on this project" from "in the tag database, not on this project". Under B it
compares against the destination project's tags and the library, and the second phrase
becomes "in your tag library".

**The trap: a copy is by definition a duplicate of its library entry.** If the copy
goes through the same check as a creation, every single add warns, and a warning that
always fires is a warning people learn to dismiss — which is the failure the check's
own doc comment says it exists to avoid. **A copy whose lineage matches the source is
not a near-duplicate and must not be reported as one.** Two copies with the *same
lineage* inside one project, on the other hand, is a real defect and should be refused
rather than warned about — there is no legitimate reason for a project to hold the same
collar twice.

### 2.7 Color

Today the next palette color is chosen by round-robin over **every tag on the device**,
from a twelve-color palette, and tag color is the map legend's key. Copying doubles
the device-wide row count, so a device-global counter drifts twice as fast and
within-project color collisions get worse.

**Recommended: a copy keeps its library entry's color; a tag created new inside a
project round-robins over that project's tags.** That keeps one collar looking the same
in every project a person holds — which is what a person expects and what makes a
screenshot comparable across projects — while making the within-project collisions the
legend actually cares about as rare as the palette allows.

### 2.8 CSV export and import

Two lists to export from instead of one: the library, and a project's tags. The
existing header round-trips through `TagCsvImport` and should keep doing so.

**`lineage_id` should be exported and must be ignored on import.** Exported, because
the CSV is one of the two ways a lineage leaves the device and a multi-year analysis in
R is exactly the use the brief names. Ignored on import, because a lineage must be
minted locally — a file that could assert one could assert that two unrelated collars
are the same animal, and that is a claim about the primary scientific record. **The
loss is real and should be on the import preview screen in words: importing a
spreadsheet creates new tags, and their lineage starts here.** The archive is the
artefact that preserves lineage; the CSV is for people and spreadsheets.

---

## 3. Migration

### 3.1 Measure first, and print what you found

The first thing the implementation task does is count, on whatever database it is
about to touch, and print the four numbers: tags in total, tags linked to exactly one
project, tags linked to two or more, tags linked to none. **A migration that forks rows
must say how many it forked**, in its own output, or nobody can tell a clean run from a
run that did nothing.

Michael can answer the same question about his own device before any of this is built.
The client database is a SQLite file named `tri_track.db`; the query is:

```sql
SELECT n, COUNT(*) FROM (
  SELECT t.tag_id, COUNT(pt.project_id) AS n
  FROM Tags t LEFT JOIN Project_Tags pt ON pt.tag_id = t.tag_id
  GROUP BY t.tag_id
) GROUP BY n;
```

A row with `n = 0` is a tag in no project; `n >= 2` is a tag the migration has to fork.
~~**If the `n >= 2` count is zero on every database anybody cares about, the whole fork
path in §3.3 is dead code and should be written as a refusal instead**~~ — but it must
not be *assumed* zero, because the local schema permits it and the app offers it.

> **Overtaken by events, 2026-09-10.** The refusal was written (task 11.219, on a Mac that counted
> zero), **it fired on Michael's iPhone the first day it met a real database** — two collars held by
> two projects each — and **task 11.224 replaced it with the fork this section describes.** The
> struck sentence is left standing, struck, because the reasoning it records is sound and the
> sentence after it is the one that turned out to matter: *it must not be assumed zero.* **It was not
> assumed, and that is the only reason this cost an evening rather than a field season.**

### 3.2 A tag in exactly one project keeps its identifier, and no data moves

This is the common case and, per §1.3(a), the only case the server will accept. The
row keeps its `tag_id` and gains the `project_id` of its one link. Every
`Observations.tag_id`, `Estimated_Positions.tag_id`, `Triangulation_Sessions.tag_id`,
`Actual_Tag_Locations.tag_id`, `Tag_Versions.tag_id` and
`Observations.tag_version_id` still resolves, untouched. Its `lineage_id` is set to its
own `tag_id` — stable, already unique, already unguessable — and `copied_at` stays null,
because nobody copied it.

**That is schema v6's move exactly**: the new key is derived entirely from what the row
already holds, which is what makes `INSERT … SELECT` sufficient and what lets the
archive reader carry an older payload forward.

### 3.3 A tag in two or more projects is forked, and the fork is the whole of the work

Order the tag's links by their `created_at`, ascending. **The first link's project keeps
the original `tag_id`** — deterministic, and it is also the project the server would
have accepted first, so a device and a server that both run this migration are most
likely to agree. Every later link's project gets a **new** tag row: fresh `tag_id`, the
same `lineage_id` as the original, `copied_at` set to that link's `created_at` (the day
that project actually adopted the collar, which is the true answer and is already
recorded).

Then, for each forked project, in this order:

1. **Fork the version chain.** Copy every `Tag_Versions` row of the original with a
   fresh `tag_version_id`, the new `tag_id` and the new `project_id`, preserving
   `effective_from` and every measurement column. A version chain is the drift record
   and both projects are entitled to the whole of it.
2. **Re-point that project's rows.** `Observations`, `Estimated_Positions`,
   `Triangulation_Sessions` and `Actual_Tag_Locations` in that project move to the new
   `tag_id`; each `Observations.tag_version_id` and `Actual_Tag_Locations.tag_version_id`
   moves to the forked version with the same `effective_from`.
3. **Leave `Non_Detections.tag_ids_listened_for` alone, and say so.** It is an
   unchecked delimited id list that feeds no reachability, by §5.9(b)'s standing
   decision and the assertion that enforces it. Re-pointing it would be the first thing
   in the codebase to read it as a real relationship, which is exactly the day that
   assertion is designed to go red. **The honest consequence is that a forked project's
   non-detections keep naming the original tag's id, which is a dangling reference and
   was already permitted to be one.** It should be written into §5.9(b) rather than
   discovered by a later reader.

**A tag in no project moves to the library and is deleted from `Tags`.** Nothing
referenced it — that is what made it an orphan — so nothing dangles.

**Every tag also gets a library entry**, so the library is a complete list of the
person's transmitters on day one rather than empty. A tag whose lineage already matches
an existing library entry contributes no second entry.

### 3.4 The server, and the archive

**The server.** The same fork logic expressed as Postgres DDL and DML, as schema v14 on
both sides, mirroring the app's statements the way every migration since v6 has. But
~~**there is no production data**, and the cheapest honest answer may be to drop and
recreate the development database rather than to write and test a fork that has never
had a row to fork.~~ **That is Michael's decision and it should be taken explicitly, not
by default.** If the fork path is written on the server, §3.1's counts should be printed
before and after.

> **Corrected 2026-09-11 (task 11.227). The server has data.** Michael ran task 11.222's
> census on the Ubuntu VM that runs the beta stack, on 2026-09-11, and it reported **schema
> version 11, five collars — four linked to exactly one project, none linked to two or more,
> one linked to none — and no record naming a collar in a project it is not linked to.**
> Whether those five are a field season or seeded rows is his to say; *"no production data"*
> is not what the database reports, and the struck sentence is left standing so the reasoning
> that followed from it can be read for what it was. What the server's v14 migration actually
> does, as of that task: a collar linked to one project keeps its identifier (§3.2); a collar
> linked to two or more is **refused, by name, before anything moves** — the server never
> forks, because on a database holding other people's records that is a person's decision;
> a collar linked to none and named by nothing is **deleted, counted and named in the server's
> startup log** — the server-side equivalent of §3.3's "move to the library and delete", there
> being no library; and a collar linked to none but still named by something is refused with
> the naming tables listed. The migration reaches v14 from v11 through v12 and v13, and
> `server/test/schema/postgres_migration_upgrade_test.dart` runs that whole path against a
> fixture built from the census above.

**The archive.** `SchemaMigrator` carries an older backup's row payload forward, and it
must gain a step for v14. It is the one place the fork logic is definitely needed
regardless of what the databases hold, because an archive written last week is a v13
payload forever. The step has everything it needs: an archive carries both `Tags` and
`Project_Tags` rows, so the pairing is right there in the payload. **This is also why
`Project_Tags` should stay in the local schema** — deleting the table would not delete
it from the archives.

**The major bump means old builds stop syncing.** That is what a major bump is, it is
the price of the design, and it is nearly free today for one reason: nobody is in the
field. It will not be free once somebody is.

### 3.5 What the migration must not do

- **It must not invent a version.** A tag that has no `Tag_Versions` row today has none
  after this, for the reason schema v9 gives at length: a version invented now is a
  claim about a past nobody observed.
- **It must not backfill `copied_at` with today's date.** A tag that has always been in
  one project was not copied, and `copied_at` is null for it. The forked ones get the
  link's own `created_at`, which is a date somebody actually recorded.
- **It must not delete `Project_Tags` rows.** They are the audit trail of what the fork
  did.
- **It must not run with foreign keys enforced.** `runMigrations` already turns them off
  and `_assertForeignKeysIntact` checks afterwards; a fork this size is exactly the case
  that check exists for.

---

## 4. Documents that become wrong the day this lands

Listed so the implementation task does not have to find them, and so nobody is left
reading a stale sentence:

- **`TriTrack_Security_Model.md` §5.9(a)** — the orphan-tag residual stops existing.
  **Its stated justification is already unmet today (§1.5) and should be corrected now,
  regardless of this task.** Its finding **F4** goes the same way, and F4's claim that
  tag ids travel in share payloads is false as written.
- **`TriTrack_Security_Model.md` §5.9(b)** — gains the sentence in §3.3(3) about forked
  projects' non-detections.
- **`PERMISSIONS_MATRIX.md` §7.** T2 becomes "copy a tag into this project". T4 loses
  *"of **any** project that uses the tag"*. **T7 — adopt a tag no project uses —
  stops being a capability, and per the convention set on 2026-09-07 it is struck
  through and dated, not deleted**, so a later reader can tell *decided against* from
  *nobody thought about it*. The matrix's own note that a tag is *"a **global** record
  that a project selects"* is the sentence the whole section is built on and it goes.
- **`TriTrack_Technical_Context.md`** — *"Tags are global; linked to projects via
  junction table"*, the `Project_Tags` table description, the `anyUser` rule row that
  names three tag tables, the `insertIsAGrant` paragraph naming `Project_Tags`, and the
  data-model summary line *"Tag database is global; each project selects a subset"*.
- **`DEVELOPMENT_PLAN.md`, Phase 12** — the "one dependency to respect" sentence is
  false (§1.4) and the deferral argument that rests on it needs re-taking.
- **`DEVELOPMENT_PLAN.md`, task 11.56** (clone a project for a new season) is
  explicitly deferred until this lands and should be re-read against §2.3: its own entry
  already says it wants the provenance value on the same terms.
- **User-visible copy changes**, which the website quotes: the Tag Database screen, the
  "Link existing tag" dialog, the near-duplicate warning's second phrase, the CSV
  import preview. **The implementing task must run the website's copy-drift check
  before it reports** — the pre-commit suite does not cover it.

---

## 5. What this task deliberately did not settle

- **Whether to build A or B.** §2.1 recommends B and gives the argument; the decision
  is Michael's and it is a spend of a schema major.
- **Lineage id versus the literal pointer the brief asked for.** §2.3 recommends the
  lineage id and says what it loses. I want this confirmed rather than assumed.
- **Whether the server's development database is migrated or recreated.** §3.4.
- **Whether Phase 12's deferral past the beta survives §1.4.** That is a scheduling
  decision, not an engineering one.
- **The three live defects in §1.3.** They are real today, they are independent of this
  design, and none of them is fixed by a document. They need task numbers.

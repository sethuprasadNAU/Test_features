# TriTrack — who may do what, and what happens when two people disagree

**Filled from the code by task 11.23 on 2026-08-22.** The skeleton was written
2026-08-21 by the planning session while task 11.9 was running, deliberately
outside the git tree so it could not be swept into that task's commit. Nothing
below is filled from memory; every verdict was read out of the source, and every
cell carries the symbol that implements it.

**Read this before filling anything in.** Finding N-1 is what this document
exists to prevent, and it is worth stating as the motive rather than as an
example. An exemption in the naming rule was written when a project reached one
person's own phone and laptop, and it was correct then. When membership records
joined the reachability query it silently became "every teammate may be named",
which is how a contributor can now sign a bearing with a colleague's name.
**Nothing was written down when that took effect.** No single change was wrong;
the combination was, and no artifact existed where the combination would have
been visible. This is that artifact.

**What this document is for.** Phase 11 built roles, project joining, shared
recordings, corrections to other people's records, and tag management. Each
piece was decided correctly and separately, and the result is a set of rules no
one person can hold in their head — including the person who wrote them. This
document is the single place where every one of those rules is stated, in one
notation, so it can be read and checked rather than reconstructed.

**What it is not.** It is not a record of security findings — that is
`TriTrack_Security_Model.md`, which is organized by what was discovered and
when. This document is organized by *capability*, which is a different axis, and
mixing the two is how you get a document nobody can audit.

---

## Where the derivation stops *(task 11.123, 2026-09-06)*

***Hand-kept*** — this section is the registry itself. The check enforces that every heading below carries a marker; nothing enforces that this prose is right.

**One derived section in a hand-kept document is more dangerous than none**,
because it teaches a reader to trust the rest. Task 11.84 derived §4.2 honestly
and said so in its report. This is that sentence moved to where the tables are.

**Every heading in this document carries one of two markers**, on its own line
directly beneath it, and a check refuses to pass if one is missing:

- ***Derived*** — a committed test parses this section's text and diffs it
  against the code in both directions. Something here being wrong is a test
  failure, not a matter of somebody noticing. The marker names the test.
- ***Hand-kept*** — **no test reads these words.** They can be wrong, and
  nothing will say so. Where the rule described *is* enforced somewhere in
  code, the marker says which test enforces it — but that test does not read
  this document, so the two can still disagree.

**What can be derived here, and what cannot.**

- **§4.2 can be, and is.** Membership operations map one-to-one onto HTTP
  routes, and a route is a thing the server's source enumerates.
- **§4.3–4.5 cannot be, by this instrument.** Those are sync-path writes gated
  by `RowAuthorizer` and by table declarations — the truth is in the code, but
  it is a *different* enumeration, keyed on tables and columns rather than on
  routes. A route-shaped check aimed at them would find nothing to disagree
  with and pass forever, which is this project's oldest defect class wearing a
  clean shirt. Deriving them is real work and needs its own task.
- **Some cells have no code-side truth at all.** The Screen and Device columns
  say where a person meets a rule; the Unknown column and every Notes cell are
  argument. Nothing in `lib/` or `server/` can be asked whether they are right.
- **Nothing here derives what a *screen* renders, and that is a different
  question from what a *route* returns** *(task 11.181, 2026-09-06)*. §4.2's
  derivation reads the server's route declarations, so a change to what the app
  shows a non-owner is invisible to it — which is exactly what happened on
  2026-09-06, when a viewer went from being refused a tag's details page to
  reading it. **The rule is now written down**: reading inside a project is not
  on the role gradient (`TriTrack_Security_Model.md` §4.21.4). **The population
  was measured before anything was built** — 13 of the 64 widget-tree files under
  `lib/features/` and `lib/widgets/` branch on a permission, 9 of them screens,
  and only 3 change what is *rendered* rather than what is *offered*. Small
  enough that the honest instrument is a written verdict per file, kept from
  rotting by a derivation:
  `test/documentation/screen_permission_branches_test.dart`. **Its limit is
  stated there and is worth knowing here: it notices a file joining or leaving
  the class, not a screen already on the list changing what it shows a viewer.**

**So the marker is about this document's text, not about whether the rule is
enforced.** §4.0's cross-cutting rule is enforced on every table by
`server/test/authz/permissions_matrix_test.dart` and its wording here is still
hand-kept, because that test never opens this file.

---

## 1. How to read the tables

***Hand-kept*** — notation, not claims about code.

### The people

***Hand-kept*** — notation.

Five columns, and the fifth is the one that matters more than it looks.

| Column | Who this is |
| --- | --- |
| **Stranger** | Not a member of this project. May be a member of others, may hold no account at all. |
| **Viewer** | A member who may read the project and change nothing in it. |
| **Contributor** | A member who may record field data and correct their own. |
| **Owner** | A member who may do everything, including manage people and roles. |
| **Unknown** | **A device that has no membership record yet** — a fresh install, or a replacement phone restoring last season's archive. |

The **Unknown** column exists because "refuse unless you are a contributor or an
owner" is a rule that reads as obviously correct and breaks the single most
important use of the backup feature. A phone that has just been wiped has no
membership records to check, and it must still be able to restore. Task 11.20
existed entirely because of this column. Any rule that forgets it is wrong.

### The answers

***Hand-kept*** — notation.

| Mark | Meaning |
| --- | --- |
| **yes** | Allowed. |
| **own** | Allowed only for records this person created. |
| **new** | Allowed, but only by creating a superseding record. The original survives; see §5. |
| **no** | Refused. |
| **n/a** | Cannot arise. **A reason is required in the notes column — never leave this bare.** |
| **?** | **Nobody has decided this, or nobody has checked.** See §8. |

**No cell may be empty.** An empty cell reads as "safe" and means "not asked",
and every one of the last four findings on this project lived in exactly that
gap. `n/a` with a stated reason and `?` are both complete answers. Blank is not.

### Which layer a mark is speaking for — read this before the tables

***Hand-kept*** — notation.

The first four columns state the **enforced** answer, which is the server's
(§2). Where the screen or the device answers differently, the enforcement ticks
and the notes say so.

**The Unknown column states the *device's* answer**, because that is the whole
reason the column exists: it is checking that a wiped phone still works. The
server's answer for the same caller is given in the notes. Almost every Unknown
cell has one shape, and it is worth stating once rather than forty times:

> A device that cannot resolve a role **permits**, deliberately, and defers to
> the server — `base_repository.dart:178` (`assertRoleMayWrite`, "when the
> device has been told a rung, honour it; when it has not, defer to the
> server"), `project_roles.dart:94` (`resolveProjectRole` returns null),
> `untrusted_import.dart:155` (`receiverMayImport` permits on null). A device
> holding a project it has no membership row for is the ordinary case for a
> project created offline, imported from a colleague, or restored from a
> backup. **On the device, Stranger and Unknown are therefore the same cell,
> and both are permissive.** §4.23, §5.10.

### A capability that has been *retired* is marked differently again *(convention set 2026-09-07)*

***Hand-kept*** — notation.

**Removed** and **retired** are not the same thing and the difference matters to a reader deciding
whether a rule still has work to do.

- **Removed** — the code is gone and no row can exist. Struck through, dated with the commit, kept.
  See the section below.
- **Retired** — **the control that created rows is gone; the rows, the table and the server-side
  permissions all remain and still govern what exists.** Marked *capability RETIRED &lt;date&gt;* with
  the task, **and the surviving half is described** rather than struck through, because it is still
  enforced.

**S1, the triangulation session, is the first of these** (task 11.197). **The failure to avoid is a
reader concluding from silence that the capability is still exercisable** — which is why the row says
what a person can no longer do *and* what the server still enforces.

### A capability that has been removed keeps its row *(convention set 2026-09-07)*

***Hand-kept*** — notation.

**A row for a capability the app no longer has is struck through, marked `capability removed
<date>` with the commit that removed it, and kept.** It is never deleted.

**Why, since task 11.179 asked and there was no precedent to copy.** These tables are read
alongside `TriTrack_Security_Model.md`, which argues about capabilities *that were considered and
rejected* as well as ones that exist — §4.15 and §4.15.1 are three pages of reasoning about a
cloud backup that no longer ships. **Delete the row and those arguments point at nothing**, and the
next reader cannot tell "this was decided against" from "nobody thought about it." The second is
the more dangerous reading, because it invites somebody to build it.

**The marking is the load-bearing part, not the row.** A removed capability written in the present
tense is worse than either — the two cloud-backup rows read as live for **eight days** after the
commit that deleted the feature, and nothing noticed.

### The citation column

***Hand-kept*** — notation. **The citations themselves are not checked**: a `path.dart:NN` here can point at a line that has since moved, and nothing says so.

Every filled cell carries the code symbol that implements it and the
security-model section that reasons about it. Without that, this document is a
hand-maintained copy of what the code already knows, which goes stale silently —
one added table left a wrong count in six document sections and two gate
instruments inside a single week. A stale permissions matrix is worse than no
matrix, because it is the document you would reason from.

**The structural fix, done by task 11.25 (2026-08-22):** the cross-cutting rule
in §4.0 and the shared-tables' cross-author direction (§8, entry 9) are now
cases in `server/test/authz/permissions_matrix_test.dart`, checked against
`tableMutationRules` in both directions rather than maintained by hand, with a
demonstrated failure — deleting a table's case, or declaring one for a table
the code does not have, turns the "structural completeness" group red and
names the table. The forty-odd named operation cells in §4 and §7 continue to
be pinned by the per-feature tests each row already cites (`authorization_test.dart`,
`member_authorization_test.dart`, `mutation_authorization_test.dart`,
`role_gradient_test.dart` and the others named per row); rewriting those as one
new fixture would be a second copy of tests that already pass, not a fix.

---

## 2. Where each rule is enforced

***Hand-kept*** — the *structural* claims underneath it (every synced table has a mutation rule; every table's audit column names the caller) are derived by `server/test/authz/permissions_matrix_test.dart`, but that test never opens this file, so these words and that code can still disagree.

Three separate questions, and the difference between them is the single thing
that has been rediscovered most often on this project:

| Layer | What it means | What it is worth |
| --- | --- | --- |
| **Screen** | The button is absent or disabled. | Courtesy. Stops honest mistakes, stops nothing else. |
| **Device** | The write is refused on the phone before the record is stored. | Keeps the user's own device honest and truthful. Bypassable by someone editing their own database file. |
| **Server** | The row is refused when it syncs. | **The enforcement.** The only layer an adversary cannot go around. |

**State this once and stop rediscovering it:** the app's permission checks are
advisory; the server is the enforcement. A contributor who edits their own
device's database file directly can change anything locally, and their changes
are refused on the next sync. That is true of every permission in this app, not
of any one feature. (§4.23.)

**And state its corollary just as loudly, because it is the one that produces
findings:** a device-layer check with **no server twin** is not advisory — it is
the only check there is, and it is bypassable. §4.23's own point 2 says so in
those words. Task 11.23's sweep found two live instances — **removing a tag from
a project** (§7, T3) and **the owner-only half of an exclusion mark**'s sibling
paths — and **both have been closed since task 11.24 (2026-08-22)**: T3 is
refused at the server by `RowAuthorizer._authorizeTagLifecycle`, which holds
*any* change to a stored `Tags` or `Tag_Versions` row — including a tombstone,
which is what removing a tag from a project is since task 11.219 — to the owner
rung. *(This paragraph said T3 was live until task 11.254, 2026-09-15, twenty-four
days after §7's own T3 row recorded it closed; the sentence was written by the sweep
and never re-read. The refusal is now measured on every server run by
`permissions_matrix_test.dart`'s "shared tables" group, which expects a contributor's
alter and tombstone of a `Tags` row to answer `unauthorized` — and was watched
answering `updated` when that rung was deliberately reopened.)* **A third instance
was named by task 11.246, 2026-09-15, while writing §4.7: merging two animals**
(§4.7, IN4). **Task 11.254 measured it and found it is not this shape** — the
server has no twin because the *product* has no rung: every write a merge makes,
and the merge's exact end state, is reachable by a contributor through the app's
own controls. **Closed by task 11.255, 2026-09-15**: Michael's choice made the
tombstone itself owner-only, which took away the reachable end state 11.254
measured and gave the merge a server twin as a consequence. §4.7's IN4 row and
§8 entry 13 carry the finding.

The tables in §4 carry three tick columns for these:

- **✓** — a real check exists at this layer.
- **—** — no check at this layer.
- **n/a** — this layer cannot apply (there is no screen; the row never syncs).

Its purpose is to make a missing layer **visible** — tasks 11.14, 11.19 and
11.20 each found an operation with a screen gate and no device check, or with
neither, and this sweep found a third shape: a device check with no server one.

---

## 3. The operation inventory

***Hand-kept*** — a list of capabilities, with no single code-side enumeration to diff it against.

**Written before reading the code, deliberately.** This is an independent list,
so comparing it against what the app actually exposes finds two useful things:
operations that exist and are not on this list, and operations on this list that
do not exist. If the list were derived from the code it could only ever agree
with the code.

Identifiers are for cross-referencing between tables and scenarios only. They
always appear with their plain-English name, never alone.

### Projects

***Hand-kept***.

- **P1 — create a project**
- **P2 — rename a project or edit its description**
- **P3 — set or change the project's study area**
- **P4 — hand ownership to somebody else**
- **P5 — archive or retire a project**
- **P6 — delete a project from this device**
- **P7 — start next season from a project** *(added by the planning session 2026-09-16, on task
  11.56's request; that task did not write it because §3 and §4.1 are both **hand-kept**)*
- **P8 — delete permanently, from this phone, a project in the Trash that this phone does not sync**
  *(task 11.339, 2026-10-10)*

### People and roles

***Hand-kept***.

- **M1 — see who is on the project**
- **M2 — switch joining on, and hold the project's join code**
- **M3 — give the join code to somebody** (outside the app: email, text,
  whiteboard)
- **M4 — ask to join with the code**
- **M5 — approve or reject somebody who has asked**

> **M2–M5 were rewritten by task 11.81 on 2026-08-31 and previously read
> "create an invitation", "send an invitation", "redeem an invitation and join",
> and "cancel an invitation that has not been used".** Per-address invitations
> are gone. **The change is not a rename**, and the matrix would be misleading
> if it were read as one: under the old operations, **M4 was the grant** —
> redeeming made you a member. Under the new ones **M4 grants nothing**; it puts
> a row in front of an owner, and **M5 is the grant**. Anybody holding the code
> may perform M4; only an owner may perform M5.
>
> A sixth membership operation arrived with it and is listed as **M10** below.
>
> **It was numbered M9 until task 11.84, and so was something else.** The
> device-sessions row in §4.2 had held M9 since task 11.35, so a citation of
> "row M9" pointed at two unrelated operations. The derivation in
> `test/documentation/permissions_matrix_membership_test.dart` found it on its
> first run; re-admission moved to M10 and the sessions row kept M9, which is
> the number the development plan already cites for it.
- **M6 — change somebody's role**
- **M7 — remove somebody from the project**
- **M8 — leave a project yourself**
- **M10 — put a past member back on the project** (task 11.81). The one
  membership grant an owner may make without the other person acting, and it is
  bounded by the project's own history: the server refuses anybody who does not
  already hold a **closed** membership row here and no open one, so it can only
  reverse a removal the owner themselves made.

### Field records — bearings and observations

***Hand-kept***.

- **O1 — record a new bearing**
- **O2 — correct your own bearing, before anyone else has seen it**
- **O3 — correct your own bearing, after it has synced**
- **O4 — correct a teammate's bearing**
- **O5 — exclude a bearing you recorded from the analysis**
- **O6 — exclude a teammate's bearing from the analysis**
- **O7 — undo an exclusion**
- **O8 — see that a record was excluded, and by whom**
- **O9 — remove a bearing permanently**

### Triangulation

***Hand-kept***.

- **S1 — create a triangulation session**
- **S2 — add or remove bearings from a session**
- **S3 — run or re-run the position estimate**
- **S4 — change a session's parameters**
- **S5 — delete a session**

### Tags

***Hand-kept***.

- **T1 — create a tag**
- **T2 — copy a tag into this project**
- **T3 — remove a tag from this project**
- **T4 — edit a tag's name, frequency or color**
- **T5 — retire a tag**
- **T6 — merge two tags that turn out to be the same animal**
- ~~**T7 — adopt a tag no project currently uses**~~ — **removed 2026-09-10,
  task 11.219.** There is no such tag: `Tags` is project-scoped, so a tag
  cannot exist outside a project.
- **T8 — record what a tag read when a bearing was taken** (task 11.32)

### Data coming in

***Hand-kept***.

- **I1 — paste a shared observation somebody sent you**
- **I2 — save that pasted observation into a project**
- **I3 — import a project file somebody sent you**
- **I4 — restore your own backup**
- **I5 — import a spreadsheet of tags or records**
- **I6 — receive teammates' records through sync**
- **I7 — accept an identity the server assigns you**

### Data going out

***Hand-kept***.

- **X1 — copy a single observation to send to somebody**
- **X2 — export the project as a file**
- **X3 — export a spreadsheet**
- **X4 — back up to the server**
- **X5 — back up to your own cloud storage**

### Operations

***Hand-kept***.

- **D1 — the diagnostics console's project routes**

---

## 3.1 What the hand-written inventory got wrong, in both directions

***Hand-kept*** — a record of one sweep on one day, not a live claim.

**This is the payoff for having written §3 blind.** The list above was drawn up
without reading the code; the app was then enumerated from the code three ways
(every mutating repository method, every server route, every user-facing control)
and the two lists diffed. Both directions are reported, because both are
informative — but the first is the valuable one.

### (a) Operations the app has that nobody wrote down

***Hand-kept***.

Each of these is a real write that a person can perform and that no row of §3
covers, which means until now no one had asked who may do it.

| Missing operation | Where it lives | Who may do it | Why it matters |
| --- | --- | --- | --- |
| **Record a non-detection** — "I listened here, at this time, and heard nothing" | `non_detection_repository.dart:14` (`insert`), `:45` (`update`); rendered `log_screen.dart` (`_NonDetectionTile`) | Contributor and owner, own only — `MutationRule.author` (`mutation_rules.dart:298`) | **This is a whole field-record type the matrix's O-group does not mention.** Negative evidence is scientific evidence, and it carries an author, so it inherits every question O1–O9 asks — including N-1's. See §10. |
| **Delete a non-detection ("no signal" record)** | `non_detection_repository.dart` (`softDelete`/`restore`, mirroring O9's shape); rendered `log_screen.dart` (`_NonDetectionTile`'s ⋮ menu, `deleteNonDetection`) | Contributor and owner, own only — same `MutationRule.author` rule as the row above, so this inherits its answer rather than being a new question | **Added by task 11.252, 2026-09-15.** Until this task the row above existed and this one did not — the record could be made and never taken back, which is how Michael found it. No prose anywhere argued this was a deliberate "evidence of absence" protection; it was an oversight in the row above, not a decision, and is treated as N-1's peer now that it exists. |
| **Record a truth point (where the animal or collar actually was)** | `actual_tag_location_repository.dart` — reachable from the record screen's **Truth** tab (task 11.33), and correctable from the map panel and the Log (task 11.92) | Any member with write rights — `MutationRule.anyUser`. **`user_id` records who found it (task 11.93) and is a fact about the record, not a permission**: any contributor may correct or delete a truth point, which is Michael's decision of 2026-08-31 and rests on the lion case — the person who saw the pride and the person driving may not be the same | **CORRECTED 2026-08-31.** This row said *"there is no way to create one"*, which was true until task 11.33 and has been false since. **The guide's roles table is filled from this document, so a stale row here becomes a stale sentence on a public page** — which is how it was found, by the content lane rather than by anything here. Task 11.84 re-derives this whole matrix from the code; this row is corrected now rather than left standing until it runs |
| **Record a note, and record an omnidirectional detection** | `observation_logging_screen.dart:554`, `:546`; `enums.dart:100`, `:118` | as O1 | Two more record types sharing O1's table and rule. Not separate permission questions, but the O-group names only "a bearing". |
| **Set a manual magnetic declination override** | `declination_control.dart:109` (set), `:98` (adjust), `:76` (reset) | Anyone using the device, no role consulted | Not a database write, but it changes the true-north bearing stamped on **every subsequent observation** (`observation_logging_screen.dart:565`). A field-record input with no author trail of its own. |
| **Sign out everywhere / revoke a lost device's sessions / list your own devices** | `auth_routes.dart` — the two revocation routes, plus `GET /auth/sessions` added by task 11.35 | The person themselves | Correct as written when 11.23 wrote it; **partly overtaken since, and recorded here rather than left to read as current.** Sign-out-everywhere gained its caller in task 11.28. The listing route was new in 11.35 and gained its caller in **task 11.36 (2026-08-29)**, which also put per-device revocation on the Server Connection screen — so all three are now reachable from the app. See M9 and §8 item 11. |
| **Manage offline map tiles and elevation data** | `manage_offline_maps_screen.dart:121`, `:176`, `:141`; `offline_data_map_screen.dart:453` | Anyone using the device | Cache management, not project data — listed so the sweep is complete. |
| **Switch the active project** | `projects_screen.dart:142` | Anyone using the device | Decides which project every other row in this table is evaluated against. |
| **Undo** — a deleted project, observation, estimate, or tag removal | `projects_screen.dart:229`; `log_screen.dart:396`; `position_estimation_screen.dart:1049`; `project_setup_screen.dart:1034` | Whoever could do the delete | Each is a real write (clearing a tombstone, or reactivating a link) and each inherits its counterpart's rule. |
| **Save a position estimate** (as distinct from running one) | `estimated_position_repository.dart` `insert`/`softDelete`/`restore`; `position_estimation_screen.dart:165` (`_save`), `:1033` (delete) | Any member with write rights; **not** author-restricted | S3 in §3 conflates computing an estimate (unrestricted, no write) with saving one (a write). They are different operations with different answers. |
| **Delete a saved position estimate** | `position_estimation_screen.dart:1033`, `:1049` (undo) | Any member with write rights, **on anyone's estimate** | Subtractive and shared, yet contributor-level. See §8. |
| **Edit your own profile — name and email** | `profile_editor.dart:22` (`ProfileEditor.apply`) | Yourself only (`Users` is `MutationRule.author`); a viewer may still do it | The one write a viewer legitimately makes. It is why a viewer's push is refused per row rather than with a blanket refusal (§4.21). |
| **Publish a local project to the server for the first time** | `project_publisher.dart`; server seam `sync_routes.dart:539-576` | Anyone, for a project id the server does not already hold; the publisher becomes its owner | A distinct grant, not covered by P1 or X4. The server substitutes owner access for the duration of the push. |
| **Join a project on a second device** | `project_joiner.dart`; `membership_provider.dart` (`joinApprovedProject`) | Whoever the owner approved | M5 covers the grant; the local download that follows is a second step and can fail on its own. |
| **Link, unlink and configure a cloud backup folder** | **capability removed 2026-08-29** (`3a9a2c8` deleted `cloud_backup_service.dart` and `auto_backup_section.dart`); row kept as the record of what was decided | Anyone using the device, no role consulted | A recurring, unattended export of the whole project. §4.15, §5.7, and task 10.85's finding that the linked folder is also a *write* surface. |
| **Retry or discard a record the server refused** | `sync_status_screen.dart:256` (`_HeldRowsSection`), `:295` (`_HeldRowTile`) | Anyone using the device | The user-facing half of every refusal in this document. |
| **Review and dismiss a sync conflict** | `sync_status_screen.dart:90-103` (`_ConflictTile`) | Anyone using the device | The only place a person is told they lost a merge (§6). |
| **Promote a value stored by a newer version of the app** | `unknown_columns.dart` (`UnknownColumnStore.promote`) | Runs on database open, no person involved | Task 10.76 exists because this can leave the database unopenable. Not a permission question, but it is a write nobody listed. |
| **Configure the server connection / pair a device** | `server_config_provider.dart`, `sync_provider.dart` | Anyone using the device | Decides which server every other row in this table is enforced by. |
| **Adopt the identity the server hands back at sign-in** | `server_identity_adopter.dart:151` | The signing-in person | §3 does list this as I7 — noted here only because it is a *write path*, and a destructive one (it deletes local `Users` rows), which the phrase "accept an identity" understates. |

### (b) Operations on the list that do not exist in the code

***Hand-kept***.

| Listed | Verdict | What I searched |
| --- | --- | --- |
| **P5 — archive or retire a project** | **Does not exist.** There is no archived/retired/inactive state for a project. | `Projects` DDL (`schema.dart:61-77`) and every migration: no `status`, `is_active`, `archived_at`, `end_date`. No repository method, no control. `archive`/`retire`/`inactive` across `lib/`, `server/lib/`, `packages/*/lib/` hit only tags and backup `.zip` archives. The only project-level lifecycle transition that exists is P6's tombstone. |
| **S2 — add or remove bearings from a session** | **Does not exist as an operation.** A bearing's session is a column set once when the bearing is recorded (`Observations.session_id`, `schema.dart:133`, written at `observation_logging_screen.dart:605`) and never changed by any code path. Nothing removes one. | Every `Observations` update call site; the only one (`observation_edit_dialog.dart:118`) touches notes, signal strength and bearing quality only. |
| **S4 — change a session's parameters** | **Does not exist in the app.** `TriangulationSessionRepository.update` exists (`triangulation_session_repository.dart:43`) with **zero call sites**, and no screen renders a session's label or notes. | Grep across `lib/` and `test/`. |
| **S5 — delete a session** | **Does not exist.** The repository has no delete or soft-delete method at all, and no screen offers one. | `triangulation_session_repository.dart` exposes `insert`, `findById`, `findByProject`, `update` and nothing else. |
| **T5 — retire a tag** | **Exists, but not as its own operation.** There is no `retired` tag state; retiring is an ordinary change to the tag's `status`, so it is T4 wearing a different name. | `TagStatus` = `active`/`recovered`/`lost`/`malfunction` (`enums.dart:20-31`). `Tag.dateRemoved` exists but no control ever sets it. |
| **T6 — merge two tags** | **Does not exist.** Deferred to Phase 12, and the code says so in both places it would live. | `tag_repository.dart:29-31`, `near_duplicate_tags.dart:11-13`. |
| **M3 — give the join code to somebody** | **Correctly listed as outside the app, and the app is consistent with that.** No code sends anything: the join code is displayed to the owner and copied to the clipboard. Delivery is a human act over a channel TriTrack does not control. | No join-code path in `server/lib/src/auth/email_sender.dart`. |
| **M8 — leave a project yourself** | **Now exists — task 11.28, 2026-08-23.** Michael decided on 2026-08-22 that a viewer or a contributor may leave and that no owner confirmation is required. Was: *"Does not exist, and a contributor who tries anyway is refused at both layers with an unhandled error. The most consequential entry in this table."* | `ProjectMembershipRepository.leaveProject`; the shared `isSelfDeparture` predicate; `RowAuthorizer.authorizeWrite`'s two exception points; the Leave control on `projects_screen.dart`. Still no membership *route* on the server — a departure travels as an ordinary synced row, like a role change. |

### (c) Operations on the list that exist, but are a different shape than named

***Hand-kept***.

- **I3 (import a project file) and I4 (restore your own backup) are one code
  path, not two.** `ProjectMerger` treats both as `MergeOrigin.untrustedArchive`
  and says so outright (`project_merger.dart:37-53`): *"Choosing a file says
  where the bytes came from, not who wrote them."* Nothing in the code
  distinguishes your own backup from a stranger's file, and that is deliberate.
  **Anywhere this document says I4 it also means I3.**
- **I5 (import a spreadsheet of tags *or records*) overstates what ships.** Only
  `Tags` and `Project_Tags` can be written from a spreadsheet
  (`tag_csv_commit.dart:35-66`). There is no observation or non-detection CSV
  importer — `observation_csv.dart` and `non_detection_csv.dart` are export-only
  formatters.
- **S3 (run or re-run the position estimate) is two operations.** Computing is
  unrestricted and writes nothing; *saving* is a write, and re-running never
  updates an existing saved estimate — every save mints a new row
  (`position_estimation_screen.dart:149`).
- **P6 (delete a project *from this device*) is not device-local.** It is a
  tombstone that syncs to every other member (§4.1). **P8 is device-local**, and
  is offered only where nothing syncs (task 11.339).
- **P4 (hand ownership to somebody else) is not one verb.** It is promote-then-
  step-down, two membership writes, and the dedicated `grantOwner` helper
  (`project_membership_repository.dart:432`) has no call site in the app at all —
  only tests reach it. What ships is the plain role dropdown.
- **O2 and O3 (correct your own bearing, before and after syncing) are one
  operation.** There is no pre-sync/post-sync distinction anywhere in the code;
  `MutationRule.author` applies identically. What differs is only whether the
  edit later loses a merge and produces a conflict record.
- **O4 (correct a teammate's bearing) does not exist as an edit and cannot.**
  The operation that serves that need is supersede, which writes a *new* record
  and a mark and never touches the original.
- **O5 and O6 are not the split the code makes.** The code splits on the **kind
  of mark** — supersede versus exclude — not on whose bearing it is. Your own
  bearing and a teammate's are treated identically. That is why O5 comes out
  "no" for a contributor, which reads as surprising until you see the axis.
- ~~**T2 (add a tag) and undoing T3 (remove a tag) are literally the same
  call.** A link is never duplicated, only deactivated and reactivated.~~
  **No longer true, task 11.219:** adding is a *copy* (a new row) and undoing
  a removal is clearing a tombstone on the row that is already there. They
  are different calls with different rungs — adding is contributor-level,
  ~~and so is putting one back,~~ while removing is owner-only.

  > **Corrected 2026-09-10 (measured by task 11.220), and then decided.** The
  > struck clause was written from `TagRepository.restoreToProject`'s doc
  > comment, which still records task 11.12's *"additive and unblocking,
  > contributor-level"* reasoning. **The server stopped agreeing on the day
  > 11.219 landed**, and nobody noticed because the two layers were not compared:
  > `RowAuthorizer._authorizeTagLifecycle` lets a contributor **create** a tag
  > and reserves every **change** to an existing one for an owner, and clearing
  > a tombstone is a change. Measured at both layers — `authorization_test.dart`
  > (*"and a contributor may NOT put it back"*) and over HTTP in
  > `verify_11_24_attribution.py`.
  >
  > **The asymmetry moved from *add versus remove* to *create versus change*,
  > and that was a side effect rather than a decision.** Michael took the
  > decision on 2026-09-10: **owner-only stands.** The rule a person can hold in
  > their head is *contributors add new collars; owners change existing ones*,
  > and a contributor who needs a removed collar back can create a new record
  > for it — `NearDuplicateTags` will tell them it looks like one they already
  > have.
  >
  > **The device did not get the message for one day, and task 11.221 closed
  > it (2026-09-10).** Project Setup showed an **"Add back"** button on a
  > removed tag, enabled for any contributor, and `restoreToProject` ran no
  > `assertMayEdit` — so the button worked on the phone and the push was
  > refused. **An app that offers what the server refuses is the shape task
  > 11.218 closed for a different operation**, and it was open again here.
  > Now `restoreToProject` asserts, the button is gated on the owner rung, and
  > the section's one sentence says why — measured by a repository test and a
  > widget test, both watched red first.
- ~~**T7 (adopt an unused tag) is a permission, not a button.**~~ **Removed
  with T7, task 11.219** — see the struck row above.
- **I2 (save a pasted observation) has three outcomes and two refusal modes**,
  none of which the one-line inventory entry can hold: a current-format payload
  becomes a faithful replica under the sender's own identifier, an older one
  becomes a copy owned by the receiver, and one that would destroy values you
  hold writes **nothing** and comes back asking for consent.
- **X4 (back up to the server) is not a backup feature.** There is no
  server-backup route and no client call for one; what the inventory means is
  ordinary sync. The server's own backups are operator shell scripts with their
  own encryption and retention, outside every user-facing surface.
- **M1 (see who is on the project) is owner-gated at the entry point** — the
  Members button renders only for an owner, even though the list itself is data
  every member already holds.

---

## 3.2 Every synced table, and which section documents it *(added by task 11.246, 2026-09-15)*

***Derived*** — `test/documentation/permissions_matrix_table_coverage_test.dart` reads
`Tables.all` (`packages/tritrack_sync/lib/src/schema_constants.dart`) and diffs it against
this list in both directions: a table `Tables.all` has and this list does not name fails,
naming the table and what to write; a row here naming a table `Tables.all` does not have
fails as stale.

**Why this exists.** §3.1 is written before reading the code, deliberately, so it can never
notice a table arriving with nobody having decided who governs it — that is exactly what
happened to `Deployments` and `Individuals`, live for weeks with no §4 row (see §4.7). A
list keyed on *tables* rather than on *hand-invented operation names* is the one shape that
cannot silently agree with a codebase that grew a table nobody wrote a sentence about,
because it is diffed against the table list itself rather than against anyone's memory of
it.

**What this does not check.** That the section named is *correct* — only that one exists.
Whether §4.7's rung for `Deployments` is the right rung is Michael's and the planning
session's question, argued in §4.7 itself, not this table's.

| Table | Documented in | Notes |
| --- | --- | --- |
| `Users` | §3.1(a) ("Edit your own profile") | No project-level operation table of its own — a `Users` row is a person, not a project's data. The only self-service write is the profile editor; account creation happens at sign-in (§4.20), not through a project operation. |
| `User_Emails` | §8 (entry 5's cross-reference), §10 | Address history, written only alongside `Users` at sign-in and email change; no control writes it on its own. |
| `Projects` | §4.1 | |
| `Project_Memberships` | §4.2 | |
| `Individuals` | §4.7 | **Had no section from task 11.240 (2026-09-13) until this task (2026-09-15).** |
| `Tags` | §4.5 / §7 | |
| `Deployments` | §4.7 | **Had no section from task 11.243 (2026-09-13) until this task (2026-09-15) — the finding that opened this task.** |
| `Tag_Versions` | §4.5 / §7 (T8) | |
| `Triangulation_Sessions` | §4.4 | |
| `Observations` | §4.3 | |
| `Observation_Exclusions` | §4.3 (O5–O7) | |
| `Non_Detections` | §3.1(a) ("Record a non-detection", "Delete a non-detection") | |
| `Estimated_Positions` | §3.1(a) ("Save a position estimate", "Delete a saved position estimate") | |
| `Actual_Tag_Locations` | §3.1(a) ("Record a truth point") | |

**`Project_Tags` is deliberately not on this list.** It left `Tables.all` with the wire in
task 11.219 — adding a tag to a project now copies it, so there is no link row left for the
server to govern — and stays only as an unused local SQLite table so an archive written
before v14 still opens. It is not a synced table any more, so it is not this list's business;
§3.1(c) records what happened to it.

---

## 4. Who may do what

***Hand-kept*** — except §4.2. Each subsection below says which it is.

Six tables, one per group above, all sharing the same five columns plus the
three enforcement ticks and a citation. Split by group because a single
forty-row table is not readable, and readability is this document's entire
purpose.

Re-read §1's "which layer a mark is speaking for" before using these.

### 4.0 Rules that apply to every row *(added 2026-08-22)*

***Hand-kept*** — **the rule is enforced, these words are not checked.** `server/test/authz/permissions_matrix_test.dart` asserts 4.0.1 on every table `tableMutationRules` declares; it does not read this paragraph.

**This section exists because task 11.24 found a rule with nowhere to live.** Some
rules are not squares in the grid — they are properties of the whole grid, like *"the
column recording who last touched a row must always name the caller."* That applies
to every row of every table. Written as a cell it disappears; written here it can be
re-checked.

**A cross-cutting rule with no home is a rule nobody re-checks**, which is how the
naming exemption behind finding N-1 survived from a one-person app into a team one
without anybody noticing its meaning had changed.

Task 11.25 asserts each of these **once per table**, not once.

**Filled by task 11.25 (2026-08-22).** Task 11.24 changed three rules underneath
this document, and only one of them has this section's shape — the other two are
ordinary cells, already in their tables (`Project_Tags`' T3 row in §7, and the
exclusion-kind note under §4.3's O6/O7 rows), and are not repeated here.

| Rule | What it means for a person | Where enforced | Source |
| --- | --- | --- | --- |
| **An update must name the caller in the column recording who last touched the row.** Leaving a stored row's `last_modified_by` unchanged — or setting it to anyone but yourself — is refused, on **every** synced table, whenever the update changes anything else about the row. | You cannot make a change and leave it looking like somebody else made it, and you cannot "fix" a colleague's row while leaving their name on the edit. This is what closes task 11.18's "…then withdrawn by *name*" sentence at its root: the name in that sentence is now guaranteed to be the person who actually acted. | Server, all three layers exist but this is the one an adversary cannot go around — **Device**: the app never constructs a push with a stale audit column; **Server**: `RowAuthorizer._authorizeNaming`'s `auditUserColumn` branch, checked before the mutation-rule permission itself, so it fires whichever rule ([MutationRule.author], `.owner`, `.projectOwner`, `.anyUser` or `.authorOrOwner`) governs the table | `row_authorizer.dart` (`_authorizeNaming`, the `column == auditUserColumn` branch); `sync_tables.dart` (`auditUserColumn`, present in every table's `userColumns`); task 11.24, Security Model §19.2. Asserted once per table — all thirteen — by `server/test/authz/permissions_matrix_test.dart`'s "cross-cutting rule 4.0.1" group, which also proves the completeness guard fires by removing a table's case and watching it name that table. |

### 4.1 Projects

***Hand-kept*** — project lifecycle is partly sync-path and partly route-shaped, and no single enumeration covers it.

| # | Operation | Stranger | Viewer | Contributor | Owner | Unknown | Screen | Device | Server | Source | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| P1 | Create a project | yes | yes | yes | yes | yes | — | — | ✓ | `projects_screen.dart:135`; `project_repository.dart:14`; `row_authorizer.dart:679` (`_authorizeGrantingInsert`, `Projects` case); §4.21.1 | The five columns describe a relationship to an *existing* project, so for creation they collapse: a viewer of one project may create another and owns it. The server's only condition is that the id is not already taken and that the row names the caller as owner. **Task 11.24: publishing is a separate act with a separate answer, and the app's owner-only gate on it is not enforceable.** A contributor holding a copy of somebody else's unpublished project can publish it first and become its sole server-side owner; the genuine owner is then refused their own project id, permanently. Reproduced live. The server has no evidence that could tell the two apart — every row of a first publish is self-asserted — so this is an accepted risk, not a missing check. Security Model §19.4. |
| P2 | Rename a project / edit its description | no | no | no | yes | yes **only if** this device's user is the recorded creator | ✓ | ✓ | ✓ | `project_setup_screen.dart:195`, `:205`, `:340`; `base_repository.dart:267` (`_authorize`) under `MutationRule.owner`; `row_authorizer.dart:485` (`permittedByOwners`); §4.21 | The Unknown case is the creator fallback in `project_owners.dart:55` — a project whose membership table names no open owner resolves to `Projects.owner_user_id`, so a restored phone can still edit a project it created. The Edit *screen* opens for anybody; the gating is inside the form. |
| P3 | Set or change the study area | no | no | no | yes | as P2 | ✓ | ✓ | ✓ | `project_setup_screen.dart:253`, `:264`; same `Projects` row and same rule as P2 | The study area is four columns of the same `Projects` row (`schema.dart:68-71`), so enforcement is P2's, identically. The extent picker has exactly one call site and is not routable on its own. |
| P9 | **Set or change the project's time zone** (task 11.331) | no | no | no | yes | as P2 | ✓ | ✓ | ✓ | `project_setup_screen.dart` (the *Time zone* section and its *Change* button, owner-gated like every other setting there); same `Projects` row and same rule as P2 (`Projects.time_zone`, schema v20) | **P2's answer, for P2's reason**: the zone is one more column of the `Projects` row, so the device's `MutationRule.owner` and the server's `permittedByOwners` decide it identically. **What a change does, stated in the confirmation:** days already recorded stay the same days, because each deployment row keeps the zone it was written in (`Deployments.time_zone`) and **no existing row is rewritten** — which is what makes the change safe while other phones are offline holding older rows. New links and "today" use the new zone. The deployment rows themselves stay governed by the deployment rules (contributor and up); a contributor never sets a project's zone, only writes rows in it. |
| P4 | Hand ownership to somebody else | no | no | no | yes | as P2 | ✓ | ✓ | ✓ | `project_members_screen.dart:160` (role dropdown) → `project_membership_repository.dart:364`; guard `:499` (`_guardLastOwner`); `row_authorizer.dart:1191` (`_authorizeOwnerRemoval`) | Not one operation: promote somebody to owner, then end your own stint. **The last owner cannot leave the project with nobody in charge** — refused on the device (`LastOwnerRemoval`) and on the server (`lastOwnerRemoval`), covering all three ways ownership can lapse (ended, tombstoned, demoted). Rewriting the project's recorded creator is not a transfer path: the server refuses it as reattribution. |
| P5 | Archive or retire a project | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | — (nothing implements it) | **Cannot arise: there is no archived or retired state for a project to be put into.** No column, no model field, no repository method, no control. See §3.1(b). |
| P7 | **Start next season from a project** | yes | yes | yes | yes | yes | — | — | ✓ | `projects_screen.dart`'s ⋮ menu → the New season screen; `SeasonCloneDisposition`; the new project is an ordinary `Projects` insert under `_authorizeGrantingInsert` | **P1's answer, for P1's reason, and the five columns collapse the same way.** It **reads** what every member of the old project may already read, and **writes** only into a **new** project the person creates and owns — so nothing about their standing on the source can be widened by it. **A viewer may start next season from a project they may not edit**, and the result is a project they own outright; that is not a privilege escalation because the new project contains only what they could already see. **The old project is not modified at all** — no row of it is written, which is what makes the rung answerable without reference to the source's owner. Task 11.56, schema v18 (`Projects.lineage_id`, `copied_at`). **Task 11.255's rung is unaffected**: deleting an animal in either project is still owner-only, and the person owns the new one. |
| P8 | **Delete permanently, from this phone, a project in the Trash that this phone does not sync** (task 11.339) | **whoever moved it to the Trash** (a read-only copy's holder can) | **whoever moved it to the Trash** | **whoever moved it to the Trash** | **whoever moved it to the Trash** | **whoever moved it to the Trash** | ✓ | ✓ | n/a | The Projects screen's Trash, a row's ⋮ → *Delete permanently…* (`_deleteTrashedHerePermanently`); `ProjectTrash.deletePermanently` | **Device-local, and the only hard delete of project data in the app.** It removes the project and every row scoped to it (every `syncTables` entry with a project scope, children first) and this phone's own bookkeeping for it, in one transaction; the person's Tag Library and every other project are untouched. **The rule is not a role**: the device refuses unless the project row is tombstoned, its tombstone was written by the person asking (`last_modified_by`), and this phone does not sync it (not linked) — the same three facts that put the row in the Trash, asked again inside the write, so a stale screen cannot widen it. **No server rule, because nothing reaches a server**: an unlinked project is never pushed, so there is nothing to enforce and nothing to resurrect — the reason for "no hard deletes" (a hard delete resurrects on the next merge) does not reach it. A copy exported or shared as a file is not touched. **No countdown**, unlike M11: that countdown lets every member see the deletion coming and export, and nobody else holds this copy; the dialog says it cannot be undone and says to restore and export first. For a never-published project the dialog says in plain words that nothing of it is on a server (Michael, 2026-10-08). |
| P6 | Delete a project from this device | no | no | no | yes | as P2 | ✓ | ✓ | ✓ | `projects_screen.dart:117` (button), `:158` (`_deleteProject`); `base_repository.dart:457` (`softDeleteByKey`); server judges it as an ordinary `Projects` row under `MutationRule.owner` | **It is not device-local and the dialog does not say so.** It writes a tombstone that syncs, and every other member's copy disappears too. Reversible while the tombstone lives (24 months, `tombstone_retention.dart`), by the undo on the same screen. There is no operation that removes a project from one device only. **Task 11.339 (2026-10-10): the Trash shows a project this phone does not sync.** A project moved to the Trash that this phone does not sync — never published, or no longer synced here (left, or destroyed on the server) — used to be reachable only from the six-second UNDO; it is now a row in the Projects screen's Trash, listed when this person wrote the tombstone (`ProjectTrash.onThisDevice`), with *Restore* (this row's undo, same rule and same exemptions, `ProjectTrash.restore`) and *Delete permanently…* (P8). The menu item is still called *Move to Trash* (task 11.324). |

### 4.2 People and roles

***Derived*** — `test/documentation/permissions_matrix_membership_test.dart` parses this table and diffs it against every route `project_routes.dart` and `auth_routes.dart` declare, in both directions. **The Screen, Device and Unknown columns and every Notes cell are excepted: they are prose and no test reads them.**

**Derived rather than hand-kept, since task 11.84 (2026-09-01).**
`test/documentation/permissions_matrix_membership_test.dart` reads every route
`project_routes.dart` and `auth_routes.dart` declare, reads this table out of
this file, and fails if either knows something the other does not — a route with
no row, a row citing a route the server does not mount, or a row claiming
somebody may do a thing the server's `_requireOwner` refuses them. **That is why
the Source cells below now quote paths in the server's own spelling**,
placeholders included: a citation that does not match the code is one nobody can
follow and nothing can check.

**Five things it found on its first run, all in rows written by hand three
weeks earlier:** two different operations were both numbered M9; one of them was
filed between M5 and M6; re-admission cited a path (`<id>`) the server does not
use (`<projectId>`); and **two routes had no row at all** — the owner's read of
the pending-request list, and the requester's read of their own request. Both are
reads rather than grants, which is why writing the grid by hand missed them, and
neither is a security defect. **What is not derived is said plainly in that
file's header**: the Screen, Device and Unknown columns and every Notes cell are
prose, and no test reads them.

| # | Operation | Stranger | Viewer | Contributor | Owner | Unknown | Screen | Device | Server | Source | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| M1 | See who is on the project | no | yes | yes | yes | yes (whatever is already on the device) | partial ✓ | — | ✓ | `projects_screen.dart` (a project row's ⋮ → Members); `members_screen.dart` (the More menu's own Members tile for the open project, task 11.313); `project_members_screen.dart:64` (list renders for anyone who reaches the route); `membership_provider.dart:59`; `sync_routes.dart:653` (`permitsSync`); `project_routes.dart` (`GET /projects/mine`, the directory read that tells a device which projects it is on) | A stranger learns nothing: "no such project" and "not yours" are the same refusal (§4.13). **A past member is the one exception, added by task 11.60:** a pull from somebody whose stint has ended returns *their own closed membership row and nothing else*, so their device can say "you were removed" rather than "the server is refusing access". They see no other member. §4.27 and inventory entry 28. **Neither entry point is owner-gated** — this row's own line-102 citation predated task 11.99, which opened both the row's ⋮ item and the screen itself to any current member; task 11.313's second door is open the same way, on purpose ("widen nothing" — the brief's own words). The screen renders the member list to any caller who reaches the route, gating only the controls and the join-code and pending-request sections. That is a courtesy gap, not a disclosure one — the member list is synced data the viewer already holds. |
| M2 | Switch joining on, and hold the join code | no | no | no | yes | no | ✓ | — | ✓ | `project_members_screen.dart` (owner-only Join code section); `project_routes.dart` (`GET /projects/<projectId>/join-settings`, `POST /projects/<projectId>/join-settings`, `POST /projects/<projectId>/join-code/rotate`) → `_requireOwner`; `join_service.dart` (`updateSettings`, `rotateCode`) | **No device-layer check exists** — the provider sends straight to the server. Acceptable under §4.23 because the server is the boundary and there is no local write, but it is a membership operation with no client-side twin. **The absent settings row means joining is OFF**, which is what keeps every project created before task 11.81 closed; asserted by `join_service_test.dart`. The code is stored readably under the named exception at Security Model §4.2.1 and is returned to the **owner only**. |
| M3 | Give the join code to somebody | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | `project_members_screen.dart` (copy to clipboard); §5.1.1, §5.3 | **Cannot arise: the app never sends anything.** It shows an eight-character code and copies it to the clipboard; delivery is a human act over a channel TriTrack does not control. §5.3 records email as an accepted non-goal. Unlike an invite code this one is re-readable, so losing it does not force a rotation. |
| M4 | Ask to join with the code | yes | no ("already a member") | no | no | yes, if signed in | ✓ | — | ✓ | `join_project_screen.dart` (`JoinWithCodeCard`); `project_routes.dart` (`POST /projects/join-requests`, and `GET /projects/join-requests/mine`, which is how the requester's own device follows a request it has already made — task 11.83); `join_service.dart` (`request`) | **This grants nothing, and that is the whole of the change task 11.81 made.** It writes a row in `project_join_requests`, which is server-only and is *not* a membership row — deliberately, because five readers of `Project_Memberships` ask only "is the stint open", including `GET /projects/mine`, which would otherwise have shown a requester the project's name before anybody approved anything. The route takes **no project id**, so it cannot be used to ask whether a code works for project X. One caller-supplied string reaches it — the claimed name — bounded by the same `RowValidator.isWellFormedPersonName` a synced `Users` row's name carries. |
| M5 | Approve or reject somebody who has asked | no | no | no | yes | no | ✓ | — | ✓ | `project_members_screen.dart` (`_RequestTile`, gated by `showAdmissionSheet`); `project_routes.dart` (`GET /projects/<projectId>/join-requests`, the owner's listing read, then `POST /projects/<projectId>/join-requests/<requestId>/approve` and `POST /projects/<projectId>/join-requests/<requestId>/reject`) → `_requireOwner`; `join_service.dart` (`approve`, `reject`) | **This is the grant.** The requester never writes their own membership row: the server authors it (`insertServerAuthoredRow`), taking the project from the request, the person from the request, and **the role from what the owner chose at that moment**. Nothing in any request body shapes it, which is why a leaked code cannot be an *owner* code and why approval needs no permissive branch in `RowAuthorizer`. **One at a time — there is deliberately no bulk reject** (design §2.5). The removal disclosure gates this action. |
| M6 | Change somebody's role | no | no | no | yes | permits (project absent locally) | ✓ | ✓ | ✓ | `project_members_screen.dart:160`; `project_membership_repository.dart:369` (`_guardLastOwner`); `row_authorizer.dart:1191` | Travels as an ordinary synced row, not a dedicated route. The last owner cannot demote themselves. |
| M7 | Remove somebody from the project | no | no | no | yes | permits (project absent locally) | ✓ | ✓ | ✓ | `project_members_screen.dart:175`; `project_membership_repository.dart:484` (`endMembership`) | Sets an end date rather than deleting the row, so the stint is history rather than erased. **The screen tells the truth about the limit** (`project_members_screen.dart:22`): removal cannot reach data already on the removed person's device (§5.1, §2.3). |
| M8 | Leave a project yourself | n/a | **yes, their own row** | **yes, their own row** | yes, unless they are the last owner | n/a (a project not on a server has nobody to leave) | ✓ | ✓ | ✓ | `projects_screen.dart` (`_LeaveButton`); `membership_provider.dart` (`MembershipController.leaveProject`, `leaveProjectVerdictFor`); `project_membership_repository.dart` (`leaveProject`); shared predicate `membership_departure.dart` (`isSelfDeparture`); `row_authorizer.dart` (`authorizeWrite`, the two `selfDeparture` points) | **Closed by task 11.28 (2026-08-23); this row used to say the operation did not exist.** Michael decided on 2026-08-22 that a viewer or a contributor may leave and that no owner confirmation is required. **The exception is one sentence: a person may set `end_date` on their own currently-open membership row, changing nothing else about it.** It overrides two things and only two: the role gradient (so a `viewer` can leave) and the `projectOwner` rule (so a non-owner can). Everything else still applies — the row must still name the caller as the one who changed it (§4.0), and **the last owner still cannot leave** (`LastOwnerRemoval` on the device, `lastOwnerRemoval` on the server, the two-in-one-batch case included). The columns a departure may move are derived from the schema, so a column added to this table later is immutable during a departure without anybody remembering to say so. Attacked by `server/test/authz/leave_project_test.dart` (24 cases) and `test/data/sync/membership_departure_test.dart` (24). The client's door is `leaveProject`, which takes a project and an actor and finds the row itself — there is no argument in which somebody else's membership could be named — and `test/security/narrow_rule_bypass_test.dart` counts the call sites of the write that skips the rule. |
| M9 | See the devices you are signed in on, and end one of them | no | n/a — not a project operation | n/a | n/a | n/a (nothing is signed in) | ✓ (sign-out-everywhere only, so far) | — | ✓ | `auth_routes.dart` (`GET /auth/sessions`, `POST /auth/sessions/revoke-device`, `POST /auth/sessions/revoke-all`); `auth_service.dart` (`listSessionsForUser`, `revokeDeviceSessions`); `server_config_screen.dart` (SIGN OUT EVERYWHERE) | **A person's sessions belong to the person, not to any project, so every role column here is `n/a` rather than a permission** — that distinction is what task 11.27 had to correct once already, and removal from a project deliberately does not touch sessions. **The listing route is new in task 11.35** and closes the reason per-device revocation was unreachable: `/auth/sessions/revoke-device` needs the lost device's id and nothing told a person what their devices were. The caller sees their own devices and no others — the `user_id` is taken from the validated session and the route reads nothing from the body or the query string (§4.11), and `server/test/security/auth_route_security_test.dart` tries both. **Each row carries a device id, when it first signed in, when it was last used, when it expires, and whether it is this device — and deliberately no source address**, which would put location-revealing data on a new read for a convenience (§4.7). There is no device *label* because the server stores none, and **task 11.36 decided not to add one** — a label is a schema change plus a new piece of free text the phone chooses and the app displays, which is a large new surface for a convenience; last-used and signed-in-on identify a device to its owner well enough. **The screen landed in task 11.36 (2026-08-29):** Server Connection lists the caller's devices most recently used first, marks the one being held, and offers per-device sign-out with a confirmation that says which of the two acts is about to happen. Revoking the current device signs you out here and says so rather than looking like a failure. All four auth routes involved are exercised end to end against a real server (`test/e2e/auth_routes_e2e_test.dart`). |
| M10 | Put a past member back | no | no | no | yes | no | ✓ | — | ✓ | `project_members_screen.dart` (`_ReadmitButton`, gated by `showAdmissionSheet`); `project_routes.dart` (`POST /projects/<projectId>/members/readmit`) → `_requireOwner`; `join_service.dart` (`readmit`) | **The one membership grant made without the other person acting**, and the only thing making it safe is a bound taken from the project's own history: the named person must already hold a **closed** membership row here and **no open one**. So it discloses nothing the owner cannot already see on their members screen, grants nothing new, and cannot add a stranger. "Already on the project" and "never was" draw the same refusal. It writes a **new** row and never nulls `end_date` on the old one. Counts toward the team-size limit. |
| M11 | Delete the project from the server, on a schedule every member sees (task 11.290) | no | no | no | yes | no | ✓ | — | ✓ | `projects_screen.dart` (`_scheduleServerDeletion`, `_cancelServerDeletion`, owner-only menu items with the reason shown to everybody else); `join_project_screen.dart` (`_JoinableRow`, owner-only menu for a project not on this device; `_DeletedOnServerSection`, the projects the caller deleted in the app that the server still holds as tombstones — task 11.292 — each with *Restore* since task 11.302); `project_routes.dart` (`GET /projects/<projectId>/deletion`, `POST /projects/<projectId>/deletion`) → `_requireOwner`; `project_routes.dart` (`GET /projects/deleted/mine`, session-keyed and owner-only by its query — §4.28.1); `project_destruction_service.dart`; `bin/project_destruction.dart` (the sweep) | **Owner only, because it destroys contributors' records and not only the owner's.** The server sets the date from its own clock and grace period; the body carries an action (`schedule`, `immediate`, `cancel`, and since task 11.302 `restore`) and nothing else, so no device can move the date. **`restore` is narrower than owner**: only the owner who deleted the project in the app may send it — exactly the people `GET /projects/deleted/mine` lists it for, asked of the same query (Security Model §4.28.1) — and it withdraws any scheduled destruction as it clears the tombstone. Every member reads the countdown from `GET /projects/mine` (§4.28's fifth field) and can export; a viewer or contributor sees the cancel greyed with the reason. The destruction itself runs in the `project-destruction` container on the server's timer with no device involved, or inside the `immediate` request. A destroyed id is retired: every later `/sync/*` request for it draws `403 project_destroyed` (§4.13's written exception), which is what stops an owner's offline device re-establishing the project with a pending rename. |

### 4.3 Field records — bearings and observations

***Hand-kept*** — and **not derivable by the route enumerator.** These are sync-path writes gated by `RowAuthorizer` and by table declarations, so the code-side truth is keyed on tables and columns, not on routes. A route-shaped check aimed here would pass forever without ever being able to disagree.

**This is the group task 11.7 built and the one cell the task named in advance.
The answer is read from the code, not reasoned:**

> **A contributor may *supersede* anyone's bearing, and may *exclude* nobody's
> — not even their own. Excluding is owner-only, at all three layers.**

That matches the project's stated dividing line exactly (additive writes that
unblock field work are contributor-level; subtractive writes that change what
the whole team sees are owner-level). **No decision is needed from Michael on
O6.** The consequence worth noticing is O5, one row up: a contributor who
records a bad bearing cannot take it out of the analysis themselves. They must
supersede it with a corrected record, or ask an owner.

| # | Operation | Stranger | Viewer | Contributor | Owner | Unknown | Screen | Device | Server | Source | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| O1 | Record a new bearing | no | no | yes | yes | yes (device permits; server refuses if the project is published and they are not a member) | ✓ | ✓ | ✓ | `observation_logging_screen.dart:137`, `:211`, `:228` (viewer banner); `base_repository.dart:118` → `:178` (`assertRoleMayWrite`); `row_authorizer.dart:568` (`_authorizeRole`); §4.21 | Additive and unblocks field work, so contributor-level by the stated dividing line — and the code agrees. A viewer's refused row is held on the device and explained, never dropped (`sync_held_rows.dart:87`). |
| O2 | Correct your own bearing, unsynced | no | no | own | own | own (permits) | ✓ | ✓ | ✓ | `authorEditVerdict` (`mutation_authorization.dart:96`); `observation_repository.dart:81` → `base_repository.dart:267`; `row_authorizer.dart:502` under `MutationRule.author` | Two gates compose, in this order: the role gradient first (a viewer may touch nothing, including rows they wrote before being demoted), then authorship. |
| O3 | Correct your own bearing, after it has synced | no | no | own | own | own (permits) | ✓ | ✓ | ✓ | as O2 | **Does a teammate ever see the earlier value?** Only if their own device also had an edit that lost the merge — the loser is captured to `Sync_Conflicts` and shown on the Sync status screen (`sync_status_screen.dart:90`). An ordinary correction simply replaces the older row on every device, with no record kept of what it said. |
| O4 | Correct a teammate's bearing | no | no | **new** | **new** | new | ✓ | ✓ | ✓ | `exclusionVerdict` (`mutation_authorization.dart:139`, `canSupersede: mayWriteProjectData`); `observation_exclusion_repository.dart:66` (`assertMayMark`); `row_authorizer.dart:604` (`_authorizeExclusionKind`); §4.21, §4.22 | Supersede, never overwrite. Editing someone else's observation stays refused (O2's rule); superseding is the only way one member can correct another's bearing, which is why it is contributor-level. The original survives with its author and values intact, the replacement carries its own author, the mark is reversible, and the solver counts only the superseding record. |
| O5 | Exclude a bearing you recorded | no | no | **no** | yes | permits | ✓ | ✓ | ✓ | `mutation_authorization.dart:149` (`canExclude: isOwner`); `observation_exclusion_repository.dart:76` (`role == ProjectRole.owner`); `row_authorizer.dart:610` | **Owner-only even for your own bearing.** Excluding removes evidence with nothing offered in its place, which is the data-quality rung the gradient reserves for owners; the rule is about the *kind* of mark, not about whose observation it names. A contributor who records a bad bearing supersedes it instead. |
| O6 | Exclude a teammate's bearing | no | no | **no** | yes | permits | ✓ | ✓ | ✓ | as O5 — the same three symbols, none of which look at whose observation it is | **The cell this task existed to check. The code says owner-only, at all three layers, and it matches the stated dividing line.** The server's check is `_authorizeExclusionKind` and it fires on the mark's kind before anything else, with its own denial reason. |
| O7 | Undo an exclusion or a supersede | no | no | own supersedes only | yes | permits | ✓ | ✓ | ✓ | `withdrawMarkVerdict` (`mutation_authorization.dart:179`); `observation_exclusion_repository.dart:159` (`withdraw`); `MutationRule.authorOrOwner` (`mutation_rules.dart:297`) | **Two questions, and both are asked.** The *rung*: an exclusion is owner-only to make and therefore owner-only to undo. *Whose mark*: the person who made it, or any current owner — widened by task 11.15 because under author-only a mark made by somebody who then left the project was permanent, and nobody, not even the bearing's own author, could restore it. Withdrawing tombstones the mark rather than deleting it, so the reversal itself merges between devices. **Task 11.24 found the server asking the wrong question here and fixed it:** `_authorizeExclusionKind` read the *pushed* `kind` where the app reads the *stored* one, so a mark's own author could escape the owner rung by flipping `kind` to `superseded` in the same row that withdrew it — reproduced live, and refused now. Security Model §19.3. |
| O8 | See that a record was excluded, and by whom | no | yes | yes | yes | yes | n/a | n/a | ✓ (read filter) | `log_screen.dart:1319` (the withdrawn sentence); `observation_exclusion_repository.dart:124` (`withdrawnByObservation`); task 11.18 | A read, so there is nothing for the device layer to refuse; what a person may see is decided by what pull delivers (§4.11). **Two of the names in that sentence come from columns the server does not bind to the caller** — see §10 and §8. |
| O9 | Remove a bearing permanently | no | no | own | own | own (permits) | ✓ | ✓ | ✓ | `observation_repository.dart:98` (`softDelete`) → `base_repository.dart:457`; `:490` (`restoreByKey`) | **"Permanently" does not exist in this app, and that is deliberate.** Every delete is a tombstone (`base_repository.dart:10-13`: a hard delete would resurrect on the next merge), it is reversible by restore, and the row stays until the server's 24-month retention purge. There is no hard-delete path anywhere in the data layer for a bearing; **since task 11.339 there is one for a whole project this phone does not sync** (P8), and it is never offered on a synced one. |

### 4.4 Triangulation

***Hand-kept*** — same reason as §4.3: sync-path writes, a different enumeration.

**Three of these five operations do not exist.** That is the honest answer, and
it is more useful than a verdict would have been.

| # | Operation | Stranger | Viewer | Contributor | Owner | Unknown | Screen | Device | Server | Source | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | ~~Create a triangulation session~~ **— capability RETIRED 2026-09-07 (task 11.197). Nothing in the app can create one any more.** | no | no | yes | yes | yes (permits) | ✓ | ✓ | ✓ | `mutation_rules.dart` (`anyUser`); `row_authorizer.dart` — **both unchanged and still enforced**; the *Attach to triangulation session* control that reached them is deleted | **Retired, not removed, and the distinction is the point.** `Triangulation_Sessions` **keeps and syncs every row any device has already made, and will gain no more** — so the row stays and the server-side rules stay, because they still govern rows that exist. **The convention for a removed capability (struck through, dated, kept) is not quite this**: nothing was deleted from the schema and the permission is still live for existing rows. **What must not happen is a reader concluding from silence that attaching an observation to a session is still something a person can do.** Michael's reason, 2026-09-07: *"we would select bearings from the list in the position menu."* Confirmed before removal — `ObservationRepository.findBySession` had no callers, so nothing downstream ever read a session. ~~There is no standalone "create a session" control — a session appears as a side effect of recording a bearing into one. `Triangulation_Sessions` is shared project vocabulary with **no author column**, which §4.21 states is deliberate: a contributor who could not write it could not record anything at all. |
| S2 | Add or remove bearings from a session | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | `Observations.session_id` (`schema.dart:133`), written once at `observation_logging_screen.dart:605` | **Cannot arise: a bearing's session is fixed when the bearing is recorded and no code path changes it.** The position estimator does not read it either — it selects bearings by project and tag and filters them through the exclusion marks. If "add" is ever needed, its answer is S1's; "remove" has no implementation at all. |
| S3 | Run or re-run the position estimate | yes to compute / refused to save | yes to compute / **no** to save | yes | yes | permits | ✓ | ✓ | ✓ | compute: `position_estimation_screen.dart:1071`; save: `:149`, `:165`, button gated `:1405`; `estimated_position_repository.dart`; `mutation_rules.dart:299` (`anyUser`) | **Two operations wearing one name.** Computing writes nothing and is open to anyone who can read the project — a viewer can and should be able to see the estimate. Saving is a write, and every save mints a **new** row; nothing ever updates a saved estimate. Saved estimates have no author, so a contributor may delete a colleague's. |
| S4 | Change a session's parameters | n/a | n/a | n/a | n/a | n/a | n/a | — | ✓ (would permit any member with write rights) | `triangulation_session_repository.dart:43` (`update`, **zero call sites**) | **Cannot arise through the app: no screen renders a session's label or notes, and the update method is never called.** If a crafted push carried one, the server would accept it from any contributor or owner of the project — `anyUser`, no author to be held to. Not to be confused with the project-wide triangulation window, which is a `Projects` column and is owner-only. |
| S5 | Delete a session | n/a | n/a | n/a | n/a | n/a | n/a | n/a | ✓ (would permit any member with write rights) | `triangulation_session_repository.dart` has no delete or soft-delete method | **Cannot arise through the app: the operation is not implemented on the device at all.** The server has no matching gap — a session tombstone arriving on a crafted push is an ordinary shared-vocabulary write and would be accepted from any contributor. |

### 4.5 Tags

***Hand-kept*** — same reason as §4.3: sync-path writes, a different enumeration.

Tags do not follow the general rule and get their own section — **see §7**,
which replaces a simple table because creating a tag, adding it to a project,
removing it, editing it and adopting an unused one have five different answers.
The table is there rather than here so it can sit next to the reasoning.

### 4.6 Data in and out

***Hand-kept*** — import and export are app-side operations with no server route and no table rule of their own.

| # | Operation | Stranger | Viewer | Contributor | Owner | Unknown | Screen | Device | Server | Source | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| I1 | Paste a shared observation somebody sent you | yes | yes | yes | yes | yes | — | — | n/a | `observation_sharing_screen.dart:86`, `:196` (`ObservationShare.decode`) | Decoding is not a write and is not gated by anything. Format and clock bounds run here but they are validity checks, not permissions. Never touches the server. |
| I2 | Save that pasted observation into a project | no | **no** | yes | yes | yes (permits) | ✓ | ✓ | ✓ | `observation_sharing_screen.dart:174`; `shared_observation_importer.dart:350` (`receiverMayImport`) — **task 11.19**; §4.19 | The check is deliberately the first statement of the save, so no branch — including one nobody has written yet — can get past it, and a refused import leaves no trace of the sender behind. The payload's *claimed author* is never run through the gradient; that is N-1's territory (§10). |
| I3 | Import a project file somebody sent you | yes (permits) | **no** | yes | yes | **yes (permits)** | n/a | ✓ **only** | ✓ | `project_merger.dart:344` (`receiverMayImport`) — **task 11.20**; §4.19.2, §5.10 | **On this path the device check is the only layer, not the second one** — which project an archive is for is unknown until the file is decoded, so there is no button to withhold. Same code path as I4. |
| I4 | Restore your own backup | yes (permits) | **no** | yes | yes | **yes (permits) — the accepted residual** | n/a | ✓ **only** | ✓ | as I3; residual stated at `untrusted_import.dart:132`; §5.10 | **This is the cell the Unknown column exists for, and it is knowingly open.** A viewer who wipes the app and restores an archive of a project they may only read passes the check, because a reinstalled device has no membership rows and the rule abstains rather than break every legitimate restore. Their rows are refused at the server, so the divergence is confined to their own device — and they could already have exported the same data (X2). **Attacked again by task 11.9 and it held.** |
| I5 | Import a spreadsheet of tags | no | **no** | yes | yes | yes (permits) | ✓ | ✓ | ✓ | `tag_csv_commit.dart:35`; `tag_repository.dart:53`; screen gate `tag_database_screen.dart:67` (task 11.14) | Writes exactly two tables — tags and their project links — all-or-nothing in one transaction. **There is no spreadsheet import of records**; the inventory's "or records" is wrong (§3.1(c)). |
| I6 | Receive teammates' records through sync | no (403) | **yes** | yes | yes | no (403) | n/a | — | ✓ | `sync_routes.dart:645` (pull), `:709` (ack); `project_authorizer.dart:101` (`permitsSync` includes viewer); `row_authorizer.dart:1020` (`canDisclose`) | Reading is the whole of what a viewer was granted, so pull must work for them. The device does not re-check on the way in, deliberately: rows from the authenticated server are a different trust class from a picked file (`project_merger.dart:55-63`). |
| I7 | Accept an identity the server assigns you | n/a — not a project operation | n/a | n/a | n/a | n/a | n/a | ✓ (four refusals) | n/a | `server_identity_adopter.dart:151` (`adopt`), `:165`, `:298` (`_refuseIfAnotherPerson`), `:364` (capture before delete); §4.20 | Role-independent: this is an identity operation, not a project one. Task 10.75 stopped the client taking the server's answer on faith — a server naming a colleague's identifier is refused, the refusal is total and atomic, and the superseded local record is preserved before anything is deleted. |
| X1 | Copy a single observation to send to somebody | n/a | **yes** | yes | yes | yes | — | — | n/a | `log_screen.dart:1386` (share button, unconditional), `:327`; §5.2, §5.7 | Ungated on purpose and correctly: a viewer may already read the observation, so copying it out is not preventable. Note the asymmetry on the same tile — edit and delete carry a reason when disabled, share carries nothing. That is deliberate, not an omission. |
| X2 | Export the project as a file | n/a | **yes** | yes | yes | yes | — | — | n/a | `data_export_screen.dart:77`; `project_exporter.dart:23`, `:56`; §5.2, §5.7 | **Not gated by role at any layer.** §5.2 argues that a member exfiltrating what they may read is not preventable — but the export is not limited to what the exporter may see: it collects the whole project including every referenced person's **prior email addresses** (`project_exporter.dart:56`). Nothing reasons about that width. See §8. |
| X3 | Export a spreadsheet | n/a | **yes** | yes | yes | yes | — | — | n/a | `data_export_screen.dart:118`; `tag_database_screen.dart:50`; `csv_writer.dart:33` | As X2. The one control on this path protects the *recipient* (spreadsheet formula injection, §4.19.4), not the project. On the tag screen the import button is role-gated and the export button beside it is not — deliberate, but it reads as an omission. |
| X4 | Back up to the server | no (403) | route yes, **rows no** | yes | yes | no (403) | n/a | — | ✓ | `sync_engine.dart:307` (`_push`, no client gate); `sync_routes.dart:525`; `row_authorizer.dart:568`; `sync_held_rows.dart:142`; §4.21 | A viewer's device does push, and each project row is refused one at a time rather than the whole push being rejected — because a viewer legitimately pushes one thing, their own profile, and because a refused row must be **held, counted and explained**, not lost (task 10.28). |
| X5 | Back up to your own cloud storage | n/a | **yes** | yes | yes | yes | — | — | n/a | **capability removed 2026-08-29** (`3a9a2c8` deleted `cloud_backup_service.dart`, `auto_backup_section.dart` and `cloud_backup_trigger.dart`); row kept as the record of what was decided; §4.15, §5.7 | X2 with one aggravation: it happens **on a schedule**, so nobody decides each time. On by default, with the reasoning recorded in §4.15 and re-decided in §4.15.1 against a multi-member population. |
| D1 | The diagnostics console's project routes | n/a | n/a | n/a | n/a | n/a | n/a | n/a | ✓ (three non-role gates) | `router.dart:129` (not mounted unless enabled); `diagnostics_routes.dart:65` (loopback only), `:89` (shared bearer token); §3.5, §4.10 | **Cannot arise in these five columns: the console has no notion of a person or a project membership at all.** It is off by default, refuses any caller that is not on the loopback interface (read from the real TCP peer, never from a header), and requires one shared token. Past those gates it reads across every project and every user, which is exactly why there is deliberately no session login on it. Read-only at the repository layer. |

---

### 4.7 Individuals and Deployments *(added by task 11.246, 2026-09-15)*

***Hand-kept*** — same reason as §4.3: sync-path writes gated by `tableMutationRules` and by
`DeploymentInterlock`, a different enumeration from routes.

**Why this section did not exist until now.** Task 11.240 added `Individuals` on 2026-09-13; task
11.243 added `Deployments` on the same date and, in doing so, **moved a permission rung**:
`Tags.individual_id` had been owner-only (changing an existing tag), and the same fact — which
collar is on which animal — is now recorded by inserting a `Deployments` row, which is
contributor-level. Neither table got a row here when it was built. **This document's own opening
promise — "nothing below is filled from memory" — was broken by omission for two days short of a
month**, which is Finding N-1's shape (a rung changing meaning with no artefact recording it)
happening to the document written to prevent exactly that.

**The rung, stated once rather than left to be inferred from a code comment.** Both tables are
`MutationRule.anyUser` in `tableMutationRules` (`packages/tritrack_sync/lib/src/mutation_rules.dart`):
any member with write rights — contributor or owner — may create, edit or tombstone a row, and there is
no author column, so one member may correct or remove another's entry. **This is a decision, not an
oversight, and task 11.243's comment gives the reason:** *"which collar went on which bird is
exactly what the person holding the bird knows and the owner does not"* — requiring an owner would
mean deployments are recorded at the end of the season or not at all. Editing a deployment's dates
does re-attribute the bearings taken in the window that moved (unlike editing an individual, which
changes nothing about what a bearing means), but it re-attributes only that window and rewrites no
bearing — which is design §2's whole argument for the table and the reason the rung did not need to
follow `Tags.individual_id`'s owner-only precedent to stay safe.

| # | Operation | Stranger | Viewer | Contributor | Owner | Unknown | Screen | Device | Server | Source | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| IN1 | Name a new animal | no | no | yes | yes | permits | ✓ | ✓ | ✓ | `IndividualRepository.insert`; the role gradient (`BaseRepository.insertRow` → `assertRoleMayWrite`) under `MutationRule.anyUser`; `AnimalDetailScreen` | Ordinary role gradient, no author. A contributor identifying a chick in the field must be able to record it — `TagRepository`'s reasoning for creating a tag, restated for the animal it now points at. |
| IN2 | Edit an animal's name, color or status | no | no | yes | yes | permits | ✓ | ✓ | ✓ | `IndividualRepository.update`; `_AnimalDetailScreenState._save` | **No owner-only lifecycle rung**, deliberately — editing an individual changes what no bearing means; bearings attach to the transmitter and the animal is derived through it (unlike an edit to a tag's own identity, which is owner-only because it changes what every earlier bearing on that collar is taken to say). |
| IN3 | Delete an animal | no | no | **no** | yes | permits | ✓ | **✓ (owner-only)** | **✓ (owner-only)** | `DeploymentLinking.deleteAnimal` → `DeploymentRepository.unlink` for each of its deployments, then `IndividualRepository.remove`, gated by `IndividualRepository.assertMayDelete`; the "Delete animal" button on `AnimalDetailScreen` (`_AnimalDetailScreenState._delete`), now gated on `isOwner`; server-side, `RowAuthorizer._authorizeIndividualLifecycle` refuses a non-owner's write that sets a live `Individuals` row's `deleted_at` (`DenialReason.deleteIndividualRequiresOwner`) | **Owner-only since task 11.255** — Michael, 2026-09-15: *"I like the idea of deleting an animal is an own only decision."* It destroys the animal's own record — name, color, status, species, sex, notes — which no screen can restore (the row is tombstoned, not hard-deleted, so the fields survive on disk; there is no `restore` on `IndividualRepository`). **Only this one write moved.** `assertMayDelete` is asked before the first deployment is withdrawn, not after, so a contributor refused this does not end up having silently emptied the animal of its collars first — watched red at both the repository and the server. **A contributor may still rename the animal or withdraw its collars** (IN2, DP3) — 11.244's "a contributor may correct a mistake" reasoning survives everywhere short of destroying the record, and the refusal sentence on the screen says so. Every deployment a delete does complete is *withdrawn* (tombstoned), not closed: the collars go back to being on nobody, and no bearing moves. The confirmation says *"That cannot be undone."* |
| IN4 | Say two animals are the same one (merge) | no | no | no | yes | permits | ✓ | ✓ (owner-only) | **✓ (owner-only)** | `IndividualMerge.merge`; device gate is `TagRepository.assertMayEdit` — the same "owns this project" check a tag's own owner-only edits use; screen gate `_mergeDisabledReason` on `AnimalDetailScreen` | **Closed by task 11.255, as a side effect of closing IN3 rather than by a merge-specific rule.** Task 11.246 recorded this as a device check with no server twin; task 11.254 measured that a contributor could reach a merge's exact end state by hand — withdraw, re-attach, edit the date back, then *Delete animal* — and concluded there was nothing for a server rule to refuse. **That argument's last step no longer holds**, because *Delete animal* is IN3, and IN3 is owner-only now: a contributor can still re-point every collar by hand but can no longer tombstone the absorbed animal's row, which is the one write a merge and a hand-done equivalent both end on. `RowAuthorizer._authorizeIndividualLifecycle` refuses that write from anybody but an owner whichever door it arrives through — `IndividualMerge.merge`'s own push, or a crafted one — so the merge's server enforcement is IN3's, not a rule of its own. See §8 entry 13. |
| DP1 | Record that a collar went on an animal | no | no | yes | yes | permits | ✓ | ✓ | ✓ | `DeploymentRepository.link`; also created inline from `ObservationLoggingScreen` while recording a bearing, when the collar has no deployment covering that moment; `AnimalDetailScreen`'s "Attach a collar" control | Additive, contributor-level, for the reason in the section preface. Refused by `DeploymentInterlock` (see DP2) if it would put the collar on two animals, or the animal in two collars, overlapping by more than a day. |
| DP2 | Edit a deployment's dates, tag or animal | no | no | yes | yes | permits | ✓ | ✓ | ✓ | `DeploymentRepository.update` → `_assertNoConflict`; `DeploymentInterlock`; `_AnimalDetailScreenState`'s deployment edit dialog | Re-checks the interlock on every edit, because moving a date is exactly the change that can create an overlap — refused with `OverlappingDeployment`, naming the colliding row, never silently adjusted. |
| DP3 | Withdraw a deployment | no | no | yes | yes | permits | ✓ | ✓ | ✓ | `DeploymentRepository.unlink`; `_AnimalDetailScreenState._unlink` | Tombstoned, not hard-deleted, like every other row in this app. A withdrawn deployment constrains nothing — freeing both the collar and the animal for a new link the interlock would otherwise have refused. |

**Two people, one deployment or one animal.** Neither table has an author column, so the answer is
the ordinary shared-vocabulary rule §6 already states for `Triangulation_Sessions`,
`Estimated_Positions` and `Actual_Tag_Locations`: whoever's write reaches the server last wins, and
either contributor may alter or tombstone the other's row. **`Individuals` is the one exception, since
task 11.255**: a contributor may still alter a colleague's animal (IN2), but may not tombstone it
(IN3) — deleting is an owner's decision whoever recorded the row. **Measured on every server run**:
`server/test/authz/permissions_matrix_test.dart`'s "shared tables" group derives its tables from
`tableMutationRules` — every `MutationRule.anyUser` table, seven today — and pushes each one's row as
one contributor and alters and tombstones it as a second. `Individuals` and `Deployments` are in it
because the rule puts them there, not because anybody remembered; the two anyUser tables a contributor
may *not* alter at all (`Tags`, `Tag_Versions`) are read out of
`RowAuthorizer._authorizeTagLifecycle`'s own source, and the one anyUser table whose *tombstone alone*
is owner-only (`Individuals`) is read the same way out of
`RowAuthorizer._authorizeIndividualLifecycle` — both expected to refuse exactly what they name. §8
entries 13 and 14 are closed.

**`Individuals`' T5-style retirement.** `IndividualStatus` (`enums.dart`) records a mortality or a
lost/malfunctioning collar the way `TagStatus` records a tag's; retiring an animal is an ordinary
edit under IN2, not a distinct operation, exactly as §3.1(b) found for T5 on tags.

---

## 5. Where being first matters

***Hand-kept***.

The question "who added it first" sounds like one rule and is five. Keeping them
apart is most of what makes this area confusing.

| What being first decides | Who wins | What it confers | Source |
| --- | --- | --- | --- |
| **Who authored a record** | the person named in the row's `user_id` when it was created | it becomes "your own" for the purpose of correcting or deleting it — and nobody else's, including an owner's. An owner cannot edit your bearing; they can only supersede or exclude it | `mutation_rules.dart:22` (`MutationRule.author`); `base_repository.dart:267`; `row_authorizer.dart:502`. **But see §10:** the server does not require that name to be the caller's on the way in |
| **Who created a project** | the creator | ownership — and, if the membership table ever names no open owner, a permanent fallback claim to it, so a restored phone cannot be locked out of its own project | `row_authorizer.dart:679`; `project_owners.dart:55` (creator fallback); §4.21.1 |
| **Who created a tag** | the creator, but only until somebody links it to a project | nothing durable. Creating a tag confers no rights over it: once any project links it, **that project's owners** may edit it, and the creator has no standing unless they are one of them. Until a project links it, the person whose name is on its audit column is the only one who may maintain it | `tag_repository.dart:137` (`assertMayEdit`); `row_authorizer.dart:1391`; §5.9(a). Two people creating one on the same frequency is a workflow, not a verdict — §7 |
| **Which of two conflicting edits survives** | the later edit, by the sync clock | the loser's copy is not destroyed: it is captured to the local conflict store before it is replaced, and shown on the Sync status screen | `merge_resolver.dart:32` (`compare`), shared verbatim by app and server; `sync_engine.dart:455` (`_recordConflicts`); `project_merger.dart:889` |
| **…and what breaks a tie** | higher revision, then the later timestamp, then **the higher device identifier, lexically** | a deterministic answer, so two devices merging the same pair always agree — but the device identifier is a random value the device picks for itself and stores in plain text, so **a device that chooses a high one wins every future tie on purpose** | `merge_resolver.dart:12-15`, `:42`; §3.7, §4.12. Recorded as known and **never dispositioned** — see §8 |
| **Who may adopt a tag no project uses** | anybody holding its identifier | the right to link it into their project, and thereafter their project's owners hold the editing rung on it | `row_authorizer.dart:1401`; `project_setup_screen.dart:711`; §5.9(a), finding F4. Accepted: the identifier is an unguessable random value, so this needs prior knowledge, not enumeration |

---

## 6. Two people, one record

***Hand-kept***.

For each pair, three things: what wins, what survives, and **what the person is
told**. The third is the one users actually experience.

| Situation | What wins | What survives | What the person sees | Source |
| --- | --- | --- | --- | --- |
| **Same person, two devices** | the later edit, by the sync clock; on a tie, the device with the higher identifier | both — the losing copy is written to the local conflict store before it is replaced | A "Conflicts" entry on the Sync status screen showing what this device offered and what is now authoritative. Nothing is shown if the loss discarded nothing | `merge_resolver.dart:32`; `sync_engine.dart:455`, `:475` (`_lostNothing`); `sync_status_screen.dart:90` |
| **Two teammates, same record** | later edit, same rule | both — for a *correction* the supersede mark keeps the original with its author and values intact, and the position estimate counts only the superseding record; for a straight edit-vs-edit the loser goes to the conflict store | The Log/Team tab shows "Superseded by *name*", with the reason if one was given; a lost edit shows in the Sync status screen's conflicts. Note that push runs before pull, so an unpushed local edit is always offered before anything can overwrite it | `observation_exclusion_repository.dart:16`; `analysis_eligibility.dart:32`; `log_screen.dart:1319`; `sync_engine.dart:211-232`; §4.22 |
| **A teammate and an imported file** | the file wins only if its clock is genuinely later, **and only after the person is shown what it would change and consents** | both — the prior version is captured before it is replaced, unconditionally on the update path, so recoverability is a property of the write rather than of the person happening to have a backup | A consent dialog listing what would change and which changes are destructive, before anything is written; afterwards, a message that reads the actual outcome rather than assuming it | `project_merger.dart:884`; `untrusted_import.dart` (`columnsMovedByEveryEdit`); §4.19 clause 4, and finding K-8's closure |
| **An imported file and the server** | whichever the shared clock rule prefers — there is no special case | both, by the same capture | The file's rows are applied locally first; anything the server then refuses is **held and explained**, not silently dropped: *"This record is safe on this device and nothing has been lost. It is waiting because it names a person, or uses a tag, that is not part of this project yet."* | `merge_resolver.dart:32`; `sync_held_rows.dart:87` (`notPermitted`); §4.19.2 |
| **Two records with the same identifier in one sync** | the shared clock rule decides, row by row, inside one transaction | both, by the same capture | Nothing special — this is the ordinary merge. **Two rows in the same push cannot each be judged against a snapshot that excludes the other**: the server tracks what a push has already been cleared to do, which is what stops two membership rows in one batch both slipping past the one-open-stint rule and two rows vouching for each other | `row_authorizer.dart:713` (`_membershipsGrantedThisPush`), `:1173` (`_ownershipsRemovedThisPush`), `:286` (`_establishedThisPush`); §4.21.3 |

---

## 7. Tags

***Hand-kept***.

Tags get their own section rather than a row in §4, because they do not follow
the general rule: creating one, adding it to a project, removing it, and
merging two of them have four different answers.

**The sentence this section used to be built on is gone (task 11.219,
2026-09-10).** It read: *"A tag is a **global** record that a project
selects."* It is not, and has not been since schema v14. **A tag belongs to
exactly one project**, and adding one to a project *copies* it — the project
gets its own row, with its own id, and editing it changes neither the
person's tag library nor any other project's copy. Two projects' tags are the
same physical collar exactly when their `lineage_id` values match, which
nothing in the app reads and an export carries.

What a person keeps outside any project is their **tag library**
(`Tag_Library`): device-local, never synced, in no archive. No role governs
it — it is their own list of their own equipment — so it appears in no row
below.

| # | Operation | Stranger | Viewer | Contributor | Owner | Unknown | Screen | Device | Server | Source |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| T1 | Create a tag | yes | **no** | **yes** | yes | yes (permits) | ✓ | ✓ | ✓ | `tag_database_screen.dart:91`, `:372`; `tag_repository.dart:53`; `row_authorizer.dart:1315`; §4.21 |
| T2 | Copy a tag into this project | no (403) | **no** | **yes** | yes | yes (permits) | ✓ | ✓ | ✓ | Project Setup's "Copy from library"; since task 11.321 also **dropping a Tag Library tag on a project heading**, **picking a library tag in an animal's *Link a tag***, and **Quick add** (same write, same rung, same refusal); `TagRepository.copyFromLibrary`; the ordinary project scope check and role gradient in `RowAuthorizer._decide` — **task 11.219 replaced a link row with a copy**, so there is no grant to authorize and no `insertIsAGrant` branch |
| T3 | Remove a tag from this project **— and putting one back** | no (403) | no | **no** | yes | permits | ✓ | ✓ | ✓ | **The put-back half is owner-only too since task 11.219, measured 2026-09-10 by task 11.220 and confirmed as the wanted rule by Michael the same day.** The device disagreed for one day — `restoreToProject` ran no `assertMayEdit` and the "Add back" button was enabled for any contributor — and **task 11.221 closed it the same way on both layers**: the repository asserts, the button is gated on the owner rung, and the section's one sentence says why. Project Setup's remove and add-back controls; `TagRepository.restoreToProject`; `TagRepository.removeFromProject`; `RowAuthorizer._authorizeTagLifecycle` (`changeTagRequiresOwner`) — **owner-only since task 11.24**, and since task 11.219 it is a tombstone on the project's own tag row rather than a link status, so the one rule covers the status change and the tombstone together; Security Model §19.3 |
| T4 | Edit a tag's name, frequency or color | no (403) | **no** | **no** | yes — of the project the tag belongs to | permits | ✓ | ✓ | ✓ | Project Setup's tag row opens the shared tag form; `TagRepository.assertMayEdit`; `RowAuthorizer._authorizeTagLifecycle`; §4.21. **Task 11.219 narrowed two things here.** The owner qualifier was *"of **any** project that uses the tag"*, because a tag was global and had no single owner; a tag has one project now. And the stranger column was *"no, except an unclaimed tag they last touched"* — there are no unclaimed tags, so §5.9(a)'s residual and its exception are both closed. |
| T5 | Retire a tag | as T4 | **no** | **no** | yes | permits | ✓ | ✓ | ✓ | as T4 — retiring is a change to the tag's status and gets no branch of its own (`tag_repository.dart:89`, `row_authorizer.dart:1384`) |
| T6 | Merge two tags | n/a | n/a | n/a | n/a | n/a | n/a | n/a | n/a | Deferred to Phase 12 (`tag_repository.dart:29`, `near_duplicate_tags.dart:11`) |
| ~~T7~~ | ~~Adopt a tag no project currently uses~~ | ~~no (403)~~ | ~~**no**~~ | ~~**yes**~~ | ~~yes~~ | ~~permits~~ | — | — | — | **Removed 2026-09-10, task 11.219 — struck through and dated rather than deleted, per this document's convention.** The capability required a tag that belonged to no project. `Tags.project_id` is `NOT NULL` and half the primary key now, so there is none, and adding a tag to a project copies it rather than adopting a shared one. `_tagIsClaimedElsewhere`, which was the whole of the server-side rule, is deleted with `_authorizeTagReferences`. This closed §5.9(a) and finding F4 — see the security model. |
| T8a | **Append** what a tag reads now, as a `Tag_Versions` row | no (403) | **no** | **yes** | yes | permits | n/a | ✓ | ✓ | `tag_repository.dart` (`insert` → `TagVersionRepository.createInitialVersion`); `RowAuthorizer._authorizeTagLifecycle`, which governs `Tag_Versions` exactly as it governs the tag; task 11.32 |
| T8b | **Rewrite** one — the *correction* half of a tag edit | no | **no** | **no** | yes | permits | ✓ | ✓ | ✓ | `tag_repository.dart` (`update` → `recordEdit`, behind `assertMayEdit`); `RowAuthorizer._authorizeTagLifecycle` (`existing != null` and the row changes); task 11.32 |

**Creating a tag** — contributor-level. Task 11.11's decision, and the code
agrees on both sides: a viewer creates nothing, a contributor may. A tag is
something a person needs in the field, and refusing it would stop them recording.

**Copying a tag into a project** — contributor-level, **and the "decision on
record" that this is owner-only is wrong**. The code is explicit and
deliberate on all three layers — *"additive, unblocking, contributor-level,
same as creating a tag"* — and the plan itself says so where the decision was
made. Whatever note said owner-only was about T3, not T2.

**It is a copy rather than a link since task 11.219**, and that changes what
the operation *is* rather than who may do it. The project gets its own row,
with a fresh id and the source's `lineage_id`; editing it afterwards changes
this project and nothing else. What it is copied *from* is the person's own
tag library, or another of their projects.

**Removing a tag from a project** — owner-only, and **enforced at all three
layers since task 11.24 (2026-08-22)**. It was owner-only *as an intention*
only: `assertMayUnlink` required an owner before the app would deactivate a
project's tag link, and nothing on the server knew the rule existed, so a
contributor's device pushing the row directly had it accepted and the tag
disappeared for the whole team. **Reproduced live before it was fixed**, and
the same push carrying a *tombstone* was accepted too — a route the app has no
button for, so the server was taking something worse than the operation it
gates. Both are refused now. Judged against §4's bar and found to **meet it**
(B4→B3, an authorization bypass at the server): Security Model §19.3 carries
the reasoning. Adding a tag, and putting back one that was removed, stay
contributor-level — only the subtraction is reserved.

**A tag added by one person appearing for the rest of the team** — the tag row
is in the project, so pull delivers it to everyone in the project like every
other project-scoped row. ~~That is what the link row is for: creating it is a
read grant, and pull then delivers the tag to everyone in the project. This is
why linking a tag another project already holds is refused: linking it would
disclose it.~~ **Task 11.219 removed both halves of that.** There is no read
grant, because there is no global row to grant sight of; and there is nothing
to refuse, because a second project holding the same collar holds its own
copy, which discloses nothing about the first.

**Two people create a tag on the same frequency** — the app **warns and then
gets out of the way**, everywhere, by design. All four creation paths call the
same near-duplicate check (equal frequency to the kilohertz, or an identical
name after trimming and lowercasing); the dialog's buttons are "Go back" and
"Create anyway", and there is no merge and no refusal, because two collars can
legitimately share a nominal frequency if they are never in range together. The
spreadsheet import does the same thing per row, with an opt-in skip checkbox
that defaults to importing.

**What a tag read when a bearing was taken (T8)** — task 11.32's `Tag_Versions`
table, and the two rungs are deliberately different for the same reason T1 and
T4 are.

*Appending* a version is contributor-level. It is additive and forward-only: an
appended version changes what records made *after* it read and never what an
already-recorded bearing reads, and it leaves the `Tags` row alone so any
discrepancy shows up in the tag list. Requiring an owner would refuse a
contributor's own new tag's first version — and would refuse it
*intermittently*, because a sync batch limit can split the `Tags` row and its
first version across two pushes, leaving the second permanently held. A tag with
no version gives every bearing on it a null measurement context forever,
silently, which is the loss class this project ranks worst.

*Rewriting* one is owner-only, all three layers. That is the correction path and
it is the retroactive act: it changes what every bearing already taken since
that version took effect says it was recorded against. Same act, same rung, as
editing the tag itself.

**Known and accepted, stated here rather than left to be found:** a contributor
can append a spurious version to a tag their project reaches, and the next
bearing anybody records on that tag will cite it. It is forward-only, it does
not touch the `Tags` row, and the extra version is visible in the tag's history
— and the alternative was an intermittent permanent refusal of legitimate rows.
If that trade is ever revisited, revisit it here.

**Merging two tags and their records** — deferred to Phase 12, confirmed absent
from the code.

~~**One thing this section cannot answer, and it belongs in §8.** A tag is
global and may be used by several projects at once. An owner of project A may
rename, re-tune or retire a tag that project B is also using, and **project B
is not told**. B's stored bearings then mean something different from what
they meant when they were recorded. The security model's tag table is written
per-project, as if a tag had one project, so nothing reasons about this.~~

**Answered by task 11.219, 2026-09-10, and the answer is that the question
stopped existing.** A tag *has* one project. An owner of project A renaming
or re-tuning their copy of a collar changes A's records and nothing else; B
holds its own row, which nobody touched. The two are recognizable as one
physical transmitter by an equal `lineage_id`, which is carried in an export
for exactly this kind of cross-project analysis and is read by nothing live —
so B is still "not told", and that is now the intended behavior rather than
an unreasoned gap. **The security model's tag table was written per-project,
as if a tag had one project; the schema caught up with it.**

---

## 8. Cells nobody has decided

***Hand-kept*** — by definition: these are the cells with no answer to derive.

**This section is the point of the document.** Every `?` above lands here with a
name, and each one is either a decision for Michael, a question for the code, or
a task. A question recorded here without one of those three dispositions is the
failure this project has cost itself six weeks on twice.

**Twelve entries. Four were decisions only Michael can make; seven wanted a task;
one was already answered by the code.**

**Every one of the twelve now has a disposition, as of 2026-08-22.** Michael's
four decisions and the task numbers are below; the table's own wording is left as
11.23 wrote it, because it is the evidence. **Entries 13 and 14 were added by task
11.246 on 2026-09-15 and dispositioned by task 11.254 the same day** — 14 closed, 13
turned into a decision only Michael can make, with its number.

| # | Disposition, 2026-08-22 |
| --- | --- |
| 1 | Answered by the code. Owner-only, all three layers. Closed. |
| 2 | **Closed by task 11.24 (2026-08-22)**, which absorbed 11.26. Reproduced live, judged against the bar and found to **meet it** — B4→B3, a contributor performing an owner-only subtractive write at the server, the first finding since the eighth run to reach the bar. Fixed for both routes (status change and tombstone), and the whole class swept: two more instances found, one fixed and one shown to be unfixable at the server. Security Model §19.3, §19.4. |
| 3 | **Michael decided: yes, a viewer or contributor may leave a project, with no owner confirmation.** Task 11.28 part 1. The narrow exception it needs is the security-sensitive part. |
| 4 | **Michael decided: status quo — accept it.** Task 11.27 writes the acceptance with a number and a reason, which is what it has been missing since Phase 10. |
| 5 | **Closed by task 11.24 (2026-08-22).** The affected set is derived from `MutationRule.namesRowAuthor` and asserted by a test that has been watched to fail — remove one table's case and it goes red naming the table. `Non_Detections` is covered because the rule covers it, not because anyone remembered it. |
| 6 | **Closed by task 11.24 (2026-08-22), and the decision was yes, the fix covers updates.** `last_modified_by` must name the caller on any update that changes the stored row — so leaving somebody else's name on a withdrawal is refused, on every table rather than on this one. Nothing legitimate is refused: a push that reaches the check is by definition changing the row, so it is an act and the actor is the caller. Security Model §19.2. |
| 7 | **Closed by task 11.32 (implemented), for the reason recorded below.** Editing a tag no longer changes what any earlier record means, in *any* project — a bearing resolves its frequency and name through the `Tag_Versions` row that was current when it was taken, so the second project's stored bearings keep saying what they always said. What survives of this cell is narrower and is task 11.34's: two projects still *share* one tag row, so an edit still changes what the other project sees on its tag list and on records it takes from now on. **Michael reversed this on 2026-08-22, and the reversal is right: tag frequencies drift, so edits must be allowed.** Task 11.29 is **canceled**. What replaces it removes the question rather than answering it — **task 11.32** records the frequency a bearing was actually taken at, so editing a tag can no longer change what past records mean, and **task 11.34** copies a tag into a project when it is added, so no two projects share one. The no-disclosure constraint 11.29 found survives and moves to 11.34. |
| 8 | **Task 11.30.** The width is the finding, not the gating. Prior email addresses out; siblings swept; the remainder accepted in writing. |
| 9 | **Closed by task 11.25 (2026-08-22)**, widened to enumerate the three shared tables in the cross-author direction. Agreed that the design is not the problem — the missing test is, and it now exists. |
| 10 | **Task 11.27.** Correct the record, do not build the control: sessions belong to a person, not a project, so revoking on removal from one project would sign them out of every other. The planning session made that exact mistake once already. |
| 11 | **Task 11.28** parts 2 and 3. Both routes exist and are correctly built; nothing calls them. |
| 12 | **Answered 2026-08-22: the feature was intended.** Scheduled as **task 11.33** — a new entry on the record screen with current-location or map-pin position, a radial precision prefilled from the phone's own reported accuracy, a three-way choice of animal-and-collar / animal-only / collar-only, notes and time. Two decisions in it are not details: no over-confident precision default, and a test asserting a truth point never changes a position estimate. |
| 13 | **Closed by task 11.255 (2026-09-15) — Michael chose option (a) of the three task 11.254 costed: 2026-09-15, "I like the idea of deleting an animal is an own only decision."** `IndividualRepository.remove` now asserts the owner rung (`assertMayDelete`) before its first write, and `RowAuthorizer._authorizeIndividualLifecycle` holds a non-owner's tombstone of a stored `Individuals` row to the same rung on the server (`DenialReason.deleteIndividualRequiresOwner`) — mirroring `_authorizeTagLifecycle`'s shape, narrowed to the one write that changes. **This reverses half of task 11.244's decision, on purpose**: a contributor may still remove an animal's *collars* (withdraw) and rename or re-describe it (IN2), but may no longer destroy its record. `DeploymentLinking.deleteAnimal` asks the rung before withdrawing any deployment, so a contributor refused this has written nothing — watched red at both layers. The merge's own server gap (IN4) closes as a consequence: `IndividualMerge.merge` ends on this same tombstone, so the rung now reaches it through the write rather than through a rule of its own. See IN3, IN4 and the "Two people" note above §8. |
| 14 | **Closed by task 11.254 (2026-09-15).** The "shared tables" group now derives its population from `tableMutationRules` — every `MutationRule.anyUser` table, seven today — and reuses each table's cross-cutting fixture, so `Individuals` and `Deployments` are covered because the rule covers them. The two anyUser tables a contributor may *not* alter, `Tags` and `Tag_Versions`, are read out of `RowAuthorizer._authorizeTagLifecycle`'s source rather than listed, and are expected to refuse — which is the first server-side measurement of T3's tombstone route in this file. Watched red twice: the tag rung deliberately reopened (both tag tables reported a contributor's tombstone `updated`), and the method renamed (the derivation refuses to load rather than returning an empty exception set). |

| # | Cell | The question, in plain terms | Disposition |
| --- | --- | --- | --- |
| 1 | **O6 — exclude a teammate's bearing** | contributor or owner? | **Answered by the code, no decision needed.** Owner-only at all three layers, matching the stated dividing line. `mutation_authorization.dart:149`, `observation_exclusion_repository.dart:76`, `row_authorizer.dart:610`. Recorded here so the question is not asked a fourth time. |
| 2 | **T3 — remove a tag from a project** | The app says only an owner may take a tag out of a project. **The server has never been told that rule.** A contributor whose device pushes the row directly has it accepted, and the tag disappears for the whole team. | **Needs a task, and it is the most actionable finding here.** This is precisely §4.23's point 2 — a client-side check with no server twin *is* a finding. The fix is a branch in `RowAuthorizer` for a `Project_Tags` row whose status is being set inactive, mirroring `_authorizeExclusionKind`'s shape. **Ask the planning session to add it to Phase 11.** |
| 3 | **M8 — leave a project yourself** | A viewer or contributor could not get off a project. There was no control, no route, and the rule table makes membership rows owner-only to write. If a device tried anyway, the app threw an error no screen caught and the server refused the row forever, leaving that device permanently out of step. | **Closed by task 11.28 (2026-08-23).** Michael chose option (b) on 2026-08-22 — a person may leave, and no owner confirmation is required. The exception is the shared `isSelfDeparture` predicate: set `end_date` on your own currently-open row and change nothing else. It overrides the role gradient and the `projectOwner` rule and nothing else; the last-owner rule and the audit-column rule both still bind. The device-divergence half is closed too: the row the app now writes is one the server accepts, the app syncs that project before writing so it is not built from a stale copy, and the project is unlinked once the server confirms the departure — or, when the person left offline and the confirmation arrives days later, when the server refuses a project this device's own records say they already left. It stops syncing rather than failing forever with an unexplained `403`. Security Model §4.25 is the section that did not exist. |
| 4 | **Which of two conflicting edits survives — the tiebreak** | The final tiebreak is the device's own identifier, which the device picks for itself and stores in plain text. A device that chooses a high one wins every future tie deliberately. | **Recorded as known since Phase 10 and never given an owner** — it sits in the security model's discovered-scope list as *"Probably acceptable; the point is to record the acceptance explicitly rather than leave it unexamined"*, with no task number, which is the exact shape task 10.72 exists to prevent. **A decision only Michael can make:** accept it in writing, or task it. |
| 5 | **`Non_Detections` — record that you heard nothing, under a colleague's name** | The same defect as the one already scheduled for bearings and exclusion marks, on a third table nobody named. A contributor can file "I listened at this place and time and heard nothing" credited to a teammate. | **Ask the planning session to widen task 11.24 to name this table.** It is the same fix, the same rule and the same line of code; if 11.24 is scoped to two tables it will close two of three. See §10. |
| 6 | **"Withdrawn by" in the Team log** | Task 11.18 shows who withdrew a supersede or exclusion. It reads that name from an audit column the server does not bind to the caller. | **Ask the planning session to add this to task 11.24's scope, explicitly, because it changes that task's answer.** 11.24's preferred fix is to require that a row naming an author names the caller **on insert**. That would not close this one: the update path permits a name that merely matches what is already stored. If 11.24 ships insert-only, this stays open. See §10. |
| 7 | **T4 — editing a tag two projects share** | An owner of one project may rename, re-tune or retire a tag another project is also using, and that project is never told. Their recorded bearings then mean something different from what they meant when taken. | **A decision only Michael can make**, because it is a research-practice question before it is a code one. Options: **(a)** accept it — tags are shared equipment and this is how shared equipment works; **(b)** notify the other projects; **(c)** refuse the edit unless the caller owns every project using the tag. The code's current behavior is (a), and it is documented in the code but **not in the security model**, whose tag table is written as though a tag had one project. |
| 8 | **X2/X3/X5 — export width** | Export is not gated by role at any layer, which §5.2 argues is unpreventable and I agree with. But the export is not limited to what the exporter may see: it includes every named person's **prior email addresses**. | **Needs a task, or an accepted-risk entry with a reason.** The width is a separate question from the gating, and §5.2's wording ("data they are authorized to see") does not cover it. I did not find anything that reasons about it. |
| 9 | **Deleting a colleague's saved position estimate, session or ground-truth point** | Three shared tables have no author column, so a contributor may alter or delete a colleague's row. That is a deliberate design decision (§4.21) and I am not challenging it. **What is missing is a test.** The permitted direction is covered; the cross-author direction is asserted only for bearings. | **Closed by task 11.25 (2026-08-22).** `server/test/authz/permissions_matrix_test.dart`'s "shared tables" group pushes each of `Triangulation_Sessions`, `Estimated_Positions` and `Actual_Tag_Locations` as one contributor and alters and soft-deletes it as a second, distinct contributor on the same project — both measured `updated`, confirming the deliberate design holds and is now guarded by a test rather than only by a decision. |
| 10 | **Removing somebody from a project does not end their sign-in sessions — and a comment in the code says it does** | `auth_routes.dart:509` states that member removal "calls `AuthService.revokeAllSessionsForUser` server-side, inside the flow that already established the caller is an owner." **There is no such call.** The only caller of that function is the person's own "sign out everywhere" route, and there is no server-side removal flow to hang one on — removal is an end-date on a synced row, not a request to the server. | **Needs a task.** The removal itself still works, and that is worth saying plainly: access is re-resolved from membership rows on every request, so a removed person is refused the project on their next sync whether or not their session survives. **What is broken is the record.** A comment asserting a control that does not exist is the exact failure this project has paid for repeatedly, and §4.3's revocation story reads as though removal revokes sessions. Either wire it up or correct the comment and §4.3 — but not neither. |
| 11 | **"Sign out everywhere" and "I lost my phone" cannot be reached from the app** | Both revocation routes exist on the server, are correctly built (the person revoked is always the authenticated caller, taken from the session and never from the request), and **no screen calls either one.** | **"Sign out everywhere" is closed by task 11.28 (2026-08-23)** — Server Connection now has a SIGN OUT EVERYWHERE control that calls `/auth/sessions/revoke-all`, confirms first, reports how many sign-ins ended, and (unlike ordinary sign-out) refuses to clear this device unless the server confirmed, so it cannot report success when nothing was revoked. **Per-device revocation is still unreachable, and the reason is a missing read, not a missing button:** `/auth/sessions/revoke-device` needs the lost device's id and there is no route that lists your own sessions, so nothing can offer a picker. Signing out everywhere reaches the same end state at the cost of one sign-in per surviving device, and the screen says so. **The listing route is built by task 11.35 (2026-08-23)** — `GET /auth/sessions` returns the caller's own devices, so the missing read is no longer missing and a picker became possible to build. **Closed by task 11.36 (2026-08-29):** Server Connection now lists your devices and signs any one of them out, so "I lost my phone" no longer costs everybody else's sign-in. |
| 12 | **Recovered tag locations can be received but never recorded** | The ground-truth recapture table has a schema, a rule, a repository with insert and update, and a map layer that draws its points — and no control anywhere creates one. | **A question for the planning session, and probably a decision for Michael:** is this a feature that was designed and never finished, or a table that exists only to carry values from elsewhere? If the former it needs a task; if the latter it should say so, because a repository with an uncalled insert reads as an oversight to the next person. |
| 13 | **Merging two animals is owner-only on the screen and the device, and not on the server** | `IndividualMerge.merge` tombstones the absorbed `Individuals` row and re-points its `Deployments` rows — an irreversible, cross-row act — gated only by `TagRepository.assertMayEdit` on the device and the widget's own `isOwner` check. Both target tables are `MutationRule.anyUser` at `RowAuthorizer`, so a contributor who edits their own database file directly, or crafts the equivalent push, performs the merge at the contributor rung with no server-side refusal. Found by task 11.246 while writing §4.7, not asked for by it. | **Needs a task, and it is the same shape as entry 2 above (T3) — a client-side check with no server twin.** The fix is a branch in `RowAuthorizer` recognizing a merge's two writes (an `Individuals` tombstone whose `deployments` on the same push re-point to a different `individual_id`) and requiring the caller to be a project owner, mirroring `_authorizeExclusionKind`'s shape — or, if that pattern proves too specific to detect reliably at the row level, an explicit accepted-risk entry saying why merge is left device-only. **Ask the planning session to add it to Phase 11.** |
| 14 | **The "shared tables" cross-author test (entry 9, §8) does not cover `Individuals` or `Deployments`** | `server/test/authz/permissions_matrix_test.dart`'s "shared tables" group proves a contributor may alter or tombstone a *different* contributor's row for `Triangulation_Sessions`, `Estimated_Positions` and `Actual_Tag_Locations` — the three tables entry 9 named in 2026-08-22. `Individuals` and `Deployments` share the identical rule (`MutationRule.anyUser`, no author column) and arrived five weeks later, and nobody widened the group. Found by task 11.246 while writing §4.7. | **Needs a task**, and a small one — the group's own shape already generalises; it is adding two more table fixtures to a loop that four already share, not new logic. **Ask the planning session to add it to Phase 11**, ideally folded into whatever task closes entry 13, since both touch the same test file. |

**Confirmed by the planning session, 2026-08-22 — task 11.32's two questions.**

- **A contributor may add a tag version; only an owner may rewrite one. Agreed.**
  Adding a version says *"from today the tag reads this"* and touches no existing
  record — that is recording drift, which is field work, and a contributor who cannot
  do it cannot record correct bearings. Rewriting a version says *"what we wrote down
  for the last six weeks was wrong"* and changes the meaning of records the whole team
  already holds. **That is exactly the additive-versus-subtractive line already stated
  in `TriTrack_Technical_Context.md`**, which is the strongest argument for it: the
  answer falls out of a rule that already existed rather than being invented here.
  The batch-splitting hazard 11.32 cites is real and is good corroboration, but it is
  **not** the primary reason and should not be recorded as one — a permission loosened
  to route around a batching problem is a shape that comes back as a finding. The
  splitting question is now its own line in task 11.24.
- **`Tag_Versions` joins the existence-oracle acceptance as the fourth table.
  Accepted, and 11.32's condition is endorsed as written:** if that acceptance is
  ever reopened it is reopened for all four tables at once, never three. That is the
  fix-the-class rule applied to an acceptance rather than to a defect, which is the
  right instinct and is not something this project has done before.

**Two acceptances recorded 2026-08-22 from task 11.24, each with the condition that
would reopen it:**

- **Publishing a project you only hold a copy of makes you its owner, permanently.**
  Michael accepted this on 2026-08-22 rather than making projects re-numberable, and
  for the malicious case that is right — the attacker must already hold the project
  and identifiers are not guessable. **The condition: the likely path is an accident,
  not an attack.** The app's own share screen suggests emailing a project file to a
  colleague, and that colleague has a publish button. So the acceptance is
  conditional on the publish screen naming who is about to become the owner, and
  saying when a project was imported rather than created on this device. Task 11.28
  part 4. **The condition is met as of 2026-08-23**: publishing now asks first,
  names the signed-in address that will become the owner, states that the server
  gives a project to whoever publishes it first, and — when the project's recorded
  creator is not this account — says in red who will be locked out and to check
  with them. Pinned by `test/features/more/publish_ownership_warning_test.dart`;
  **if those tests go, the acceptance goes with them.**
- **A contributor can create a brand-new tag stamped with a colleague's name.** Left
  open deliberately: closing it would break publishing a project whose tags a
  teammate created, and a held tag drags every bearing that uses it down with it.
  What the forgery buys is that only the named person may edit that tag while no
  project uses it — an annoyance and a self-inflicted lockout, not a false scientific
  record, because a tag is equipment metadata rather than a measurement. **The
  condition that would reopen it: the day anything displays or exports "tag created
  by", that display is false.** Same shape as the exclusion-reference acceptance — a
  residual that is harmless only because nothing reads it yet. Also worth checking
  against task 11.34: once a tag added to a project is a copy, "who created it" may
  be a different question and this residual may cease to exist.

**Two decisions taken 2026-08-22 from task 11.28, both accepted:**

- **A person leaving a project states their own departure date and nothing checks
  it. Accepted.** Nothing in the app reads that date for anything except "is this
  person still on the project", so it grants no access and removes none, and an owner
  could already set any date they liked. 11.28 was right not to bound it: a clock
  check on one column of one table is a new mechanism, and this project's record says
  new mechanisms are where findings come from.
  **But the residual is worth naming precisely, because it is not access — it is a
  sentence a permit report might quote.** The right fix, if it ever matters, is **not
  to validate the stated date but to stop losing the corroborating one**: the server
  already records when the record actually arrived, so display and export that
  alongside the stated date. Keep both values and do not reconcile them — the same
  shape as tag versions and for the same reason.
- **Nobody is told when somebody leaves. Accepted for now.** People can now leave
  without telling anyone, so an owner may find out only by looking at the members
  screen. Not tasked, and the reason is that there is no notification channel in this
  app at all — building one to carry this single event would be a new surface for a
  courtesy. **The condition that changes it: the first time any other feature needs
  to tell somebody something**, this joins it rather than justifying its own
  mechanism.

**One decision taken 2026-08-27, from task 11.38:**

- **The two-device walkthrough supports a Mac, and an Apple ID is an accepted
  prerequisite.** 11.38 asked whether the supported path should instead be two
  non-Mac devices, to avoid requiring an Apple account. **No — and the reason is
  11.38 itself.** Building any Apple app requires a signing identity; that is Apple's
  rule and not a defect in this project. Declaring two non-Mac devices as the
  supported path would mean the macOS build's sign-in is never exercised by the
  walkthrough, **which is exactly how sign-in on macOS stayed broken from Phase 5
  until somebody ran it by hand.** The option that keeps the test honest is the one
  that costs a prerequisite. Write the prerequisite at the top of the walkthrough,
  including that a free Apple ID expires the build after seven days.

**One acceptance recorded 2026-08-28 from task 11.47, with its reopen condition:**

- **Somebody who can already write to your project can now stamp a tag or session
  "last edited by" a colleague who is not on the project. Accepted, and the trade is
  the right way round.** What it buys an attacker is a false note about who touched a
  piece of shared vocabulary. What refusing it cost was **your own field data blocked
  from the server forever**, because a bearing referencing that tag could never be
  published. A certain, permanent harm to real observations against a cosmetic,
  forgeable line about a rename — take the trade.
- It discloses nothing (nothing about the named person is delivered to anybody as a
  result) and it cannot touch who **recorded** a measurement, which is what task
  11.24 protects and what Michael's provenance decision was about.
- **The condition that would reopen it: the day anything displays or exports "last
  edited by" as provenance in a scientific context**, that line becomes a false
  record rather than a cosmetic one. **This is the third acceptance of exactly this
  shape** — after the tag-creator forgery and the exclusion reference — each harmless
  only because nothing reads the value yet. If a fourth arrives, the pattern itself
  deserves a look rather than a fourth entry.
- The single line to revisit if the trade is ever judged wrong is
  `replicatesAForeignAuditName` in `mutation_rules.dart`.

**Two cells that read like gaps and are not, recorded so they are not
rediscovered:**

- **The device permits when it cannot resolve a role.** Every Unknown cell in
  this document. It is deliberate, stated in three places in the code, and it is
  what makes a restored phone work at all. §5.10 accepted the one thing it leaves
  open, task 11.9 attacked it again, and it held.
- **The members screen renders the member list to any caller who reaches its
  route**, gating only the controls. The member list is synced data every member
  already holds, so this is a tidiness issue at the screen layer, not a
  disclosure. A stranger cannot reach the route or the data.

---

## 9. Worked scenarios

***Hand-kept*** — narrative.

Tables state the rule. Scenarios are how you find out whether you believe it —
and for a document whose purpose is confidence, these may matter more than the
tables. Each ends with what each person sees, not with which rule fired.

**1. Two contributors record bearings on the same animal an hour apart, both
offline, and sync that evening.** Nothing collides. Each bearing is a separate
record with its own identifier and its own author, both are accepted, and both
devices end the evening holding both. The position estimate now has two more
rays. *Each sees: two bearings in the log, each with the other person's name on
theirs.*

**2. A contributor records three bearings on Tuesday, a second contributor
corrects one of them on Wednesday, and the first syncs on Friday.** The
correction is not an edit — a contributor cannot edit a colleague's bearing at
all. It is a new bearing plus a mark saying the old one is superseded by it. On
Friday the first contributor's device pulls both. Their original bearing is
still there, with their name and their numbers unchanged; the solver stops
counting it and counts the replacement instead. *The first sees: their bearing,
marked "Superseded by Sam", with Sam's reason if Sam gave one. Nothing of theirs
was destroyed or altered.*

**3. A viewer is sent a project file and imports it on their own phone.** If
their phone already knows they are a viewer of that project, the import is
refused before a single row is written, and the message names the rung they hold.
If their phone has been wiped and holds no membership rows, the import
**succeeds** — that is the residual §5.10 accepted, and the reason is that
refusing it would break every legitimate restore. What they end up with is a
private copy that diverges from the project; their rows are refused on the next
sync and nobody else ever sees them. *They see: either a refusal that says why,
or a working local copy that never syncs, with held records explained on the Sync
status screen.*

**4. A contributor is demoted to viewer while their phone is out of signal with
a day of unsynced records on it.** The demotion reaches them on the next sync.
From that moment their device refuses new writes — **including edits to the rows
they wrote themselves before the change**, because the role gradient is asked
before authorship. The day's records already on the phone are pushed and refused
one at a time, and held. *They see: the record controls disabled with "Viewers
cannot edit or delete observations — ask an owner to change your role", and a
count of held records on the Sync status screen, each explained. Nothing is lost;
nothing reaches the team.*

**5. A member is removed from one project and remains an owner of another.**
Removal ends their stint on the first project; the row stays as history rather
than being erased. They keep everything already on their phone — the removal
disclosure on the members screen says so in plain words before the owner
confirms it — and they get nothing further. Their standing in the second project
is untouched, including their right to edit tags that project uses. *They see:
the first project stops updating and its writes are refused; the second is
unchanged.*

**6. A phone is lost and replaced, and last season's archive is restored onto
the new one before the new owner has re-joined anything.** The restore works.
This is the case the whole Unknown column exists for: a wiped phone has no
membership rows, the rule abstains rather than refuse, and the archive is
applied. If this person really is the project's owner, their rows are accepted
the moment they sign in and sync. If they are only a viewer, the rows are refused
at the server and the copy stays private to that phone. *They see: their season's
data back, and — if they are not entitled to write it — a held-record count and
an explanation, rather than a silent failure.*

**7. Two people independently create a tag for the same collar on the same
frequency.** Both succeed. Each is warned at the moment of creation — "there is
already a tag on this frequency" — with "Go back" and "Create anyway", and
neither is refused, because two collars can legitimately share a nominal
frequency if they are never in range together. The project now has two tag
records for one animal. There is no merge tool; that is Phase 12. *They see: a
warning each, and afterwards two similar tags in the list.*

**8. An owner removes a tag from the project after a contributor has recorded
twenty bearings against it.** The link is deactivated, not deleted, and the
twenty bearings are untouched — they still name the tag and still carry their
data. The tag can be added back, by a contributor, and the link reactivates
rather than duplicating. *The contributor sees: the tag gone from the project's
tag list, their twenty bearings still in the log.* **And one thing they should
not be able to see:** if that contributor's device pushed the removal itself
rather than the owner's, the server would accept it — §8 entry 2.

**9. A contributor excludes a teammate's bearing, and the teammate re-runs the
position estimate.** **The contributor cannot.** Excluding is owner-only, on
their own bearings and everyone else's alike, at all three layers. What they can
do is supersede it with a corrected record, which takes the original out of the
estimate and puts something in its place. If an *owner* excludes it, the
teammate's re-run drops that ray. *The teammate sees: the bearing marked
"Excluded by Alex" with the reason, and an estimate computed without it. They can
ask an owner to put it back; they cannot do it themselves.*

**10. Somebody outside the project sends a shared observation by text message,
and a contributor pastes it in.** Pasting and decoding are unrestricted — that
is just reading a string. Saving it into the project is a write, and it is
checked: a contributor may, a viewer may not. What is saved is a faithful replica
carrying the original observer's identity, so the first time it syncs the server
usually refuses it, because that observer is not on the project. The record is
not lost — it is held, and the message says so: *"This record is safe on this
device and nothing has been lost. It is waiting because it names a person, or
uses a tag, that is not part of this project yet."* Once an owner adds that
person, "Try again" works. *They see: the record in their log immediately, and a
held-record note until the person it names joins.*

**11. A join code is written on a whiteboard, photographed by a visitor, and
used by somebody the owner never meant to let in.** **It works — and it grants
them nothing.** This scenario was rewritten by task 11.81 on 2026-08-31, and the
rewrite is the point: it used to say the code was bound to the invited mailbox
and a forwarded code failed. There is no address binding any more, on purpose.
What happens instead is that the visitor appears in the owner's pending list,
with the email address the server authenticated for them, and the owner taps
Reject. **The failure changed from *a stranger is on your project and can read
every collar location* to *a stranger is a line in your list*.** If the owner
would rather it stop happening at all, they rotate the code, which takes one
tap and does not disturb the people already waiting. *The visitor sees: "Waiting
for approval", and then that it was turned down. The owner sees: a request from
an address they do not recognize, and a name that person typed — labeled as
what that person says they are called, not as a fact.*

**12. A spreadsheet export is opened by a colleague who is not on the project.**
Nothing in TriTrack applies — the file left the app and §5.7 says plainly that
exported data is outside every control in this document. Two things are still
true and worth saying: the export carries every named person's prior email
addresses as well as the field data, and the file is written so that a tag name
beginning with a formula character cannot execute in the colleague's spreadsheet
program. *They see: the whole project, including contact history for everyone
named in it.*

---

## 10. N-1's siblings — the whole class, not the instance

***Hand-kept*** — a record of one sweep.

**N-1 is "a row may name a person other than the caller."** Task 11.9 found it by
asking that question once, of two tables. The standing rule on this project is to
fix the class rather than the instance, so this section asks it of **every column
in every synced table that identifies a person** — twelve tables at the time
this sweep ran, and every column named in their descriptors. **Task 11.32 has
since added a thirteenth**, `Tag_Versions`, whose only person-naming column is
the `last_modified_by` every table carries; the sweep's own conclusion below
therefore stands unchanged for it, but the count is corrected here rather than
left to rot, which is the drift task 11.21 found the hard way.

**The rule being tested** is §4.17: a row may not name a user other than the
caller unless real replication provenance backs the name. **The provenance clause
that N-1 exploits** is `row_authorizer.dart:844` — *this project already reaches
them*. Two properties of that clause are worth stating because neither is
written down anywhere:

- **The vouching set is computed with no filter for ended or deleted rows**
  (`project_reachability.dart:88`). Somebody who left the project a year ago is
  still permanently in it.
- **It is self-feeding.** Once a forged row names someone, that row itself puts
  them in the set.

### The sweep

***Hand-kept***.

| Column | Can a client name somebody else? | What constrains it | Insert / update | What is visibly false to a person |
| --- | --- | --- | --- | --- |
| `Observations.user_id` | **yes — this is N-1** | `row_authorizer.dart:844` permits any reachable person | insert only; update refused | A bearing in the Log and Team tabs, and in the position estimate's observer provenance, credited to someone who never took it |
| `Observation_Exclusions.user_id` | **yes — N-1's second arm** | same | insert only | "Superseded by" / "Excluded by" naming a colleague who made no such judgement |
| **`Non_Detections.user_id`** | **yes — the same defect, on a table nobody named** | same | insert only | "I listened here and heard nothing", credited to a colleague. Negative evidence is evidence; this is the same scientific-record harm as N-1 |
| `Observation_Exclusions.last_modified_by` **on update** | **yes, by a different route** | `row_authorizer.dart:837` permits a name that merely equals what is already stored | **update** | **"…then withdrawn by *name*"** in the Team log (`log_screen.dart:1319`) naming somebody who did not withdraw it. **An insert-only fix does not close this** |
| `last_modified_by` on the other nine non-authorization tables | yes | `row_authorizer.dart:844` | insert; update only if unchanged | Not rendered today except above. Feeds the conflict store and the diagnostics console |
| **`Tags.last_modified_by`** | yes — **and it is read back as a permission** | `row_authorizer.dart:1391` decides who may maintain an unclaimed tag by comparing this column | insert | A forged stamp on a new unclaimed tag hands maintenance of it to the named person and locks the forger out. This column is described in the code as "provenance that references nothing"; that is no longer true |
| `Users.user_id`, `Users.email`, `User_Emails.*` | **no** | the address claim must match one the server authenticated (§4.18), and address history is barred from the replication exemption outright | both | — |
| `Projects.owner_user_id`, `Projects.last_modified_by` | **no** | these are authorization state, which gets no exemption at all | both | — |
| `Project_Memberships.user_id`, `.last_modified_by` | **no — closed twice over** | authorization state, *and* a membership insert must name the caller, come from an owner, and not duplicate an open stint | both | — |
| Join-request records (`user_id`, `email`, `decided_by`) | **no** | written from the authenticated session, never from the request; the membership row at approval is authored by the server, from the request's own `project_id` and the role the owner chose | both | The one caller-supplied field on a request is `claimed_name`, which is **not** an authorship column: it is never written onto the `Users` row and never attributes anything. It is rendered to the owner as a claim, bounded exactly as `Users.first_name` is |

### Verdicts

***Hand-kept***.

**Closed by task 11.24 on 2026-08-22.** The sweep below is left as 11.23 wrote
it, because it is the evidence; what each verdict became is recorded here.

**Was genuinely open, and the same shape as N-1** — three tables, not two:
`Observations.user_id`, `Observation_Exclusions.user_id`, and
**`Non_Detections.user_id`**. **All three refused now**, and not because they
were listed: clause 2 no longer vouches for any table whose `MutationRule`
names an author, so a fourteenth table is covered the day its rule is declared.

**Was open, and *not* the same shape** — `Observation_Exclusions.
last_modified_by` on the update path, and `Tags.last_modified_by`, consumed as
an authorization input rather than as provenance. **The update path is closed
on every table**: an update must name the caller in the audit column, which was
the half 11.23 warned an insert-only fix would miss. `Tags.last_modified_by` is
closed on update and **still forgeable on insert**, deliberately and with the
reason recorded — refusing it would refuse the first publish of a project whose
tags a colleague created, and a held `Tags` row cascades into every observation
that references it. What a forged stamp on a *new unclaimed* tag buys is
maintenance of that tag by the person named, which is a nuisance and a
self-inflicted lockout rather than a false scientific record. Security Model
§19.6.

**Closed, and by what:** everything that is authorization state (projects,
memberships) is closed by the rule that replication does not apply to it;
everything about a person's identity or address is closed by the authenticated-
address rule; every update path but the one named above is closed by the
no-reattribution rule; and the join-request records are closed by being written
from the session rather than from the request.

**Not audited here, because they do not go through the server's row
authorization at all:** the pasted-share import and the picked-file restore.
Those are tasks 11.19 and 11.20's territory and have their own rules.

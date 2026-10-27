# TriTrack — Technical Context Document (Reconciled/Current)

**Purpose:** Cross-platform Flutter mobile app (iOS + Android, developed on Mac) for field wildlife VHF radio telemetry. Built for offline field use by wildlife researchers performing triangulation-based localization. Development via Claude Code. No app store deployment planned initially.

**App naming:** The app was designed under the working name "Tri Track" (two words); it has been standardized on "TriTrack" (one word, no space) everywhere it's user-visible — app title, iOS `CFBundleDisplayName`, Android `android:label`, README — and the Dart package itself was also renamed (`pubspec.yaml: name: tritrack`) rather than kept as an internal exception.

---

## Global Data Conventions (apply to ALL tables)

These conventions exist so the Phase 1 local database can sync cleanly in Phase 2/3 without a painful migration. Build them in now, before any real data exists.

- **Timestamps:** every table stores `timestamp_local` + `timestamp_utc` + `timezone_offset` where a time is recorded. Times shown in the UI are local; UTC is authoritative in the data.
- **Sync/merge fields on every table:** `created_at`, `updated_at` (both UTC), `deleted_at` (UTC, nullable — **soft delete only**, no hard deletes anywhere), `revision` (integer, incremented on each edit, for last-write-wins/conflict detection), `last_modified_by` (user_id), `origin_device_id` (text).
- **No hard deletes:** a hard delete on one device would "resurrect" on the next merge. Everything is soft-deleted via `deleted_at`; queries filter `deleted_at IS NULL` by default. **Two exceptions, each because there is no merge for the row to resurrect in:** the superseded `Users` row in identity adoption (Security Model §4.20), and, since task 11.339, *Delete permanently…* on a project in the Projects Trash that this phone does not sync (`ProjectTrash.deletePermanently`; `PERMISSIONS_MATRIX.md` P8).
- **Schema versioning:** set SQLite `PRAGMA user_version` and store a `schema_version` in the backup archive so older backups can be migrated forward on restore.
- **[Note for Claude Code — critical]** SQLite has foreign keys **OFF by default**. Run `PRAGMA foreign_keys = ON` on every connection or referential integrity is not enforced.
- **User identity across devices:** the same person will have a different `user_id` on two devices. Treat **email** (normalized, lowercased) as the cross-device identity anchor for dedup on import/merge.
- **Indexes:** create indexes on `project_id`, `tag_id`, and timestamp columns on the high-volume tables (Observations, Non_Detections, Estimated_Positions) from the start.

---

## The canonical column set (shared between app and server)

**Added by task 10.5 (2026-08-01).**

`packages/tritrack_sync/lib/src/table_columns.dart` declares `tableSpecs` — every
table's columns, types, nullability, and primary key — and it is the single
authority both schemas are checked against.

Why a declaration rather than shared DDL: the app writes SQLite and the server
writes Postgres, so the DDL *strings* genuinely cannot be shared, and the app's
shipped migrations must never be edited. So the two schemas are separate code
that must describe the same thing. `tableSpecs` is what makes that checkable:

- **App side:** `test/data/schema_matches_shared_spec_test.dart` runs the real
  migrations and compares `PRAGMA table_info` against `tableSpecs` — names,
  order, types, nullability, primary keys.
- **Server side:** the Postgres DDL is *generated* from `tableSpecs`
  (`server/lib/src/schema/postgres_schema.dart`), and
  `server/test/schema/postgres_schema_test.dart` checks the generated output
  against the same declaration.

**Adding a column** therefore means: append it to `tableSpecs`, add a migration
on *both* sides, and bump `latestSchemaVersion` (the *minor* — leave
`schemaMajorVersion` alone; see "Version skew" below for what a major bump costs
and the five standing rules that keep it unnecessary). Skipping any of the three
fails a test rather than silently diverging.

One deliberate asymmetry: **primary keys are NOT NULL in the shared spec even
though SQLite doesn't enforce that.** A bare `TEXT PRIMARY KEY` in SQLite really
does accept NULL (only `INTEGER PRIMARY KEY`, the rowid alias, is implicitly NOT
NULL). The spec takes Postgres's stricter reading, since a NULL primary key is
meaningless in both and only SQLite's leniency permits it.

---

## Server sync clock: `server_seq`, and clock discipline

**Added by task 10.5 (2026-08-01).** Read this alongside the last-write-wins
rule above — the two are separate mechanisms and conflating them is the main way
this goes wrong.

### `server_seq` does not decide who wins

`revision` → `updated_at` → `origin_device_id` decide **which row wins**, via the
one shared `MergeResolver`. `server_seq` answers only **"in what order did the
server learn about this row"** — which is what a delta cursor requires and what
`updated_at` cannot provide, because `updated_at` comes from devices whose clocks
disagree.

The server's merge path (`server/lib/src/sync/row_merge.dart`) *calls* the shared
`MergeResolver`. It must keep doing so. Expressing the comparison as SQL
(`WHERE incoming.revision > existing.revision OR (…)`) is the tempting version
and is forbidden: it would be a second implementation of the merge rule, and a
client and server that disagree about who wins produce split-brain — two devices
converging on different states depending on which one synced through the server.
Preventing exactly that is why `packages/tritrack_sync` exists.

### `server_seq` is not a row identity — it changes

Every accepted write to a row, insert **or** update, assigns a fresh higher
value. That is what makes a changed row redeliverable to devices whose cursor
predates the change. Corollary: a merge that *skips* (the server's copy already
won) must **not** bump `server_seq`, or an unchanged row is redelivered to every
other device forever.

### It is nullable, and nothing client-side may require it

Phase 10's invariant 3. `server_seq`, `received_at`, and `clock_skew_flag` are
server-only and deliberately **absent from `tableSpecs`**, so no client code can
reference them even by accident, and a device that has never synced writes rows
normally. Tests on both sides assert this.

### Why a locked counter row and not a Postgres `SEQUENCE`

This is the subtlest decision in the task and the one most likely to be
"optimised" back into a bug, so the reasoning is recorded in full in
`postgres_schema.dart`'s `createSyncSeqCounter`. In short: `nextval()` does not
lock, so sequence values are handed out in *request* order while transactions
commit in an unrelated order. That silently loses rows:

1. Transaction A takes `server_seq = 100`; B takes `101`.
2. B commits first; A is still open.
3. A client pulls, sees `101`, advances its cursor to `101`.
4. A commits, writing row `100`.
5. That client asks for `> 101` forever. **Row 100 is never delivered to it.**

No error, no conflict — just an observation that quietly never arrives on one
device. `UPDATE sync_seq_counter SET next_value = next_value + n RETURNING
next_value` takes a row-level write lock held until commit, so a transaction
cannot obtain a higher value until the holder of a lower one has committed.
Assignment order therefore equals commit order, and a reader that can see
sequence *n* can see everything below it.

The cost is that accepted writes serialise on that row. At this application's
scale — a handful of field devices — that is irrelevant, and the field record's
correctness is not a fair trade for throughput we don't need. If it ever
genuinely becomes a bottleneck the fix is a commit-ordered alternative (e.g.
`pg_current_snapshot()`-based cursors), a deliberate redesign with its own
tests — **not** a swap to a bare sequence.

### Client timestamps stay `TEXT` in Postgres

`created_at`/`updated_at`/`deleted_at` and the domain-time triples are stored as
`TEXT`, not `TIMESTAMPTZ`. `MergeResolver` compares `updated_at` values that
originated on devices, and `DbCodec` defines their exact encoding; storing them
as a Postgres timestamp would re-render them on the way out, so a row could come
back byte-different from how a peer wrote it — breaking the tie-break *and*
convergence with peers that never saw the server. The server stores what the
device wrote, verbatim. `received_at` is the one genuinely server-generated
timestamp, so it is a real `TIMESTAMPTZ`.

### Clock discipline: detect and record, never correct

The server records `received_at` (its own clock) next to every row and
classifies the client's `updated_at` against it
(`server/lib/src/sync/clock_skew.dart`). It **never rewrites** `updated_at`.
That timestamp is part of the field record — it says when a biologist actually
edited an observation — and it is a tie-break input that peers which never saw
the server will compare against. Silently "correcting" it would destroy the
record's own history and make two devices converge differently depending on
whether their data passed through the server. Correcting a skewed timestamp is a
deliberate, visible decision for a human; 10.13 surfaces the flags.

Three flags, and one deliberate non-flag:

| Flag | Trigger | Why |
| --- | --- | --- |
| `future` | `updated_at` > `received_at` + 5 min | A device cannot have edited a row later than the server received it. |
| `implausible_past` | `updated_at` before 2020 | The dead-battery case: a phone that comes back believing it is 1970. |
| `updated_before_created` | `updated_at` < that row's `created_at` | Internally impossible for a well-behaved client. |

**"Old" is deliberately not a fault.** The obvious reading — flag rows "far older
than the sync that carried them" — cannot be implemented as a relative-age check,
because that is exactly what a legitimate offline backlog looks like: a device
off-network for a full field season pushes rows genuinely weeks old. Flagging
those would mean flagging normal field use, and a flag that fires constantly is
one that gets ignored. The real "far older" fault is a *reset clock*, which an
absolute floor catches and a relative check cannot distinguish from a long trip.

The 5-minute future tolerance is chosen the same way: an NTP-synced phone is
within seconds and request latency is sub-second, so five minutes ahead is
genuinely anomalous, while a 30-second window would flag every mildly-drifted
device.

`clock_skew_flag` is stored denormalized (rather than recomputed on read) so the
diagnostics console's "show me the skewed rows" is an indexed query, and because
it records what the server concluded *at the time* — which is what an audit
wants even if the rule is later tightened.

### The sync wire protocol (task 10.7)

Declared once in `packages/tritrack_sync/lib/src/sync_protocol.dart` so client
and server cannot disagree about it. Three messages, all POST JSON:
`/sync/push`, `/sync/pull`, `/sync/ack`.

**Envelope.** Every message carries `envelope` (`tritrack_sync`, a stable
marker following task 6.2's `TT1:` precedent), `protocol_version`, and
`schema_version`. The last two are **separate on purpose**: the schema version
says what columns a row has, the protocol version says what the envelope looks
like, and they move for different reasons — adding a column must not force a
protocol break. Identity is checked before version so an unrelated payload is
reported as "not a sync envelope" rather than as a version problem. A version
mismatch throws a distinct exception so task 10.11 can answer "update to sync"
rather than surfacing a parse error.

**Cursors are keyed on `(user_id, device_id, project_id)`. Never on user
alone.** This is the single most important detail in the protocol. With a
per-user cursor, one device's sync advances the shared position past rows
another device never received, and that device is then never offered them
again: it asks for `server_seq > n` forever while the rows below `n` it never
saw simply do not come. Nothing errors, nothing retries — an observation is
just missing on one device, discovered months later if at all. Project id is in
the key too, because pulls are project-scoped for authorization and a user
belongs to many projects.

**The client's cursor decides delivery; the server's stored copy is
bookkeeping.** The server records a cursor per `(user, device, project)` in
`sync_cursors`, but only ever as a *record* — for the diagnostics device
registry (10.13) and task 10.11's tombstone-retention check. What a device is
*sent* is decided by the cursor in its own request. If the stored copy were
authoritative, a client that crashed after the server advanced it but before
committing the batch locally would never be offered those rows again, which is
the same silent loss from the other direction. The client knows what it
committed; the server only knows what it sent. Acknowledgement is monotonic
(`GREATEST`), because retried acks arrive out of order on a flaky link.

**Every push and pull response names the database that answered (task
11.58).** A cursor is a position in one database's `server_seq` line, and a row
receipt says one database holds a row; until this field neither said which. A
server restored from a backup or rebuilt therefore got asked "anything after
4,812?" by every device, answered "nothing" from a line that now stops lower,
and was reported as a clean sync — while every receipt minted against the old
database kept its row off the new one's push, for good. The server mints
`database_id` once (`server_database_identity`, ensured on every start) and
**a restore does not carry it across**: `backup.sh` dumps the table without
its row and `restore.sh` empties it, so the restored database mints a new one
on its next start. The app keeps the value beside the cursor
(`SyncStateStore.databaseId`); on a response naming a different one it resets
the cursor to zero, forgets the project's receipts, releases its holds, and
runs the round again from the top — `resetIfServerDatabaseChanged` in
`lib/data/sync/server_database_check.dart`. A second change inside that
restarted round is two databases at one address, and fails as
`SyncFailureCause.serverDatabaseChanged`. **Additive, so task 10.18's guarantee
holds and no version moves:** an older app ignores the field, and a newer app
reads its absence as "this server cannot say" and concludes nothing. **Two
blind spots, stated rather than assumed away:** a device's first round after
updating adopts whatever answers (it has nothing to compare with), and a
restore that copies the whole disk — a VM snapshot rolled back — brings the old
identifier back with everything else.

**Ack is a separate message, and that separation is the resumability story.**
The server must not treat "sent" as "stored". A sync that dies between
receiving a page and committing it re-receives that page — harmless, because
the merge is idempotent — whereas advancing on send would lose it silently.

**Chunking is sized for the first sync, not the steady state.**
`defaultSyncBatchSize` is 500 rows; `maxSyncBatchSize` (2000) is the ceiling the
server enforces regardless of what a client asks for, since an unbounded
request is a memory-exhaustion primitive. A client may request *less* — a phone
on a bad link reasonably might. Pull responses carry `remaining` so 10.12 can
show real progress ("batch 3 of 40") instead of an indeterminate spinner, which
is the difference between a field tech waiting confidently and force-quitting.

**Push outcomes are reported per row**, including `lost_to_server`. A merge that
silently discards the loser leaves nothing to answer "my observation
disappeared" with — the bug that actually gets reported. 10.12 turns these into
a user-visible record; 10.13 shows them to a developer.

**The server merges with the shared `MergeResolver`.** `SyncService.applyPush`
reads each row, compares in Dart, and writes. Expressing this as one clever
`INSERT … ON CONFLICT … WHERE incoming.revision > …` is faster and is
forbidden: it would be a second implementation of the merge rule, and a client
and server that disagree about who wins produce split-brain. A `skip` decision
deliberately does **not** bump `server_seq` — bumping on a no-op would
redeliver an unchanged row to every other device forever.

**Server-only columns never cross the wire.** `server_seq`, `received_at`, and
`clock_skew_flag` are stripped from pull responses; a client that stored them
would depend on columns Phase 10's invariant 3 forbids it from requiring.

**Unknown tables in a payload are ignored, not rejected**, matching
`BackupArchive.decode`'s forward compatibility — a newer peer that gained a
table must not make an older one fail outright. Deliberate version refusal is
10.11's policy, not a parse error.

### Version skew: same major syncs, different major refuses (tasks 10.11, 10.18)

**The schema version is two parts.** `schemaMajorVersion` is the compatibility
boundary; `latestSchemaVersion` is the minor, and is also the migration counter,
so it is monotonic and never resets — a minor keeps climbing across a major bump.
Both ride in every envelope (`schema_major`, `schema_version`) and are checked in
`SyncEnvelope.fromJson`, so every request and every response passes through the
check and no endpoint can forget it.

**Same major syncs, whatever the minors. Different major is refused.**

#### Why this is not the naive relaxation

Task 10.11 originally required exact equality on a single integer, and the
argument it made against relaxing was correct as far as it went: server at minor
6 with a new `Observations` column, client at minor 5 that has never heard of it.
The client pulls the row and **drops the column it cannot store**, the user edits
the notes, the client pushes the row back, and row-level last-write-wins writes
the whole row with the new column now empty. A value another device contributed,
destroyed silently by a client behaving exactly as designed.

What that reasoning missed is that the drop is a choice, not a consequence. **An
older build can hold what it does not recognize and hand it back untouched.**
Incoming columns with no local home are split off into a client-only holding
table (`UnknownColumnStore`) keyed by table + primary key + column name, stored
as their JSON encoding, and re-attached to the row on the way back out — on
push, and in backups. The row that leaves is byte-identical to the row that
arrived, in the parts this build could not read. Column-level merge is still a
different engine and is still not what this is; the merge model did not change at
all. The row simply stayed whole while passing through.

When an upgrade later declares the column, a generic promotion pass (run on every
database open) moves each held value into place and forgets it. It is written
once against `tableSpecs`, so every future addition is covered without anyone
writing a step for it.

#### Why this had to exist before the first release

**The protection lives on the older side.** A build shipped without unknown-value
preservation cannot be made compatible retroactively — bumping the schema still
strands it. Whatever version first ships this is the permanent compatibility
floor. Building it before deployment was nearly free; after deployment the gap
would have been permanent for every device already in the field.

#### What a minor can and cannot cover

Of nine kinds of schema change, three are safe under preservation and six are
not. Only the first three may bump the minor.

| Change | Old app still works | Why |
|---|---|---|
| Add optional column | **Yes** | Preserved verbatim, echoed back intact |
| Add column with default | **Yes** | Rows it creates take the default |
| Add a table | **Yes** | Ignores it; server keeps its own copy |
| Delete a column | No | Keeps showing and re-sending something retired |
| Rename a column | No | Both versions maintain the same fact separately |
| Change a column's type | No | Sends the wrong type |
| Same name, new meaning | No | **Undetectable** — both sides accept it |
| Delete a table | No | Re-uploads removed rows |
| Tighten a validation rule | No | Previously-legal rows rejected unexplained |

#### Standing rules for schema evolution

These matter more than the machinery above. Follow them and a major bump — which
strands every device in the field until it updates — almost never becomes
necessary.

1. **Prefer adding to changing.** To retire a column: add the replacement, stop
   writing the old one, leave it in place. An unused nullable column costs a few
   bytes; a major bump costs every device in the field.
2. **Never reuse a column name for a different meaning.** This is the only change
   no software can detect — both versions accept every value and the data is
   silently wrong. If the meaning changes, the name changes.
3. **A major bump is a last resort and requires written justification** in
   `DEVELOPMENT_PLAN.md` naming what was tried instead.
4. **Never edit a shipped migration.** (Also documented in `migrations.dart`;
   restated here because it belongs with the others.)
5. **Release order: server first, app second. Always.** Schedule any major bump
   for a quiet period — noting that field seasons vary by species and hemisphere,
   so "quiet" is not universal and shrinks as the user base grows.

**Bumps so far: five.** Major 2 (schema v6, task 10.35, 2026-08-13) — primary
keys became project-scoped; justification, and what was tried instead, in
`TriTrack_Security_Model.md` §4.13 and task 10.35's plan entry. Major 3 (schema
v14, task 11.219, 2026-09-10) — tags became project-scoped; `TAG_COPY_ON_ADD_DESIGN.md`.
Major 4 (schema v16, task 11.242, 2026-09-13) — `Tags.color_hex` lost `NOT NULL`
under task 11.240 without the major moving, and a v15 device handed a v16 row
refused it at its own database and never synced again; the bump makes that
device refuse instead. **Major 5 (schema v17, task 11.243, 2026-09-13) — the first spent on a
deletion**: `Tags` loses `date_put_on`, `date_removed`, `capture_date` and `individual_id`, and
`Deployments` arrives to hold the link with its dates
(`CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md`). Three of the nine kinds in one bump, any one of
which would require it on its own: four columns deleted, one of them `NOT NULL`, plus a new table.
**Nothing was tried instead and that is the honest answer** — there is no expression of *"the dates
belong to the link"* that leaves `Tags` alone, and keeping the columns and writing them null is the
two-sources-of-truth this schema has refused twice. What the design considered and withdrew was the
alternative *model* (a second `Tags` row per redeployment), which makes the equipment inventory
report two collars where the project owns one.

**Major 6 (schema v19, task 11.323, 2026-10-06)** — `Estimated_Positions.semi_major_axis`,
`semi_minor_axis` and `rotation_angle` lose `NOT NULL`; the three empty together mean *no ellipse*.
A two-bearing estimate has no ellipse (two bearings cross exactly, so there is no scatter to
measure), and the app wrote it as 0 × 0 m — a perfectly precise position, which the server then
refused because an axis must be greater than zero, so the estimate never synced. The same kind of
change as major 4. **Tried instead:** a positive placeholder (an invented measurement a major-5
device would draw as real — rule 2); new nullable columns beside these (the old ones would still need
a placeholder); and not letting a two-bearing estimate be saved, which needs no bump and which
Michael declined on 2026-10-06. Full argument on `schemaMajorVersion`.

**Schema v20 (task 11.331, 2026-10-10) is a minor, inside major 6** — `Projects.time_zone` and
`Deployments.time_zone`, both nullable IANA names: the field site's zone, and the zone each
deployment row's days were written in. A bare deployment day is now the start of that day in the
row's zone (`field_time_zone.dart`, `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §4c). **Old and new
builds:** a v19 app sends no zone, and the server stores null and reads the row's ends as instants,
as it always has; a v20 app reads a zoneless row in the phone's own zone, as v19 did; a v19 app holds
the zone column it does not know untouched (`UnknownColumnStore`). A v20 app pushing to a v19 server
loses the zone silently (that server has no column for it) — the standing release order, server
first, avoids it. **Standing rule 2 was checked:** `attached_date` keeps its meaning (a UTC instant);
what a bare day's instant is midnight *of* is now said by the new column, rather than by which phone
wrote it.

> **Four of the five majors have now been spent inside the same window, for the same reason: one
> device, no field season.** That window is an asset and it is being consumed. Rule 3 above says a
> bump is a last resort; what has actually made each one cheap is *timing*, not restraint, and the
> day a beta team installs, every argument on this page gets more expensive rather than less.

Every bump's justification is also on `schemaMajorVersion`
itself, and the history is data: `schemaMajorFirstMinor` in `schema_constants.dart`,
which the backup scripts are checked against.

#### What speaks the wire and is not the app (added 2026-09-13, after task 11.242)

**Task 11.219 bumped the major on 2026-09-10 and the backup pipeline went on labelling every
archive of the beta server "schema major 2" for three days** — in the cleartext sidecar **and in the
signed comment `restore.sh` trusts.** Nobody reported it; task 11.242 found it while doing something
else. **The lesson is not "remember the backup scripts". It is that nobody had ever written down
what else speaks this wire**, so a bump had no checklist to fail.

**Measured 2026-09-13** — files outside `lib/` and `packages/` that name the major:

| Where | What it is | Now checked by |
| --- | --- | --- |
| `server/backup/backup.sh`, `restore.sh`, `scripts/backup_restore_drill.sh` | The archive's stated major, in the sidecar **and the signed comment** | a server-suite group reading `schemaMajorFirstMinor` (task 11.242) |
| `scripts/gate_wire.py` and the instruments importing it | The gate's own envelopes | reads `schemaMajorVersion` **from source** — needs no bump |
| `scripts/verify_h6_archive_forgery.sh`, `gate_c_adversarial_pass.py` | Adversarial probes that build envelopes | the gate run itself |
| `.github/workflows/gate-instruments.yml` | Arranges the above | — |
| `server/lib/**`, `server/test/**` | The other side of the wire | the server suite |

> **Re-derived at the major 5 bump (task 11.243, 2026-09-13): the list found nothing new, and
> that is the result that proves it works.** The grep below returned 21 files; three are not in the
> table above (`scripts/gate_smoke_test.sh`, `verify_round8_server_surface.py`,
> `verify_h3_existence_oracle_sweep.py`) and **none of them needed a bump** —
> `gate_smoke_test.sh` only does arithmetic on whatever `gate_wire.py` read, `verify_h3` mentions
> the word in prose, and `verify_round8`'s literal is a **deliberately malformed value** (a string
> where an integer belongs), which is refused whatever number it spells. The two files that did
> need editing — `backup.sh`'s threshold chain and `restore.sh`'s `SCHEMA_MAX` — were both already
> in the table *and* already held to the constant by `shipped_defaults_test.dart`, so the change
> could not have been forgotten. **The remaining hand-typed `schema_major=2` literals are in
> `verify_h6_archive_forgery.sh`'s forged sidecars**; they are archives an attacker fabricates and
> need no bump, because `restore.sh` supports majors 1 through 6 and the drill is about the
> signature rather than the number. Left as they are on purpose, and written down here so the next
> bump does not re-derive the same conclusion.
>
> **Re-derived at the major 6 bump (task 11.323, 2026-10-06): the same 21 files, nothing new.**
> The only edits were again `backup.sh`'s threshold chain and `restore.sh`'s `SCHEMA_MAX`; the only
> hand-typed majors left are the forged and too-far archives described above.

> **Do not trust this table alone — it is a hand-maintained list, and this project's oldest rule is
> that one is already wrong.** It is here to say *the class exists*. **Re-derive it before any major
> bump** with the grep that produced it:
>
> ```
> grep -rln "schema_major\|schemaMajor\|SCHEMA_MAJOR\|schema major" \
>   --include=*.sh --include=*.py --include=*.yml --include=*.dart \
>   scripts/ server/ integration_test/ tool/ .github/
> ```
>
> **The right answer is for each of these to read the constant rather than repeat it**, the way
> `gate_wire.py` already does — **and every one that does drops off this list permanently.** Prefer
> that to updating the table.

**The nine-kinds table above is now enforced, not only read.** Since task
11.242 the wire's shape is *frozen* when a major begins
(`packages/tritrack_sync/lib/src/wire_shape_freezes.dart`, written by
`tool/freeze_wire_shape.dart`), and `assertWireShapeCompatibleWithMajor` fails
the app suite, the package suite and the server suite on any later change a
device on the current major cannot survive — a column deleted, retyped, losing
or gaining `NOT NULL`, joining or leaving the key, a bound tightened, a new
`NOT NULL` column, a table removed. The failure names the remedy: undo it, or
bump the major and freeze again. **What it cannot see is written on that file:**
a name reused for a new meaning (undetectable by construction — rule 2 is the
only defense) and the closed enum sets `RowValidator` keeps in its own `switch`.
Two things the first bump established that every later one inherits:

- **A backup archive is not held to the wire's rule.** `SchemaMigrator`
  migrates an older major forward; only the wire refuses outright. The wire
  refuses because two live peers must agree on a shape neither controls,
  whereas reading an archive is one-way and the reader knows strictly more. It
  is safe *only* while the crossing is lossless, so `_lowestMigratableMajor`
  is an explicit constant: a future major that cannot cross losslessly must
  raise it rather than inherit the exemption.
- **Anything outside the app that speaks the wire needs updating in the same
  change.** The `scripts/verify_*.py` gate tools embed the envelope, and a
  bump refuses them with a `409` until they are updated — which reads as a
  broken tool rather than a version skew if you are not expecting it.

#### The refusal itself

A major mismatch names **which side is behind**, because "update the app" and
"update the server" are instructions to different people and guessing wrong sends
a field tech chasing an update that does not exist.
`SyncSchemaVersionException` keeps both sides' major and minor separate for this;
the server returns `409 {"error": "schema_version_mismatch",
"client_schema_major": …, "server_schema_major": …, "client_schema_version": …,
"server_schema_version": …}` and the client picks its own copy from a fixed
vocabulary of refusal codes — no server-supplied text ever reaches the UI
(§4.13). Direction is decided on the major, since the minor can move in the
opposite direction across a bump.

**The cost of a major bump is real and is accepted:** every device must update
before it can sync again, including one holding a season of unsynced
observations. That data is not lost — it sits on the device until the app is
updated — but it is stuck.

**Server-side preservation is deliberately out of scope.** Rule 5 makes the
server upgrade first, so the app is never ahead of it in practice, and the server
writes only the columns its `tableSpecs` declares. If that release order ever
changes, or if anyone other than this project self-hosts a server, the server
needs its own holding area too.

`protocol_version` is checked first and requires exact equality. A payload wrong
on both counts is reported as a protocol problem: the schema number inside a
shape this build cannot parse is not meaningful. An envelope with no
`schema_major` at all is a protocol error rather than an assumed major — guessing
would bypass the one gate that decides compatibility.

**Unknown tables are ignored, not refused** (`decodeRows`), and the pull loop
advances on the server's `next_cursor` rather than on how many rows it could
decode. Data safety was never the risk there — the app never had those rows — but
stopping on a page that decoded to nothing would park the cursor permanently:
sync dead, no error, nothing to notice.

### Tombstone retention: 24 months, and why refusal is the recovery (task 10.11)

Deletes propagate as tombstones (`deleted_at`), and without purging both server
and clients grow without bound. Purging creates the resurrection bug: a device
offline longer than the window never saw the delete, still holds the row live,
and pushes it back as an insert because the server no longer has a tombstone to
compare against.

**The window is 24 months** (`tombstoneRetention`), sized against the field
scenario rather than storage: last synced early in season one, shelved over the
off-season, brought back late in season two is roughly eighteen months, and a
late season or a missed year pushes past it. The number is chosen by asymmetry,
not precision — too short corrupts data silently, too long wastes kilobytes at a
data scale where deletes are the rare correction of a mis-recorded observation.

**The age is measured on the server's own clock — when *this server* accepted the
delete — never on the phone's deletion stamp** (task 11.291, 2026-09-21, which was
the first task to actually run this sweep). The distinction is not pedantry: a
record a phone deleted in 2023 and uploaded in 2026 is three years old by its own
stamp and purgeable on a first sweep, while no device has ever had a chance to
learn of the delete. On the server's receipt it is kept 24 months from upload,
which costs kilobytes and cannot strand anybody. **A consequence worth stating
because it is reassuring rather than alarming: on a server whose code did not
exist before August 2026, the first sweep that can purge anything at all is in
August 2028.**

**Purging is additionally held back by every device that has synced inside the
window**, at the lowest such device's acknowledged position. Age alone is not
sufficient: a device syncing weekly is entirely current and may still sit below
a three-year-old tombstone if it joined recently. This is what makes hard
refusal defensible — a device that keeps syncing can never be stranded, so the
devices that trip the guard are exactly those that have been gone longer than
the window.

**That sentence was not true until task 11.291, and the reason is worth keeping.**
The holdback reads `sync_cursors`, and the only writer of that table was
`/sync/ack` — which the app sends **only after a pull that moved**. So a project's
publisher, and every device on a project where nothing changes, had no row there at
all: invisible to the holdback, and refused on the first push after anything in
their project was purged, with the app telling a phone that had synced every week
that it had been offline too long. `/sync/pull` now records the position a device
pulls from. **A holdback that reads a table only some of the protected population
appears in is a holdback for the population that appears in it**, and nothing said
so for a year because the sweep never ran.

**The guard is on push as well as pull, and push is the one that matters.**
Push is where resurrection happens. A retention check on pull alone would leave
the whole hole open. Push has no cursor of its own, so it is checked against
`sync_cursors.acknowledged_seq`; pull is checked against the cursor in the
request. A cursor of **zero is never stale** — that is a full re-pull asking for
current state rather than claiming to hold it, and refusing it would break
`ProjectJoiner` on exactly the old projects a new device most needs to join.

The floor is **per project** (`tombstone_purge_floor`), not global. `server_seq`
comes from one counter shared by every project, so a global floor would be set
by the busiest project and would refuse devices on quiet ones whose cursors are
legitimately low.

**A refused device is not automatically recovered, and this is deliberate.**
The plan originally specified "refuse the incremental sync and require a full
re-pull". A full re-pull does not fix it: `ProjectMerger` only upserts rows
present in the payload and never deletes local rows the server omitted, so the
purged row survives locally and the next push resurrects it exactly as before.
Absence is not a signal. The alternative — after re-pulling, delete any local
row the server did not send and this device did not originate — deletes real
field data on a heuristic that becomes unreliable after an identity remap, which
is a worse failure than being stuck.

So the device is refused, terminally, with an explanation, and reconciliation is
left to a deliberate human-visible act. Resurrection is fundamentally
unpreventable once the tombstone is gone; what is achievable is refusing to do
it silently. The recovery flow itself is unbuilt — see the plan's Discovered
Scope.

**Global tables are not purged.** `Users`, `User_Emails`, and `Tags` have no
`project_id`, so neither a per-project floor nor a per-project cursor applies,
and their tombstone volume is negligible. Purging them safely needs a different
scheme.

### Deferrable foreign keys

The Postgres schema's foreign keys are all `DEFERRABLE INITIALLY DEFERRED`,
checked at commit rather than per statement. A sync push legitimately arrives as
a batch whose rows reference each other, and requiring a particular insert order
would make correctness depend on iteration order up in the protocol layer.
Deferred checks keep the integrity guarantee while making intra-transaction
ordering a non-issue. `last_modified_by` remains deliberately un-keyed on both
sides — a merged row may reference a user row that hasn't synced yet.

---

## Standing rule: an order that is safe for foreign keys is not automatically safe for authorization

**Added 2026-09-01, from task 11.43, and it cost a beta-blocking defect to learn.**

`Tables.all` is one ordering used in three different jobs. It had been reasoned about twice —
**merge order on the client, and the order the server judges a single push in** — and both
readings were correct. **The third use was never named: the order in which the publisher sends
its tables as *separate HTTP requests*.**

That is where it was wrong. The publisher sent a tag's version history **one request before**
the row that tells the server the tag belongs to the project — so the server, judging that
request on its own, **had no way to know the history was legitimate and refused it.** Every
first publish showed a red banner asking the person to report a bug.

> **A foreign-key-safe order guarantees that a parent exists before a child references it. It
> guarantees nothing about whether the server can yet *authorize* the child** — because
> authorization depends on what the server has been told, and across separate requests it has
> been told less than the client knows. **The link that vouches for a row must arrive before the
> row it vouches for, which is not the same constraint and can be the opposite one.**

**So: whenever an ordering is reused, name the job.** If a constant is correct for two purposes
and is reached for a third, **that third use needs its own argument, not an inheritance.** The
rule is written into `packages/tritrack_sync/lib/src/offer_order.dart` and enforced by a test.

## Standing fact: how far a VHF tag is actually heard (Michael, 2026-09-02)

**Trackers Michael knows report picking up tags at around 35 km** — in good conditions, from
elevation, a mountain top down into a valley. Ordinary ground-to-ground working range is far
shorter; this is the tail, not the median.

**Why it is written down here rather than in one task.** Two constants in this repository are
answers to this same question, and **until 2026-09-02 both came from reasoning rather than from
anybody who had tracked a collar**: task 11.131's maximum drag length (chosen as 20 km from
equipment specifications, and flagged by its own author as *"the number I could defend, not one
measured here"*), and `ViewshedConfig.maxRangeMeters`, hard-coded at 10 km. **Michael set the
drag cap at 40 km; task 11.87 (2026-09-02) applied that and set `maxRangeMeters` to 35 km — the
field figure itself, not the drag cap's padded 40 km, since the drag control is a display bound
with its own built-in margin and the viewshed is an actual physical prediction.**

**The rule this leaves:** any bound on *how far a signal reaches* is a field question, and a
figure derived from a datasheet should be marked as provisional until somebody who has done the
work says otherwise. **A number that looks tidy is usually a number nobody measured.**

## Standing fact: Docker restart policies do not act on health (measured 2026-09-02, task 11.128)

**`restart: unless-stopped` reacts to a container *exiting*. It does not read the health check
at all.** Acting on health is a Swarm and Kubernetes behavior, and this stack is neither.
**Measured:** a container forced unhealthy sat at `Up (unhealthy)` for as long as it was
watched — same process id, restart count still zero.

**So a health check in this project buys visibility, not recovery**, and any plan that assumes
an unhealthy container will be restarted is wrong. Task 11.128 wrote the opposite claim into a
Discovered Scope entry three hours before building the thing that disproved it, and corrected
it in place — **an assumption about a mechanism nobody had run**, which is the shape the task
it belonged to existed to find.

**Consequence worth stating once:** `/health` on this server answers for the process,
`/ready` answers for the job. **A `(healthy)` container is not a working server** — a server
that cannot reach its database reports healthy, deliberately, because "unhealthy" is the label
a restart would hang off and no restart can reach a database that is down.

## Phase Structure

### Phase One (MVP — Core Field Tool)
- Tag database with VHF frequencies, names, bulk CSV import
- Observation logging: bearings, omnidirectional detections, non-detections (and, per current direction, Note and No-Signal record types — see Open Work)
- Offline maps: terrain, street, satellite tile downloads + DEM elevation data, with a dedicated download/delete management interface (polygon/rectangle area selection, visible coverage extent)
- Biangulation/triangulation via Lenth MLE with uncertainty ellipse visualization
- Viewshed: automatic from current location + tap-to-predict from any map point; live-updating-from-GPS mode requested (open work)
- Compass with calibration, magnetic/true north display (dual needle), bubble level, bearing range capture
- CSV export, full project database backup/restore (archive ~100–250KB, suitable for WhatsApp transfer)
- Observation sharing via formatted plain text (parsed by receiving device, temporary map overlay, not stored unless explicitly saved)
- Project/user management with permission model
- High-contrast outdoor UI, haptic feedback, scroll wheels, minimal taps

### Phase Two
- Next-location recommendation: optimize viewshed along roads to minimize localization error
- Route/driving-based coverage planning (pick points along a road; compute scanned viewshed for continuous-scan driving, or suggest optimal stop points to maximize coverage)
- Team member positions on shared map
- SMS auto-detection for observation sharing (if Phase One assessment shows it's not overly complex)

### Phase Three
- Inter-team communication via central server (university server planned)
- Habitat/multispectral layer integration (land cover, vegetation type)
- Potential export to CyberTracker/SMART or Movebank (see Interoperability, below)

---

## SQLite Schema

### Users
- `user_id` (text, primary key, UUID)
- `first_name` (text)
- `last_name` (text)
- `email` (text) — the cross-device identity anchor. **No `UNIQUE` constraint** (plain index only): both merge paths deliberately tolerate duplicate emails and resolve them via `_preferredLocalUserId`, so a UNIQUE constraint would turn a survivable merge into a hard failure. Normalized (trimmed/lowercased) for *comparison*; stored as entered for display.

**Identity is user-supplied, captured at first launch (Phase 7, planned 2026-07-31).** Prior to Phase 7 the app auto-created a placeholder `Field User` with a random `field-user-<uuid>@local.tritrack` email, which silently defeated all cross-device dedup — no two installs could ever match. First-run capture is non-skippable, and devices carrying the old placeholder are prompted to complete their profile. Editing identity updates the existing row in place; the `user_id` must never change, since every observation, tag, and project on the device references it.

**Identity is not authentication.** Nothing in the offline app verifies that a user is who they claim — there are no passwords, tokens, or sessions. UI copy must not imply verification. Real authentication arrives with the Phase 3 server.

### User_Emails
Prior email addresses, retained so one human can still be matched across devices after an email change (Phase 7 task 7.3, schema v5). Without this, changing an email on one device and not another produces a duplicate user on merge — a real case, since one person may run both a phone and a desktop build.
- `user_email_id` (text, primary key, UUID)
- `user_id` (text, foreign key to Users)
- `email` (text) — a *previous* address for this user
- `recorded_at` (datetime) — when it was superseded

**Match precedence (required):** a current↔current email match always wins over any prior-email match; prior emails are strictly a fallback, and a prior↔prior-only overlap must never merge two users. **The hazard this guards against:** a reassigned institutional address (e.g. a shared lab account passed from a graduating student to a new one) would otherwise merge two genuinely different people. Prior-email matches must also be reported distinctly in the merge summary rather than applied silently.

### Projects
- `project_id` (text, primary key, UUID)
- `project_name` (text)
- `description` (text, nullable)
- `notes` (text, nullable) — species info, etc.
- `owner_user_id` (text, foreign key to Users)
- `creation_date` (datetime)
- `bbox_min_lat` (real, nullable) — geographic extent, drives tile/DEM pre-download and viewshed cropping
- `bbox_min_lon` (real, nullable)
- `bbox_max_lat` (real, nullable)
- `bbox_max_lon` (real, nullable)
- `datum` (text, default "WGS84") — stated explicitly for GIS handoff
- `triangulation_window_minutes` (numeric, free-text editable, default ~15–20) — drives the temporal-spread warning; UI is a text field, not a +/- stepper

### Project_Memberships
- `project_id` (text, foreign key to Projects)
- `user_id` (text, foreign key to Users)
- `join_date` (datetime)
- `end_date` (datetime, nullable)
- `role` (text) — "owner" | "contributor" | "viewer"

### Individuals — the animal, added 2026-09-13 (task 11.240, schema v16)

**The thing actually being tracked.** Until v16 the animal was a *text label on a
collar*, which could not survive the ordinary field case: **an animal is recaptured
and given a new transmitter.** Marie on 160.321 MHz last season and Marie on
160.523 MHz in March were two unrelated rows that happened to share a string.

**Project-scoped with a `lineage_id`, for the reasons `Tags` has both.** Michael's
case is Ponui 2025 → Ponui 2026: a season cloned into a new project, mostly the
same birds. The lineage makes the two rows recognizable as one animal **in an
export** and nowhere in the app — a message about an animal may no more reveal
another project than a message about a tag may (the standing rule from canceled
task 11.29).

- `individual_id` (text, primary key with `project_id`), `project_id`, `lineage_id`
- **`color_hex` (NOT NULL) — the one home for color.** It moved here from `Tags`
  because **it is the animal's color, not the transmitter's**: Marie is one color
  across both collars, and last season's bearings recolor with her. The move was
  nearly free because task 11.32 had already classified color as
  `TagColumnKind.display` — read live, never frozen onto an observation — so only
  the source changed, not the behavior.
- **A status of its own, which is not the collar's status.** *"A few mortalities"*
  is a fact about a bird; *"collar removed"* is a fact about a transmitter.
  **A recovered collar must not make a dead animal read as alive.**
- **An individual with no tag is legitimate**: a chick identified before it is
  collared, an animal whose collar came off and was not replaced.

~~**The link lives on the tag** (`Tags.individual_id`)~~ — **superseded 2026-09-14: the
link is a `Deployments` row carrying the attached and removed dates**, because a collar
can be redeployed and a single pair of dates on the tag cannot describe two
deployments. See `ANIMALS_AND_DEPLOYMENTS_DESIGN.md`. **`Observations` are unchanged and
must stay so** — you observed a signal
from a transmitter, not an animal, so the animal is *derived*. That keeps a mistake
about who wore what correctable without touching a single bearing, and makes "this
animal's track" a query rather than a stored fact that can go stale. It is the same
reasoning that made `Tag_Versions` a table instead of three copied columns.

### Deployments — the dated link, added 2026-09-13 (task 11.243, schema v17, schema major 5)

**A tag on an animal, between two dates.** `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` is the
decision; §§2 and 4 are this table.

- `deployment_id` (text, primary key with `project_id`), `project_id`
- `tag_id`, `individual_id` — both **NOT NULL**, both same-project composite foreign keys. A
  deployment with no tag or no animal is not a deployment, it is a blank row.
- `attached_date` (nullable), `removed_date` (nullable), `notes`

**No `lineage_id`, unlike `Tags` and `Individuals`.** A deployment is a fact inside one project —
*this* project's collar on *this* project's animal — so there is nothing two projects could hold a
copy of for a lineage to identify. A season clone (task 11.56) copies deployments and re-points
both ends.

**Two nulls that mean different things, and both look like bugs the first time:**

- **`removed_date` null means *still on***. An open-ended deployment covers everything from
  `attached_date` onward, which is why two of them on one animal are refused.
- **`attached_date` null covers no interval**, so the deployment attributes **no bearings at all**
  and conflicts with nothing — including bearings taken while the collar demonstrably was on.
  Nobody said when it went on, so nothing can be said about which bearings it covers. Michael
  named this as the thing that will look like a bug the first time he meets it; it is asserted by
  name in `test/data/repositories/deployment_repository_test.dart` rather than left to be met.

**The interlock (design §6) is one shared function both sides call** —
`DeploymentInterlock` in `package:tritrack_sync`, from `DeploymentRepository` on the device and
from `SyncService.applyPush` at the boundary. An animal's deployments may not overlap by more than
a day, nor may a tag's; the allowance is the real-world handover, and the ordinary case sits at
**zero** overlap because §5a writes the same date to one deployment's end and the next one's start.
**A rule enforced on one device is a rule about that device, not about the record.**

**Two questions, two answers, both right.** *"Which animal was this bearing about"* takes a
timestamp and is `DeploymentRepository.animalForObservation`; *"whose collar is this"* has no
timestamp to be asked with and is `latestAnimalForTag`, which is what a list of equipment, a
color swatch and a map legend read. A collar that came off Marie in June is **listed under Marie**
and every bearing taken on it since June is attributed to **nobody**.

### Tags
~~Tags are global; linked to projects via junction table.~~ **A tag belongs to
exactly one project — task 11.219, schema v14, schema major 3.** Adding a tag
to a project *copies* it, so the project's tag is its own: editing it changes
neither the device's personal `Tag_Library` nor any other project's copy.
Multiple tags can share the same name (e.g., same animal re-tagged across
seasons).
- `tag_id` (text, primary key with `project_id`, UUID)
- ~~**`individual_id` (text, nullable) — added schema v16 (task 11.240)**, declared
  `TagColumnKind.collarLife`, safe only because a redeployed collar got a NEW tag
  row.~~ **WITHDRAWN 2026-09-14, one day old — see
  `CLAUDE_DOCS/ANIMALS_AND_DEPLOYMENTS_DESIGN.md` §2.** The new-tag-row rule held only
  while a tag row was created *at deployment*. Under Michael's workflow a tag row is
  **equipment entered before any animal**, so a second row for a collar already owned
  would make the inventory lie about how many collars exist. **The link and its dates
  move to a `Deployments` row; this column is removed**, and so are `date_put_on`,
  `date_removed` and `capture_date`. The danger the withdrawn rule guarded against is
  not re-introduced but *solved*: an observation's animal is derived from the
  deployment whose interval contains its timestamp, so correcting dates re-attributes
  exactly the window corrected.
- **`color_hex` — retired to nullable by schema v16.** Color now lives on
  `Individuals`. **Making it nullable cost a major bump — schema major 4, task
  11.242.** A v15 device stores this column `NOT NULL`, so the first v16 tag row
  it was handed was refused by its own database, the page rolled back and its
  sync never advanced — while both builds still announced major 3. Measured in
  `test/data/sync/older_major_device_meets_current_row_test.dart` (**renamed from `v15_device_meets_v16_row_test.dart` by task 11.243**, which derives the two versions instead of naming them, so the next bump needs no edit there); the v15 build is now
  refused with "update the app" instead. The class — a shared column changing
  shape without the major moving — is checked by `wire_shape_freeze.dart` in the
  sync package (see "Version skew" below).
- `project_id` (text, foreign key to Projects) — added schema v14. The id
  leads and the scope follows, for the reason schema v6 gives: by-id lookup
  is the query this schema runs most.
- `lineage_id` (text, NOT NULL) — added schema v14. **Which physical collar
  this is, across every project holding a copy of it.** Minted when a tag is
  first created and carried unchanged by every copy, forever; the v14
  migration set every existing tag's to its own `tag_id`. Two projects' tags
  are the same transmitter exactly when these match. **Read by nothing that
  decides which rows travel** — `assertSealedColumnsFeedNoReachability`
  enforces that rather than a comment — and rendered nowhere as words about
  another project. Its use is an export: a multi-year analysis that has to
  know two files are about one animal. A value rather than a pointer at the
  source row, for the three reasons in §2.3 of
  `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md`: it cannot dangle, it is transitive
  without a project's row ever naming another project, and it survives a tag
  created in a project and later copied elsewhere.
- `copied_at` (datetime, nullable) — added schema v14. When this copy was
  made; **null on a tag created in place, and the null is the information.**
- `frequency_mhz` (real)
- `pulse_rate` (real, nullable) — pulses per minute; often the ONLY way to distinguish two tags on the same nominal frequency in the field
- `pulse_pattern` (text, nullable) — free/coded description of pulse pattern where applicable
- `tag_name` (text) — e.g., "Coco"
- `date_put_on` (date)
- `date_removed` (date, nullable)
- `status` (text) — "active" | "recovered" | "lost" | "malfunction"
- `capture_date` (date, nullable)
- `notes` (text, nullable)
- `color_hex` (text, NOT NULL, default from palette — added 2026-07-28, see Phase 4 in `DEVELOPMENT_PLAN.md`) — `"#RRGGBB"` format, validated against `^#[A-Fa-f0-9]{6}$` on both manual entry and CSV import. Auto-assigned round-robin from a curated colorblind-safe palette when a tag is created; user-editable in the tag form. Drives per-tag map coloring — see Display Conventions below.

**Three decisions that change how a tag relates to a project — read these
before touching tags, observations, or the solver.** The first two were taken
2026-08-22; the third is Michael's decision of 2026-08-22 implemented on
2026-09-10.

**1. A bearing references the tag as it was, not the tag as it is (task 11.32 —
implemented, schema v9; see `Tag_Versions` below).** A
VHF transmitter does not hold its nominal frequency for its whole life and names get
corrected, so a tag must be editable. But every tag field lives *only* on the tag
row, so editing one made every past bearing retroactively claim to have been taken
against the new values — frequency, and worse, **name**, since a rename makes every
earlier export and map figure unmatchable and two tags may legitimately share a
name. **So a version of the tag's full state is recorded whenever any of it
changes, and each observation points at the version current when it was recorded.**
**Not every column, though.** Each tag column is one of three kinds: **display**
(always current, never versioned — `color_hex`, because recoloring a tag is meant to
change every record already drawn and there is no such thing as "the color it was
then"); **measurement context** (versioned — `frequency_mhz`, `pulse_rate`,
`pulse_pattern`, `tag_name`); or **a fact about the collar's life** (current only, no
per-observation copy — `date_put_on`, `date_removed`, `capture_date`, `status`,
`notes`). **Every column must declare its kind and a schema-derived test fails if one
has not** — adding a column forces the decision instead of defaulting, because
"current" and "versioned" are each silently wrong half the time. **An edit to a
versioned field must say whether it is a correction or a change**: drift is a change
and old bearings keep the old value; a typo is a correction and they take the new
one. Only the person knows which, so the app asks — the same question, in the same
shape, as supersede-versus-overwrite for observations. A color-only edit asks
nothing. **Two reads stay distinct
forever:** "what was this bearing recorded against" resolves through the version,
"what is this tag now" reads the tag row. **Do not reconcile them — the difference
is the drift record**, and it is more scientifically useful than a tag row that only
remembers today. No version reference means "not recorded", never "whatever the tag
says now", so older rows are not backfilled. An opaque blob of tag state on each
observation was considered and rejected: the validator cannot check it.

**3. Adding a tag to a project copies it (task 11.219 — implemented, schema
v14, schema major 3; the design is
`CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md`).** Michael decided on 2026-08-22
that a project's tag should be its own. `Tags` and `Tag_Versions` took a
`project_id` and became keyed `(<id>, project_id)`; `Project_Tags` left the
wire; and the device gained a `Tag_Library` that never syncs.
**What that bought, beyond the product decision:** the server stops needing
to compute which tag ids a project may see, so `GlobalReachSet` drops from
two members to one and `RowAuthorizer._authorizeTagReferences` — 161 lines
under about 200 lines of argument — plus `_tagIsClaimedElsewhere`,
`_tagRowExists`, `_noteEstablishedTag` and `_establishedThisPush` are all
deleted rather than kept. Security Model §5.9(a) and finding F4 close with
them. **What it cost:** the second schema major bump this project has ever
spent, and it was spent while nobody was in the field, which is the only time
it is cheap.

### Tag_Versions — what a tag read when a record was taken (task 11.32, schema v9)

**Project-scoped, exactly like `Tags` (task 11.219, schema v14).** A version
is a version of one project's copy of a collar, so it lives in that project
and a pull narrows it by `project_id` like every other scoped table. ~~Global,
exactly like `Tags`: a version is a version of a global tag, so it has no
project of its own, and a pull narrows it to the versions of the tags the
project reaches.~~ Two projects holding the same collar keep separate version
chains — which is what copy-on-add means applied to history, and is §2.2 of
`CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md`'s answer to "where does a tag's
history live once the tag is project-local".

- `tag_version_id` (text, primary key with `project_id`, UUID)
- `project_id` (text, foreign key to Projects) — added schema v14
- `tag_id` (text, composite foreign key to Tags with `project_id`) — the tag
  this is a version of
- `effective_from` (datetime, UTC) — when this version took effect **in this
  database**, deliberately not the collar's `date_put_on`; the collar may have gone
  on the animal months before anyone entered it. Provenance, not a lookup key: an
  observation names its version *by id*, never by "whichever version was current at
  my timestamp", because the two disagree whenever a bearing is entered after the
  fact.
- `frequency_mhz`, `pulse_rate`, `pulse_pattern`, `tag_name` — **and nothing else.**
  This column set is *derived* in code from the `measurementContext` entries of
  `tagColumnKinds`, so declaring a new tag column that kind is the whole of what it
  takes to make it travel with every bearing. Writing the four names out by hand
  would have been the fifth instance of the drift defect this task exists to avoid.

**What each copy means, stated so a future reader does not reconcile them:**

| Where you read it | What it means | May it be edited? |
| --- | --- | --- |
| `Tag_Versions.frequency_mhz` (via `Observations.tag_version_id`) | What the receiver was tuned to when that bearing was taken. | **Never**, except by a *correction* — see below. |
| `Tags.frequency_mhz` | The tag's current state. | Freely, by a project owner. |

`Observations.tag_version_id` is nullable, and **NULL means "not recorded", never
"whatever the tag says now"**. Rows predating schema v9 keep it null and are not
backfilled; a pasted share payload lands null (the payload carries the recorded
*values*, so the person can see them, but the sender's version id names a row in
*their* tag's history while the replica is relabeled onto the receiver's local
tag); and a version id this device does not hold yet resolves to null and is inert,
never an error. It carries **no foreign key**, for the same reason
`Observation_Exclusions` carries none into `Observations`: sync delivers rows in
`server_seq` order across pages, so a bearing can legitimately arrive before the
version it names, and refusing it would wedge that device's sync entirely.

**A correction rewrites the current version in place; a change appends a new one.**
Earlier versions are untouched by either — a correction to today's frequency says
nothing about a genuine drift six weeks ago, and flattening the two would destroy
the history the table exists to keep.

**Who may write one**, and the asymmetry is deliberate: *appending* is
contributor-level (additive, forward-only, and requiring an owner would refuse a
contributor's own new tag's first version — intermittently, since a sync batch limit
can split a tag and its first version across two pushes); *rewriting* one is
owner-only, because that is the retroactive act. See `PERMISSIONS_MATRIX.md` §7, rows
T8a and T8b, including the residual that is knowingly accepted.

**Size:** tags change rarely — a drift correction, a rename. Single-digit versions
per tag over its whole life. This is a few rows per collar, not a history system.

**2. A tag added to a project is copied into it (task 11.34 — design first, not yet
implemented).** Project tags are decoupled from the person's own tag log and from
every other project: editing a project's tag changes nothing outside that project,
and the user is told the copy is a copy in both directions. This deletes the whole
cross-project coordination question rather than answering it — no cross-project
authorization rule, no frozen shared tag, and the orphan-tag residual stops
existing. **A non-authoritative provenance pointer is kept on the copy** so a
multi-year analysis can still tell that two projects meant the same physical collar;
nothing live may read it, and **no message about a tag may reveal that another
project exists.** Adding a tag to a project is owner-only, and that rule is now
load-bearing here — it is what keeps copy-on-add from multiplying within-project
duplicates.

### Ground-truth positions — where the animal or collar actually was (task 11.33)
The table, its sync rule, its storage code and its map layer already existed with
nothing ever calling the save, so a truth point could arrive by sync and be drawn
but never entered. Decisions taken 2026-08-22:
- Entered from the record screen. Position is "use current location" (default) or a
  map pin — the existing `gps_fix` and `manual_pin` conventions, not a third one.
- **Radial precision prefills from the phone's own reported horizontal accuracy for
  a GPS fix, and is told to the user.** Freely editable up or down, including below
  the phone's figure. **Not prefilled at all for a map pin** — a pin is only as good
  as the person's ability to identify the spot in the imagery, and base-map
  registration is itself commonly off by meters. An over-confident default here
  would quietly corrupt the accuracy statistics the feature exists to produce.
- **Three-way kind: animal and collar / animal only / collar only.** Only the first
  validates triangulation of a live collared animal; a collar-only point may be
  where the collar was shed days earlier, and comparing it to estimates from when
  the animal still wore it would make the app look wrong when it was right.
- Notes and timestamp as for any record. Time matters because animals move.
- **A truth point must never enter the position-estimate solver**, which is why it
  is its own table rather than a new `observation_type`: a solver query that must
  *remember to exclude* a row type is an exemption, and exemptions are where this
  project keeps finding its next problem. Asserted by test, not by care.

### Project_Tags — retired from the wire, kept on the device (task 11.219)
~~Junction table. Tags are never deleted, only deactivated — maintains an audit
trail.~~

**A tag belongs to one project since schema v14**, so there is nothing left to
link. The table is **out of `syncTables`, `tableSpecs` and `Tables.all`**, and
dropped from the server's Postgres schema; it stays in the app's local SQLite
schema, unused and unwritten, for two reasons the design (§2.2, §3.5) gives:
it is the only durable record of what the v14 migration did, and an archive
written before v14 still carries its rows. Its rebuild in v14 drops its
foreign key into `Tags` — a record of the past must not be able to stop the
app opening because the present schema moved underneath it.

- `project_id` (text, foreign key to Projects)
- `tag_id` (text, **no foreign key since v14**)
- `status` (text) — "active" | "inactive" within project

**"Remove a tag from this project" is now a tombstone on the project's own
`Tags` row.** Nothing is deleted: the row stays, so every bearing that names
it still resolves, and putting it back clears the tombstone.

### Tag_Library — this device's own list of transmitters (task 11.219)
**Device-local. Not in `syncTables`, not in `tableSpecs`, not in
`Tables.all`** — no push, pull, merge or archive carries a row of it, and no
role governs it.

It is the lab's list of collars, and what a project's tag is **copied from**.
Same columns as `Tags` minus `project_id` and `copied_at`, plus `lineage_id`.
No version chain: a version records what a collar read when a bearing was
taken against it, and nothing is ever recorded against a library entry.

Taking it off the wire cost nothing that worked. §5.9(a) kept a write path
open so *"a tag not yet on any project still has to replicate between one
person's phone and their laptop"* — measured by task 11.34 and false: sync is
per-project on both sides and an unlinked tag was in no project's set, so no
request could ever carry one.

### Observations
- `observation_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `user_id` (text, foreign key to Users)
- `tag_id` (text, foreign key to Tags, nullable if "No tag" is used for a Note-type record — see Open Work)
- `session_id` (text, nullable) — groups bearings intended as one near-simultaneous triangulation fix (see Triangulation Sessions below)
- `tag_version_id` (text, nullable, **no foreign key** — added 2026-08-22, schema v9, task 11.32) — the `Tag_Versions` row recording what the tag read when this bearing was taken. **NULL means "not recorded", never "whatever the tag says now."** See the `Tag_Versions` section above for the full contract, including why there is no foreign key and why nothing backfills it.
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `position_accuracy_m` (real, nullable) — GPS horizontal accuracy / HDOP-derived, meters
- `position_source` (text) — "gps_fix" | "manual_pin" | "manual_entry". Semantics clarified 2026-07-30: **`gps_fix`** = this device's GPS; **`manual_pin`** = user placed/dragged a point on the map; **`manual_entry`** = typed coordinates, deliberately unimplemented (see `List_of_fixes_needed.rtf` — "no one wants to manually enter a lat/lon"). A replicated shared observation carries the *original* device's value, not a receiver-invented one.
- `elevation` (real) — auto-populated from DEM
- `altitude_agl` (real, default 0)
- `observation_type` (text) — currently **"directional" | "omnidirectional"** in the implemented enum. Design direction calls for two additional record types, **not yet in the schema**: **"note"** (tag-linked or tag-less free text with standard position/time metadata, no radio fields) and **"no_signal"** (records that none of several selected tags were heard — may fit better as a multi-tag variant of `Non_Detections` rather than a new `Observations` row type; needs a schema decision before implementation).
- `magnetic_bearing` (real, nullable)
- `true_north_bearing` (real, nullable)
- `bearing_uncertainty` (real, nullable) — degrees, default 10–15°
- `bearing_capture_method` (text, nullable) — "single_point" | "range_capture"
- `bearing_method` (text, nullable) — "peak" | "null" — peak vs. null antenna method; affects precision
- `magnetic_bearing_start` (real, nullable) — if range_capture
- `magnetic_bearing_end` (real, nullable) — if range_capture
- `true_north_bearing_start` (real, nullable)
- `true_north_bearing_end` (real, nullable)
- `magnetic_declination` (real, nullable) — computed for the observation DATE, stored for audit
- `wmm_model_version` (text, nullable) — WMM epoch/model used for the declination calc (e.g., "WMM2025")
- `antenna_type` (text, nullable) — e.g., "yagi_3el" | "yagi_5el" | "h_adcock" | "omni" | "other"
- `receiver_gain` (real, nullable) — gain/attenuation setting needed to hear signal; rough distance proxy
- `signal_type` (text, NOT NULL) — "regular_pulse" | "mortality_signal". **Superseded as the app's answer, kept as the schema's, and both halves matter (task 11.187, schema v12).** Pulse modes are now named per tag by whoever entered the collar, so this column no longer describes what the app offers. It survives because it is `NOT NULL` on a table that already holds records — removing it is a major-version change — and because it does two live jobs: **it is the only mode information every pre-v12 bearing has** (read on the fly, nothing backfilled), and **it is what a build older than v12 sees.** Its wart: the projection expresses two values, so a bearing heard on a *third* mode is written here as if it were the first. **Nothing in this build reads it when `pulse_mode` is present**, so the loss reaches only an older reader. **Do not schedule its removal on its own; spend it with the next major bump taken for another reason.**
- `pulse_mode` (integer, nullable — added 2026-09-07, schema v12, task 11.187) — **which of the tag's pulse modes the receiver was hearing, as a slot number: 1, 2 or 3.** The mode's *identity*, never its words: the name and rate at the time live on the `Tag_Versions` row `tag_version_id` names. **NULL is an ordinary answer with three causes and no backfill turns any of them into a number** — a row written before v12 (read through `signal_type` instead), a record with no tag, and a pasted or imported replica, which drops it deliberately because a slot number names a mode in the *sender's* tag.
- `signal_strength` (text, NOT NULL) — "faint" | "weak" | "medium" | "strong" | "very_strong". **Captured on a scroll wheel** — the horizontal slider this line described was never what shipped. **Best is at the top since task 11.188.**
- `signal_irregular` (nullable — added 2026-09-07, schema v13, task 11.193) — **the transmitter sounded faulty at this listening moment**, an irregular inter-pulse duration. **It is not `Tags.status`'s `malfunction`, and nothing derives one from the other:** that status is a claim about the collar today; this is a claim about one moment, and several of these are the evidence that would justify setting it. **It does not withdraw the bearing from anything** — excluding a bearing from an estimate is `Observation_Exclusions`' job (task 11.7). **Empty is not "no": it means nobody was asked**, which is true of every bearing recorded before v13 and of every note, truth point and no-signal sweep.
- `bearing_quality` (text, nullable) — "good" | "fair" | "suspected_bounce" — applies to directional records only; omnidirectional records should not prompt for this field. **This is the field that means *I am not sure about this direction*** — distinct from `signal_strength` (*it was faint*) and from `signal_irregular` (*the transmitter sounded faulty*). Three different doubts; the guide is told not to blur them.
- `notes` (text, nullable) — plain text only

> **This list has now drifted three times and been repaired by hand three times** (task 11.32's
> `tag_version_id`, and 11.187's and 11.193's columns above). **`packages/tritrack_sync/lib/src/table_columns.dart`
> is the truth and this is a copy of it.** If it drifts a fourth time, the answer is not a fourth
> repair — it is task 11.123's enumerator pointed at this section, the way §4.2 and §4.21.2 are.
> *(Recorded 2026-09-07. Task 11.193's report named three missing columns; there were two —
> `tag_version_id` was already here. Counted rather than trusted.)*

### Non_Detections
- `non_detection_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `user_id` (text, foreign key to Users)
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `position_accuracy_m` (real, nullable)
- `position_source` (text) — "gps_fix" | "manual_pin" | "manual_entry". Semantics clarified 2026-07-30: **`gps_fix`** = this device's GPS; **`manual_pin`** = user placed/dragged a point on the map; **`manual_entry`** = typed coordinates, deliberately unimplemented (see `List_of_fixes_needed.rtf` — "no one wants to manually enter a lat/lon"). A replicated shared observation carries the *original* device's value, not a receiver-invented one.
- `elevation` (real)
- `altitude_agl` (real, default 0)
- `tag_ids_listened_for` (text/JSON array) — already modeled as multi-tag capable, matching the "No Signal" quick-record request; **the gap is UI/route, not schema** — no screen currently creates a `Non_Detection` record.
- `notes` (text, nullable)

### Estimated_Positions
Single tag per estimate — all contributing observations must share the same `tag_id`.
- `position_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `tag_id` (text, foreign key to Tags)
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `semi_major_axis` (real)
- `semi_minor_axis` (real)
- `rotation_angle` (real)
- `method` (text) — "lenth_mle"
- `observation_ids_used` (text) — JSON array, all same tag_id
- `notes` (text, nullable)

### Triangulation_Sessions
Groups observations intended to be near-simultaneous (same stationary animal position). Lenth's method assumes all bearings point at ONE stationary source; this table makes the "these belong together" intent explicit and enables the temporal-spread warning.
- `session_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `tag_id` (text, foreign key to Tags) — a session is always about one tag
- `label` (text, nullable) — optional user label (e.g., "Coco morning fix")
- `started_at_local` / `started_at_utc` (datetime)
- `notes` (text, nullable)

### Actual_Tag_Locations
- `location_id` (text, primary key, UUID)
- `project_id` (text, foreign key to Projects)
- `tag_id` (text, foreign key to Tags)
- `timestamp_local` (datetime)
- `timestamp_utc` (datetime)
- `timezone_offset` (text)
- `latitude` (real)
- `longitude` (real)
- `uncertainty_radius` (real) — meters, the radial precision claimed for this position
- `notes` (text, nullable)
- `found_kind` (text, nullable) — `animal_and_collar` | `animal_only` | `collar_only` (task 11.33). Only `animal_and_collar` validates the triangulation of a live collared animal; a `collar_only` point may be where the collar was shed days earlier. Nullable because a row written before schema v10 recorded nothing here, where null reads as "not recorded"
- `tag_version_id` (text, nullable, **no foreign key**) — the `Tag_Versions` row the tag read when the point was taken, as `Observations.tag_version_id` does for a bearing (task 11.32). No foreign key and no backfill, for the reasons that column gives: sync can deliver the point before the version it names, and a value invented later would be a claim about a past nobody observed

**Two tables that name a tag and deliberately record no version** (task 11.33, written down so the absence is not rediscovered as a gap): `Estimated_Positions` — an estimate is derived from bearings that each already record their own version, so the information is reachable without duplicating it; `Triangulation_Sessions` — a session is a grouping label, not a measurement.

**Global rule:** All timestamps are stored as both local time and UTC, with timezone offset, across all tables.

---

## Key Technical Requirements

### Compass & Bearings
- Phone provides magnetic north; convert to true north using the NOAA World Magnetic Model (embedded, offline)
- Store all three: `magnetic_bearing`, `true_north_bearing`, `magnetic_declination` — full audit trail
- Compass rose UI: **red needle** points to magnetic north, **light green arrow** points to true north; both rotate live with the phone, visually showing the declination as the offset between them. **Implementation check needed:** a recent code review found only a single (magnetic) needle painter in `compass_dial.dart` — confirm the true-north arrow is actually rendered, not just documented.
- **[Note for Claude Code — accessibility, required]** Red/light-green is the worst color pair for the most common color-vision deficiency (~8% of men, and the field user base skews that way). The two indicators MUST be distinguishable by shape and label alone: label the magnetic needle "M" and the true-north arrow "T", give them different head/shaft geometry (e.g., solid vs. dashed shaft), so color is redundant, not required.
- Bubble level indicator alongside compass; must move like a physical bubble (opposite the tilt direction) in both pitch and roll — a pitch-direction inversion has been reported and needs re-verification against current sensor-fusion code
- Declination shown as computed from device location (WMM) with a manual-override control for the user
- Two capture modes:
  - **Single Point**: point phone, press save; uncertainty control shows the live numeric degree value, not only the graphical wedge
  - **Angular Range**: press Start at beginning angle, rotate — the swept band highlights live as the phone moves — press End at final angle → midpoint = bearing, half-range = uncertainty; the full captured band stays highlighted with its center marked
- **[Note for Claude Code — critical bug class]** All bearing/angle math must use circular statistics, NOT linear arithmetic. Linear averaging breaks across the 0/360 boundary: a sweep from 350°→10° must yield a midpoint of 0° (± 10°), not 180°. Use shortest-arc / von Mises handling for range-capture midpoint, uncertainty, and any bearing averaging or differencing.
- **[Note for Claude Code — WMM epoch]** Compute declination using the OBSERVATION date, not today's date (WMM is valid per ~5-year epoch and drifts). Store the model version used (`wmm_model_version`). Ensure the embedded model is updatable. Double-check the declination sign convention — Flagstaff/Arizona is ~+10° EAST; a sign flip here is a classic silent error that puts every true-north bearing off by ~20°.
- **[Note for Claude Code — magnetometer interference]** The normal field posture is holding a metal Yagi/H-antenna, often beside a vehicle, while reading the phone compass — this corrupts the magnetometer. Detect likely interference (magnetic field magnitude far from expected ~25–65 µT, or failed calibration) and warn the user to step away from metal/antenna. This is a primary reason manual bearing entry must remain first-class.
- Calibrate button accessible immediately before bearing capture
- **[Note for Claude Code]** iOS: Core Location + native calibration flow. Android: SensorManager + guided rotation (figure-eight).
- The Compass screen is an instrument-only view (no save action); the Record screen's bearing capture must visually mirror this compass exactly — no divergence between the two.
- Main map's compass-linked rotation should be low-sensitivity enough that ordinary pan/zoom doesn't inadvertently rotate the map; tapping the north arrow/N label resets to north-up.

### Observation Data Entry (Speed Critical)
- **[Note for Claude Code]** Minimize taps. Use scroll wheels (not dropdowns) for categorical fields, with haptic tick feedback on scroll. Signal strength is the deliberate exception (horizontal slider).
- Signal strength: horizontal slider, faint (left) → very strong (right); qualitative levels stored, not dBm
- Tag selection: scrollable list showing "frequency | name"; persists the last-selected tag as the default across sessions; list needs an "Add new tag" entry (routes to tag creation) and, for Note-type records, a "No tag" entry pinned at the top
- Record-type selector (directional / omnidirectional / Note / No Signal) belongs at the top of the Record screen, above the tag selector
- Location: GPS auto-populated, or manual map pin if GPS unavailable
- Manual bearing entry allowed (not just compass)
- Manual lat/lon entry allowed (for remote reports relayed by colleagues)
- Bearing observations must be linked to a specific `tag_id` selected from the project's tag list (Note records may be tag-less)
- Preview step: after capturing a bearing/omnidirectional record, show it on the map before final save, with a manual reposition affordance for GPS-multipath cases

### Observation Sharing (Offline Team Coordination)
- Share button on each observation formats it as a **versioned, structured payload** (not a fragile human-readable string). Use versioned JSON, optionally base64-wrapped so messaging apps don't mangle it, with a short format-version prefix (e.g., `TT1:` + base64).
- **Why not a pipe-delimited string:** a raw `TAG: 147.5 MHz | BEARING: 145° | ...` string breaks if notes contain `|`, if a colleague's locale uses comma decimals, or if the degree symbol re-encodes in transit — and it carries no observer identity, timestamp, position uncertainty, pulse rate, or unambiguous tag key.
- Payload must include: format version, tag frequency + pulse rate + name, observer name, timestamp (UTC), lat/lon, position accuracy, true-north bearing, bearing uncertainty, and optional notes.
- **[Note for Claude Code]** Design this envelope generically now so Phase 2 team-position "pings" and Phase 3 server messages reuse the same versioned structure.
- On parse: handle the case where the receiver does NOT have the referenced tag (offer to create it or show as unlinked). Validate/bound-check every field on ingest.
- Received observations display as a temporary map overlay; not saved to the database unless the user explicitly saves.
- **Saved shared observations must be faithful replicas, not new rows (decided 2026-07-30, see Phase 6 in `DEVELOPMENT_PLAN.md`).** The payload carries the original `observation_id`, the observer's `user_id` + normalized email + name, `position_source`, `position_accuracy_m`, and the original sync clock (`created_at`/`updated_at`/`revision`/`last_modified_by`/`origin_device_id`). On save the receiving device reuses the original primary key, resolves/creates a local `Users` row keyed by normalized email (using the original `user_id` so the replicated row's `user_id` matches across devices), and defers to `MergeResolver` if it already holds that row. **Rationale:** minting a new UUID per share-save — the original behavior — produced two rows with different primary keys for one real observation, so last-write-wins never fired and the observation silently duplicated on sync. Duplicated bearings are especially harmful here because the Lenth MLE treats them as independent confirmations and returns a falsely tight confidence ellipse.
- **Envelope marker vs. payload version (decided 2026-07-31, task 6.2):** the `TT1:` marker identifies the *envelope* (marker + base64 + JSON object carrying a `v` field) and deliberately does **not** track payload version; the inner `v` does. Identity/provenance/sync-clock fields were added as `v: 2`. Keeping the marker at `TT1:` means an older build still recognizes the envelope and reports "this payload is newer than the app" rather than "not a Tri Track payload." Bump the marker only if the envelope encoding itself changes such that older builds can't parse far enough to read `v`.
- **v1 payloads cannot be replicated:** they predate the identity fields, so `decode` surfaces a null identity block and the save path must fall back to a new receiver-owned observation *with a visible warning* — never silently pretend it replicated. A `v: 2` payload missing any identity field is rejected outright, since a half-populated identity would be written as though authoritative.
- **The measurer owns the record:** preserving the original `user_id` also means the existing "only the creator can edit" rule correctly makes a replica read-only on the receiving device.
- **Privacy note, accepted:** because email is the cross-device identity anchor, share payloads contain a team member's email address and travel over consumer messaging apps. A forwarded payload discloses it downstream. Do not change the identity anchor to avoid this without accounting for merge/dedup — it's load-bearing.
- **[Note for Claude Code]** Attempt SMS auto-detection (similar to bank OTP autofill) if feasible; defer to Phase Two if too complex.

### Localization Algorithm
- **Reference:** Lenth, R.V. (1981). "On Finding the Source of a Signal." *Technometrics*, 23(2), 149–154.
- **[Note for Claude Code]** Validate implementation against the example data in the 1981 paper and cross-check against the R packages `radiotrack` and `sigloc`
- Inputs: observer position (lat/lon), true north bearing, bearing uncertainty
- Output: best-fit tag position + uncertainty ellipse (semi-major axis, semi-minor axis, rotation angle)
- Also compute pairwise bearing intersections for display as a separate, toggleable layer
- Position Estimation flow: user must first select a tag → only that tag's observations are shown → bearings from different tags are never mixed
- No finite time limit on which bearings are eligible for selection — the full history for the tag is shown, reverse-chronological, with select/deselect-all; the temporal-spread warning (not a hard cutoff) is what flags stale/likely-moved-source risk
- User can toggle individual observations on/off before recomputing, both from the list and directly from clickable rays on the map
- Estimated positions are saved with the list of `observation_ids` used
- Positions are updatable: add a new observation, recompute, save the updated estimate

#### Stationary-source / temporal assumption (critical science point)
- Lenth assumes ALL bearings point at the SAME STATIONARY source. Bearings taken minutes apart on a moving animal will be fused into a confident but WRONG fix with a deceptively tight ellipse.
- Use `Triangulation_Sessions` to group bearings intended as one fix. In the Position Estimation screen, when selected observations span more than a configurable window (default ~15–20 min, project-adjustable via free-text field), show a **soft warning** ("these bearings span 34 min; the animal may have moved") — warn, don't block, and don't let the warning banner grow large enough to cover the selection list.
- Surface the time span of the selected observation set in the UI at all times.

#### Degenerate-geometry guards (required — otherwise crashes / garbage output)
Claude Code must guard every one of these before running the MLE:
- **N = 1:** cannot triangulate. Render the single bearing as a ray only; do not attempt an estimate or ellipse.
- **N = 2, near-parallel:** intersection approaches infinity → near-singular matrix → inf/NaN ellipse. Detect small inter-bearing angle and warn/refuse.
- **All observers at (nearly) the same point:** no triangulation information regardless of N. Detect and warn.
- **Near-singular / near-zero semi-minor axis:** clamp and flag rather than emitting NaN.
- **Poor geometry (high GDOP):** when the resulting ellipse is very large or highly elongated, show a geometry-quality warning so the user understands WHY, and suggest a better next observer position.
- Down-weight or flag observations with large `position_accuracy_m` (Lenth assumes known observer positions; a ±20 m fix under canopy inflates true error).

### Viewshed
- DEM raster downloaded for offline use
- Grid spacing: 10–50 meters (coarse = fast, sufficient for signal propagation modeling)
- Phase One: computed on-device in real time
- Automatic viewshed from current location, displayed on map on open
- Tap-to-predict: user taps "predict viewshed," then taps any map point to preview visibility from that point
- **Live mode (open request):** continuously recompute from the user's current GPS position as they move (e.g., while driving), rather than only a one-shot tap
- Displayed as a semi-transparent overlay on the map
- Show a progress indicator during computation; if there's no DEM coverage for the tapped/current area, say so explicitly and prompt a download rather than showing a perpetual "Computing viewshed…" state
- **[Note for Claude Code]** Crop the DEM to a radius around the observer before computing so a large project doesn't exhaust memory. Handle taps OUTSIDE downloaded DEM coverage gracefully (clear message, not a crash). The project bounding box bounds which DEM to fetch.
- **[Accuracy caveat — important, affects UI copy]** A binary optical viewshed is neither purely conservative nor purely liberal relative to real VHF reception: standard DEMs are bare-earth (no canopy), so a "clear" cell in dense ponderosa pine may not actually be clear for signal, while diffraction/multipath around ridges (~2m wavelength at these frequencies) can deliver signal into cells the viewshed marks blocked. Label the viewshed in the UI as **predicted line-of-sight coverage**, not a guarantee of reception in either direction.
- **`max_detection_range_m`** (project- or tag-level, user-configurable): the viewshed display should clip to this radius, since a large open LOS polygon at long range overstates realistic detection distance for a hand-held VHF setup regardless of terrain clearance. Required field, not optional polish.

### Viewshed — Under Review, NOT approved for build
- **Relative-likelihood layer via ITM (Longley-Rice):** replacing/supplementing the binary viewshed with a graded "relative likelihood of detection" surface, using the open-source NTIA ITM reference implementation. Path loss from ITM does not require known transmitter power — output would be relative/comparative, not absolute — and could eventually be calibrated against real `Observations`/`Non_Detections` data already in the schema.
- Substantially heavier computation than binary viewshed; on-device feasibility at real-time speed is unproven and may require server-side computation (ties to Phase 3 server).
- No ready-made Dart/Flutter package exists. Two integration paths considered: (a) Dart FFI wrapper around the official NTIA C++ implementation (public domain), likely more tractable but needs native builds per platform; (b) full Dart reimplementation, higher risk of subtle numerical error.
- Any implementation must validate against NTIA's own reference test vectors (`area.csv`/`p2p.csv`) before being trusted.
- **Status: logged for future review, not scheduled to any phase yet.**
- **Route/driving-based coverage optimization** (Phase Two candidate): computing scanned viewshed along a driving route, or suggesting optimal stop points to maximize coverage for a drive. Not yet designed in technical detail.

### Live Audio Pulse Detection & Signal-Strength Plotting — Under Review, NOT approved for build
*Proposed 2026-07-27, in response to the gap between "predicted coverage" (viewshed/ITM, computed from terrain) and an actual real-time reading of what the receiver is hearing right now — useful both for road-cruise scanning with an omni antenna and for close-range homing on a tag once a rough position is known.*
- **Concept:** feed the demodulated audio (pulse tone) output of a handheld VHF receiver into the phone's microphone input — via a Lightning/USB-C-to-3.5mm adapter that supports line/mic input, since most modern phones lack a native headphone jack — and run real-time pulse detection and envelope/level analysis on the incoming audio stream.
- **Live display:** a numeric/graphical relative signal-strength (and, once inter-pulse timing is available, live pulse-rate) readout, continuously updated, plus a live signal-strength trace plotted along the user's current GPS track on the map — so a strengthening/weakening trend is visible while driving a road with an omni antenna, or while walking in on foot for a close-range fix.
- **Audio capture:** Flutter has no built-in raw-PCM mic API; would need a plugin (e.g. `flutter_sound`/`record`) or a native platform channel. **[Note for Claude Code — iOS]** Must set `AVAudioSession` to `.measurement` mode (or otherwise disable voice-processing/AGC/noise-suppression), or iOS's phone-call-oriented audio pipeline will actively smear out pulses and normalize away the amplitude differences the feature depends on.
- **Pulse detection / signal-strength DSP:** envelope-follow the audio (rectify + low-pass, or short-window RMS), estimate a noise floor from the inter-pulse gaps, and report level as peak-to-floor ratio. Pulse-to-pulse timing yields pulse rate "for free," reusing the app's existing pulse-rate-as-tag-disambiguator concept. An optional tone-frequency filter (narrowband around the receiver's audio-tone frequency) would help reject engine/road/wind noise picked up by the phone mic.
- **[Labeling caveat — same honesty principle as the viewshed/ITM labeling]** Without calibration against a known reference this is a *relative* signal-to-background level, not a true, calibrated SNR in dB. UI copy should say "relative signal strength (uncalibrated)" or similar, not "SNR," unless/until a calibration procedure exists.
- **Hardware caveat:** receiver audio-output line level vs. phone mic-input level commonly mismatch (risk of clipping or of a too-weak signal), and TRRS wiring standards (CTIA vs. OMTP) differ across adapters — this needs bench-testing against the actual receiver hardware in use before committing UI/permission work to it. Not purely a software risk.
- **Permissions:** adds a microphone-permission request alongside the existing location permission.
- **Status: logged for future review at user request, not scheduled to any phase yet.** Comparable in scope to the viewshed engine (a new DSP + live-overlay subsystem), not a small UI addition.

### Data Management
- Backup: export full project as a `.zip` archive (~100–250KB uncompressed, ~80–130KB compressed)
- Shareable via WhatsApp, email, or cloud storage
- CSV export: all observation fields, filterable by tag or date range
- Import backup to restore full project state
- Bulk tag import via CSV
- **[Note for Claude Code — import/merge semantics, must be defined]** Importing a project already held in a different state needs an explicit strategy. UUID PKs prevent ID collisions, but define merge vs. overwrite behavior using the per-row `revision` + `updated_at` fields (last-write-wins by default), dedup users by normalized email, and handle corrupt/partial zips without wiping the existing project. Validate `schema_version` and migrate forward if older.
- **[Note for Claude Code — offline tile licensing, resolve early]** Many providers (Google, some Mapbox tiers) prohibit bulk download / offline caching of tiles — satellite especially. Choose a provider whose license explicitly permits offline use (e.g., USGS/USFS topo, appropriately licensed ESRI, or Mapbox's official offline SDK).
- **[Note for Claude Code — validation]** Bound-check every field on BOTH manual entry and CSV import: frequency (sane VHF range), bearing (0–360), uncertainty (>0), lat/lon ranges, pulse rate. Bulk tag import needs a preview/dry-run before commit and must tolerate Excel UTF-8 BOM and header-name variants.
- **Coordinate display toggle:** offer decimal degrees / DMS / UTM; datum is WGS84 and stated explicitly.
- **Offline download UX:** progress bars must reflect actual download progress (bytes/tiles fetched), not sit at 100% while only a fraction counter updates; completed downloads must show an explicit "Completed" state rather than continuing to show "Cancel"; show an estimated time remaining based on current rate; prevent the device from sleeping mid-download so downloads run to completion in the background.
- **Offline data visibility:** the map/download management interface should show existing downloaded coverage (tiles + DEM) so the user can see gaps, both to add new coverage and to select-and-delete existing coverage to free space.

### Security & Data Integrity
- Only the observation's creator can edit that observation
- Only a project owner can delete observations or modify project settings
- Roles: owner, contributor, viewer — **a project may have any number of
  co-equal owners** (task 11.1), and the gradient is enforced server-side per
  row (task 11.3): a viewer writes nothing, a contributor records and edits
  their own, an owner does everything plus membership and settings
- **[Important — Phase One reality]** With no server, everything is device-local and roles/permissions are **advisory only**: anyone holding the backup file can edit its contents. This is acceptable for Phase One, but the app (and users) should not mistake it for enforced security. Real enforcement arrives with the Phase Three server.
- **[Enforcement location — Phase 8, implemented 2026-07-31 in task 8.1]** Even as advisory controls, authorization belongs **below the widget layer**, in the repository, not in per-screen render conditions. An audit found the "only the creator can edit" rule implemented as a single `canEdit` condition in `log_screen.dart`, while `map_screen.dart` rendered the same Edit action with no check at all — so any observation could be edited by tapping it on the map. Repository-level checks mean a new screen cannot bypass the rule by forgetting it.

#### Authorization rules (repository layer)

`BaseRepository.updateById` / `softDeleteById` / `restoreById` each require a
`MutationActor` (`lib/data/repositories/mutation_authorization.dart`). It is
both stamped into `last_modified_by` and checked against the table's
`MutationRule`; a violation throws `UnauthorizedMutation`. `modifiedBy` as a
free-floating audit *label* no longer exists — the actor is the label.

| Rule | Governing column | Tables | Meaning |
| --- | --- | --- | --- |
| `author` | `user_id` | Observations, Non_Detections, Users, User_Emails | Only the row's author may modify it. For Users the column *is* the primary key, so it reads as "only you may edit your own profile". |
| `owner` | `project_id` (resolved to that project's current owners) | Projects | Only an owner of the project may modify or soft-delete it. **Changed by task 11.1** — was `owner_user_id` compared directly. |
| `projectOwner` | `project_id` (resolved to that project's current owners) | Project_Memberships | Only an owner of the row's project may modify a membership row — added task 8.4, replacing this table's previous `anyUser` rule (a contributor must not be able to grant themselves a different role). **Changed by task 11.1** — was resolved to `Projects.owner_user_id`. **One exception since task 11.28: a person may end their own currently-open membership row** — set `end_date`, change nothing else — which is how somebody who is not an owner leaves a project. Like the tag and exclusion rungs above it, it is not expressible as a rule over a row's columns, because it compares the incoming row against the stored one; it lives in the shared `isSelfDeparture` predicate (`packages/tritrack_sync/lib/src/membership_departure.dart`), applied by `ProjectMembershipRepository.leaveProject` on the device and at two named points in `RowAuthorizer.authorizeWrite` at the boundary. It overrides the role gradient and this rule and nothing else — the last-owner guard and the audit-column rule both still bind. Security Model §4.25. |
| `authorOrOwner` | `user_id` **and** `project_id` (resolved to that project's current owners) | Observation_Exclusions | **The rule table's first disjunction, added task 11.15.** The person who made a supersede/exclude mark, *or* any current owner of its project, may withdraw it. Task 11.7 made it `author`-only, which meant a mark whose author then left the project could never be undone by anybody — not an owner, not the observation's own author — leaving a wrongly discarded bearing permanently out of analysis. Which *kind* of mark may be made or undone is a separate, stricter question the rule table cannot express (a rule governs a stored row; an insert has none), asked by `ObservationExclusionRepository.assertMayMark` client-side and `RowAuthorizer._authorizeExclusionKind` server-side: superseding is contributor-level, excluding is owner-only. |
| `anyUser` | — | Individuals, Tags, Deployments, Tag_Versions, Estimated_Positions, Actual_Tag_Locations, Triangulation_Sessions | Shared project data with no single author. `Individuals` (task 11.240 — the animal a collar is on) joins for the reason tags have it: a contributor who identifies a chick in the field must be able to record it; unlike a tag there is no owner-only rung on editing one, because bearings attach to the transmitter and editing the animal changes what no bearing means. **`Deployments` (task 11.243 — which collar was on which animal, and when) joins for a sharper version of the same reason**: which collar went on which bird is precisely what the person holding the bird knows and the owner does not, so requiring an owner would mean it is recorded at the end of the season or not at all. It has no owner-only rung either, and that is a decision rather than an inheritance — editing a deployment *does* change what earlier bearings are attributed to, but it re-attributes exactly the window it changes and rewrites no bearing. **The interlock (design §6 — one animal, one collar at a time) is not expressible as a rule over a row's columns either**, because an overlap is a fact about the project's *other* deployments; it lives in `DeploymentInterlock`, called from `DeploymentRepository` on the device and from `SyncService.applyPush` at the boundary. `Tag_Versions` (task 11.32 — what a tag read when a record was taken) is governed exactly as the tag it versions is, and for the same reason; the owner-only rung on *changing* a tag is not expressible as a rule over a row's columns and lives in `TagRepository.assertMayEdit` and `RowAuthorizer._authorizeTagLifecycle`. **`Project_Tags` left this list with the wire in task 11.219** — adding a tag to a project copies it, so there is no link row left to govern. **Narrowed by task 11.3** from "any identified user" to *any current member of that row's project holding write rights*. The narrowing is not in the rule value, because membership and role are properties of the caller and the project rather than of the row, and answering them needs a database — see the role-gradient note below. |

Notes on the boundary:

- **Inserts are not authorized — except on `Project_Memberships`, where the
  insert *is* the grant (task 11.2).** Creating a row is normally attributed to
  its creator and harms nobody, and merge/import inserts take the raw path
  below. That reasoning fails for exactly one table: inserting a membership row
  is how somebody gets access. Task 11.1 noticed this and hand-checked the actor
  inside `grantOwner`; 11.2 turned that into a rule rather than adding a second
  hand-check, because a third caller is how the class stays open (see "Fix the
  Class, Not the Instance"). **Every insert into that table must now name a
  `MembershipInsertAuthority`, and the repository verifies it:**
  - `bootstrapOwner` — the project's first owner row. Valid only while the
    project has *no* open owner membership, and only for the user
    `Projects.owner_user_id` records. It cannot hand ownership to anyone else
    and cannot be replayed once an owner exists.
  - `byOwner(actor)` — an existing owner granting a role; this is `grantOwner`.
  - `replication(reason)` — a row decided elsewhere, written verbatim. Checks
    nothing, exactly like `MutationActor.replication` and for the same recorded
    reason: a named door that must be typed out beats a permissive default
    nobody can grep for.

  **There is deliberately no door for a join approval or a re-admission.** The
  server writes that membership row itself, from the request's own `project_id`
  and the role the owner chose, and this device receives it by ordinary pull —
  see the membership section below.
- **A row whose governing column is NULL, or that doesn't exist, passes.**
  There's nothing to authorize against, and the mutation affects zero rows.
- **Tombstoned rows are still checked** — `restoreById` targets exactly those,
  and a tombstone doesn't transfer ownership.
- **Replication exemption.** `ProjectMerger._upsert` and
  `SharedObservationImporter._upsertReplica` legitimately write rows authored
  by other users and must preserve their sync clocks verbatim. Both write
  through raw `DatabaseExecutor` statements inside their own transaction
  rather than through a repository, so neither is subject to (or needs to
  disable) these checks. `MutationActor.replication(reason)` exists as the
  named door if replication is ever routed through a repository, so the
  exemption stays a greppable argument at one call site instead of a
  permissive default. It skips the check and leaves `last_modified_by`
  untouched rather than claiming the edit.
- **The role gradient, and where each half of it lives (task 11.3).** A
  membership carries a role and the role decides what its holder may write:
  a `viewer` writes nothing, a `contributor` records and edits their own, an
  owner does everything plus membership and settings. **Two questions compose
  on every write** — *may this person write in this project at all* (the
  gradient) and *may they write this row* (the rule table above, unchanged).
  A contributor passes the first and is still held to their own observations by
  the second.
  - Resolved once, for both sides, by `resolveProjectRole` in
    `packages/tritrack_sync` — the same reason task 11.1 hoisted
    `resolveProjectOwners`. An unrecognized `role` string resolves to *no
    rights*, never to a guess.
  - Enforced on the server by `RowAuthorizer._authorizeRole`, per row, which is
    the boundary; and in the app by `BaseRepository._assertRoleMayWrite`, which
    is agreeing rather than deciding. **A `viewer` who can write because only
    the UI stopped them is not a viewer.**
  - The client's version is deliberately narrower: it refuses on an explicit
    `viewer` and on nothing else, because a local database legitimately holds
    projects this device has no membership row for — a restored backup, a
    colleague's import, one created offline and never published. Refusing those
    would make the app read-only on data it is the only holder of.
  - `contributor` writing "its own and nothing else" does **not** mean no
    shared row: recording one observation also writes a `Triangulation_Sessions`
    row and may write a `Tags` row, and neither table has an author column.
    Reading it the strict way would leave the role unable to do the one thing
    it exists for.
- **A row whose existence is itself a permission (task 11.3).** Every table
  declares `SyncTable.insertIsAGrant`, required rather than defaulted so that
  adding a table is a decision somebody wrote down. Three answer yes —
  `Project_Memberships` (the insert *is* the membership) and `Projects`
  (creating one makes you its owner). **`Project_Tags` was a third until task
  11.219** — linking a global tag made it readable by everyone in the project
  — and the flag did not become false, the operation stopped existing:
  adding a tag to a project creates a row *inside* a project the caller is
  already in, which widens nothing. The server authorizes those inserts in
  their own right, in an exhaustive switch whose unhandled branch denies; see
  `TriTrack_Security_Model.md` §4.21.1. **On the push path exactly one
  membership insert survives**: a project's own creator bootstrapping their
  owner row. Everybody else joins by an owner approving their request, where the
  server
  writes the row itself.
- **`Project_Memberships` is adopted, not dropped (decided 2026-07-31).** It
  had existed as a fully-built but entirely unused table/model/repository/
  provider with zero production reads or writes, and `ProjectRole` was
  validated on import but never compared to anything.
- **[Project_Memberships wired up — task 8.4, 2026-07-31]**
  - **Written on project creation**: `project_setup_screen.dart`'s `_save()`
    inserts an owner `ProjectMembership` row alongside the `Project` row for
    every newly-created project.
  - **Backfilled on load** for projects that predate this table's adoption:
    `currentProjectProvider`, `projectByIdProvider`, and `allProjectsProvider`
    (`app_context_provider.dart`) each call a shared `_ensureOwnerMembership`
    helper after resolving a `Project`, which inserts the owner's membership
    row if (and only if) one doesn't already exist. Chosen over a one-time
    schema migration for the same reason `currentUser`'s tombstone-recovery
    case is on-load rather than migration-based: cheap, idempotent, and
    naturally covers rows that arrive later via merge too. No new sync
    plumbing was needed — membership rows already flow through
    `sync_tables.dart`.
  - **Role lookup**: `ProjectMembershipRepository.roleForUser(projectId,
    userId)` (and the `projectRoleForUserProvider` family wrapping it) is the
    one path to "what's my role on this project" — no raw queries at call
    sites. It backs the new `projectOwner` `MutationRule` above.
  - **Decision on task 8.1/8.3's open question — ~~final~~ superseded by task
    11.1 (2026-08-20).** 8.4 answered it with "no switch": the `owner` rule
    (Projects) and 8.3's UI ownership gate both stayed on
    `Projects.owner_user_id`. Its reasons were (a) no ownership-transfer
    feature existed, so the two values could not diverge; (b) `owner_user_id`
    is a column on the row itself, checkable with the one query `_authorize`
    already ran, where a membership check adds a cross-table read for no
    behavioral difference *today*; (c) making the enforcement boundary depend
    on a second table's population state is the subtlety 8.1 warned would
    "block legitimate edits or silently permit unauthorized ones" (e.g. a
    project touched before its backfill runs).
    **The flag is now resolved the other way. See "[Project ownership — task
    11.1]" below** for what replaced it and why each of those three reasons
    stopped holding.

- **[UI/repository agreement — task 8.2, 2026-07-31]** `MutationRule` exposes a
  pure, synchronous `permits(actorUserId, governingValue)` so UI-layer "can
  edit" checks and the repository-layer check in `BaseRepository._authorize`
  call the *same* function instead of each re-deriving their own `userId ==`
  comparison. (Task 11.1: still true for `author`; the ownership rules answer
  through `resolveProjectOwners` + `permittedByOwners` instead, which is the
  same single-definition discipline over a question that needs a database.)
  `log_screen.dart` and `map_screen.dart`'s Edit affordances both call `MutationRule.author.permits(currentUserId, observation.userId)` —
  this is what fixed the map's Edit-bypass bug (task 8.2) and is what
  guarantees the two screens can't drift apart again the same way.
- **[Project ownership source of truth — task 8.3, 2026-07-31; reconfirmed by
  task 8.4; **replaced by task 11.1, 2026-08-20**]** 8.3 gated project delete
  (`projects_screen.dart`) and project settings edits
  (`project_setup_screen.dart`) on `owner_user_id` via
  `MutationRule.owner.permits(...)`. Both now gate on the project's current
  owners: `isProjectOwnerProvider` for the single-project form,
  `ownedProjectIdsProvider` for the list (one lookup for N rows rather than N
  answers resolving at N moments). Both screens render only once the answer is
  known rather than flickering a provisional one. Non-owners see the disabled
  action explained inline (a `Tooltip` on the Projects list's Delete button; a
  banner plus disabled fields on the Project Setup form) rather than a
  missing button, per the "explain, don't just gray out" pattern Phase 5.2
  established for the compass-unavailable capture buttons.
- **[Note for Phase Two]** Notes field is plain text only — no rich HTML. Sanitize inputs when server sync is added; encode output for web display to prevent XSS injection
- Tags and membership records are never deleted, only deactivated (audit trail preserved); all other records use soft-delete (`deleted_at`)
- Destructive-action undo affordances (e.g., delete-project snackbar) must auto-dismiss after a bounded time (~6s) across all screens that use the pattern, not just the one where it was first noticed


#### [Project ownership — task 11.1, 2026-08-20]

**A project's owners are its open `role='owner'` rows in
`Project_Memberships` (`end_date IS NULL`, `deleted_at IS NULL`). Any number,
all with identical rights.** `Projects.owner_user_id` is **retained as a
creator/audit record** — it is populated in every existing project and backup
and must not be dropped — but it is no longer the authorization source.

Why 8.4's three reasons stopped holding:

- **(a) is gone by construction.** 11.1 *is* the ownership-transfer feature,
  so the column and the table diverge the moment anyone uses it. Keeping the
  column authoritative would mean a creator who handed a project on retained
  full rights over it, and a successor who received it had none.
- **(b) was a cost argument, and the cost is one indexed read** on a table
  already loaded for every project screen.
- **(c) was the real one, and it is answered rather than dismissed.** The
  shared `resolveProjectOwners` (`packages/tritrack_sync`) **falls back to
  `owner_user_id` when the membership table names no open owner**, so a
  project whose backfill has not run, and the window inside a first publish
  where the server authorizes a batch's rows before writing any of them, both
  resolve exactly as they did before. The fallback cannot be used to *regain*
  ownership after a transfer, because a transfer leaves an open owner
  membership by construction — the last-owner guard refuses anything else.

**One definition, three enforcement points.** `resolveProjectOwners` lives in
the shared package for the reason the rule table does: the client's
`BaseRepository._authorize`, the server's `RowAuthorizer`, and the server's
`ProjectAuthorizer` all call it, so they cannot disagree about who owns a
project. Only the row *fetch* differs (sqflite vs. Postgres).

**`MutationRule.permits` now throws for `owner`, `projectOwner` and (since
task 11.15) `authorOrOwner`.** They
need an owner set, not a column value;
`permittedByOwners(actor, owners:, authorUserId:)` is the replacement, where a
`null` owner set means "no such project resolvable" (permits, same contract as
a null governing value) and an **empty** set means "resolved, and named nobody"
(denies). Throwing rather than leaving the old comparison working is
deliberate: any call site still asking the single-value question is a place
ownership transfer would silently not apply, and the two UI call sites 11.1
inherited were exactly that.

`authorUserId` is a **required** argument even for the two rules that ignore
it (task 11.15). Only `authorOrOwner` consults it, and a call site that omitted
it would silently deny the mark's own author — a wrong denial, which is the
same unwithdrawable-mark harm the rule was added to end. Requiring it makes
every caller state both halves of the disjunction rather than lose one by
omission.

**The last-owner guard.** A project must never reach zero open owner
memberships — nobody could then manage it, and a TriTrack server is a laptop
in a lab with no privileged operator to appeal to. Someone leaving a lab and
closing out their last stint is the ordinary path there, not an exotic edge.
Enforced in both places, because they catch different cases:

- Client (`ProjectMembershipRepository`): refuses with `LastOwnerRemoval`,
  which unlike `UnauthorizedMutation` **is** a user-facing error carrying an
  explanation. Covers all three ways a row stops conferring ownership —
  `end_date`, the tombstone, and a demoted `role`.
- Server (`RowAuthorizer._authorizeOwnerRemoval`, `DenialReason
  .lastOwnerRemoval`): catches what no client can see — two devices, each
  ending a *different* owner membership while offline. Each is legitimate
  alone; the second to arrive is refused.

**The backfill's condition changed with it.** 8.4 asked whether
`project.ownerUserId` held any open membership. That has two wrong answers once
ownership moves: a creator who transferred away holds none, so the next project
load would silently hand ownership back; and a creator demoted to contributor
holds one, so a project whose only owner had left would not be repaired.
`_ensureOwnerMembership` now asks whether the *project* has any open owner
membership.

#### [Membership lifecycle and joining — task 11.2, 2026-08-20; replaced by task 11.81, 2026-08-31]

> **Task 11.81 replaced per-address invitations with one shared join code per
> project plus the owner's approval.** The section below is written as it now
> stands. What changed, in one sentence: **holding a code used to *be*
> membership; it now buys only the right to ask, and the owner is the gate.**
> The reason was that one code per person, typed by the owner, one at a time,
> each expiring in 14 days, does not scale to a real field crew.

**How somebody joins a project.** The owner switches joining on, which mints an
8-character code for the project (`JoinService.updateSettings`, and
`join_code.dart` for the format and the entropy argument). The code travels out
of band — the server never mails a non-member — and the **whole crew uses the
same one**. Somebody who has it signs in on their own device and *asks*
(`POST /projects/join-requests`), optionally saying what they are called. That
writes a row in `project_join_requests` and **grants nothing**. The owner sees
the request, picks a role, and approves it; **the server writes the
`Project_Memberships` row itself** and the joining device pulls it like any
other row.

**A pending request is deliberately not a membership row**, and this is the
decision the whole shape rests on. Five of the places that read
`Project_Memberships` ask only *"is the stint open"* without looking at the role
— including `GET /projects/mine`, which would therefore have shown a requester
the project's name and its owner **before anybody approved anything**. Both
sides of the wire also refuse a role outside the three `ProjectRole` values, so
there is no "pending" role to invent. Keeping the request in a server-only table
makes the question disappear rather than answering it, and means **not one of
those readers had to change**.

**The server writing the membership row is the load-bearing choice, not an
implementation detail.** The alternative — the joining device pushes the row and
`RowAuthorizer` learns to permit one backed by an approval — hands the attacker
the pen: the pushed row would name its own project, user and role, and the
authorizer would have to prove each matched. Transcribing the grant from the
*request* instead, with the role taken from what the owner chose at that moment,
means the push path can keep refusing **every** membership insert from a
non-owner, with no exemption to get subtly wrong. The one seam is
`SyncService.insertServerAuthoredRow`, which is named so a second call site
shows up in a grep.

**The role is never in the code**, which is what makes a leaked code
uninteresting: there is no such thing as a leaked *owner* code.

**No expiry, and the owner switches joining off.** An invitation expired because
it was handed to one person for one purpose; a project's join code is
infrastructure that lives on a whiteboard for the season. A hidden expiry
produces *"the code stopped working and nobody knows why"*.

**The code is stored readably**, which is a **named written exception** to
Security Model §4.2 — see **§4.2.1**, which gives the reasoning (a join code is
no longer a credential), bounds what the exception covers, and states the
condition under which it lapses. It buys the owner the ability to re-read the
code instead of rotating and re-broadcasting to a whole crew.

**An owner may also put a past member back directly**
(`POST /projects/<id>/members/readmit`), with no code and no request. The bound
that makes that safe comes from the project's own history: the named person must
already hold a **closed** membership row here and no open one, so it can only
reverse a removal the owner themselves made and cannot add a stranger.

**Neither the app's database nor the sync protocol moved.** Both new tables are
server-only, created by `PostgresMigrations._ensureServerOnlyTables`;
`latestSchemaVersion` stayed 9 and `schemaMajorVersion` stayed 2, so no device
in the field had to chase a version.

**Joining is the one part of the app that requires connectivity**, and the flow
says so rather than letting somebody discover it at a trailhead. Everything else
on the members screen — who is on the project, in what role, past stints,
changing a role, removing somebody — reads and writes local SQLite and works
offline. Only the *join code and the pending-request list* need the server,
which is why they are separate providers that can fail without taking the member
list down with them.

**Rejoining creates a new row; `end_date` is never nulled.** The record of the
prior stint is the point of keeping it: it says this person collected data on
this project between two dates, which is what a permit report or a publication
needs. The invariant that matters is on the **pair**: for any single
(project, user) pair, at most one row with `end_date IS NULL`. It constrains the
pair and never the user — one person holding open memberships in ten projects is
the normal shape of this user base, not an edge case, and nothing in the schema,
the protocol or the authorization model may assume otherwise.

**A member whose profile has not arrived yet.** `Project_Memberships.user_id` is
a foreign key into `Users`, and a new member's profile is synced data that
reaches the server only when their device next pushes — after approval. So
approval mints a `Users` row if one is missing, from the address the server
itself authenticated. **It leaves the name empty on purpose**: the server does
not know their name and must not invent one on the row that attributes field
observations. Its `updated_at` is the epoch and its `revision` is 0, so under
`MergeResolver`'s ordering every real row beats it — otherwise somebody whose
profile predated their request would push their real name, lose the merge, and
have a blank row pulled back over it. The UI falls back to the address
(`ProjectMember.displayName`).

**And note what is deliberately *not* written there: the name the requester
typed.** That string exists so an owner can recognize who is asking — Michael's
decision of 2026-08-31, and the reason is that an owner may simply not recognize
`f.lastname@nau.edu`. It is caller-supplied, it is rendered to the owner as a
claim rather than as a fact, and it is bounded by the same
`RowValidator.isWellFormedPersonName` a synced `Users` row's name carries —
length, control characters, and **bidirectional-override characters**, which
matter here more than anywhere else in the app because the pending-request
screen is the one place a person decides whether to trust somebody by reading a
string. Letting that claim become the app's record of who took a bearing would
turn it into an attribution, which is the harm §4.17 is about.

**Role changes and removal travel by ordinary sync**, not through endpoints of
their own: both are *updates* to a row the rule table already governs, checked
on the device by `MutationRule.projectOwner` and again on the server by
`RowAuthorizer`, last-owner guard included. A dedicated route would be a third
place for the same decision to be made slightly differently.

### Test Signal Integrity — standing rule
- **A test that cannot run must not look like a test that passed.** Phase 10
  hit this shape three times: a swallowed sign-in exception that let a bug
  reach a real phone with 700+ tests green; task 10.26's red
  `no_committed_secrets_test.dart` that had been failing so long nobody was
  reading it; and task 10.31, where 139 server tests silently skipped with
  no database and 11 more (`test/sync/tombstone_retention_test.dart`) were
  missing the same skip guard entirely, so they errored instead — a plain
  `dart test` run with no Postgres configured was still reported as an
  overall pass.
- **When a test's preconditions aren't met, that must be loud, not quiet.**
  A `skip:` is acceptable for genuinely optional local dev friction (no
  Postgres running), but a suite must never let "all preconditions
  unmet" report the same success as "everything ran and passed" — see
  `server/test/support/database_coverage_guard_test.dart`, which fails
  (never skips) whenever no database is configured, so a no-database
  `dart test` run exits non-zero instead of green.
- **Don't let the guard itself rot into copy-pasted boilerplate** — that is
  exactly how `tombstone_retention_test.dart` ended up with the guard code
  present but never wired into a `skip:` argument. Route new Postgres-backed
  tests through the one shared helper
  (`server/test/support/database_test_config.dart`) instead of writing a new
  `_config`/`_skipReason` pair.
- **A run's skip count is a number worth watching, not just a detail in the
  log.** `scripts/run_server_tests_docker.sh` (a real database) is the
  canonical way to get a trustworthy green signal for the server suite;
  expect zero skips there. A `dart test` run outside that script skipping a
  large, stable number of Postgres-gated tests is a known state, not
  evidence of coverage — don't treat it as a substitute for a gate run.
- **A change under `packages/tritrack_sync/` touches client *and* server —
  Done requires both suites, in a configuration where all of their tests can
  run.** Task 10.67 strengthened shared validation there, re-ran `dart test`
  in `server/` with no Postgres configured, saw the pre-existing
  no-database guard fail, and treated that failure as expected background
  noise — "261 tests, minus the pre-existing no-Postgres-configured guard,
  confirmed by `git stash`" — rather than as the suite refusing to answer the
  question the task actually needed answered. It genuinely had not
  regressed anything the 261 tests covered; what it missed is that the two
  tests its own change went on to shadow (task 10.68) were in the 190 the
  guard's failure was standing in for, and a stable skip count is only
  evidence of "no new skips," never evidence that what's skipped doesn't
  matter to *this* change. `git stash`-diffing a skip count is not the same
  check as running the suite where it doesn't skip — for `packages/
  tritrack_sync`, run `scripts/run_server_tests_docker.sh` before reporting
  Done, every time, not only when the diff touches `server/` directly.

### Data Custody Signals — standing rule
- **No surface may report success while a record exists only on the device.**
  Task 10.28 (Gate C finding D-3) found the sync engine discarding a row the
  server had refused, advancing the push watermark past it, never re-offering
  it, and the app reporting a green "Synced." The same hole existed in
  `ProjectPublisher.publish`, which ignored per-row outcomes entirely and
  returned a count of rows *sent* labeled as rows uploaded. For a primary
  scientific record that is silent loss of irreplaceable field data — the risk
  this project ranks above all others.
- **Account for every row, and treat silence as a refusal.** A push offers
  rows; the response must be reconciled against what was offered, not merely
  read for the outcomes it happens to contain. An offered row with no outcome
  (reachable under version skew) is held, not assumed applied. The
  classification is an exhaustive `switch` over `SyncRowOutcome`
  (`HeldRowReason.forOutcome`) so a new outcome cannot silently join the
  accepted branch — which is precisely how `unauthorized` and `invalid` fell
  through a `continue` written for `lostToServer`.
- **Held, explained, and retryable — not retried forever, and not dropped.**
  The legitimate refusal (task 10.20 declining a replica that names a
  colleague who is not on the project) is permanent until somebody changes the
  project's membership. So the refusal is recorded durably
  (`SyncHeldRowStore`), counted (`SyncStatus.heldCount`), explained in
  client-authored copy, and offered again only when the row changes or the user
  asks. Bookkeeping is one record per refused row, never one per refusal —
  a refusal is a remote decision that could repeat without bound (task 10.30's
  lesson, applied locally).
- **Two different statements, two different numbers.** "Waiting to sync" means
  it will go on its own; "refused" means it will not. A row must never be
  counted in both, and a warning must clear when its cause does.
- **What still needs to go to the server is recorded, not inferred**
  (task 10.33). The push used to select by `updated_at >= watermark`, a single
  per-project mark set to the highest row *offered* — an approximation that
  loses rows in two ways: a row a batch limit never reached ends up below a mark
  it was never offered against, and an imported replica carrying its sender's
  clock (task 6.3) is below the mark the moment it is written, on any device
  that has ever synced. Selection is now a join against `Sync_Row_Receipts`,
  one durable receipt per row the server has confirmed, and a row is pending
  unless a receipt matches its current `updated_at`. **Anything unrecognized is
  pending**: an unknown clock, an unfamiliar write path, a restored backup, an
  interrupted round all fail toward offering the row again. Over-pushing costs
  bandwidth; under-pushing loses an observation, and those are not comparable.
- **The count the user sees must be the set the push will offer.** Both are
  computed from one predicate (`_pendingClause`), not two that agree by
  convention. A status number derived separately from the behavior it
  describes is a number that will eventually be wrong about a missing record.
- **The corollary for reviews:** a correct server refusal is only half of a
  correct system. The client surface that reports it is in scope for the same
  review — `SyncStatusScreen`/`SyncStatusBanner` had no widget test at all when
  D-3 was found, which is the same blind spot that put the sign-in bug on a real
  phone with 700+ tests green.

### Fix the Class, Not the Instance — standing rule
- **A remediation's acceptance criteria must name the class the finding
  belongs to and enumerate every other site where that class could occur,
  with a verdict per site.** "Fixed where it reproduced" is an incomplete
  task. A verdict is one of: fixed here; verified unaffected (state why);
  or open — needs its own task (state why it's out of scope for this one).
  Silence about a site is not a verdict.
- **This binds whoever writes the task brief, not only whoever implements
  it.** Most of the recorded instances below were briefed by a file that
  named only the reproduction — the implementing session did exactly what
  it was asked, and the class stayed open. A brief that hands over a single
  repro without asking "where else could this shape live?" has already
  failed the task before implementation starts.

### Open Needs an Owner — standing rule
- **A finding recorded as open must leave the session with a task number, or
  it has not been recorded — it has been described.** "Fix the Class, Not the
  Instance" above already requires a verdict per site, and one of its three
  values is "open — needs its own task." This rule is the enforcement of that
  clause: the task number (or an explicit accepted-risk entry naming who
  accepted the risk and why) must exist **before the session that wrote the
  verdict ends**, not at some later point someone remembers to circle back.
- **Why this is its own rule and not just a restatement:** task 10.66 adopted
  "fix the class, not the instance" and it worked — `TriTrack_Security_Model.md`
  §4.19.1 enumerated eight import paths, asked the right five questions of
  each, and recorded three as Open. The sixth gate's two blocking findings
  (K-1, K-2) were both on that list, unscheduled, for six weeks. The class was
  named and the sites were enumerated correctly; the step that failed was the
  one after — nobody gave the open items a task number, so a written "Open"
  read exactly like a written "Closed" to anyone who didn't re-read the
  detail lines. Task 10.72 is the sweep that found and fixed this once; this
  rule is what stops it from needing a second sweep.
- **An accepted-risk entry is a legitimate alternative to a task, but it must
  name a person and a reason** — not just describe the risk again. §11.7's
  `User_Emails`/`Tags` decision (accept both, amend the rule that overclaimed)
  is the model: it says who decided (left to the planning session, decided
  explicitly) and why (the keys are unenumerable random UUIDs; the structural
  fix is unavailable without a redesign of the identity tables). A finding
  restated as "accepted" with no reasoning attached is the same silence this
  rule exists to close.

### Additive vs Subtractive — the role gradient's dividing line
- **Additive writes that unblock field work are `contributor`-level.
  Subtractive writes that change what the whole team sees are `owner`-level.**
  Decided 2026-08-17 on task 11.11's report; apply it rather than re-deciding
  each case.
- Creating a tag is additive and unblocking: a contributor who cannot create one
  cannot record the animal in front of them. Making that owner-only would trade
  a tidiness problem for permanent data loss on the primary use case.
- Unlinking a tag from a project is subtractive and edits *shared configuration*
  — it disappears from every member's list, including someone mid-transect. That
  it is reversible with UNDO is not the deciding factor; UNDO helps the person
  who did it, not the teammate who synced in between.
- The asymmetry that settles close calls: a contributor blocked by an owner-only
  rule sends one message and loses nothing. An owner whose shared configuration
  was changed underneath them has to *notice* first, and mid-season may not.

### Commit Before Updating Status — standing rule
- **A task's `Status` may not be set to Done until its work is committed.**
  Four times in Phase 10 a task marked itself Done and left its work
  uncommitted, so the plan asserted "finished" while the disk held nothing.
  Tasks 10.65 and 10.67 were the fourth: twenty files, three of them new,
  both entries reading `Done`.
- **This is "the record gets ahead of the code" in the workflow rather than
  the codebase** — the same failure the gates keep finding, one level out.
  It is worse here than it looks: the natural check is `git log`, which is
  silent about uncommitted work, so the state looks correct from the outside.
  `git status --porcelain` is the check that can actually fail.
- If a session genuinely should not commit — because the tree holds another
  task's work it cannot attribute — it must **say so explicitly in its final
  report and leave `Status` as In progress**, not report Done and stay quiet.
- **Six recorded instances, each costing a full gate cycle to re-derive:**
  C-3's cleartext exemption → E-2 → G-2 → I-9 (three more rounds on
  compose/build-mode cleartext); H-5's non-`Map` row silence, fixed for one
  shape and reopened by J-5; I-1's rate-limit source-identity collapse →
  J-2's second deployment shape; I-10's restore-role fix on the always-on
  superuser connection (task 10.63); and weak assertions — a check that
  cannot distinguish success from its own failure — found five separate
  times (the sign-in swallow, task 10.26's detector, task 10.31's server
  skips, task 10.39's e2e skips, task 10.37's backup-drill exit code)
  before being named as one class.
- **A comment that explains why a control cannot work in some configuration
  is a finding about that configuration, and must name it** rather than
  just justifying a local escape hatch — the same corollary task 10.62 drew
  out for `rate_limiter.dart`'s per-source-limit exemption comment.
- **The corollary for instruments:** an instrument that measures one site of
  a class and is described as confirming the class is closed has the same
  shape as the underlying defect. Task 10.65's detector — proving each
  instrument fails both when its subject is broken and when its own tooling
  is broken — is this rule applied to the gate's own tooling, not just to
  application code.

### A Check Must Name What Is Wrong — standing rule (added 2026-08-27)
- **A check that fires correctly and does not say what is wrong is half a check.**
  This project already has the rule that *a check which cannot distinguish success
  from its own failure is not a check*. This is its sibling: an instrument must be
  able to fail, **and its failure must be legible to whoever has to act on it.**
- **When it fires, it must name two things: what is wrong, and what to do next.**
  Not a code, not a null, not "something went wrong" — the record, the rule, the
  action.
- **Four instances in three days, which is why this is a rule and not a bug
  report:** a waiting-to-sync screen whose banner said "tap to see why" and whose
  detail screen would not say why; a failure that surfaced as a null reference
  instead of naming the missing variable; a suite that failed only after the wrong
  command was run, rather than saying which command was right; and a test that could
  not tell a duplicate row from a broken insert. Each was fixed on its own. **The
  cost is measurable: the first of those turned a diagnosis into an afternoon of
  guessing at something the app already knew.**
- **The audience test bounds this — it is not a license to gold-plate every error
  string.** It applies wherever the reader is a person who must then act: anything
  user-facing, and any developer-facing failure that blocks work. An internal
  assertion in a hot path is not in scope.
- **The corollary, and it is the one that keeps being expensive:** when an
  instrument cannot tell you what happened, **fix the instrument before the thing
  it was pointing at.** Debugging around a broken instrument produces a guess that
  looks like a diagnosis.

### Never Write the Number of Synced Tables — standing rule (added 2026-08-21)
- **In present-tense prose, write "every synced table," never a count.** Say
  which ones only by pointing at the single enumeration, which is the code's
  `SyncTable` list.
- **Why.** A number in a sentence is a hand-maintained copy of something the
  code already knows, and it goes wrong silently the moment a table is added.
  Task 11.7 added a twelfth table; within one week that one addition had left a
  stale count in six sections of the security model, two task write-ups in the
  plan, one source-file doc comment, and — worse than any of those — **two gate
  instruments**, so the H-3 disclosure sweep and the governing-column checks
  were both measuring eleven-twelfths of the system while reporting complete
  coverage. This is the same defect as any other hand-kept mirror of what the
  code knows; the difference is that when an instrument has it, the report says
  "clean."
- **The exception, and it is not optional: dated records stay as written.** A
  sentence recording what a specific gate run measured on a specific day is
  history and is correct. Rewriting it to match today's count converts an
  accurate record into a false one. This is why a find-and-replace is always
  the wrong tool here, and why anyone doing this work reports how many
  sentences they changed *and* how many they deliberately left.
- **The structural version of this rule is a test, not care.** Task 11.22
  asserts from `SyncTable` itself that every governing column is type-checked.
  Prefer that shape wherever a count matters to correctness: derive it, and
  prove the derivation can fail.

### A Guard Derives Its Subject — standing rule (added 2026-08-28)
- **A test that exists to prove a property holds everywhere must work out
  "everywhere" from the code, not from a list somebody keeps.** If it cannot,
  it must say so in its own text, say what the list cannot see, and be built so
  that forgetting an entry turns it **red** rather than leaving the new case
  silently exempt.
- **The failure this rule exists to prevent.** Four consecutive weeks of
  findings were the same defect wearing different clothes: a hand-kept mirror
  of something the code already knew. Task 11.14 (role-aware controls), task
  11.21 (the H-3 sweep that never learned about the twelfth table), task 11.23
  (the permissions matrix), and task 11.45 (a five-file list of the paths that
  tell the screens data arrived, and a nine-file count standing in for
  end-to-end coverage). In every one of them the list was *accurate on the day
  it was written* and the guard was green while the property was false.
- **The two shapes that pass this rule.**
  1. *Derived.* Compute the set from the code — the `SyncTable` enumeration,
     the repositories a display provider actually reads, the methods declared
     on the client's transport class. Adding a case adds it to the guard.
  2. *Fail-closed with reasons.* Where derivation is impossible, invert the
     list: enumerate what is **exempt** or **not yet covered**, each with a
     reason, so an unrecognized case fails. An exemption must also fail when it
     stops being true, or it rots into cover for something it was never about.
- **A guard nobody has watched fail is not a guard.** Before a session that
  writes or changes one ends, it must have made the guard go red on purpose —
  by adding the case it claims to catch — and said in its report what it did
  and what the failure looked like. This is the same discipline as task 10.65's
  instrument self-checks, applied to ordinary tests.
- **Say what it still cannot see.** Every derivation has a horizon: a table
  name built by string interpolation, a repository reached through an unusual
  expression, a file deleted whose loss removes no property the guard can name.
  Write the horizon down in the guard, where the next reader will look, rather
  than letting the green result imply there isn't one.

### Announcing During a Build Deadlocks the Provider Being Built — standing fact (added 2026-09-04, task 11.151; **measured properly and closed by 11.153, 2026-09-04**)

- **`DataArrival.announce()` can be called from inside a provider's build**, so any listener that
  reacts by invalidating providers can be invalidating one that is mid-build. `currentUserProvider`
  announces when it auto-creates a device's first user, **so this is the first-run path**, not a
  test artefact.
- **What invalidating a mid-build provider actually does, measured by 11.153 on riverpod 3.3.2 with
  this app's own providers — the three outcomes are different and only one of them is loud:**
  - **A `keepAlive` provider hangs silently.** A bare `container.read(currentProjectProvider.future)`
    with an announcement landing mid-build **never returned, and nothing threw.** On a phone that is
    a screen that never finishes opening with no error to report.
  - **An `autoDispose` provider throws** — *"disposed during loading state, yet no value could be
    emitted"*. Legible, and it is what most of this app's providers are.
  - **A provider a widget is watching recovers** on the rebuild the invalidation triggers. So the
    hazard is invisible to any test that pumps a screen, and lives entirely in `ref.read(x.future)`
    call sites and in `await container.read(x.future)` in tests.
- **Deferring the invalidation to a later event-loop turn does not help, and this was worth
  measuring rather than assuming.** A `Timer.run` made **no difference at all**: an `async` build
  stays "building" across its own awaits, so a timer lands inside the window as readily as a
  synchronous call. **The intuition that "later is safer" is wrong here.**
- **What does work is waiting until the provider has settled.** `ArrivalRefresh`
  (`lib/core/providers/arrival_refresh.dart`) holds the whole refresh back while any provider on its
  list is mid-build, and re-runs it the moment that one finishes — **waiting, never dropping**,
  because a sync round racing app start would otherwise lose exactly the refresh it exists to
  deliver. `arrival_refresh_test.dart` has a case that times out at four seconds without the guard.
- **The stated limit: a *family* cannot be checked this way.** Riverpod 3.3.2 exports no way to
  enumerate a family's live instances, so only the non-family providers can be asked whether they
  are mid-build. That is tolerable because every family on these lists is `autoDispose`, which is
  the loud outcome above — **but it is a limit, not a proof, and the next person to add a
  `keepAlive` family to a refresh list has re-opened this.**
- **A SECOND DOOR EXISTS AND ONLY ONE OF THE THREE OUTCOMES ABOVE DESCRIBES IT** — added
  2026-09-04 from task 11.160, which re-checked each one rather than assuming this entry covered
  it. **The door is `TickerMode`**, toggled by the tab shell on every tab change, and it reaches
  the same "wrote during build" fault **with no `package:tritrack` frame in the stack at all.**
  - *"Invalidating a provider while it is building orphans the Future an awaiter is holding"* —
    **does not apply here.** Nothing is building when a Profile save invalidates
    `currentUserProvider`; the invalidation raises nothing at all, which 11.160's test asserts.
  - *"Deferring to a later event-loop turn does not help"* — **holds, and for a stronger reason
    than the one recorded above.** The fault arrives roughly **300 milliseconds** after the
    invalidation and is raised by a **tab change**, so no amount of deferring the *write* can
    reach it.
  - *"Waiting until the provider has settled fixes it"* — **does not apply.** `ArrivalRefresh`'s
    settle-first guard has nothing to hold back, because nothing on its `settleFirst` list is
    loading at the moment of the write.
  **So `ArrivalRefresh` is not the pattern to copy for a `TickerMode`-entered fault** — which is
  the opposite of what task 11.160's own brief offered as a starting point, and the brief was
  wrong. **The fix that worked is in the tab shell's branch container**, one place rather than at
  `currentUserProvider`'s three invalidation sites.
  > **The transferable part: a recorded set of outcomes is a set of outcomes *for the door somebody
  > measured*.** This entry said "invalidating a mid-build provider has three outcomes" when it
  > meant "three outcomes when the invalidation arrives through `DataArrival`." **Re-check them
  > against a new entry point rather than reading them as a law.**
- **Which routes are covered.** All eight *local* tag routes go through `refreshTagViews`
  (`tag_view_refresh.dart`); all local membership routes go through `refreshProjectViews`
  (`project_view_refresh.dart`, which is the list `membership_provider.dart` used to hold inline);
  and **everything arriving from another device goes through `ArrivalRefresh`**, attached to
  `DataArrival` rather than to `SyncController` for task 11.45's reason — the caller that forgot was
  the sync pull.

### What `currentProjectProvider` Costs — standing fact (added 2026-09-04, task 11.120)

- **9–21 ms once per app launch**, and **8.8 microseconds per rebuild.** The launch cost is
  preferences, opening and migrating the database, the row read and the owner-membership
  backfill — **and the database open is a cost every screen pays anyway.** It is `keepAlive`, so
  every later read is a cache hit with no I/O.
- `test/features/more/current_project_watch_cost_test.dart` **prints both numbers every run and
  fails if a rebuild ever starts doing work.**
- **These are macOS host numbers and nothing here can run a phone.** What transfers is the shape,
  not the milliseconds: a phone's storage is slower, and the number of times it is touched is the
  same.
- **It was suspected of a 250x test slowdown for three days and was innocent.** The real cost was
  the tile counter building a whole tile list to measure its length at the whole-planet default
  zoom. **The map, record and log screens that also watch this provider are fine** — that branch
  is closed, not deferred.

### What the Offline Suite Actually Runs — standing fact (added 2026-09-04, task 11.156)

- **The suite states its own scope every run:** *"250 suite(s) loaded of 250 `*_test.dart` on
  disk; 2196 test(s) ran, 15 skipped"*. **If the first number stops matching the second, the run
  goes red and names the files it missed.** Before this it echoed PASS on an exit code —
  `flutter test test/localization` loads **7 of 250 files** and exits zero.
- **There are 15 skips, not "a standing count" implying many**, and they are **whole files
  skipped by a tag in `dart_test.yaml`** — 14 under `test/e2e/` and one under `test/network/`.
  **That is what made asserting the declared set easy rather than hard**, and it is why the
  answer here was a set and not a number.
- **Two files under `test/e2e/` are NOT tagged and do run offline:** `suite_coverage_test.dart`
  and `publish_corpus_test.dart`, which analyze the e2e suite rather than talking to a server.
  **A future task reading "test/e2e/ is skipped" would get that wrong**, which is why it is
  written here.
- **`test/declared_skips.json` is correct on macOS and Linux and would fail on Windows**, where
  two tests in `dev_stack_host_prerequisites_test.dart` skip themselves on `Platform.isWindows`.
  They are deliberately not declared: **a declared rule that matches nothing is itself a
  failure**, so declaring them would break the check on the machines that actually run it.
  Nobody develops or runs CI for this project on Windows. Stated in that file's own header too.
- **The JSON reporter's cost is below the noise floor of the machine that measured it, and that
  is the honest answer rather than "free".** Four timed runs: with the reporter 111.3 s and
  106.4 s; without it 81.7 s and 84.8 s. **The two reporter-free runs of an identical command
  differed by 29.6 s on their own**, so no number can be put on the reporter beyond "smaller
  than that".

### The Pre-Commit Suite, and What `flutter test` Will Not Tell You — standing fact (added 2026-09-06, task 11.180)

**A commit made from a Claude window runs the whole suite first and is refused if anything fails.**
`scripts/pre_commit_suite.sh`, wired as a `PreToolUse` hook in `.claude/settings.json`. **96 seconds
per commit, measured** (88 s on a later run).

> **It works, and it is invisible from inside the window — which is how it came to be reported
> dead.** **A `PreToolUse` hook's stdout on success is not shown to the session that triggered it**,
> so there is nothing on screen to see. And **a `PreToolUse` hook completes *before* the command it
> guards begins**, so `time git commit …` inside a tool call is **structurally incapable of
> containing the hook** — task 11.181 timed exactly that, got 0.088 s, and concluded the hook was
> dead. **It had been running since 11.180 landed.** **To ask whether it ran, make it say so; do not
> time the command next to it.**
>
> **No git `pre-commit` fallback is needed and none exists.** `.claude/settings.json` is committed,
> so the hook has no install step for anybody to forget. It closes the window between a test breaking and somebody noticing — which
was **two commits, and would have been until the next push**, since this project pushes in batches.
**It does not bind a commit typed into a terminal by hand.** The escape
(`TRITRACK_PRECOMMIT_RED_IS_PREEXISTING=1`) exists because three windows share one tree; using it
obliges an entry in `TASK_COMMS.md`.

**Suite size as of 2026-09-06: 2358 tests across 263 test files, green.**

> **The instrument-design finding underneath it, which is the reusable part.**
> **`flutter test`'s ordinary human output cannot tell you what ran.** The expanded reporter
> attributes each line to the suite it is *currently loading*, so **122 files that really did run
> never appeared in an 8234-line green run.** Anything deriving which suites loaded, which tests ran
> or which were skipped must read `--reporter json`'s `suite` events. **Checked 2026-09-06: every
> `flutter test` caller in `scripts/` and `.github/workflows/` that derives a verdict already uses
> the JSON reporter** — `pre_commit_suite.sh`, `run_offline_suite.sh`, `run_e2e_tests.sh`,
> `assert_suite_scope.py`, `lib/suite_verdict.py`. **Not checked:**
> `verify_ats_transport_security.sh` and `verify_session_store_keychain.sh` use `flutter drive` and
> read its exit code, which is a different question.

**Why the app-shell ledger's per-file counts stay**, settled here so it is not re-opened: between
task 11.110 counting the bare-pumping tests and task 11.118 counting them again, the population went
**205 → 219 cases across the same 28 files.** The growth was *inside* files already listed — **which
is precisely what the file set alone cannot see.** The friction is real and frequent (in the
ledger's first four days, **all five edits to it were count bumps and none was a set change**), and
it is accepted: what was wrong at commit `1d4bfd5` was *when* somebody found out, not what they were
asked to maintain.

### There Is A Picture Machine, And It Is Not Under `test/` — standing fact (added 2026-09-07, task 11.186)

**`integration_test/screenshots/` boots the real app on a real iOS simulator at App Store device
geometry and photographs 33 states across two device profiles.** `review.dart` compares each new
image against the committed one, names every screen that moved, writes a diff picture, and **stops**
— `--accept` is a separate command a person types after looking. **66 committed images.** It has
existed since before any of the tasks that ended by asking Michael to look, and the code lane did
not know.

> **So `matchesGoldenFile` appearing nowhere under `test/` is true and points at the wrong
> conclusion.** The measurement was right; the inference from it was not.

**Goldens under `test/` are refused, and the refusal is coupled rather than written in prose.**
`test/documentation/rendering_verification_policy_test.dart` reddens on a `matchesGoldenFile` under
`test/` unless somebody adds an argued entry — **and it reads the simulator harness, so if that
harness is deleted or its `--accept` gate removed, the policy reddens and the decision must be made
again rather than inherited.** Watched red four ways.

**The two numbers that decided it, measured over Phase 11 rather than asserted:**

- **20 requests across 16 tasks** where a task could not settle an appearance question and handed it
  to Michael. **20 of 20 were about a change the same task had just made on purpose** — so a golden's
  only honest claim, *"this did not change"*, would have been re-blessed in that same commit. **Not
  a majority. All of them.**
- **Every rendering defect this project has actually caught was caught by a number, not a picture**
  — 11.126's three live overflows, 11.109's bearings list at 83.5 then 42.5 pixels, 11.149's
  zero-pixel viewport, 11.162's structural floor, 11.166's derived overlay sets, 11.177's 10.5° and
  20.5°, 11.178's wrap guard. **Zero by anything picture-shaped.**

**Two limits, both open and both recorded rather than fixed.** **Nothing runs the harness on a
schedule** — it is now checklist item B2, deliberately a human step, because its value is entirely in
a person doing the accepting. **And it photographs one text size:** there is no `TextScaler` anywhere
in `integration_test/screenshots/`, so all 66 images are at the default — **which is exactly the axis
nearly every open rendering question sits on** (11.149, 11.162, 11.164, 11.166, 11.167). That is
named in `WEBSITE_PLAN.md` as a restart item for the content lane, which owns the harness.

### The Pending-Decision Sweep Was Measured And Refused — standing fact (added 2026-09-07, task 11.179)

**Do not commission a vocabulary sweep for sentences saying a decision is still owed.** Task 11.179
measured it before proposing anything: **19 phrasings, ~155 matches repository-wide, 34 of them
outside `CLAUDE_DOCS/`, and exactly one is a live claim that a decision is owed.** *"Undecided"* in
this repository is **domain vocabulary for a join request**, so a checker on that shape would flag
dozens of join requests forever — **which is how a check gets turned off.**

**The one live claim is wired instead.** The backup health check prints a sentence saying where the
server's archives are copied to has not been chosen yet — true, and the line task 11.80 stopped at.
**A test now requires that sentence and 11.80's status to agree**, so the day somebody records
11.80 as finished the build goes red until the sentence is rewritten. The risk is unchanged —
**nothing copies a backup off that machine** — but it can no longer be quietly forgotten.

### How Big the Hand-Kept Surface Actually Is — standing fact (added 2026-09-06, task 11.123)

**`CLAUDE_DOCS/*.md` carry 712 `path:NN` citations.** 251 in `DEVELOPMENT_PLAN.md`, 176 in
`PERMISSIONS_MATRIX.md`, 158 in `TriTrack_Security_Model.md`, 66 in `UNEXERCISED_CONTROLS.md`, 61
across the rest. **688 resolve to exactly one committed file, 22 name a file that no longer exists,
2 are an ambiguous basename, and none points past the end of its file.** That last number is why the
obvious cheap check — *a line number beyond the end of the file is a failure* — **would go green
today and catch nothing.** Measured so nobody proposes it again.

**`TriTrack_Security_Model.md` has 304 headings; `PERMISSIONS_MATRIX.md` has 36.** This is why the
two documents mark derivation differently, and the difference is deliberate. The matrix carries a
`***Derived***` / `***Hand-kept***` marker on every heading. The security model carries **one
registry at the top** stating that everything is hand-kept except the sections it names — because
marking 304 headings would have added ~600 lines of boilerplate to the document this project treats
as its record of decisions. **The guarantee is preserved by coupling, not by repetition:** a check
requires the registry's list to equal the set of `***Derived***` markers in the body, so neither can
drift alone. **Ratified by the planning session 2026-09-06 as the better shape, over the brief's
own instruction.**

> **And the reason the whole exercise is worth its cost, in one number.** §4.21.2 was missing rows
> for **ten** routes. The brief named nine of them. **The tenth was `GET /auth/sessions`, which the
> brief did not know existed** and which had been absent from that table since it was written.
> **A hand-check of the routes the brief listed would have closed the table and left it out.** The
> enumerator found it because it enumerated the routes instead of reading the list it was handed.

### One File Owns Readiness Waiting — standing fact (added 2026-09-06, task 11.176)

**`scripts/lib/wait_for.sh` is the only readiness loop this repository should grow.** It polls
quietly, keeps every attempt's combined output, and hands the last attempt's back through
`wait_for_evidence`, so **a loop that runs out says what it actually got** instead of printing a
verdict it guessed. Its header carries the story that caused it. **A task that needs to wait for
something to come up calls this; it does not write a fresh `for _ in $(seq 1 60)`.**

**Four of the seven scripts use it** — `verify_h6_archive_forgery.sh`, `backup_restore_drill.sh`,
`verify_source_identity.sh`, `verify_ats_transport_security.sh`. **Three were deliberately left**
— `verify_i1_source_identity.sh`, `verify_tls_termination.sh` and
`verify_deployment_refusal_matrix.sh` already read the subject's own log or container state and
print it on every failure path; `verify_i1` and `verify_tls` also distinguish *refused to start*
from *not up yet*, which is the behavior worth copying. **Each of the three carries a comment
saying 11.176 looked at it and why it was left**, so the next sweep does not re-derive the
judgement.

**What it does not do.** It fixes the thrown-away-evidence half only. **It cannot fix a compound
probe** — one whose success needs three unrelated things — because only the caller knows what its
probe touches. h6 was the only real instance of that among the seven.

### Pinning an Alpine Package, and What a Digest Pin Does Not Buy — standing fact (added 2026-09-06, task 11.175)

> **Superseded on 2026-10-05 by task 11.327: the version pin described below broke too.** Alpine's
> *stable* 3.24 branch upgraded `age` from 1.3.1 to 1.3.2 on 2026-10-04, so `age=~1.3.1` stopped
> resolving exactly as `-r5` had. **No Alpine index keeps old versions, stable or not.** The pin is
> now the Alpine release in the `FROM` tag (`postgres:16-alpine3.24`), with version *floors*
> (`age>=1.3.2`, `minisign>=0.12`) on the `apk add` line. Its cost is that the release stops getting
> fixes for these two when Alpine retires its community repository (2026-11-01 for 3.24), which the
> nightly check's preflight warns about. The reasoning is in `server/backup/Dockerfile` and Security
> Model §3.8. The section below is kept as the record of the first attempt; its point about digest
> pins still holds.

**`apk add age=1.3.1-r5` is not a version pin.** `1.3.1` is the upstream version; **`-r5` is
Alpine's own build number for that same version**, and a rolling repository *replaces* those rather
than accumulating them. On 2026-09-06 Alpine shipped `-r6` and dropped `r5` from the index, and
`server/backup/Dockerfile` stopped building — taking three gate instruments red with it, on a day
nobody pushed anything to that file.

**What is used now, and what it means, measured rather than assumed.** `age=~1.3.1` and
`minisign=~0.12`. **`=~` is a component-wise prefix match**, so:

- `age=~1` resolves, `age=~1.3.1` resolves, **`age=~1.4` is refused** — an upstream upgrade is still
  a deliberate edit to that line.
- **`minisign=~0.1` does *not* match `0.12`** — the components are compared whole, not as text.

**The exact bytes are deliberately no longer pinned.** A bad Alpine rebuild of the same version is
picked up without an edit here; vendoring both binaries with checksums would prevent that, and was
judged the worse trade for two widely-used tools. **The reasoning is written beside the line in the
Dockerfile so it can be disagreed with rather than rediscovered.**

> **Pinning `FROM` by digest would not have helped, and it is worth knowing why.** A digest freezes
> the *base image*. **`apk` fetches the package index over the network at build time**, so a frozen
> base still resolves package names against today's rolling repository. **A reproducible base image
> does not give you reproducible packages.**

### The Committed-Secret Scan — standing fact (added 2026-09-04, task 11.150)

- **The history is clean, established 2026-09-04 over 652 commits and 4,744 distinct blobs.**
  Confirmed twice by independent means: the Dart test, and a shell pass streaming every blob
  through `grep` without using any of that test's code. **No historical `.env`, no key or
  certificate file, no age private key**; the only six PEM matches in the whole history are six
  past revisions of the scanner file itself, which is on the exemption list for that reason.
- **Two blob counts appear in the record and they are not a contradiction. 4,744** is every
  distinct blob; **4,246** is the number read for content. The difference is **498 blobs over
  512 KB**, a bound the detectors already applied and which this task did not change. **It is the
  one thing the word "every" does not cover.**
- **What a shallow clone gives it instead: 1 commit, 1,047 distinct blobs, 30 MB** — against
  652 commits, 4,744 blobs, 789 MB for the real thing. That 1,047 is why the old
  `greaterThan(100)` guard passed.
- **Runtime: over twelve minutes → about five seconds**, by asking git only for the blobs a
  detector would read (≤512 KB) and reading them in bounded chunks. **Nothing that was being
  scanned stopped being scanned.**
- **Two alternatives were considered and rejected; do not re-open them without new reason.**
  **Caching by last-scanned commit** gives up the property that a fresh clone and a warm one check
  the same thing, and a stale or missing cache silently reduces scope — *the very defect this task
  existed to fix, wearing a hat.* **Moving it to a schedule** gives up its running on every commit,
  and a `cron:` line nobody has watched fire is a claim rather than a control.
- **When the claim was last established is a real question with a real answer.** The manual
  `git log --all -p` review last ran at **78 commits**; task 10.58's automated replacement then ran
  against one. **Nothing covered the stretch between.** The honest answer to "when was this last
  established" is **the last green offline-suite run**, not "continuously" — and never a date
  earlier than 2026-09-04.

### What a Whole Arrival Refresh Costs — standing fact (added 2026-09-04, task 11.153)

- **Measured on a five-project, five-member device holding forty collars: median 15.4 ms**
  for one complete refresh (13.5–19.8 ms over 20 runs). **The four gating providers are 1.5 ms
  of that**; the project lists 4.0 ms; the tag views 8.1 ms.
- **The frequency is per sync round that changed rows, not per write.** There are seven
  announce sites and the dominant one is a merged sync page. A paginated pull announces once
  per page, so **a fresh join of forty pages costs roughly 0.6 s of refresh work spread across
  a much longer download.**
- **Nothing here needs optimising.** This is recorded so a future task does not re-measure it,
  and so no brief argues from a cost nobody has taken.

### Invalidating a Provider Does Not Re-Run What It Reads — standing fact (added 2026-09-04, task 11.153)

- **Measured on riverpod 3.3.2:** invalidating provider B, where B's whole body is
  `ref.watch(A.future)`, rebuilds B and lets it read **A's cached value**. B comes back with the same
  answer it started with. **Nothing warns.**
- **This is how a hand-kept invalidation list goes wrong**, and it had: `_afterMembershipChange`
  invalidated `myProjectRoleProvider` and `mayWriteProjectDataProvider` but not
  `projectRoleForUserProvider`, which is the one line `myProjectRole` consists of. **So an owner
  changing somebody's role watched the members list update and the "Your role" card beside it not,
  from the same tap — on a purely local write, nothing to do with syncing.** It had been that way
  since task 11.12.
- **So a refresh list must name every provider in the chain, not the one the screen reads.** The
  question to ask of each entry is *"what does this one read, and is that on the list too?"*
  `project_view_refresh_test.dart` holds the case that goes red without
  `projectRoleForUserProvider` on it.
- **The same shape bit the tag list from the other direction.** 11.151 defined
  `refreshTagViews(projectId: null)` as *"the write only touched the global tag database — a rename,
  a recolor, a retirement — and no link changed"* (the phrase is task 11.151's; task 11.219
  retired both the global tag database and the link). But `projectActiveTags` returns whole `Tag` rows,
  **so a rename changes it**; and the Tag Database screen's edit dialog offers no project when
  editing an existing tag, so **that route passes null on every rename, retune and recolor**.
  Measured: the Record screen's tag wheel kept offering the old collar name until restart, and tag
  color is the map's legend key. Null now means *every project*.

### A Provider's Read-Set Can Be Derived at Run Time — standing fact (added 2026-09-04, task 11.154)

- **Riverpod 3.3.2 will tell you what a provider reads, without a source scan.** `ProviderObserver`
  is exported from `package:flutter_riverpod/flutter_riverpod.dart`, and its `didAddProvider` fires
  once per provider *created*. On a **fresh container**, everything created while one provider
  builds is something that provider reads, directly or through another — so reading one provider
  with an observer attached hands you its whole transitive read-set, derived rather than
  transcribed. `test/core/providers/refresh_lists_test.dart` is the worked example; **it reproduces
  11.153's finding from scratch** — take `projectRoleForUserProvider` off the refresh list and it
  names it as something `myProjectRole` reads and nothing refreshes.
- **The fresh container matters.** `didAddProvider` fires on creation, not on read, so a provider
  another test already materialised is invisible. One container per provider under examination.
- **`package:flutter_riverpod/misc.dart` exports the introspection.** `ProviderOrFamily` carries
  **`name`** (the code generator sets it, and a family instance carries its family's name),
  **`isAutoDispose`**, and **`from`** (the family an instance belongs to, so
  `p is Family ? p : (p.from ?? p)` is the key to compare against a list of families). `Family` and
  `ProviderBase` are exported there too. **Compare by identity, not by name** — generated providers
  are top-level finals, and a hand-written provider (`allTagsProvider`) has no name at all and
  prints as `FutureProvider<List<Tag>>#79eeb`.
- **What this does not give you: a family's live instances.** There is still no way to enumerate
  them, which is why `ArrivalRefresh`'s deadlock guard cannot watch families. **What it does give
  you is the family object**, so *"every family on a refresh list is `autoDispose`"* is now an
  assertion rather than an accident — `autoDispose` throws when invalidated mid-build, `keepAlive`
  hangs forever with nothing raised (11.153's measurement).

### What a Hidden Tab Is Still Doing Can Be Measured — standing fact (added 2026-09-04, task 11.161)

- **Two numbers answer "is this app doing work for a screen nobody is looking at", and both come off
  the running app rather than off a reading of the code.** A `ProviderObserver`'s `didAddProvider` /
  `didUnmountProvider` gives **which providers are alive**; `SchedulerBinding.instance.transientCallbackCount`
  gives **how many tickers are asking for frames**. Snapshot both on one tab, walk every tab, come
  back, and snapshot again: the difference is what the tabs you are not looking at are holding.
  `test/routing/hidden_tab_liveness_test.dart` is the worked example, and it runs in about eight
  seconds.
- **Take the baseline inside the same run, not from a second boot.** The first version booted the app
  twice — a control run and a sweep run — and took **more than ten minutes**, hitting `flutter_test`'s
  per-test timeout, with two live containers and two map screens fetching tiles. One boot with a
  before-and-after snapshot answers the same question, and nothing differs between the two snapshots
  except which tabs have been opened.
- **A tab sweep under the fake clock measures a different app, and the artifact looks exactly like a
  finding.** Pumping without `runAsync` leaves every screen stuck on a database future, so the sweep
  "found" three `CircularProgressIndicator`s ticking on hidden tabs. **They do not exist**: with real
  time available every loading state resolves and the count is zero. Settle with bounded real-time
  pumps inside `runAsync` — `pumpAndSettle` is not available either, because a live sensor stream
  means nothing ever settles.
- **A stream faked as a single value hides every ticker it would have driven.** `CompassDial`
  animates on heading *change*, so a fake that emits three samples and stops leaves the dial still
  and reports no animation. The override has to be `Stream.periodic` for the ticker count to mean
  anything.
- **`SchedulerBinding.debugAssertNoTransientCallbacks` names the owners.** It throws with the
  registration stack of every live transient callback, which is how the three spinners and the one
  dial were identified rather than guessed at.

### Where the Invalidation Audit Stops — standing fact (added 2026-09-04, task 11.154)

- **37 by-name provider invalidations exist across 21 files under `lib/`**, and every one is
  declared with a verdict in `test/documentation/invalidation_sites_test.dart`. An undeclared site
  fails the run; so does a declaration whose site has gone.
- **That file is a declaration, not a derivation, and says so.** It notices a *new* invalidation. It
  cannot notice that an existing verdict has stopped being true. The two refresh lists are the ones
  with a derived guard, because they are the two that can be enumerated from the code.
- **Neither instrument can see a provider that ought to be refreshed and is read by nothing on a
  list.** The derivation starts from the lists; a screen provider nobody ever added is outside both.
  That is the residue, and it is written here rather than left to be discovered.
- **Checked and found sound, so nobody re-derives it:** signing in adopts a server identity, which
  rewrites the user column of every synced table and hard-deletes the old `Users` row, while
  `auth_provider.dart` invalidates only `currentUserProvider`. **That is not a hole** —
  `ServerIdentityAdopter.adopt()` announces through `DataArrival` after its transaction commits
  (task 11.45 named this as its sixth inbound path), and that is what refreshes every other screen.

### The Main Map's Clear Band, Actually Measured — standing fact (added 2026-09-05, task 11.166)

- **The band does not hold at every text size, and a planning-session brief said it did.**
  `bandHoldsThrough` in `map_screen_space_budget_test.dart` has recorded **AX1** as the last stop
  that holds since task 11.149, and the biconditional above it **requires** the band to be under
  the floor from AX2 up.
- **Measured with both shell banners live and a navigation target running: 229 / 191 / 152 / 134 /
  102** up to AX1, then **30, 14, 14, 8.**
- **The tightest state on the ordinary slider is not a text size at all.** With tiles failing on a
  new project the band is **105 against a floor of 96 — nine pixels of slack.**
- **Its floor stays an assertion rather than a structure, and the reason is not that it is a
  `Stack`.** It is that **a budget can only say no by taking something away, and this screen has
  nothing it may take**: every overlay is a license condition, a control, or a warning about state.
  See `map_screen.dart`'s SPACE BUDGET, where the reasoning lives.
- **The width axis is swept and clean: seven budgets, seven enforced, zero inoperative** (task
  11.166). Every historical horizontal overflow was fixed with `Flexible`/`Expanded`, which is
  enforcement — **the symptoms were real and the remedy that fixed them is why the sweep is empty.**
- **`scripts/derive_space_budgets.py` is the instrument for both axes**, reproduces 11.165's counts
  exactly (138 `Column`s, 591 children), and states its own blind spots in its header. **Point a
  third sweep there rather than building a fourth instrument.**

### Why the Gate's Coverage Check Lives in `server-suite.yml` — standing fact (added 2026-09-05, task 11.173)

- **It is hosted there rather than in `gate-instruments.yml`, and the reason is load-bearing.**
  `gate-instruments.yml` is **path-filtered** — a commit that deletes a `run_instrument` line
  while touching nothing under `server/`, `packages/`, `scripts/`, `proxy/` or the compose files
  **would never start it.** That is precisely the commit the coverage check exists to catch.
  **`server-suite.yml` has a bare `push:`.**
- **This is mechanised rather than written down: if a future task adds a `paths:` filter to
  `server-suite.yml`, the guard fails with a sentence saying why.** So the reason above does not
  need to be remembered — **but it should not be re-derived either**, which is why it is here.
- **The runner cost is a self-measuring open item, not a follow-up task.** Measured at **1.35 s**
  on Michael's Mac and **195 ms** in a bare `ubuntu:24.04` container with no Docker, Python or
  network — **which is also the evidence the job needs nothing but bash, grep and the checkout.**
  **Neither number came from a GitHub runner.** The step times itself on every run and prints the
  milliseconds into the run summary, **so the first push turns the estimate into a measurement**
  and somebody only has to read it once.

### The Record Form's Floor, And Where It Stops Being Reachable — standing fact (added 2026-09-07, task 11.195)

**The Record screen's *record type* and *tag* share one tappable header row** reading e.g.
`Directional · 150.900 MHz · 46 bpm` over the animal's name. **That bought 157 logical pixels** and
put *Preview / set position on map* fully on screen on a **6.1-inch phone** for the first time.
Michael chose the option. **Nothing filled in per observation moved** — bearing, quality, pulse mode,
signal strength and the irregular flag are where they were.

**Where it stops, stated rather than discovered later.** The button is whole at the default text size
and **up to xxxLarge**, and goes **under the fold from AX1 up**, where **the bearing block alone is
taller than the form's viewport.** Task 11.195's judgement: no layout on this screen fixes that
without collapsing the bearing block, which is the screen's subject.

> **One possibility that task did not name, recorded as a question rather than a correction.** This
> screen already has a **pinned** SAVE bar (`BudgetedColumn`'s only caller). **Whether the map button
> could be pinned the same way at the accessibility sizes has not been examined**, and the planning
> session has not checked it either — **it is a lead, not a claim.** Anybody revisiting this should
> test it before repeating that no layout can help.

**And the harness could not see the screen this was about.** `integration_test/screenshots/` had a
6.9-inch phone profile and a 13-inch iPad — **not the 6.1-inch geometry every space-budget assertion
in this project is written for.** 11.195 added an `iphone-6.1` profile temporarily, confirmed the
fix, and reverted it, because making it permanent commits 33 baseline images into `website/`, which
is the content lane's. **Two tasks in a row (11.193, 11.195) were about a control cut off on a phone
size nothing photographs.**

### The Contrast Floors This App Is Held To — standing fact (added 2026-09-08, task 11.201)

**Every `ColorScheme` member is now passed explicitly.** `_knownFallbacks` in
`test/core/theme/color_scheme_tokens_defined_test.dart` **is empty and was kept rather than
deleted**, so adding a row back is a visible decision to ship a color nobody picked.

**The floor is WCAG 2.1 SC 1.4.3 (AA), 4.5:1 for normal text**, asserted as **measured ratios** in
`test/core/theme/theme_contrast_test.dart` — **never as equality with a token**, which is the rule
task 11.200 produced after that exact mistake hid an unmet requirement under a green suite.

**One case worth remembering, because it is easy to get wrong the other way.** The observer badge's
initials are **9px bold**, and **WCAG's relaxed 3:1 "large text" allowance does not begin until 14pt
bold — so the 3:1 shortcut never applied here.** They are held to **7:1 (SC 1.4.6, AAA)** as well,
deliberately, because that badge is read on a phone outdoors. **Measured 7.12:1 light and 7.93:1
dark, from 1.00:1** before task 11.200.

> **The alternative was rejected with a number rather than an opinion.** Keeping the muted initials
> and lightening the circle until the pair cleared 4.5:1 needs a fill of about `#EBEBE8` — **1.06:1
> against the card.** **That trades an invisible label for an invisible circle.** So the circle became
> a mid neutral and the initials went full strength; **excluded still reads as excluded from three
> cues that are not this one** — the circle gives up the brand green, the checkbox is unticked, and
> the row title is muted.

**One deliberate inversion of Material 3, accepted 2026-09-08 so it is not later read as a mistake.**
In this app **`outlineVariant` is more present than `outline`**, which is the opposite of M3's
ordering. **The reason is in `design_tokens.dart`:** this app's `outline` is a **hairline (1.14:1 on
white)**, and the two things drawn in the variant role are **objects** — a badge, a drag handle —
**not rules.** **The condition to revisit it: the day something is drawn as a hairline using
`outlineVariant` it will be too heavy, and the answer then is a different role rather than a
different value.**


### A Role Now Moves a Space Budget — standing fact (added 2026-09-07, task 11.183)

**On the Position screen, a viewer's reason line takes height out of the bottom panel, so fewer
bearing rows are visible at once than an owner sees.** Nothing is unreachable — the list scrolls —
but **that panel is a measured budget** (tasks 11.139 and 11.148) and **a permission is now one of
the things that moves it.** Anybody re-pricing that budget must price it for a non-owner too, or
they will price the roomier of the two cases and call it the floor.

**A second difference on the project-setup screen, recorded because it will look like hiding one
day and is not.** A non-owner's fields are `enabled: false`, so the text is legible but **not
selectable**. Nothing is withheld — every value is also in the project list and in the tag export —
but *"I cannot copy this text"* is the sort of difference somebody eventually reads as data being
kept from them.

### Which Space Budgets Are Actually Enforced — standing fact (added 2026-09-05, task 11.165)

- **Swept on the height axis: 138 `Column`s and 591 direct children in `lib/`, two scan methods
  plus a hand read of all four `SPACE BUDGET` headers. Eleven distinct budgets — nine enforced,
  one out of the class, one inoperative.**
- **The nine enforced:** the shell's banner share, the Offline Data Map's 96-pixel clear band, the
  Position screen's map/panel split, two `minHeight` floors, a `maxWidth` on a legend footnote, the
  past-estimates sheet, the Main Map's elevation panel, and the selection card — whose height is
  measured every frame and the furniture lifted by it.
- **The one inoperative was the Record screen's pinned SAVE bar.** Its rule said it does not grow
  and nothing could refuse a line added to it. **Now bounded to half the screen's body, and the
  bound binds at none of the nine text sizes — the form and bar measure the same to the pixel at
  every one.**
- **A brief that calls the Record screen's rule 3 "a comment" is describing code from before
  2026-09-05.** It now says in its own text that it is enforced, and names `kRecordPinnedBarShare`.
- **What the enumeration cannot see, stated rather than implied:** a budget written in prose on a
  screen with no `SPACE BUDGET` header, and **width budgets on `Row` children — the same defect on
  the other axis, not swept.** That axis is task 11.166.

### The Shell's Budget, and Four Ceilings That Rose Without Their Screens Changing — standing fact (added 2026-09-05, task 11.149)

- **The app shell is now held to a quarter of the frame**, so a screen gets at least the other
  three quarters at every text size. Before this, at the largest settings the shell left a screen
  **56 logical pixels out of 852.**
- **Four recorded ceilings rose as a result, and nobody should read them as four screens
  improving.** Main Map clear band xxxLarge → AX1; Position map floor AX1 → AX2; Position clear
  band AX1 → AX2; Position reachability AX3 → the whole ladder; Position "clean" AX4 → the whole
  ladder for both roles. **One change, in the shell. The screens' own budgets are unchanged.**
- **The Record screen's failure was the shell's, which settles task 11.147's open hypothesis.**
  Its scrolling area was handed a viewport of **zero logical pixels** from AX4 (AX3 for a viewer),
  and the pinned SAVE bar then overflowed the body by 29, 155, 166, 287 and 509 pixels.
  **Nothing on that screen was changed and it is now clean for an owner at every stop, and for a
  viewer through AX4.**
- **The Position screen is non-monotonic in text size, and this is a decision rather than a
  defect.** A whole bearing row fits at xxxLarge, does **not** fit at AX1 or AX2 — where the map
  still holds its floor and the panel pays for it — and **fits again at AX3**, because the map has
  stopped holding anything and `_panelFractionWhenNothingFits` hands the panel 60%. **The recorded
  fact is a *set* of text sizes, not a threshold, because a threshold cannot express this.**
- **What a person sees at the three largest sizes is written beside the constant, not only in a
  test:** AX3 a 169-pixel map and a 254-pixel panel; AX4 a 151-pixel map with no whole bearing row
  fitting; AX5 a 138-pixel map. **At all three, the last bearing and SAVE POSITION are still
  reachable by scrolling** — degraded rather than broken.

### Two Offline Data Map Overflows Already Fixed — standing fact (added 2026-09-04, task 11.162)

**Recorded so the next screen-space sweep does not report them as fresh findings.** Both were live,
both were found while measuring something else, and both are fixed:

- **The coverage legend's four label rows overflowed to the right above AX1**, with nothing
  bounding them.
- **Once the legend shared a row with the map buttons, it pushed those buttons off the right edge
  from xxLarge.**

Both now wrap. **Neither was caused by 11.162's own change**, and neither has an open task.

### The Text-Size Instruments That Already Exist — standing fact (added 2026-09-04, task 11.147)

- **`collectLayoutOverflows` in `test/support/text_scale_probe.dart` names the widget that
  overflowed**, not just the direction and distance. Every Flutter layout overflow reports its
  context as the words *"during layout"*, so a failure used to read *"overflowed by 39 pixels
  on the right"* and leave the reader to work out which of four rows it meant. 11.147 taught it
  to read the `creator:` chain out of the framework's own information collector.
- **The Position ladder prints the body height at each stop** — the pixels the shell leaves a
  screen for its own content. That is the measurement that separates *"this screen's layout is
  wrong"* from *"the shell has taken the screen"*, and it is the difference between a diagnosis
  and a resemblance.
- **Two measure-the-text helpers now exist and a third one-off should not be written.**
  `DisabledReasonNote.heightFor` and `MapBottomReadoutColumn.heightFor` in `map_furniture.dart`.
  The second shares its `static` metrics with its own `build`, so the measurement and the drawing
  cannot drift without failing to compile — **that is the shape to copy.**
- **Confirmed on hardware by Michael, 2026-09-04:** the Position screen at an increased text size
  looks right on a real iPhone. **This is the first time any of the text-size work has been seen on
  a device**, and it confirms the direction recorded above — the harness is harsher than the phone.
  Every floor in that work remains a lower bound.
- **Point the next text-size task at both of these.** The last three each built a one-off probe;
  this is the standing one. **A fresh instrument beside a working one is two things to keep
  true**, and the older one is usually the one that rots.

### Which Way the Test Font Errs — standing fact (added 2026-09-04, task 11.139)

- Task 11.133 established that `flutter_test`'s fallback font draws letters **about twice
  Roboto's width**, and it has been the cause of several wrong diagnoses. **Task 11.139
  establishes the direction, which matters as much as the magnitude: for layout floors it
  makes the harness *harsher* than a real phone.**
- **So every floor measured in a widget test is a lower bound.** A real device has at least
  that much headroom, never less. **Nothing measured this way is overstated**, and a fix made
  against these numbers was made against a stricter phone than exists.
- **This does not license the reverse inference.** The font makes text *wider*; it says nothing
  about a layout that fails for a reason other than width, and it has already produced five
  wrong causes for one Navigate-row overflow. **Use it to say "at least this much room", never
  to say "therefore the real device is fine."**

### A DEM Tile's Presence Is a Record, Not a File — standing fact (added 2026-09-04, task 11.143)

- **`DemTileStore.hasTile` no longer means "a file exists there."** It asks a recorded
  completeness answer — `DemTileRecord`, carrying byte count, cell count, filled-cell
  count and attempt count, written **after** the file is closed. **Briefs must stop
  describing this store as file-existence**; that description is now wrong and it is the
  kind of sentence that gets copied forward for months.
- **The vocabulary, which is fixed and should not be reinvented:** `tileHealth` returns
  `absent`, `unusable`, `incomplete` or `complete`; `needsFetch` is the download path's
  question; and **`missingTilesForPolygon` means "tiles the store still wants", not
  "tiles with no file."**
- **Tiles already on devices are validated from their own bytes** — parsed, filled cells
  counted, a record written from what is actually there — so a whole tile settles offline
  and a truncated one is caught anyway. **In-place corruption that does not change the
  file's length is explicitly out of scope** and says so in `DemTileRecord`'s doc comment.
- **`kDemTileMaxFetchAttempts = 3` is a policy, not a measurement**, and is named here so
  it can be disagreed with: it is how many times a tile that came back with holes is
  re-fetched before the store accepts the source has nothing more to give.
- **A progress readout counts what is finished, never what is started.** The terrain
  readout used to increment when a fetch *began*, so "72 of 72" meant the last fetch was
  still in flight — **a display that reaches its own denominator and stops is the most
  confusing state to leave somebody in, because it looks finished.** Fixed by 11.143.

### What `flutter test` Cannot See — standing fact (added 2026-09-04, from task 11.144)

- **A provider deriving from another provider can crash a debug build and no widget
  test will ever show it.** The Position screen's `_tagObserversProvider` watched
  `_directionalObservationsProvider`, and the widget watched the upstream one directly.
  A sync round marks the observations provider stale; the next frame's `build` calls
  `ref.watch`, so Riverpod recomputes it **during build**; the recompute notifies the
  downstream provider, which invalidates itself; and invalidating a provider asks the
  surrounding `ProviderScope` to schedule a refresh — **a `setState` on a widget above
  the one being built.** Measured stack, not deduced:
  `_UncontrolledProviderScopeState.scheduleRefresh ← Ref._invalidateSelf ←
  ProviderElement.flush ← ConsumerStatefulElement.watch ← _EstimationContentState.build`.
- **Four attempts to reproduce it under `flutter test` came back green against the
  unfixed code** — bare screen, real app shell, visible tab and offstage tab, with and
  without an async gap. **The reason is structural rather than a gap in the attempts:**
  the cascade needs the provider still dirty when `build` reads it, and under
  `flutter_test`'s automated binding Riverpod's scheduled refresh always flushes first.
  **The only instrument that has ever caught this is the screenshot harness on a
  simulator**, which runs in the content lane and days apart.
- **So the guard for it is a source check and says so in its own header**:
  `test/routing/shell_provider_chain_test.dart` (task 11.145 moved it out of the
  Position screen's folder and widened it to all five branches; it was
  `position_estimation_provider_chain_test.dart` before that). It derives the chains
  from `lib/` rather than listing them, and compares them against an allowlist where
  **every surviving chain has to be argued for in writing**. Confirmed red in both
  directions — 11.144's shape put back on `/position`, and an allowlist entry left
  behind after its chain was gone. **Point the next "why did no test catch this"
  question at that file** rather than assuming somebody forgot to write one.
- **Four of the shell's five branches have the same shape and are not fixed** — and the
  full list is one provider longer than 11.144's report said. `StatefulShellRoute.indexedStack`
  keeps every visited branch mounted, and the derivation (11.145) finds eight chains:
  `/map` through `currentUserProvider`, `mayWriteProjectDataProvider` and
  `selectedTileCategoryProvider`; `/record` through `mayWriteProjectDataProvider`;
  `/position` through `mayWriteProjectDataProvider` and `selectedTileCategoryProvider`;
  `/more` through `currentUserProvider` and `serverConfigProvider`. **`/compass` has
  none, and now for a stated reason rather than by inspection**: not one of the four
  providers it watches is watched from inside any provider body in `lib/`.
- **The remedy for all eight is "leave it", decided once, and the reason is the same
  every time.** 11.144's remedy was to merge two providers, which needs both ends
  private to one screen; every upstream here is app-wide (the signed-in user, the
  server's address, this project's write permission, the chosen basemap), so merging
  would be a worse defect than the one it fixed. The remedy that generalises — point the
  widget at the *downstream* provider instead — needs the widget not to want the
  upstream value, and each of these widgets reads something only the upstream has. The
  per-chain reasons, and what would change each answer, are in the guard's `_argued`
  map.
- **"A sync round does not move those providers" was true when written and is not any
  more, and neither is "none of them is live".** Both were corrected by task 11.145 on
  2026-09-04:
  - **A sync round now moves `mayWriteProjectDataProvider`.** Task 11.153's
    `ArrivalRefresh` (`lib/core/providers/arrival_refresh.dart`) calls
    `refreshProjectViews(ref, projectId: null)` on every `DataArrival`, and that list
    invalidates `mayWriteProjectDataProvider`, `myProjectRoleProvider` and
    `currentProjectProvider`. **That is the reopen trigger below, fired the day after it
    was written.**
  - **The cascade is live, and it is not a sync round that reaches it.** Measured on an
    iPhone 17 Pro Max simulator (iOS 26.5), `integration_test`, debug: a bare
    `container.invalidate(currentUserProvider)` — which a **Profile save** does, with no
    server anywhere, and so do identity setup and sign-in — followed by a tab switch
    raises *"setState() or markNeedsBuild() called during build"*. Reproduced on three
    separate runs, on the same two transitions each time (`/compass` → `/position` and
    `/more` → `/map`). **Announcing a `DataArrival` and switching tab immediately raised
    nothing**, on any of the five transitions — `ArrivalRefresh`'s settle-first guard
    appears to be doing real work there, which is a measurement rather than a proof.
  - **The stack is a different door into the same room, and no `package:tritrack` frame
    appears in it.** The cascade is not entered from a screen's `build` calling
    `ref.watch`, the way 11.144's was; it is entered from
    `ConsumerStatefulElement._updateTickerMode ← _TickerModeState.didChangeDependencies
    ← StatefulElement.performRebuild`, then three nested `ProviderElement.flush` levels
    up the ancestor chain (`mayWriteProjectData → myProjectRole → currentUser`), then
    `Ref._invalidateSelf → scheduleProviderRefresh →
    _UncontrolledProviderScopeState.scheduleRefresh → setState`. **`TickerMode` toggling
    is exactly what `indexedStack` does when you change tab**, so the trigger is the
    shell's own mechanism and the widget does not have to watch the stale provider
    directly — watching anything descended from it is enough.
  - **So the four screens' chains are not what makes this live, and fixing them would
    not close it.** That is why 11.145 left them and filed the tab-switch cascade as its
    own finding instead. **To reproduce in about ten minutes:** an `integration_test`
    file that calls `bootApp` and `goTo` from `integration_test/screenshots/harness.dart`,
    installs a `FlutterError.onError` that records the message, then for each pair of
    adjacent routes settles, calls `container.invalidate(currentUserProvider)`, and
    navigates to the next route within ~300 ms. Deliberately **not committed**: an
    instrument nobody runs rots, and this one demonstrates an open defect rather than
    guarding a closed one.
- **The reopen trigger, stated so it is not a judgement call: the day a sync round
  starts changing any of those three providers, these four become live and this becomes
  a task.** Anybody adding a provider to what a sync round announces is the person this
  paragraph is written for. **It fired on 2026-09-04 (task 11.153) and the task it became
  is 11.145.**

### Performance & Battery
- GPS throttled to every 5–10 seconds during active use
- Pause GPS, viewshed computation, and other background processes when the app is backgrounded — **except downloads in progress**, which should be allowed to continue (or the user warned not to switch screens if that's not achievable) rather than silently stalling
- **A hidden tab is not a backgrounded app, and the same rule reaches it — but only as far as the resume cost allows** *(added 2026-09-04, task 11.161)*. Since task 11.160 the tab shell keeps the tabs you are not looking at mounted and running, so "when the app is backgrounded" is no longer the only moment a sensor is running for nobody. **The difference is what resuming costs.** Backgrounding is a person putting the phone away, so anything may be paused; a tab change is a person still using the app and coming straight back, so a pause is only worth taking where resuming is not a wait. Measured against the app itself: **the compass — the OS heading, the magnetometer and the accelerometer — is paused when neither the Compass nor the Record tab is on screen**, and resuming costs one sensor sample (the dial reads 0° with no bubble level until it lands, as on a cold start). **GPS is deliberately not paused on a tab change**, because re-acquiring a fix under canopy is seconds at best and can be a minute; it stays on the backgrounded rule above, where that cost is worth paying. **The mechanism is `lib/routing/tab_visibility.dart`, and it is a decision at each call site rather than a framework noticing a widget is off-screen** — that accident is what caused 11.160's crash. What stays live on a hidden tab is derived rather than listed, in `test/routing/hidden_tab_liveness_test.dart`, which fails on anything new that nobody has decided about. **The battery saving itself is unmeasured and needs a field day — release-checklist item F1.**
- Progress bar/indicator during long operations (viewshed computation, Lenth calculation, downloads)
- Haptic feedback on all scroll interactions

### Display Conventions
- Map labels show `tag_name` and `frequency_mhz` (never the internal `tag_id`) on all map overlays
- **Per-tag color (added 2026-07-28):** bearing rays, estimated positions, and actual tag locations render in that tag's `color_hex` (joined via `tag_id`) instead of a fixed element-type color. Viewshed overlay stays fixed (`#60a5fa` semi-transparent) — it's not tag-specific. Shape remains the required non-color cue: rays keep an observer-position circle + line with a translucent uncertainty wedge, estimated positions keep their ellipse, actual tag locations keep a distinct marker icon — color alone must never be the only way to tell them apart.
- Observation rays: line from the observer point, at the recorded bearing angle, labeled with tag name/frequency; the observer's position should be marked with a circle (not a bare line start), and a translucent wedge overlay should show the bearing's uncertainty range
- Uncertainty ellipses: semi-transparent overlay on estimated positions; toggle to show/hide, and to highlight which underlying bearings contributed
- Map legend is tag-keyed (swatch + tag name, only for tags with currently-visible elements) plus one fixed row for viewshed — not the old fixed per-element-type legend
- Local time shown throughout the UI; UTC available in underlying data records
- Map recordings (bearings/positions/other) must live-update on add/delete without requiring an app restart

### Project & Team Management
- Project QR code as a join mechanism (Phase One: local project ID; Phase Two: server-based handshake)
- Owner can transfer ownership
- Project owner can add, remove, or deactivate members
- ~~Tag database is global; each project selects a subset via `Project_Tags`~~
  **Since task 11.219: each project holds its own copy of a collar, and the
  device keeps a personal `Tag_Library` to copy from.** Editing one project's
  tag changes that project and nothing else.
- Project tags are manageable after project creation (add, remove — never
  hard-delete)

---

## Algorithm Validation Checklist (for Claude Code)
1. Implement Lenth MLE per the 1981 Technometrics paper
2. Reproduce the paper's worked example to confirm correctness
3. Cross-validate against R packages `radiotrack` and `sigloc` using shared test data
4. Confirm uncertainty ellipse parameters (semi-major, semi-minor, rotation) match expected outputs
5. Confirm pairwise intersection calculations are independent of and consistent with the MLE result
6. Verify circular-statistics handling across the 0/360 boundary (350°→10° sweep midpoint = 0°)
7. Verify all degenerate-geometry guards (N=1, near-parallel, coincident observers, near-singular) fail gracefully with warnings, never NaN/crash
8. Verify declination sign and magnitude against a known reference for Flagstaff (~+10° E)

---

## Field-Readiness (Phase One)
- **Pre-trip checklist** surfaced before heading out of connectivity: maps + DEM downloaded for the project bounding box, tags loaded, GPS acquiring, compass calibrated.
- **Project bounding box** (in Projects) drives tile/DEM pre-download, later crops viewshed, and feeds Phase 2 road optimization and Phase 3 habitat layers.
- **Destructive-action safety:** confirm + undo on deletes (with bounded auto-dismiss); autosave a draft observation so a mid-entry crash (cold hands, dying battery) doesn't lose data.

---

## Map Furniture (Phase One)
- Scale bar, north arrow (tap-to-reset-orientation), live coordinate readout
- Color legend for ray / estimate / tag-location / viewshed scheme
- **Point-to-point measure tool** (distance + bearing between two tapped points, draggable endpoints, "Clear" button, elevation-profile graph with adaptive gridlines)

---

## Open/Deferred Items
- SMS auto-detection for observation sharing — assess complexity; implement in Phase One if straightforward, otherwise defer to Phase Two
- Route/driving-based viewshed coverage planning (Phase Two)
- Server-based team communication and project join handshake (Phase Three)
- Painted Dog Conservation (Zimbabwe) field-app identification for interoperability export target — **confirmed: SMART Mobile**, which is built on the CyberTracker engine (see Interoperability below)
- App rename to "TriTrack" (no space) across app title, platform manifests, README — decided direction, not yet executed in code
- Live audio pulse detection & signal-strength plotting via mic-input from a handheld VHF receiver (see "Live Audio Pulse Detection & Signal-Strength Plotting" above) — proposed 2026-07-27, not yet designed to screen level or scheduled to a phase

## Interoperability — Under Review, Not Yet Approved for Any Phase
These are candidate features surfaced during design discussion. None are committed; all need further review before being scheduled to a phase.

- **Movebank submission.** Movebank's official documented API is a *download* interface; data gets in primarily via manual file upload or a manufacturer-style automated feed arrangement. A couple of third-party API directory listings describe a writable v2 REST endpoint, but this isn't corroborated by Movebank's own docs — needs direct confirmation with Movebank before designing around it. Realistic near-term path if pursued: a Movebank-schema export formatter paired with either a genuine write endpoint (if confirmed to exist) or a manual-upload-ready file. Likely Phase 3 candidate.
- **SMART/CyberTracker interoperability via webhook.** Confirmed: SMART Mobile is built on CyberTracker's engine, used by Painted Dog Conservation. CyberTracker/SMART supports **outbound webhooks** — a POST of JSON to a configured URL whenever a field record is saved. This makes **one-way ingestion (SMART → TriTrack) technically feasible**, but only once TriTrack has a live server (Phase 3) to receive it, plus a parser for CyberTracker's JSON payload shape. The **reverse direction (TriTrack → SMART) has no equivalent inbound mechanism** — would require a manual import via a custom SMART data model configured by the conservation org, an organizational ask, not just engineering. Data models are structurally different: SMART is patrol/incident-centric; TriTrack is tag/bearing-centric. Only a few fields map cleanly (ISO 8601 timestamps; lon/lat/alt/accuracy).
- **ITM relative-detection-likelihood layer** — see Viewshed section above for full detail. Logged here as a cross-reference; same "under review" status applies.

## Business Model — Under Review, Not Approved for Any Phase
A free core tier (Phase One feature set) plus a paid "Pro" tier gated at the Phase Two/Three team-sync boundary was discussed during design conversation, priced per team/project rather than per seat. Not committed, no pricing finalized. Logged here so Phase Two/Three planning accounts for a possible paywall boundary at the sync/team-features line, and so it isn't lost between chat sessions.

---

## Implementation Status Snapshot (informal, at time of reconciliation)

This section is a working gut-check against the current `lib/` codebase, not a formal audit — re-verify anything load-bearing before relying on it.

**Believed done:** compass calibration UI overhaul, separation of the Compass (instrument) and Record (bearing capture) screens, splash screen + app icon, measurement tool (clear/move endpoints, basic elevation profile), offline-data download screen with polygon/rectangle area selection, signal-strength horizontal slider, tag-to-project assignment UI, Log vs. Record screen naming, compass needle visibility fix, map layer on/off checkboxes, undo-snackbar auto-dismiss, triangulation window as free text.

**Confirmed still open, with rough pointers for whoever picks these up:**
- `ObservationType` enum (`data/models/enums.dart`) has only `directional`/`omnidirectional` — no `note` or `no_signal` value; `Non_Detections` already supports multi-tag (`tagIdsListenedFor` as a list) but no screen currently creates a `Non_Detection` record — this is the natural home for "No Signal," pending a UI decision.
- Download progress bar tracked to job.done/total in code, but no device wake-lock and no ETA display found.
- Bearing/omnidirectional preview-before-save step not located in the current Record flow.
- Bearing map rendering (observer circle + uncertainty wedge) not found in `estimation_map_painter.dart`.
- Dual compass needle (magnetic + true north) — only a single needle painter was found in `compass_dial.dart`; the true-north arrow needs to be confirmed present or added.
- Bubble level pitch/roll direction — orientation math looked symmetric between axes in a spot check, but the reported pitch-direction bug hasn't been independently reproduced or ruled out.

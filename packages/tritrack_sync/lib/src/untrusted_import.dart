import 'enums.dart';
import 'project_roles.dart';
import 'row_validator.dart';
import 'sync_tables.dart';

/// Security model **§4.19**'s rules 3, 4 and 6, expressed once and
/// table-agnostic, so every import path enforces the *same* rule rather than
/// each re-deriving one.
///
/// §4.19 was written to close finding J-1 on one path — a pasted `TT1:` string
/// reaching one `Observations` row. Finding **K-1** is the same defect on the
/// picked-`.zip` restore, which reaches *every* column of *every* table. The
/// numbers and the column lists below were previously constants on
/// `ObservationShare`, i.e. on the encoder for the one payload format §4.19
/// happened to be written against. They live here now because they are
/// properties of *"data from an untrusted party"*, not of that format — and a
/// rule that only one path can reach is a rule the next path re-derives
/// wrongly, which is exactly how K-1 happened.
///
/// **What this is deliberately not.** These checks are not folded into
/// [RowValidator], even though [RowValidator] is the gate that already runs on
/// every write path, because the server also runs [RowValidator] on pushed rows
/// and the server's answer to a bad clock is *different on purpose*: it
/// classifies the skew and writes the row anyway (`ClockSkew.classify`), since
/// it is replicating an authenticated device's own record and must not rewrite
/// history it did not author. A picked file has no device behind it. Same
/// reading, different trust context — §4.19 rule 3 records that distinction and
/// asks that the two never be "reconciled" into one behaviour, so the check
/// that must not reach the server is kept out of the class that does.
abstract final class UntrustedImportRules {
  /// **§4.19 clause 6 — an import is a write, and the person doing it must be
  /// allowed to write here** (task 11.19).
  ///
  /// True when [receiverRole] — the role held by *the user of the device doing
  /// the importing*, in the project the rows are landing in — may write the
  /// project's data at all. It is [ProjectRoleRights.mayWriteProjectData] with
  /// one addition, and the addition is the whole substance: **a role this
  /// device cannot resolve permits.** Same reading, same reason and same
  /// wording as `BaseRepository.assertRoleMayWrite`, because they are the same
  /// question and a second answer to it is the defect this clause exists to
  /// avoid.
  ///
  /// ## Which actor this is, and which one it is not
  ///
  /// An import has **two** people in it and they are not interchangeable:
  ///
  /// - **The receiver** — whoever is holding the device and pressing save.
  ///   They are performing a write into a project, so the §4.21 role gradient
  ///   governs them exactly as it governs every other write the app makes.
  ///   That is this predicate, and it is the only thing this predicate is
  ///   about.
  /// - **The payload's claimed author** — the observer a shared row is
  ///   attributed to, or the `user_id` an archived row carries. They are not
  ///   acting. Their name is being *transcribed* onto a record made somewhere
  ///   else, and what governs a name is §4.17's row-naming invariant, not the
  ///   gradient. §4.19 clause 2 is that invariant on this side of the wire:
  ///   authorship never comes from a payload, `user_id` is never written to a
  ///   row that already exists, and a payload whose author is not the row's
  ///   local author is refused outright.
  ///
  /// **The claimed author must not be run through this predicate, and saying so
  /// is half the reason the clause is written down.** Requiring a shared
  /// observation's observer to hold a role in the receiving project would
  /// refuse every genuine share from a colleague who has not been invited yet —
  /// which is the *ordinary* case sharing exists for, and is a state §4.17
  /// already decided is legitimate for a device to be in. §4.17's accepted cost
  /// says such a row stays on the importing device until its author is a member
  /// of the project; it does not say the device may not hold it. Reading the
  /// gradient onto the author would turn a documented replication delay into
  /// local data loss.
  ///
  /// The two compose the way §4.21's own two questions compose — *may this
  /// person write in this project at all* (here) and *may this row be written,
  /// naming whom it names* (clauses 1, 2, 4 and 5) — and they compose in that
  /// order, so a receiver with no write rights is turned away before any
  /// question about the payload's contents is asked, and before anything at all
  /// is written on its behalf.
  ///
  /// ## Why a null role permits
  ///
  /// A device's SQLite file legitimately holds projects its user has no
  /// membership row for: one restored from a backup, one a colleague shared,
  /// one created offline and never published. Refusing there would make the app
  /// read-only on data it is the only holder of — a far worse failure than the
  /// one this clause prevents, and one the server does not have to weigh
  /// because it never holds such a project. So: **when the device has been told
  /// a rung, honour it; when it has not, defer to the server.** An unrecognised
  /// role string also resolves to null (`resolveProjectRole`) and therefore
  /// permits here and is refused there, which is the right way round for an
  /// advisory check standing in front of an authoritative one.
  ///
  /// ## The archive-restore path, where abstaining is the whole design
  ///
  /// Task 11.20 brought `ProjectMerger` — the picked-`.zip` restore — under
  /// this predicate, and there the paragraph above stops being a caveat and
  /// becomes the reason the check is shaped this way. **The obvious fix on that
  /// path is wrong, and this is where it is written down**, because the next
  /// reader will otherwise reach for it.
  ///
  /// A restore's most important use is a device that has just been reinstalled,
  /// or a replacement phone recovering last season's archive. **Membership is
  /// server-derived**, so such a device has no `Project_Memberships` rows for
  /// the project and no `Projects` row either. A plain *"refuse unless the user
  /// is a contributor or owner"* would refuse exactly that restore — breaking
  /// the feature's most important use to close its least important gap, and
  /// violating the Phase 10 invariant that the app works fully with no server
  /// at all. Two states produce the null, and neither can be told from the
  /// other by any local evidence:
  ///
  /// - **The project is not on this device.** No answer is *possible*; the
  ///   restore is what creates the project.
  /// - **The project is here and the user holds no open membership row and is
  ///   not its creator** — created offline and never published, restored
  ///   earlier, or membership not yet synced.
  ///
  /// What is left is the case where the device *does* have an answer: the
  /// `Projects` row is present and an open membership row says `viewer`. That
  /// is the one the check refuses, and it is the one that matters — a person
  /// with read-only access restoring a file over a project on their own device.
  ///
  /// **Two candidates were considered and rejected, and the rejections are the
  /// useful part.** *Allow and treat the project as local until sync confirms
  /// membership* is today's behaviour with a name on it, and leaves the viewer
  /// case open. *Allow, but warn the user their records may be refused when
  /// they sync* cannot be aimed: the only signal available is the same null,
  /// so the warning fires on every fresh-device restore — including the
  /// project owner's, where nothing will be refused at all. A warning that is
  /// usually wrong and always shown is the dialog §4.19 clause 4 is built to
  /// avoid, one more thing to dismiss on the day someone is rebuilding a
  /// device after losing one.
  ///
  /// **What abstaining leaves open, stated plainly.** A viewer who wipes the
  /// app and restores the archive onto a device with no membership rows passes
  /// this check. Their rows are refused at the server on the next sync, and
  /// what they have is a private, divergent copy of a project they were already
  /// allowed to read. That is the residual, it is bounded to their own device,
  /// and it is the price of the restore working at all.
  ///
  /// ## What this clause is worth, stated honestly
  ///
  /// It is a **backstop, not the boundary**. A viewer with a text editor and
  /// their own device's database file can write the row anyway, and the server
  /// refuses it on the next sync (§4.21). What the clause buys is that this
  /// control now has the same shape as every other write control in the app —
  /// a UI gate *and* an independent check below it — instead of being the one
  /// place where a bypassed or raced screen reaches an unguarded write.
  ///
  /// **On the restore path it is not even the second layer; it is the only
  /// one, and that is structural rather than an oversight.** The share screen
  /// can gate its own control because it knows which project the paste is
  /// landing in before the user acts. The import screen does not: which project
  /// an archive is for is not known until the file has been picked and decoded,
  /// so there is no button to withhold. Whatever is enforced on that path has
  /// to be enforced here.
  static bool receiverMayImport(ProjectRole? receiverRole) =>
      receiverRole == null || receiverRole.mayWriteProjectData;

  /// Largest `revision` a payload from an untrusted party may claim.
  ///
  /// `revision` increments once per edit. A row edited every second for a
  /// century reaches ~3.2e9, so this is already far past anything a field
  /// record can produce, and its job is not to be tight — it is to stop
  /// `9223372036854775807`, the value that made the merge clock an
  /// unconditional trump card in findings J-1 and K-1 alike.
  ///
  /// **On its own this bound does not defend anything**, and saying so here is
  /// the point: an attacker who picks 4,000,000,000 still outranks a genuine
  /// `revision: 4`, and `MergeResolver` will hand them the row. The clock is
  /// bounded because an unbounded attacker-chosen integer is indefensible on
  /// its own terms; what actually protects the record is rules 1, 2 and 4 —
  /// write only what you carry, never take authorship from a payload, and
  /// never destroy unseen.
  static const int maxRevision = 4000000000;

  /// How many of this device's own future edits [maxImportedRevision] reserves.
  ///
  /// A row edited every ten seconds for four months reaches 1,000,000, so this
  /// is not a budget a field record can spend. Its size is not the point; its
  /// existence is.
  static const int revisionHeadroom = 1000000;

  /// The largest `revision` an untrusted payload may actually *carry* — as
  /// opposed to [maxRevision], the largest this device is willing to hold.
  ///
  /// **Finding L-2 is the gap between those two sentences, and the class
  /// statement is worth more than the number: a bound that admits a value it
  /// will later refuse is not a bound.** §14.3's archive set `revision` to
  /// exactly [maxRevision] — legal, because clause 3's check was `>` — and the
  /// row applied. One honest edit later `base_repository`'s
  /// `revision = revision + 1` put it at 4,000,000,001, and the *user's own
  /// export* would not restore on a replacement device: the same clause 3 that
  /// admitted the value refused the row that grew out of it. The harm is
  /// silent loss of an irreplaceable field record, invisible until the day the
  /// backup is needed.
  ///
  /// So the import bound reserves headroom for what this device will itself do
  /// to the row. Anything above it is **refused at the door, visibly**, which
  /// is the one place a refusal costs nothing: the file is still on disk and
  /// the user is told. Contrast the alternative of relaxing the *storage*
  /// ceiling on restore — that cannot work, because an archive is
  /// unauthenticated (§4.19.2's named residual) and the restore path cannot
  /// tell the user's own export from a forgery.
  static const int maxImportedRevision = maxRevision - revisionHeadroom;

  /// The largest single-step `revision` advance an untrusted payload may make
  /// to a row this device already holds without the user being shown it.
  ///
  /// `revision` counts edits **to one row**. A field observation is corrected a
  /// handful of times; a row a person has edited a thousand times is not a
  /// field record. The bound exists because [maxImportedRevision] closes the
  /// *ceiling* arm of L-2 and not the *freeze* arm: `revision: 1000000` is far
  /// below every absolute bound, outranks a genuine `revision: 7` forever, and
  /// the app reports every later correction from a teammate as *"Unchanged
  /// (local was newer)."*
  ///
  /// **Chosen so that being wrong is cheap.** Exceeding it does not refuse
  /// anything — it moves the clock into rule 4's consent diff, so a legitimate
  /// import that trips it costs one extra line in a dialog the user is already
  /// reading. That asymmetry is what makes a domain guess safe to make here
  /// and would not make it safe in [maxImportedRevision]'s position.
  ///
  /// **Finding M-17 is the measurement of what this bound leaves open below
  /// itself, and it is now the *ceiling* of the allowance rather than the whole
  /// of it** — see [revisionAdvancePerVisibleChange]. A payload advancing the
  /// clock by exactly 1000 while filling one empty column applied with no
  /// dialog and no mention of the clock, and froze the row against every
  /// teammate's later correction. Kept as an absolute cap so that no quantity
  /// of visible changes can explain an advance past it.
  static const int maxUnexplainedRevisionAdvance = 1000;

  /// How much clock advance **one visible change** accounts for.
  ///
  /// This is finding **M-17**'s fix, and the class statement is the part worth
  /// keeping: *§4.19 clause 4's exemption reasons about a field's visibility,
  /// and the harm lives in its magnitude.* The exemption itself is correct and
  /// is deliberately not being deleted — `revision` moves on every honest edit,
  /// so listing it column-by-column would make the dialog fire on every
  /// legitimate import, and a dialog people learn to dismiss protects nobody.
  /// What was wrong is that the allowance was a **flat** number: one filled
  /// column bought the same 1000 as forty rewritten ones. `+1` beside one
  /// edited column is noise; `+1000` beside one filled column is the finding.
  ///
  /// So consent now turns on the advance being *unexplained relative to what
  /// the user is being shown*. `revision` counts edits to one row, and the diff
  /// is the net effect of the edits the file's copy has that this device's does
  /// not. Repeated edits to the same column mean an honest advance can exceed
  /// the change count — hence an allowance well above 1 per change rather than
  /// an equality — but it cannot be unbounded in a diff of size one, which is
  /// exactly what M-17 measured.
  ///
  /// **The same cheapness asymmetry as the bound above, and it is why a domain
  /// guess is safe here too:** being too tight costs one extra line in a dialog;
  /// being too loose costs a field record frozen against its own project. A row
  /// re-edited more than twenty-five times per column the holder can see is not
  /// a field observation.
  static const int revisionAdvancePerVisibleChange = 25;

  /// The largest advance [otherChanges] visible changes can account for.
  ///
  /// Zero when nothing else changed — a payload whose only effect is to move
  /// the clock explains nothing, which is arm (1) of
  /// [isUnexplainedRevisionAdvance] and is unchanged by M-17.
  static int explainedRevisionAdvance(int otherChanges) {
    if (otherChanges <= 0) return 0;
    final scaled = otherChanges * revisionAdvancePerVisibleChange;
    return scaled < maxUnexplainedRevisionAdvance
        ? scaled
        : maxUnexplainedRevisionAdvance;
  }

  /// How far ahead of this device's clock a payload's timestamps may sit.
  ///
  /// Matches the server's `ClockSkew.tolerance`, and departs from it in what
  /// happens next — see this class's own note above.
  static const Duration maxClockLead = Duration(minutes: 5);

  /// Timestamps before this are a broken clock, not old data. Mirrors the
  /// server's `ClockSkew.plausibleFloor` and exists for the same reason: an
  /// absolute floor separates a dead-battery device from a legitimately long
  /// offline backlog, which a relative age check cannot.
  static final DateTime plausibleFloor = DateTime.utc(2020);

  /// Every timestamp column the merge clock is read from, on every table.
  ///
  /// `deleted_at` is in the list and was not in §4.19's original enforcement,
  /// because the share format carries it as a fixed `null` (only live
  /// observations are shareable) — an exemption the *format* creates, not the
  /// rule. An archive carries it verbatim, and K-1's reproduction used
  /// `deleted_at = 2999-01-01` to tombstone an observation the device held.
  static const List<String> timestampColumns = [
    'created_at',
    'updated_at',
    'deleted_at',
  ];

  /// Columns excluded from rule 4's `was → becomes` consent diff.
  ///
  /// **One criterion, and it is not "these are the clock columns":** a column
  /// is exempt only if it *moves on every honest edit*. Listing such a column
  /// would make a one-word note correction render as a multi-field overwrite,
  /// and a confirmation prompt that is always alarming is one the user learns
  /// to dismiss — which puts the record back where J-1 found it with an extra
  /// click.
  ///
  /// Finding **K-8** is what this list looked like when the criterion was left
  /// implicit. `created_at` and `origin_device_id` were exempt too, and neither
  /// moves on an honest edit: `created_at` is the row's birth instant and
  /// `origin_device_id` is the device that first wrote it. Both are taken
  /// verbatim from the payload, so a file could rewrite provenance
  /// (`created_at`) and claim the permanent last-write-wins tiebreaker
  /// (`origin_device_id` — `postgres_schema.dart`'s documented final tiebreak,
  /// so a lexically-high forged value wins *every future tie* against the
  /// holder's genuine edits) with **no dialog at all**, while the receipt said
  /// *"replaced as you confirmed — 0 values were changed."* That is J-1's
  /// fourth defect — a correct-looking message hiding harm — reproduced inside
  /// J-1's own remediation.
  ///
  /// `last_modified_by` stays exempt and is the case that shows the criterion
  /// is the right one rather than a convenient one: it genuinely does move
  /// whenever a different person edits the row, *and* on every import path
  /// rule 2 already forbids it from carrying the payload's claim — so what it
  /// changes to is this device's own resolution, never an attacker's choice.
  static const Set<String> columnsMovedByEveryEdit = {
    'revision',
    'updated_at',
    'last_modified_by',
  };

  /// The columns whose **value the merge itself reads** — the ordering keys
  /// `MergeResolver` decides a conflict on, and the quantity clause 3 bounds.
  ///
  /// This is the second half of the exemption criterion, and finding **L-2** is
  /// what it cost to have only the first. "Moves on every honest edit" was
  /// treated as sufficient; it is not. **The criterion is sound for a column
  /// whose value the merge *ignores* and unsound for one the merge *reads*** —
  /// because exempting a column the merge reads means the one field an attacker
  /// most wants to set is the one field the user is never shown. §14.3's
  /// archive changed nothing but `revision` and applied with
  /// `changes=0 destructive=0 issues=0` and no dialog.
  ///
  /// `origin_device_id` is here because `postgres_schema.dart` documents it as
  /// the final last-write-wins tiebreak. Finding K-8 already removed it from
  /// the exemption by hand; listing it here is what stops the two sets drifting
  /// back together, since the exemption is now *derived* rather than typed.
  static const Set<String> columnsTheMergeReads = {
    'revision',
    'updated_at',
    'origin_device_id',
  };

  /// Clause 4's exemption, **derived from the criterion rather than listed.**
  ///
  /// The whole content of the fix for L-2 is that this is a computation.
  /// Patching `revision` out of a hand-maintained list would have left the next
  /// reader with the same list and no criterion, which is how K-8 happened
  /// inside J-1's own remediation.
  ///
  /// What survives derivation is `last_modified_by` alone — and it is the case
  /// that shows the criterion is the right one rather than a convenient one. It
  /// genuinely moves whenever a different person edits the row; the merge never
  /// reads it (task 10.10 excluded it from reachability by hand for the same
  /// reason — it is free-text provenance that references nothing); and on every
  /// import path rule 2 already forbids it from carrying the payload's claim.
  /// So what it changes to is never an attacker's choice, which is the property
  /// an exemption actually requires.
  static final Set<String> consentDiffExempt = {
    for (final column in columnsMovedByEveryEdit)
      if (!columnsTheMergeReads.contains(column)) column,
  };

  /// The merge clock proper: moved by every honest edit **and** read by the
  /// merge. These are not exempt — but neither are they diffed column by
  /// column, because a one-word note correction rendering as a three-field
  /// overwrite is the prompt the user learns to dismiss, which is what the
  /// exemption existed to prevent and is a real property worth keeping.
  ///
  /// They are judged together instead, by [isUnexplainedRevisionAdvance]: shown
  /// when the payload cannot account for them, silent when it can.
  static final Set<String> mergeClockColumns = {
    for (final column in columnsMovedByEveryEdit)
      if (columnsTheMergeReads.contains(column)) column,
  };

  /// Whether an incoming update's advance of the merge clock is something the
  /// change it carries can account for.
  ///
  /// Two ways it cannot, and each is a measured harm from §14.3 rather than a
  /// guess:
  ///
  /// 1. **The file's only effect is to move the clock.** An honest edit changes
  ///    something and stamps the clock on the way past. A payload that changes
  ///    nothing else is not an edit — it is a bid for the row's future, and it
  ///    is exactly L-2's reproduction.
  /// 2. **The advance is larger than the changes on screen explain**
  ///    ([explainedRevisionAdvance]) — the arm that closes the obvious bypass
  ///    of (1), which is to poison the clock *alongside* a real change.
  ///
  /// Arm (2) was a flat [maxUnexplainedRevisionAdvance] and is now proportional
  /// to what the user is shown, capped by it. **That is finding M-17**: a flat
  /// allowance meant one filled column bought the same thousand versions as a
  /// wholesale rewrite, so `+1000` with a single addition applied silently and
  /// froze the row against every teammate's later correction. The exemption's
  /// original purpose is untouched — the question is still *"can the change
  /// this file carries account for the clock it moves?"*, and for an ordinary
  /// correction the answer is still yes and the clock is still never mentioned.
  ///
  /// A clock that does not advance is not judged at all: it cannot win
  /// last-write-wins, so it destroys nothing.
  ///
  /// [otherChanges] counts the non-exempt, non-clock columns this update would
  /// change — the ones the user would have been shown anyway.
  static bool isUnexplainedRevisionAdvance({
    required Object? was,
    required Object? becomes,
    required int otherChanges,
  }) {
    if (was is! int || becomes is! int) return false;
    final advance = becomes - was;
    if (advance <= 0) return false;
    return advance > explainedRevisionAdvance(otherChanges);
  }

  /// Whether *any* movement of the merge clock is something the change the
  /// payload carries can account for. This is what the consent diff asks.
  ///
  /// **M-17's sweep found this, and it is the same defect one column over.**
  /// [isUnexplainedRevisionAdvance] judges `revision` — so a payload that left
  /// `revision` alone and moved only `updated_at`, the merge's *tiebreak*, was
  /// never judged at all. Measured: `updated_at` set four minutes ahead of the
  /// holder's clock, everything else byte-identical, `outcome=applied
  /// changes=0` and a falsified timestamp on disk with no dialog. It is small —
  /// clause 3 caps the lead at [maxClockLead], so the row outranks only honest
  /// edits made inside that window, and the next edit anywhere bumps `revision`
  /// past it — but "the file's only effect is to move the clock" is arm (1),
  /// and arm (1) had been written about one of the two clock columns.
  ///
  /// [mergeClockColumns] rather than the two names, for §4.19.3's reason: a
  /// column that later becomes one the merge reads inherits the clause instead
  /// of needing someone to remember it here.
  static bool isUnexplainedClockAdvance({
    required Map<String, Object?> existing,
    required Map<String, Object?> patch,
    required int otherChanges,
  }) {
    if (isUnexplainedRevisionAdvance(
      was: existing['revision'],
      becomes: patch['revision'],
      otherChanges: otherChanges,
    )) {
      return true;
    }
    if (otherChanges > 0) return false;
    return mergeClockColumns.any((column) =>
        patch.containsKey(column) && existing[column] != patch[column]);
  }

  /// Whether one `was → becomes` change destroys information the device
  /// already holds, and therefore needs rule 4's consent.
  ///
  /// Filling an empty column is an *addition* and needs no prompt — that is
  /// the whole reason rule 4 is a targeted gate rather than a prompt on every
  /// import, and a prompt that always fires is one the user learns to dismiss.
  ///
  /// **Deactivation is the exception, and it is not a special case so much as
  /// the criterion read correctly.** A tombstone landing on a live row has
  /// `was == null`, so a plain "was it non-null?" test calls it an addition —
  /// while what it actually does is remove the whole record from every screen
  /// the holder looks at. §4.19 rule 4's subject is *information this device
  /// already holds*, and a live row is information. K-1's reproduction
  /// tombstoned an observation this way, counted as nothing changed.
  ///
  /// The share format never reaches that branch (it carries `deleted_at` as a
  /// fixed `null`, so it can only ever *un*-delete, which the non-null test
  /// already catches) — which is exactly why the branch has to be defined
  /// here, on the rule, rather than on the one path that happens not to need
  /// it.
  ///
  /// **Finding L-12 is what it cost to spell `deleted_at` out here.** The
  /// branch named one column by hand, and `Project_Memberships.end_date` is a
  /// second way a row goes away — `end_date IS NULL` is what
  /// `ProjectMembershipRepository` means by "current" — so an archive
  /// deactivating a membership applied with `destructiveChanges=0` and no
  /// dialog. The predicate now derives from [SyncTable.deactivationColumns],
  /// the way clause 2 derives from [SyncTable.identityUserColumns]: a table
  /// that gains a deactivation column inherits the clause instead of needing
  /// someone to remember it here. An unknown [table] falls back to the
  /// universal soft-delete column rather than to *nothing*, because failing
  /// open on this predicate means a silent write.
  static bool isDestructiveChange({
    required String table,
    required String column,
    required Object? was,
    required Object? becomes,
  }) {
    if (was != null) return true;
    final deactivation =
        syncTablesByName[table]?.deactivationColumns ?? const ['deleted_at'];
    return deactivation.contains(column) && becomes != null;
  }

  /// §4.19 rule 3 over one raw column-map, for any table.
  ///
  /// Returns the empty list when the row's merge clock is in range. Every
  /// finding is a **refusal** of the row, never a clamp: clamping a hostile
  /// clock to "now" leaves it winning last-write-wins against every honest
  /// local edit — the attack succeeds and the bound reports that it worked.
  ///
  /// [now] is this device's clock, passed in rather than read so the bound is
  /// testable and so a single import measures every row against one reading.
  static List<RowIssue> checkClock(
    String table,
    Map<String, Object?> row, {
    required DateTime now,
  }) {
    final issues = <RowIssue>[];
    final pk = _primaryKeyValue(table, row);
    final ceiling = now.toUtc().add(maxClockLead);

    void issue(String field, String message) =>
        issues.add(RowIssue(
          table: table,
          primaryKeyValue: pk,
          field: field,
          message: message,
        ));

    final revision = row['revision'];
    if (revision != null) {
      if (revision is! int) {
        issue('revision', 'must be an integer (was ${revision.runtimeType})');
      } else if (revision < 0) {
        issue('revision', 'must not be negative (was $revision)');
      } else if (revision > maxRevision) {
        issue('revision',
            'sync clock is out of range (implausibly large: $revision)');
      } else if (revision > maxImportedRevision) {
        // Finding L-2's ceiling arm. Legal to *hold* and not legal to
        // *receive*, because holding it is what this device does to the row
        // next — one honest edit past the ceiling and the row cannot be
        // restored from the holder's own export ever again.
        issue(
          'revision',
          'sync clock leaves no room for this device\'s own edits '
          '($revision; an imported row may not exceed $maxImportedRevision)',
        );
      }
    }

    final parsed = <String, DateTime>{};
    for (final column in timestampColumns) {
      final raw = row[column];
      if (raw == null) continue;
      if (raw is! String) {
        issue(column, 'must be an ISO-8601 string (was ${raw.runtimeType})');
        continue;
      }
      final value = DateTime.tryParse(raw);
      if (value == null) {
        issue(column, 'is not a valid timestamp ("$raw")');
        continue;
      }
      final utc = value.toUtc();
      parsed[column] = utc;
      if (utc.isAfter(ceiling)) {
        issue(column, 'sync clock is out of range (in the future: $raw)');
      } else if (utc.isBefore(plausibleFloor)) {
        issue(column, 'sync clock is out of range (predates TriTrack: $raw)');
      }
    }

    final createdAt = parsed['created_at'];
    final updatedAt = parsed['updated_at'];
    if (createdAt != null && updatedAt != null && updatedAt.isBefore(createdAt)) {
      issue('updated_at',
          'sync clock is inconsistent (updated_at precedes created_at)');
    }
    return issues;
  }

  static String _primaryKeyValue(String table, Map<String, Object?> row) {
    final spec = syncTablesByName[table];
    if (spec == null) return '?';
    return spec.primaryKey.map((c) => '${row[c] ?? '?'}').join('/');
  }
}

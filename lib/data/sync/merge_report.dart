import 'package:tritrack_sync/tritrack_sync.dart';

/// Per-table outcome of a merge.
class TableMergeStats {
  TableMergeStats();

  /// Rows that did not exist locally and were inserted.
  int inserted = 0;

  /// Rows that existed locally and were overwritten because the incoming copy
  /// won last-write-wins (or the strategy was overwrite).
  int updated = 0;

  /// Rows that existed locally and were kept because the local copy was newer
  /// (or identical).
  int skipped = 0;

  /// Rows rejected by [RowValidator] and not applied.
  int invalid = 0;

  /// Rows refused by a §4.19 rule before [RowValidator]'s domain checks were
  /// even relevant: an out-of-range merge clock (rule 3), or a row addressed
  /// at a project this import is not for.
  ///
  /// Counted separately from [invalid] because the two answer different
  /// questions and a single "rejected" number hides which. `invalid` means
  /// *this row is not a well-formed record*; `refused` means *this row is
  /// well-formed and the file was not allowed to send it*. Finding K-1's
  /// payload was well-formed throughout.
  int refused = 0;

  int get considered => inserted + updated + skipped + invalid + refused;
}

/// One column an import would change, or did change, on a row this device
/// already holds — the archive-restore counterpart of
/// `SharedObservationFieldChange`, carrying the table and row it belongs to
/// because a restore's diff spans every table rather than one observation.
class MergeFieldChange {
  const MergeFieldChange({
    required this.table,
    required this.rowKey,
    required this.column,
    required this.was,
    required this.becomes,
  });

  final String table;

  /// The row's primary-key value(s), joined — what the UI names the record by.
  final String rowKey;

  final String column;

  /// The value currently in the local database. Null means the column is
  /// empty, which is (almost always) what separates an addition from a
  /// replacement — see [UntrustedImportRules.isDestructiveChange] for the one
  /// case where it is not.
  final Object? was;

  final Object? becomes;

  /// Whether applying this change destroys information the device already had.
  bool get isDestructive => UntrustedImportRules.isDestructiveChange(
        table: table,
        column: column,
        was: was,
        becomes: becomes,
      );
}

/// Whether a merge wrote, or is waiting for the user to say yes.
enum MergeOutcome {
  /// The transaction committed. Every count in the report describes what
  /// happened.
  applied,

  /// The import would replace values this device already holds and no consent
  /// was given, so **nothing was written** (§4.19 rule 4). Every count in the
  /// report describes what *would* happen, and [MergeReport.destructiveChanges]
  /// is the field-by-field list the caller must show before re-running with
  /// `confirmChanges: true`.
  needsConfirmation,

  /// The person performing the import may not write in the project this
  /// archive is for, so **nothing was written and nothing was read from the
  /// file** (§4.19 clause 6, task 11.20).
  ///
  /// Distinct from [needsConfirmation], which is a question. This is an
  /// answer: re-running with `confirmChanges: true` changes nothing, because
  /// consent is not what was missing. A caller that treats every non-[applied]
  /// outcome as "ask the user again" would loop forever on it.
  ///
  /// Every count in the report is zero — the check runs before the plan, so
  /// there is nothing to describe. [MergeReport.receiverRole] carries why.
  refusedNotPermitted,
}

/// **Which of task 11.237's four cases an archive import is**, classified
/// before anything is written and from the archive's own membership rows —
/// because offline is where an import happens, and the file is the only
/// answer available there.
///
/// Two questions, and their product:
///
/// | | The project is already on this device | It is not |
/// |---|---|---|
/// | **I am a member** | [merge] — task 10.87's case, where consent about overwrites belongs | [adopt] — bring it in live |
/// | **I am not** | [mergeIntoSnapshot] — still read-only | [snapshot] — read-only, and said so |
///
/// *Member* is resolved by `resolveProjectRole` over the archive's
/// `Project_Memberships` rows (after the user remap, so the file's ids are
/// this device's ids) and its `Projects.owner_user_id` creator fallback —
/// **or** over this device's own rows for the project, where it already holds
/// them. Either saying yes is a yes: the device's rows are the ones the app
/// will derive from afterwards, and an archive older than this person's
/// membership must not report a live project as a snapshot.
///
/// **The file is untrusted and can lie in either direction; each lie costs
/// something recoverable, which is the argument for deriving rather than
/// refusing.** A file that *claims* a membership the person lacks lands them
/// exactly where every non-member was before 11.237 — a project the server
/// will not take rows for — except that the write gate now refuses on the
/// device's own rows the moment the next sync fails to confirm it. A file that
/// *denies* a membership the person holds makes a live project read-only until
/// the next sync brings their real row, and nothing else. Neither destroys a
/// record, and neither survives a sync.
///
/// **Never stored.** This is what the import *was*; what the project *is* on
/// this device from then on is `readProjectStanding`, re-derived on every
/// read.
enum ImportCase {
  /// Already here, and a member: an ordinary merge into a live project.
  merge,

  /// Not here yet, and a member: the project arrives live. Whether it then
  /// syncs is the ordinary link question — this device still has to publish
  /// or join it — and the file does not decide that.
  adopt,

  /// Already here as a read-only snapshot, and still not a member: the merge
  /// happens, and the result is still read-only.
  mergeIntoSnapshot,

  /// Not here, and not a member: a read-only snapshot of somebody else's
  /// project, which the projects list and every write gate say so about.
  snapshot;

  /// Whether the project is read-only on this device after this import.
  bool get isSnapshot => this == snapshot || this == mergeIntoSnapshot;
}

/// Summary of what a `ProjectMerger.merge` did — or, on
/// [MergeOutcome.needsConfirmation], of what it would do. Nothing here is
/// written to the database; it is a report about the transaction.
class MergeReport {
  MergeReport({
    required this.byTable,
    required this.usersDeduped,
    this.usersMatchedViaPriorEmail = 0,
    required this.schemaMigratedFrom,
    required this.currentSchemaVersion,
    required this.issues,
    this.outcome = MergeOutcome.applied,
    this.changes = const [],
    this.rowsReattributed = 0,
    this.receiverRole,
    this.importCase,
    this.tagsMatchedByLineage = 0,
  });

  /// How many incoming tags named a collar this device already held in the
  /// project under a different id — an archive written before task 11.224's
  /// fork meeting a device that has forked — and were matched onto the
  /// device's tag rather than inserted beside it (task 11.239). Reported
  /// because a re-key is a rewrite of every bearing in the file, and a
  /// rewrite nobody is told about is this project's founding defect.
  final int tagsMatchedByLineage;

  /// Which of task 11.237's cases this import is — see [ImportCase]. Set for
  /// an untrusted archive on every outcome that got as far as reading the
  /// file, including [MergeOutcome.needsConfirmation], so the consent dialog
  /// can say what it is asking consent for. Null on the authenticated-server
  /// path (a sync pull is not an import) and on
  /// [MergeOutcome.refusedNotPermitted], which never reads the file.
  final ImportCase? importCase;

  /// Outcome keyed by table name.
  final Map<String, TableMergeStats> byTable;

  /// Whether the merge committed or is holding at §4.19 rule 4's consent gate.
  final MergeOutcome outcome;

  /// Whether a row was actually written. Stated as a property of the outcome
  /// rather than re-derived at each call site, so a screen cannot report a
  /// successful import after the consent gate held everything back — the same
  /// guard `SharedObservationImportResult.wrote` exists for, and for the same
  /// reason (finding J-1's fourth property).
  ///
  /// Written as an exhaustive switch rather than `== applied` so that adding a
  /// third outcome is a compile error here instead of a silent `false` that
  /// might have wanted to be `true`. Task 11.20 added the third one.
  bool get wrote => switch (outcome) {
        MergeOutcome.applied => true,
        MergeOutcome.needsConfirmation ||
        MergeOutcome.refusedNotPermitted =>
          false,
      };

  /// On [MergeOutcome.refusedNotPermitted], the role the importing user holds
  /// in the project the archive names — the reason the restore was refused.
  ///
  /// Null on every other outcome, including a permitted one, and deliberately:
  /// a permitted restore is *usually* permitted because this device could not
  /// resolve a role at all (§4.19 clause 6's null-permits reading, which on
  /// this path is what makes restoring onto a reinstalled phone work). A
  /// caller reading this as "the role of whoever imported" would be reading a
  /// null that means *unknown* as one that means *none*. The same guard, and
  /// the same wording, as `SharedObservationImportResult.receiverRole`.
  final ProjectRole? receiverRole;

  /// Every column this import would change, or did change, on a row the device
  /// already held. Empty for a pure insert, and for the authenticated-server
  /// path, where §4.19 rule 4 does not apply (overwrites are already recorded
  /// to `Sync_Conflicts` by task 10.12's sync-side capture).
  ///
  /// Populated identically on [MergeOutcome.needsConfirmation] (proposed,
  /// nothing written) and on the [MergeOutcome.applied] run that follows the
  /// user's yes — the same list describes the offer and the receipt, so the
  /// consent given and the change made cannot disagree.
  final List<MergeFieldChange> changes;

  /// The subset of [changes] that replaces, clears or tombstones something the
  /// device already held. This — not [changes] — is what the consent gate
  /// triggers on.
  List<MergeFieldChange> get destructiveChanges =>
      [for (final c in changes) if (c.isDestructive) c];

  /// How many incoming users were matched to an existing local user (by
  /// *current* normalized email, or the prior-email fallback below) with a
  /// different id and remapped onto it. Includes [usersMatchedViaPriorEmail].
  final int usersDeduped;

  /// Of [usersDeduped], how many were matched only via a *prior* email —
  /// either the incoming user's current address matched a local user's
  /// recorded prior address, or one of the incoming user's own prior
  /// addresses matched a local user's current one. Reported distinctly per
  /// the Phase 7 decision that a historical-address match should be visible
  /// to the user rather than silently folded into the same count as an
  /// exact current-email match.
  final int usersMatchedViaPriorEmail;

  /// How many incoming *rows* had a user column rewritten by that dedup.
  ///
  /// Reported because the dedup is a rewrite primitive keyed on an
  /// unauthenticated string, and finding K-1 fact (d) is what it does when
  /// nobody is told: a `Users` row in the archive claiming the holder's email
  /// address caused every one of the file's own rows to be re-attributed to
  /// them — the file's observations, filed under the victim's name, reported
  /// as an ordinary import. The dedup stays (it is the only thing between
  /// "merged my own phone's export" and two of me — see `IdentityTrust`), so
  /// what it owes is visibility.
  final int rowsReattributed;

  /// The schema version the backup was written at (== [currentSchemaVersion]
  /// if no forward-migration was needed).
  final int schemaMigratedFrom;
  final int currentSchemaVersion;

  /// Field-level rejections gathered during validation, and every §4.19
  /// refusal. A refused row is never silently dropped (task 10.28's rule).
  final List<RowIssue> issues;

  bool get migratedSchema => schemaMigratedFrom != currentSchemaVersion;

  int get totalInserted =>
      byTable.values.fold(0, (a, s) => a + s.inserted);
  int get totalUpdated => byTable.values.fold(0, (a, s) => a + s.updated);
  int get totalSkipped => byTable.values.fold(0, (a, s) => a + s.skipped);
  int get totalInvalid => byTable.values.fold(0, (a, s) => a + s.invalid);
  int get totalRefused => byTable.values.fold(0, (a, s) => a + s.refused);

  TableMergeStats statsFor(String table) =>
      byTable.putIfAbsent(table, TableMergeStats.new);
}

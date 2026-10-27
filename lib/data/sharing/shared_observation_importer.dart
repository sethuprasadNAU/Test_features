import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tritrack_sync/tritrack_sync.dart';
import '../db/data_arrival.dart';
import '../models/observation.dart';
import '../models/sync_meta.dart';
import '../models/user.dart';
import '../repositories/project_role_lookup.dart';
import '../repositories/user_repository.dart';
import '../sync/sync_conflicts.dart';
import 'observation_share.dart';

/// What happened when a shared observation was saved.
enum SharedObservationImportOutcome {
  /// v2 replica the device had never seen: written under the sender's original
  /// `observation_id`, so both copies are now the same row.
  replicaInserted,

  /// v2 replica of a row already held locally, and the incoming copy won
  /// last-write-wins — the local row was brought up to date. Reached only with
  /// explicit consent when the change would replace values this device already
  /// held (see [changeNeedsConfirmation]).
  replicaUpdated,

  /// v2 replica of a row already held locally which is the same or newer. The
  /// local copy was kept. Not an error, and deliberately not a silent no-op:
  /// the user pasted something and deserves to be told it was already here.
  replicaAlreadyCurrent,

  /// The payload would replace values this device already holds. **Nothing was
  /// written.** [SharedObservationImportResult.changes] says exactly what would
  /// change; the caller shows it and re-invokes with `confirmChanges: true` if
  /// the user accepts.
  ///
  /// Security model §4.19 rule 4. This is the outcome that makes finding J-1's
  /// reproduction stop being silent — everything else about that payload could
  /// be legitimate and this would still hold it at the door.
  changeNeedsConfirmation,

  /// The payload names an observer who is not the author of the row this device
  /// already holds, so it may not modify it (§4.19 rule 2). Nothing was
  /// written — including no `Users` row for the claimed observer.
  refusedNotAuthor,

  /// The user of **this device** may not write in this project — they are a
  /// viewer (§4.19 clause 6, task 11.19). Nothing was written, and nothing
  /// about the payload was examined: the receiver's rights are decided before
  /// the payload's contents are, so a refused import leaves no trace of the
  /// payload at all, not even a `Users` row for its observer.
  ///
  /// **Distinct from [refusedNotAuthor], and the pair is the actor question
  /// answered in the type.** That one is about the person the payload names —
  /// they may not modify a record they did not write. This one is about the
  /// person holding the phone — they may not write here at all.
  refusedNotPermitted,

  /// [RowValidator] rejected the row the payload would produce (§4.19 rule 5).
  /// Nothing was written. [SharedObservationImportResult.issues] has the
  /// field-level reasons.
  refusedInvalid,

  /// v1 payload: provenance cannot be preserved, so a new receiver-owned
  /// observation was created. May duplicate the sender's row on a later sync.
  legacyCopyCreated,
}

/// One column an import would change on a row this device already holds.
class SharedObservationFieldChange {
  const SharedObservationFieldChange({
    required this.column,
    required this.was,
    required this.becomes,
  });

  final String column;

  /// The value currently in the local database. Null means the column is
  /// empty, which is what separates an addition from a replacement.
  final Object? was;

  final Object? becomes;

  /// Whether applying this change destroys information the device already had.
  /// The criterion — and the `deleted_at` case a bare `was != null` gets
  /// wrong — lives on [UntrustedImportRules.isDestructiveChange], shared with
  /// the archive-restore path so the two cannot answer it differently.
  bool get isDestructive => UntrustedImportRules.isDestructiveChange(
        table: Tables.observations,
        column: column,
        was: was,
        becomes: becomes,
      );
}

/// Outcome of one save, with everything the UI needs to describe it honestly.
class SharedObservationImportResult {
  const SharedObservationImportResult({
    required this.outcome,
    required this.observationId,
    required this.observerUserId,
    this.observerIdMismatch,
    this.observerMatchedViaPriorEmail = false,
    this.changes = const [],
    this.issues = const [],
    this.existingAuthorUserId,
    this.confirmedByUser = false,
    this.receiverRole,
    this.receiverIsNotAMember = false,
  });

  final SharedObservationImportOutcome outcome;

  /// Whether this write went through §4.19 rule 4's consent gate — i.e. it
  /// would have replaced something the device held, so the caller had to show
  /// the `was → becomes` diff and come back with `confirmChanges: true`.
  ///
  /// **False is the interesting value, and finding K-8 is why it exists.** An
  /// update that destroys nothing needs no prompt and gets none — but the
  /// receipt was written as though every update had been confirmed, so a
  /// payload that changed only exempt columns produced *"replaced as you
  /// confirmed — 0 values were changed"* with no dialog anywhere behind it.
  /// Both halves false in the same sentence. The message now reads this rather
  /// than assuming.
  final bool confirmedByUser;

  /// Every column the import would change, or did change, on a row this device
  /// already held. Empty for an insert (nothing to change) and for
  /// [SharedObservationImportOutcome.replicaAlreadyCurrent].
  ///
  /// Populated on both [SharedObservationImportOutcome.changeNeedsConfirmation]
  /// (proposed, nothing written) and
  /// [SharedObservationImportOutcome.replicaUpdated] (applied) — the same list
  /// describes the offer and the receipt, so the confirmation the user gave and
  /// the change they got cannot disagree.
  final List<SharedObservationFieldChange> changes;

  /// Field-level validation failures behind
  /// [SharedObservationImportOutcome.refusedInvalid].
  final List<RowIssue> issues;

  /// On [SharedObservationImportOutcome.refusedNotAuthor], the `user_id` this
  /// device records as the row's author — the one the payload is not.
  final String? existingAuthorUserId;

  /// On [SharedObservationImportOutcome.refusedNotPermitted], the role the
  /// receiving user holds in this project — the reason the save was refused.
  ///
  /// Carried rather than left for the caller to re-read, so the message the
  /// user sees names their actual rung instead of assuming `viewer`. Null on
  /// every other outcome, including a permitted one: a caller must not read
  /// this as "the role of whoever imported" and start deciding things with it.
  final ProjectRole? receiverRole;

  /// On [SharedObservationImportOutcome.refusedNotPermitted], whether the
  /// refusal is task 11.237's: this device can see the receiving user is **not
  /// on** the project at all — a read-only snapshot of a colleague's archive —
  /// rather than on it as a viewer. [receiverRole] is null in both cases, and
  /// the sentence the screen shows is different: a viewer is told to ask for
  /// a better role, a snapshot-holder is told how to join.
  final bool receiverIsNotAMember;

  /// Changes that replace or clear a value the device already held, as opposed
  /// to filling an empty column.
  List<SharedObservationFieldChange> get destructiveChanges =>
      [for (final c in changes) if (c.isDestructive) c];

  /// The row actually written. Equals the payload's `observation_id` for a
  /// replica; a freshly minted UUID on the v1 path.
  final String observationId;

  /// The `user_id` the observation was attributed to.
  final String observerUserId;

  /// Set when a local `Users` row already existed for the observer's email but
  /// under a *different* `user_id` than the payload carried. The local row wins
  /// (see [SharedObservationImporter.save]); this records the id we did not
  /// use so the caller can surface it rather than losing the discrepancy.
  final String? observerIdMismatch;

  /// True when the observer was resolved via a *prior* email (Phase 7) rather
  /// than an exact current-email match — the payload's current address
  /// matched a local user's recorded previous one. Reported distinctly so a
  /// historical-address match is visible to the user rather than looking
  /// like an ordinary match.
  final bool observerMatchedViaPriorEmail;

  bool get isReplica => outcome != SharedObservationImportOutcome.legacyCopyCreated;

  /// Whether a row was actually written. False for every refusal and for the
  /// consent prompt — stated as a property of the outcome rather than
  /// re-derived at each call site, so a screen cannot clear its input on a
  /// refusal and leave the user believing the save happened.
  bool get wrote => switch (outcome) {
        SharedObservationImportOutcome.replicaInserted ||
        SharedObservationImportOutcome.replicaUpdated ||
        SharedObservationImportOutcome.legacyCopyCreated =>
          true,
        SharedObservationImportOutcome.replicaAlreadyCurrent ||
        SharedObservationImportOutcome.changeNeedsConfirmation ||
        SharedObservationImportOutcome.refusedNotAuthor ||
        SharedObservationImportOutcome.refusedNotPermitted ||
        SharedObservationImportOutcome.refusedInvalid =>
          false,
      };
}

/// Saves a pasted [SharedObservation] into the local database.
///
/// A v2 payload is saved as a **faithful replica** of the sender's row: same
/// `observation_id`, same observer `user_id`, same `position_source` /
/// `position_accuracy_m`, and the sender's sync clock copied verbatim. That is
/// the whole point of Phase 6 — minting a new UUID per save (the original
/// behavior) produced two rows with different primary keys for one real
/// observation, so last-write-wins never fired and the observation silently
/// duplicated on sync. Duplicated bearings are especially harmful because the
/// Lenth MLE reads them as independent confirmations and returns a falsely
/// tight confidence ellipse.
///
/// A v1 payload carries none of that identity, so it falls back to creating a
/// new receiver-owned observation — the caller must warn the user that
/// provenance is lost (see [SharedObservation.canReplicate]).
///
/// Takes a [DatabaseExecutor] and does its own raw queries rather than going
/// through repositories, for two reasons: everything must happen in one
/// transaction (repositories hold a `Database`, not the active txn), and a
/// replica write must set the sync columns *verbatim* — `updateById` bumps
/// `revision` and touches `updated_at`, which would corrupt the very clock
/// being replicated.
///
/// ## What a payload may do to a row this device already holds
///
/// A `TT1:` string is data from an untrusted party. It needs no server, no
/// account and no network to reach this code — someone need only get it pasted.
/// Security model **§4.19** states the rules; this class is where they are
/// enforced, and each is load-bearing on its own:
///
/// 0. **The person doing the importing must be allowed to write here** — the
///    §4.21 role gradient, checked against this device's own membership rows
///    before anything about the payload is read
///    ([UntrustedImportRules.receiverMayImport]). Numbered clause 6 in §4.19
///    and listed first here because it runs first; see *"who the actor is"*
///    below.
///
/// 1. **Only the columns the payload can express are written.** The write set
///    is [ObservationShare.writableColumns], not `toColumns()`.
/// 2. **Authorship never comes from a payload.** `user_id` is never written to
///    an existing row, `last_modified_by` is restated as the observer this
///    device resolved, and a payload whose observer is not the row's local
///    author is refused outright.
/// 3. **The merge clock is bounded** (in `ObservationShare.decode`) and refused
///    rather than clamped when out of range.
/// 4. **Nothing that replaces a held value is written without consent** —
///    `confirmChanges`, defaulting to refuse — and the prior version is
///    recorded to `Sync_Conflicts` before it stops existing.
/// 5. **[RowValidator] runs**, as on every other write path in the project.
///
/// Rules 1, 2, 4 and 5 all trace to finding **J-1** (§12.2), where one pasted
/// string moved a real observation to (0,0), reassigned its author, forged its
/// audit column to name the victim, and NULLed the sweep endpoints, declination
/// and WMM model version that make its bearing re-derivable — while the app
/// reported *"updated it to the newer version."* Any one of the four alone
/// leaves that open.
///
/// ## Who the actor is (task 11.19)
///
/// An import has two people in it and every rule above belongs to exactly one
/// of them. Getting this wrong in either direction is a real failure, so it is
/// written down rather than inferred:
///
/// - **The receiving user** — whoever is holding this device. They are
///   performing a write into a project, so the question about them is the
///   ordinary one the app asks before every other write: *may this person
///   write in this project at all?* That is clause 6, it resolves the role
///   from `Project_Memberships` through the same [readProjectRole] the
///   repository layer and the screens use, and a `viewer` is refused here on
///   the device rather than only at the server.
/// - **The payload's observer** — the person the row is attributed to. They
///   are **not** acting. Phase 6 keeps their identity on the row precisely so
///   the record says who made the observation, and the question about them is
///   not about rights but about naming: §4.17's row-naming invariant, which on
///   this path is clause 2. They are never run through the role gradient, and
///   that is a decision rather than an omission — a colleague who shares an
///   observation before they have been invited to the project is the ordinary
///   case sharing exists for, and §4.17 already settled that such a row may be
///   held here and simply will not replicate until they are a member.
///
/// So the two compose in one order and only one: rights first, over the
/// receiver; naming second, over the payload. A receiver who fails clause 6 is
/// turned away before the observer is resolved, which is why a refused import
/// deposits no `Users` row — the same property the sixth consequence below
/// gives the other refusals.
class SharedObservationImporter {
  const SharedObservationImporter(this.db);

  final DatabaseExecutor db;

  /// Saves [shared] into [projectId] against local [tagId].
  ///
  /// [receivingUserId] and [receivingDeviceId] identify *this* device — used to
  /// own the v1 fallback observation, and to stamp the local `Users` row
  /// created for a previously-unknown observer (that row genuinely does
  /// originate here; the payload carries no clock for it).
  ///
  /// [newId] mints ids for the v1 fallback path; injectable so tests are
  /// deterministic.
  /// [confirmChanges] is the user's explicit consent to replace values this
  /// device already holds. Without it an import that would do so returns
  /// [SharedObservationImportOutcome.changeNeedsConfirmation] and writes
  /// nothing — §4.19 rule 4's "no destruction the user did not see", expressed
  /// as a parameter the caller cannot forget, because the default refuses.
  Future<SharedObservationImportResult> save(
    SharedObservation shared, {
    required String projectId,
    required String tagId,
    required String receivingUserId,
    required String receivingDeviceId,
    required String Function() newId,
    bool confirmChanges = false,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    final database = db;
    final result = database is Database
        ? await database.transaction(
            (txn) => _save(txn, shared, projectId, tagId, receivingUserId,
                receivingDeviceId, newId, confirmChanges, timestamp),
          )
        : await _save(database, shared, projectId, tagId, receivingUserId,
            receivingDeviceId, newId, confirmChanges, timestamp);
    // A pasted replica is a bearing that arrived from somebody else's device,
    // so the map and the log have to be told (task 11.45). Said here rather
    // than on the screen that pasted it, because a second screen doing the
    // same import would otherwise have to remember, and would not.
    if (result.wrote) DataArrival.announce();
    return result;
  }

  Future<SharedObservationImportResult> _save(
    DatabaseExecutor txn,
    SharedObservation shared,
    String projectId,
    String tagId,
    String receivingUserId,
    String receivingDeviceId,
    String Function() newId,
    bool confirmChanges,
    DateTime now,
  ) async {
    // **§4.19 clause 6, and it is deliberately the first thing in this method**
    // (task 11.19). Every branch below this line writes an `Observations` row,
    // and one of them writes a `Users` row too. Asking once, here, is what
    // makes the answer the same for all of them — including the branch nobody
    // has written yet. Two guards, one per branch, would be the two-lists
    // defect clause 1 exists because of.
    //
    // Before the payload is looked at, not after: a receiver with no write
    // rights leaves no trace of a payload they were not allowed to import, and
    // this device does not spend a query resolving the identity of an observer
    // named in it.
    //
    // **The standing, not only the role, since task 11.237.** Pasting a
    // bearing into a project is a write into it, and a person holding a
    // read-only snapshot of a colleague's archive is refused here exactly as
    // they are at every other write — `UntrustedImportRules.receiverMayImport`
    // permits on a null role because a *restore* onto a device with no rows
    // must work, and that reading is kept for the merger; this path asks the
    // sharper question the device can answer.
    final receiverStanding = await readProjectStanding(
      txn,
      projectId: projectId,
      userId: receivingUserId,
    );
    final receiverRole = receiverStanding.role;
    if (receiverStanding.isSnapshot ||
        !UntrustedImportRules.receiverMayImport(receiverRole)) {
      return SharedObservationImportResult(
        outcome: SharedObservationImportOutcome.refusedNotPermitted,
        // The payload's own id, not a minted one: nothing was created, so
        // there is no new row to name, and echoing back what was refused is
        // more use to a caller than a UUID that exists nowhere. Null identity
        // (a v1 payload) has no id to echo at all.
        observationId: shared.identity?.observationId ?? '',
        observerUserId: receivingUserId,
        receiverRole: receiverRole,
        receiverIsNotAMember: receiverStanding.isSnapshot,
      );
    }

    final identity = shared.identity;
    if (identity == null) {
      return _saveLegacyCopy(
          txn, shared, projectId, tagId, receivingUserId, receivingDeviceId, newId, now);
    }

    final observer = await _resolveObserver(
      txn,
      identity: identity,
      observerName: shared.observerName,
      receivingDeviceId: receivingDeviceId,
      now: now,
    );

    final replica = Observation(
      observationId: identity.observationId,
      projectId: projectId,
      userId: observer.userId,
      tagId: tagId,
      // The sender's `session_id` is a row on *their* device that this one has
      // never seen, and the payload doesn't carry it. Leaving it null is
      // correct: the replica isn't part of any local triangulation session.
      sessionId: null,
      timestampLocal: shared.timestampLocal,
      timestampUtc: shared.timestampUtc,
      timezoneOffset: shared.timezoneOffset,
      latitude: shared.latitude,
      longitude: shared.longitude,
      positionAccuracyM: identity.positionAccuracyM,
      positionSource: identity.positionSource,
      elevation: shared.elevation,
      observationType: shared.observationType,
      magneticBearing: shared.magneticBearing,
      trueNorthBearing: shared.trueNorthBearing,
      bearingUncertainty: shared.bearingUncertainty,
      signalType: shared.signalType,
      signalStrength: shared.signalStrength,
      // **Carried, unlike `tag_version_id` and `pulse_mode` below** (task
      // 11.193). Those two name rows and slots in the *sender's* database and
      // cannot survive being relabelled onto the receiver's tag; this is what a
      // person heard at a time and a place, and it means the same thing here.
      // Null stays null: a payload that did not say is not a payload saying the
      // signal was fine.
      signalIrregular: shared.signalIrregular,
      bearingQuality: shared.bearingQuality,
      // No "Shared by X" prefix: the observer is now properly attributed via
      // `user_id`, so folding their name into notes would corrupt the
      // sender's own text on every hop.
      notes: shared.notes,
      // **Left null on purpose (task 11.32), and not in
      // `ObservationShare.writableColumns` either.** The payload carries what
      // the sender's bearing was recorded against as *values*, shown on the
      // paste screen, but the sender's `tag_version_id` names a row in their
      // tag's history while this replica is relabelled onto the local tag the
      // receiver picked — the two describe different tags. Null reads "not
      // recorded on this device", which is true. Do not fill this in from the
      // local tag's current version: that is precisely the "whatever the tag
      // says now" substitution this task removes.
      tagVersionId: null,
      // `last_modified_by` is overwritten below with the observer this device
      // resolved. The payload's own value is discarded and never reaches a
      // column: in finding J-1 it was set to the *victim*, so the row recorded
      // its own destruction as the victim's edit.
      sync: identity.sync,
    );

    return _upsertReplica(
      txn,
      replica,
      observer: observer,
      confirmChanges: confirmChanges,
      now: now,
    );
  }

  /// The row a replica write may produce: the model's full column map narrowed
  /// to [ObservationShare.writableColumns], with `last_modified_by` restated as
  /// the resolved observer.
  ///
  /// Narrowing here rather than at each call site is the whole of §4.19 rule 1.
  /// `Observation.toColumns()` emits all 41 columns because that is what an
  /// *authored* row needs; a payload can express 25 of them, and writing the
  /// rest as `NULL` is what erased the sweep endpoints, the declination and
  /// the WMM model version — the fields that make a bearing re-derivable rather
  /// than merely believed.
  static Map<String, Object?> _writableColumns(
    Observation replica,
    String observerUserId,
  ) {
    final all = replica.toColumns();
    return {
      for (final column in ObservationShare.writableColumns)
        if (all.containsKey(column)) column: all[column],
      'last_modified_by': observerUserId,
    };
  }

  /// Inserts the replica, or applies §4.19's rules to a row this device already
  /// holds. Never throws on a primary-key conflict: the same payload gets
  /// pasted twice, and the row may also have arrived from a server sync.
  Future<SharedObservationImportResult> _upsertReplica(
    DatabaseExecutor txn,
    Observation replica, {
    required _ResolvedObserver observer,
    required bool confirmChanges,
    required DateTime now,
  }) async {
    final writable = _writableColumns(replica, observer.userId);

    SharedObservationImportResult result(
      SharedObservationImportOutcome outcome, {
      List<SharedObservationFieldChange> changes = const [],
      List<RowIssue> issues = const [],
      String? existingAuthorUserId,
      bool confirmedByUser = false,
    }) =>
        SharedObservationImportResult(
          outcome: outcome,
          observationId: replica.observationId,
          observerUserId: observer.userId,
          observerIdMismatch: observer.mismatchedPayloadId,
          observerMatchedViaPriorEmail: observer.matchedViaPriorEmail,
          changes: changes,
          issues: issues,
          existingAuthorUserId: existingAuthorUserId,
          confirmedByUser: confirmedByUser,
        );

    // Tombstoned rows are included deliberately: a local tombstone is a real
    // sync state that must be compared, not ignored. Ignoring it would insert
    // over the delete and resurrect the row.
    //
    // Matched on the whole key — `(observation_id, project_id)` since task
    // 10.35 — and this is the call site that most needed it. A replica keeps
    // the sender's `observation_id` by design (task 6.3), so on a device that
    // holds more than one project the same id can genuinely exist in another
    // one. Matching on the id alone would compare this replica against *that*
    // project's row and, if the replica's clock happened to win, overwrite it.
    final existingRows = await txn.query(
      Tables.observations,
      where: 'observation_id = ? AND project_id = ?',
      whereArgs: [replica.observationId, replica.projectId],
      limit: 1,
    );

    if (existingRows.isEmpty) {
      // A row this device has never seen destroys nothing, so the full column
      // map is written — the columns the payload cannot express are genuinely
      // empty here rather than being emptied. It is still validated: §4.19
      // rule 5 is about what lands in the database, not about who is at risk.
      final columns = replica.toColumns()
        ..['last_modified_by'] = observer.userId;
      final issues = RowValidator.validate(Tables.observations, columns);
      if (issues.isNotEmpty) {
        return result(SharedObservationImportOutcome.refusedInvalid, issues: issues);
      }
      await _createObserverIfNeeded(txn, observer);
      await txn.insert(Tables.observations, columns,
          conflictAlgorithm: ConflictAlgorithm.abort);
      return result(SharedObservationImportOutcome.replicaInserted);
    }

    final existing = existingRows.first;

    // Authorship is checked before the merge clock, on purpose. A payload from
    // someone who is not this row's author may not modify it however new it
    // claims to be, and answering "your copy is up to date" to a forged payload
    // would be a correct-looking message about a refusal.
    final localAuthor = existing['user_id'] as String?;
    if (localAuthor != observer.userId) {
      return result(
        SharedObservationImportOutcome.refusedNotAuthor,
        existingAuthorUserId: localAuthor,
      );
    }

    if (!MergeResolver.incomingWins(writable, existing)) {
      return result(SharedObservationImportOutcome.replicaAlreadyCurrent);
    }

    // `user_id` is never written to a row that already exists. The check above
    // has already established the two agree, so removing it changes no value —
    // what it removes is the *possibility* that a future edit to this method
    // reassigns authorship, which is how J-1 locked a biologist out of their
    // own record.
    final patch = Map<String, Object?>.of(writable)..remove('user_id');
    final changes = _changesAgainst(existing, patch);
    final destructive = changes.any((c) => c.isDestructive);

    if (!confirmChanges && destructive) {
      return result(
        SharedObservationImportOutcome.changeNeedsConfirmation,
        changes: changes,
      );
    }

    final merged = {...existing, ...patch};
    final issues = RowValidator.validate(Tables.observations, merged);
    if (issues.isNotEmpty) {
      return result(SharedObservationImportOutcome.refusedInvalid, issues: issues);
    }

    // The prior version is captured before it stops existing, so "recoverable"
    // is a property of the write rather than of the user having a backup.
    // Reuses the Sync_Conflicts store task 10.12 built for the same question
    // asked of sync — an overwrite is an overwrite whichever path carried it.
    await SyncConflictStore.ensureTable(txn);
    await SyncConflictStore(txn).record(
      projectId: replica.projectId,
      tableName: Tables.observations,
      rowKey: replica.observationId,
      localSnapshot: existing,
      incomingSnapshot: merged,
      detectedAtUtc: now,
    );

    await _createObserverIfNeeded(txn, observer);
    await txn.update(
      Tables.observations,
      patch,
      where: 'observation_id = ? AND project_id = ?',
      whereArgs: [replica.observationId, replica.projectId],
    );
    // `destructive`, not `confirmChanges`: consent was *asked for* only if
    // something would have been destroyed. A caller that passes
    // `confirmChanges: true` up front on an import that destroys nothing has
    // not shown the user a dialog, and the receipt must not say it did.
    return result(
      SharedObservationImportOutcome.replicaUpdated,
      changes: changes,
      confirmedByUser: destructive,
    );
  }

  /// Which columns [patch] would actually change on [existing], excluding the
  /// columns clause 4 exempts ([UntrustedImportRules.consentDiffExempt]).
  ///
  /// A column is exempt only if it moves on every honest edit *and* the merge
  /// does not read it, which after finding **L-2** leaves `last_modified_by`
  /// alone. The merge clock is neither exempt nor diffed column by column: a
  /// one-word note correction rendering as a three-field overwrite is the
  /// always-alarming prompt the user learns to dismiss, which would put the
  /// record back where J-1 found it with an extra click. It is judged as one
  /// thing instead and shown only when the payload cannot account for it —
  /// identically to `ProjectMerger._changesAgainst`, because a rule only one
  /// path enforces is the rule the next path re-derives wrongly. After finding
  /// **M-17** "account for" is a magnitude, not a presence: the allowance
  /// scales with the changes the user is being shown.
  static List<SharedObservationFieldChange> _changesAgainst(
    Map<String, Object?> existing,
    Map<String, Object?> patch,
  ) {
    final changes = <SharedObservationFieldChange>[];
    SharedObservationFieldChange change(String column) =>
        SharedObservationFieldChange(
          column: column,
          was: existing[column],
          becomes: patch[column],
        );

    for (final entry in patch.entries) {
      if (UntrustedImportRules.consentDiffExempt.contains(entry.key)) continue;
      if (UntrustedImportRules.mergeClockColumns.contains(entry.key)) continue;
      if (existing[entry.key] == entry.value) continue;
      changes.add(change(entry.key));
    }

    if (UntrustedImportRules.isUnexplainedClockAdvance(
      existing: existing,
      patch: patch,
      otherChanges: changes.length,
    )) {
      for (final column in UntrustedImportRules.mergeClockColumns) {
        if (!patch.containsKey(column)) continue;
        if (existing[column] == patch[column]) continue;
        changes.add(change(column));
      }
    }
    return changes;
  }

  /// Writes the `Users` row for a previously-unknown observer, and only once
  /// the import it belongs to is actually going ahead.
  ///
  /// Deferred deliberately. Creating it during resolution meant a payload that
  /// was about to be refused still deposited a `Users` row of the sender's
  /// choosing — an identity anchor a later file import can match on, planted by
  /// an import that "failed".
  Future<void> _createObserverIfNeeded(
    DatabaseExecutor txn,
    _ResolvedObserver observer,
  ) async {
    final user = observer.userToCreate;
    if (user == null) return;
    await txn.insert(Tables.users, user.toColumns(),
        conflictAlgorithm: ConflictAlgorithm.abort);
  }

  /// Finds or creates the local `Users` row for the payload's observer, keyed
  /// on normalized email (the documented cross-device identity anchor). Falls
  /// back to a prior-email match (Phase 7) when no current email matches —
  /// see the guardrail in the body: current always wins, and an ambiguous
  /// prior email never auto-matches.
  ///
  /// If a local row already exists for that email under a different `user_id`,
  /// the **local row wins**: rewriting a local id would break every foreign key
  /// already pointing at it, and creating a second row for one person would
  /// defeat the dedup this anchor exists for. The rejected payload id is
  /// reported back instead of being dropped.
  Future<_ResolvedObserver> _resolveObserver(
    DatabaseExecutor txn, {
    required SharedObservationIdentity identity,
    required String observerName,
    required String receivingDeviceId,
    required DateTime now,
  }) async {
    final email = UserRepository.normalizeEmail(identity.observerEmail);
    final matches = await txn.query(
      Tables.users,
      where: 'email = ?',
      whereArgs: [email],
    );

    if (matches.isNotEmpty) {
      final localId = _preferredLocalUserId(matches);
      return _ResolvedObserver(
        userId: localId,
        mismatchedPayloadId: localId == identity.observerUserId ? null : identity.observerUserId,
      );
    }

    // No current-email match: fall back to a local user's *prior* email —
    // the other device changed its address and recorded the old one here.
    // Current matches always take precedence (handled above); this only runs
    // when none exists. An address recorded as a prior email by more than one
    // distinct local user is ambiguous (e.g. a reassigned shared address) and
    // is not used — mirrors `ProjectMerger._buildUserRemap`'s guardrail so the
    // two paths never disagree.
    final priorRows = await txn.query(
      Tables.userEmails,
      where: 'email = ? AND deleted_at IS NULL',
      whereArgs: [email],
    );
    final priorUserIds = priorRows.map((r) => r['user_id'] as String).toSet();
    if (priorUserIds.length == 1) {
      final localId = priorUserIds.single;
      return _ResolvedObserver(
        userId: localId,
        mismatchedPayloadId: localId == identity.observerUserId ? null : identity.observerUserId,
        matchedViaPriorEmail: true,
      );
    }

    // Unknown observer: the row is *described* here and written only if the
    // import proceeds (see [_createObserverIfNeeded]). It carries the payload's
    // `user_id` so the replica's `user_id` is identical on both devices — a
    // locally-minted id instead would leave the two copies differing in a
    // column and conflicting forever on the very row we're trying to converge.
    //
    // The clock is `initial` because the payload carries no clock for the
    // *user* row (only for the observation) — and honestly so: this local
    // Users row really was created here, now.
    final names = _splitName(observerName);
    final user = User(
      userId: identity.observerUserId,
      firstName: names.first,
      lastName: names.last,
      email: email,
      sync: SyncMeta.initial(
        now: now,
        modifiedBy: identity.observerUserId,
        originDeviceId: receivingDeviceId,
      ),
    );
    return _ResolvedObserver(userId: user.userId, userToCreate: user);
  }

  /// Deterministic choice when more than one local row shares an email (an
  /// unusual state, but reachable via merge): prefer a live row over a
  /// tombstoned one, then the lexically smallest id. Matches
  /// `ProjectMerger`'s rule so the two paths never disagree about which row
  /// is "the" local user.
  static String _preferredLocalUserId(List<Map<String, Object?>> rows) {
    String? chosen;
    var chosenDeleted = true;
    for (final row in rows) {
      final id = row['user_id'] as String;
      final deleted = row['deleted_at'] != null;
      if (chosen == null ||
          (chosenDeleted && !deleted) ||
          (chosenDeleted == deleted && id.compareTo(chosen) < 0)) {
        chosen = id;
        chosenDeleted = deleted;
      }
    }
    return chosen!;
  }

  /// Today's pre-v2 behavior, kept only for v1 payloads: a new,
  /// receiver-owned observation with the observer's name folded into notes,
  /// because a v1 payload genuinely carries no identity to preserve.
  Future<SharedObservationImportResult> _saveLegacyCopy(
    DatabaseExecutor txn,
    SharedObservation shared,
    String projectId,
    String tagId,
    String receivingUserId,
    String receivingDeviceId,
    String Function() newId,
    DateTime now,
  ) async {
    final provenance = 'Shared by ${shared.observerName}';
    final notes = shared.notes == null ? provenance : '$provenance — ${shared.notes}';

    final observation = Observation(
      observationId: newId(),
      projectId: projectId,
      userId: receivingUserId,
      tagId: tagId,
      timestampLocal: shared.timestampLocal,
      timestampUtc: shared.timestampUtc,
      timezoneOffset: shared.timezoneOffset,
      latitude: shared.latitude,
      longitude: shared.longitude,
      positionSource: PositionSource.manualEntry,
      elevation: shared.elevation,
      observationType: shared.observationType,
      magneticBearing: shared.magneticBearing,
      trueNorthBearing: shared.trueNorthBearing,
      bearingUncertainty: shared.bearingUncertainty,
      signalType: shared.signalType,
      signalStrength: shared.signalStrength,
      bearingQuality: shared.bearingQuality,
      notes: notes,
      // Null for the same reason the replica path leaves it null — see there.
      // A v1 payload additionally predates task 11.32 entirely and could not
      // say what the bearing was recorded against even in principle.
      tagVersionId: null,
      sync: SyncMeta.initial(
        now: now,
        modifiedBy: receivingUserId,
        originDeviceId: receivingDeviceId,
      ),
    );
    // Validated like every other import (§4.19 rule 5). This path mints its own
    // id and cannot collide with an existing row, so it has nothing to destroy
    // — but "cannot destroy" is not "may write anything", and a v1 payload is
    // the same untrusted string.
    final columns = observation.toColumns();
    final issues = RowValidator.validate(Tables.observations, columns);
    if (issues.isNotEmpty) {
      return SharedObservationImportResult(
        outcome: SharedObservationImportOutcome.refusedInvalid,
        observationId: observation.observationId,
        observerUserId: receivingUserId,
        issues: issues,
      );
    }
    await txn.insert(Tables.observations, columns,
        conflictAlgorithm: ConflictAlgorithm.abort);

    return SharedObservationImportResult(
      outcome: SharedObservationImportOutcome.legacyCopyCreated,
      observationId: observation.observationId,
      observerUserId: receivingUserId,
    );
  }

  /// "Sam Ranger" -> ("Sam", "Ranger"). A single-token name keeps an empty
  /// last name (the column is NOT NULL, not non-empty), and extra tokens all
  /// land in the last name rather than being dropped.
  static ({String first, String last}) _splitName(String full) {
    final parts = full.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return (first: 'Unknown', last: '');
    if (parts.length == 1) return (first: parts.first, last: '');
    return (first: parts.first, last: parts.sublist(1).join(' '));
  }
}

class _ResolvedObserver {
  const _ResolvedObserver({
    required this.userId,
    this.mismatchedPayloadId,
    this.matchedViaPriorEmail = false,
    this.userToCreate,
  });
  final String userId;
  final String? mismatchedPayloadId;
  final bool matchedViaPriorEmail;

  /// The local `Users` row this observer needs, when no local user matched.
  /// Described, not yet written — see [SharedObservationImporter
  /// ._createObserverIfNeeded].
  final User? userToCreate;
}

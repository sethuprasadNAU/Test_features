import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../db/data_arrival.dart';
import 'sync_conflicts.dart';

/// What [ServerIdentityAdopter._resolveLocalUserIds] concluded: the ids to
/// fold in, and the ids it deliberately declined to fold in.
typedef _ResolvedLocalIds = ({Set<String> adopt, Set<String> heldBack});

/// Adoption refused, with nothing written — the transaction rolls back whole.
///
/// Every reason is a statement about the *server's* response, not about the
/// user, which is why the message is worth surfacing: the user did nothing
/// wrong and their device is unchanged. See security model §4.20.
class IdentityAdoptionRefused implements Exception {
  const IdentityAdoptionRefused(this.reason);

  /// Short, user-showable, and deliberately free of the offending value —
  /// a server-chosen string is exactly the thing not to paste into a snackbar.
  final String reason;

  @override
  String toString() => 'IdentityAdoptionRefused: $reason';
}

/// What an adoption did, for reporting and tests.
class IdentityAdoptionReport {
  const IdentityAdoptionReport({
    required this.serverUserId,
    required this.remappedFrom,
    required this.heldBack,
    required this.rowsRewritten,
    required this.createdServerUserRow,
    required this.supersededRowsCaptured,
  });

  /// The authoritative id every affected row now carries.
  final String serverUserId;

  /// Local user ids that were folded into [serverUserId]. Empty when this
  /// device was already on the server's id — the idempotent re-run case.
  final Set<String> remappedFrom;

  /// Local user ids that matched the signed-in address but were **not** folded
  /// in, because more than one local person claims that address — the shared
  /// institutional mailbox case. Their rows are untouched and their `Users`
  /// rows still exist. See [ServerIdentityAdopter._resolveLocalUserIds].
  final Set<String> heldBack;

  /// How many column values were rewritten across all tables.
  final int rowsRewritten;

  /// True if a `Users` row for [serverUserId] had to be created (the normal
  /// first sign-in); false if one already existed.
  final bool createdServerUserRow;

  /// How many `Sync_Conflicts` rows were written to preserve the superseded
  /// `Users` rows before they were hard-deleted. Zero exactly when nothing
  /// was superseded.
  final int supersededRowsCaptured;

  bool get changedAnything => remappedFrom.isNotEmpty || createdServerUserRow;
}

/// Adopts the server's authoritative `user_id` for a signed-in email, rewriting
/// this device's local rows onto it (task 10.6).
///
/// ## Why this exists at all
///
/// Phase 6's `ProjectMerger._buildUserRemap` resolves an email collision in
/// favour of the **local** id. Peer-to-peer that is symmetric and fine: desktop
/// merges the phone's backup and remaps the phone's user onto the desktop id,
/// the phone does the reverse, each device stays internally consistent, and
/// they permanently disagree with each other. File-based sync is manual and
/// occasional, so it never shows.
///
/// Continuous server sync makes it acute. Every round would rewrite `user_id`
/// values, bump `revision` on every affected row, and push the churn back —
/// two devices renaming the same person forever. So: **the server is
/// authoritative for the `user_id` behind an email**, and a device adopts it
/// rather than negotiating. Peer-to-peer merge keeps its local-wins rule
/// unchanged for the no-server case; this class is a different *choice*, not a
/// second copy of the rewrite.
///
/// ## What is reused, and what isn't
///
/// The set of columns that hold a user id is **not** re-listed here — it comes
/// from `syncTables`' `userColumns`, the same declaration `ProjectMerger`
/// drives its own remap from. A hand-written list would be a second source of
/// truth and would drift the first time a table gained a user column. What is
/// genuinely new is that this rewrites *local database rows*, where the merger
/// rewrites an *in-memory incoming payload* before insert.
///
/// ## How far the server is trusted here (task 10.75, finding K-4)
///
/// §4.19 says an untrusted import may never be trusted with authorship or with
/// the merge clock. This class takes both from the server. The full argument
/// for why that is defensible — and for the three places it stops being
/// defensible — is security model **§4.20**; the short form, because a reader
/// standing in this file should not have to go and find it:
///
/// - **The server IS the authority on which id names an email**, by design
///   (§4.17/§4.18), over an authenticated session, on a response bounded by
///   `completeSignIn`'s check that the address is the one the *user typed*. A
///   picked file has no such authority and no such session. That asymmetry is
///   real, and it is the whole of what it buys.
/// - **It is not authority over the id's shape.** An opaque remote string goes
///   into a primary key on eleven tables. [RowValidator] runs here now — §4.19
///   clause 5, which was never a trust judgement in the first place.
/// - **It is not authority over which local rows are that person's.** The
///   server names an id; the *targets* are chosen here, from local email
///   anchors. The honest-path defect below is entirely a local inference bug
///   and would exist against a perfectly behaved server.
/// - **It is not authority to destroy.** §4.19 clause 4's subject is *the
///   person holding the record*, not the trust level of the sender. The
///   superseded `Users` row is captured to `Sync_Conflicts` before it is
///   deleted, for the same reason every other overwrite in the app is.
///
/// ## Guarantees
///
/// - **One transaction.** Nothing is half-applied: an interruption rolls the
///   whole thing back, so a re-run starts from a clean state. A partially
///   remapped database — rows split across two ids with no record of which was
///   intended — has no clean recovery, which is why this is the one thing the
///   class is most careful about.
/// - **Idempotent.** Running it twice does what running it once did. The second
///   run finds no local user matching the email except the server-id row
///   itself, and rewrites nothing.
/// - **Rewritten rows get a bumped sync clock**, so the new attribution
///   actually propagates. See [_rewriteUserColumns].
/// - **Refusal is total.** Every check below throws [IdentityAdoptionRefused]
///   from inside the transaction, so a refused adoption leaves the database
///   byte-identical. `completeSignIn` runs this *before* storing the session,
///   so a refusal also leaves the device signed out rather than signed in
///   under an id it just declined to write.
class ServerIdentityAdopter {
  const ServerIdentityAdopter(this.db);

  final DatabaseExecutor db;

  /// Folds this device's local identity for [email] onto [serverUserId].
  ///
  /// [activeUserId] is the device's current user. It is adopted even when its
  /// stored email does not match [email], but only if it still carries a
  /// Phase 7 placeholder address — see [_resolveLocalUserIds].
  /// `async` so that **every** refusal below arrives as a failed future rather
  /// than as a synchronous throw. The pre-transaction check would otherwise
  /// throw from the call expression itself, and a caller that catches around
  /// its `await` — which is every caller, including `completeSignIn` — would
  /// handle two of the four refusals differently from the other two.
  Future<IdentityAdoptionReport> adopt({
    required String serverUserId,
    required String email,
    required String firstName,
    required String lastName,
    String? activeUserId,
    required String deviceId,
    required DateTime now,
  }) async {
    final normalized = normalizeEmail(email);

    // Before the transaction, because it needs nothing from the database and
    // because a value this malformed should not reach a `WHERE` clause even
    // as a parameter. §4.19 clause 5 applied to the one column that arrives
    // outside a row map: the server's chosen id is about to become the
    // primary key of a `Users` row and the value of a user column on ten
    // other tables, and "is a non-empty String" was the entire check.
    if (!RowValidator.isWellFormedIdentifier(serverUserId)) {
      throw const IdentityAdoptionRefused(
        'The server answered with an account id this device cannot store.',
      );
    }

    final report = await _asTransaction((txn) async {
      final resolved = await _resolveLocalUserIds(
        txn,
        email: normalized,
        activeUserId: activeUserId,
      );
      final localIds = resolved.adopt;
      // The server's own id is never a *source* — folding it into itself is
      // the no-op that makes re-running safe.
      localIds.remove(serverUserId);

      final existingServerRow = await txn.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [serverUserId],
        limit: 1,
      );
      final createdServerUserRow = existingServerRow.isEmpty;

      if (!createdServerUserRow) {
        await _refuseIfAnotherPerson(
          txn,
          existingRow: existingServerRow.first,
          serverUserId: serverUserId,
          email: normalized,
        );
      }

      if (createdServerUserRow) {
        // The new row inherits the local user's profile when there is one, so
        // adoption does not quietly discard a name the user typed at first run.
        final source = localIds.isEmpty
            ? null
            : (await txn.query(
                Tables.users,
                where: 'user_id = ?',
                whereArgs: [localIds.first],
                limit: 1,
              )).firstOrNull;
        final userRow = <String, Object?>{
          'user_id': serverUserId,
          'first_name': (source?['first_name'] as String?) ?? firstName,
          'last_name': (source?['last_name'] as String?) ?? lastName,
          'email': normalized,
          'created_at':
              (source?['created_at'] as String?) ?? DbCodec.encodeUtc(now),
          'updated_at': DbCodec.encodeUtc(now),
          'deleted_at': null,
          'revision': (source?['revision'] as int?) ?? 0,
          'last_modified_by': serverUserId,
          'origin_device_id':
              (source?['origin_device_id'] as String?) ?? deviceId,
        };
        // This was the only remaining write path in the app that skipped
        // `RowValidator` — §4.19's clause 5, on the one path whose input
        // comes from the network rather than from a file. The `email` bound
        // matters as much as the id one: `completeSignIn` proved the server
        // echoed the address the user typed, and proved nothing about its
        // length.
        _refuseOnIssues(RowValidator.validate(Tables.users, userRow));
        await txn.insert(Tables.users, userRow);
      }

      // Preserve any address the local rows were previously attributed under,
      // so Phase 6/7's prior-email matching can still recognise this person
      // from a backup written before the change (same contract as
      // `ProfileEditor`).
      await _recordPriorEmails(
        txn,
        localIds: localIds,
        serverUserId: serverUserId,
        newEmail: normalized,
        deviceId: deviceId,
        now: now,
      );

      final rewritten = await _rewriteUserColumns(
        txn,
        from: localIds,
        to: serverUserId,
        now: now,
      );

      // Capture, then delete — in that order, and inside the same transaction,
      // so there is no window in which the row is gone and unrecorded.
      final captured = await _captureSupersededUsers(
        txn,
        localIds: localIds,
        serverUserId: serverUserId,
        now: now,
      );

      // Last, once nothing references them any more.
      await _deleteOldUserRows(txn, localIds);

      return IdentityAdoptionReport(
        serverUserId: serverUserId,
        remappedFrom: localIds,
        heldBack: resolved.heldBack,
        rowsRewritten: rewritten,
        createdServerUserRow: createdServerUserRow,
        supersededRowsCaptured: captured,
      );
    });
    // Adoption rewrites `user_id` across every table — including the bearings
    // the log names an author for, and the `Users` rows it reads those names
    // from — and then hard-deletes the superseded `Users` rows. It runs during
    // sign-in, while the log and map may already be built. Task 11.45: this is
    // the sixth inbound path, in a file the hand-written list never named.
    if (report.rowsRewritten > 0 ||
        report.remappedFrom.isNotEmpty ||
        report.createdServerUserRow) {
      DataArrival.announce();
    }
    return report;
  }

  /// Refuses when the server names an id this device already holds for
  /// **someone else**.
  ///
  /// `completeSignIn`'s email check bounds which local rows adoption can
  /// *read from*; it says nothing about the id adopted *into*. A hostile or
  /// confused server can answer a legitimate redemption of `sam@example.com`
  /// with a colleague's `user_id`, and the rewrite below would then attribute
  /// Sam's observations to a `Users` row that says Alex — silently, with a
  /// bumped revision that beats Alex's own copy on the next sync. Nothing
  /// downstream would notice: the row exists, the foreign keys hold, and the
  /// name on the profile screen is simply the wrong one.
  ///
  /// Three ways an existing row is legitimately the same person, and no
  /// fourth: it carries the signed-in address, it carries a Phase 7
  /// placeholder (so it names nobody yet), or `User_Emails` already records
  /// the signed-in address as one of its prior addresses. Anything else is a
  /// refusal rather than a guess — the same call `_resolveLocalUserIds` makes
  /// about ambiguous prior addresses, for the same reason.
  Future<void> _refuseIfAnotherPerson(
    DatabaseExecutor txn, {
    required Map<String, Object?> existingRow,
    required String serverUserId,
    required String email,
  }) async {
    final existingEmail = normalizeEmail(
      (existingRow['email'] as String?) ?? '',
    );
    if (existingEmail.isEmpty ||
        existingEmail == email ||
        isPlaceholderEmail(existingEmail)) {
      return;
    }
    final prior = await txn.query(
      Tables.userEmails,
      where: 'user_id = ? AND email = ? AND deleted_at IS NULL',
      whereArgs: [serverUserId, email],
      limit: 1,
    );
    if (prior.isNotEmpty) return;

    throw const IdentityAdoptionRefused(
      'The server named an account this device already holds for a different '
      'person. Nothing on this device was changed.',
    );
  }

  /// Turns [RowValidator] output into a refusal.
  ///
  /// The issue text is deliberately kept out of [IdentityAdoptionRefused] —
  /// it embeds the offending value, which is server-chosen — but it is worth
  /// having in the exception's own `toString` for a debug build, so the
  /// message names the field and not the content.
  void _refuseOnIssues(List<RowIssue> issues) {
    if (issues.isEmpty) return;
    final fields = {for (final issue in issues) issue.field}.join(', ');
    throw IdentityAdoptionRefused(
      'The server answered with account details this device cannot store '
      '($fields).',
    );
  }

  /// Preserves each superseded `Users` row in `Sync_Conflicts` before it is
  /// hard-deleted.
  ///
  /// **This is §4.19 clause 4's recoverability half, on the one overwrite in
  /// the app that had neither half.** The delete below is defensible (see
  /// [_deleteOldUserRows]) and stays; what was not defensible is that the
  /// row's `first_name`, `last_name`, `created_at` and `origin_device_id`
  /// existed on exactly one device in the world and then did not, with no
  /// record anywhere that they ever had. A tombstone is the wrong instrument —
  /// it would sync the false claim "this user was deleted" — and
  /// `Sync_Conflicts` is the right one, because it is local-only, is already
  /// where every other superseded-by-a-remote-write row goes (task 10.12),
  /// and is already rendered by the sync status screen.
  ///
  /// **On `project_id`.** `Users` is globally keyed and has no project column,
  /// so there is no honest single answer; the existing precedent
  /// (`SyncEngine._recordConflicts`, `ProjectMerger`) attributes a global row
  /// to whichever project the round happened to be for. Adoption has no round.
  /// One row per project is written instead, because the alternative that
  /// looks tidier — a sentinel project id — produces a record no screen can
  /// ever show, and a record nobody can read is the same as no record, which
  /// is the defect being fixed. The sentinel is used only when the device
  /// holds no projects at all, where there is no screen either way.
  Future<int> _captureSupersededUsers(
    DatabaseExecutor txn, {
    required Set<String> localIds,
    required String serverUserId,
    required DateTime now,
  }) async {
    if (localIds.isEmpty) return 0;
    await SyncConflictStore.ensureTable(txn);
    final store = SyncConflictStore(txn);

    final adopted = (await txn.query(
      Tables.users,
      where: 'user_id = ?',
      whereArgs: [serverUserId],
      limit: 1,
    )).firstOrNull;

    final projectRows = await txn.query(
      Tables.projects,
      columns: ['project_id'],
    );
    final projectIds = <String>{
      for (final row in projectRows)
        if (row['project_id'] case final String id) id,
    };
    if (projectIds.isEmpty) projectIds.add(noProjectScope);

    var written = 0;
    for (final localId in localIds) {
      final rows = await txn.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [localId],
        limit: 1,
      );
      final superseded = rows.firstOrNull;
      if (superseded == null) continue;
      for (final projectId in projectIds) {
        await store.record(
          projectId: projectId,
          tableName: Tables.users,
          rowKey: localId,
          localSnapshot: Map<String, Object?>.from(superseded),
          incomingSnapshot: adopted == null
              ? null
              : Map<String, Object?>.from(adopted),
          detectedAtUtc: now,
        );
        written++;
      }
    }
    return written;
  }

  /// `Sync_Conflicts.project_id` for a globally-keyed row on a device that
  /// holds no projects. Not a real project id and deliberately not shaped like
  /// one, so it cannot collide with one.
  static const String noProjectScope = '(no project)';

  /// Mirrors `ProjectMerger._asTransaction` so this composes the same way.
  Future<T> _asTransaction<T>(Future<T> Function(DatabaseExecutor txn) action) {
    final database = db;
    if (database is Database) {
      return database.transaction((txn) => action(txn));
    }
    return action(database);
  }

  /// Which local user ids represent the person who just signed in.
  ///
  /// Three rules, mirroring the anchors the app already uses elsewhere rather
  /// than inventing new ones:
  ///
  /// - **Any local user whose current email equals the signed-in address —
  ///   unless more than one does.** That is the identity anchor Phase 6/7
  ///   established. More than one local row *can* legitimately carry one
  ///   address (a merge can leave a duplicate of the same person), and more
  ///   than one can also be **two different people sharing an institutional
  ///   mailbox on a shared field device**, which is finding K-4's honest-path
  ///   variant and needs no attacker at all. Nothing in the data distinguishes
  ///   them: same address, plausibly different names, and names are not an
  ///   identity anchor anywhere else in this app.
  ///
  ///   The old rule folded *all* of them in — so `lab@nau.edu` signing in
  ///   reattributed both people's observations to one id and hard-deleted one
  ///   of the two profiles. The rule now is the same one the prior-address
  ///   branch below has always applied: **ambiguous means do not guess.** Only
  ///   the active user is adopted when several match, because the person
  ///   sitting in front of the device is the one whose profile is selected;
  ///   the rest are reported in [IdentityAdoptionReport.heldBack] and left
  ///   completely untouched, rows and `Users` row alike. If the active user is
  ///   not among the matches, none of them is adopted by this anchor.
  ///
  ///   The cost is named rather than hidden: a genuine same-person duplicate
  ///   is no longer folded automatically, and the user keeps two profiles
  ///   until something merges them. That is recoverable. Fusing two people and
  ///   deleting one is not.
  /// - **A local user with the signed-in address in `User_Emails`.** Phase 7
  ///   records every address a user has ever used precisely so a changed email
  ///   doesn't fracture their identity, and Phase 6's merge already matches on
  ///   it (its "tier 2a"). Someone who changed their address and signs in with
  ///   the older one would otherwise get a duplicate identity on a device that
  ///   already knows the two are the same person. Ambiguous addresses — claimed
  ///   as a prior by two different local users, e.g. a reassigned institutional
  ///   mailbox — are **excluded**, the same exclusion `ProjectMerger` makes,
  ///   because guessing there would fuse two people.
  /// - **The active user, if it still has a Phase 7 placeholder address.** A
  ///   device whose owner never completed identity capture has an
  ///   auto-generated `…@local.tritrack` address; the person signing in is
  ///   unambiguously that user, because nobody else has ever used this device.
  ///
  /// **What is deliberately *not* adopted: a user with a real, different email
  /// and no recorded link to the signed-in one.** Signing in as `sam@gmail.com`
  /// on a device whose local identity is `alex@nau.edu` does not reassign
  /// Alex's observations to Sam. The plan says sign-in should "merge into the
  /// existing local user … Phase 7's first-run local user is the same person" —
  /// and that reasoning holds exactly when an anchor matches or was never set.
  /// When none does, the premise fails, and silently rewriting the authorship
  /// of another person's field records is the provenance violation Phase 8 and
  /// 11.7 exist to prevent. Those records keep their author; the signed-in
  /// identity gets its own row.
  Future<_ResolvedLocalIds> _resolveLocalUserIds(
    DatabaseExecutor txn, {
    required String email,
    required String? activeUserId,
  }) async {
    final ids = <String>{};
    final heldBack = <String>{};

    final byCurrentEmail = <String>{};
    for (final row in await txn.query(Tables.users)) {
      final rowEmail = normalizeEmail((row['email'] as String?) ?? '');
      if (rowEmail.isNotEmpty && rowEmail == email) {
        byCurrentEmail.add(row['user_id'] as String);
      }
    }
    if (byCurrentEmail.length <= 1) {
      ids.addAll(byCurrentEmail);
    } else {
      // Several local people claim this address. Adopt at most the active one;
      // hold the rest back untouched. See this method's doc comment.
      for (final id in byCurrentEmail) {
        if (id == activeUserId) {
          ids.add(id);
        } else {
          heldBack.add(id);
        }
      }
    }

    // Prior-email match, excluding addresses more than one local user claims.
    String? priorMatch;
    var priorAmbiguous = false;
    for (final row in await txn.query(Tables.userEmails)) {
      if (row['deleted_at'] != null) continue;
      if (normalizeEmail((row['email'] as String?) ?? '') != email) continue;
      final userId = row['user_id'] as String;
      if (priorMatch == null) {
        priorMatch = userId;
      } else if (priorMatch != userId) {
        priorAmbiguous = true;
      }
    }
    // A user held back as ambiguous above is not let back in through a second
    // anchor: the reason for holding them back is that this device cannot tell
    // which person they are, and a prior-address record does not answer that.
    if (priorMatch != null &&
        !priorAmbiguous &&
        !heldBack.contains(priorMatch)) {
      ids.add(priorMatch);
    }

    if (activeUserId != null && !ids.contains(activeUserId)) {
      final active = await txn.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [activeUserId],
        limit: 1,
      );
      final activeEmail = normalizeEmail(
        (active.firstOrNull?['email'] as String?) ?? '',
      );
      if (activeEmail.isNotEmpty && isPlaceholderEmail(activeEmail)) {
        ids.add(activeUserId);
      }
    }

    return (adopt: ids, heldBack: heldBack..removeAll(ids));
  }

  /// Records each distinct prior address in `User_Emails` so cross-device
  /// dedup can still match a backup written before this sign-in.
  Future<void> _recordPriorEmails(
    DatabaseExecutor txn, {
    required Set<String> localIds,
    required String serverUserId,
    required String newEmail,
    required String deviceId,
    required DateTime now,
  }) async {
    for (final localId in localIds) {
      final rows = await txn.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: [localId],
        limit: 1,
      );
      final priorEmail = normalizeEmail(
        (rows.firstOrNull?['email'] as String?) ?? '',
      );
      // A placeholder address was never a real mailbox and identifies nobody,
      // so recording it would only add noise to future matching.
      if (priorEmail.isEmpty ||
          priorEmail == newEmail ||
          isPlaceholderEmail(priorEmail)) {
        continue;
      }
      final existing = await txn.query(
        Tables.userEmails,
        where: 'user_id = ? AND email = ?',
        whereArgs: [serverUserId, priorEmail],
        limit: 1,
      );
      if (existing.isNotEmpty) continue;
      final stamp = DbCodec.encodeUtc(now);
      final emailRow = <String, Object?>{
        'user_email_id': '$serverUserId::$priorEmail',
        'user_id': serverUserId,
        'email': priorEmail,
        'recorded_at': stamp,
        'created_at': stamp,
        'updated_at': stamp,
        'deleted_at': null,
        'revision': 0,
        'last_modified_by': serverUserId,
        'origin_device_id': deviceId,
      };
      // Validated for a reason the id check alone does not cover: this primary
      // key is *composed* from the server's id and an address, so a server id
      // that is individually within bounds can still produce a key that is
      // not. A derived key needs its own check, not its parts'.
      _refuseOnIssues(RowValidator.validate(Tables.userEmails, emailRow));
      await txn.insert(Tables.userEmails, emailRow);
    }
  }

  /// Rewrites every user-referencing column from any id in [from] to [to],
  /// bumping the sync clock on each row it changes.
  ///
  /// Driven off `syncTables`' `userColumns`, so a table that gains a user
  /// column is covered automatically. `Users.user_id` is skipped here because
  /// it is a primary key — that row is replaced, not updated, by the
  /// insert/delete pair around this call. Ordering matters and is fixed by the
  /// caller: the new parent row exists before any child is pointed at it, and
  /// the old parent is deleted only after nothing references it, because the
  /// app forces `PRAGMA foreign_keys = ON` on every connection.
  ///
  /// **`revision` and `updated_at` ARE bumped, and an earlier version of this
  /// code was wrong not to.** The tempting argument for leaving them alone is
  /// that adoption runs during sign-in, which precedes this device's first
  /// push, so the rewritten ids get pushed anyway and bumping only inflates
  /// the clock. That argument holds for a *first* sign-in and fails for every
  /// later one. Concretely: sign in, sync 500 observations, change your
  /// address in the profile screen, sign in again with the new address. The
  /// server has no account for it, mints a fresh `user_id`, and this method
  /// rewrites 500 rows the server already holds. Without a bump those rewrites
  /// lose last-write-wins against the server's copies — equal `revision`,
  /// equal `updated_at` — so the next pull silently reverts the attribution
  /// and nobody is told. That is a silent integrity failure, which §1.2 of the
  /// security model ranks above account access precisely because nobody goes
  /// looking for it.
  ///
  /// Bumping is not the "identity churn" the "One user, many devices" analysis
  /// forbids. That churn is two devices rewriting each other's ids **every
  /// sync round, forever**, which is prevented by the server being
  /// authoritative and by this operation being idempotent — a second adoption
  /// finds nothing to rewrite and bumps nothing. A one-time bump per genuine
  /// identity change is just an edit propagating, which is what the sync clock
  /// is for.
  Future<int> _rewriteUserColumns(
    DatabaseExecutor txn, {
    required Set<String> from,
    required String to,
    required DateTime now,
  }) async {
    if (from.isEmpty) return 0;
    final placeholders = List.filled(from.length, '?').join(', ');
    final oldIds = from.toList();
    final stamp = DbCodec.encodeUtc(now);
    var rewritten = 0;

    for (final table in syncTables) {
      final columns = table.userColumns
          .where((c) => !(table.name == Tables.users && c == 'user_id'))
          .toList();
      if (columns.isEmpty) continue;

      // One statement per table, not per column. A row with two user columns
      // (`Observations` has `user_id` and `last_modified_by`) would otherwise
      // be updated twice and have its `revision` bumped twice — harmless for
      // last-write-wins, which only needs "higher", but it makes the clock
      // depend on how many user columns a table happens to declare, which is
      // not a property anything should encode. `CASE` rewrites only the
      // columns that actually match, leaving the rest alone.
      final assignments = [
        for (final column in columns)
          '$column = CASE WHEN $column IN ($placeholders) THEN ? ELSE $column END',
        'revision = revision + 1',
        'updated_at = ?',
      ].join(', ');
      final predicate = columns
          .map((c) => '$c IN ($placeholders)')
          .join(' OR ');

      rewritten += await txn.rawUpdate(
        'UPDATE ${table.name} SET $assignments WHERE $predicate',
        [
          for (final _ in columns) ...[...oldIds, to],
          stamp,
          for (final _ in columns) ...oldIds,
        ],
      );
    }
    return rewritten;
  }

  /// Removes the superseded `Users` rows.
  ///
  /// **A hard delete, which is the documented exception to the schema's
  /// no-hard-deletes rule.** That rule exists because a hard delete on one
  /// device resurrects on the next merge; it assumes the row is being removed
  /// from the world. This row isn't — the same person continues to exist under
  /// the authoritative id, and every reference to the old id has just been
  /// repointed. A tombstone would instead sync the claim "this user was
  /// deleted", which is false and would propagate as a confusing ghost user to
  /// every peer.
  ///
  /// **Finding K-4 did not dispute that and neither does this comment.** What
  /// it disputed is that the argument for *not tombstoning* had been read as
  /// an argument for *not recording*, and those are different claims: the
  /// first is about what to tell other devices, the second about what to keep
  /// on this one. [_captureSupersededUsers] runs immediately before this and
  /// answers the second. The rows this touches are also no longer chosen by
  /// "every local row with that address" — see [_resolveLocalUserIds] — so the
  /// set being deleted is one this device has an actual basis for believing is
  /// the same person.
  Future<void> _deleteOldUserRows(
    DatabaseExecutor txn,
    Set<String> localIds,
  ) async {
    for (final id in localIds) {
      await txn.delete(Tables.users, where: 'user_id = ?', whereArgs: [id]);
    }
  }
}

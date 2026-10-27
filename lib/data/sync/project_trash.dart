import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../db/data_arrival.dart';
import '../repositories/mutation_authorization.dart';
import '../repositories/project_membership_repository.dart';
import '../repositories/project_repository.dart';
import 'sync_conflicts.dart';
import 'sync_dropped_rows.dart';
import 'sync_held_rows.dart';
import 'sync_row_receipts.dart';
import 'unknown_columns.dart';

/// A project this person moved to the Trash on this phone, which this phone
/// does not sync (task 11.339, item 1).
class TrashedHere {
  const TrashedHere({
    required this.projectId,
    required this.projectName,
    required this.deletedAt,
    required this.everOnServer,
  });

  final String projectId;
  final String projectName;

  /// When it was moved to the Trash, by this phone's clock; null only for a
  /// stored value that does not parse.
  final DateTime? deletedAt;

  /// Whether any row of it was ever confirmed by a server — the same
  /// `SyncRowReceiptStore` answer `strandedRecordCount` gives as `everSynced`.
  /// False for a project that was never published, which is the case the
  /// Trash row and the permanent-delete dialog say "only on this phone" for.
  /// True for one this phone used to sync and has stopped (it left, or the
  /// server destroyed the project): its row and dialog speak about this
  /// phone's copy instead, because a server may hold one too.
  final bool everOnServer;
}

/// Thrown by [ProjectTrash.deletePermanently] when the project is not one of
/// [ProjectTrash.onThisDevice]'s — nothing has been changed.
class NotInThisPhonesTrash implements Exception {
  const NotInThisPhonesTrash(this.message);
  final String message;
  @override
  String toString() => message;
}

/// **The Trash for projects that live only on this phone** (task 11.339).
///
/// Michael, 2026-10-08: the Trash lists every project moved there from this
/// phone, published or not. Before this, the Projects screen's Trash listed
/// only what a server still held, so a never-published project moved to the
/// Trash was hidden after the six-second UNDO and could not be got back.
///
/// Three operations, and what each does to the project's records on this
/// phone:
///
/// - **Moving to the Trash** is the ordinary soft delete
///   (`ProjectRepository.softDeleteById`): the project row is marked, and
///   every record in it — bearings, animals, collars, estimates — stays on the
///   phone untouched, hidden with it. Not done here.
/// - **[restore]** clears the mark. Every record reappears as it was.
/// - **[deletePermanently]** removes the project and every row scoped to it
///   from this phone's database. It is the one deliberate exception to "no
///   hard deletes" for project data, and the reason that rule exists — a hard
///   delete resurrects on the next merge — does not reach it: the project is
///   not synced by this phone, so there is no merge for it to resurrect in.
///   A copy exported or shared as a file is not touched, and importing it
///   brings the project back, which is the honest outcome.
///
/// **Who and what** ([onThisDevice]'s rule, enforced again inside
/// [deletePermanently] so a stale screen cannot widen it): a project row
/// whose tombstone this person wrote (`last_modified_by`), which this phone
/// does not sync (not linked). A linked project's Trash row is the server's,
/// or is waiting to be sent, and is handled by the server's own path.
abstract final class ProjectTrash {
  /// Every project this person moved to the Trash that this phone does not
  /// sync, by name. [isLinked] is `SyncStateStore.isProjectLinked`.
  static Future<List<TrashedHere>> onThisDevice(
    DatabaseExecutor db, {
    required String userId,
    required Future<bool> Function(String projectId) isLinked,
  }) async {
    final rows = await db.query(
      Tables.projects,
      columns: const ['project_id', 'project_name', 'deleted_at'],
      where: 'deleted_at IS NOT NULL AND last_modified_by = ?',
      whereArgs: [userId],
      orderBy: 'project_name',
    );
    if (rows.isEmpty) return const [];
    await SyncRowReceiptStore.ensureTable(db);
    final receipts = SyncRowReceiptStore(db);
    final out = <TrashedHere>[];
    for (final row in rows) {
      final projectId = row['project_id'] as String;
      if (await isLinked(projectId)) continue;
      out.add(
        TrashedHere(
          projectId: projectId,
          projectName: row['project_name'] as String? ?? '',
          deletedAt: DateTime.tryParse(row['deleted_at'] as String? ?? ''),
          everOnServer: await receipts.count(projectId) > 0,
        ),
      );
    }
    return out;
  }

  /// Brings [projectId] back, with every record. The same write the six-
  /// second UNDO makes, under the same rule: an owner restores as an owner;
  /// somebody who left, or who holds a read-only copy, restores under the
  /// exemption that let them move it to the Trash. The repository re-derives
  /// the exemption from this phone's rows, so naming one here grants nothing
  /// the rows do not.
  static Future<int> restore(
    DatabaseExecutor db,
    String projectId, {
    required String userId,
    String? deviceId,
  }) async {
    final memberships = ProjectMembershipRepository(db);
    final owners = await memberships.ownersOf(projectId);
    final MutationExemption? exemption;
    if (owners.contains(userId)) {
      exemption = null;
    } else if (await memberships.hasDeparted(projectId, userId)) {
      exemption = MutationExemption.departedMember(projectId);
    } else if ((await memberships.projectStandingFor(
      projectId,
      userId,
    )).isSnapshot) {
      exemption = MutationExemption.snapshotHolder(projectId);
    } else {
      exemption = null;
    }
    final restored = await ProjectRepository(db).restoreById(
      projectId,
      actor: MutationActor.user(userId),
      deviceId: deviceId,
      exemption: exemption,
    );
    // Every record in the project is visible again (task 11.45's reason).
    if (restored > 0) DataArrival.announce();
    return restored;
  }

  /// This phone's own bookkeeping about a project's rows. Each table is
  /// created lazily by its store, so one that was never made is skipped.
  static const _localTables = [
    SyncRowReceiptStore.table,
    SyncHeldRowStore.table,
    SyncConflictStore.table,
    SyncDroppedRowStore.table,
    UnknownColumnStore.table,
    UnknownColumnStore.quarantineTable,
  ];

  /// Removes [projectId] and every row scoped to it from this phone, in one
  /// transaction. Returns how many rows went.
  ///
  /// Throws [NotInThisPhonesTrash], having changed nothing, unless the
  /// project is in [onThisDevice]'s list for [userId]: moved to the Trash,
  /// by them, and not synced by this phone ([isLinked] false).
  ///
  /// Children before parents — the reverse of `syncTables`, which is the
  /// merger's parents-first order — so every `DELETE` runs while its own
  /// foreign keys still resolve. The person's Tag Library is not project data
  /// and is not touched; nor is any other project, since every statement is
  /// `WHERE project_id = ?`.
  static Future<int> deletePermanently(
    Database db,
    String projectId, {
    required String userId,
    required bool isLinked,
  }) async {
    if (isLinked) {
      throw const NotInThisPhonesTrash(
        'This project is still synced by this phone, so it can only be '
        'deleted through the server.',
      );
    }
    final removed = await db.transaction((txn) async {
      final rows = await txn.query(
        Tables.projects,
        columns: const ['deleted_at', 'last_modified_by'],
        where: 'project_id = ?',
        whereArgs: [projectId],
        limit: 1,
      );
      if (rows.isEmpty ||
          rows.single['deleted_at'] == null ||
          rows.single['last_modified_by'] != userId) {
        throw const NotInThisPhonesTrash(
          'This project is not in your Trash on this phone, so nothing was '
          'deleted.',
        );
      }
      var count = 0;
      for (final table in syncTables.reversed) {
        final column = table.projectScopeColumn;
        if (column == null) continue;
        count += await txn.delete(
          table.name,
          where: '$column = ?',
          whereArgs: [projectId],
        );
      }
      for (final table in _localTables) {
        final exists = await txn.query(
          'sqlite_master',
          columns: const ['name'],
          where: 'type = ? AND name = ?',
          whereArgs: ['table', table],
          limit: 1,
        );
        if (exists.isEmpty) continue;
        await txn.delete(
          table,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
      }
      return count;
    });
    // After the commit, once for the whole project (task 11.45's reason): a
    // screen still holding one of its records must stop showing it.
    DataArrival.announce();
    return removed;
  }
}

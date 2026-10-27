import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'sync_engine.dart';
import 'sync_state_store.dart';

/// **A change to a project's own row that no ordinary sync round can carry**
/// (task 11.289).
///
/// ## The trap this exists to open
///
/// A sync round is scoped to the **active** project: `SyncController._run`
/// begins `if (projectId == null) return;` and `syncIfDue`/`syncNow` never look
/// at any other. That scope was chosen and is load-bearing — the status a
/// person reads (pending, held, last synced) is about the project they have
/// open, and a round costs a push and a pull over whatever network the phone
/// has. Every row in this app is safe under it, because every row belongs to a
/// project that stays selected while you edit it.
///
/// **Except the project's own row.** It is the one row that changes while the
/// project is *not* the open one:
///
/// - **Deleting it.** `ProjectsScreen._deleteProject` sets the active project
///   to null when the deleted project was the open one, and a deleted project
///   is hidden from the list, so it can never be selected again. The tombstone
///   sits on a linked project with nothing that will ever run a round for it.
///   Selecting another project does not help — that round pushes *that*
///   project's rows. **Measured by Michael on 2026-09-20**: a published project
///   deleted on the phone, a different project selected and synced, and the
///   server's `deleted_at` still empty. His server held nine live projects and
///   zero tombstones after a month.
/// - **Undoing that delete** from the snackbar, when the tombstone has already
///   gone: the restored row is pending on a project that is no longer open.
/// - **Editing it from the Projects list** — `projectByIdProvider` exists so
///   the list can edit a project that is not the active one.
///
/// This is the same shape task 11.57 met for a **departure**: a closed
/// membership row on a project that is, by definition, no longer the one you
/// have open. `pending_departure.dart` is the sibling and this follows it —
/// find the stranded row from the data, run a round for that project from the
/// app's lifecycle hooks, and leave the row pending until the server confirms
/// it. A push made at delete time would fail exactly the case this app exists
/// for, somebody deleting a project at a trailhead with no signal, and would
/// look handled while doing so.
///
/// ## Derived from the push's own predicate, not from a copy of it
///
/// Which `Projects` rows a device may offer at all is `offer_rules.dart`'s
/// question, and the answer has changed once already (task 11.57's ownership
/// waiver). So this file does not decide it. It asks [SyncEngine.wouldOffer] —
/// *would the next push for this project offer this row?* — which is the
/// selection the push itself runs, held-row suppression and snapshot gate
/// included. A departed member's local delete of somebody else's project
/// (task 11.54) and a snapshot holder's (task 11.238) both come back false
/// there, for the reason `offer_rules.dart` states, without this file naming
/// either case.
///
/// ## What it costs
///
/// One `Projects` scan and, per **linked** project, one `SharedPreferences`
/// read and one indexed SQLite probe. Nothing reaches the network unless a
/// row is actually stranded, and then one round for that project only, until
/// the server confirms it. The per-project scope of ordinary sync is
/// untouched: this does not sync every project, it delivers one table's rows
/// for the projects that have no other way to deliver them.
class PendingProjectChange {
  const PendingProjectChange({
    required this.projectId,
    required this.isDeletion,
  });

  final String projectId;

  /// Whether the pending version of the row is a tombstone. Reported for the
  /// caller's account of what it delivered; the delivery is the same either
  /// way.
  final bool isDeletion;
}

/// Every change to a project's own row, on a project this device is linked to,
/// that the next push for that project would offer — for every project other
/// than [excludingProjectId].
///
/// [excludingProjectId] is the **active** project, whose own round owns its
/// row: a rename of the open project is pending like any other edit and goes
/// out on the next ordinary round, and running a second engine round for the
/// same project from here would put two rounds on one project. Pass null to
/// ask about every project, which is what a test does.
///
/// Reads deleted rows deliberately — the tombstone is the case this exists
/// for. A project that was never published has no link and is skipped: the
/// server has never heard of it, so there is nothing there to change.
Future<List<PendingProjectChange>> findUndeliveredProjectChanges({
  required Database db,
  required SyncStateStore state,
  required String userId,
  String? excludingProjectId,
}) async {
  final rows = await db.query(
    Tables.projects,
    columns: ['project_id', 'deleted_at'],
  );
  if (rows.isEmpty) return const [];

  final table = syncTablesByName[Tables.projects]!;
  final pending = <PendingProjectChange>[];
  for (final row in rows) {
    final projectId = row['project_id'] as String;
    if (projectId == excludingProjectId) continue;
    if (!await state.isProjectLinked(projectId)) continue;
    if (!await SyncEngine.wouldOffer(
      db,
      table: table,
      projectId: projectId,
      userId: userId,
      row: row,
    )) {
      continue;
    }
    pending.add(
      PendingProjectChange(
        projectId: projectId,
        isDeletion: row['deleted_at'] != null,
      ),
    );
  }
  return pending;
}

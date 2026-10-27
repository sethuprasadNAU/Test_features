import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'sync_engine.dart';
import 'sync_held_rows.dart';
import 'sync_state_store.dart';

/// **A project this device holds as deleted, that the server may have
/// brought back** (task 11.302).
///
/// ## The trap this exists to open
///
/// An owner can now restore a project they deleted — the `restore` action
/// on `POST /projects/<id>/deletion`. The server clears the tombstone
/// and every record in the project is live again — **on the server**. Every
/// device that already believed the project gone is still holding the
/// tombstone, and **nothing on those devices would ever ask again**:
///
/// - A sync round runs for the **active** project only, and a project whose
///   own row is tombstoned is hidden from the Projects list, so it can never
///   be selected. This is the same trap `pending_project_change.dart` met for
///   the outbound tombstone, now met by the inbound restore.
/// - The join screen would offer it (a tombstoned local copy counts as "not
///   syncing" there, task 11.57), but only to somebody who goes and looks.
///   **The member who lost the project without being told is the person
///   least likely to**, and least able to tell a restore from a fault.
///
/// So a device finds these projects from its own data, asks the server once
/// whether any of them is live again, and runs one ordinary round for each
/// that is — see `SyncController.bringBackRestoredProjects`.
///
/// ## Which tombstones are this device's to bring back
///
/// Every condition is a way a local tombstone can be *not* the server's news:
///
/// 1. **The project's own row is tombstoned here.** Only the `Projects` row
///    hides a project; nothing else is asked about.
/// 2. **The project is linked** — this device was syncing it. An unlinked
///    copy is one this device was taken off, or never published; the join
///    screen's *Restore* button is the way back for those, deliberately a
///    person's choice (task 11.57).
/// 3. **The next push would not offer that row** ([SyncEngine.wouldOffer]).
///    A tombstone still waiting to go out is this device's own deletion not
///    yet delivered — the Projects Trash's "not sent to the server yet" row
///    owns it, with its own Restore (task 11.289's *"Deleted here, not yet on
///    the server"* section until task 11.339 folded it into the Trash). Bringing it back from here would
///    undo the person's delete behind their back.
/// 4. **The server has not refused that row** (the held-row store). A held
///    tombstone is a deletion the server declined; the server's copy is
///    live because it never took the delete, not because anybody restored
///    it, and the same section says so. *Measured, not assumed:* a round
///    here would not undo the tombstone anyway — the device's revision
///    outranks the server's untouched row — so what this condition buys is
///    not asking: without it the device would query the server and run a
///    round on every foreground for a deletion that section already shows.
///
/// What is left is a tombstone the server itself sent (a member's device), or
/// one it confirmed (the deleting owner's device): **settled**. If the server
/// now lists that project as live on `GET /projects/mine`, its row changed
/// after the tombstone — somebody restored it — and fetching it is right.
///
/// ## Why a round and not a local undelete
///
/// The round pulls the server's own row, which the restore stamped with a
/// higher revision than any tombstone a device holds, so the shared merge
/// rule puts it over the tombstone whatever the device clocks say
/// (`deleted_project_directory_test.dart` asserts that on a real server). A
/// project is reported back only if that row actually landed — decided from
/// the data afterwards, never from the round not throwing. The round pushes
/// first, as every round does, so anything this device recorded in the
/// project and never sent goes up in the same trip.
///
/// ## What it costs
///
/// One `Projects` scan and, per tombstoned project, a `SharedPreferences`
/// read and two indexed SQLite probes. **A device holding no settled
/// tombstone reaches no server at all.** A device that deleted a project and
/// still holds its tombstone asks `/projects/mine` once per foreground — one
/// small read, in the bucket the Projects list already uses — until the
/// project is restored or destroyed (destruction unlinks it, which ends the
/// asking).
Future<List<String>> findSettledProjectTombstones({
  required Database db,
  required SyncStateStore state,
  required String userId,
}) async {
  final rows = await db.query(
    Tables.projects,
    columns: ['project_id'],
    where: 'deleted_at IS NOT NULL',
  );
  if (rows.isEmpty) return const [];

  final table = syncTablesByName[Tables.projects]!;
  await SyncHeldRowStore.ensureTable(db);
  final held = SyncHeldRowStore(db);
  final settled = <String>[];
  for (final row in rows) {
    final projectId = row['project_id'] as String;
    if (!await state.isProjectLinked(projectId)) continue;
    if (await SyncEngine.wouldOffer(
      db,
      table: table,
      projectId: projectId,
      userId: userId,
      row: row,
    )) {
      continue;
    }
    final refused = (await held.held(projectId)).any(
      (h) => h.tableName == Tables.projects && h.rowKey == projectId,
    );
    if (refused) continue;
    settled.add(projectId);
  }
  return settled;
}

/// One project that came back onto this device because somebody restored it
/// on the server.
class RestoredProjectArrival {
  const RestoredProjectArrival({
    required this.projectId,
    required this.projectName,
    required this.restoredBy,
    this.restoredByName,
  });

  final String projectId;
  final String projectName;

  /// The restored row's `last_modified_by` — the owner who restored it, which
  /// the server stamps (§4.17) and which is always the owner who deleted it
  /// (§4.28.1). Compared with the signed-in account to decide whether the
  /// person reading needs telling at all.
  final String? restoredBy;

  /// The restoring person's name as this device holds it on their `Users`
  /// row, or null when it holds none — never a guess.
  final String? restoredByName;
}

/// **The moment a deleted project comes back onto this device, announced
/// from the one place every route passes through** (task 11.302, from
/// Michael's device look on 2026-09-24).
///
/// ## Why this is not in `SyncController.bringBackRestoredProjects`
///
/// It was, and the device look found the hole on the first try. A restored
/// project reaches a phone by **three** routes, not one: the foreground check
/// that fetches settled tombstones; *Sync now* and the Projects list's
/// pull-to-refresh, which run that check and throw its answer away; and the
/// ordinary round for the **open** project — because a tombstone arriving by
/// sync hides a project but does not close it, so a member who had it open
/// keeps syncing it and the restore simply lands. Michael's Mac had
/// TestProject07 open; it came back with its bearing and no word said.
///
/// So the announcement moved to where the data changes:
/// `ProjectMerger.merge` reports every `Projects` row that a **server** page
/// took from tombstoned to live, after the write commits, and whoever is
/// listening decides what to say. Same shape as [DataArrival] and for the
/// same reason (task 11.45): the caller that forgets is the one nobody
/// listed. A plain callback list, so `lib/data` depends on neither Flutter nor
/// Riverpod.
///
/// **Only a server page is announced.** An archive the person restored from a
/// file is their own act, and a join-screen *Restore* clears the local
/// tombstone before its round, so neither reaches this.
abstract final class ProjectRestoration {
  static final List<void Function(List<RestoredProjectArrival>)> _listeners =
      [];

  static void addListener(
    void Function(List<RestoredProjectArrival>) listener,
  ) => _listeners.add(listener);

  static void removeListener(
    void Function(List<RestoredProjectArrival>) listener,
  ) => _listeners.remove(listener);

  /// Says these projects just came back. Iterates a copy, so a listener that
  /// removes itself mid-call cannot corrupt the walk.
  static void announce(List<RestoredProjectArrival> arrivals) {
    if (arrivals.isEmpty) return;
    for (final listener in List.of(_listeners)) {
      listener(arrivals);
    }
  }

  static int get listenerCount => _listeners.length;
}

/// One project this device lost because somebody deleted it on the server —
/// the symmetric case to [RestoredProjectArrival] (task 11.313, from task
/// 11.302's Discovered Scope: *"a member's project disappears without a word
/// when its owner deletes it"*).
class ProjectDeletionArrival {
  const ProjectDeletionArrival({
    required this.projectId,
    required this.projectName,
    required this.deletedBy,
    this.deletedByName,
  });

  final String projectId;
  final String projectName;

  /// The tombstoned row's `last_modified_by` — the owner who deleted it,
  /// which the server stamps (§4.17). Compared with the signed-in account to
  /// decide whether the person reading needs telling at all.
  final String? deletedBy;

  /// The deleting person's name as this device holds it on their `Users`
  /// row, or null when it holds none — never a guess.
  final String? deletedByName;
}

/// **The moment a project this device is on vanishes because somebody
/// deleted it, announced from the same place the restore is** (task 11.313).
///
/// Symmetric to [ProjectRestoration] in every way that matters: the same
/// three routes can carry the news (the foreground check that pulls
/// `/projects/mine`, *Sync now* / pull-to-refresh, and the ordinary round for
/// whichever project is open — which does not stop being open just because
/// its own row is now hidden, see `findSettledProjectTombstones`'s doc), so
/// the announcement lives in `ProjectMerger.merge`, after the same commit,
/// rather than in each caller.
///
/// **What this device's own unsent records do next is not this class's
/// business, because nothing about it changes.** A tombstoned project stays
/// linked, and neither the client's push selection (`SyncEngine._pendingClause`)
/// nor the server's row authorization reads a project's own `deleted_at`
/// before accepting a write scoped to it — only `offersNothingFor`'s snapshot
/// gate does, and a genuine member is never a snapshot holder. So a bearing
/// recorded before the tombstone arrived, and not yet sent, still goes up on
/// the next round precisely as it would have; the sentence a listener builds
/// from this may say so, but nothing here needs to count anything to make
/// that true.
abstract final class ProjectDeletionAnnouncement {
  static final List<void Function(List<ProjectDeletionArrival>)> _listeners =
      [];

  static void addListener(
    void Function(List<ProjectDeletionArrival>) listener,
  ) => _listeners.add(listener);

  static void removeListener(
    void Function(List<ProjectDeletionArrival>) listener,
  ) => _listeners.remove(listener);

  /// Says these projects just left. Iterates a copy, so a listener that
  /// removes itself mid-call cannot corrupt the walk.
  static void announce(List<ProjectDeletionArrival> arrivals) {
    if (arrivals.isEmpty) return;
    for (final listener in List.of(_listeners)) {
      listener(arrivals);
    }
  }

  static int get listenerCount => _listeners.length;
}

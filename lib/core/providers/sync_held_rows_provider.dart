import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../data/sync/held_row_details.dart';
import '../../data/sync/sync_held_rows.dart';
import 'app_context_provider.dart';
import 'database_provider.dart';
import 'sync_provider.dart';

part 'sync_held_rows_provider.g.dart';

/// Rows this device is holding for [projectId] because the server refused them
/// (task 10.28 / finding D-3) — the reviewable half of "something did not sync,
/// and here is why."
///
/// Same shape and lifetime as [syncConflictsProvider]: not `keepAlive`, read by
/// the status screen, and invalidated by [SyncController] after every sync round
/// so it cannot go stale while something is watching it.
@riverpod
Future<List<HeldRow>> syncHeldRows(Ref ref, String projectId) async {
  final db = await ref.watch(appDatabaseProvider.future);
  await SyncHeldRowStore.ensureTable(db.raw);
  return SyncHeldRowStore(db.raw).held(projectId);
}

/// The same holds, resolved into which record, which rule, and what to do —
/// what the status screen actually renders (task 11.41).
///
/// A separate provider rather than a change to [syncHeldRows] so the raw rows
/// stay available to anything that only needs to count them, and so the reads
/// this one performs (the record itself, the people it names, the project's
/// tags) happen once per screen build rather than once per tile.
///
/// **The signed-in user is resolved here and not inside the resolver.** Every
/// sentence the screen shows turns on "is this you?", and a resolver that
/// looked the answer up itself could not be handed the no-identity case to
/// test.
@riverpod
Future<List<HeldRowDetail>> syncHeldRowDetails(
  Ref ref,
  String projectId,
) async {
  final db = await ref.watch(appDatabaseProvider.future);
  final held = await ref.watch(syncHeldRowsProvider(projectId).future);
  if (held.isEmpty) return const [];
  // A device with no identity yet cannot be holding a row it pushed, but the
  // read is allowed to fail rather than the screen: a status screen that
  // throws is worse than one that says "nobody yet".
  String? currentUserId;
  try {
    currentUserId = (await ref.watch(currentUserProvider.future)).userId;
  } on Object {
    currentUserId = null;
  }
  return HeldRowDetails.resolve(
    db.raw,
    projectId: projectId,
    currentUserId: currentUserId,
    held: held,
  );
}

/// Puts one held row back within reach of the next push.
///
/// **One step, since task 10.33.** A held row used to be out of reach for two
/// independent reasons — the held record suppressed it, *and* the push
/// watermark had moved past its timestamp — so a retry that lifted only one
/// left the button doing nothing visible. There is no watermark any more: a row
/// is selected unless a receipt says the server already has it, and a refused
/// row never got one. Lifting the suppression is now the whole job.
///
/// The record is *not* deleted. It stays, and stays counted, until the server
/// actually accepts the row: a retry is not a resolution.
///
/// Separate from [heldRowRetry] so the part with rules can be tested without a
/// widget tree.
Future<void> releaseHeldRowForRetry({
  required Database db,
  required String projectId,
  required HeldRow row,
}) async {
  await SyncHeldRowStore.ensureTable(db);
  await SyncHeldRowStore(
    db,
  ).release(projectId: projectId, tableName: row.tableName, rowKey: row.rowKey);
}

/// What the status screen's "Try again" button does.
typedef HeldRowRetry = Future<void> Function(String projectId, HeldRow row);

/// The "Try again" action: [releaseHeldRowForRetry], then sync now.
///
/// Syncs immediately rather than waiting for the schedule because the user has
/// just told the app the situation changed, and the answer to "did it work this
/// time" should arrive while they are still looking at the screen.
///
/// Exposed as a provider rather than a bare function so a widget test can assert
/// that the button is wired to it without putting a real database in the tap
/// path — under `testWidgets`' fake clock, SQLite work started from a tap never
/// completes, so a widget test written the obvious way hangs instead of failing.
/// The action's own rules are covered by [releaseHeldRowForRetry]'s tests.
///
/// ## Every `ref.watch` before the first `await` — task 11.236, same fix as
/// task 11.235's [_ensureOwnerMembership]
///
/// This is [heldRowRetryProvider], **auto-disposing**, read bare by the status
/// screen (`ref.read(heldRowRetryProvider)(...)` — a read with no listener
/// behind it). Riverpod disposes a provider like that a microtask after the
/// read returns; the closure below keeps running through the database write
/// that follows. **It used to `ref.invalidate` and `ref.read` again after that
/// write** — after an `await`, on a `Ref` that may already be dead — and a
/// probe calling it exactly as the screen does threw *"Cannot use the Ref of
/// heldRowRetryProvider after it has been disposed"*, the same exception task
/// 11.235 found on the tag database's + button.
///
/// The database and the sync controller are both resolved here, synchronously,
/// before the closure's first `await`; nothing inside the closure touches
/// `ref` at all. **The explicit `ref.invalidate(syncHeldRowsProvider(...))`
/// this used to do here is gone rather than moved** — [SyncController] is
/// `keepAlive`, so its own `_run` already invalidates
/// `syncHeldRowsProvider(projectId)` whenever a round changes what is held
/// (`report.refused.isNotEmpty || counts.held != current.heldCount`), which
/// [syncNow] below runs into. And it changed nothing a person could see: the
/// release only clears `held_updated_at`, which [syncHeldRows] never reads —
/// `held()`'s query filters on `resolved_at_utc`, not that column — so the
/// tile renders identically with or without this call between the release and
/// the sync round it was standing in front of.
@riverpod
HeldRowRetry heldRowRetry(Ref ref) {
  final dbFuture = ref.watch(appDatabaseProvider.future);
  final controller = ref.watch(syncControllerProvider.notifier);
  return (projectId, row) async {
    final db = await dbFuture;
    await releaseHeldRowForRetry(db: db.raw, projectId: projectId, row: row);
    await controller.syncNow();
  };
}

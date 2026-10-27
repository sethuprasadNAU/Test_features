import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../data/sync/sync_dropped_rows.dart';
import 'database_provider.dart';

part 'sync_dropped_rows_provider.g.dart';

/// Rows this device refused to store when the server sent them (task 11.44)
/// — the inbound mirror of [syncHeldRowsProvider], and the reviewable half of
/// "something did not arrive, and here is why."
///
/// Same shape and lifetime as `syncHeldRowsProvider`: not `keepAlive`, read by
/// the status screen, and invalidated by `SyncController` after every sync
/// round so it cannot go stale while something is watching it.
@riverpod
Future<List<DroppedRow>> syncDroppedRows(Ref ref, String projectId) async {
  final db = await ref.watch(appDatabaseProvider.future);
  await SyncDroppedRowStore.ensureTable(db.raw);
  return SyncDroppedRowStore(db.raw).dropped(projectId);
}

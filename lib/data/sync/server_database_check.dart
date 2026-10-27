import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_held_rows.dart';
import 'sync_row_receipts.dart';
import 'sync_state_store.dart';

/// **Is the server database that just answered the one this project's
/// bookmark and receipts were minted against?** (task 11.58). Adopts it if
/// this project has no record of one; forgets everything that was only true of
/// the old one if it differs, and returns true exactly then.
///
/// One function for the two places that write a project's receipts from a
/// server's answer — `SyncEngine`, and `ProjectPublisher` — because they are
/// two readers of one fact, and a second copy of "what does a replaced
/// database invalidate" is the copy that forgets the holds.
///
/// ## What is forgotten, and why each
///
/// Everything this device holds that is a statement about **one database**,
/// rather than about this device or the project's records:
///
/// - **the pull cursor**, a position in that database's numbering. Kept, it
///   asks a restored database for "everything after 4,812" when its numbering
///   now stops lower, and is told "nothing" —
///   `test/data/sync/stale_cursor_new_server_test.dart` was the reproduction;
/// - **the row receipts** — "that database has this row". Kept, they hold
///   rows off the push, and **unlike the cursor that never heals**: nothing
///   the new database sends prompts a re-offer. Their documented reason for
///   surviving an unlink was that a receipt "does not stop being true"; the
///   reason it held was that the server had not changed;
/// - **the holds** — "that database would not take this row". Kept, they
///   hold rows off the push the same way until somebody taps "Try again".
///   Released, not resolved: see [SyncHeldRowStore.releaseProject].
///
/// **Not forgotten:** the records (nothing here touches a synced table), the
/// overwritten-edit list and the refused-on-arrival list (history of what
/// happened on this device), and the last-success time (a round did connect).
/// A refused-on-arrival record the new database never sends again stays
/// counted — it is still a record this device does not hold.
///
/// ## Order
///
/// **The new identifier is written last.** A round killed part way through
/// the reset finds the old one still stored, meets the difference again, and
/// repeats a reset that is safe to repeat. Written first, a kill would leave
/// the new identifier beside the old bookmark — the exact state this exists to
/// prevent, with nothing left that could notice it.
///
/// ## What it cannot see
///
/// - **A server that does not say** ([reported] null): one built before task
///   11.58. Nothing is concluded and nothing is forgotten.
/// - **A project with no identifier stored** — every linked project on its
///   first round after this build is installed. It adopts whatever answers,
///   because it has nothing to compare with, so a server replaced *before* the
///   device updated is invisible to it. The protection starts at the first
///   round after both the server and the app carry it.
///
/// [noticeAt] is when to record the change for the sync status screen's
/// sentence, or null not to record one — a first publish to a different
/// server is somebody's deliberate act, not news about the server.
Future<bool> resetIfServerDatabaseChanged({
  required Database db,
  required SyncStateStore state,
  required String projectId,
  required String? reported,
  required DateTime? noticeAt,
}) async {
  if (reported == null) return false;
  final known = await state.databaseId(projectId);
  if (known == reported) return false;
  if (known == null) {
    await state.setDatabaseId(projectId, reported);
    return false;
  }
  await state.setCursor(projectId, 0);
  await SyncRowReceiptStore.ensureTable(db);
  await SyncRowReceiptStore(db).forgetProject(projectId);
  await SyncHeldRowStore.ensureTable(db);
  await SyncHeldRowStore(db).releaseProject(projectId);
  if (noticeAt != null) await state.setDatabaseChangedAt(projectId, noticeAt);
  await state.setDatabaseId(projectId, reported);
  return true;
}

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'sync_held_rows.dart';
import 'sync_row_receipts.dart';
import 'sync_state_store.dart';
import 'sync_transport.dart';

/// **A departure this device wrote and the server has never confirmed**
/// (task 11.57, item 4).
///
/// ## The trap this exists to open
///
/// `MembershipController.leaveProject` writes the closed membership row first
/// and only unlinks the project once the server has taken it — which is the
/// right order, because unlinking first would strand the departure with nothing
/// left to push it. But when the server *cannot* be reached, what that leaves
/// behind had, until this file, no way out at all:
///
/// - the project stays **linked**, with the departure row pending;
/// - `SyncController.syncNow` and `syncIfDue` both operate on the **active**
///   project only;
/// - and the person, having left, then deletes their copy — which is exactly
///   what task 11.54 made possible — at which point the project can never be
///   the active one again.
///
/// So the one thing that could deliver the departure was the one thing that
/// could no longer happen. The person is still a member on the server, no
/// invitation can be issued to them (the server is right to refuse one), and
/// **nothing on the device says any of this**. That is the state Michael's
/// iPhone was in on 2026-08-29.
///
/// **This holds whatever caused the delivery to fail**, which is why it is a
/// separate fix from finding out why. Measured on 2026-08-29 against the real
/// server: a departure from a device that *can* reach the server is accepted
/// on the first attempt, membership row and all. The failure this recovers
/// from is therefore an unsent departure, not a refused one — and an unsent
/// one is what a person leaving a project at a trailhead, or on a phone with
/// no signal, produces every time.
///
/// ## Why it is keyed on "this device wrote it"
///
/// A closed membership row can also arrive **from the server**, when an owner
/// removes somebody. That row needs no delivery — it came from the place it
/// would be delivered to — so `last_modified_by` naming the signed-in person is
/// what separates *I left* from *I was removed*. Without that clause this would
/// re-offer somebody else's decision about them on every app launch.
class PendingDeparture {
  const PendingDeparture({
    required this.projectId,
    required this.membershipId,
    required this.updatedAt,
  });

  final String projectId;
  final String membershipId;

  /// The `updated_at` string as stored, which is what a receipt is compared
  /// against — see [departureIsConfirmed] for why the raw column and not a
  /// decoded `DateTime`.
  final String? updatedAt;
}

/// Every departure [userId] wrote on this device that the server has not
/// confirmed.
///
/// Reads three things, in the order that makes the common case free: a closed
/// membership row this person wrote, on a project this device is still linked
/// to, with no row receipt matching the row as it now stands. A device with
/// nothing stuck does one small local query and stops.
///
/// **Deleted projects are deliberately included.** A tombstoned local project
/// is precisely the case that has no other route out, and filtering it here
/// would leave the trap exactly where it was.
Future<List<PendingDeparture>> findUndeliveredDepartures({
  required Database db,
  required SyncStateStore state,
  required String userId,
}) async {
  await SyncRowReceiptStore.ensureTable(db);
  final rows = await db.query(
    Tables.projectMemberships,
    columns: ['membership_id', 'project_id', 'updated_at'],
    where:
        'user_id = ? AND last_modified_by = ? '
        'AND end_date IS NOT NULL AND deleted_at IS NULL',
    whereArgs: [userId, userId],
  );
  if (rows.isEmpty) return const [];

  final receipts = SyncRowReceiptStore(db);
  final table = syncTablesByName[Tables.projectMemberships]!;
  final pending = <PendingDeparture>[];
  for (final row in rows) {
    final projectId = row['project_id'] as String;
    if (!await state.isProjectLinked(projectId)) continue;
    if (await departureIsConfirmed(
      receipts: receipts,
      table: table,
      projectId: projectId,
      storedRow: row,
    )) {
      continue;
    }
    pending.add(
      PendingDeparture(
        projectId: projectId,
        membershipId: row['membership_id'] as String,
        updatedAt: row['updated_at'] as String?,
      ),
    );
  }
  return pending;
}

/// Whether the server has confirmed the departure row as it now stands.
///
/// Compares the receipt's acknowledged `updated_at` against the **raw** stored
/// value rather than merely asking whether a receipt exists: a receipt from
/// before the departure would otherwise read as "the server knows", which is
/// the one wrong answer that matters here. Raw, because a receipt stores the
/// string the sync engine read straight out of SQLite — decoding to a
/// `DateTime` and re-encoding would rest on the codec round-tripping byte for
/// byte, and the cost of it ever not doing so is a departure the server has
/// taken reading as pending forever.
///
/// [storedRow] needs only this table's primary-key columns and `updated_at`.
///
/// Shared with `MembershipController._serverHasDeparture`, which asks the same
/// question the moment somebody leaves; two spellings of one question are two
/// answers waiting to disagree.

/// **Whether a whole-request refusal answered to a self-departure's own push
/// is the outcome the caller wanted** (task 11.301).
///
/// `403 forbidden` on a departure means *the server will not accept this
/// device's rows for this project because it no longer counts this device as
/// a member* — and for a self-departure that is indistinguishable from
/// success: the thing the person asked for (being off the project) is already
/// true. The commonest way to meet it is an owner who removed the person
/// before this device's own closed row ever reached the server (`_push`'s
/// project-level check runs before any row is inspected), but nothing here
/// depends on that being the reason — whatever caused the server to refuse
/// this device's standing on the project, the departure has already been
/// achieved by definition.
///
/// **Narrow on purpose, and not a rule to reuse.** This is true only because
/// a self-departure's entire request is "end my own membership row", so there
/// is no other outcome a `403` could represent. It must never be applied to
/// any other write — a *deletion* refused with `403` means the deletion did
/// not happen and the project is still live for everyone else (task 11.290's
/// refused row, in the Projects Trash since task 11.339), which is the
/// opposite rule for a
/// reason: unlike a departure, a refused deletion leaves something undone
/// that other people are still relying on.
bool departureSettledByRefusal(SyncTransportException error) =>
    error.statusCode == 403;

Future<bool> departureIsConfirmed({
  required SyncRowReceiptStore receipts,
  required SyncTable table,
  required String projectId,
  required Map<String, Object?> storedRow,
}) async {
  final acked = await receipts.ackedUpdatedAt(
    projectId: projectId,
    tableName: Tables.projectMemberships,
    rowKey: syncRowKey(table, storedRow),
  );
  return acked != null && acked == storedRow['updated_at'];
}

import 'sync_dropped_rows.dart';

/// Turns one durably-recorded drop into what a person needs to read: **which
/// record, which rule refused it, and what to do** — the standing rule added
/// 2026-08-27 ("A Check Must Name What Is Wrong"), applied to task 11.44's
/// inbound mirror of `HeldRowDetails` (task 10.28 / 11.41).
///
/// **Deliberately thinner than `HeldRowDetails`, and that is the honest
/// answer rather than a shortcut.** A held row is still in this device's own
/// SQLite, so that resolver can read it and say "the tag ..." or name the
/// person it belongs to. A dropped row was refused *before* it was ever
/// written here — there is no local copy to read anything from — so the only
/// facts available are the ones the sync protocol itself carries: which
/// table, which row, and the validator's own field/message explanation. This
/// class states exactly those and invents nothing beyond them.
abstract final class DroppedRowDetails {
  /// Which record — the identity the protocol carries, since there is no
  /// stored copy on this device to read a friendlier name from.
  static String recordLabel(DroppedRow row) =>
      '${_humanTableName(row.tableName)} · ${row.rowKey}';

  /// Which rule refused it, stated as a fact about the record rather than as
  /// the server's own reason: this app's own read of the incoming row is what
  /// found the problem, before the row ever reached the server's decision.
  static String reason(DroppedRow row) =>
      'This app did not store this record when the server sent it: '
      '${row.field} — ${row.message}.';

  /// What the person can do — including "nothing you can force," which is the
  /// honest answer here. Unlike a held row, there is no local action that
  /// re-offers this record: the pull that skipped it has already moved past
  /// it, and this app has no "fetch everything again" button.
  static String whatYouCanDo(DroppedRow row) =>
      'It is safe on the server, so nothing has been lost. Update this app; '
      'it comes back automatically the next time it changes on the device '
      'that holds it.';

  static String _humanTableName(String tableName) =>
      tableName.replaceAll('_', ' ').trim();
}

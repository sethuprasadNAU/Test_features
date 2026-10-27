import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../db/data_arrival.dart';
import '../repositories/tag_library_repository.dart';
import '../repositories/tag_repository.dart';
import 'tag_csv_import.dart';

/// Writes a previewed tag CSV import, all of it or none of it.
///
/// ## Why this is not a loop on the screen — finding M-2 (§14.9)
///
/// It was one, in `tag_database_screen.dart`: `for (row in validRows) { await
/// insert; await link; }`, with no transaction and no `try`. One row the
/// database rejected — a duplicate `tag_id`, or a `NaN` frequency reaching a
/// `REAL NOT NULL` column, which is how finding M-1 reaches here — threw out
/// of the middle of the loop. The rows before it stayed, the rows after it
/// never happened, there was no rollback, and the throw escaped past the
/// success snackbar, so **the user was told nothing at all**. A partial write
/// with no report is a small instance of the shape §4's B1 exists for.
///
/// The commit lives here rather than in the widget because a transaction is
/// not a screen's business and because a property this file asserts —
/// *nothing, or everything* — has to be testable without a file picker.
abstract final class TagCsvCommit {
  /// Writes every valid row of [preview] into this device's tag library, and
  /// — when [projectId] is given — puts a **copy** of each into that project,
  /// all inside a single transaction.
  ///
  /// ## The two writes are a library entry and a copy, not a tag and a link
  ///
  /// Task 11.219. A spreadsheet describes the person's transmitters, so the
  /// row it produces is a library entry; a project's tag is a copy of one,
  /// with its own id and the entry's lineage. The old shape — one global tag
  /// plus a `Project_Tags` link — no longer exists.
  ///
  /// **A copy that the project's role gradient refuses fails the whole
  /// import**, which is deliberate and is the property this class exists for:
  /// a viewer who imports two hundred tags into a project they may not write
  /// must not end up with two hundred library entries and no tags, reported
  /// as a success. Nothing, or everything.
  ///
  /// [skippedRowNumbers] drops rows the user chose not to import after seeing
  /// the preview — task 11.13's per-row "skip this one", offered on rows that
  /// resemble an existing tag so a person can drop the handful of duplicates
  /// out of a large batch rather than re-editing the file.
  ///
  /// Returns the number of tags written. Throws whatever the database threw,
  /// having written nothing — the caller's job is to say so, not to guess how
  /// much landed.
  static Future<int> commit(
    Database db,
    TagCsvPreview preview, {
    required String? projectId,
    required String modifiedBy,
    required String deviceId,
    required DateTime now,
    Set<int> skippedRowNumbers = const {},
  }) async {
    final rows = preview.validRows
        .where((r) => !skippedRowNumbers.contains(r.rowNumber))
        .toList();
    if (rows.isEmpty) return 0;
    await db.transaction((txn) async {
      final library = TagLibraryRepository(txn);
      final tags = projectId == null ? null : TagRepository(txn);
      for (final row in rows) {
        final entry =
            row.withSync(now: now, modifiedBy: modifiedBy, deviceId: deviceId);
        await library.insert(entry);
        if (tags != null) {
          await tags.copyFromLibrary(
            entry,
            projectId: projectId!,
            modifiedBy: modifiedBy,
            deviceId: deviceId,
            now: now,
          );
        }
      }
    });
    // One announcement for the whole batch, not one per row: a CSV of two
    // hundred tags is a single arrival, and announcing per row would re-run
    // the map's entire query two hundred times (task 11.45).
    DataArrival.announce();
    return rows.length;
  }
}

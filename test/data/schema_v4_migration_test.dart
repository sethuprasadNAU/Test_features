import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart' show kTagLibraryTable;
import 'package:tritrack_sync/tritrack_sync.dart';

import 'migration_support.dart';

/// Exercises the actual on-device upgrade path for schema v4 (rather than the
/// backup-row path covered in `sync/schema_migrator_test.dart`): a database
/// opened at v3 (pre-color_hex) with several pre-existing tags, upgraded to
/// v4, must backfill each tag with a *distinct* round-robin color rather than
/// leaving them all on the `ALTER TABLE ... DEFAULT` value.
///
/// **Where those tags end up changed in task 11.219, and the change is worth
/// asserting here rather than working around.** These three are in no
/// project — the fixture never made one — so schema v14 moves them into the
/// device's personal tag library and deletes them from `Tags`, which is
/// exactly §3.3's orphan rule. So the colours are read from the library, and
/// this test now covers two migrations: v4 assigned the colours and v14
/// carried them across without touching them.
void main() {
  test('upgrading a v3 database backfills existing tags with distinct colors', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 3, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 3);

    for (final id in ['tag-1', 'tag-2', 'tag-3']) {
      await db.insert(Tables.tags, {
        'tag_id': id,
        'frequency_mhz': 150.0,
        'tag_name': id,
        'date_put_on': '2026-07-16T18:30:00.000Z',
        'status': 'active',
        'created_at': '2026-07-16T18:30:00.000Z',
        'updated_at': '2026-07-16T18:30:00.000Z',
        'revision': 0,
      });
    }

    await runMigrations(db, from: 3, to: lastVersionBeforeTheWipe);

    expect(
      await db.query(Tables.tags),
      isEmpty,
      reason: 'no project names these three, so schema v14 moves them to the '
          'library — nothing referenced them, which is what made them orphans',
    );
    final rows = await db.query(kTagLibraryTable, orderBy: 'tag_id');
    final colors = rows.map((r) => r['color_hex'] as String).toList();
    expect(colors, [
      TagColorPalette.colors[0],
      TagColorPalette.colors[1],
      TagColorPalette.colors[2],
    ]);
    expect(colors.toSet(), hasLength(3), reason: 'backfilled colors must be distinct');

    await db.close();
  });
}

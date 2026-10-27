import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Task 10.19's "no failure path may delete local data" invariant, for the
/// migration case specifically.
///
/// This is deliberately independent of `AppDatabase`/`migrations.dart`: it
/// proves what sqflite itself guarantees when an `onUpgrade` callback throws,
/// using a callback built to fail on purpose, so the claim doesn't depend on
/// reading library source correctly. If this ever goes red, the pre-migration
/// backup (`pre_migration_backup_test.dart`) is what stands between a failed
/// migration and real data loss — this test is what tells you whether that
/// backup is the *only* thing standing between them, or a second line of
/// defense behind sqflite's own transaction.
void main() {
  setUpAll(() => sqfliteFfiInit());

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('migration_failure_test_');
  });

  tearDown(() => tempDir.delete(recursive: true));

  test(
    'a migration that throws partway leaves the file at its old version, '
    'with none of its partial changes applied',
    () async {
      final path = '${tempDir.path}/db';

      // Version 1: a real table with a real row.
      final v1 = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute('CREATE TABLE Widgets (id TEXT PRIMARY KEY)');
            await db.insert('Widgets', {'id': 'w1'});
          },
        ),
      );
      await v1.close();

      // Version 2: a migration that does one real thing (adds a column) and
      // then fails — modeling a broken statement discovered mid-migration.
      final failure = expectLater(
        databaseFactoryFfi.openDatabase(
          path,
          options: OpenDatabaseOptions(
            version: 2,
            onUpgrade: (db, oldVersion, newVersion) async {
              await db.execute('ALTER TABLE Widgets ADD COLUMN color TEXT');
              throw Exception('simulated failure partway through migration');
            },
          ),
        ),
        throwsA(isA<Exception>()),
      );
      await failure;

      // Reopen with no upgrade at all (version omitted) to inspect what
      // actually landed on disk, without the act of inspecting it triggering
      // another migration attempt.
      final inspect = await databaseFactoryFfi.openDatabase(path);
      final versionRows = await inspect.rawQuery('PRAGMA user_version');
      expect(
        versionRows.first.values.first,
        1,
        reason: 'sqflite must not have recorded the upgrade as complete',
      );

      final columns = await inspect.rawQuery('PRAGMA table_info(Widgets)');
      expect(
        columns.map((c) => c['name']),
        isNot(contains('color')),
        reason:
            'the ALTER that ran before the throw must have rolled back too — '
            'a partially-applied migration is exactly the corruption this '
            'invariant rules out',
      );

      final rows = await inspect.query('Widgets');
      expect(rows.single['id'], 'w1', reason: 'the original row survives untouched');
      await inspect.close();
    },
  );
}

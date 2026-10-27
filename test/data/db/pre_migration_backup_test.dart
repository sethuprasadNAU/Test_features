import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/pre_migration_backup.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_path_provider.dart';

/// Task 10.19: "back up automatically before every migration." A migration is
/// the one place the app itself can destroy data (a failure partway through),
/// so this is the one guaranteed backup — a raw file copy taken before
/// `runMigrations` touches anything, proven here both in isolation
/// ([PreMigrationBackup] directly) and wired through [AppDatabase.open].
void main() {
  setUpAll(() => sqfliteFfiInit());

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pre_migration_backup_test_');
  });

  tearDown(() => tempDir.delete(recursive: true));

  Future<String> seedDatabaseAt(String path, {required int version}) async {
    final db = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: version,
        onCreate: (db, v) => runMigrations(db, from: 0, to: v),
      ),
    );
    await db.close();
    return path;
  }

  group('PreMigrationBackup.ensureBackedUpBeforeMigration', () {
    test('no-ops when the database file does not exist yet', () async {
      final path = '${tempDir.path}/fresh.db';
      final backupDir = Directory('${tempDir.path}/backups');

      final result = await PreMigrationBackup.ensureBackedUpBeforeMigration(
        factory: databaseFactoryFfi,
        path: path,
        targetVersion: latestSchemaVersion,
        backupDir: backupDir,
      );

      expect(result, isNull);
      expect(await backupDir.exists(), isFalse);
    });

    test('no-ops when the database is already at the target version',
        () async {
      final path = await seedDatabaseAt(
        '${tempDir.path}/current.db',
        version: latestSchemaVersion,
      );
      final backupDir = Directory('${tempDir.path}/backups');

      final result = await PreMigrationBackup.ensureBackedUpBeforeMigration(
        factory: databaseFactoryFfi,
        path: path,
        targetVersion: latestSchemaVersion,
        backupDir: backupDir,
      );

      expect(result, isNull);
      expect(await backupDir.exists(), isFalse);
    });

    test('copies the file when a migration is about to run, at the '
        'pre-migration version', () async {
      final oldVersion = latestSchemaVersion - 1;
      final path = await seedDatabaseAt(
        '${tempDir.path}/stale.db',
        version: oldVersion,
      );
      final backupDir = Directory('${tempDir.path}/backups');
      final now = DateTime.utc(2026, 8, 6, 12);

      final backup = await PreMigrationBackup.ensureBackedUpBeforeMigration(
        factory: databaseFactoryFfi,
        path: path,
        targetVersion: latestSchemaVersion,
        backupDir: backupDir,
        now: now,
      );

      expect(backup, isNotNull);
      expect(await backup!.exists(), isTrue);
      expect(backup.path, contains('pre_migration_v${oldVersion}_'));

      // The copy is a real, independently openable database at the old
      // version — not just bytes that happen to match.
      final reopened = await databaseFactoryFfi.openDatabase(backup.path);
      final versionRows = await reopened.rawQuery('PRAGMA user_version');
      await reopened.close();
      expect(versionRows.first.values.first, oldVersion);

      // The source file is untouched — this is a copy, not a move.
      expect(await File(path).exists(), isTrue);
    });

    test('a value written before the migration survives in the backup',
        () async {
      final oldVersion = latestSchemaVersion - 1;
      final path = '${tempDir.path}/withdata.db';
      final seeded = await databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: oldVersion,
          onCreate: (db, v) => runMigrations(db, from: 0, to: v),
        ),
      );
      final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));
      await seeded.insert(Tables.users, {
        'user_id': 'user-1',
        'first_name': 'Sam',
        'last_name': 'Ranger',
        'email': 'sam@example.com',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': 'user-1',
        'origin_device_id': 'device-A',
      });
      await seeded.close();

      final backup = await PreMigrationBackup.ensureBackedUpBeforeMigration(
        factory: databaseFactoryFfi,
        path: path,
        targetVersion: latestSchemaVersion,
        backupDir: Directory('${tempDir.path}/backups'),
      );

      final reopened = await databaseFactoryFfi.openDatabase(backup!.path);
      final rows = await reopened.query(Tables.users);
      await reopened.close();
      expect(rows.single['email'], 'sam@example.com');
    });

    test('keeps only the newest snapshots beyond retentionCount', () async {
      final backupDir = Directory('${tempDir.path}/backups');
      await backupDir.create(recursive: true);

      // One backup per "migration", each at a later moment, more than the
      // retention count. Each source file must itself be a distinct database
      // (a `File.copy` of the same never-reopened source would race with a
      // still-open connection), so each generation gets its own seeded file.
      final expectedSurvivorTimestamps = <String>[];
      final totalGenerations = PreMigrationBackup.retentionCount + 2;
      for (var i = 0; i < totalGenerations; i++) {
        final path = '${tempDir.path}/gen$i.db';
        await seedDatabaseAt(path, version: latestSchemaVersion - 1);
        final now = DateTime.utc(2026, 1, 1).add(Duration(seconds: i));
        await PreMigrationBackup.ensureBackedUpBeforeMigration(
          factory: databaseFactoryFfi,
          path: path,
          targetVersion: latestSchemaVersion,
          backupDir: backupDir,
          now: now,
        );
        if (i >= totalGenerations - PreMigrationBackup.retentionCount) {
          expectedSurvivorTimestamps.add(
            '${now.year}${now.month.toString().padLeft(2, '0')}'
            '${now.day.toString().padLeft(2, '0')}'
            'T${now.hour.toString().padLeft(2, '0')}'
            '${now.minute.toString().padLeft(2, '0')}'
            '${now.second.toString().padLeft(2, '0')}Z',
          );
        }
      }

      final remaining = await backupDir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      expect(remaining.length, PreMigrationBackup.retentionCount);

      // The survivors are the ones with the latest embedded timestamps —
      // proving age order came from that timestamp, not filesystem metadata
      // (creation order and iteration order need not otherwise agree).
      final survivorNames = remaining.map((f) => f.uri.pathSegments.last);
      for (final stamp in expectedSurvivorTimestamps) {
        expect(survivorNames.any((n) => n.contains(stamp)), isTrue);
      }
    });
  });

  group('wired through AppDatabase.open', () {
    setUp(installFakePathProvider);

    test('opening an old-version database on disk leaves a pre-migration '
        'backup behind and still migrates successfully', () async {
      // Build the file AppDatabase.open will find, at one version behind
      // current — exactly the shape a real upgrade takes.
      final directory = Directory((await getApplicationSupportDirectory()).path);
      final fileName = 'tri_track_test.db';
      final path = '${directory.path}/$fileName';
      await seedDatabaseAt(path, version: latestSchemaVersion - 1);

      final db = await AppDatabase.open(fileName: fileName);
      addTearDown(db.close);

      final backupDir = Directory('${directory.path}/pre_migration_backups');
      expect(await backupDir.exists(), isTrue);
      final backups = await backupDir.list().toList();
      expect(backups, isNotEmpty);

      // And the real database did land on the current version.
      final versionRows = await db.raw.rawQuery('PRAGMA user_version');
      expect(versionRows.first.values.first, latestSchemaVersion);
    });

    test('a fresh install writes no pre-migration backup', () async {
      final directory = Directory((await getApplicationSupportDirectory()).path);
      final db = await AppDatabase.open(fileName: 'brand_new.db');
      addTearDown(db.close);

      final backupDir = Directory('${directory.path}/pre_migration_backups');
      expect(await backupDir.exists(), isFalse);
    });
  });
}

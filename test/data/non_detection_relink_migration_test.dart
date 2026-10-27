import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/non_detection_relink_migration.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/dart_source.dart';

/// **Schema v15 (task 11.225): the repair schema v14's fork (task 11.224)
/// deliberately left for a later task.**
///
/// A forked collar's copy left every "no signal" entry in the receiving
/// project still naming the original tag's id — a dangling reference,
/// accepted by Security Model §5.9(b) as a known consequence of the fork.
/// This file tests [NonDetectionRelinkMigration], which re-points those ids
/// from `Tags.lineage_id` rather than from anything the fork recorded, so it
/// gives the same answer whether it runs right after the fork or on a device
/// that has held the dangling reference for weeks.
///
/// The reachability half is tested separately, at the bottom: this migration
/// is the first code in the repository to read
/// `Non_Detections.tag_ids_listened_for` as a relationship, which is exactly
/// what [assertSealedColumnsFeedNoReachability] exists to catch **if it is
/// done by declaring the column in a reachability set**. It is not declared
/// there; every lookup below stays inside the row's own project instead. Both
/// halves of that claim are checked here rather than assumed.
void main() {
  const t = '2026-08-02T12:00:00.000Z';

  // v14, not v13: this migration runs on a database already shaped the way
  // v14 leaves it — `Tags.project_id` and `Tags.lineage_id` both exist —
  // since that is what it is registered to run after.
  Future<Database> openV14() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 14, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 14);
    return db;
  }

  Map<String, Object?> sync(String at) => {
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': 'user-1',
  };

  Future<void> seedUser(Database db) => db.insert(Tables.users, {
    'user_id': 'user-1',
    'first_name': 'Sam',
    'last_name': 'Reyes',
    'email': 'user-1@example.com',
    ...sync(t),
  });

  Future<void> seedProject(Database db, String projectId) =>
      db.insert(Tables.projects, {
        'project_id': projectId,
        'project_name': projectId,
        'owner_user_id': 'user-1',
        'creation_date': t,
        'datum': 'WGS84',
        'coordinate_format': 'dd',
        'triangulation_window_minutes': 15,
        ...sync(t),
      });

  Future<void> seedTag(
    Database db,
    String tagId, {
    required String projectId,
    required String lineageId,
    String? copiedAt,
  }) => db.insert(Tables.tags, {
    'tag_id': tagId,
    'project_id': projectId,
    'lineage_id': lineageId,
    'copied_at': copiedAt,
    'frequency_mhz': 150.325,
    'pulse_rate': 40.0,
    'tag_name': 'Coco',
    'date_put_on': t,
    'status': 'active',
    'color_hex': '#E69F00',
    ...sync(t),
  });

  Future<void> seedNonDetection(
    Database db, {
    required String id,
    required String projectId,
    required List<String> tagIds,
    String updatedAt = t,
    int revision = 0,
  }) => db.insert(Tables.nonDetections, {
    'non_detection_id': id,
    'project_id': projectId,
    'user_id': 'user-1',
    'timestamp_local': t,
    'timestamp_utc': t,
    'timezone_offset': '+00:00',
    'latitude': 35.1,
    'longitude': -111.6,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'tag_ids_listened_for': DbCodec.encodeStringList(tagIds),
    ...sync(t),
    'updated_at': updatedAt,
    'revision': revision,
  });

  /// The v14-shaped fixture directly: two projects, each holding its own
  /// `Tags` row for the same lineage — exactly what the fork leaves behind —
  /// without going through `TagScopeMigration.fork` itself. This isolates
  /// [NonDetectionRelinkMigration] from the fork's own behaviour, which
  /// `schema_v14_fork_test.dart` already covers end to end.
  Future<Database> seedForkedShape(Database db) async {
    await seedUser(db);
    await seedProject(db, 'proj-a');
    await seedProject(db, 'proj-b');
    await seedTag(db, 'shared-1', projectId: 'proj-a', lineageId: 'shared-1');
    await seedTag(
      db,
      'shared-1-copy',
      projectId: 'proj-b',
      lineageId: 'shared-1',
      copiedAt: t,
    );
    return db;
  }

  group('derives from lineage rather than from what the fork did', () {
    test('an id naming a row this project does not hold is re-pointed to '
        'this project\'s own same-lineage row', () async {
      final db = await openV14();
      addTearDown(db.close);
      await seedForkedShape(db);
      await seedNonDetection(
        db,
        id: 'nd-1',
        projectId: 'proj-b',
        tagIds: ['shared-1'],
      );

      final report = await NonDetectionRelinkMigration.relink(db);
      expect(report.rowsExamined, 1);
      expect(report.idsRewritten, 1);
      expect(report.idsLeftAlone, 0);

      final nd = (await db.query(
        Tables.nonDetections,
        where: 'non_detection_id = ?',
        whereArgs: ['nd-1'],
      )).single;
      expect(nd['tag_ids_listened_for'], '["shared-1-copy"]');
    });

    test('an id that already resolves locally is left alone', () async {
      final db = await openV14();
      addTearDown(db.close);
      await seedForkedShape(db);
      await seedNonDetection(
        db,
        id: 'nd-1',
        projectId: 'proj-a',
        tagIds: ['shared-1'],
      );

      final report = await NonDetectionRelinkMigration.relink(db);
      expect(report.idsRewritten, 0);
      expect(report.idsLeftAlone, 0);

      final nd = (await db.query(
        Tables.nonDetections,
        where: 'non_detection_id = ?',
        whereArgs: ['nd-1'],
      )).single;
      expect(nd['tag_ids_listened_for'], '["shared-1"]');
    });

    test('an id with no same-lineage row in this project is left alone and '
        'counted — it should not happen, and if it does, the count is the '
        'finding', () async {
      final db = await openV14();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'proj-a');
      await seedProject(db, 'proj-b');
      await seedTag(
        db,
        'only-in-a',
        projectId: 'proj-a',
        lineageId: 'only-in-a',
      );
      await seedNonDetection(
        db,
        id: 'nd-1',
        projectId: 'proj-b',
        tagIds: ['only-in-a'],
      );

      final report = await NonDetectionRelinkMigration.relink(db);
      expect(report.idsRewritten, 0);
      expect(report.idsLeftAlone, 1);

      final nd = (await db.query(
        Tables.nonDetections,
        where: 'non_detection_id = ?',
        whereArgs: ['nd-1'],
      )).single;
      expect(
        nd['tag_ids_listened_for'],
        '["only-in-a"]',
        reason: 'left exactly as found, not dropped',
      );
    });

    test('an unknown id, naming no Tags row at all, is left alone and '
        'counted the same way', () async {
      final db = await openV14();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'proj-a');
      await seedNonDetection(
        db,
        id: 'nd-1',
        projectId: 'proj-a',
        tagIds: ['never-existed'],
      );

      final report = await NonDetectionRelinkMigration.relink(db);
      expect(report.idsLeftAlone, 1);
    });

    test('prints zeroes rather than nothing when there is nothing to '
        'rewrite', () async {
      final db = await openV14();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'proj-a');

      final printed = <String>[];
      await NonDetectionRelinkMigration.apply(db, 13, log: printed.add);
      expect(printed.first, contains('Schema v15'));
      expect(printed, contains('  Non_Detections rows examined: 0'));
      expect(
        printed,
        contains('  listened-for ids rewritten to this project\'s own copy: 0'),
      );
    });

    test('a fresh create prints nothing', () async {
      final db = await openV14();
      addTearDown(db.close);
      final printed = <String>[];
      await NonDetectionRelinkMigration.apply(db, 0, log: printed.add);
      expect(printed, isEmpty);
    });
  });

  group('idempotent on a database that has already run it', () {
    test('running it twice rewrites nothing the second time', () async {
      final db = await openV14();
      addTearDown(db.close);
      await seedForkedShape(db);
      await seedNonDetection(
        db,
        id: 'nd-1',
        projectId: 'proj-b',
        tagIds: ['shared-1'],
      );

      final first = await NonDetectionRelinkMigration.relink(db);
      expect(first.idsRewritten, 1);

      final second = await NonDetectionRelinkMigration.relink(db);
      expect(second.idsRewritten, 0);
      expect(second.idsLeftAlone, 0);
    });
  });

  group(
    'updated_at, measured against Sync_Row_Receipts rather than assumed',
    () {
      test('a row the server has already accepted has its updated_at and '
          'revision bumped, so the correction is offered again', () async {
        final db = await openV14();
        addTearDown(db.close);
        await seedForkedShape(db);
        await seedNonDetection(
          db,
          id: 'nd-1',
          projectId: 'proj-b',
          tagIds: ['shared-1'],
          updatedAt: t,
          revision: 3,
        );
        await SyncRowReceiptStore.ensureTable(db);
        await SyncRowReceiptStore(db).record(
          projectId: 'proj-b',
          tableName: Tables.nonDetections,
          rowKey: 'nd-1/proj-b',
          ackedUpdatedAt: t,
          at: DateTime.parse(t),
        );

        final report = await NonDetectionRelinkMigration.relink(db);
        expect(report.rowsUpdatedAtBumped, 1);

        final nd = (await db.query(
          Tables.nonDetections,
          where: 'non_detection_id = ?',
          whereArgs: ['nd-1'],
        )).single;
        expect(nd['updated_at'], isNot(t));
        expect(nd['revision'], 4);
      });

      test('a row the server has never accepted keeps its updated_at — it is '
          'already pending regardless', () async {
        final db = await openV14();
        addTearDown(db.close);
        await seedForkedShape(db);
        await seedNonDetection(
          db,
          id: 'nd-1',
          projectId: 'proj-b',
          tagIds: ['shared-1'],
          updatedAt: t,
          revision: 0,
        );
        // No `Sync_Row_Receipts` table at all — the ordinary shape of a device
        // that has never synced.

        final report = await NonDetectionRelinkMigration.relink(db);
        expect(report.rowsUpdatedAtBumped, 0);

        final nd = (await db.query(
          Tables.nonDetections,
          where: 'non_detection_id = ?',
          whereArgs: ['nd-1'],
        )).single;
        expect(nd['updated_at'], t);
        expect(nd['revision'], 0);
      });

      test('a receipt for a *different* row does not bump this one', () async {
        final db = await openV14();
        addTearDown(db.close);
        await seedForkedShape(db);
        await seedNonDetection(
          db,
          id: 'nd-1',
          projectId: 'proj-b',
          tagIds: ['shared-1'],
        );
        await SyncRowReceiptStore.ensureTable(db);
        await SyncRowReceiptStore(db).record(
          projectId: 'proj-b',
          tableName: Tables.nonDetections,
          rowKey: 'some-other-row/proj-b',
          ackedUpdatedAt: t,
          at: DateTime.parse(t),
        );

        final report = await NonDetectionRelinkMigration.relink(db);
        expect(report.rowsUpdatedAtBumped, 0);
      });
    },
  );

  group('registered as a schema migration', () {
    test('schema v15 is registered and runs after v14', () {
      expect(latestSchemaVersion, greaterThanOrEqualTo(15));
      expect(
        migrations.any(
          (m) => m.version == 15 && m.run == NonDetectionRelinkMigration.apply,
        ),
        isTrue,
      );
    });
  });

  group('the sealed-column obligation this reader owes (§5.9(b), task '
      '11.225)', () {
    test('assertSealedColumnsFeedNoReachability still returns normally with '
        'this migration in the tree', () {
      // This is the check that this reader was **not** smuggled past the
      // assertion by declaring `tag_ids_listened_for` in `userColumns`,
      // `tagColumns` or `emailColumns` — the three sets `ProjectReachability`,
      // `ProjectExporter` and `RowAuthorizer` actually walk. If a later edit
      // ever does that, this goes red exactly as it did before this
      // migration existed.
      expect(assertSealedColumnsFeedNoReachability, returnsNormally);
      expect(
        unvalidatedIdListColumns[Tables.nonDetections],
        'tag_ids_listened_for',
        reason:
            'this migration derives the column name from the registration '
            'rather than hardcoding it — if this entry moves, the migration '
            'throws rather than silently repairing nothing, and this test is '
            'what would tell a reader why',
      );
    });

    test('every lookup this reader makes stays inside the row\'s own '
        'project', () {
      // A structural check on the reader's own source, in the shape
      // `data_arrival_announced_test.dart` uses for a different obligation:
      // derived from what the file actually does, not trusted from its doc
      // comment. If either WHERE clause below is ever loosened to search
      // across projects, this fails — which is the day the column would
      // actually start feeding reachability, `SyncTable` declarations or
      // not.
      final source = stripComments(
        File(
          'lib/data/db/non_detection_relink_migration.dart',
        ).readAsStringSync(),
      );
      expect(
        source,
        contains("where: 'tag_id = ? AND project_id = ?'"),
        reason:
            'the "does this id still resolve here" lookup must be '
            'scoped to the row\'s own project_id',
      );
      expect(
        source,
        contains("where: 'project_id = ? AND lineage_id = ?'"),
        reason:
            'the "does this project hold the same lineage" lookup must '
            'be scoped to the row\'s own project_id, never to every '
            'project holding that lineage',
      );
      expect(
        source,
        isNot(contains('GROUP BY')),
        reason:
            'a lookup that groups across projects would be the '
            '"which projects hold this lineage" question — the one this '
            'reader must never ask',
      );
    });
  });
}

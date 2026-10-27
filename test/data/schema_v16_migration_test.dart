import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/individual_backfill_migration.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Schema v16 (task 11.240): one individual per tag, colour moved, no
/// name-matching anywhere.
void main() {
  const t = '2026-08-02T12:00:00.000Z';

  Future<Database> openV15() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 15, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 15);
    return db;
  }

  Map<String, Object?> sync(String at, {String? deletedAt}) => {
    'created_at': at,
    'updated_at': at,
    'deleted_at': deletedAt,
    'revision': 0,
    'last_modified_by': 'user-1',
    'origin_device_id': 'device-A',
  };

  Future<void> seedProject(Database db, String projectId) async {
    await db.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': projectId,
      'owner_user_id': 'user-1',
      'creation_date': t,
      'datum': 'WGS84',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
      ...sync(t),
    });
  }

  /// A v15 tag row: `color_hex` NOT NULL, no `individual_id`.
  Future<void> seedTag(
    Database db, {
    required String id,
    required String projectId,
    required String name,
    required String color,
    String status = 'active',
    String? deletedAt,
  }) => db.insert(Tables.tags, {
    'tag_id': id,
    'project_id': projectId,
    'lineage_id': id,
    'frequency_mhz': 150.1,
    'tag_name': name,
    'date_put_on': t,
    'status': status,
    'color_hex': color,
    ...sync(t, deletedAt: deletedAt),
  });

  Future<Database> seededV15() async {
    final db = await openV15();
    await db.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Reyes',
      'email': 'user-1@example.com',
      ...sync(t),
    });
    await seedProject(db, 'p1');
    await seedProject(db, 'p2');
    // Two collars called Marie in one project — one bird on a second collar,
    // a reused name, or a typo: the migration cannot know and must not guess.
    await seedTag(db, id: 'marie-2025', projectId: 'p1', name: 'Marie',
        color: '#111111');
    await seedTag(db, id: 'marie-2026', projectId: 'p1', name: 'Marie',
        color: '#222222');
    // A recovered collar, and a removed one.
    await seedTag(db, id: 'coco', projectId: 'p1', name: 'Coco',
        color: '#333333', status: 'recovered');
    await seedTag(db, id: 'gone', projectId: 'p2', name: 'Gone',
        color: '#444444', deletedAt: t);
    return db;
  }

  test('one individual per tag, keyed by the tag, wearing its name and colour',
      () async {
    final db = await seededV15();
    final lines = <String>[];
    await runMigrations(db, from: 15, to: 16);
    // The census, re-derived on the migrated database rather than trusted.
    final report = IndividualBackfillReport(
      tags: 4,
      individuals: (await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${Tables.individuals}',
      )).first['c'] as int,
      linkedTags: (await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${Tables.tags} t JOIN ${Tables.individuals} i '
        'ON i.individual_id = t.individual_id AND i.project_id = t.project_id',
      )).first['c'] as int,
    );
    lines.addAll(report.report());
    expect(lines.single, contains('4 individual(s) created'));
    expect(lines.single, contains('4 tag(s) now name their animal'));
    expect(lines.single, isNot(contains('MISMATCH')));

    final individuals = await db.query(Tables.individuals, orderBy: 'individual_id');
    expect(individuals.map((i) => i['individual_id']),
        ['coco', 'gone', 'marie-2025', 'marie-2026']);
    for (final i in individuals) {
      expect(i['lineage_id'], i['individual_id'], reason: 'nothing was copied');
      expect(i['copied_at'], isNull);
      expect(i['revision'], 0);
    }
    final marie2025 = individuals.singleWhere((i) => i['individual_id'] == 'marie-2025');
    expect(marie2025['name'], 'Marie');
    expect(marie2025['color_hex'], '#111111');
    expect(marie2025['project_id'], 'p1');
    expect(marie2025['status'], 'alive');

    for (final tag in await db.query(Tables.tags)) {
      expect(tag['individual_id'], tag['tag_id']);
      expect(tag['color_hex'], isNull, reason: 'the retired column is emptied');
    }
    await db.close();
  });

  test('two same-named tags stay two individuals — no name-matching', () async {
    final db = await seededV15();
    await runMigrations(db, from: 15, to: 16);
    final maries = await db.query(
      Tables.individuals,
      where: 'name = ?',
      whereArgs: ['Marie'],
    );
    expect(maries, hasLength(2));
    expect(maries.map((m) => m['lineage_id']).toSet(), hasLength(2),
        reason: 'and not one animal by lineage either');
    await db.close();
  });

  test("a recovered collar's animal is unknown, not dead and not alive",
      () async {
    final db = await seededV15();
    await runMigrations(db, from: 15, to: 16);
    final coco = (await db.query(Tables.individuals,
            where: 'individual_id = ?', whereArgs: ['coco']))
        .single;
    expect(coco['status'], IndividualStatus.unknown.db);
    await db.close();
  });

  test('a removed collar gets a removed animal, not one that appears from nowhere',
      () async {
    final db = await seededV15();
    await runMigrations(db, from: 15, to: 16);
    final gone = (await db.query(Tables.individuals,
            where: 'individual_id = ?', whereArgs: ['gone']))
        .single;
    expect(gone['deleted_at'], t);
    await db.close();
  });

  test('the migrated schema matches a fresh one, and its foreign keys hold',
      () async {
    final db = await seededV15();
    await runMigrations(db, from: 15, to: 16);
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
    final migrated = await db.rawQuery('PRAGMA table_info(${Tables.tags})');
    final fresh = await openV15();
    await runMigrations(fresh, from: 15, to: 16);
    final freshInfo = await fresh.rawQuery('PRAGMA table_info(${Tables.tags})');
    expect(migrated.map((c) => c['name']), freshInfo.map((c) => c['name']));
    expect(
      migrated.map((c) => '${c['name']}:${c['notnull']}'),
      freshInfo.map((c) => '${c['name']}:${c['notnull']}'),
    );
    await db.execute('PRAGMA foreign_keys = ON');
    // The composite key refuses a tag naming an animal in another project.
    await expectLater(
      db.insert(Tables.tags, {
        'tag_id': 'stray',
        'project_id': 'p2',
        'lineage_id': 'stray',
        'frequency_mhz': 150.1,
        'tag_name': 'Stray',
        'date_put_on': t,
        'status': 'active',
        'individual_id': 'marie-2025',
        ...sync(t),
      }),
      throwsA(isA<DatabaseException>()),
    );
    await db.close();
    await fresh.close();
  });

  test('the census prints on an upgrade and stays silent on a fresh create',
      () async {
    final db = await seededV15();
    final upgrade = <String>[];
    await IndividualBackfillMigration.apply(db, 15, log: upgrade.add);
    expect(upgrade, hasLength(1));
    expect(upgrade.single, startsWith('schema v16: 4 tag row(s) found'));
    await db.close();

    final fresh = await openV15();
    final create = <String>[];
    await IndividualBackfillMigration.apply(fresh, 0, log: create.add);
    expect(create, isEmpty);
    await fresh.close();
  });
}

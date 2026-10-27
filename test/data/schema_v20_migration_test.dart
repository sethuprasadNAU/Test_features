import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/core/time/time_zone_boundaries.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/project_time_zone_migration.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Schema v20 (task 11.331): a project's time zone, and each deployment
/// row's.
///
/// **Run against a populated database**, for task 11.243's reason — what
/// this migration decides is invisible with no rows. The zone at a place is
/// read from the boundaries the app actually ships; the phone's zone is
/// pinned to London, the case Michael is in (entering an Arizona project's
/// collars from the UK).
void main() {
  const t = '2026-09-01T00:00:00.000Z';
  const phoenix = 'America/Phoenix';
  const london = 'Europe/London';
  final boundaries = TimeZoneBoundaries.parse(
    File(TimeZoneBoundaries.assetPath).readAsBytesSync(),
  );

  Future<Database> openV19() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 19, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 19);
    return db;
  }

  Map<String, Object?> sync() => {
    'created_at': t,
    'updated_at': t,
    'revision': 2,
  };

  Future<void> seed(Database db) async {
    await db.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    Future<void> project(String id, {bool area = true}) =>
        db.insert(Tables.projects, {
          'project_id': id,
          'project_name': id,
          'owner_user_id': 'user-1',
          'creation_date': t,
          // Around Phoenix.
          if (area) 'bbox_min_lat': 33.40,
          if (area) 'bbox_max_lat': 33.50,
          if (area) 'bbox_min_lon': -112.12,
          if (area) 'bbox_max_lon': -112.02,
          'datum': 'WGS84',
          'coordinate_format': 'dd',
          'triangulation_window_minutes': 15,
          ...sync(),
        });
    await project('arizona');
    await project('no-area', area: false);
    Future<void> deployment(
      String id,
      String projectId, {
      DateTime? attached,
      DateTime? removed,
    }) => db.insert(Tables.deployments, {
      'deployment_id': id,
      'project_id': projectId,
      'tag_id': 'tag-$id',
      'individual_id': 'animal-$id',
      'attached_date': DbCodec.encodeUtcOrNull(attached),
      'removed_date': DbCodec.encodeUtcOrNull(removed),
      ...sync(),
    });
    // Typed as Arizona days: Arizona midnight is 07:00 UTC.
    await deployment(
      'arizona-days',
      'arizona',
      attached: DateTime.utc(2026, 9, 1, 7),
      removed: DateTime.utc(2026, 9, 20, 7),
    );
    // Typed on a phone in London: London midnight in September is 23:00 UTC
    // the day before — 16:00 in Arizona, which would read as a time.
    await deployment(
      'london-days',
      'arizona',
      attached: DateTime.utc(2026, 9, 3, 23),
    );
    // A swap confirmed at 14:32 Arizona time, attached the 1st as a day.
    await deployment(
      'arizona-swap',
      'arizona',
      attached: DateTime.utc(2026, 9, 1, 7),
      removed: DateTime.utc(2026, 9, 10, 21, 32),
    );
    await deployment('no-dates', 'arizona');
    await deployment(
      'no-area-row',
      'no-area',
      attached: DateTime.utc(2026, 9, 3, 23),
    );
  }

  Future<ProjectTimeZoneReport> migrate(Database db) =>
      ProjectTimeZoneMigration.backfill(
        db,
        zoneAt: (lat, lon) async => boundaries.zoneAt(lat, lon),
        phoneZone: () => london,
      );

  test('a v19 database has no zone columns; v20 appends both, nullable', () async {
    final db = await openV19();
    await seed(db);
    for (final table in [Tables.projects, Tables.deployments]) {
      final before = await db.rawQuery('PRAGMA table_info($table)');
      expect(before.map((c) => c['name']), isNot(contains('time_zone')));
    }
    await migrate(db);
    for (final table in [Tables.projects, Tables.deployments]) {
      final after = await db.rawQuery('PRAGMA table_info($table)');
      expect(after.last['name'], 'time_zone', reason: table);
      expect(after.last['notnull'], 0, reason: 'a minor may not add NOT NULL');
    }
    await db.close();
  });

  test('a project takes the zone at the center of its area, or the phone\'s '
      'when it has none', () async {
    final db = await openV19();
    await seed(db);
    final report = await migrate(db);
    Future<String?> zoneOf(String id) async =>
        (await db.query(
              Tables.projects,
              where: 'project_id = ?',
              whereArgs: [id],
            )).single['time_zone']
            as String?;
    expect(await zoneOf('arizona'), phoenix);
    expect(await zoneOf('no-area'), london);
    expect(report.projectsFromArea, 1);
    expect(report.projectsFromPhone, 1);
    await db.close();
  });

  test('each deployment takes its project\'s zone, except one whose days were '
      'plainly typed at this phone\'s midnight — it keeps the phone\'s zone so '
      'its days do not change, and is listed', () async {
    final db = await openV19();
    await seed(db);
    final report = await migrate(db);
    final rows = {
      for (final row in await db.query(Tables.deployments))
        row['deployment_id'] as String: Deployment.fromRow(row),
    };
    expect(rows['arizona-days']!.timeZone, phoenix);
    expect(rows['arizona-swap']!.timeZone, phoenix);
    expect(rows['no-dates']!.timeZone, phoenix);
    expect(rows['london-days']!.timeZone, london);
    expect(rows['no-area-row']!.timeZone, london);
    expect(report.deploymentsTypedInPhoneZone, ['london-days']);
    expect(report.deploymentsWithProjectZone, 4);

    // What that buys: the London row is still the 4th, as typed, and still a
    // bare day; given Arizona's zone it would have become a time on the 3rd.
    final londonRow = rows['london-days']!;
    expect(
      londonRow.calendarDateOf(londonRow.attachedDate!),
      DateTime(2026, 9, 4),
    );
    expect(londonRow.endHasTime(londonRow.attachedDate!), isFalse);
    expect(deploymentEndHasTime(londonRow.attachedDate!, phoenix), isTrue);

    // And the swap's time survives as a time in its own zone.
    final swap = rows['arizona-swap']!;
    expect(swap.endHasTime(swap.removedDate!), isTrue);
    expect(fieldWallClock(swap.removedDate!, phoenix).hour, 14);
    await db.close();
  });

  test('no sync stamp moves — a backfill is not an edit', () async {
    final db = await openV19();
    await seed(db);
    await migrate(db);
    for (final table in [Tables.projects, Tables.deployments]) {
      for (final row in await db.query(table)) {
        expect(row['updated_at'], t, reason: table);
        expect(row['revision'], 2, reason: table);
      }
    }
    await db.close();
  });

  test('the report says what it did, including on a database with nothing '
      'to do', () async {
    final db = await openV19();
    final report = await migrate(db);
    expect(report.report(), hasLength(2));
    expect(report.report().first, contains('0 project(s)'));
    await db.close();
  });

  test('the full chain reaches v20 and the project model reads the zone', () async {
    final db = await openV19();
    await seed(db);
    await migrate(db);
    final project = Project.fromRow(
      (await db.query(
        Tables.projects,
        where: 'project_id = ?',
        whereArgs: ['arizona'],
      )).single,
    );
    expect(project.timeZone, phoenix);
    expect(latestSchemaVersion, 20);
    await db.close();
  });
}

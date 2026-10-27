import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/csv/deployment_csv.dart';
import 'package:tritrack/data/csv/schema_table_csv.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/repositories/season_clone.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// Task 11.331 item 5 and 6: **a project's zone, and each deployment row's,
/// travel with it** — through a project file, into next season, and out to
/// `deployments.csv` as plain dates a spreadsheet can read without knowing
/// anything about zones.
void main() {
  const phoenix = 'America/Phoenix';
  const denver = 'America/Denver';
  late AppDatabase source;

  setUp(() async {
    source = await AppDatabase.openInMemory();
    final db = source.raw;
    await db.insert(Tables.users, sampleUser().toColumns());
    await db.insert(
      Tables.projects,
      sampleProject().copyWith(timeZone: phoenix).toColumns(),
    );
    await db.insert(Tables.tags, sampleTag().toColumns());
    await db.insert(Tables.individuals, sampleIndividual().toColumns());
    // Written while the project was on Denver time (Navajo side), then the
    // project moved to Arizona time: the row keeps its own zone.
    await db.insert(
      Tables.deployments,
      sampleDeployment(
        attachedDate: fieldDayStart(DateTime(2026, 7, 1), denver),
        removedDate: fieldInstant(DateTime(2026, 7, 20, 14, 32), denver),
      ).copyWith(timeZone: denver).toColumns(),
    );
  });
  tearDown(() => source.close());

  Future<Map<String, Object?>> only(AppDatabase db, String table) async =>
      (await db.raw.query(table)).single;

  test('a project file carries the project\'s zone and each row\'s', () async {
    final backup = await ProjectExporter.collect(
      source.raw,
      'project-1',
      now: DateTime.utc(2026, 10, 5),
    );
    final target = await AppDatabase.openInMemory();
    addTearDown(target.close);
    await ProjectMerger(target.raw).merge(
      BackupArchive.decode(BackupArchive.encode(backup)),
      origin: MergeOrigin.authenticatedServer,
    );
    expect(Project.fromRow(await only(target, Tables.projects)).timeZone, phoenix);
    final row = Deployment.fromRow(await only(target, Tables.deployments));
    expect(row.timeZone, denver);
    expect(row.calendarDateOf(row.attachedDate!), DateTime(2026, 7, 1));
  });

  test('next season starts with the same zone, and copied records keep '
      'theirs', () async {
    final result = await SeasonClone(source.raw).clone(
      sourceProjectId: 'project-1',
      name: 'Mesa Coyotes 2027',
      creatorUserId: 'user-1',
      includeAnimalsRecordedDead: true,
      includeLastKnownPositions: false,
    );
    expect(result.project.timeZone, phoenix);
    final copies = await source.raw.query(
      Tables.deployments,
      where: 'project_id = ?',
      whereArgs: [result.project.projectId],
    );
    expect(Deployment.fromRow(copies.single).timeZone, denver);
  });

  test('deployments.csv adds the days as plain dates in the row\'s zone, and '
      'the zone\'s name', () async {
    final row = Deployment.fromRow(await only(source, Tables.deployments));
    // And a New Zealand season, whose days start the evening before in UTC —
    // read naively, every one of them comes out a day early.
    final kiwi = sampleDeployment(
      id: 'kiwi',
      attachedDate: fieldDayStart(DateTime(2026, 3, 1), 'Pacific/Auckland'),
    ).copyWith(timeZone: 'Pacific/Auckland');
    final csv = deploymentsCsv([row, kiwi]);
    final lines = csv.trim().split(RegExp(r'\r?\n'));
    final header = lines.first.split(',');
    final values = lines[1].split(',');
    String cell(String name) => values[header.indexOf(name)];
    // Every column the table declares is still there, in its order.
    expect(
      header.sublist(0, SchemaTableCsv.header(Tables.deployments).length),
      SchemaTableCsv.header(Tables.deployments),
    );
    expect(cell('time_zone'), denver);
    expect(cell('attached_day'), '2026-07-01');
    // A timed end is still a day in the file — the day it fell on, there.
    expect(cell('removed_day'), '2026-07-20');
    final kiwiValues = lines[2].split(',');
    expect(kiwiValues[header.indexOf('attached_day')], '2026-03-01');
    expect(kiwiValues[header.indexOf('time_zone')], 'Pacific/Auckland');
  });
}

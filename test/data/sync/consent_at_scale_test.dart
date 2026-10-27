import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/consent_summary.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';
import 'backup_builders.dart';

/// **Task 10.87's acceptance, demonstrated at 1,000 rows against a real
/// database rather than a fixture list**: a whole-project restore that
/// rewrites every bearing's coordinates reaches the consent gate with a
/// summary a person can read, and the overwrites it then records are one
/// reviewable event, not a thousand.
///
/// Also the measurement that corrected this task's brief: an import of a
/// project *not on this device* can still reach the gate, through the two
/// tables the schema keeps global.
void main() {
  late AppDatabase database;
  late Database db;

  const me = 'user-me';
  const colleague = 'user-colleague';
  final now = DateTime.utc(2026, 9, 13, 10);
  const bearings = 1000;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    await db.insert(
      Tables.users,
      sampleUser(id: me, email: 'me@example.com').toColumns(),
    );
  });
  tearDown(() async => database.close());

  Map<String, Object?> myUserRow() =>
      sampleUser(id: me, email: 'me@example.com').toColumns();

  /// My own project, with [bearings] bearings at [latitude].
  ProjectBackup archive({
    double latitude = 35.19,
    int revision = 0,
    Map<String, Object?>? meRow,
  }) => makeBackup({
    Tables.users: [
      sampleUser(id: colleague, email: 'colleague@example.com').toColumns(),
      meRow ?? myUserRow(),
    ],
    Tables.projects: [
      sampleProject(id: 'project-1', ownerUserId: me).toColumns(),
    ],
    Tables.projectMemberships: [
      sampleMembership(id: 'm-me', userId: me).toColumns(),
      sampleMembership(
        id: 'm-colleague',
        userId: colleague,
        role: ProjectRole.contributor,
      ).toColumns(),
    ],
    Tables.tags: [sampleTag(id: 'tag-1').toColumns()],
    Tables.observations: [
      for (var i = 0; i < bearings; i++)
        sampleObservation(
          id: 'obs-$i',
          userId: me,
          sessionId: null,
          tagVersionId: null,
          latitude: latitude,
        ).toColumns()
          ..['revision'] = revision
          ..['updated_at'] = '2026-09-13T0$revision:00:00.000Z',
    ],
  }, schemaVersion: latestSchemaVersion);

  Future<MergeReport> import(ProjectBackup backup, {bool confirm = false}) =>
      ProjectMerger(db).merge(
        backup,
        importingUserId: me,
        now: now,
        confirmChanges: confirm,
      );

  group('the merge case at $bearings bearings', () {
    late MergeReport offer;

    setUp(() async {
      final first = await import(archive());
      expect(first.wrote, isTrue);
      expect(first.importCase, ImportCase.adopt);
      // The same project again, every bearing moved, one revision newer so
      // last-write-wins takes the file's side.
      offer = await import(archive(latitude: 0.0, revision: 1));
    });

    test('the gate holds, and the offer is one line rather than a thousand',
        () {
      expect(offer.outcome, MergeOutcome.needsConfirmation);
      expect(offer.importCase, ImportCase.merge);
      expect(offer.destructiveChanges, hasLength(bearings),
          reason: 'one coordinate per bearing');

      final summary = ConsentSummary.of(offer.destructiveChanges);
      expect(summary, hasLength(1));
      expect(summary.single.table, Tables.observations);
      expect(summary.single.records, bearings);
      expect(summary.single.values, bearings);
      expect(summary.single.removed, 0);
      expect(summary.single.columns, ['latitude']);
    });

    test('after consent, the $bearings overwrites are one reviewable event',
        () async {
      final applied = await import(
        archive(latitude: 0.0, revision: 1),
        confirm: true,
      );
      expect(applied.wrote, isTrue);
      expect(applied.totalUpdated, bearings);

      final conflicts = await SyncConflictStore(db).unreviewed('project-1');
      expect(conflicts, hasLength(bearings),
          reason: 'clause 4\'s recoverability half: every previous version '
              'is kept');

      final events = SyncConflictEvent.group(
        conflicts,
        tableOrder: ConsentSummary.tableOrder,
      );
      expect(events, hasLength(1),
          reason: 'one import, one clock reading, one event');
      expect(events.single.count, bearings);
      expect(events.single.countByTable, {Tables.observations: bearings});

      // Acknowledging the event acknowledges all of them, in one act.
      await SyncConflictStore(db).markReviewedMany(events.single.ids);
      expect(await SyncConflictStore(db).unreviewed('project-1'), isEmpty);
      final kept = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM ${SyncConflictStore.table}',
      );
      expect(kept.single['n'], bearings, reason: 'reviewed, never deleted');
    });
  });

  group('a project not on this device (the brief said "no overwrite is '
      'possible"; measured, that is true of its records and false of people)',
      () {
    test('the project\'s own rows cannot reach the gate — there is nothing '
        'here to overwrite', () async {
      final report = await import(archive(latitude: 0.0, revision: 1));
      expect(report.importCase, ImportCase.adopt);
      expect(report.outcome, MergeOutcome.applied);
      expect(report.destructiveChanges, isEmpty);
    });

    test('a file that renames a person this device already knows does reach '
        'the gate, and the summary is about people only', () async {
      final renamed = myUserRow()
        ..['last_name'] = 'Renamed'
        ..['revision'] = 5
        ..['updated_at'] = '2026-09-13T09:00:00.000Z';
      final report = await import(archive(meRow: renamed));
      expect(report.importCase, ImportCase.adopt);
      expect(report.outcome, MergeOutcome.needsConfirmation);
      final summary = ConsentSummary.of(report.destructiveChanges);
      expect(summary.map((t) => t.table), [Tables.users]);
      expect(summary.single.columns, ['last_name']);
      // Structural, not a coincidence of this fixture: in the not-here cases
      // no project-scoped row exists locally, so only the global tables can
      // appear. Asserted so a table that loses its scope column is noticed.
      for (final t in summary) {
        expect(syncTablesByName[t.table]!.projectScopeColumn, isNull);
      }
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation_exclusion.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/observation_exclusion_repository.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.7's round-trip requirement.** A project that has been corrected —
/// one bearing superseded by another, one excluded outright — must arrive on a
/// second device still corrected. If the marks did not travel, the same
/// project would produce two different positions on two devices, with nothing
/// on screen to say why, and the corrections would look like they had been
/// silently reverted.
void main() {
  late AppDatabase source;
  late Database db;

  final at = DateTime.utc(2026, 8, 21, 9, 0, 0);

  SyncMeta metaFor(String userId) =>
      SyncMeta.initial(now: at, modifiedBy: userId, originDeviceId: 'device-1');

  setUp(() async {
    source = await AppDatabase.openInMemory();
    db = source.raw;
  });
  tearDown(() => source.close());

  Future<void> seed(String table, Map<String, Object?> columns) =>
      db.insert(table, columns);

  test('both relationships survive export and re-import into a fresh device',
      () async {
    await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
    await seed(Tables.users, sampleUser(id: 'user-2', email: 'b@x.com').toColumns());
    await seed(
      Tables.projects,
      sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns(),
    );
    await seed(Tables.tags, sampleTag(id: 'tag-1').toColumns());
    for (final id in ['obs-bad', 'obs-good', 'obs-junk']) {
      await seed(
        Tables.observations,
        sampleObservation(
          sessionId: null,
          id: id,
          projectId: 'project-1',
          userId: 'user-2',
          tagId: 'tag-1',
        ).toColumns(),
      );
    }

    await seed(
      Tables.observationExclusions,
      ObservationExclusion(
        exclusionId: 'mark-supersede',
        projectId: 'project-1',
        observationId: 'obs-bad',
        userId: 'user-1',
        kind: ObservationExclusionKind.superseded,
        supersededByObservationId: 'obs-good',
        reason: 'bearing re-read from the field sheet',
        sync: metaFor('user-1'),
      ).toColumns(),
    );
    await seed(
      Tables.observationExclusions,
      ObservationExclusion(
        exclusionId: 'mark-exclude',
        projectId: 'project-1',
        observationId: 'obs-junk',
        userId: 'user-1',
        kind: ObservationExclusionKind.excluded,
        reason: 'bounced off the ridge',
        sync: metaFor('user-1'),
      ).toColumns(),
    );

    final bytes = BackupArchive.encode(
      await ProjectExporter.collect(db, 'project-1', now: at),
    );

    final receiver = await AppDatabase.openInMemory();
    addTearDown(receiver.close);
    final report = await ProjectMerger(
      receiver.raw,
    ).merge(BackupArchive.decode(bytes));
    expect(report.totalInvalid, 0);

    final marks = await ObservationExclusionRepository(
      receiver.raw,
    ).activeByObservation('project-1');

    expect(marks.keys, containsAll(['obs-bad', 'obs-junk']));

    final supersede = marks['obs-bad']!;
    expect(supersede.kind, ObservationExclusionKind.superseded);
    // The pointer is the relationship. Losing it would leave a bearing out of
    // analysis with nothing saying what replaced it.
    expect(supersede.supersededByObservationId, 'obs-good');
    expect(supersede.userId, 'user-1');
    expect(supersede.reason, 'bearing re-read from the field sheet');

    final exclude = marks['obs-junk']!;
    expect(exclude.kind, ObservationExclusionKind.excluded);
    expect(exclude.supersededByObservationId, isNull);
    expect(exclude.reason, 'bounced off the ridge');

    // The observation that superseded the bad one is untouched and still
    // counts; so is the bad one's own row, which is the invariant this whole
    // feature is built around.
    final stored = await receiver.raw.query(
      Tables.observations,
      where: 'project_id = ?',
      whereArgs: ['project-1'],
    );
    expect(stored, hasLength(3));
    for (final row in stored) {
      expect(row['user_id'], 'user-2');
      expect(row['deleted_at'], isNull);
    }
  });

  test('a withdrawn mark travels as a tombstone, so the receiving device does '
      'not re-apply a correction that was undone', () async {
    await seed(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
    await seed(
      Tables.projects,
      sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns(),
    );
    await seed(Tables.tags, sampleTag(id: 'tag-1').toColumns());
    await seed(
      Tables.observations,
      sampleObservation(
        sessionId: null,
        id: 'obs-1',
        projectId: 'project-1',
        userId: 'user-1',
        tagId: 'tag-1',
      ).toColumns(),
    );
    await seed(
      Tables.observationExclusions,
      ObservationExclusion(
        exclusionId: 'mark-1',
        projectId: 'project-1',
        observationId: 'obs-1',
        userId: 'user-1',
        kind: ObservationExclusionKind.excluded,
        sync: metaFor('user-1').copyWith(
          revision: 1,
          deletedAt: DateTime.utc(2026, 8, 21, 10),
        ),
      ).toColumns(),
    );

    final bytes = BackupArchive.encode(
      await ProjectExporter.collect(db, 'project-1', now: at),
    );
    final receiver = await AppDatabase.openInMemory();
    addTearDown(receiver.close);
    await ProjectMerger(receiver.raw).merge(BackupArchive.decode(bytes));

    final repo = ObservationExclusionRepository(receiver.raw);
    expect(await repo.activeByObservation('project-1'), isEmpty);
    // But the tombstone itself arrived — without it the mark would resurrect
    // the next time the two devices exchanged data.
    expect(
      await repo.findByProject('project-1', includeDeleted: true),
      hasLength(1),
    );
  });
}

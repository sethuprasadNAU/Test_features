import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/repositories/tag_version_repository.dart';
import 'package:tritrack/data/sync/backup_archive.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';
import '../../support/tag_version_history.dart';

/// **Task 11.32's every-write-path requirement.**
///
/// A tag's measurement history has to travel with the project, or the same
/// bearing means one thing on the device that recorded it and another on a
/// colleague's — which is the harm this task exists to end, reproduced one file
/// transfer later. The project-file path is the one tested here end to end;
/// sync uses the same `ProjectMerger` over the same descriptors, so the same
/// property holds there.
void main() {
  late AppDatabase source;
  late Database db;

  setUp(() async {
    source = await AppDatabase.openInMemory();
    db = source.raw;
  });
  tearDown(() => source.close());

  Future<void> seed(String table, Map<String, Object?> columns) =>
      db.insert(table, columns);

  /// A project holding one tag that drifted: two bearings, one taken against
  /// each version.
  Future<void> seedDriftedProject(Database into) async {
    await into.insert(Tables.users, sampleUser().toColumns());
    await into.insert(Tables.projects, sampleProject().toColumns());
    // A tag references its project since task 11.219, so it is seeded after
    // the project rather than before it.
    await into.insert(Tables.tags, sampleTag().toColumns());
    await into.insert(
      Tables.tagVersions,
      sampleTagVersion(id: 'ver-first').toColumns(),
    );
    await into.insert(
      Tables.tagVersions,
      sampleTagVersion(
        id: 'ver-second',
        frequencyMhz: 150.51,
        tagName: 'F21',
        effectiveFrom: DateTime.utc(2026, 10, 4),
      ).toColumns(),
    );
    for (final (id, version) in [
      ('obs-before', 'ver-first'),
      ('obs-after', 'ver-second'),
      // …and one that genuinely does not know.
      ('obs-unknown', null),
    ]) {
      await into.insert(
        Tables.observations,
        sampleObservation(id: id, sessionId: null, tagVersionId: version)
            .toColumns(),
      );
    }
  }

  Future<AppDatabase> transferToFreshDevice() async {
    final backup = await ProjectExporter.collect(
      db,
      'project-1',
      now: DateTime.utc(2026, 10, 5),
    );
    final bytes = BackupArchive.encode(backup);
    final target = await AppDatabase.openInMemory();
    await ProjectMerger(target.raw).merge(
      BackupArchive.decode(bytes),
      origin: MergeOrigin.authenticatedServer,
    );
    return target;
  }

  test('a tag\'s history travels with the project, and each bearing still '
      'says what it was recorded against', () async {
    await seedDriftedProject(db);
    final target = await transferToFreshDevice();
    addTearDown(target.close);

    final versions = TagVersionRepository(target.raw);
    expect(
      await tagVersionHistory(versions, 'tag-1'),
      hasLength(2),
      reason: 'the drift record is the point — an archive that carried only '
          'the current values would put the whole defect back one file '
          'transfer later',
    );

    final tag = Tag.fromRow(
      (await target.raw.query(Tables.tags, where: 'tag_id = ?',
          whereArgs: ['tag-1'])).single,
    );
    Future<String?> nameAsRecorded(String id) async {
      final row = (await target.raw.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: [id],
      )).single;
      final state = await versions.recordedStateOf(
        Observation.fromRow(row),
        tag: tag,
      );
      return state!.recordedTagName;
    }

    expect(await nameAsRecorded('obs-before'), 'Coco');
    expect(await nameAsRecorded('obs-after'), 'F21');
    expect(
      await nameAsRecorded('obs-unknown'),
      isNull,
      reason: 'a bearing that did not know still does not know — an import '
          'must not invent a version for a row that arrived without one',
    );
  });

  test('the export collects every version of a reachable tag, not only the '
      'ones a surviving bearing names', () async {
    // A version an earlier record pointed at is still the history of a tag
    // this archive carries. Collecting only referenced versions would drop the
    // drift record the moment a bearing was superseded or deleted.
    await seedDriftedProject(db);
    await db.delete(
      Tables.observations,
      where: 'observation_id = ?',
      whereArgs: ['obs-before'],
    );

    final backup = await ProjectExporter.collect(
      db,
      'project-1',
      now: DateTime.utc(2026, 10, 5),
    );
    expect(
      backup.rowsFor(Tables.tagVersions).map((r) => r['tag_version_id']),
      containsAll(['ver-first', 'ver-second']),
    );
  });

  test('another project\'s tag carries none of its history into the archive',
      () async {
    // **The same property, reached differently since task 11.219.** It used
    // to be the reachability rule: `Tag_Versions` was narrowed by the same
    // `tag_id` set that narrowed `Tags`, so a tag this project did not
    // reference contributed nothing. Both tables are project-scoped now, so
    // it is the ordinary `WHERE project_id = ?` — which is the point of the
    // change, not a weakening of it. Asserted anyway: what a `.zip` carries
    // is the disclosure question, and it must not widen because the
    // mechanism behind it got simpler.
    await seedDriftedProject(db);
    await seed(
      Tables.projects,
      sampleProject(id: 'project-2').toColumns(),
    );
    await seed(
      Tables.tags,
      sampleTag(id: 'tag-other', projectId: 'project-2').toColumns(),
    );
    await seed(
      Tables.tagVersions,
      sampleTagVersion(
        id: 'ver-other',
        tagId: 'tag-other',
        projectId: 'project-2',
      ).toColumns(),
    );

    final backup = await ProjectExporter.collect(
      db,
      'project-1',
      now: DateTime.utc(2026, 10, 5),
    );
    expect(
      backup.rowsFor(Tables.tagVersions).map((r) => r['tag_version_id']),
      isNot(contains('ver-other')),
    );
    expect(
      backup.rowsFor(Tables.tags).map((r) => r['tag_id']),
      isNot(contains('tag-other')),
    );
  });
}

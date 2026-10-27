import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack/data/sync/schema_migrator.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';
import 'backup_builders.dart';

/// **Task 11.239 — an old archive meeting a forked collar.**
///
/// `Tags` is keyed `(tag_id, project_id)`. Task 11.224's fork gave a collar
/// shared by two projects a fresh `tag_id` in the later project, with
/// `lineage_id` still naming the original. A v13 archive of that later
/// project was written before the fork, so its `Tags` row carries the
/// *original* id, and the v14 reader step keys it `(t1, B)`. The device holds
/// `(t2, B)` with `lineage_id = t1`. Task 10.87 reasoned that nothing makes
/// those the same row and both survive; this file is the measurement.
void main() {
  late AppDatabase database;
  late Database db;

  const me = 'user-me';
  const projectB = 'project-B';
  const t1 = 'tag-original';
  const t2 = 'tag-forked-copy';
  final now = DateTime.utc(2026, 9, 13, 10);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    await db.insert(
      Tables.users,
      sampleUser(id: me, email: 'me@example.com').toColumns(),
    );
    await db.insert(
      Tables.projects,
      sampleProject(id: projectB, ownerUserId: me).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(id: 'm-me', projectId: projectB, userId: me)
          .toColumns(),
    );
  });
  tearDown(() async => database.close());

  /// The device after 11.224's fork: project B holds the collar under a fresh
  /// id whose lineage is the original, with one bearing already re-pointed.
  Future<void> deviceHoldsFork() async {
    await db.insert(
      Tables.tags,
      sampleTag(
        id: t2,
        projectId: projectB,
        lineageId: t1,
        copiedAt: now,
        modifiedBy: me,
      ).toColumns(),
    );
    await db.insert(
      Tables.tagVersions,
      sampleTagVersion(id: 'tv-device', projectId: projectB, tagId: t2)
          .toColumns(),
    );
    await db.insert(
      Tables.observations,
      sampleObservation(
        id: 'obs-device',
        projectId: projectB,
        userId: me,
        tagId: t2,
        sessionId: null,
        tagVersionId: 'tv-device',
      ).toColumns(),
    );
  }

  /// A v13 archive of project B: the pre-fork shape. `Tags` has no
  /// `project_id`, `lineage_id` or `copied_at`; `Tag_Versions` has no
  /// `project_id`; the link lives in `Project_Tags`.
  ProjectBackup v13Archive() {
    final tagRow = sampleTag(id: t1, projectId: projectB, modifiedBy: me)
        .toColumns()
      ..remove('project_id')
      ..remove('lineage_id')
      ..remove('copied_at');
    final versionRow =
        sampleTagVersion(id: 'tv-archive', projectId: projectB, tagId: t1)
            .toColumns()
          ..remove('project_id');
    final sync = sampleSync().toColumns();
    return makeBackup(
      {
        Tables.users: [
          sampleUser(id: me, email: 'me@example.com').toColumns(),
        ],
        Tables.projects: [
          sampleProject(id: projectB, ownerUserId: me).toColumns(),
        ],
        Tables.projectMemberships: [
          sampleMembership(id: 'm-me', projectId: projectB, userId: me)
              .toColumns(),
        ],
        Tables.tags: [tagRow],
        Tables.tagVersions: [versionRow],
        Tables.projectTags: [
          {'project_id': projectB, 'tag_id': t1, 'status': 'active', ...sync},
        ],
        Tables.triangulationSessions: [
          sampleSession(id: 'sess-archive', projectId: projectB, tagId: t1)
              .toColumns(),
        ],
        Tables.observations: [
          sampleObservation(
            id: 'obs-archive',
            projectId: projectB,
            userId: me,
            tagId: t1,
            sessionId: 'sess-archive',
            tagVersionId: 'tv-archive',
          ).toColumns(),
        ],
        Tables.estimatedPositions: [
          sampleEstimatedPosition(
            id: 'est-archive',
            projectId: projectB,
            tagId: t1,
          ).toColumns(),
        ],
        Tables.actualTagLocations: [
          sampleActualLocation(
            id: 'loc-archive',
            projectId: projectB,
            tagId: t1,
            tagVersionId: 'tv-archive',
            userId: me,
          ).toColumns(),
        ],
      },
      schemaVersion: 13,
      schemaMajor: 2,
      projectId: projectB,
    );
  }

  Future<MergeReport> import(ProjectBackup backup) => ProjectMerger(db).merge(
        backup,
        importingUserId: me,
        confirmChanges: true,
        now: now,
      );

  Future<List<Map<String, Object?>>> tagsInB() => db.query(
        Tables.tags,
        where: 'project_id = ?',
        whereArgs: [projectB],
        orderBy: 'tag_id',
      );

  Future<int> tagCountIn(String project) async => (await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${Tables.tags} WHERE project_id = ?',
        [project],
      ))
          .first['c'] as int;

  Future<List<String>> tagIdsOf(String table, {String column = 'tag_id'}) async =>
      [
        for (final r in await db.query(table,
            where: 'project_id = ?', whereArgs: [projectB], orderBy: column))
          r[column] as String,
      ];

  group('task 11.239 — the measurement', () {
    // **The finding, kept as the test that would reproduce it.** Before the
    // merger matched by lineage this asserted 2 and printed both ids; it
    // asserts 1 now, and reverting `_matchForkedTags` turns it red with the
    // original count. Watched going red before believing it green.
    test('a v13 archive of project B meeting the fork leaves ONE tag in B, '
        'not two', () async {
      await deviceHoldsFork();
      final report = await import(v13Archive());
      expect(report.wrote, isTrue, reason: report.issues.join('\n'));
      expect(report.tagsMatchedByLineage, 1);
      final tags = await tagsInB();
      expect(tags.map((t) => t['tag_id']), [t2],
          reason: 'the archive\'s (t1, B) was matched onto the device\'s '
              '(t2, B) by their shared lineage, not inserted beside it');
      expect(tags.single['lineage_id'], t1);
    });

    test('the archive\'s bearings, sessions, estimates, truth points and tag '
        'versions all follow onto the device\'s tag', () async {
      await deviceHoldsFork();
      await import(v13Archive());
      expect(await tagIdsOf(Tables.observations), [t2, t2],
          reason: 'obs-archive re-pointed; obs-device already there');
      expect(await tagIdsOf(Tables.triangulationSessions), [t2]);
      expect(await tagIdsOf(Tables.estimatedPositions), [t2]);
      expect(await tagIdsOf(Tables.actualTagLocations), [t2]);
      expect(await tagIdsOf(Tables.tagVersions), [t2, t2],
          reason: 'tv-archive lands under the tag its bearings name');
      // Nothing in project B names the pre-fork id any more.
      for (final table in [
        Tables.observations,
        Tables.triangulationSessions,
        Tables.estimatedPositions,
        Tables.actualTagLocations,
        Tables.tagVersions,
      ]) {
        expect((await tagIdsOf(table)).contains(t1), isFalse, reason: table);
      }
    });

    test('the matched tag keeps the device\'s copied_at; the archive\'s null '
        'does not clear it', () async {
      await deviceHoldsFork();
      await import(v13Archive());
      final tag = (await tagsInB()).single;
      expect(tag['copied_at'], DbCodec.encodeUtc(now));
    });

    test('a "no signal" entry naming the pre-fork id follows the collar too — '
        'through the v15 derivation, not a new one', () async {
      await deviceHoldsFork();
      final archive = v13Archive();
      archive.tables[Tables.nonDetections] = [
        sampleNonDetection(id: 'nd-archive', projectId: projectB, userId: me)
            .toColumns()
          ..['tag_ids_listened_for'] = DbCodec.encodeStringList([t1]),
      ];
      await import(archive);
      final nd = await db.query(Tables.nonDetections,
          where: 'project_id = ?', whereArgs: [projectB]);
      expect(DbCodec.decodeStringList(nd.single['tag_ids_listened_for']),
          [t2]);
    });

    test('the sealed-column obligation still holds with the repair in the '
        'tree', () {
      expect(assertSealedColumnsFeedNoReachability, returnsNormally);
    });
  });

  group('task 11.239 — when there is nothing to match', () {
    test('a device that never forked inserts the archive\'s tag as it is',
        () async {
      final report = await import(v13Archive());
      expect(report.tagsMatchedByLineage, 0);
      expect((await tagsInB()).map((t) => t['tag_id']), [t1]);
      expect(await tagIdsOf(Tables.observations), [t1]);
    });

    test('a tag the device holds under the same id is an ordinary merge, '
        'not a match', () async {
      await db.insert(
        Tables.tags,
        sampleTag(id: t1, projectId: projectB, modifiedBy: me).toColumns(),
      );
      final report = await import(v13Archive());
      expect(report.tagsMatchedByLineage, 0);
      expect((await tagsInB()).map((t) => t['tag_id']), [t1]);
    });

    test('scoped to the row\'s own project: the same lineage held in another '
        'project is not a match — §5.9(b)', () async {
      await db.insert(
        Tables.projects,
        sampleProject(id: 'project-A', ownerUserId: me).toColumns(),
      );
      await db.insert(
        Tables.tags,
        sampleTag(id: t2, projectId: 'project-A', lineageId: t1, modifiedBy: me)
            .toColumns(),
      );
      final report = await import(v13Archive());
      expect(report.tagsMatchedByLineage, 0);
      expect((await tagsInB()).map((t) => t['tag_id']), [t1]);
      expect(await tagCountIn('project-A'), 1);
    });

    test('a sync pull is not matched: the server\'s ids are the server\'s',
        () async {
      await deviceHoldsFork();
      final page = v13Archive();
      // Bring the payload to the current shape by hand, as a server page is.
      SchemaMigrator.migrateToCurrent(page);
      final report = await ProjectMerger(db).merge(
        page,
        origin: MergeOrigin.authenticatedServer,
        importingUserId: me,
        now: now,
      );
      expect(report.tagsMatchedByLineage, 0);
      // The trusted path inserts beside — which is fine only because no
      // server has ever held a tag in two projects (tag_scope_migration's
      // note); this pins the decision rather than endorsing the outcome.
      expect(await tagCountIn(projectB), 2);
    });
  });

  group('task 11.239 — refused rather than guessed at', () {
    test('an archive carrying two tag rows of one lineage in its project is '
        'refused, and nothing is written', () async {
      await deviceHoldsFork();
      final archive = v13Archive();
      // A second pre-fork row that will migrate to the same lineage: v14
      // sets lineage_id = tag_id, so build it post-shape to share t1.
      archive.tables[Tables.tags]!.add(
        sampleTag(id: 'tag-third', projectId: projectB, lineageId: t1,
                modifiedBy: me)
            .toColumns()
          ..remove('project_id')
          ..remove('copied_at'),
      );
      final before = await tagCountIn(projectB);
      await expectLater(
        import(archive),
        throwsA(isA<BackupFormatException>()
            .having((e) => e.message, 'message', forkedTagArchiveRefusal)),
      );
      expect(await tagCountIn(projectB), before);
      expect(await tagIdsOf(Tables.observations), ['tag-forked-copy']);
    });

    test('a device already holding two tags of one lineage in the project '
        'refuses a third rather than picking one', () async {
      await deviceHoldsFork();
      await db.insert(
        Tables.tags,
        sampleTag(id: 'tag-second-copy', projectId: projectB, lineageId: t1,
                modifiedBy: me)
            .toColumns(),
      );
      await expectLater(
        import(v13Archive()),
        throwsA(isA<BackupFormatException>()
            .having((e) => e.message, 'message', forkedTagDeviceRefusal)),
      );
      expect(await tagCountIn(projectB), 2);
    });

    test('both refusal sentences name no id and say what was done', () {
      for (final sentence in [forkedTagArchiveRefusal, forkedTagDeviceRefusal]) {
        expect(sentence, isNot(matches(RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}'))));
        expect(sentence, contains('imported nothing'));
        expect(sentence, contains('unchanged'));
      }
    });
  });
}

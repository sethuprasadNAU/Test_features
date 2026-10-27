import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/sync/project_exporter.dart';

import '../fixtures.dart';

void main() {
  late AppDatabase database;
  late Database db;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
  });
  tearDown(() async => database.close());

  Future<void> insert(String table, Map<String, Object?> columns) =>
      db.insert(table, columns);

  test('collects the whole project including tombstones and reachable globals',
      () async {
    // Two users: owner (user-1) and a contributor (user-2).
    await insert(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
    await insert(Tables.users, sampleUser(id: 'user-2', email: 'b@x.com').toColumns());
    // A prior email for the reachable owner, and one for an unrelated user
    // that must NOT be exported.
    await insert(Tables.userEmails,
        sampleUserEmail(id: 'ue-1', userId: 'user-1', email: 'old-a@x.com').toColumns());
    await insert(Tables.users, sampleUser(id: 'user-unreachable', email: 'z@x.com').toColumns());
    await insert(Tables.userEmails,
        sampleUserEmail(id: 'ue-unreachable', userId: 'user-unreachable', email: 'old-z@x.com')
            .toColumns());
    // Reachable tag + an unreachable one that must NOT be exported.
    await insert(Tables.projects, sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns());
    // **A tag belongs to a project since task 11.219**, so it is seeded
    // after the project it references — and `tag-unused` has to go somewhere
    // too. It goes in a *second* project, which is what makes it the case
    // this test is about: a tag the exported project does not hold.
    await insert(Tables.projects, sampleProject(id: 'project-2', ownerUserId: 'user-1').toColumns());
    await insert(Tables.tags, sampleTag(id: 'tag-1', projectId: 'project-1').toColumns());
    await insert(Tables.tags, sampleTag(id: 'tag-unused', projectId: 'project-2').toColumns());
    await insert(Tables.projectMemberships,
        sampleMembership(id: 'm-2', projectId: 'project-1', userId: 'user-2').toColumns());

    await insert(Tables.observations,
        sampleObservation(sessionId: null, id: 'obs-1', projectId: 'project-1', userId: 'user-1', tagId: 'tag-1').toColumns());
    // A soft-deleted observation must travel in the backup (else it resurrects).
    final tombstoned = sampleObservation(sessionId: null, 
      id: 'obs-del',
      projectId: 'project-1',
      userId: 'user-2',
      tagId: 'tag-1',
    ).copyWith(
      sync: sampleSync().copyWith(revision: 2, deletedAt: DateTime.utc(2026, 7, 17)),
    );
    await insert(Tables.observations, tombstoned.toColumns());

    // A second project whose rows must be excluded. Its bearing names that
    // project's own tag — since task 11.219 a bearing and the tag it names
    // are in the same project by construction, which is exactly why this
    // exporter no longer needs a reachability pass for tags.
    await insert(Tables.observations,
        sampleObservation(sessionId: null, id: 'obs-other', projectId: 'project-2', userId: 'user-1', tagId: 'tag-unused').toColumns());

    final backup = await ProjectExporter.collect(
      db,
      'project-1',
      now: DateTime.utc(2026, 7, 17, 12),
    );

    // Only project-1.
    expect(backup.rowsFor(Tables.projects).map((r) => r['project_id']),
        ['project-1']);
    // Both observations, including the tombstone; nothing from project-2.
    final obsIds = backup.rowsFor(Tables.observations).map((r) => r['observation_id']).toSet();
    expect(obsIds, {'obs-1', 'obs-del'});
    expect(
        backup.rowsFor(Tables.observations).firstWhere((r) => r['observation_id'] == 'obs-del')['deleted_at'],
        isNotNull);
    // Reachable users (owner + contributor + observers); unreachable tag absent.
    expect(backup.rowsFor(Tables.users).map((r) => r['user_id']).toSet(), {'user-1', 'user-2'});
    expect(backup.rowsFor(Tables.tags).map((r) => r['tag_id']).toSet(), {'tag-1'});
    // The reachable owner's prior email travels; the unreachable user's does not.
    // Task 11.30: prior addresses are **withheld** from an archive, however
    // reachable they are. `ue-1` belongs to a user this project references and
    // would have travelled under the old rule; nothing in this app has ever
    // displayed a prior address, so the archive somebody emails to a colleague
    // no longer carries their team's old email addresses. See
    // `test/security/archive_disclosure_test.dart`.
    expect(backup.rowsFor(Tables.userEmails), isEmpty);
    // Manifest counts reflect the payload.
    expect(backup.manifest.rowCounts[Tables.observations], 2);
    expect(backup.manifest.projectName, 'Mesa Coyotes');
  });

  test('an empty project exports just its own row', () async {
    await insert(Tables.users, sampleUser(id: 'user-1').toColumns());
    await insert(Tables.projects, sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns());

    final backup = await ProjectExporter.collect(db, 'project-1', now: DateTime.utc(2026));
    expect(backup.rowsFor(Tables.projects), hasLength(1));
    // The owner is reachable via owner_user_id.
    expect(backup.rowsFor(Tables.users).map((r) => r['user_id']), ['user-1']);
    expect(backup.rowsFor(Tables.observations), isEmpty);
  });
}

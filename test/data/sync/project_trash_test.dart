import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/sync/project_trash.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.339, item 1 — the Trash holds a project that never reached a
/// server.**
///
/// Before this task a project moved to the Trash on a phone that had never
/// published it was hidden after the six-second UNDO and appeared nowhere:
/// the Projects screen's Trash section listed only what a **server** still
/// held. These are the data-layer claims behind the new rows:
///
/// 1. **What is listed**: a project this person moved to the Trash that this
///    phone does not sync. Not a live project, not one this phone still syncs
///    (that one is the server's, or is waiting to be sent), and not one
///    somebody else's tombstone put there.
/// 2. **Restore** clears the mark and every record comes back, untouched.
/// 3. **Delete permanently** removes the project and every row scoped to it
///    from this phone — and nothing else: another project's rows and the
///    person's Tag Library stay.
/// 4. **It refuses anything outside that list**, so a stale screen cannot
///    erase a project that is live, synced, or somebody else's tombstone.
///
/// "Project `local`" is the one moved to the Trash; "project `other`" is a
/// live neighbor holding the same record ids (keys are `(id, project_id)`),
/// so a delete that forgot its `WHERE project_id` would empty both.
void main() {
  late AppDatabase database;
  late Database db;
  const me = 'user-1';
  const local = 'project-local';
  const other = 'project-other';

  /// Every project-scoped table the app syncs, in the order the merger
  /// inserts — the census the permanent delete has to empty.
  final scoped = [
    for (final t in syncTables)
      if (t.projectScopeColumn != null) t,
  ];

  Future<int> rowsIn(String table, String projectId) async =>
      (await db.rawQuery(
                'SELECT COUNT(*) AS c FROM $table WHERE project_id = ?',
                [projectId],
              )).first['c']
              as int;

  Future<void> seedProject(String projectId) async {
    await db.insert(
      Tables.projects,
      sampleProject(id: projectId, ownerUserId: me).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(projectId: projectId, userId: me).toColumns(),
    );
    await db.insert(
      Tables.individuals,
      sampleIndividual(projectId: projectId).toColumns(),
    );
    await db.insert(Tables.tags, sampleTag(projectId: projectId).toColumns());
    await db.insert(
      Tables.deployments,
      sampleDeployment(projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.tagVersions,
      sampleTagVersion(projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.triangulationSessions,
      sampleSession(projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.observations,
      sampleObservation(projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.nonDetections,
      sampleNonDetection(projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.estimatedPositions,
      sampleEstimatedPosition(projectId: projectId).toColumns(),
    );
    await db.insert(
      Tables.actualTagLocations,
      sampleActualLocation(projectId: projectId).toColumns(),
    );
    final stamp = DateTime.utc(2026, 1, 1).toIso8601String();
    await db.insert(Tables.observationExclusions, {
      'exclusion_id': 'excl-1',
      'project_id': projectId,
      'observation_id': 'obs-1',
      'user_id': me,
      'kind': 'excluded',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 1,
      'last_modified_by': me,
      'origin_device_id': 'device-A',
    });
  }

  Future<void> moveToTrash(String projectId, {String by = me}) =>
      ProjectRepository(db).softDeleteById(
        projectId,
        actor: MutationActor.user(by),
        deviceId: 'device-A',
      );

  Future<List<TrashedHere>> listed({Set<String> linked = const {}}) =>
      ProjectTrash.onThisDevice(
        db,
        userId: me,
        isLinked: (id) async => linked.contains(id),
      );

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    await db.insert(Tables.users, sampleUser(id: me).toColumns());
    await db.insert(
      Tables.users,
      sampleUser(id: 'user-2', email: 'two@example.com').toColumns(),
    );
    await seedProject(local);
    await seedProject(other);
    await TagLibraryRepository(db).insert(
      sampleTagLibraryEntry(id: 'lib-1', lineageId: 'l-1', tagName: 'Kept'),
    );
  });

  tearDown(() => database.close());

  group('what the Trash lists from this phone', () {
    test('WATCHED RED: a project moved to the Trash that never reached a '
        'server is listed, with its name and the day it was moved', () async {
      await moveToTrash(local);
      final rows = await listed();
      expect(rows.map((r) => r.projectId), [local]);
      expect(rows.single.projectName, 'Mesa Coyotes');
      expect(rows.single.deletedAt, isNotNull);
      expect(
        rows.single.everOnServer,
        isFalse,
        reason: 'no row of it was ever confirmed by a server',
      );
    });

    test('a project this phone still syncs is not listed here — the server '
        'lists it, or it is waiting to be sent', () async {
      await moveToTrash(local);
      expect(await listed(linked: {local}), isEmpty);
    });

    test('a live project is not listed', () async {
      expect(await listed(), isEmpty);
    });

    test('a tombstone somebody else wrote is not listed', () async {
      // Written as user-2: what an arriving tombstone from another person
      // looks like on this phone.
      await db.rawUpdate(
        'UPDATE ${Tables.projects} SET deleted_at = ?, last_modified_by = ? '
        'WHERE project_id = ?',
        [DateTime.utc(2026, 10, 1).toIso8601String(), 'user-2', local],
      );
      expect(await listed(), isEmpty);
    });

    test('a project that once reached a server and no longer syncs here is '
        'listed, and says so', () async {
      await SyncRowReceiptStore.ensureTable(db);
      await SyncRowReceiptStore(db).record(
        projectId: local,
        tableName: Tables.projects,
        rowKey: local,
        ackedUpdatedAt: '2026-01-01T00:00:00.000Z',
        at: DateTime.utc(2026, 1, 1),
      );
      await moveToTrash(local);
      expect((await listed()).single.everOnServer, isTrue);
    });
  });

  group('Restore', () {
    test('WATCHED RED: clears the mark, and every record is still there',
        () async {
      final before = {for (final t in scoped) t.name: await rowsIn(t.name, local)};
      await moveToTrash(local);
      expect(
        {for (final t in scoped) t.name: await rowsIn(t.name, local)},
        before,
        reason: 'moving to the Trash marks the project; it removes no record',
      );
      expect(await ProjectTrash.restore(db, local, userId: me), 1);
      final project = await ProjectRepository(db).findById(local);
      expect(project, isNotNull, reason: 'back in the list of live projects');
      expect(
        {for (final t in scoped) t.name: await rowsIn(t.name, local)},
        before,
      );
      expect(await listed(), isEmpty);
    });

    test('works for somebody who has left the project, under the same '
        'exemption that let them move it to the Trash', () async {
      await db.rawUpdate(
        'UPDATE ${Tables.projectMemberships} SET end_date = ? '
        'WHERE project_id = ?',
        [DateTime.utc(2026, 5, 1).toIso8601String(), local],
      );
      await db.rawUpdate(
        'UPDATE ${Tables.projects} SET owner_user_id = ? WHERE project_id = ?',
        ['user-2', local],
      );
      await ProjectRepository(db).softDeleteById(
        local,
        actor: MutationActor.user(me),
        deviceId: 'device-A',
        exemption: MutationExemption.departedMember(local),
      );
      expect(await ProjectTrash.restore(db, local, userId: me), 1);
    });
  });

  group('Delete permanently, from this phone', () {
    test('WATCHED RED: removes the project and every row scoped to it, and '
        'nothing of any other project or of the Tag Library', () async {
      final otherBefore = {
        for (final t in scoped) t.name: await rowsIn(t.name, other),
      };
      expect(otherBefore.values.every((n) => n > 0), isTrue,
          reason: 'the neighbor holds a row in every table, so the check '
              'below can see a missing WHERE clause');
      await SyncHeldRowStore.ensureTable(db);
      await SyncRowReceiptStore.ensureTable(db);
      await SyncRowReceiptStore(db).record(
        projectId: local,
        tableName: Tables.observations,
        rowKey: 'obs-1',
        ackedUpdatedAt: '2026-01-01T00:00:00.000Z',
        at: DateTime.utc(2026, 1, 1),
      );
      await moveToTrash(local);

      final removed = await ProjectTrash.deletePermanently(
        db,
        local,
        userId: me,
        isLinked: false,
      );
      expect(removed, greaterThan(scoped.length - 1));
      for (final t in scoped) {
        expect(await rowsIn(t.name, local), 0, reason: '${t.name} emptied');
      }
      expect(await SyncRowReceiptStore(db).count(local), 0,
          reason: "this phone's bookkeeping for it goes too");
      expect(
        {for (final t in scoped) t.name: await rowsIn(t.name, other)},
        otherBefore,
        reason: 'another project is untouched',
      );
      expect(
        (await TagLibraryRepository(db).findAll()).map((e) => e.tagName),
        ['Kept'],
        reason: "the person's Tag Library is theirs, not the project's",
      );
      expect(await listed(), isEmpty);
    });

    test('refuses a project that is not in the Trash, and changes nothing',
        () async {
      await expectLater(
        ProjectTrash.deletePermanently(db, local, userId: me, isLinked: false),
        throwsA(isA<NotInThisPhonesTrash>()),
      );
      expect(await rowsIn(Tables.observations, local), 1);
    });

    test('refuses a project this phone still syncs, and changes nothing',
        () async {
      await moveToTrash(local);
      await expectLater(
        ProjectTrash.deletePermanently(db, local, userId: me, isLinked: true),
        throwsA(isA<NotInThisPhonesTrash>()),
      );
      expect(await rowsIn(Tables.observations, local), 1);
    });

    test('refuses a tombstone somebody else wrote, and changes nothing',
        () async {
      await db.rawUpdate(
        'UPDATE ${Tables.projects} SET deleted_at = ?, last_modified_by = ? '
        'WHERE project_id = ?',
        [DateTime.utc(2026, 10, 1).toIso8601String(), 'user-2', local],
      );
      await expectLater(
        ProjectTrash.deletePermanently(db, local, userId: me, isLinked: false),
        throwsA(isA<NotInThisPhonesTrash>()),
      );
      expect(await rowsIn(Tables.observations, local), 1);
    });
  });
}

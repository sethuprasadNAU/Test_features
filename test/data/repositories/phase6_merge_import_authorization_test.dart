import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/data/sharing/shared_observation_importer.dart';
import 'package:tritrack/data/sync/project_merger.dart';

import '../fixtures.dart';
import '../sync/backup_builders.dart';

/// Task 8.5's explicit Phase 6 regression guard: task 8.1 added repository-
/// layer authorization, and `ProjectMerger`/`SharedObservationImporter` are
/// the two places that legitimately write rows authored by someone other
/// than whoever is using this device. Each test below proves *both* halves
/// of that guarantee for the same row — merge/import still writes it, and
/// the ordinary authorized path (`ObservationRepository`) still refuses to —
/// so the exemption is confirmed narrow, not a hole that also weakened the
/// authorization it's exempt from.
///
/// Both `ProjectMerger` and `SharedObservationImporter` write through raw
/// `DatabaseExecutor` statements in their own transaction rather than through
/// `BaseRepository` (see their class docs), which is *why* they're immune to
/// begin with — this is what proves that immunity behaviorally rather than
/// only by code inspection.
void main() {
  late AppDatabase database;
  late Database db;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
  });
  tearDown(() async => database.close());

  group('ProjectMerger', () {
    test(
        'merges in an observation authored by a different user, which the '
        'authorized repository path still refuses to let a local user touch',
        () async {
      // The local device: user-1 owns project-1 and everything on it so far.
      await db.insert(Tables.users, sampleUser(id: 'user-1', email: 'a@x.com').toColumns());
      await db.insert(
          Tables.projects, sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns());
      await db.insert(Tables.tags, sampleTag(id: 'tag-1').toColumns());

      // The incoming backup: user-2's own observation, from their device.
      final incomingUser = sampleUser(id: 'user-2', email: 'b@x.com');
      final incomingObservation = sampleObservation(
        id: 'obs-remote',
        projectId: 'project-1',
        userId: 'user-2',
        sessionId: null,
      );

      final report = await ProjectMerger(db).merge(makeBackup({
        Tables.users: [
          sampleUser(id: 'user-1', email: 'a@x.com').toColumns(),
          incomingUser.toColumns(),
        ],
        Tables.projects: [sampleProject(id: 'project-1', ownerUserId: 'user-1').toColumns()],
        Tables.observations: [incomingObservation.toColumns()],
      }));

      expect(report.statsFor(Tables.observations).inserted, 1);
      final rows = await db.query(Tables.observations, where: 'observation_id = ?', whereArgs: ['obs-remote']);
      expect(rows.single['user_id'], 'user-2');

      // Contrast: the same row, reached the ordinary way, is still protected.
      final observations = ObservationRepository(db);
      await expectLater(
        observations.update(
          incomingObservation.copyWith(notes: 'edited by someone else'),
          actor: const MutationActor.user('user-1'),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });
  });

  group('SharedObservationImporter', () {
    test(
        'saves a replica authored by the sender, which the authorized '
        'repository path still refuses to let the receiving user touch',
        () async {
      const receivingUserId = 'user-bob';
      const receivingDeviceId = 'device-B';
      await db.insert(Tables.users,
          sampleUser(id: receivingUserId, email: 'bob@example.com').toColumns());
      await db.insert(Tables.projects,
          sampleProject(id: 'project-local', ownerUserId: receivingUserId).toColumns());
      await db.insert(
      Tables.tags,
      sampleTag(id: 'tag-local', projectId: 'project-local').toColumns(),
    );

      final sent = sampleObservation(
        id: 'obs-alice',
        userId: 'user-alice',
        sessionId: 'session-alice',
      ).copyWith(
        sync: sampleSync().copyWith(
          revision: 3,
          lastModifiedBy: 'user-alice',
          originDeviceId: 'device-A',
        ),
      );
      final payload = ObservationShare.encode(
        sent,
        tag: sampleTag(id: 'tag-alice'),
        observer: sampleUser(id: 'user-alice', email: 'alice@example.com'),
      );

      final result = await SharedObservationImporter(db).save(
        ObservationShare.decode(payload),
        projectId: 'project-local',
        tagId: 'tag-local',
        receivingUserId: receivingUserId,
        receivingDeviceId: receivingDeviceId,
        newId: () => 'minted-id',
        now: DateTime.utc(2026, 7, 31),
      );

      expect(result.outcome, SharedObservationImportOutcome.replicaInserted);
      expect(result.observerUserId, 'user-alice');
      final rows = await db.query(Tables.observations,
          where: 'observation_id = ?', whereArgs: [result.observationId]);
      expect(rows.single['user_id'], 'user-alice');

      // Contrast: the same replica, reached the ordinary way, is still
      // protected from the *receiving* user — the whole point of task 6.3
      // (a replica must stay read-only to everyone but its original author)
      // and exactly the failure mode task 8.1 closed for the map screen.
      final observations = ObservationRepository(db);
      final replica = (await observations.findById(result.observationId,
          projectId: 'project-local'))!;
      await expectLater(
        observations.update(
          replica.copyWith(notes: 'edited by the receiver'),
          actor: const MutationActor.user(receivingUserId),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });
  });
}

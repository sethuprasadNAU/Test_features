import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/data/sharing/shared_observation_importer.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';

import '../fixtures.dart';

/// Task 6.4: end-to-end coverage of the Phase 6 correctness properties
/// (encode -> decode -> save -> re-export, and the specific duplication
/// regression the phase exists to fix), exercised across two independent
/// in-memory databases standing in for two devices.
///
/// The narrower per-field properties (identity/clock preservation, email
/// dedup, mismatched-id handling, LWW in both directions, v1 fallback) are
/// already covered against the importer directly in
/// `shared_observation_importer_test.dart`; this file adds the properties
/// that only show up once a full device round-trip is in play.
void main() {
  late AppDatabase aliceDb; // The sender: this is where the observation lives.
  late AppDatabase bobDb; // The receiver: pastes Alice's share payload.

  setUp(() async {
    aliceDb = await AppDatabase.openInMemory();
    bobDb = await AppDatabase.openInMemory();
  });
  tearDown(() async {
    await aliceDb.close();
    await bobDb.close();
  });

  /// Seeds one project + tag + the named user on [db].
  Future<void> seedProjectAndTag(
    AppDatabase db, {
    required String projectId,
    required String ownerUserId,
    required String tagId,
  }) async {
    await db.raw.insert(Tables.users,
        sampleUser(id: ownerUserId, email: '$ownerUserId@example.com').toColumns());
    await db.raw.insert(
        Tables.projects, sampleProject(id: projectId, ownerUserId: ownerUserId).toColumns());
    await db.raw.insert(
      Tables.tags,
      sampleTag(id: tagId, projectId: projectId).toColumns(),
    );
  }

  test(
      'encode -> decode -> save round-trips identity, provenance, and the sync '
      'clock exactly, and the save is visible in a project re-export', () async {
    await seedProjectAndTag(aliceDb,
        projectId: 'project-alice', ownerUserId: 'user-alice', tagId: 'tag-alice');
    final aliceObservation = sampleObservation(
      id: 'obs-shared',
      projectId: 'project-alice',
      userId: 'user-alice',
      tagId: 'tag-alice',
      sessionId: null,
    ).copyWith(
      positionAccuracyM: 6.25,
      notes: 'strong steady pulse',
      sync: sampleSync().copyWith(revision: 2, updatedAt: DateTime.utc(2026, 7, 21, 8, 0, 0)),
    );
    await aliceDb.raw.insert(Tables.observations, aliceObservation.toColumns());
    final alice = (await aliceDb.raw
            .query(Tables.users, where: 'user_id = ?', whereArgs: ['user-alice']))
        .map(User.fromRow)
        .single;

    final payload = ObservationShare.encode(
      aliceObservation,
      tag: sampleTag(id: 'tag-alice'),
      observer: alice,
    );

    // Bob receives and parses it.
    final shared = ObservationShare.decode(payload);
    expect(shared.canReplicate, isTrue);

    // Bob's device: his own project/tag, distinct ids from Alice's.
    await seedProjectAndTag(bobDb, projectId: 'project-bob', ownerUserId: 'user-bob', tagId: 'tag-bob');

    final result = await SharedObservationImporter(bobDb.raw).save(
      shared,
      projectId: 'project-bob',
      tagId: 'tag-bob',
      receivingUserId: 'user-bob',
      receivingDeviceId: 'device-bob',
      newId: () => 'unused',
      now: DateTime.utc(2026, 7, 31, 12, 0, 0),
    );
    expect(result.outcome, SharedObservationImportOutcome.replicaInserted);

    final saved = (await bobDb.raw
            .query(Tables.observations, where: 'observation_id = ?', whereArgs: ['obs-shared']))
        .map(Observation.fromRow)
        .single;

    // Identity and provenance match the original exactly.
    expect(saved.observationId, aliceObservation.observationId);
    expect(saved.userId, aliceObservation.userId);
    expect(saved.positionSource, aliceObservation.positionSource);
    expect(saved.positionAccuracyM, aliceObservation.positionAccuracyM);
    // The sync clock is the sender's, not a fresh one stamped at save time.
    expect(saved.sync.revision, aliceObservation.sync.revision);
    expect(saved.sync.createdAt, aliceObservation.sync.createdAt);
    expect(saved.sync.updatedAt, aliceObservation.sync.updatedAt);
    expect(saved.sync.originDeviceId, aliceObservation.sync.originDeviceId);
    // `last_modified_by` is the one clock column NOT copied verbatim, since
    // task 10.61: it names the observer this device resolved rather than
    // whatever the payload claimed. In finding J-1 the payload set it to the
    // *victim*, so the row recorded its own destruction as the victim's edit.
    // The cost is a small loss of fidelity when a sender's row was genuinely
    // last touched by a third party; the alternative is a forgeable audit
    // column, which is not a trade worth making.
    expect(saved.sync.lastModifiedBy, saved.userId);
    // Content came through too.
    expect(saved.notes, 'strong steady pulse');
    // But it's bound into Bob's local project/tag, not Alice's.
    expect(saved.projectId, 'project-bob');
    expect(saved.tagId, 'tag-bob');

    // Re-exporting Bob's project surfaces the replica with the same identity
    // — a later merge elsewhere would recognize it as the same row.
    final backup = await ProjectExporter.collect(bobDb.raw, 'project-bob', now: DateTime.utc(2026, 8, 1));
    final exportedObs = backup.rowsFor(Tables.observations).single;
    expect(exportedObs['observation_id'], 'obs-shared');
    expect(exportedObs['user_id'], 'user-alice');
    expect(exportedObs['revision'], aliceObservation.sync.revision);
  });

  test(
      'the duplication regression: two devices independently saving one shared '
      'observation converge to a single row once their data is merged together',
      () async {
    // Alice observes something and shares it with both Bob and Carol.
    await seedProjectAndTag(aliceDb,
        projectId: 'project-shared', ownerUserId: 'user-alice', tagId: 'tag-shared');
    final aliceObservation = sampleObservation(
      id: 'obs-triangulated',
      projectId: 'project-shared',
      userId: 'user-alice',
      tagId: 'tag-shared',
      sessionId: null,
    );
    await aliceDb.raw.insert(Tables.observations, aliceObservation.toColumns());
    final alice = (await aliceDb.raw
            .query(Tables.users, where: 'user_id = ?', whereArgs: ['user-alice']))
        .map(User.fromRow)
        .single;
    final payload = ObservationShare.encode(aliceObservation,
        tag: sampleTag(id: 'tag-shared'), observer: alice);

    // Bob and Carol are two independent devices, each with their own project
    // (a common real setup: a shared tag but per-observer project bookkeeping
    // isn't assumed here — what matters is each device saves the payload with
    // no knowledge of the other).
    final carolDb = await AppDatabase.openInMemory();
    addTearDown(carolDb.close);
    await seedProjectAndTag(bobDb, projectId: 'project-bob', ownerUserId: 'user-bob', tagId: 'tag-bob');
    await seedProjectAndTag(carolDb,
        projectId: 'project-carol', ownerUserId: 'user-carol', tagId: 'tag-carol');

    await SharedObservationImporter(bobDb.raw).save(
      ObservationShare.decode(payload),
      projectId: 'project-bob',
      tagId: 'tag-bob',
      receivingUserId: 'user-bob',
      receivingDeviceId: 'device-bob',
      newId: () => 'unused',
      now: DateTime.utc(2026, 7, 31, 12, 0, 0),
    );
    await SharedObservationImporter(carolDb.raw).save(
      ObservationShare.decode(payload),
      projectId: 'project-carol',
      tagId: 'tag-carol',
      receivingUserId: 'user-carol',
      receivingDeviceId: 'device-carol',
      newId: () => 'unused',
      now: DateTime.utc(2026, 7, 31, 12, 0, 0),
    );

    // Now the two backups meet on a third device via ProjectMerger — the
    // real mechanism last-write-wins convergence runs through. Before task
    // 6.2/6.3, this is exactly the scenario that produced two permanently
    // duplicate rows for one real observation: each save minted its own UUID,
    // so nothing about them looked like a conflict to merge.
    final bobBackup =
        await ProjectExporter.collect(bobDb.raw, 'project-bob', now: DateTime.utc(2026, 8, 1));
    final carolBackup = await ProjectExporter.collect(carolDb.raw, 'project-carol',
        now: DateTime.utc(2026, 8, 1));

    final mergedDb = await AppDatabase.openInMemory();
    addTearDown(mergedDb.close);
    await ProjectMerger(mergedDb.raw).merge(bobBackup);
    // Carol's archive replaces something Bob's already put here: both carry a
    // `Users` row for Alice, and each device stamped it with its own
    // `origin_device_id` and `created_at`. That is an honest divergence, and
    // §4.19 rule 4 (task 10.73) still holds it at the door — which is the
    // point. The gate does not ask whether a change is hostile, only whether it
    // replaces something the device already holds; one that tried to tell the
    // two apart would be guessing.
    await ProjectMerger(mergedDb.raw).merge(carolBackup, confirmChanges: true);

    final rows = await mergedDb.raw.query(Tables.observations,
        where: 'observation_id = ?', whereArgs: ['obs-triangulated']);

    // One row *per project*, not one row overall — and this assertion was
    // inverted before task 10.35.
    //
    // Bob and Carol imported into two different projects, so there are
    // genuinely two records here: `project-bob`'s copy of Alice's observation
    // and `project-carol`'s. When primary keys were global, the merger keyed
    // on `observation_id` alone, so the second merge *overwrote* the first and
    // this test asserted `hasLength(1)` and passed. What that actually meant is
    // that one of the two projects silently lost its observation entirely —
    // the old assertion never checked which `project_id` survived, so the loss
    // was invisible to it. That is the same silent-loss shape as D-3, arriving
    // through the merge path instead of the sync path.
    //
    // Convergence is still a real guarantee; it is just scoped to a project,
    // which is the only scope in which it means anything. The case below
    // exercises it.
    expect(rows, hasLength(2),
        reason: 'two projects each hold their own copy of the shared '
            'observation; collapsing them would delete one project\'s record');
    expect(
      rows.map((r) => r['project_id']).toSet(),
      {'project-bob', 'project-carol'},
    );
    expect(rows.every((r) => r['user_id'] == 'user-alice'), isTrue,
        reason: 'both copies still attribute the observation to Alice');
  });

  test(
      'the duplication regression: two devices importing one shared observation '
      'into the SAME project converge to a single row', () async {
    // The Phase 6.2/6.3 guarantee proper. Before those tasks each import minted
    // a fresh UUID, so two devices saving one real observation produced two
    // permanently distinct rows that nothing could ever reconcile. Preserving
    // the sender's `observation_id` is what makes them recognizable as the same
    // row — and since task 10.35 the key that has to match is
    // `(observation_id, project_id)`, so this only converges when the importers
    // agree on the project. They do here, which is the case that matters: it is
    // what happens once a project is published and joined (task 10.9).
    await seedProjectAndTag(aliceDb,
        projectId: 'project-shared',
        ownerUserId: 'user-alice',
        tagId: 'tag-shared');
    final aliceObservation = sampleObservation(
      id: 'obs-triangulated',
      projectId: 'project-shared',
      userId: 'user-alice',
      tagId: 'tag-shared',
      sessionId: null,
    );
    await aliceDb.raw.insert(Tables.observations, aliceObservation.toColumns());
    final alice = (await aliceDb.raw.query(Tables.users,
            where: 'user_id = ?', whereArgs: ['user-alice']))
        .map(User.fromRow)
        .single;
    final payload = ObservationShare.encode(aliceObservation,
        tag: sampleTag(id: 'tag-shared'), observer: alice);

    // Both devices hold the *same* project and tag — the published/joined case.
    final carolDb = await AppDatabase.openInMemory();
    addTearDown(carolDb.close);
    await seedProjectAndTag(bobDb,
        projectId: 'project-joint',
        ownerUserId: 'user-bob',
        tagId: 'tag-joint');
    await seedProjectAndTag(carolDb,
        projectId: 'project-joint',
        ownerUserId: 'user-bob',
        tagId: 'tag-joint');

    await SharedObservationImporter(bobDb.raw).save(
      ObservationShare.decode(payload),
      projectId: 'project-joint',
      tagId: 'tag-joint',
      receivingUserId: 'user-bob',
      receivingDeviceId: 'device-bob',
      newId: () => 'unused',
      now: DateTime.utc(2026, 7, 31, 12, 0, 0),
    );
    await SharedObservationImporter(carolDb.raw).save(
      ObservationShare.decode(payload),
      projectId: 'project-joint',
      tagId: 'tag-joint',
      receivingUserId: 'user-carol',
      receivingDeviceId: 'device-carol',
      now: DateTime.utc(2026, 7, 31, 12, 0, 0),
      newId: () => 'unused',
    );

    final bobBackup = await ProjectExporter.collect(bobDb.raw, 'project-joint',
        now: DateTime.utc(2026, 8, 1));
    final carolBackup = await ProjectExporter.collect(
        carolDb.raw, 'project-joint',
        now: DateTime.utc(2026, 8, 1));

    final mergedDb = await AppDatabase.openInMemory();
    addTearDown(mergedDb.close);
    await ProjectMerger(mergedDb.raw).merge(bobBackup);
    // Carol's archive replaces something Bob's already put here: both carry a
    // `Users` row for Alice, and each device stamped it with its own
    // `origin_device_id` and `created_at`. That is an honest divergence, and
    // §4.19 rule 4 (task 10.73) still holds it at the door — which is the
    // point. The gate does not ask whether a change is hostile, only whether it
    // replaces something the device already holds; one that tried to tell the
    // two apart would be guessing.
    await ProjectMerger(mergedDb.raw).merge(carolBackup, confirmChanges: true);

    final rows = await mergedDb.raw.query(Tables.observations,
        where: 'observation_id = ?', whereArgs: ['obs-triangulated']);
    expect(rows, hasLength(1),
        reason: 'the Phase 6 bug: independent replica saves into one project '
            'must converge, not silently duplicate the shared observation');
    expect(rows.single['user_id'], 'user-alice');
    expect(rows.single['project_id'], 'project-joint');
  });
}

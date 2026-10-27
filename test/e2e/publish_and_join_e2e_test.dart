@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/project_joiner.dart';
import 'package:tritrack/data/sync/project_publisher.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// Task 10.17: task 10.9's publish/join over the actual wire, including the
/// idempotent re-publish the acceptance criteria call out by name.
void main() {
  group('publish and join over real HTTP', skip: e2eSkipReason, () {
    late E2eDevice owner;
    late String email;
    late String projectId;
    final now = DateTime.utc(2026, 8, 2, 12);

    setUp(() async {
      email = randomEmail();
      owner = await E2eDevice.create();
      await owner.signIn(email);
      projectId = 'e2e-proj-${randomId()}';
      await seedLocalProject(
        owner.db.raw,
        projectId: projectId,
        ownerId: owner.userId,
        deviceId: owner.deviceId,
        now: now,
      );
      await owner.db.raw.insert(
        Tables.observations,
        observationRow(
          'e2e-obs-${randomId()}',
          projectId: projectId,
          userId: owner.userId,
          deviceId: owner.deviceId,
          now: now,
        ),
      );
    });


    ProjectPublisher publisherFor(E2eDevice device) => ProjectPublisher(
      db: device.db.raw,
      transport: device.transport(),
      state: device.state,
      deviceId: device.deviceId,
      userId: device.userId,
    );

    test('publishing an offline project uploads it completely', () async {
      final report = await publisherFor(owner).publish(projectId, now: now);

      expect(report.alreadyLinked, isFalse);
      expect(report.rowsUploaded, greaterThan(0));
      expect(await owner.state.isProjectLinked(projectId), isTrue);
    });

    /// **Task 11.43, reopened; generalised by task 11.118.**
    ///
    /// This used to be a local helper one test opted into, and the comment
    /// here said plainly that *"the other tests in this file publish a
    /// project with no tag, which is why the whole e2e suite stayed green
    /// while this was broken on real hardware."* Task 11.118 measured that
    /// across the repository — seventeen of nineteen publish fixtures had no
    /// tag — and moved the tag into `seedLocalProject`, so it is now the
    /// default for **every** test in this file and in every other e2e file
    /// that seeds a project. The case below stays because it is the one that
    /// asserts the outcome directly.
    test('a first publish of a project with a tag refuses nothing', () async {

      final report = await publisherFor(owner).publish(projectId, now: now);

      expect(
        report.refused,
        isEmpty,
        reason:
            'a refusal here is the banner and the "not a case the app expects" '
            'card, on the first thing this person ever does with a server',
      );
      expect(report.everythingReachedTheServer, isTrue);
      // And nothing is held on the device either — the two are separate
      // statements, and it was the held row that persisted for four minutes.
      expect(
        await SyncEngine.heldRowCount(owner.db.raw, projectId),
        0,
        reason: 'nothing may be waiting after a publish that refused nothing',
      );
    });

    /// **Task 11.118.** Six of the thirteen synced tables had never been
    /// through a publish in any test in this repository. This is the one
    /// whose shape makes that a risk rather than merely a gap: a truth point
    /// is the only row in `syncTables` that is `anyUser` (so §4.17 permits a
    /// foreign edit stamp) **and** carries an identity column naming who
    /// found it **and** carries a `tag_id` that must already be reachable.
    /// All three rules meet on one row, and no publish had ever sent one.
    test('a first publish carrying a truth point refuses nothing', () async {
      final tagId = (await owner.db.raw.query(
        Tables.tags,
        columns: ['tag_id'],
      )).single['tag_id']! as String;
      await owner.db.raw.insert(
        Tables.actualTagLocations,
        truthPointRow(
          'e2e-trp-${randomId()}',
          projectId: projectId,
          tagId: tagId,
          userId: owner.userId,
          deviceId: owner.deviceId,
          now: now,
        ),
      );

      final report = await publisherFor(owner).publish(projectId, now: now);

      expect(
        report.refused,
        isEmpty,
        reason:
            'a truth point is an ordinary thing to have recorded before the '
            'first publish, and refusing one shows the red banner',
      );
      expect(report.everythingReachedTheServer, isTrue);
      expect(await SyncEngine.heldRowCount(owner.db.raw, projectId), 0);
    });

    test('publishing twice is idempotent — no duplicate project', () async {
      await publisherFor(owner).publish(projectId, now: now);
      final second = await publisherFor(owner).publish(projectId, now: now);

      expect(second.alreadyLinked, isTrue);
      expect(second.rowsUploaded, 0);
    });

    test('a second device joins and converges to the owner\'s state', () async {
      await publisherFor(owner).publish(projectId, now: now);

      final second = await E2eDevice.create();
      addTearDown(second.close);
      await second.signIn(email);

      final available = await ProjectDirectoryClient(
        db: second.db.raw,
        transport: second.transport(),
        state: second.state,
      ).listAvailableToJoin();
      expect(available.map((p) => p.projectId), contains(projectId));

      await ProjectJoiner(
        db: second.db.raw,
        transport: second.transport(),
        state: second.state,
        deviceId: second.deviceId,
        userId: second.userId,
      ).join(projectId);

      final rows = await second.db.raw.query(
        Tables.observations,
        where: 'project_id = ?',
        whereArgs: [projectId],
      );
      expect(rows, hasLength(1));
      expect(await second.state.isProjectLinked(projectId), isTrue);
    });

    test('a joined project no longer appears in listAvailableToJoin', () async {
      await publisherFor(owner).publish(projectId, now: now);

      final second = await E2eDevice.create();
      addTearDown(second.close);
      await second.signIn(email);
      await ProjectJoiner(
        db: second.db.raw,
        transport: second.transport(),
        state: second.state,
        deviceId: second.deviceId,
        userId: second.userId,
      ).join(projectId);

      final availableAfter = await ProjectDirectoryClient(
        db: second.db.raw,
        transport: second.transport(),
        state: second.state,
      ).listAvailableToJoin();
      expect(
        availableAfter.map((p) => p.projectId),
        isNot(contains(projectId)),
      );
    });
  });
}

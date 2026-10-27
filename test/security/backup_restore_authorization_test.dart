import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../data/sync/backup_builders.dart';

/// **Task 11.20 — §4.19 clause 6 on the picked-`.zip` restore.**
///
/// Task 11.19 put the clause on the share path and, asking it of every other
/// import path as task 10.66 requires, found this one open: `ProjectMerger`
/// reaches every column of all eleven synced tables and asked nobody whether
/// the person restoring was allowed to write in the project being restored
/// into. A **viewer** could restore an archive over a project they are only
/// allowed to read. Their rows are refused at the server on the next sync, so
/// no teammate's field record was ever reachable — what they got was their own
/// device showing them a project the project does not agree with.
///
/// ## Why this needed deciding rather than patching, which is what these tests
/// are really pinning
///
/// The obvious fix — *refuse unless the user is a contributor or owner* — is
/// wrong, and wrong in the direction that costs data. **Membership is
/// server-derived.** A reinstalled phone, or a replacement one recovering last
/// season's archive, has no `Project_Memberships` rows for the project and no
/// `Projects` row either. That is the case restore exists for, and Phase 10's
/// first invariant says the app works fully with no server at all. So the
/// check honours a rung the device has been told and **abstains when it has
/// not been told one** — which is exactly `UntrustedImportRules
/// .receiverMayImport`'s existing null-permits reading, reused rather than
/// re-derived.
///
/// The `no membership answer` group is therefore not a set of edge cases. It
/// is the feature. A change that makes those tests fail has broken restore for
/// the people it matters most to, whatever it did for the one refusal above.
///
/// ## What goes red under which mutation — measured, not predicted
///
/// Each mutation below was applied to `ProjectMerger` and the suite re-run, so
/// these counts are transcript rather than intent.
///
/// - **Neutralize the check** (`if (false && ...)`) → **7 red, 10 green**: all
///   four of `a viewer is refused`, both of `the archive cannot author its own
///   permission`, and `being an owner somewhere else does not buy a restore
///   here`. Nothing in `no membership answer` moves, which is the point — those
///   tests pass with no check at all and are guarding the opposite direction.
/// - **Make a null role refuse — the obvious fix, and the trap** → **5 red, 12
///   green**, and the five are exactly the `no membership answer` group. That
///   mutation closes nothing and breaks restoring onto a reinstalled phone.
///   The group exists so that fix cannot be made quietly.
/// - **Ask the question after `_apply` instead of before it** → **5 red**,
///   including *both* self-authorization tests, and the interesting half is
///   *why*: with the archive's rows already written, the file's own
///   `Project_Memberships` row naming the importer as `owner` had made them
///   one, so the check **permitted**. The self-granting archive is not a
///   hypothetical the position guards against; it is an attack that works the
///   moment the check moves.
///
/// Two more mutations are reasoned rather than run, and named so the next
/// reader knows which tests own them: resolving the role in the app's *current*
/// project rather than the manifest's is owned by `the project checked is the
/// one the archive names`, and applying the check on the sync path too is owned
/// by `replication is not authorship` — a viewer's device refusing to
/// *receive* the project it is entitled to read.
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const localProject = 'project-local';
  const otherProject = 'project-other';
  const owner = 'user-owner';
  const viewer = 'user-viewer';
  const contributor = 'user-contributor';
  const stranger = 'user-stranger';
  const localTag = 'tag-local';

  /// This device's clock during the restore, passed in rather than read so the
  /// clock bounds do not drift with the wall clock.
  final now = DateTime.utc(2026, 8, 21, 12);

  late AppDatabase database;
  late Database db;
  late ProjectMerger merger;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    db = database.raw;
    merger = ProjectMerger(db);
    // Users before projects: `Projects.owner_user_id` is a foreign key.
    for (final (id, email) in const [
      (owner, 'owner@nau.edu'),
      (viewer, 'viewer@nau.edu'),
      (contributor, 'contributor@nau.edu'),
      (stranger, 'stranger@nau.edu'),
    ]) {
      await db.insert(
          Tables.users, sampleUser(id: id, email: email).toColumns());
    }
    await db.insert(Tables.projects,
        sampleProject(id: localProject, ownerUserId: owner).toColumns());
    await db.insert(
      Tables.tags,
      sampleTag(id: localTag, projectId: localProject).toColumns(),
    );
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
              id: 'membership-owner', projectId: localProject, userId: owner)
          .toColumns(),
    );
  });
  tearDown(() async => database.close());

  /// Gives [userId] a membership at [role] in [projectId]. `user-stranger`
  /// deliberately never gets one — see the `no membership answer` group.
  Future<void> joinAs(String userId, ProjectRole role,
          {String projectId = localProject}) =>
      db.insert(
        Tables.projectMemberships,
        sampleMembership(
                id: 'membership-$projectId-$userId',
                projectId: projectId,
                userId: userId,
                role: role)
            .toColumns(),
      );

  /// An ordinary, honest archive of [projectId] carrying one observation.
  /// Nothing in it is hostile; the question every test here asks is about the
  /// person restoring it, never about the file.
  ProjectBackup archiveOf(
    String projectId, {
    String observationId = 'obs-restored',
    Map<String, List<Map<String, Object?>>> extraTables = const {},
  }) =>
      makeBackup(
        {
          // **The tag travels with the archive since task 11.219.** A tag
          // belongs to one project, so a bearing in *this* archive's project
          // names a tag in that project — which an archive of that project
          // carries, because `ProjectExporter` collects it by scope. Without
          // it the bearing's `(tag_id, project_id)` reference has nothing to
          // point at, which is the composite foreign key doing its job.
          Tables.tags: [
            sampleTag(id: localTag, projectId: projectId).toColumns(),
          ],
          Tables.observations: [
            sampleObservation(
              id: observationId,
              projectId: projectId,
              userId: owner,
              tagId: localTag,
              sessionId: null,
            ).toColumns(),
          ],
          ...extraTables,
        },
        projectId: projectId,
      );

  Future<int> countOf(String table, [DatabaseExecutor? on]) async =>
      ((await (on ?? db).rawQuery('SELECT COUNT(*) FROM $table')).first.values
          .first as int);

  group('a viewer is refused on the device, not only at the server', () {
    setUp(() => joinAs(viewer, ProjectRole.viewer));

    test('the restore is refused and names the rung that refused it', () async {
      final report = await merger.merge(
        archiveOf(localProject),
        importingUserId: viewer,
        now: now,
      );

      expect(report.outcome, MergeOutcome.refusedNotPermitted);
      expect(report.wrote, isFalse);
      expect(report.receiverRole, ProjectRole.viewer);
    });

    test('nothing is written — not one row of eleven tables', () async {
      final before = await countOf(Tables.observations);

      await merger.merge(archiveOf(localProject),
          importingUserId: viewer, now: now);

      expect(await countOf(Tables.observations), before);
      expect(
        await db.query(Tables.observations,
            where: 'observation_id = ?', whereArgs: ['obs-restored']),
        isEmpty,
      );
    });

    test('a refused restore plants no Users row either', () async {
      // The share path's equivalent property (§4.19's "a refused import writes
      // nothing at all, including no `Users` row"). Here the archive's own
      // `Users` row is what would otherwise become an identity anchor a later
      // file could match on — and the email dedup would rewrite every row that
      // named it.
      final before = await countOf(Tables.users);

      final report = await merger.merge(
        archiveOf(localProject, extraTables: {
          Tables.users: [
            sampleUser(id: 'user-planted', email: 'planted@example.org')
                .toColumns(),
          ],
        }),
        importingUserId: viewer,
        now: now,
      );

      expect(report.outcome, MergeOutcome.refusedNotPermitted);
      expect(await countOf(Tables.users), before);
    });

    test('consent does not buy what rights did not — confirmChanges is not a '
        'second chance', () async {
      // The refusal must not look like the consent gate to a caller. Re-running
      // with `confirmChanges: true` is what a caller does after
      // `needsConfirmation`; doing it here changes nothing, because consent is
      // not what was missing.
      final report = await merger.merge(
        archiveOf(localProject),
        importingUserId: viewer,
        confirmChanges: true,
        now: now,
      );

      expect(report.outcome, MergeOutcome.refusedNotPermitted);
      expect(await countOf(Tables.observations), 0);
    });
  });

  group('no membership answer — the case restore exists for', () {
    test('a whole project restores onto a device that has never held it',
        () async {
      // The reinstalled phone. No `Projects` row, no membership rows, no
      // server: the restore is what creates the project, so there is no answer
      // to resolve and refusing would break the feature outright.
      final fresh = await AppDatabase.openInMemory();
      addTearDown(fresh.close);

      final report = await ProjectMerger(fresh.raw).merge(
        makeBackup(
          {
            Tables.users: [
              sampleUser(id: owner, email: 'owner@nau.edu').toColumns(),
            ],
            Tables.projects: [
              sampleProject(id: localProject, ownerUserId: owner).toColumns(),
            ],
            Tables.tags: [
              sampleTag(id: localTag, projectId: localProject).toColumns(),
            ],
            Tables.observations: [
              sampleObservation(
                id: 'obs-restored',
                projectId: localProject,
                userId: owner,
                tagId: localTag,
                sessionId: null,
              ).toColumns(),
            ],
          },
          projectId: localProject,
        ),
        importingUserId: owner,
        now: now,
      );

      expect(report.outcome, MergeOutcome.applied);
      expect(await countOf(Tables.observations, fresh.raw), 1);
    });

    test('a project this device holds with no membership row for the importer '
        'still restores', () async {
      // Created offline and never published, shared by a colleague, or simply
      // not synced yet. `user-stranger` has no membership row anywhere and is
      // not the project's creator, so the device has nothing to answer with.
      final report = await merger.merge(archiveOf(localProject),
          importingUserId: stranger, now: now);

      expect(report.outcome, MergeOutcome.applied);
      expect(report.receiverRole, isNull);
      expect(await countOf(Tables.observations), 1);
    });

    test('an ended membership is no answer either, and permits', () async {
      // `end_date` set: the person was a viewer and is not one now. That is
      // still "this device cannot say", not "no rights" — the same reading
      // `resolveProjectRole` gives every other caller.
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: 'membership-ended',
          projectId: localProject,
          userId: stranger,
          role: ProjectRole.viewer,
          endDate: DateTime.utc(2026, 1, 1),
        ).toColumns(),
      );

      final report = await merger.merge(archiveOf(localProject),
          importingUserId: stranger, now: now);

      expect(report.outcome, MergeOutcome.applied);
    });

    test('a device with no identity permits, for the same reason', () async {
      // Unreachable in the app — task 7.1 made identity capture a
      // non-skippable first-run gate — and reachable here, which is why it is
      // pinned rather than assumed. A null user resolves to a null role, and a
      // null role is *unknown*, not *none*.
      final report = await merger.merge(archiveOf(localProject), now: now);

      expect(report.outcome, MergeOutcome.applied);
    });

    test('the project the archive names not being here is enough — even when '
        'the importer is a viewer of a different project', () async {
      await joinAs(viewer, ProjectRole.viewer);

      final report = await merger.merge(
        archiveOf('project-never-seen', extraTables: {
          Tables.projects: [
            sampleProject(id: 'project-never-seen', ownerUserId: owner)
                .toColumns(),
          ],
        }),
        importingUserId: viewer,
        now: now,
      );

      // Being a viewer of one project says nothing about a project the device
      // has never held. The role is resolved in the project the *manifest*
      // names, where there is no answer, so the clause abstains.
      expect(report.outcome, MergeOutcome.applied);
      expect(await countOf(Tables.observations), 1);
    });
  });

  group('the rungs that may restore', () {
    test('a contributor may', () async {
      await joinAs(contributor, ProjectRole.contributor);

      final report = await merger.merge(archiveOf(localProject),
          importingUserId: contributor, now: now);

      expect(report.outcome, MergeOutcome.applied);
      expect(await countOf(Tables.observations), 1);
    });

    test('an owner may', () async {
      final report = await merger.merge(archiveOf(localProject),
          importingUserId: owner, now: now);

      expect(report.outcome, MergeOutcome.applied);
      expect(await countOf(Tables.observations), 1);
    });
  });

  group('the archive cannot author its own permission', () {
    setUp(() => joinAs(viewer, ProjectRole.viewer));

    test('a file granting the importer ownership is still refused', () async {
      // The reason the check is the first statement inside the transaction
      // rather than a per-row test inside `_plan`. The archive carries the
      // project's own `Project_Memberships` rows, so any check made after they
      // land is answered with rights the file just wrote. Task 11.3's Gate B
      // run named this class — a permission read from state a permissive
      // branch wrote.
      final report = await merger.merge(
        archiveOf(localProject, extraTables: {
          Tables.projectMemberships: [
            sampleMembership(
              id: 'membership-self-granted',
              projectId: localProject,
              userId: viewer,
              role: ProjectRole.owner,
            ).toColumns(),
          ],
        }),
        importingUserId: viewer,
        now: now,
      );

      expect(report.outcome, MergeOutcome.refusedNotPermitted);
      expect(report.receiverRole, ProjectRole.viewer);
    });

    test('and the grant itself is not written', () async {
      await merger.merge(
        archiveOf(localProject, extraTables: {
          Tables.projectMemberships: [
            sampleMembership(
              id: 'membership-self-granted',
              projectId: localProject,
              userId: viewer,
              role: ProjectRole.owner,
            ).toColumns(),
          ],
        }),
        importingUserId: viewer,
        now: now,
      );

      expect(
        await db.query(Tables.projectMemberships,
            where: 'membership_id = ?', whereArgs: ['membership-self-granted']),
        isEmpty,
      );
    });
  });

  group('the project checked is the one the archive names', () {
    setUp(() async {
      // Owner of one project, viewer of another — the state that separates
      // "which project" from "which person".
      await db.insert(Tables.projects,
          sampleProject(id: otherProject, ownerUserId: viewer).toColumns());
      await joinAs(viewer, ProjectRole.owner, projectId: otherProject);
      await joinAs(viewer, ProjectRole.viewer);
    });

    test('being an owner somewhere else does not buy a restore here', () async {
      final report = await merger.merge(archiveOf(localProject),
          importingUserId: viewer, now: now);

      expect(report.outcome, MergeOutcome.refusedNotPermitted);
    });

    test('and being a viewer here does not block a restore there', () async {
      final report = await merger.merge(archiveOf(otherProject),
          importingUserId: viewer, now: now);

      expect(report.outcome, MergeOutcome.applied);
    });
  });

  group('replication is not authorship', () {
    test('a pulled page still merges for a viewer', () async {
      // The sync path must never be gated on the local gradient: applying it
      // would make a viewer's device refuse to *receive* the project it is
      // entitled to read. The rows arrived authorized; §4.19 clause 6 governs
      // the person performing an import, and a background pull has none.
      await joinAs(viewer, ProjectRole.viewer);

      final report = await merger.merge(
        archiveOf(localProject),
        origin: MergeOrigin.authenticatedServer,
        importingUserId: viewer,
        now: now,
      );

      expect(report.outcome, MergeOutcome.applied);
      expect(await countOf(Tables.observations), 1);
    });
  });

  group('the file is judged on its own merits once the person passes', () {
    test('an owner restoring a hostile clock is still refused per row',
        () async {
      // Clause 6 is a gate in front of the others, not a replacement for them:
      // passing it buys nothing about the contents of the file.
      final row = sampleObservation(
        id: 'obs-hostile',
        projectId: localProject,
        userId: owner,
        tagId: localTag,
        sessionId: null,
      ).toColumns()
        ..['revision'] = 9223372036854775807;

      final report = await merger.merge(
        makeBackup({Tables.observations: [row]}, projectId: localProject),
        importingUserId: owner,
        now: now,
      );

      expect(report.outcome, MergeOutcome.applied);
      expect(report.totalRefused, 1);
      expect(await countOf(Tables.observations), 0);
    });
  });
}

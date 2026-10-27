import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/observation_exclusion_repository.dart';
import 'package:tritrack/data/repositories/observation_repository.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/project_role_lookup.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.237 — a colleague's project on a device whose user is not on it
/// is a read-only snapshot, derived per read, and every write gate says so.**
///
/// The fixture is the archive-import shape: `project-1` was created by
/// `user-1`, whose owner membership row is the only membership row here, and
/// `user-2` is the person using this device. Nothing names `user-2`.
///
/// Three things are asserted, and the third is the one that makes the first
/// two safe to ship:
///
/// 1. [readProjectStanding] tells *not a member* from *cannot say* — the two
///    answers a `ProjectRole?` collapsed into one `null`.
/// 2. Every repository gate — the general one, the tag-table one and the
///    exclusion one — refuses with the same [notAMemberWriteRefusal].
/// 3. **One open membership row turns the snapshot live, with nothing else
///    changed** — no re-import, no flag cleared, no restart.
void main() {
  late AppDatabase database;
  late ProjectRepository projects;
  late ProjectMembershipRepository memberships;
  late ObservationRepository observations;
  late TagRepository tags;
  late ObservationExclusionRepository marks;

  const creator = MutationActor.user('user-1');
  const holder = MutationActor.user('user-2');
  final at = DateTime.utc(2026, 9, 13, 9);

  SyncMeta metaFor(MutationActor actor) =>
      SyncMeta.initial(now: at, modifiedBy: actor.userId, originDeviceId: 'd');

  setUp(() async {
    database = await AppDatabase.openInMemory();
    projects = ProjectRepository(database.raw);
    memberships = ProjectMembershipRepository(database.raw);
    observations = ObservationRepository(database.raw);
    tags = TagRepository(database.raw);
    marks = ObservationExclusionRepository(database.raw);

    final users = UserRepository(database.raw);
    await users.insert(sampleUser());
    await users.insert(sampleUser(id: 'user-2', email: 'holder@example.com'));
    await projects.insert(sampleProject(ownerUserId: 'user-1'));
    await memberships.insert(
      sampleMembership(userId: 'user-1'),
      authority: MembershipInsertAuthority.bootstrapOwner(),
    );
    await tags.insert(sampleTag());
    await observations.insert(
      sampleObservation(id: 'obs-theirs', sessionId: null, userId: 'user-1')
          .copyWith(sync: metaFor(creator)),
    );
  });

  tearDown(() => database.close());

  Future<ProjectStanding> standingOf(String userId) => readProjectStanding(
    database.raw,
    projectId: 'project-1',
    userId: userId,
  );

  /// The person the device is used by gets onto the project the way the
  /// server would tell the device: an open membership row arrives.
  Future<void> holderJoins(ProjectRole role) => memberships.insert(
    sampleMembership(id: 'membership-2', userId: 'user-2', role: role),
    authority: MembershipInsertAuthority.byOwner(creator),
  );

  group('readProjectStanding tells the three answers apart', () {
    test('the creator is a member, by the fallback and by the row', () async {
      expect(
        await standingOf('user-1'),
        const ProjectStanding.member(ProjectRole.owner),
      );
    });

    test('the holder of somebody else\'s project is not a member', () async {
      final standing = await standingOf('user-2');
      expect(standing, ProjectStanding.notAMember);
      expect(standing.isSnapshot, isTrue);
      expect(standing.mayWriteProjectData, isFalse);
      expect(standing.role, isNull);
    });

    test('a project this device does not hold is unknown, not a snapshot',
        () async {
      final standing = await readProjectStanding(
        database.raw,
        projectId: 'project-elsewhere',
        userId: 'user-2',
      );
      expect(standing, ProjectStanding.unknown);
      expect(standing.mayWriteProjectData, isTrue);
    });

    test('no signed-in user is unknown', () async {
      expect(await standingOf(''), ProjectStanding.unknown);
    });

    test(
      'an open row with a role this build cannot read is unknown — the server '
      'refuses it, this device does not guess',
      () async {
        // The `CHECK` constraint refuses an unknown role on the way in, so
        // the row is planted underneath it, as a build behind its server
        // would find it after a migration it does not understand.
        await database.raw.execute(
          'PRAGMA ignore_check_constraints = ON',
        );
        await database.raw.insert(Tables.projectMemberships, {
          'membership_id': 'membership-future',
          'project_id': 'project-1',
          'user_id': 'user-2',
          'join_date': DbCodec.encodeUtc(at),
          'role': 'co_owner',
          'created_at': DbCodec.encodeUtc(at),
          'updated_at': DbCodec.encodeUtc(at),
          'revision': 0,
          'last_modified_by': 'user-1',
          'origin_device_id': 'd',
        });
        expect(await standingOf('user-2'), ProjectStanding.unknown);
      },
    );

    test('a closed row is not a membership — a departed member is not on it',
        () async {
      await holderJoins(ProjectRole.contributor);
      expect(
        await standingOf('user-2'),
        const ProjectStanding.member(ProjectRole.contributor),
      );
      await memberships.update(
        sampleMembership(
          id: 'membership-2',
          userId: 'user-2',
          role: ProjectRole.contributor,
          endDate: at,
        ),
        actor: creator,
      );
      expect(await standingOf('user-2'), ProjectStanding.notAMember);
    });
  });

  group('every write gate refuses a snapshot with the one shared sentence', () {
    test('the general gate — recording an observation', () async {
      await expectLater(
        observations.insert(
          sampleObservation(id: 'obs-mine', sessionId: null, userId: 'user-2')
              .copyWith(sync: metaFor(holder)),
        ),
        throwsA(
          isA<UnauthorizedMutation>()
              .having((e) => e.notAMember, 'notAMember', isTrue)
              .having(
                (e) => e.refusalSentence(asViewer: 'viewer wording'),
                'refusalSentence',
                notAMemberWriteRefusal,
              ),
        ),
      );
    });

    test('the tag-table gate — editing a tag', () async {
      await expectLater(
        tags.assertMayEdit('project-1', holder),
        throwsA(
          isA<UnauthorizedMutation>().having(
            (e) => e.notAMember,
            'notAMember',
            isTrue,
          ),
        ),
      );
    });

    test('the exclusion gate — superseding an observation', () async {
      await expectLater(
        marks.assertMayMark(
          'project-1',
          ObservationExclusionKind.superseded,
          holder,
        ),
        throwsA(
          isA<UnauthorizedMutation>().having(
            (e) => e.notAMember,
            'notAMember',
            isTrue,
          ),
        ),
      );
    });

    test('and the screen-side verdicts say the same sentence', () {
      const standing = ProjectStanding.notAMember;
      expect(
        authorEditVerdict(
          standing: standing,
          actorUserId: 'user-2',
          rowUserId: 'user-2',
        ).reason,
        notAMemberWriteRefusal,
      );
      expect(
        truthPointEditVerdict(standing: standing).reason,
        notAMemberWriteRefusal,
      );
      final marking = exclusionVerdict(standing: standing, isOwner: false);
      expect(marking.supersedeReason, notAMemberWriteRefusal);
      expect(marking.excludeReason, notAMemberWriteRefusal);
      expect(
        withdrawMarkVerdict(
          standing: standing,
          isOwner: false,
          actorUserId: 'user-2',
          markUserId: 'user-2',
          markKind: ObservationExclusionKind.superseded,
        ).reason,
        notAMemberWriteRefusal,
      );
    });

    test('a viewer still gets the viewer wording, not the snapshot one', () {
      const viewer = ProjectStanding.member(ProjectRole.viewer);
      expect(viewer.writeRefusal(asViewer: 'viewer wording'), 'viewer wording');
      expect(ProjectStanding.unknown.writeRefusal(asViewer: 'x'), isNull);
      expect(
        const ProjectStanding.member(ProjectRole.contributor)
            .writeRefusal(asViewer: 'x'),
        isNull,
      );
    });

    test('the sentence names the join code and the screens it lives on', () {
      // The words are `join_project_screen.dart`'s and
      // `project_members_screen.dart`'s: a code an owner gives out, entered
      // under "Join a project", and a request the owner approves.
      expect(notAMemberWriteRefusal, contains('join code'));
      expect(notAMemberWriteRefusal, contains('Join a project'));
      expect(notAMemberWriteRefusal, contains('approves'));
      expect(notAMemberWriteRefusal.length, lessThan(300));
    });
  });

  group('joining later turns the snapshot live with no re-import', () {
    test('one open membership row, and the same write goes through', () async {
      final refused = observations.insert(
        sampleObservation(id: 'obs-before', sessionId: null, userId: 'user-2')
            .copyWith(sync: metaFor(holder)),
      );
      await expectLater(refused, throwsA(isA<UnauthorizedMutation>()));

      // What a sync pull does when the owner approves the request: the row
      // arrives. Nothing else on the device changes — no flag, no re-import.
      await holderJoins(ProjectRole.contributor);

      expect(
        await standingOf('user-2'),
        const ProjectStanding.member(ProjectRole.contributor),
      );
      await observations.insert(
        sampleObservation(id: 'obs-after', sessionId: null, userId: 'user-2')
            .copyWith(sync: metaFor(holder)),
      );
      expect(
        await observations.findById('obs-after', projectId: 'project-1'),
        isNotNull,
      );
    });

    test('and joined as a viewer it is a viewer\'s project, not a snapshot',
        () async {
      await holderJoins(ProjectRole.viewer);
      final standing = await standingOf('user-2');
      expect(standing, const ProjectStanding.member(ProjectRole.viewer));
      expect(standing.isSnapshot, isFalse);
      expect(standing.writeRefusal(asViewer: 'viewer wording'), 'viewer wording');
    });
  });
}

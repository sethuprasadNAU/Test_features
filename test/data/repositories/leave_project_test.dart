import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.28 part 1, on the device: leaving a project.**
///
/// The server is the boundary and `server/test/authz/leave_project_test.dart`
/// is where the exception is attacked. This file is about the other half of
/// the task — *the app cannot be wrong* — and about the specific defect 11.28
/// names: before this, a device that tried to leave threw an exception no
/// screen caught while the server refused the row forever, so the device was
/// permanently out of step on it.
///
/// The narrowness here is structural rather than checked.
/// [ProjectMembershipRepository.leaveProject] takes a project and an actor and
/// finds the row itself, so there is no argument in which somebody else's
/// membership could be named. The tests below prove that is *true of the
/// behaviour* and not only of the signature.
void main() {
  late AppDatabase database;
  late ProjectMembershipRepository memberships;

  const owner = MutationActor.user('user-owner');
  const contributor = MutationActor.user('user-contributor');
  const viewer = MutationActor.user('user-viewer');
  const stranger = MutationActor.user('user-stranger');

  final now = DateTime.utc(2026, 8, 22, 10);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    memberships = ProjectMembershipRepository(database.raw);
    final users = UserRepository(database.raw);
    for (final id in [
      'user-owner',
      'user-contributor',
      'user-viewer',
      'user-stranger',
    ]) {
      await users.insert(sampleUser(id: id, email: '$id@x.com'));
    }
    await ProjectRepository(
      database.raw,
    ).insert(sampleProject(ownerUserId: 'user-owner'));
    await memberships.insert(
      sampleMembership(id: 'mem-owner', userId: 'user-owner'),
      authority: const MembershipInsertAuthority.bootstrapOwner(),
    );
    for (final (id, user, role) in [
      ('mem-contributor', 'user-contributor', ProjectRole.contributor),
      ('mem-viewer', 'user-viewer', ProjectRole.viewer),
    ]) {
      await memberships.insert(
        sampleMembership(id: id, userId: user, role: role),
        authority: const MembershipInsertAuthority.byOwner(owner),
      );
    }
  });

  tearDown(() => database.close());

  Future<DateTime?> endDateOf(String membershipId) async =>
      (await memberships.findById(
        membershipId,
        projectId: 'project-1',
        includeDeleted: true,
      ))?.endDate;

  group('a person may leave', () {
    test('a contributor ends their own stint', () async {
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: contributor,
        now: now,
      );
      expect(await endDateOf('mem-contributor'), now.toUtc());
      expect(
        await memberships.findForUser('project-1', 'user-contributor'),
        isNull,
        reason: 'the stint is closed, so it is no longer the current one',
      );
    });

    test('a viewer ends their own stint', () async {
      // A `viewer` writes nothing in a project — `assertRoleMayWrite` refuses
      // every row before the rule table is consulted. Leaving is the one
      // exception, and this is the person it matters most for: without it, the
      // member with the fewest rights would be the only one who could never
      // get off the project.
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: viewer,
        now: now,
      );
      expect(await endDateOf('mem-viewer'), now.toUtc());
    });

    test('the stint is kept, not deleted', () async {
      // A closed stint is the record that somebody collected data on this
      // project between two dates, which is what a permit report needs. It
      // must survive leaving, and it must still name them.
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: contributor,
        now: now,
      );
      final row = await memberships.findById(
        'mem-contributor',
        projectId: 'project-1',
        includeDeleted: true,
      );
      expect(row, isNotNull);
      expect(row!.sync.isDeleted, isFalse);
      expect(row.userId, 'user-contributor');
      expect(row.role, ProjectRole.contributor);
      expect(row.sync.lastModifiedBy, 'user-contributor');
    });

    test('an owner leaves while a co-owner remains', () async {
      // Promotes the existing contributor row to owner — what
      // `MembershipProvider.changeRole` does on a real device, and the way
      // `ProjectMembershipRepository.grantOwner` did it before task 11.62
      // deleted it as dead code with no caller.
      final contributorRow = (await memberships.findById(
        'mem-contributor',
        projectId: 'project-1',
      ))!;
      await memberships.update(
        contributorRow.copyWith(role: ProjectRole.owner),
        actor: owner,
      );
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: owner,
        now: now,
      );
      expect(await endDateOf('mem-owner'), now.toUtc());
      expect(await memberships.ownersOf('project-1'), {'user-contributor'});
    });
  });

  group('and may end nobody else', () {
    test('leaving touches only the caller\'s own row', () async {
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: contributor,
        now: now,
      );
      expect(await endDateOf('mem-owner'), isNull);
      expect(await endDateOf('mem-viewer'), isNull);
    });

    test('somebody with no open stint has nothing to leave', () async {
      expect(
        () => memberships.leaveProject(
          projectId: 'project-1',
          actor: stranger,
          now: now,
        ),
        throwsA(isA<NotAProjectMember>()),
      );
      expect(await endDateOf('mem-owner'), isNull);
      expect(await endDateOf('mem-contributor'), isNull);
    });

    test('leaving twice is refused the second time', () async {
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: contributor,
        now: now,
      );
      // Not an error worth hiding: the ordinary way to see it is a stale
      // screen, and the second call must not re-date the first departure.
      expect(
        () => memberships.leaveProject(
          projectId: 'project-1',
          actor: contributor,
          now: now.add(const Duration(days: 1)),
        ),
        throwsA(isA<NotAProjectMember>()),
      );
      expect(await endDateOf('mem-contributor'), now.toUtc());
    });

    test('replication cannot leave', () async {
      // Replication writes rows decided elsewhere; it has nobody to leave as,
      // and an actor with a null `userId` would otherwise fall through to
      // "find the row belonging to nobody".
      expect(
        () => memberships.leaveProject(
          projectId: 'project-1',
          actor: const MutationActor.replication('a merge'),
          now: now,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('the general path is unchanged: a contributor cannot end a '
        'colleague', () async {
      // The exception must not have widened `endMembership`, which is the
      // owner's remove-a-member path and the one a screen bug would reach for.
      final theirs = await memberships.findForUser('project-1', 'user-viewer');
      expect(
        () => memberships.endMembership(theirs!, actor: contributor, now: now),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await endDateOf('mem-viewer'), isNull);
    });

    test('the general path is unchanged: a contributor cannot end their own '
        'row through it either', () async {
      // Deliberate. `endMembership` is the owner's verb and stays owner-only;
      // the narrow exception lives in `leaveProject` and nowhere else, so a
      // future caller cannot reach it by accident from the wrong method.
      final mine = await memberships.findForUser(
        'project-1',
        'user-contributor',
      );
      expect(
        () => memberships.endMembership(mine!, actor: contributor, now: now),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await endDateOf('mem-contributor'), isNull);
    });
  });

  group('and cannot empty a project of owners', () {
    test('the last owner cannot leave', () async {
      expect(
        () => memberships.leaveProject(
          projectId: 'project-1',
          actor: owner,
          now: now,
        ),
        throwsA(isA<LastOwnerRemoval>()),
      );
      expect(await endDateOf('mem-owner'), isNull);
      expect(await memberships.ownersOf('project-1'), {'user-owner'});
    });

    test('a contributor can leave a project with no open owner row', () async {
      // The guard only applies to a row that currently confers ownership.
      // Applied unconditionally it would refuse this — no *other* open owner
      // row exists, which is what `_guardLastOwnerRemoval` refuses on — and
      // tell a contributor they are the project's last owner, which is both
      // wrong and baffling. Reachable on a project whose owner-membership
      // backfill has not run.
      // Raw, because every supported path to this state is refused — which is
      // the point: the state is reachable only by a backfill that has not run
      // or a merge that landed oddly, never by an action, so it has to be
      // constructed rather than performed.
      await database.raw.update(
        Tables.projectMemberships,
        {'end_date': DbCodec.encodeUtc(DateTime.utc(2026, 8, 1))},
        where: 'membership_id = ?',
        whereArgs: ['mem-owner'],
      );
      expect(await memberships.openOwnerships('project-1'), isEmpty);
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: contributor,
        now: now,
      );
      expect(await endDateOf('mem-contributor'), now.toUtc());
    });

    test('the sole owner can leave once somebody else is an owner', () async {
      final viewerRow = (await memberships.findById(
        'mem-viewer',
        projectId: 'project-1',
      ))!;
      await memberships.update(
        viewerRow.copyWith(role: ProjectRole.owner),
        actor: owner,
      );
      await memberships.leaveProject(
        projectId: 'project-1',
        actor: owner,
        now: now,
      );
      expect(await memberships.ownersOf('project-1'), {'user-viewer'});
    });
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.1 — co-equal project owners and ownership transfer.**
///
/// Task 8.4 decided the `owner` rule reads `Projects.owner_user_id`, on the
/// explicit grounds that with no transfer feature the column and the
/// membership table could not diverge. They can now, so enforcement moved to
/// open `role='owner'` rows in `Project_Memberships` — any number of them, all
/// with identical rights — and this is where that is proven at the layer a
/// screen cannot bypass.
void main() {
  late AppDatabase database;
  late ProjectRepository projects;
  late ProjectMembershipRepository memberships;

  const creator = MutationActor.user('user-creator');
  const second = MutationActor.user('user-second');
  const outsider = MutationActor.user('user-outsider');

  final now = DateTime.utc(2026, 8, 20);

  setUp(() async {
    database = await AppDatabase.openInMemory();
    projects = ProjectRepository(database.raw);
    memberships = ProjectMembershipRepository(database.raw);
    final users = UserRepository(database.raw);
    for (final id in ['user-creator', 'user-second', 'user-outsider']) {
      await users.insert(sampleUser(id: id, email: '$id@x.com'));
    }
    await projects.insert(sampleProject(ownerUserId: 'user-creator'));
    await memberships.insert(
      sampleMembership(id: 'membership-creator', userId: 'user-creator'),
      authority: const MembershipInsertAuthority.bootstrapOwner(),
    );
  });

  tearDown(() => database.close());

  /// Seeds a second co-owner the way one actually arrives on a device: an
  /// invitation issued at the `owner` role is a **server-authored** insert,
  /// delivered by an ordinary pull — never a client push naming somebody
  /// else, which `RowAuthorizer` refuses unconditionally (task 11.62 deleted
  /// `ProjectMembershipRepository.grantOwner`, which modelled the insert the
  /// wrong way and had no caller for exactly that reason). `replication` is
  /// the authority door for a row decided elsewhere and written verbatim.
  Future<void> grantSecondOwner() => memberships.insert(
    sampleMembership(
      id: 'membership-second',
      userId: 'user-second',
      role: ProjectRole.owner,
    ),
    authority: const MembershipInsertAuthority.replication(
      'test setup: a second co-owner, as an owner-role invitation would '
      'deliver it',
    ),
  );

  group('who owns the project', () {
    test('one owner membership names one owner', () async {
      expect(await memberships.ownersOf('project-1'), {'user-creator'});
    });

    test('a granted owner is co-equal, not subordinate', () async {
      await grantSecondOwner();
      expect(await memberships.ownersOf('project-1'), {
        'user-creator',
        'user-second',
      });
    });

    test(
      'the creator column no longer decides once memberships name an owner',
      () async {
        // `owner_user_id` is retained as the creator/audit record and is
        // deliberately still populated — it just stops being the answer.
        await grantSecondOwner();
        final creatorRow = (await memberships.findById(
          'membership-creator',
          projectId: 'project-1',
        ))!;
        await memberships.endMembership(creatorRow, actor: creator, now: now);

        expect(
          (await projects.findById('project-1'))!.ownerUserId,
          'user-creator',
          reason:
              'retained as the creator record, per the plan: do not drop it',
        );
        expect(await memberships.ownersOf('project-1'), {'user-second'});
      },
    );
  });

  group('two owners each perform every owner action', () {
    setUp(grantSecondOwner);

    test('both may rename the project', () async {
      expect(
        await projects.update(
          sampleProject(
            ownerUserId: 'user-creator',
          ).copyWith(projectName: 'By the creator'),
          actor: creator,
        ),
        1,
      );
      expect(
        await projects.update(
          sampleProject(
            ownerUserId: 'user-creator',
          ).copyWith(projectName: 'By the second owner'),
          actor: second,
        ),
        1,
      );
      expect(
        (await projects.findById('project-1'))!.projectName,
        'By the second owner',
      );
    });

    test('both may manage membership, and an outsider may not', () async {
      final creatorRow = (await memberships.findById(
        'membership-creator',
        projectId: 'project-1',
      ))!;
      // Note the actor: the *second* owner editing the *creator's* row.
      expect(
        await memberships.update(
          creatorRow.copyWith(role: ProjectRole.owner),
          actor: second,
        ),
        1,
      );
      await expectLater(
        memberships.update(
          creatorRow.copyWith(role: ProjectRole.contributor),
          actor: outsider,
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
    });

    test('both may soft-delete the project', () async {
      expect(await projects.softDeleteById('project-1', actor: second), 1);
      await projects.restoreById('project-1', actor: creator);
      expect(await projects.softDeleteById('project-1', actor: creator), 1);
    });
  });

  group('ownership transfer', () {
    test(
      'grant then end: the successor owns it and the creator does not',
      () async {
        await grantSecondOwner();
        final creatorRow = (await memberships.findById(
          'membership-creator',
          projectId: 'project-1',
        ))!;
        await memberships.endMembership(creatorRow, actor: creator, now: now);

        expect(await memberships.isOwner('project-1', 'user-second'), isTrue);
        expect(await memberships.isOwner('project-1', 'user-creator'), isFalse);

        // And the departed creator has actually lost the rights, not just the
        // label — this is the assertion Phase 8's rule could not have made.
        await expectLater(
          projects.update(
            sampleProject(
              ownerUserId: 'user-creator',
            ).copyWith(projectName: 'X'),
            actor: creator,
          ),
          throwsA(isA<UnauthorizedMutation>()),
        );
        expect(
          await projects.update(
            sampleProject(
              ownerUserId: 'user-creator',
            ).copyWith(projectName: 'X'),
            actor: second,
          ),
          1,
        );
      },
    );

    // Promoting an *existing* member to owner is `MembershipProvider
    // .changeRole` (an ordinary `update`, governed by `MutationRule
    // .projectOwner` like any other membership edit) — covered above in
    // 'both may manage membership, and an outsider may not', and by
    // `mutation_authorization_test.dart`'s `projectOwner rule` group.
    // `grantOwner` used to duplicate that logic for a row that did not exist
    // yet, plus an insert path for a brand-new member that only ever worked
    // locally: `RowAuthorizer` refuses any client-pushed insert naming
    // somebody other than the caller, unconditionally, so nothing that
    // reached a real server could ever land that way. Task 11.62 deleted it
    // — nothing in the app called it — and
    // `mutation_authorization_test.dart`'s 'a non-owner cannot add a member
    // by inserting a row' already covers an outsider attempting exactly that
    // insert.
  });

  group('the last-owner guard', () {
    // Not an edge case. Someone leaving a lab, closing out their stint on the
    // way, is the ordinary path to a project nobody can manage — and there is
    // no privileged operator to appeal to, because the server is a laptop.
    Future<ProjectMembership> creatorRow() async => (await memberships.findById(
      'membership-creator',
      projectId: 'project-1',
    ))!;

    test('the last owner cannot end their own membership', () async {
      await expectLater(
        memberships.endMembership(await creatorRow(), actor: creator, now: now),
        throwsA(isA<LastOwnerRemoval>()),
      );
      expect(await memberships.ownersOf('project-1'), {'user-creator'});
    });

    test('the last owner cannot demote themselves either', () async {
      // Same hole, one column over — the guard keys on what confers
      // ownership, not on which field the caller happened to change.
      await expectLater(
        memberships.update(
          (await creatorRow()).copyWith(role: ProjectRole.contributor),
          actor: creator,
        ),
        throwsA(isA<LastOwnerRemoval>()),
      );
      expect(await memberships.ownersOf('project-1'), {'user-creator'});
    });

    test('the last owner cannot tombstone their own membership', () async {
      await expectLater(
        memberships.softDeleteByKey({
          'membership_id': 'membership-creator',
          'project_id': 'project-1',
        }, actor: creator),
        throwsA(isA<LastOwnerRemoval>()),
      );
      expect(await memberships.ownersOf('project-1'), {'user-creator'});
    });

    test('the refusal explains itself rather than failing bare', () async {
      // The plan asks for "an explanation rather than leaving an unmanageable
      // project", so the message is part of the contract, not decoration.
      try {
        await memberships.endMembership(
          await creatorRow(),
          actor: creator,
          now: now,
        );
        fail('expected LastOwnerRemoval');
      } on LastOwnerRemoval catch (e) {
        expect(e.message, contains('last owner'));
        expect(e.message, contains('someone else an owner first'));
      }
    });

    test('with a second owner, the first may leave', () async {
      await grantSecondOwner();
      await memberships.endMembership(
        await creatorRow(),
        actor: creator,
        now: now,
      );
      expect(await memberships.ownersOf('project-1'), {'user-second'});
    });

    test('ending a non-owner membership is never guarded', () async {
      await memberships.insert(
        sampleMembership(
          id: 'membership-second',
          userId: 'user-second',
          role: ProjectRole.contributor,
        ),
        authority: MembershipInsertAuthority.byOwner(creator),
      );
      final row = (await memberships.findById(
        'membership-second',
        projectId: 'project-1',
      ))!;
      await memberships.endMembership(row, actor: creator, now: now);
      expect(await memberships.ownersOf('project-1'), {'user-creator'});
    });
  });
}

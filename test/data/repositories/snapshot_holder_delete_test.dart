import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.238 — a read-only snapshot can be removed from your device.**
///
/// `Projects` is `MutationRule.owner`, and until this task its only exemption
/// was [MutationExemption.departedMember] — somebody who *was* a member and
/// no longer is. A colleague's archive, imported by somebody the project's
/// own membership rows do not name, is a read-only snapshot (task 11.237):
/// they were never on the project at all, so that exemption does not reach
/// them either, and the project sat in their list with no way off it.
///
/// **Same safety argument as `departed_member_delete_test.dart`, verified
/// fresh rather than trusted.** `Projects` is one of the four tables
/// `offer_rules.dart` says a device never offers to the server at all, so a
/// local delete here cannot reach anybody else's copy of the project —
/// whoever is deleting it, and whatever their history with the project is.
///
/// **What is not a copy of that file: the check itself.** The departed-member
/// exemption asks for no *open* row and at least one *closed* one. This asks
/// for **no row at all** — the tests below prove the two do not admit each
/// other's case.
void main() {
  late AppDatabase database;
  late ProjectRepository projects;

  const owner = MutationActor.user('user-owner');
  const contributor = MutationActor.user('user-contributor');
  const departed = MutationActor.user('user-departed');
  const stranger = MutationActor.user('user-stranger');

  Future<bool> isDeleted(String projectId) async {
    final project = await projects.findById(projectId, includeDeleted: true);
    return project?.sync.isDeleted ?? false;
  }

  setUp(() async {
    database = await AppDatabase.openInMemory();
    projects = ProjectRepository(database.raw);
    final users = UserRepository(database.raw);
    for (final id in [
      'user-owner',
      'user-contributor',
      'user-departed',
      'user-stranger',
    ]) {
      await users.insert(sampleUser(id: id, email: '$id@x.com'));
    }
    await projects.insert(
      sampleProject(id: 'project-1', ownerUserId: 'user-owner'),
    );
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(userId: 'user-owner').toColumns(),
    );
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-contributor',
        userId: 'user-contributor',
        role: ProjectRole.contributor,
      ).toColumns(),
    );
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-departed',
        userId: 'user-departed',
        role: ProjectRole.contributor,
        endDate: DateTime.utc(2026, 8, 20),
      ).toColumns(),
    );
    // `user-stranger` has no row at all — the snapshot shape.
  });

  tearDown(() => database.close());

  test('a snapshot holder may delete their local copy', () async {
    await projects.softDeleteById(
      'project-1',
      actor: stranger,
      exemption: const MutationExemption.snapshotHolder('project-1'),
    );
    expect(await isDeleted('project-1'), isTrue);
  });

  test('and may undo it — the same exemption covers the restore', () async {
    await projects.softDeleteById(
      'project-1',
      actor: stranger,
      exemption: const MutationExemption.snapshotHolder('project-1'),
    );
    await projects.restoreById(
      'project-1',
      actor: stranger,
      exemption: const MutationExemption.snapshotHolder('project-1'),
    );
    expect(await isDeleted('project-1'), isFalse);
  });

  test('a current member claiming it is refused, owner or not', () async {
    await expectLater(
      projects.softDeleteById(
        'project-1',
        actor: contributor,
        exemption: const MutationExemption.snapshotHolder('project-1'),
      ),
      throwsA(isA<UnauthorizedMutation>()),
    );
    expect(await isDeleted('project-1'), isFalse);
  });

  test(
    'a departed member claiming the snapshot exemption is refused — a '
    'closed row is not the same as no row',
    () async {
      // The half that makes this not a copy-paste of `DepartedMemberExemption`.
      // A departed member has a row (closed); a snapshot holder has none.
      // Getting that backwards would let either masquerade as the other.
      await expectLater(
        projects.softDeleteById(
          'project-1',
          actor: departed,
          exemption: const MutationExemption.snapshotHolder('project-1'),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await isDeleted('project-1'), isFalse);
    },
  );

  test(
    'a snapshot holder claiming the departed-member exemption is refused — '
    'no row is not the same as a closed row',
    () async {
      // The mirror image of the case above, proven the other direction so
      // neither exemption can stand in for the other.
      await expectLater(
        projects.softDeleteById(
          'project-1',
          actor: stranger,
          exemption: const MutationExemption.departedMember('project-1'),
        ),
        throwsA(isA<UnauthorizedMutation>()),
      );
      expect(await isDeleted('project-1'), isFalse);
    },
  );

  test('naming one project while deleting another is refused', () async {
    await projects.insert(
      sampleProject(id: 'project-2', ownerUserId: 'user-owner'),
    );
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-owner-2',
        projectId: 'project-2',
        userId: 'user-owner',
      ).toColumns(),
    );
    await expectLater(
      projects.softDeleteById(
        'project-2',
        actor: stranger,
        exemption: const MutationExemption.snapshotHolder('project-1'),
      ),
      throwsA(isA<UnauthorizedMutation>()),
    );
    expect(await isDeleted('project-2'), isFalse);
  });

  test('the ordinary owner-only rule is untouched without one', () async {
    await expectLater(
      projects.softDeleteById('project-1', actor: stranger),
      throwsA(isA<UnauthorizedMutation>()),
    );
    await projects.softDeleteById('project-1', actor: owner);
    expect(await isDeleted('project-1'), isTrue);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **Task 11.54 — a project you have left can be removed from your device.**
///
/// Michael found this on real hardware on 2026-08-29: after leaving a project,
/// the leave control correctly disappeared and the delete control was greyed
/// out, because it had always been owner-only and he had never been an owner.
/// The project sat in his list with every control dead. He decided the same
/// day that a departed member may delete their copy.
///
/// `Projects` is `MutationRule.owner`, so permitting this needs a named,
/// **verified** exemption rather than a bypass — [MutationExemption] — and
/// this is where the verification is proven at the layer no screen can get
/// past. The three refusals below are what stop it becoming "anyone who is
/// not an owner may delete anything."
void main() {
  late AppDatabase database;
  late ProjectRepository projects;

  const owner = MutationActor.user('user-owner');
  const departed = MutationActor.user('user-departed');
  const stillOn = MutationActor.user('user-still-on');
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
      'user-departed',
      'user-still-on',
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
        id: 'membership-departed',
        userId: 'user-departed',
        role: ProjectRole.contributor,
        endDate: DateTime.utc(2026, 8, 20),
      ).toColumns(),
    );
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-still-on',
        userId: 'user-still-on',
        role: ProjectRole.contributor,
      ).toColumns(),
    );
  });

  tearDown(() => database.close());

  test('a past member may delete their copy of the project', () async {
    await projects.softDeleteById(
      'project-1',
      actor: departed,
      exemption: const MutationExemption.departedMember('project-1'),
    );
    expect(await isDeleted('project-1'), isTrue);
  });

  test('and may undo it — the same exemption covers the restore', () async {
    // Task 11.42 spent a whole task on an undo bar that was offered and did
    // not work. Offering one that is then refused by authorization would be
    // the same failure with a different cause.
    await projects.softDeleteById(
      'project-1',
      actor: departed,
      exemption: const MutationExemption.departedMember('project-1'),
    );
    await projects.restoreById(
      'project-1',
      actor: departed,
      exemption: const MutationExemption.departedMember('project-1'),
    );
    expect(await isDeleted('project-1'), isFalse);
  });

  test('a current member claiming it is refused', () async {
    // The exemption is re-derived from this device's rows, not believed. A
    // contributor who is still on the project must not be able to delete it
    // out from under the rest of the team by naming an exemption.
    await expectLater(
      projects.softDeleteById(
        'project-1',
        actor: stillOn,
        exemption: const MutationExemption.departedMember('project-1'),
      ),
      throwsA(isA<UnauthorizedMutation>()),
    );
    expect(await isDeleted('project-1'), isFalse);
  });

  test('somebody who was never a member is refused', () async {
    // "No open membership" is also true of everybody who has never been near
    // the project, which is why the check requires a *closed* stint as well.
    await expectLater(
      projects.softDeleteById(
        'project-1',
        actor: stranger,
        exemption: const MutationExemption.departedMember('project-1'),
      ),
      throwsA(isA<UnauthorizedMutation>()),
    );
    expect(await isDeleted('project-1'), isFalse);
  });

  test('naming one project while deleting another is refused', () async {
    // Without the key check, a past member of any project could name that
    // project's id while deleting a different one.
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
        actor: departed,
        exemption: const MutationExemption.departedMember('project-1'),
      ),
      throwsA(isA<UnauthorizedMutation>()),
    );
    expect(await isDeleted('project-2'), isFalse);
  });

  test('the ordinary owner-only rule is untouched without one', () async {
    await expectLater(
      projects.softDeleteById('project-1', actor: departed),
      throwsA(isA<UnauthorizedMutation>()),
    );
    // And an owner still needs no exemption at all.
    await projects.softDeleteById('project-1', actor: owner);
    expect(await isDeleted('project-1'), isTrue);
  });
}

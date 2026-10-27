import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/repositories/user_repository.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../fixtures.dart';

/// **`ProjectMembershipRepository.hasDeparted` — the one derivation of "have
/// I left this project"** (task 11.305), pinned on all three of its inputs.
///
/// Three states, one answer. An **open row** is a current member. A **closed
/// row and no open one** is a departure — the only `true`. **No row at all**
/// is neither: a purely local project has rows for nobody, and a project left
/// linked by a different account's session has none for the person now
/// signed in.
///
/// The third state is why this file exists. Until task 11.305 the sync round
/// classified a `403` against "no *open* row", which is true of the second
/// state *and* the third, while `SyncController.build` required the closed
/// row. So a second account signing in on a device still holding the first
/// account's linked project had its first automatic round read as *"you
/// left"* — the project was unlinked, the cursor erased, and the newcomer
/// told they were no longer on a project they were never on. The end-to-end
/// case is `sign_out_leaves_sync_state_test.dart`'s "Finding 3"; this is the
/// derivation those paths now share, tested where it lives.
void main() {
  late AppDatabase database;
  late ProjectMembershipRepository memberships;

  setUp(() async {
    database = await AppDatabase.openInMemory();
    memberships = ProjectMembershipRepository(database.raw);
    final users = UserRepository(database.raw);
    for (final id in ['user-owner', 'user-left', 'user-on', 'user-never']) {
      await users.insert(sampleUser(id: id, email: '$id@x.com'));
    }
    await ProjectRepository(
      database.raw,
    ).insert(sampleProject(id: 'project-1', ownerUserId: 'user-owner'));
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-owner',
        userId: 'user-owner',
      ).toColumns(),
    );
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-left',
        userId: 'user-left',
        role: ProjectRole.contributor,
        endDate: DateTime.utc(2026, 8, 20),
      ).toColumns(),
    );
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-on',
        userId: 'user-on',
        role: ProjectRole.contributor,
      ).toColumns(),
    );
  });

  tearDown(() => database.close());

  test('an open row is a current member, not a departure', () async {
    expect(await memberships.hasDeparted('project-1', 'user-on'), isFalse);
    expect(await memberships.hasDeparted('project-1', 'user-owner'), isFalse);
  });

  test('a closed row and no open one is a departure', () async {
    expect(await memberships.hasDeparted('project-1', 'user-left'), isTrue);
  });

  test(
    'no row at all is not a departure — the case the sync round got wrong',
    () async {
      // `user-never` has never been recorded on this project. "No open row"
      // is true of them, and reading that as "left" is the defect: it told a
      // person they had left a project they were never on, and unlinked it.
      expect(await memberships.hasDeparted('project-1', 'user-never'), isFalse);
    },
  );

  test('a project with no rows for anybody is nobody\'s departure', () async {
    await database.raw.delete(Tables.projectMemberships);
    for (final id in ['user-owner', 'user-left', 'user-on', 'user-never']) {
      expect(await memberships.hasDeparted('project-1', id), isFalse);
    }
  });

  test('a closed row beside a fresh open one is a current member', () async {
    // Re-admitted: the old stint is closed and a new one is open. The open
    // row wins, because it is the one that says what is true now.
    await database.raw.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'membership-left-again',
        userId: 'user-left',
        role: ProjectRole.contributor,
      ).toColumns(),
    );
    expect(await memberships.hasDeparted('project-1', 'user-left'), isFalse);
  });

  test('a tombstoned row counts as closed', () async {
    // `findForUser` excludes tombstones, so a row soft-deleted by a merge
    // reads exactly as an ended one: no open row, and a row on record.
    await database.raw.update(
      Tables.projectMemberships,
      {'deleted_at': DbCodec.encodeUtc(DateTime.utc(2026, 8, 21))},
      where: 'membership_id = ?',
      whereArgs: ['membership-on'],
    );
    expect(await memberships.hasDeparted('project-1', 'user-on'), isTrue);
  });
}

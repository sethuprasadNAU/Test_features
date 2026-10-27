@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/sync/pending_departure.dart';
import 'package:tritrack/data/sync/project_joiner.dart';
import 'package:tritrack/data/sync/project_publisher.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// **Task 11.57 — the whole membership cycle, in every ordering, on two
/// devices.**
///
/// ## Why a matrix rather than four tests named after four symptoms
///
/// Task 11.54's field report carried four defects, and all four came out of
/// **two orderings of the cycle, walked once each**. Every step is fine on its
/// own; the transitions are not. So what is asserted here is the cycle —
/// *create → share the code → ask → be approved → work → (leave | be removed)
/// → delete → get back on
/// → rejoin* — over the orderings that can actually occur, enumerated in code
/// rather than chosen by hand, with each ordering run against the real server
/// on two genuinely different accounts.
///
/// The enumeration is [_orderings]: how the stint ends (three ways, including
/// *it doesn't*), crossed with when the person deletes their local copy (three
/// times, including *never*). The way back is not a third dimension because it
/// is not free — it is a **consequence** of the first: somebody still on the
/// project comes back through "Join a project", and somebody who is off it
/// has to ask again with the code. Making it a dimension would have written four
/// impossible cases and asserted something about none of them.
///
/// ## The invariant every ordering is checked against
///
/// > **A device is never left holding a project it is a member of and cannot
/// > reach.**
///
/// That is [_assertNotLockedOut], and it is asked after every step of every
/// ordering rather than at the end — the lockout Michael hit on 2026-08-29 was
/// reached in the middle of a cycle, not at the end of one, and a check that
/// only runs at the end would have walked straight past it.
///
/// ## Both directions of removal, which is what had never been walked
///
/// [StintEnd.ownerRemoves] is the direction no test and no hardware round had
/// ever taken: every earlier walk had the *member* leave. It is the reason this
/// file is a matrix.
void main() {
  group('the membership cycle, both directions, over real HTTP', skip: e2eSkipReason, () {
    for (final ordering in _orderings) {
      test(ordering.description, () async {
        await _walk(ordering);
      });
    }

    // **The ordering Michael actually walked on 2026-08-29**, which the eight
    // above cannot reach because they all have a working connection: leave at a
    // trailhead, so the departure is written and never sent, then delete the
    // project. It is its own test rather than a ninth cell because the variable
    // is not the ordering — it is whether the network was there.
    test(
      'a departure that never reached the server, and then the project is '
      'deleted',
      () async {
        final now = DateTime.utc(2026, 8, 29, 12);
        final owner = await E2eDevice.create();
        await owner.signIn(randomEmail(), firstName: 'Ada', lastName: 'Owner');
        final member = await E2eDevice.create();
        await member.signIn(randomEmail(), firstName: 'Kim', lastName: 'Member');
        final projectId = 'e2e-stuck-${randomId()}';

        await seedLocalProject(
          owner.db.raw,
          projectId: projectId,
          ownerId: owner.userId,
          deviceId: owner.deviceId,
          now: now,
        );
        await ProjectPublisher(
          db: owner.db.raw,
          transport: owner.transport(),
          state: owner.state,
          deviceId: owner.deviceId,
          userId: owner.userId,
        ).publish(projectId, now: now);
        await owner.admit(member, projectId: projectId);
        await _joinerFor(member).join(projectId);

        // **Leaving with nothing to leave through.** The row is written and the
        // push never happens — which is what an unreachable server leaves
        // behind, and what `MembershipController.leaveProject` correctly
        // tolerates: it does not unlink, because unlinking would strand the
        // departure with nothing left to push it.
        await ProjectMembershipRepository(member.db.raw).leaveProject(
          projectId: projectId,
          actor: MutationActor.user(member.userId),
          now: DateTime.now().toUtc(),
          deviceId: member.deviceId,
        );
        await _deleteLocalCopy(member, projectId, hasLeft: true);

        // The state Michael's phone was in: a member on the server, holding a
        // hidden copy, shown nothing at all.
        expect(
          (await member.transport().listMyProjects()).map((p) => p.projectId),
          contains(projectId),
          reason: 'the server should still have them as a member here',
        );
        await _assertNotLockedOut(
          member,
          projectId,
          'after leaving out of signal and deleting the project',
        );

        // **Item 4: the way out.** Nothing else can offer this row — the
        // project is deleted, so it is never the active one, and sync acts on
        // the active project. This is what runs on every app foreground.
        final stuck = await findUndeliveredDepartures(
          db: member.db.raw,
          state: member.state,
          userId: member.userId,
        );
        expect(
          stuck.map((d) => d.projectId),
          [projectId],
          reason:
              'a departure written on a deleted project must still be findable, '
              'or it can never be delivered',
        );
        await _pushAndTolerateTheDoorClosing(member, projectId);

        final stored = await _serverMembershipFor(
          owner,
          projectId,
          member.userId,
        );
        expect(
          stored?['end_date'],
          isNotNull,
          reason: 'the recovered departure still has not reached the server',
        );
        expect(
          await findUndeliveredDepartures(
            db: member.db.raw,
            state: member.state,
            userId: member.userId,
          ),
          isEmpty,
          reason:
              'a delivered departure must stop being pending, or every '
              'foreground re-sends it forever',
        );

        // And now a request can be made and approved, which it could not be
        // while the server still had them as a member — the code would have
        // drawn `already_a_member` instead.
        await owner.admit(member, projectId: projectId);
        await _joinerFor(member).join(projectId);
        final project = await _localProjectRow(member, projectId);
        expect(project?['deleted_at'], isNull);
      },
    );
  });
}

/// How a person's stint on a project comes to an end — or doesn't.
enum StintEnd {
  /// Nobody ends anything. The person is still on the project throughout,
  /// which is the state in which a lost local copy is *only* recoverable from
  /// "Join a project": the server correctly refuses a join request from
  /// somebody who is already a member.
  staysAMember,

  /// The person leaves, from their own device — the only direction that had
  /// ever been walked before task 11.57.
  memberLeaves,

  /// An owner removes them, from the owner's device. Never walked before.
  ownerRemoves,
}

/// When the person deletes their own copy of the project.
enum DeleteTiming {
  never,

  /// While they are still on the project. Innocuous-looking, and it is the
  /// pure form of the lockout: the server still says they are a member, so no
  /// request can be made and approved, and until task 11.57 the project was
  /// excluded from "Join a project" because a tombstoned local row counted as
  /// "already have it".
  whileStillOnIt,

  /// After the stint has ended — the ordering Michael actually walked.
  afterTheStintEnds,
}

class _Ordering {
  const _Ordering(this.stintEnd, this.deleteTiming);
  final StintEnd stintEnd;
  final DeleteTiming deleteTiming;

  /// Whether the person is still on the project when the walk reaches the
  /// "get back to it" step — which is what decides the way back, rather than
  /// the test choosing one.
  bool get stillAMember => stintEnd == StintEnd.staysAMember;

  String get description =>
      '${_stintWords[stintEnd]}, ${_deleteWords[deleteTiming]}';

  static const _stintWords = {
    StintEnd.staysAMember: 'still on the project',
    StintEnd.memberLeaves: 'the member leaves',
    StintEnd.ownerRemoves: 'an owner removes them',
  };
  static const _deleteWords = {
    DeleteTiming.never: 'never deleting their copy',
    DeleteTiming.whileStillOnIt: 'deleting their copy while still on it',
    DeleteTiming.afterTheStintEnds: 'deleting their copy afterwards',
  };
}

/// The cross product, minus the one cell that cannot occur.
///
/// **Enumerated rather than listed**, which is the acceptance: a fourth way a
/// stint can end lands here without anybody remembering to add six tests.
/// `staysAMember` × `afterTheStintEnds` is the single exclusion, and it is
/// excluded because there is no "afterwards" — not because it is uninteresting.
final List<_Ordering> _orderings = [
  for (final stintEnd in StintEnd.values)
    for (final deleteTiming in DeleteTiming.values)
      if (!(stintEnd == StintEnd.staysAMember &&
          deleteTiming == DeleteTiming.afterTheStintEnds))
        _Ordering(stintEnd, deleteTiming),
];

Future<void> _walk(_Ordering ordering) async {
  final now = DateTime.utc(2026, 8, 29, 12);
  final owner = await E2eDevice.create();
  await owner.signIn(randomEmail(), firstName: 'Ada', lastName: 'Owner');
  final member = await E2eDevice.create();
  await member.signIn(randomEmail(), firstName: 'Kim', lastName: 'Member');

  final projectId = 'e2e-cycle-${randomId()}';

  // --- add: the owner creates a project and publishes it -------------------
  await seedLocalProject(
    owner.db.raw,
    projectId: projectId,
    ownerId: owner.userId,
    deviceId: owner.deviceId,
    now: now,
  );
  await ProjectPublisher(
    db: owner.db.raw,
    transport: owner.transport(),
    state: owner.state,
    deviceId: owner.deviceId,
    userId: owner.userId,
  ).publish(projectId, now: now);

  // --- ask, be approved, and join -------------------------------------------
  // **The role is a consequence of the ordering, not a third dimension.**
  // Deleting your own copy of a project you are *still on* is an owner's
  // action: `Projects` is [MutationRule.owner], and the departed-member
  // exemption only applies once you have left. So the orderings that delete
  // while still a member run as a co-owner, which task 11.1 makes an ordinary
  // configuration — and the orderings that do not, run as a contributor, which
  // is the commoner case. Picking one role for all eight would have made half
  // the matrix unreachable through the app.
  final role = ordering.deleteTiming == DeleteTiming.whileStillOnIt
      ? ProjectRole.owner
      : ProjectRole.contributor;
  await owner.admit(member, projectId: projectId, role: role);
  await _joinerFor(member).join(projectId);
  expect(
    await _localProjectRow(member, projectId),
    isNotNull,
    reason: 'redeeming and joining must put the project on the device',
  );

  // --- work: a bearing that exists only on the member's device --------------
  final observationId = 'e2e-obs-${randomId()}';
  await member.db.raw.insert(
    Tables.observations,
    observationRow(
      observationId,
      projectId: projectId,
      userId: member.userId,
      deviceId: member.deviceId,
      now: now,
    ),
  );
  await _assertNotLockedOut(member, projectId, 'after joining');

  if (ordering.deleteTiming == DeleteTiming.whileStillOnIt) {
    await _deleteLocalCopy(member, projectId, hasLeft: false);
    await _assertNotLockedOut(
      member,
      projectId,
      'after deleting their copy while still on the project',
    );
  }

  // --- the stint ends, one way or the other --------------------------------
  switch (ordering.stintEnd) {
    case StintEnd.staysAMember:
      break;
    case StintEnd.memberLeaves:
      await _memberLeaves(member, projectId);
    case StintEnd.ownerRemoves:
      await _ownerRemoves(owner, member.userId, projectId);
  }

  if (ordering.stintEnd != StintEnd.staysAMember) {
    // **Item 3, and the whole of the removal direction.** Read from the
    // server's own table rather than from either device's copy of it: task
    // 11.54's report could not tell "the departure never left the phone" from
    // "it reached the server and the Mac never showed it", and those need
    // different fixes.
    final stored = await _serverMembershipFor(owner, projectId, member.userId);
    expect(
      stored,
      isNotNull,
      reason:
          'the server holds no membership row at all for the person whose '
          'stint just ended',
    );
    expect(
      stored!['end_date'],
      isNotNull,
      reason:
          'the stint ended on a device and the server still shows it open, so '
          'nobody else will ever learn it ended. Ordering: '
          '${ordering.description}',
    );
  }

  if (ordering.deleteTiming == DeleteTiming.afterTheStintEnds) {
    if (ordering.stintEnd == StintEnd.ownerRemoves) {
      await _removedMemberDeletesTheirCopy(member, projectId);
    } else {
      await _deleteLocalCopy(member, projectId, hasLeft: true);
    }
  }
  await _assertNotLockedOut(member, projectId, 'after ${ordering.description}');

  // --- the way back, which the ordering decides rather than the test --------
  if (ordering.stillAMember) {
    // Still on the project: a code cannot be issued (the server is right to
    // refuse one), so "Join a project" is the only route and must offer it.
    final available = await _directoryFor(member).listAvailableToJoin();
    if (ordering.deleteTiming == DeleteTiming.never) {
      expect(
        available.map((p) => p.projectId),
        isNot(contains(projectId)),
        reason:
            'the project is on this device and syncing, so offering it as '
            'something to join would be offering a second copy of one project',
      );
    } else {
      expect(
        available.map((p) => p.projectId),
        contains(projectId),
        reason:
            'this device is a member of a project it cannot see, and "Join a '
            'project" is the only route back to it',
      );
      await _joinerFor(member).join(projectId);
    }
  } else {
    // **The return path for somebody whose stint ended.** Under task 11.81
    // there are two, and this walks the one that needs no owner-side lookup:
    // they ask again with the project's code and the owner approves. The other
    // — the owner putting them back directly with `readmitMember` — is covered
    // by `join_code_and_approval_e2e_test.dart`.
    await owner.admit(member, projectId: projectId, role: role);
    await _joinerFor(member).join(projectId);
  }

  // --- back on it, and holding what it held ---------------------------------
  final project = await _localProjectRow(member, projectId);
  expect(
    project,
    isNotNull,
    reason: 'the project is not on the device after coming back to it',
  );
  expect(
    project!['deleted_at'],
    isNull,
    reason:
        'the project came back invisible — a local tombstone still hides a '
        'project this device has just been granted',
  );
  expect(
    await member.state.isProjectLinked(projectId),
    isTrue,
    reason: 'back on the project but not syncing it',
  );
  final kept = await member.db.raw.query(
    Tables.observations,
    where: 'observation_id = ?',
    whereArgs: [observationId],
  );
  expect(
    kept,
    hasLength(1),
    reason:
        'the bearing this device recorded before the round trip is gone — '
        'coming back must relink what is here, not fetch a fresh copy over '
        'the top of it',
  );

  // And it can finally reach the server, which is what "not stranded" means.
  await _engineFor(member).run(projectId);
  final onServer = await _serverRows(owner, projectId, Tables.observations);
  expect(
    onServer.map((r) => r['observation_id']),
    contains(observationId),
    reason:
        'the record that was stranded on this device while it was locked out '
        'still has not reached the server after rejoining',
  );
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

SyncEngine _engineFor(E2eDevice device) => SyncEngine(
  db: device.db.raw,
  transport: device.transport(),
  state: device.state,
  deviceId: device.deviceId,
  userId: device.userId,
);

ProjectJoiner _joinerFor(E2eDevice device) => ProjectJoiner(
  db: device.db.raw,
  transport: device.transport(),
  state: device.state,
  deviceId: device.deviceId,
  userId: device.userId,
);

ProjectDirectoryClient _directoryFor(E2eDevice device) => ProjectDirectoryClient(
  db: device.db.raw,
  transport: device.transport(),
  state: device.state,
);

/// The member ends their own stint and pushes it, which is what
/// `MembershipController.leaveProject` does around this repository call.
Future<void> _memberLeaves(E2eDevice member, String projectId) async {
  await ProjectMembershipRepository(member.db.raw).leaveProject(
    projectId: projectId,
    actor: MutationActor.user(member.userId),
    now: DateTime.now().toUtc(),
    deviceId: member.deviceId,
  );
  await _pushAndTolerateTheDoorClosing(member, projectId);
}

/// **A round that delivers a departure fails on its own second half, every
/// time.** The engine pushes, the server takes the departure, and the pull that
/// follows is refused because the person is — correctly, and as of that instant
/// — no longer a member. Measured against the real server on 2026-08-29;
/// `MembershipController.leaveProject` swallows exactly this, and a test that
/// did not would be asserting that leaving a project is broken.
Future<void> _pushAndTolerateTheDoorClosing(
  E2eDevice device,
  String projectId,
) async {
  try {
    await _engineFor(device).run(projectId);
  } on SyncTransportException catch (_) {
    // Expected. Whether the departure landed is asserted from the server's own
    // table, not from whether this threw.
  }
}

/// An owner ends somebody else's stint and pushes it — the direction that had
/// never been walked.
Future<void> _ownerRemoves(
  E2eDevice owner,
  String memberUserId,
  String projectId,
) async {
  final repo = ProjectMembershipRepository(owner.db.raw);
  // The owner's device learns of the membership by pulling it, exactly as the
  // members screen does.
  await _engineFor(owner).run(projectId);
  final theirs = await repo.findForUser(projectId, memberUserId);
  expect(
    theirs,
    isNotNull,
    reason:
        "the owner's device never received the membership row for the person "
        'it is about to remove, so the members screen would show nobody to '
        'remove',
  );
  await repo.endMembership(
    theirs!,
    actor: MutationActor.user(owner.userId),
    now: DateTime.now().toUtc(),
    deviceId: owner.deviceId,
  );
  await _engineFor(owner).run(projectId);
}

/// **A person an owner removed deletes their own copy — after one sync, and
/// through the path that already existed.**
///
/// ## What this asserted until task 11.60, and why it changed
///
/// Task 11.54 gave a departed member the Delete control by way of
/// `MutationExemption.departedMember`, which verifies against the *local*
/// membership rows: no open stint, and a closed one. That held for somebody who
/// left. It did not hold for somebody an owner removed, **because their device
/// never learned it had happened** — the pull that would carry the closed row
/// was the request the server was refusing. They were left with a project they
/// could not use, could not leave the ordinary way, and could not delete. This
/// function asserted exactly that, in both halves, so that the day it stopped
/// being true somebody would have to come here and say so.
///
/// This is that day. Michael decided on 2026-08-29 that **the server tells
/// them**: a pull from a device whose stint has ended is answered with that
/// person's own closed membership row and nothing else (Security Model §4.27,
/// trust-boundary inventory entry 28). So the walk is now:
///
/// 1. **Before the news, the delete is still refused** — locally they are still
///    a member, and nothing about the exemption changed. Kept, because it is
///    what makes step 3 mean something.
/// 2. **One ordinary sync**, which is what the app runs on every foreground.
///    The round fails, correctly — the push is refused — and the pull inside it
///    carries the closed row anyway.
/// 3. **The same delete call, unchanged, now works.** Not a second mechanism
///    and not a different exemption: the local evidence it always read is
///    finally true.
///
/// **What is gone is the "press Leave first" step**, which was the route out
/// nothing in the app ever told anybody about.
Future<void> _removedMemberDeletesTheirCopy(
  E2eDevice member,
  String projectId,
) async {
  await expectLater(
    _deleteLocalCopy(member, projectId, hasLeft: true),
    throwsA(isA<UnauthorizedMutation>()),
    reason:
        'A removed member could delete their own copy before their device had '
        'been told anything. The departed-member exemption reads local '
        'membership rows, and locally this person is still a member — so this '
        'passing early means the exemption has stopped checking.',
  );

  // The news arrives through the one request that can carry it. The round
  // itself fails: this device has records the server will not take, and
  // reporting otherwise would claim they arrived.
  await _pushAndTolerateTheDoorClosing(member, projectId);

  final local = await ProjectMembershipRepository(
    member.db.raw,
  ).findForUser(projectId, member.userId);
  expect(
    local,
    isNull,
    reason:
        'the device still holds an open stint after syncing, so it never '
        'learned it was removed — and everything below is back to needing a '
        '"press Leave first" step nothing tells anybody about (§4.27)',
  );

  // The same call as every other delete in this file. No second mechanism.
  await _deleteLocalCopy(member, projectId, hasLeft: true);
}

Future<void> _deleteLocalCopy(
  E2eDevice device,
  String projectId, {
  required bool hasLeft,
}) async {
  await ProjectRepository(device.db.raw).softDeleteById(
    projectId,
    actor: MutationActor.user(device.userId),
    deviceId: device.deviceId,
    exemption: hasLeft ? MutationExemption.departedMember(projectId) : null,
  );
}

// ---------------------------------------------------------------------------
// Questions
// ---------------------------------------------------------------------------

/// **The invariant, asked after every step.**
///
/// A device is locked out when the server says this person is a member of a
/// project and the device offers them no way to reach it: not present and
/// visible locally, and not listed under "Join a project" either. That is the
/// state Michael's phone was in on 2026-08-29, and its defining property is
/// that nothing on the device says so.
Future<void> _assertNotLockedOut(
  E2eDevice device,
  String projectId,
  String when,
) async {
  final serverSaysMember = (await device.transport().listMyProjects())
      .any((p) => p.projectId == projectId);
  if (!serverSaysMember) return;

  final local = await _localProjectRow(device, projectId);
  final visibleHere = local != null && local['deleted_at'] == null;
  final linkedHere = await device.state.isProjectLinked(projectId);
  if (visibleHere && linkedHere) return;

  final offered = (await _directoryFor(device).listAvailableToJoin())
      .map((p) => p.projectId);
  expect(
    offered,
    contains(projectId),
    reason:
        'Locked out $when: the server says this person is a member of this '
        'project, the device is not showing it (present: ${local != null}, '
        'visible: $visibleHere, syncing: $linkedHere), and "Join a project" '
        'does not offer it either. There is no route back and nothing says so.',
  );
}

Future<Map<String, Object?>?> _localProjectRow(
  E2eDevice device,
  String projectId,
) async {
  final rows = await device.db.raw.query(
    Tables.projects,
    where: 'project_id = ?',
    whereArgs: [projectId],
    limit: 1,
  );
  return rows.isEmpty ? null : rows.first;
}

/// **The server's own copy of a table**, read through an ordinary pull from
/// cursor zero rather than through either device's merged database.
///
/// [reader] must still be a member — a removed one is refused the project
/// entirely, which is the server behaving correctly and is why every call here
/// reads as the owner.
Future<List<Map<String, Object?>>> _serverRows(
  E2eDevice reader,
  String projectId,
  String table,
) async {
  final rows = <Map<String, Object?>>[];
  var cursor = 0;
  while (true) {
    final page = await reader.transport().pull(
      SyncPullRequest(
        projectId: projectId,
        deviceId: 'e2e-reader-${reader.deviceId}',
        cursor: cursor,
      ),
    );
    rows.addAll(page.rows[table] ?? const []);
    if (!page.hasMore) break;
    cursor = page.nextCursor;
  }
  return rows;
}

Future<Map<String, Object?>?> _serverMembershipFor(
  E2eDevice reader,
  String projectId,
  String userId,
) async {
  final rows = await _serverRows(reader, projectId, Tables.projectMemberships);
  final mine = rows.where((r) => r['user_id'] == userId).toList();
  return mine.isEmpty ? null : mine.last;
}

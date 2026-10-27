@Tags(['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/project_publisher.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'support/e2e_env.dart';
import 'support/e2e_harness.dart';

/// **Task 11.81 — the join code and the owner's approval, against a real
/// server.**
///
/// ## What this file exists to prove, and why a unit test cannot
///
/// The whole design rests on one sentence: **holding the code buys the right to
/// ask, and only the owner's approval creates a membership.** Everything else —
/// the entropy argument in `join_code.dart`, §4.2.1's exception permitting the
/// code to be stored readably, the acceptance that a correct guess confirms a
/// project exists — is downstream of that sentence being true *of the server*.
///
/// A fake can be made to model it, and `join_request_test.dart` checks that the
/// client half behaves. Only a real server can show that a real request writes
/// no membership row into a real Postgres, and that the row appears when, and
/// only when, an owner approves.
///
/// ## Two people, deliberately
///
/// Both accounts are genuinely different — separate addresses, separate
/// sessions, separate `user_id`s — because a requester and an owner who are the
/// same person cannot demonstrate an approval at all.
void main() {
  group('the join code, over real HTTP', () {
    late E2eDevice owner;
    late E2eDevice newcomer;
    late String projectId;
    final now = DateTime.utc(2026, 8, 31, 9);

    setUp(() async {
      owner = await E2eDevice.create();
      newcomer = await E2eDevice.create();
      await owner.signIn(randomEmail());
      await newcomer.signIn(randomEmail());
      projectId = 'project-${randomId()}';
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
    });

    test('a project with no settings row has joining OFF — fail closed', () async {
      // **The single most dangerous line in this change, asked of the real
      // server.** Every project that existed before task 11.81 is in exactly
      // this state, and a "create the row on first read, enabled" convenience
      // would have opened all of them at once. Reading must not create.
      final settings = await owner.transport().joinSettings(projectId);
      expect(settings.joiningEnabled, isFalse);
      expect(settings.code, isNull);

      // Read it twice: if the first read had quietly created a row, the second
      // would be the one that looked innocent.
      final again = await owner.transport().joinSettings(projectId);
      expect(again.joiningEnabled, isFalse);
      expect(again.code, isNull);
    });

    test('a correct code produces a request and no membership', () async {
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      expect(settings.code, isNotNull);

      final created = await newcomer.transport().requestToJoin(
        code: settings.code!,
        claimedName: 'Dana Reyes',
      );
      expect(created.projectName, isNotEmpty);

      // **Nothing was granted.** The newcomer's own project directory is the
      // server's own answer to "what may I sync", so this is the assertion that
      // matters most in the file.
      expect(
        (await newcomer.transport().listMyProjects()).map((p) => p.projectId),
        isNot(contains(projectId)),
        reason: 'holding the code granted access, which is the whole failure '
            'this design exists to prevent',
      );

      final pending = await owner.transport().joinRequests(projectId);
      expect(pending.where((r) => r.isPending), hasLength(1));
      // The email the owner sees is the one the *server* authenticated, and
      // the name is what the requester claimed — presented as two fields
      // precisely because they are not equally trustworthy.
      expect(pending.single.email, normalizeEmail(newcomer.signedInEmail));
      expect(pending.single.claimedName, 'Dana Reyes');
    });

    test('approval is what grants, and the role comes from the approval',
        () async {
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      await newcomer.transport().requestToJoin(code: settings.code!);
      final pending = await owner.transport().joinRequests(projectId);

      await owner.transport().approveJoinRequest(
        projectId: projectId,
        requestId: pending.single.requestId,
        // The code carried no role and could not have — deliberately, so that
        // there is no such thing as a leaked *owner* code.
        role: ProjectRole.viewer,
      );

      final mine = await newcomer.transport().listMyProjects();
      final joined = mine.where((p) => p.projectId == projectId);
      expect(joined, hasLength(1));
      expect(joined.single.role, ProjectRole.viewer.db);
    });

    test('a rejected requester is told, rather than left waiting', () async {
      // The class task 11.60 found for removed members, answered here before
      // it could happen a second time.
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      await newcomer.transport().requestToJoin(code: settings.code!);
      final pending = await owner.transport().joinRequests(projectId);
      await owner.transport().rejectJoinRequest(
        projectId: projectId,
        requestId: pending.single.requestId,
      );

      final mine = await newcomer.transport().myJoinRequests();
      expect(mine.where((r) => r.decision == 'rejected'), hasLength(1));
      expect(
        (await newcomer.transport().listMyProjects()).map((p) => p.projectId),
        isNot(contains(projectId)),
      );
    });

    test('a wrong code and a switched-off code answer identically', () async {
      // **The existence oracle.** If these differed, somebody sweeping codes
      // could learn which guesses named a real project. Compared to each other
      // rather than to a constant, which is the technique task 11.9 established
      // for this class of check.
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      final realCode = settings.code!;
      await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: false,
      );

      final reasons = <String>{};
      for (final attempt in [realCode, 'ZZZZ9999', 'QQQQ1111']) {
        try {
          await newcomer.transport().requestToJoin(code: attempt);
          fail('$attempt should not have produced a request');
        } on SyncTransportException catch (e) {
          reasons.add('${e.statusCode}:${e.reason}');
        }
      }
      expect(
        reasons,
        hasLength(1),
        reason: 'a real project with joining off is distinguishable from a '
            'code that names nothing',
      );
    });

    test('rotation mints a new code and keeps pending requests by default',
        () async {
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      await newcomer.transport().requestToJoin(code: settings.code!);

      final rotated = await owner.transport().rotateJoinCode(
        projectId: projectId,
      );
      expect(rotated.code, isNot(settings.code));
      expect(
        rotated.clearedPending,
        0,
        reason: 'pending requests survive a rotation unless the owner asks',
      );
      expect(
        (await owner.transport().joinRequests(
          projectId,
        )).where((r) => r.isPending),
        hasLength(1),
      );

      // **And the code is re-readable**, which is the whole of what §4.2.1's
      // exception buys: an owner who closed the screen does not have to rotate
      // and re-broadcast to a whole crew.
      expect(
        (await owner.transport().joinSettings(projectId)).code,
        rotated.code,
      );
    });

    test('clearing on rotation marks requests cleared rather than deleting them',
        () async {
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      await newcomer.transport().requestToJoin(code: settings.code!);

      final rotated = await owner.transport().rotateJoinCode(
        projectId: projectId,
        clearPending: true,
      );
      expect(rotated.clearedPending, 1);
      // Marked, not deleted — so the person's own status read tells them their
      // request is gone instead of leaving them on "pending" forever.
      final mine = await newcomer.transport().myJoinRequests();
      expect(mine.single.decision, 'cleared');
    });

    test('the team-size limit counts pending requests, and says so', () async {
      await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
        // The owner already occupies one place, so one more admits nobody.
        teamSizeLimit: 1,
      );
      final settings = await owner.transport().joinSettings(projectId);
      expect(settings.memberCount, 1);

      await expectLater(
        newcomer.transport().requestToJoin(code: settings.code!),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            joinRefusalTeamFull,
          ),
        ),
      );
    });

    test('re-admission puts a past member back and cannot add a stranger',
        () async {
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      await newcomer.transport().requestToJoin(code: settings.code!);
      final pending = await owner.transport().joinRequests(projectId);
      await owner.transport().approveJoinRequest(
        projectId: projectId,
        requestId: pending.single.requestId,
        role: ProjectRole.contributor,
      );

      // A stranger — nobody with any history on this project — is refused, and
      // that bound is what makes the route safe at all.
      await expectLater(
        owner.transport().readmitMember(
          projectId: projectId,
          userId: 'user-${randomId()}',
          role: ProjectRole.owner,
        ),
        throwsA(isA<SyncTransportException>()),
      );

      // And so is somebody who is currently *on* the project: "already in" and
      // "never was" answer the same, so this route cannot be used to ask
      // questions about a user id.
      await expectLater(
        owner.transport().readmitMember(
          projectId: projectId,
          userId: newcomer.userId,
          role: ProjectRole.contributor,
        ),
        throwsA(isA<SyncTransportException>()),
      );
    });

    test('a non-owner reaches none of the owner routes', () async {
      // Refused identically to a project that does not exist — §4.13, through
      // the same `_requireOwner` every other owner route uses.
      final statuses = <int?>{};
      for (final attempt in <Future<void> Function()>[
        () => newcomer.transport().joinSettings(projectId),
        () => newcomer.transport().updateJoinSettings(
          projectId: projectId,
          joiningEnabled: true,
        ),
        () => newcomer.transport().rotateJoinCode(projectId: projectId),
        () => newcomer.transport().joinRequests(projectId),
        () => newcomer.transport().approveJoinRequest(
          projectId: projectId,
          requestId: 'req-${randomId()}',
          role: ProjectRole.owner,
        ),
        () => newcomer.transport().rejectJoinRequest(
          projectId: projectId,
          requestId: 'req-${randomId()}',
        ),
        () => newcomer.transport().readmitMember(
          projectId: projectId,
          userId: newcomer.userId,
          role: ProjectRole.owner,
        ),
      ]) {
        try {
          await attempt();
          fail('a non-owner reached an owner-only route');
        } on SyncTransportException catch (e) {
          statuses.add(e.statusCode);
        }
      }
      expect(statuses, {403});
    });

    test('a bidirectional-override character in a claimed name is refused',
        () async {
      // **The attack this screen is uniquely exposed to.** The owner's pending
      // list is the one place in TriTrack where a person decides whether to
      // trust somebody by reading a string, so a name that renders as a
      // colleague's is the thing worth refusing at the server rather than
      // trusting a text field to prevent.
      final settings = await owner.transport().updateJoinSettings(
        projectId: projectId,
        joiningEnabled: true,
      );
      await expectLater(
        newcomer.transport().requestToJoin(
          code: settings.code!,
          // U+202E RIGHT-TO-LEFT OVERRIDE, escaped because the Dart analyzer
          // itself refuses to have one sitting in a source literal — which is
          // the same judgement this test is asking the server to make.
          claimedName: 'Ann\u202Eeciov\u202D',
        ),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            joinRefusalInvalidName,
          ),
        ),
      );
      expect(await owner.transport().joinRequests(projectId), isEmpty);
    });
  }, skip: e2eSkipReason);
}

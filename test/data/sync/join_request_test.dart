import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/project_joiner.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// **Task 11.81, from the requester's device, with no server running.**
///
/// Phase 10's invariant 5 — no test suite may require a server — applies here
/// too, so this runs against `FakeSyncTransport`, which implements the same
/// refusal rules the real server does.
///
/// **The client-side shape being pinned, and it is the one that changed.**
/// Before task 11.81, typing a code *was* joining: the server wrote your
/// membership row on the spot. Now a code produces a **request**, an owner
/// approves it, and only then does a membership row exist — which this device
/// receives by ordinary pull, exactly as before. It never writes a membership
/// row of its own. That is why `ProjectMembershipRepository`'s insert doors
/// still have no entry for joining, and why the sync push path can go on
/// refusing every membership insert from a non-owner without an exemption to
/// get subtly wrong.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const deviceId = 'device-B';
  const bob = 'user-bob';
  final now = DateTime.utc(2026, 8, 1, 12);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport()
      ..sessionUserId = bob
      ..sessionEmail = 'bob@example.org';
    state = SyncStateStore(prefs: SharedPreferencesAsync());
    transport
      ..seedServerRow(Tables.users, _user('user-alice', 'alice@example.org', now))
      ..seedServerRow(Tables.users, _user(bob, 'bob@example.org', now))
      ..seedServerRow(Tables.projects, _project('proj-1', now))
      ..seedServerRow(
        Tables.observations,
        _observation('obs-1', 'proj-1', 'user-alice', now),
      );
  });

  tearDown(() => appDb.close());

  ProjectJoiner joiner() => ProjectJoiner(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: bob,
  );

  Future<List<Map<String, Object?>>> localMemberships() =>
      appDb.raw.query(Tables.projectMemberships);

  group('a code buys the right to ask, and nothing else', () {
    test('a request on its own grants no membership and downloads nothing',
        () async {
      // **The single most important assertion in this file.** If this ever
      // starts passing with a membership row present, the approval step has
      // been lost and a leaked code is a key again.
      final code = transport.enableJoining('proj-1');

      final created = await transport.requestToJoin(code: code);
      expect(created.projectName, 'Elk Study');

      expect(
        transport.serverRow(Tables.projectMemberships, 'membership-1'),
        isNull,
      );
      expect(
        (await transport.joinRequests('proj-1')).single.isPending,
        isTrue,
      );
      expect(await localMemberships(), isEmpty);
      expect(await state.isProjectLinked('proj-1'), isFalse);
    });

    test('an approved request brings the project down, membership included',
        () async {
      final code = transport.enableJoining('proj-1');
      final created = await transport.requestToJoin(code: code);
      await transport.approveJoinRequest(
        projectId: 'proj-1',
        requestId: created.requestId,
        role: ProjectRole.contributor,
      );

      await joiner().join('proj-1');

      expect(
        await appDb.raw.query(Tables.observations),
        hasLength(1),
        reason: 'the project history arrived',
      );
      final memberships = await localMemberships();
      expect(memberships, hasLength(1));
      expect(memberships.single['user_id'], bob);
      expect(memberships.single['role'], 'contributor');
      expect(memberships.single['end_date'], isNull);
    });

    test('a rejected request grants nothing, and the requester is told',
        () async {
      final code = transport.enableJoining('proj-1');
      final created = await transport.requestToJoin(code: code);
      await transport.rejectJoinRequest(
        projectId: 'proj-1',
        requestId: created.requestId,
      );

      expect(await localMemberships(), isEmpty);
      // **The half task 11.60 found missing for removed members**: being told,
      // rather than waiting forever on a screen that never changes.
      final mine = await transport.myJoinRequests();
      expect(mine.single.decision, 'rejected');
      expect(mine.single.isPending, isFalse);
    });

    test('the role comes from the approval, never from the code', () async {
      // There is no such thing as a leaked *owner* code, because the code
      // carries no role at all. Two requests on one code, admitted differently.
      final code = transport.enableJoining('proj-1');
      final created = await transport.requestToJoin(code: code);
      await transport.approveJoinRequest(
        projectId: 'proj-1',
        requestId: created.requestId,
        role: ProjectRole.viewer,
      );
      await joiner().join('proj-1');
      expect((await localMemberships()).single['role'], 'viewer');
    });
  });

  group('what the device never does', () {
    test('it does not push a membership row of its own', () async {
      // If the client ever started creating this row locally, it would be
      // creating a *grant* on a device an attacker controls — the exact reason
      // approval writes it server-side. Asserted on what went over the wire,
      // not on what ended up stored, because the stored row is legitimately
      // there after the pull.
      final code = transport.enableJoining('proj-1');
      final created = await transport.requestToJoin(code: code);
      await transport.approveJoinRequest(
        projectId: 'proj-1',
        requestId: created.requestId,
        role: ProjectRole.contributor,
      );
      await joiner().join('proj-1');

      for (final push in transport.pushes) {
        expect(
          push.rows[Tables.projectMemberships] ?? const [],
          isEmpty,
          reason: 'this device never proposes a membership row',
        );
      }
    });
  });

  group('refusals', () {
    test('joining switched off is refused exactly like a wrong code', () async {
      // **The existence oracle, closed.** If these two answered differently, a
      // caller sweeping codes would learn which guesses named a real project.
      final code = transport.enableJoining('proj-1');
      await transport.updateJoinSettings(
        projectId: 'proj-1',
        joiningEnabled: false,
      );

      final reasons = <String>[];
      for (final attempt in [code, 'ZZZZ9999', 'not-a-code']) {
        try {
          await transport.requestToJoin(code: attempt);
          fail('$attempt should not have produced a request');
        } on SyncTransportException catch (e) {
          reasons.add(e.reason);
        }
      }
      expect(reasons.toSet(), hasLength(1));
      expect(reasons.toSet().single, joinRefusalCodeNotValid);
      expect(await localMemberships(), isEmpty);
    });

    test('a project with no join settings at all refuses — fail closed',
        () async {
      // Every project that existed before task 11.81 is in exactly this state.
      // A fake (or a server) that created settings on first read with joining
      // enabled would open all of them at once.
      expect(
        (await transport.joinSettings('proj-1')).joiningEnabled,
        isFalse,
      );
      await expectLater(
        transport.requestToJoin(code: 'ABCD0001'),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            joinRefusalCodeNotValid,
          ),
        ),
      );
    });

    test('asking twice is refused, and says so rather than looking broken',
        () async {
      final code = transport.enableJoining('proj-1');
      await transport.requestToJoin(code: code);
      await expectLater(
        transport.requestToJoin(code: code),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            joinRefusalAlreadyRequested,
          ),
        ),
      );
    });

    test('the team-size limit counts people who are only waiting', () async {
      // The tidy consequence of counting pending toward the limit, and the
      // thing the refusal copy has to explain or nobody can act on it.
      final code = transport.enableJoining('proj-1', teamSizeLimit: 1);
      await expectLater(
        transport.requestToJoin(code: code),
        completes,
        reason: 'the project has no members yet, so one place is free',
      );
      transport.sessionUserId = 'user-carol';
      await expectLater(
        transport.requestToJoin(code: code),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            joinRefusalTeamFull,
          ),
        ),
      );
    });

    test('every refusal reaches the user as client-authored, actionable copy',
        () async {
      // §4.13: no server-supplied text becomes user-facing text. The code is a
      // fixed vocabulary; the sentence is written in the app. **A refusal code
      // with no sentence is a blank screen**, so this walks the whole
      // vocabulary rather than checking the two somebody remembered.
      for (final code in knownSyncRefusals) {
        final message = SyncTransportException(code, statusCode: 409)
            .userMessage;
        expect(
          message,
          isNotNull,
          reason: 'refusal "$code" has no app copy written for it',
        );
        expect(message, isNotEmpty);
      }
    });

    test('the code refusal no longer claims things that stopped being true',
        () async {
      // **Task 11.54's defect class, asserted rather than trusted.** The old
      // sentence said codes "expire, can only be used once, and only work for
      // the email address they were sent to". All three became false with the
      // join code, and copy describing a mechanism the code does not have is
      // the thing this assertion exists to catch coming back.
      final message = const SyncTransportException(
        joinRefusalCodeNotValid,
        statusCode: 403,
      ).userMessage!;
      expect(message, isNot(contains('expire')));
      expect(message, isNot(contains('once')));
      expect(message, isNot(contains('email address they were sent to')));
    });

    test('the team-full refusal says that waiting people count', () async {
      // Without this sentence, an owner reading "40 members, limit 50" and a
      // refusal has no way to understand it.
      final message = const SyncTransportException(
        joinRefusalTeamFull,
        statusCode: 409,
      ).userMessage!;
      expect(message, contains('approval'));
      expect(message.toLowerCase(), contains('limit'));
    });
  });

  group('re-admission', () {
    test('it can reverse a removal', () async {
      final code = transport.enableJoining('proj-1');
      final created = await transport.requestToJoin(code: code);
      await transport.approveJoinRequest(
        projectId: 'proj-1',
        requestId: created.requestId,
        role: ProjectRole.contributor,
      );
      // Close the stint the way a removal does.
      final granted = transport
          .serverRows(Tables.projectMemberships)
          .singleWhere((row) => row['user_id'] == bob);
      transport.seedServerRow(Tables.projectMemberships, {
        ...granted,
        'end_date': DbCodec.encodeUtc(now),
      });

      await expectLater(
        transport.readmitMember(
          projectId: 'proj-1',
          userId: bob,
          role: ProjectRole.contributor,
        ),
        completes,
      );
    });

    test('it cannot add a stranger', () async {
      // The bound that makes re-admission safe: it comes from the project's own
      // history, not from a list somebody maintains.
      await expectLater(
        transport.readmitMember(
          projectId: 'proj-1',
          userId: 'user-nobody',
          role: ProjectRole.owner,
        ),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            joinRefusalNotAPastMember,
          ),
        ),
      );
    });
  });

  test('a typed code survives case, spacing and the O/0 confusion', () async {
    final code = transport.enableJoining('proj-1');
    // `enableJoining` mints codes from the real alphabet, so this exercises the
    // same canonicalization a code read off a whiteboard goes through.
    final typed = formatJoinCode(code).toLowerCase().replaceAll('-', ' ');
    expect((await transport.requestToJoin(code: typed)).projectName, 'Elk Study');
  });
}

Map<String, Object?> _user(String id, String email, DateTime now) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'user_id': id,
    'first_name': 'Sam',
    'last_name': 'Ranger',
    'email': email,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': id,
    'origin_device_id': 'device-A',
  };
}

Map<String, Object?> _project(String id, DateTime now) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'project_id': id,
    'project_name': 'Elk Study',
    'owner_user_id': 'user-alice',
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': 'user-alice',
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };
}

Map<String, Object?> _observation(
  String id,
  String projectId,
  String userId,
  DateTime now,
) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': stamp,
    'timestamp_utc': stamp,
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };
}

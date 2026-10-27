@Tags(['postgres'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Task 11.291, over a real bound socket: what a device meets once the
/// tombstone sweep has actually run.
///
/// The sweep itself is `test/sync/tombstone_retention_test.dart`; this file
/// is about the wire. Two claims the task's acceptance names:
///
///   1. A device whose position predates the floor is refused **by name** —
///      `409 cursor_too_old`, the code the app has copy for — and **keeps its
///      own records**: nothing it offered is written, its recorded position
///      is untouched, and the one request it may still make (a full re-pull
///      from zero) is answered.
///   2. A device that only ever *pulls* has a recorded position and a fresh
///      sync time on this server, so the sweep's active-device holdback
///      knows it exists. Before this task the server recorded a position
///      only on `/sync/ack`, which the app sends only after a pull that
///      *moved* — so a project's publisher, or any device on a quiet
///      project, looked to the sweep like a device that had never been here.
void main() {
  late Connection connection;
  late Connection auditConnection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_tombstone_retention_routes_test';

  final captured = <String, String>{};

  const aliceEmail = 'alice@example.org';
  const projectA = 'proj-a';
  const at = '2026-08-01T12:00:00.000Z';
  const bobEmail = 'bob@example.org';
  const newPhone = 'phone-new';
  const oldPhone = 'phone-old';
  const bobPhone = 'phone-bob';
  final longAgo = DateTime.utc(2020, 1, 1);

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    auditConnection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await auditConnection.close();
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    captured.clear();
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await auditConnection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);

    EmailSender sender() => _CapturingSender(captured);

    final handler = createHandler(
      withAuthService: <T>(action) => connection.runTx(
        (tx) => action(
          AuthService(
            session: tx,
            emailSender: sender(),
            linkBaseUrl: 'http://test',
          ),
        ),
      ),
      withSyncContext: (request, action) async {
        final token = bearerToken(request);
        if (token == null) return _unauthorized();
        return connection.runTx((tx) async {
          final auth = AuthService(
            session: tx,
            emailSender: sender(),
            linkBaseUrl: 'http://test',
          );
          final activeSession = await auth.validateSession(token);
          if (activeSession == null) return _unauthorized();
          return action(
            SyncContext(
              sync: SyncService(session: tx),
              cursors: CursorStore(tx),
              session: activeSession,
              trafficLog: SyncTrafficLogStore(tx),
            ),
          );
        });
      },
      withAuditLog: (action) => auditConnection.runTx(
        (tx) => action(
          AuthAuditLog(
            tx,
            onError: (type) => throw StateError('audit write failed: $type'),
          ),
        ),
      ),
    );

    server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    baseUri = Uri.parse('http://${server.address.address}:${server.port}');
  });

  tearDown(() => server.close(force: true));

  // ---- harness ------------------------------------------------------------

  Future<({String token, String userId})> signIn(
    String email, {
    required String deviceId,
  }) async {
    await http.post(
      baseUri.replace(path: '/auth/magic-link'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    final token = Uri.parse(captured[email]!).queryParameters['token']!;
    final redeemed =
        jsonDecode(
              (await http.post(
                baseUri.replace(path: '/auth/redeem'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({'token': token, 'device_id': deviceId}),
              )).body,
            )
            as Map<String, Object?>;
    return (
      token: redeemed['session_token']! as String,
      userId: redeemed['user_id']! as String,
    );
  }

  Map<String, String> authHeaders(String token) => {
    'content-type': 'application/json',
    'authorization': 'Bearer $token',
  };

  Map<String, Object?> userRow(String userId, String email) => {
    'user_id': userId,
    'first_name': 'Ranger',
    'last_name': 'Person',
    'email': email,
    'created_at': at,
    'updated_at': at,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': newPhone,
  };

  Map<String, Object?> projectRow(String id, String ownerId) => {
    'project_id': id,
    'project_name': 'Elk Study',
    'owner_user_id': ownerId,
    'creation_date': at,
    'datum': 'WGS84',
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': newPhone,
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> membershipRow(
    String id, {
    required String projectId,
    required String userId,
  }) => {
    'membership_id': id,
    'project_id': projectId,
    'user_id': userId,
    'join_date': at,
    'end_date': null,
    'role': 'owner',
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': newPhone,
  };

  Map<String, Object?> observationRow(
    String id, {
    required String userId,
    int revision = 1,
    String? deletedAt,
  }) => {
    'observation_id': id,
    'project_id': projectA,
    'user_id': userId,
    'timestamp_local': at,
    'timestamp_utc': at,
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': at,
    'updated_at': at,
    'deleted_at': deletedAt,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': newPhone,
  };

  Future<http.Response> push(
    String token, {
    required String deviceId,
    required SyncRows rows,
  }) => http.post(
    baseUri.replace(path: '/sync/push'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncPushRequest(
        projectId: projectA,
        deviceId: deviceId,
        rows: rows,
      ).toJson(),
    ),
  );

  Future<http.Response> pull(
    String token, {
    required String deviceId,
    required int cursor,
  }) => http.post(
    baseUri.replace(path: '/sync/pull'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncPullRequest(
        projectId: projectA,
        deviceId: deviceId,
        cursor: cursor,
      ).toJson(),
    ),
  );

  Future<http.Response> ack(
    String token, {
    required String deviceId,
    required int cursor,
  }) => http.post(
    baseUri.replace(path: '/sync/ack'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncAckRequest(
        projectId: projectA,
        deviceId: deviceId,
        cursor: cursor,
      ).toJson(),
    ),
  );

  int highestSeq(http.Response response) =>
      (jsonDecode(response.body) as Map<String, Object?>)['highest_server_seq']!
          as int;

  /// Publishes [projectA] from [newPhone] with one live observation, the way
  /// the app does: a push, and no ack.
  Future<int> publish(({String token, String userId}) owner) async {
    await push(
      owner.token,
      deviceId: newPhone,
      rows: {
        Tables.users: [userRow(owner.userId, aliceEmail)],
      },
    );
    final established = await push(
      owner.token,
      deviceId: newPhone,
      rows: {
        Tables.projects: [projectRow(projectA, owner.userId)],
        Tables.projectMemberships: [
          membershipRow('m-a', projectId: projectA, userId: owner.userId),
        ],
        Tables.observations: [observationRow('obs-1', userId: owner.userId)],
      },
    );
    expect(established.statusCode, 200, reason: established.body);
    return highestSeq(established);
  }

  Future<String> enableJoining(String token) async {
    final response = await http.post(
      baseUri.replace(path: '/projects/$projectA/join-settings'),
      headers: authHeaders(token),
      body: jsonEncode({'joining_enabled': true}),
    );
    expect(response.statusCode, 200, reason: response.body);
    return JoinSettings.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).code!;
  }

  /// Walks [email] onto [projectA] as a contributor through the real join
  /// code and a real approval, as `project_destruction_routes_test.dart`
  /// does.
  Future<({String token, String userId})> joinAsContributor(
    ({String token, String userId}) owner,
    String email, {
    required String deviceId,
  }) async {
    final member = await signIn(email, deviceId: deviceId);
    final code = await enableJoining(owner.token);
    final asked = await http.post(
      baseUri.replace(path: '/projects/join-requests'),
      headers: authHeaders(member.token),
      body: jsonEncode({'code': code}),
    );
    expect(asked.statusCode, 200, reason: asked.body);
    final requestId = JoinRequestCreatedResponse.fromJson(
      jsonDecode(asked.body) as Map<String, Object?>,
    ).requestId;
    final approved = await http.post(
      baseUri.replace(
        path: '/projects/$projectA/join-requests/$requestId/approve',
      ),
      headers: authHeaders(owner.token),
      body: jsonEncode({'role': 'contributor'}),
    );
    expect(approved.statusCode, 200, reason: approved.body);
    return member;
  }

  Future<StoredCursor?> recordedPosition(String userId, String deviceId) =>
      CursorStore(connection).read(
        SyncCursorKey(userId: userId, deviceId: deviceId, projectId: projectA),
      );

  Future<bool> observationExists(String id) async {
    final result = await connection.execute(
      'SELECT 1 FROM ${quoted(Tables.observations)} '
      r'WHERE observation_id = $1',
      parameters: [id],
    );
    return result.isNotEmpty;
  }

  /// The two ways time passes in these tests, both applied by hand because
  /// every route stamps the database's `now()`: the server's receipt of a
  /// tombstone (the clock the window is measured on), and a device's last
  /// recorded sync (the clock the holdback is measured on).
  Future<void> receivedLongAgo(String observationId) => connection.execute(
    'UPDATE ${quoted(Tables.observations)} SET received_at = \$1 '
    r'WHERE observation_id = $2',
    parameters: [longAgo, observationId],
  );

  Future<void> lastSyncedLongAgo(String deviceId) => connection.execute(
    r'UPDATE sync_cursors SET last_synced_at = $1 WHERE device_id = $2',
    parameters: [longAgo, deviceId],
  );

  /// What `bin/tombstone_retention.dart` does each cycle.
  Future<TombstonePurgeReport> sweep() =>
      connection.runTx((tx) => TombstoneRetentionService(tx).purge());

  group('a device behind the floor', skip: databaseSkipReason, () {
    test('is refused by name on push and on incremental pull, keeps its own '
        'records, and may still re-pull from zero', () async {
      final alice = await signIn(aliceEmail, deviceId: newPhone);
      final published = await publish(alice);

      // The old phone joins: a full pull, then the ack the app sends once
      // the page is committed. That is its recorded position.
      final joined = await pull(alice.token, deviceId: oldPhone, cursor: 0);
      expect(joined.statusCode, 200, reason: joined.body);
      final acked = await ack(
        alice.token,
        deviceId: oldPhone,
        cursor: published,
      );
      expect(acked.statusCode, 200, reason: acked.body);

      // The old phone goes into a drawer. obs-1 is deleted from the new
      // phone, which stays current.
      final deleted = await push(
        alice.token,
        deviceId: newPhone,
        rows: {
          Tables.observations: [
            observationRow(
              'obs-1',
              userId: alice.userId,
              revision: 2,
              deletedAt: at,
            ),
          ],
        },
      );
      expect(deleted.statusCode, 200, reason: deleted.body);
      final afterDelete = highestSeq(deleted);
      await ack(alice.token, deviceId: newPhone, cursor: afterDelete);

      // Years pass, on both clocks the sweep reads.
      await receivedLongAgo('obs-1');
      await lastSyncedLongAgo(oldPhone);
      final report = await sweep();
      expect(report.rowsPurged, 1, reason: 'the tombstone is gone');
      final before = (await recordedPosition(alice.userId, oldPhone))!;
      expect(before.acknowledgedSeq, published);

      // The old phone comes back and offers what it holds: its live copy
      // of obs-1, and a bearing it took while away.
      final resurrection = await push(
        alice.token,
        deviceId: oldPhone,
        rows: {
          Tables.observations: [
            observationRow('obs-1', userId: alice.userId),
            observationRow('obs-2', userId: alice.userId),
          ],
        },
      );
      expect(resurrection.statusCode, 409, reason: resurrection.body);
      final body = jsonDecode(resurrection.body) as Map<String, Object?>;
      expect(
        body['error'],
        'cursor_too_old',
        reason:
            'the code the app switches on to say "offline too long"; any '
            'other string collapses to a generic failure on the phone',
      );
      expect(body['device_cursor'], published);
      expect(body['purged_through_seq'], afterDelete);
      expect(
        body.keys,
        unorderedEquals(['error', 'device_cursor', 'purged_through_seq']),
        reason: 'integers only cross; no server prose reaches the UI',
      );

      // Nothing it offered was written — the deleted observation stays
      // deleted, and the new bearing stays on the phone rather than half
      // on the server.
      expect(await observationExists('obs-1'), isFalse);
      expect(await observationExists('obs-2'), isFalse);
      // And its recorded position is exactly what it was: the refusal
      // changed nothing about the device.
      final after = (await recordedPosition(alice.userId, oldPhone))!;
      expect(after.acknowledgedSeq, before.acknowledgedSeq);
      expect(after.lastSyncedAt, before.lastSyncedAt);

      // An incremental pull from where it was is refused the same way.
      final stale = await pull(
        alice.token,
        deviceId: oldPhone,
        cursor: published,
      );
      expect(stale.statusCode, 409, reason: stale.body);
      expect(
        (jsonDecode(stale.body) as Map<String, Object?>)['error'],
        'cursor_too_old',
      );

      // A full re-pull from zero is the one request it may still make.
      final fresh = await pull(alice.token, deviceId: oldPhone, cursor: 0);
      expect(fresh.statusCode, 200, reason: fresh.body);
    });
  });

  group('a pull records the device', skip: databaseSkipReason, () {
    test('a device that only ever pulls has a position and a sync time on the '
        'server, so the sweep can hold back for it', () async {
      final alice = await signIn(aliceEmail, deviceId: newPhone);
      final published = await publish(alice);
      expect(
        await recordedPosition(alice.userId, newPhone),
        isNull,
        reason:
            'a publish is a push and an ack is only sent after a pull that '
            'moved, so the publisher has no row here yet',
      );

      // The publisher's next round: nothing to push, a pull from where its
      // own publish left it, which returns nothing new — and therefore,
      // in the app, no ack.
      final quiet = await pull(
        alice.token,
        deviceId: newPhone,
        cursor: published,
      );
      expect(quiet.statusCode, 200, reason: quiet.body);
      expect(
        SyncPullResponse.fromJson(
          jsonDecode(quiet.body) as Map<String, Object?>,
        ).nextCursor,
        published,
        reason: 'nothing moved; the app would not ack this',
      );

      final recorded = await recordedPosition(alice.userId, newPhone);
      expect(
        recorded,
        isNotNull,
        reason:
            'the pull said where this device is; the server must remember '
            'it, or a device that syncs every week on a quiet project reads '
            'to the sweep as one that has never been here',
      );
      expect(recorded!.acknowledgedSeq, published);
      expect(
        DateTime.now().toUtc().difference(recorded.lastSyncedAt),
        lessThan(const Duration(minutes: 5)),
      );

      // A later ack can only raise the position, and a lower pull cursor
      // never lowers it — the same monotonic rule the ack route has.
      await ack(alice.token, deviceId: newPhone, cursor: published + 5);
      await pull(alice.token, deviceId: newPhone, cursor: published);
      expect(
        (await recordedPosition(alice.userId, newPhone))!.acknowledgedSeq,
        published + 5,
      );
    });

    test('a removed member\'s disclosure pull records nothing', () async {
      // The closed-membership page is not a sync: the device is being told
      // it was removed, and it is refused on ack for the same reason. A row
      // recorded here would be a departed device holding a live project's
      // purge back.
      final alice = await signIn(aliceEmail, deviceId: newPhone);
      final published = await publish(alice);
      final bob = await joinAsContributor(alice, bobEmail, deviceId: bobPhone);
      // Bob's stint ends. (An owner's removal lands here; the row is what
      // the disclosure reads, so it is written directly.)
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r'SET end_date = $1 WHERE user_id = $2',
        parameters: [at, bob.userId],
      );

      final disclosure = await pull(
        bob.token,
        deviceId: bobPhone,
        cursor: published,
      );
      expect(disclosure.statusCode, 200, reason: disclosure.body);
      final page = SyncPullResponse.fromJson(
        jsonDecode(disclosure.body) as Map<String, Object?>,
      );
      expect(page.rows.keys, [
        Tables.projectMemberships,
      ], reason: 'the disclosure page, not a sync page');
      expect(await recordedPosition(bob.userId, bobPhone), isNull);
    });
  });
}

Response _unauthorized() => Response(
  401,
  body: jsonEncode({'error': 'unauthorized'}),
  headers: const {'content-type': 'application/json'},
);

class _CapturingSender implements EmailSender {
  _CapturingSender(this.captured);
  final Map<String, String> captured;

  @override
  void sendMagicLink({
    required String email,
    required String url,
    required DateTime expiresAt,
    void Function(bool delivered)? onOutcome,
  }) {
    captured[email] = url;
  }
}

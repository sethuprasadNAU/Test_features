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

/// **Trust-boundary inventory entry 28 — the closed-membership disclosure
/// exemption** (task 11.60, Security Model §4.27).
///
/// ## What is on trial here
///
/// `POST /sync/pull` now answers one caller it would otherwise refuse: a
/// person whose stint on the project has ended gets **their own closed
/// membership rows and nothing else**, so their device learns it was removed
/// instead of showing "the server is refusing access" beside a delete control
/// that does nothing.
///
/// That is a read that answers a refused caller, which is the shape existence
/// oracles are made of. So this file has two jobs and they pull in opposite
/// directions:
///
/// 1. **The exemption does what it is for**, and no more than that.
/// 2. **Nobody else can see it happen.** A caller holding no closed
///    membership on the named project must not be able to tell a project that
///    does not exist from one that exists and is not theirs — §4.13's
///    requirement, and Gate C finding B2's.
///
/// ## Demonstrated, not asserted
///
/// The brief for this task said to demonstrate indistinguishability rather
/// than assert it, and the difference is the whole design of the group below.
///
/// - The **responses are compared to each other**, byte for byte plus status
///   and content type, not to an expected constant. A test that asserted
///   `403` twice would still pass if both branches drifted to the same wrong
///   place, and would break on a reworded refusal that discloses nothing.
/// - The prober is **somebody who can reach the exemption** — a person with a
///   closed stint on a *different* project. A stranger with no closed
///   membership anywhere would be a weaker probe: they can never take the
///   disclosure branch under any input, so they cannot detect a leak in it.
/// - **The statements themselves are compared**, not just the answers.
///   `_RecordingSession` records every query the authorization path runs, so
///   "same order, same work" is checked directly rather than inferred from a
///   timing measurement that would be flaky on a loaded machine. This is the
///   check that catches the class of mistake this exemption is most likely to
///   reintroduce: a lookup placed inside a branch only one kind of caller
///   reaches.
void main() {
  late Connection connection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_closed_membership_test';

  final captured = <String, String>{};

  const ownerEmail = 'owner@example.org';
  const departedEmail = 'departed@example.org';
  const strangerEmail = 'stranger@example.org';
  // The project the departed person was removed from.
  const theirs = 'proj-theirs';
  // A real project they were never on. The foil for the fictional id below:
  // both must answer them identically.
  const foreign = 'proj-foreign';
  const fictional = 'proj-does-not-exist';
  const at = '2026-08-01T12:00:00.000Z';
  const later = '2026-08-02T12:00:00.000Z';

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    captured.clear();
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
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
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> projectRow(String id, String ownerId) => {
    'project_id': id,
    'project_name': 'Elk Study $id',
    'owner_user_id': ownerId,
    'creation_date': at,
    'datum': 'WGS84',
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> observationRow(
    String id, {
    required String projectId,
    required String userId,
  }) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'tag_id': null,
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
    'notes': null,
    'created_at': at,
    'updated_at': at,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-X',
  };

  Future<http.Response> push(
    String token, {
    required String projectId,
    required SyncRows rows,
    String deviceId = 'device-X',
  }) => http.post(
    baseUri.replace(path: '/sync/push'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncPushRequest(
        projectId: projectId,
        deviceId: deviceId,
        rows: rows,
      ).toJson(),
    ),
  );

  Future<http.Response> pull(
    String token, {
    required String projectId,
    int cursor = 0,
    String deviceId = 'device-X',
  }) => http.post(
    baseUri.replace(path: '/sync/pull'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncPullRequest(
        projectId: projectId,
        deviceId: deviceId,
        cursor: cursor,
      ).toJson(),
    ),
  );

  Future<http.Response> ack(
    String token, {
    required String projectId,
    int cursor = 1,
    String deviceId = 'device-X',
  }) => http.post(
    baseUri.replace(path: '/sync/ack'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncAckRequest(
        projectId: projectId,
        deviceId: deviceId,
        cursor: cursor,
      ).toJson(),
    ),
  );

  Future<void> publish(
    ({String token, String userId}) owner,
    String email,
    String projectId,
  ) async {
    await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.users: [userRow(owner.userId, email)],
      },
    );
    final established = await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.projects: [projectRow(projectId, owner.userId)],
        Tables.projectMemberships: [
          {
            'membership_id': 'm-own-$projectId',
            'project_id': projectId,
            'user_id': owner.userId,
            'join_date': at,
            'end_date': null,
            'role': 'owner',
            'created_at': at,
            'updated_at': at,
            'revision': 0,
            'last_modified_by': owner.userId,
            'origin_device_id': 'device-A',
          },
        ],
      },
    );
    expect(established.statusCode, 200, reason: established.body);
  }

  /// A real join code, asked for and approved — never a row seeded straight into the table,
  /// so the membership under test is the one the product actually produces.
  Future<({String token, String userId})> joinAs(
    ({String token, String userId}) owner,
    String email, {
    required String projectId,
    required String deviceId,
    String role = 'contributor',
  }) async {
    final member = await signIn(email, deviceId: deviceId);
    final enabled = await http.post(
      baseUri.replace(path: '/projects/$projectId/join-settings'),
      headers: authHeaders(owner.token),
      body: jsonEncode({'joining_enabled': true}),
    );
    expect(enabled.statusCode, 200, reason: enabled.body);
    final code = JoinSettings.fromJson(
      jsonDecode(enabled.body) as Map<String, Object?>,
    ).code!;
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
        path: '/projects/$projectId/join-requests/$requestId/approve',
      ),
      headers: authHeaders(owner.token),
      body: jsonEncode({'role': role}),
    );
    expect(approved.statusCode, 200, reason: approved.body);
    return member;
  }

  /// The membership row the server holds for [userId] on [projectId], read
  /// through an ordinary owner's pull rather than out of the table, so what is
  /// compared later is what the wire actually carries.
  Future<Map<String, Object?>> serverMembershipFor(
    String ownerToken,
    String projectId,
    String userId,
  ) async {
    final response = await pull(
      ownerToken,
      projectId: projectId,
      deviceId: 'device-reader',
    );
    expect(response.statusCode, 200, reason: response.body);
    final page = SyncPullResponse.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
    final rows = (page.rows[Tables.projectMemberships] ?? const [])
        .where((row) => row['user_id'] == userId)
        .toList();
    expect(
      rows,
      hasLength(1),
      reason: 'expected exactly one membership row for $userId on $projectId',
    );
    return rows.single;
  }

  /// The owner ends [userId]'s stint, the way the members screen does: push
  /// the row back with `end_date` set and the revision advanced.
  Future<void> removeMember(
    ({String token, String userId}) owner,
    String projectId,
    String userId,
  ) async {
    final row = await serverMembershipFor(owner.token, projectId, userId);
    final response = await push(
      owner.token,
      projectId: projectId,
      deviceId: 'device-A',
      rows: {
        Tables.projectMemberships: [
          {
            ...row,
            'end_date': later,
            'updated_at': later,
            'revision': (row['revision']! as int) + 1,
            'last_modified_by': owner.userId,
          },
        ],
      },
    );
    expect(response.statusCode, 200, reason: response.body);
    expect(
      SyncPushResponse.fromJson(
        jsonDecode(response.body) as Map<String, Object?>,
      ).applied,
      1,
      reason: 'the removal did not land, so nothing below is testing anything',
    );
  }

  /// Everything about a response an outside caller can see, minus the three
  /// headers that differ between **any** two requests whatsoever.
  ///
  /// `date` moves with the clock, `content-length` is a function of the body
  /// that is already being compared, and `x-trace-id` is minted per request —
  /// it is §4.13's own device for making a support conversation possible
  /// without disclosing anything, and it carries no information about the
  /// project named. Everything else — status, every other header, and the
  /// body bytes — is in, and the exclusions are listed here rather than
  /// filtered by a prefix so that a *new* varying header fails this
  /// comparison and has to be reasoned about.
  Object visible(http.Response response) => {
    'status': response.statusCode,
    'body': response.body,
    'headers': {
      for (final entry in response.headers.entries)
        if (entry.key != 'date' &&
            entry.key != 'content-length' &&
            entry.key != 'x-trace-id')
          entry.key: entry.value,
    },
  };

  // ---- the group ----------------------------------------------------------

  group('the closed-membership disclosure (§4.27, inventory entry 28)', skip: databaseSkipReason, () {
    late ({String token, String userId}) owner;
    late ({String token, String userId}) departed;

    setUp(() async {
      owner = await signIn(ownerEmail, deviceId: 'device-A');
      await publish(owner, ownerEmail, theirs);
      await publish(owner, ownerEmail, foreign);

      departed = await joinAs(
        owner,
        departedEmail,
        projectId: theirs,
        deviceId: 'device-D',
      );
      // A record of the owner's, in the project the departed person is about
      // to be removed from. If the exemption ever widens, this is the row that
      // shows up where it should not.
      final seeded = await push(
        owner.token,
        projectId: theirs,
        deviceId: 'device-A',
        rows: {
          Tables.observations: [
            observationRow('obs-theirs', projectId: theirs,
                userId: owner.userId),
          ],
        },
      );
      expect(seeded.statusCode, 200, reason: seeded.body);

      await removeMember(owner, theirs, departed.userId);
    });

    test(
      'a removed member is handed their own closed row and nothing else',
      () async {
        final response = await pull(
          departed.token,
          projectId: theirs,
          deviceId: 'device-D',
        );
        expect(response.statusCode, 200, reason: response.body);
        final page = SyncPullResponse.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        );

        expect(
          page.rows.keys,
          [Tables.projectMemberships],
          reason:
              'the disclosure delivered a table other than the one it is for. '
              'Nothing beyond their own row may cross — not the project, not '
              'its members, not one record.',
        );
        final rows = page.rows[Tables.projectMemberships]!;
        expect(rows, hasLength(1));
        final row = rows.single;
        expect(row['user_id'], departed.userId);
        expect(row['project_id'], theirs);
        expect(
          row['end_date'],
          isNotNull,
          reason:
              'the row arrived with the stint still open, so the device learns '
              'nothing and is exactly where task 11.57 found it',
        );
        // Server-only bookkeeping, stripped for the same reason an ordinary
        // page strips it.
        expect(row.containsKey('server_seq'), isFalse);
        expect(row.containsKey('received_at'), isFalse);
        expect(row.containsKey('clock_skew_flag'), isFalse);
      },
    );

    test('the page is terminal and asks for no acknowledgement', () async {
      final response = await pull(
        departed.token,
        projectId: theirs,
        cursor: 3,
        deviceId: 'device-D',
      );
      final page = SyncPullResponse.fromJson(
        jsonDecode(response.body) as Map<String, Object?>,
      );
      expect(
        page.nextCursor,
        3,
        reason:
            'the cursor moved, so the client will try to acknowledge it — and '
            'ack is still refused for a closed stint, which would throw away '
            'the page that had just been committed',
      );
      expect(
        page.hasMore,
        isFalse,
        reason:
            'a removed device would ask again, and again, for a page that can '
            'only ever be the same rows',
      );
    });

    test(
      'the disclosure does not depend on where the cursor sits',
      () async {
        // Far beyond any `server_seq` this fixture allocated. A delta window
        // would deliver nothing here; the disclosure is not a delta window.
        final response = await pull(
          departed.token,
          projectId: theirs,
          cursor: 100000,
          deviceId: 'device-D',
        );
        final page = SyncPullResponse.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        );
        expect(
          page.rows[Tables.projectMemberships],
          hasLength(1),
          reason:
              'a device whose cursor is already past the removal would never '
              'learn — and a device that has pulled recently is the ordinary '
              'case, not the exotic one',
        );
      },
    );

    test('nothing else about the project opens up', () async {
      final pushed = await push(
        departed.token,
        projectId: theirs,
        deviceId: 'device-D',
        rows: {
          Tables.observations: [
            observationRow('obs-after', projectId: theirs,
                userId: departed.userId),
          ],
        },
      );
      expect(
        pushed.statusCode,
        403,
        reason: 'the disclosure is a read; it must not have opened the write',
      );

      final acked = await ack(
        departed.token,
        projectId: theirs,
        deviceId: 'device-D',
      );
      expect(
        acked.statusCode,
        403,
        reason:
            'ack is a write to the cursor table and stays refused — which is '
            'why the disclosure page hands the cursor straight back',
      );
    });

    test(
      'a caller who can reach the exemption still cannot tell a real foreign '
      'project from one that has never existed',
      () async {
        // The strongest prober available: somebody the disclosure branch is
        // reachable *for*, on a different project. If the branch leaked — by
        // status, by body, by a header — this is who would see it.
        final real = await pull(
          departed.token,
          projectId: foreign,
          deviceId: 'device-D',
        );
        final fake = await pull(
          departed.token,
          projectId: fictional,
          deviceId: 'device-D',
        );
        expect(
          visible(real),
          visible(fake),
          reason:
              'a real project this caller was never on answers differently '
              'from an id that names nothing. That is a working existence '
              'oracle (§4.13), and it is what the pre-check on every refusal '
              'exists to prevent.',
        );
        // Compared to each other above; pinned to a refusal here so the pair
        // cannot both drift to a permissive answer and still match.
        expect(real.statusCode, 403, reason: real.body);
      },
    );

    test(
      'a stranger with no membership anywhere sees the same two answers',
      () async {
        final stranger = await signIn(strangerEmail, deviceId: 'device-S');
        final real = await pull(
          stranger.token,
          projectId: theirs,
          deviceId: 'device-S',
        );
        final fake = await pull(
          stranger.token,
          projectId: fictional,
          deviceId: 'device-S',
        );
        expect(visible(real), visible(fake));
        expect(real.statusCode, 403, reason: real.body);
      },
    );

    test(
      'and the two refusals are the same refusal a removed member used to get',
      () async {
        // The third leg of the triangle the task named: does-not-exist, never
        // was in it, and *was* in it — the last one compared from a caller who
        // holds no row for the id, which is every caller but its subject.
        final stranger = await signIn(strangerEmail, deviceId: 'device-S');
        final wasRemovedFrom = await pull(
          stranger.token,
          projectId: theirs,
          deviceId: 'device-S',
        );
        final neverIn = await pull(
          stranger.token,
          projectId: foreign,
          deviceId: 'device-S',
        );
        final doesNotExist = await pull(
          stranger.token,
          projectId: fictional,
          deviceId: 'device-S',
        );
        expect(visible(wasRemovedFrom), visible(neverIn));
        expect(visible(neverIn), visible(doesNotExist));
      },
    );

    test(
      'an open membership is never disclosed, even one this build cannot read',
      () async {
        // The fail-closed case: a `role` string no version of this build
        // recognises leaves somebody with an *open* row and no access. They
        // are refused exactly as before — the exemption is for stints that are
        // over, and handing back an open row would tell a device it is still a
        // member of a project the server refuses.
        await connection.execute(
          'UPDATE ${quoted(Tables.projectMemberships)} '
          r"SET role = 'archivist', end_date = NULL "
          r'WHERE project_id = $1 AND user_id = $2',
          parameters: [theirs, departed.userId],
        );
        final response = await pull(
          departed.token,
          projectId: theirs,
          deviceId: 'device-D',
        );
        expect(response.statusCode, 403, reason: response.body);
        final fake = await pull(
          departed.token,
          projectId: fictional,
          deviceId: 'device-D',
        );
        expect(visible(response), visible(fake));
      },
    );

    test(
      'the authorization path runs the same statements in the same order for '
      'all three cases',
      () async {
        // **The work done is observable from outside too**, and a status code
        // and a body are not the only channels §4.13 has been caught by — see
        // task 10.29's D-1, which was this same question answered one level
        // down. A timing assertion would be the obvious way to check it and
        // would be flaky on a shared machine; this compares the statements
        // themselves, which is both exact and stable.
        //
        // The failure it is built to catch is the tempting one: putting the
        // disclosure lookup inside a branch only a member-ish caller reaches,
        // so that a refusal costs one query less than a disclosure.
        Future<List<String>> statementsFor(
          String projectId,
          String userId,
        ) async {
          final recorded = <String>[];
          await connection.runTx((tx) async {
            final session = _RecordingSession(tx, recorded);
            final access = await ProjectAuthorizer.resolve(
              session,
              projectId: projectId,
              userId: userId,
            );
            expect(
              access.permitsSync,
              isFalse,
              reason: 'this case is meant to be a refusal',
            );
            await ClosedMembershipDisclosure.rowsFor(
              session,
              projectId: projectId,
              userId: userId,
            );
          });
          return recorded;
        }

        final stranger = await signIn(strangerEmail, deviceId: 'device-S');
        final wasRemovedFrom = await statementsFor(theirs, departed.userId);
        final neverIn = await statementsFor(foreign, stranger.userId);
        final doesNotExist = await statementsFor(fictional, stranger.userId);

        expect(
          wasRemovedFrom,
          isNotEmpty,
          reason: 'the recorder recorded nothing, so it is checking nothing',
        );
        expect(
          neverIn,
          wasRemovedFrom,
          reason:
              'a project the caller was never on takes a different route '
              'through the authorization path than one they were removed from',
        );
        expect(
          doesNotExist,
          neverIn,
          reason:
              'a project that does not exist is answered in fewer statements '
              'than one that does — which is the shape ProjectAuthorizer.'
              'resolve carried until task 11.60 removed its early return',
        );
      },
    );
  });
}

/// A [Session] that writes down every statement before passing it on.
///
/// Only [execute] is instrumented, because that is all the authorization path
/// uses; everything else forwards untouched so this cannot quietly change what
/// is being measured.
class _RecordingSession implements Session {
  _RecordingSession(this._inner, this._recorded);

  final Session _inner;
  final List<String> _recorded;

  /// The SQL text only. Parameter *values* differ between the cases by
  /// construction — that is what makes them different cases — so recording
  /// them would make every comparison fail for the one reason that does not
  /// matter.
  @override
  Future<Result> execute(
    Object query, {
    Object? parameters,
    bool ignoreRows = false,
    QueryMode? queryMode,
    Duration? timeout,
  }) {
    _recorded.add(query is String ? query : query.runtimeType.toString());
    return _inner.execute(
      query,
      parameters: parameters,
      ignoreRows: ignoreRows,
      queryMode: queryMode,
      timeout: timeout,
    );
  }

  @override
  Future<Statement> prepare(Object query) => _inner.prepare(query);

  @override
  bool get isOpen => _inner.isOpen;

  @override
  Future<void> get closed => _inner.closed;
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

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

/// **The publisher's real request sequence, replayed against a real server**
/// (task 11.43, reopened 2026-08-31).
///
/// ## Why this file exists, which is the finding rather than the row
///
/// Task 11.43 reached Done with its acceptance unmet, and shipped a first
/// publish that always refused one `Tag_Versions` row. Two suites were green
/// throughout, and neither was wrong on its own terms:
///
/// - the **client** publisher tests drive `ProjectPublisher` against a fake
///   transport that models no reachability rule, so any order passes;
/// - every **server** test pushes the whole project in **one request**, so the
///   authorizer's same-push escape (`_establishedThisPush`) always covers a
///   tag reference, and any order passes.
///
/// Between them, the sequence the app actually sends — *one table per HTTP
/// request, each its own Postgres transaction* — had never been executed.
/// **That gap, not the ordering, is what let this ship**, so closing it is
/// this file's job: it sends exactly one table per request, and it takes the
/// order from `Tables.all`, the same declaration `ProjectPublisher.publish`
/// iterates, so the replay cannot drift away from the thing it replays.
///
/// The second test is the one that makes the first evidence rather than
/// decoration: it replays a **wrong** order and asserts the server refuses
/// exactly one row. A test that cannot fail against a known-broken input is
/// not a test.
///
/// **Task 11.220: that second test no longer replays the order that shipped,
/// and its own comment says why.** The defect the Android walk found was
/// `Tag_Versions` offered before the `Project_Tags` link that vouched for its
/// tag; task 11.219 retired `Project_Tags` and deleted
/// `RowAuthorizer._establishedThisPush`, so **the original broken input is no
/// longer expressible.** The control is now `Tag_Versions` offered before
/// `Tags`, refused by the foreign key rather than by a reachability rule —
/// the same shape (a row offered before the row that makes it valid, in an
/// earlier transaction) against a constraint that is still live. The first
/// test's claim is unchanged and is still the one that matters.
void main() {
  late Connection connection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_publish_sequence_test';

  final captured = <String, String>{};

  const email = 'alice@example.org';
  const projectId = 'proj-sequence';
  const tagId = 'tag-sequence';
  const deviceId = 'device-publish';
  const at = '2026-08-31T12:00:00.000Z';

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

  Future<({String token, String userId})> signIn() async {
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

  /// The rows a first publish of a one-tag, one-bearing project offers, keyed
  /// by table.
  ///
  /// Deliberately the **narrowed** payload `ProjectPublisher._payloadFrom`
  /// produces — every row names the publisher, so nothing here is expected to
  /// be refused on naming grounds and the only thing a refusal can be about is
  /// the order the requests arrive in.
  Map<String, List<Map<String, Object?>>> payloadFor(String userId) => {
    Tables.users: [
      {
        'user_id': userId,
        'first_name': 'Alice',
        'last_name': 'Ranger',
        'email': email,
        'created_at': at,
        'updated_at': at,
        'revision': 1,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      },
    ],
    Tables.projects: [
      {
        'project_id': projectId,
        'project_name': 'Elk Study',
        'owner_user_id': userId,
        'creation_date': at,
        'datum': 'WGS84',
        'created_at': at,
        'updated_at': at,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
        'coordinate_format': 'dd',
        'triangulation_window_minutes': 15,
      },
    ],
    Tables.projectMemberships: [
      {
        'membership_id': 'mem-sequence',
        'project_id': projectId,
        'user_id': userId,
        'join_date': at,
        'end_date': null,
        'role': 'owner',
        'created_at': at,
        'updated_at': at,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      },
    ],
    Tables.tags: [
      {
        'tag_id': tagId,
        // Project-scoped since task 11.219. The `Project_Tags` link that used
        // to follow this row is gone from the payload because it is gone from
        // the schema: the tag's own `project_id` is what puts it in the
        // project, so a first publish sends six tables here where it sent
        // seven.
        'project_id': projectId,
        'lineage_id': tagId,
        'frequency_mhz': 150.1,
        'tag_name': 'Collar 7',
        'status': 'active',
        'color_hex': '#4C72B0',
        'created_at': at,
        'updated_at': at,
        'revision': 1,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      },
    ],
    // Task 11.32 gives every tag a version the moment it is created, which is
    // why this row is on *every* first publish rather than an unusual one.
    Tables.tagVersions: [
      {
        'tag_version_id': 'ver-sequence',
        'project_id': projectId,
        'tag_id': tagId,
        'effective_from': at,
        'frequency_mhz': 150.1,
        'pulse_rate': null,
        'pulse_pattern': null,
        'tag_name': 'Collar 7',
        'created_at': at,
        'updated_at': at,
        'revision': 1,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      },
    ],
    Tables.observations: [
      {
        'observation_id': 'obs-sequence',
        'project_id': projectId,
        'user_id': userId,
        'tag_id': tagId,
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
        'origin_device_id': deviceId,
      },
    ],
  };

  /// Sends [payload] the way `ProjectPublisher.publish` does — **one table per
  /// HTTP request**, in [order], skipping tables the payload has no rows for —
  /// and returns every row's outcome, keyed `table/rowKey`.
  Future<Map<String, SyncRowOutcome>> publishTableByTable(
    String token,
    Map<String, List<Map<String, Object?>>> payload, {
    required List<String> order,
  }) async {
    final outcomes = <String, SyncRowOutcome>{};
    for (final table in order) {
      final rows = payload[table];
      if (rows == null || rows.isEmpty) continue;
      final response = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: {
          'content-type': 'application/json',
          'authorization': 'Bearer $token',
        },
        body: jsonEncode(
          SyncPushRequest(
            projectId: projectId,
            deviceId: deviceId,
            rows: {table: rows},
          ).toJson(),
        ),
      );
      expect(
        response.statusCode,
        200,
        reason: 'push of $table failed: ${response.body}',
      );
      outcomes.addAll(
        SyncPushResponse.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        ).outcomes,
      );
    }
    return outcomes;
  }

  /// Whether the server kept the row.
  ///
  /// Exhaustive over [SyncRowOutcome] with no `default`, so a sixth outcome is
  /// a compile error here rather than something this test quietly counts as
  /// success. `lostToServer` counts as kept: the server has a copy at the same
  /// or a newer revision, which is what a re-publish of an already-uploaded
  /// row produces and is not a refusal.
  bool serverKeptIt(SyncRowOutcome outcome) => switch (outcome) {
    SyncRowOutcome.inserted => true,
    SyncRowOutcome.updated => true,
    SyncRowOutcome.lostToServer => true,
    SyncRowOutcome.invalid => false,
    SyncRowOutcome.unauthorized => false,
  };

  /// The outcomes that mean the server did **not** keep the row.
  Map<String, SyncRowOutcome> refusals(Map<String, SyncRowOutcome> outcomes) => {
    for (final entry in outcomes.entries)
      if (!serverKeptIt(entry.value)) entry.key: entry.value,
  };

  group(
    'a first publish, sent the way the publisher sends it',
    skip: testDatabaseConfig == null ? databaseSkipReason : null,
    () {
      test('refuses nothing, table by table, in Tables.all order', () async {
        final alice = await signIn();
        final payload = payloadFor(alice.userId);

        final outcomes = await publishTableByTable(
          alice.token,
          payload,
          // The publisher's own order, read from the same declaration it
          // iterates. Spelling one out here would let the two drift, which is
          // the whole class of defect this file was written for.
          order: Tables.all,
        );

        expect(
          refusals(outcomes),
          isEmpty,
          reason:
              'every row of a first publish must be accepted; a refusal here '
              'is the red banner a person sees on the first thing they ever '
              'do with a server',
        );
        // Not merely "no refusal": the rows are actually there.
        expect(outcomes, hasLength(6));
        final stored = await connection.execute(
          'SELECT COUNT(*) FROM "${Tables.tagVersions}" '
          r'WHERE tag_id = $1 AND project_id = $2',
          parameters: [tagId, projectId],
        );
        expect(stored.first.first, 1);
      });

      test('a version offered before its tag is refused — the negative '
          'control, restated for task 11.219', () async {
        // **What this test used to replay, and why it could not stay.** It
        // reconstructed the order that actually shipped — `Tag_Versions`
        // offered before the `Project_Tags` link that vouched for its tag —
        // and asserted the server refused the version row, because each
        // request is its own transaction and the authorizer's same-push escape
        // (`RowAuthorizer._establishedThisPush`) could not reach back into the
        // request that carried the tag. **Both halves of that are gone**:
        // `Project_Tags` is not a table any more and `_establishedThisPush` is
        // not a field any more. There is no order of the shipped tables that
        // reproduces the Android walk's refusal, because the rule it broke
        // does not exist — `offer_order.dart` says so at length, and
        // `reachLinkTableFor` now returns null for the one reach set left.
        //
        // **Deleting it was the other option and it was rejected, because the
        // test above needs a control.** *"A first publish refuses nothing"* is
        // a claim that can be satisfied by a replay that has quietly stopped
        // replaying anything — a payload that lost its rows, a loop that skips
        // every table, a server that answers `inserted` to everything. The
        // original second test was what made the first one evidence, and that
        // job did not go away when its particular defect did.
        //
        // **So the control is restated against the constraint that is still
        // live: the foreign key.** `Tag_Versions.(tag_id, project_id)`
        // references `Tags`, so a version offered in an earlier *request* than
        // its tag points at a row this server does not hold and never will
        // within that transaction — `RowAuthorizer._authorizeReferences`, the
        // ordinary dangling-reference rule. Same shape as the original defect
        // (a row offered before the row that makes it valid, across two
        // transactions), same single refused row, and it exercises the same
        // replay machinery. What it no longer claims is that any *shipped*
        // order does this; `Tables.all` puts `Tags` first and this test moves
        // it deliberately.
        final versionFirst = [...Tables.all]
          ..remove(Tables.tags)
          ..insert(
            [...Tables.all].indexOf(Tables.tagVersions) + 1,
            Tables.tags,
          );
        expect(
          versionFirst.indexOf(Tables.tagVersions),
          lessThan(versionFirst.indexOf(Tables.tags)),
          reason: 'sanity: the reconstruction really is Tag_Versions-first',
        );
        expect(
          Tables.all.indexOf(Tables.tags),
          lessThan(Tables.all.indexOf(Tables.tagVersions)),
          reason: 'and the shipped order is the other way round, which is the '
              'thing this test would be pointless without',
        );

        final alice = await signIn();
        final outcomes = await publishTableByTable(
          alice.token,
          payloadFor(alice.userId),
          order: versionFirst,
        );

        expect(
          refusals(outcomes).keys,
          ['${Tables.tagVersions}/ver-sequence/$projectId'],
          reason:
              'exactly one row, and it is the version whose tag had not been '
              'committed yet — if this ever passes with an empty list, the '
              'replay has stopped being able to see a wrong order at all, '
              'which is what makes the test above meaningful',
        );
      });
    },
  );
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

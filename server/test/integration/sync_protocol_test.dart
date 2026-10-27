@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Proves the **real** storage layer honours the protocol contract that
/// `packages/tritrack_sync/test/sync_convergence_test.dart` pins against an
/// in-memory harness. The harness checks the rules; this checks Postgres
/// follows them.
///
/// Skipped unless a database is configured — see
/// `test/integration/postgres_sync_test.dart`'s header for how to run these.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_sync_proto_test';
  const projectId = 'proj-1';
  const userId = 'user-1';

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
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
    await _seed(connection);
  });

  Map<String, Object?> observation(String id, {int revision = 1}) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': '2026-08-01T12:00:00.000Z',
    'timestamp_utc': '2026-08-01T12:00:00.000Z',
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_accuracy_m': null,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'magnetic_bearing': null,
    'true_north_bearing': null,
    'bearing_uncertainty': null,
    'bearing_capture_method': null,
    'bearing_method': null,
    'magnetic_bearing_start': null,
    'magnetic_bearing_end': null,
    'true_north_bearing_start': null,
    'true_north_bearing_end': null,
    'magnetic_declination': null,
    'wmm_model_version': null,
    'antenna_type': null,
    'receiver_gain': null,
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'bearing_quality': null,
    'notes': null,
    'tag_id': null,
    'session_id': null,
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': '2026-08-01T12:00:00.000Z',
    'deleted_at': null,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  // These tests exercise the protocol, not authorization — the caller is the
  // project's owner, which is the ordinary case. Task 10.10's own tests cover
  // what happens when they are not.
  Future<PushResult> push(SyncRows rows) => connection.runTx(
    (tx) => SyncService(session: tx).applyPush(
      projectId: projectId,
      rows: rows,
      authorizer: RowAuthorizer(
        session: tx,
        projectId: projectId,
        userId: userId,
        access: ProjectAccess.owner,
      ),
    ),
  );

  Future<({SyncRows rows, int nextCursor, int remaining})> pull({
    required int cursor,
    int batchSize = 500,
  }) => connection.runTx(
    (tx) => SyncService(
      session: tx,
    ).pull(projectId: projectId, cursor: cursor, batchSize: batchSize),
  );

  group('push', skip: databaseSkipReason, () {
    test('inserts a new row and assigns a server_seq', () async {
      final result = await push({
        Tables.observations: [observation('obs-1')],
      });
      expect(result.applied, 1);
      expect(
        result.outcomes['${Tables.observations}/obs-1/$projectId'],
        SyncRowOutcome.inserted,
      );
      expect(result.highestServerSeq, isNotNull);
    });

    test(
      'a re-push of the same row loses and does NOT bump server_seq',
      () async {
        await push({
          Tables.observations: [observation('obs-1')],
        });
        final before = await connection.execute(
          'SELECT server_seq FROM ${quoted(Tables.observations)}',
        );
        final firstSeq = before.first.first! as int;

        final result = await push({
          Tables.observations: [observation('obs-1')],
        });
        expect(
          result.outcomes['${Tables.observations}/obs-1/$projectId'],
          SyncRowOutcome.lostToServer,
        );
        expect(result.applied, 0);

        final after = await connection.execute(
          'SELECT server_seq FROM ${quoted(Tables.observations)}',
        );
        expect(
          after.first.first,
          firstSeq,
          reason: 'bumping on a no-op would redeliver forever',
        );
      },
    );

    test(
      'a higher revision wins and gets a fresh, higher server_seq',
      () async {
        await push({
          Tables.observations: [observation('obs-1')],
        });
        final before = await connection.execute(
          'SELECT server_seq FROM ${quoted(Tables.observations)}',
        );
        final firstSeq = before.first.first! as int;

        final result = await push({
          Tables.observations: [observation('obs-1', revision: 5)],
        });
        expect(
          result.outcomes['${Tables.observations}/obs-1/$projectId'],
          SyncRowOutcome.updated,
        );
        expect(result.lost, hasLength(1));

        final after = await connection.execute(
          'SELECT server_seq FROM ${quoted(Tables.observations)}',
        );
        expect(after.first.first! as int, greaterThan(firstSeq));
      },
    );

    test('a row scoped to another project is rejected, not stored', () async {
      final result = await push({
        Tables.observations: [
          {...observation('obs-x'), 'project_id': 'other-project'},
        ],
      });
      expect(
        result.outcomes['${Tables.observations}/obs-x/other-project'],
        SyncRowOutcome.unauthorized,
      );
      final count = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.observations)}',
      );
      expect(count.first.first, 0);
    });

    test(
      'an invalid row is rejected without blocking the rest of the batch',
      () async {
        final result = await push({
          Tables.observations: [
            {...observation('obs-bad'), 'latitude': 999.0},
            observation('obs-good'),
          ],
        });
        expect(
          result.outcomes['${Tables.observations}/obs-bad/$projectId'],
          SyncRowOutcome.invalid,
        );
        expect(
          result.outcomes['${Tables.observations}/obs-good/$projectId'],
          SyncRowOutcome.inserted,
        );
      },
    );

    /// **Task 11.221 — two rows for one primary key in a single push.**
    ///
    /// Measured 2026-09-10: this used to answer `applied: 1` with the only
    /// outcome in the map reading `invalid`. The first row landed, Postgres
    /// refused the second on the key, and because the outcome map is keyed
    /// by the row reference both rows share, the second verdict overwrote the
    /// first. A client could not tell which of its two rows had been taken.
    ///
    /// Not reachable from this app — the phone's own database holds the same
    /// primary key — but a response that contradicts itself is a defect
    /// whoever sends it. The answer is per-row (task 10.46 removed "one bad
    /// row fails the whole push" and this does not bring it back): every row
    /// sharing the key is `invalid`, none is applied, and the rest of the
    /// push is untouched.
    test('two rows sharing a primary key are both refused, neither is '
        'applied, and the rest of the push still lands', () async {
      final result = await push({
        Tables.observations: [
          observation('obs-twin'),
          {...observation('obs-twin'), 'notes': 'the other copy'},
          observation('obs-good'),
        ],
      });

      final twin = '${Tables.observations}/obs-twin/$projectId';
      expect(result.applied, 1, reason: 'only obs-good');
      expect(result.outcomes, hasLength(2));
      expect(result.outcomes[twin], SyncRowOutcome.invalid);
      expect(
        result.outcomes['${Tables.observations}/obs-good/$projectId'],
        SyncRowOutcome.inserted,
      );
      final stored = await connection.execute(
        'SELECT observation_id FROM ${quoted(Tables.observations)} '
        'ORDER BY observation_id',
      );
      expect(stored.map((r) => r.first), ['obs-good']);
    });

    test('a push that is nothing but a duplicated key applies nothing — '
        'the count and the one outcome agree', () async {
      final result = await push({
        Tables.observations: [
          observation('obs-twin'),
          observation('obs-twin'),
        ],
      });
      expect(result.applied, 0);
      expect(result.outcomes, hasLength(1));
      expect(
        result.outcomes['${Tables.observations}/obs-twin/$projectId'],
        SyncRowOutcome.invalid,
      );
      expect(result.highestServerSeq, isNull);
    });

    /// **Task 11.124 — the real server naming which part it refused.**
    ///
    /// The client half of this is tested against a fake server. This is the
    /// half that says the fake is telling the truth: a real push, through a
    /// real Postgres, refused by the real shared validator.
    group('and says which part, for the refusals it can explain', () {
      test('a name the rule refuses comes back with the code that column\'s '
          'own bound declares, and the column\'s name', () async {
        // U+202E RIGHT-TO-LEFT OVERRIDE — task 11.84's measured case.
        final result = await push({
          Tables.users: [
            {
              'user_id': userId,
              'first_name': 'Sam\u202ERanger',
              'last_name': 'Ranger',
              'email': 'sam@example.com',
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-09-02T12:00:00.000Z',
              'revision': 2,
            },
          ],
        });

        final key = '${Tables.users}/$userId';
        expect(result.outcomes[key], SyncRowOutcome.invalid);
        expect(result.refusals[key]?.code, RowIssueCode.textNotAName);
        expect(result.refusals[key]?.field, 'first_name');
      });

      test('a range failure carries the detail its declared bound names, all '
          'the way across the wire', () async {
        // **This test used to assert the opposite, and both versions were
        // right when they were written.** Latitude 999 failed a range check
        // written inline in `RowValidator`; nothing declared a code for it, so
        // the honest answer was silence and silence reached task 11.122's
        // default on the device. Task 11.136 gave the range a declaration —
        // `NumericBound.latitude` on the column — so the server now knows what
        // to say, and says it here rather than at the check.
        final result = await push({
          Tables.observations: [
            {...observation('obs-bad'), 'latitude': 999.0},
          ],
        });

        final key = '${Tables.observations}/obs-bad/$projectId';
        expect(result.outcomes[key], SyncRowOutcome.invalid);
        expect(result.refusals[key]?.code, RowIssueCode.numberAboveMaximum);
        expect(result.refusals[key]?.field, 'latitude');
      });

      test('a refusal with no declared bound behind it still carries no '
          'detail, rather than the nearest one', () async {
        // The property the test above used to hold, moved to a check that
        // genuinely has no declaration behind it: a closed enum's membership
        // lives in `enums.dart` and is checked inline. **Silence is still the
        // honest answer there**, and it still reaches 11.122's default.
        final result = await push({
          Tables.observations: [
            {...observation('obs-enum'), 'signal_type': 'telepathy'},
          ],
        });

        final key = '${Tables.observations}/obs-enum/$projectId';
        expect(result.outcomes[key], SyncRowOutcome.invalid);
        expect(result.refusals[key], isNull);
      });

      test('an unkeyable row carries no detail either — the server does not '
          'know which part of a row it cannot even name', () async {
        final result = await push({
          Tables.observations: [
            {...observation('obs-x'), 'observation_id': null},
          ],
        });

        expect(result.refusals, isEmpty);
      });

      test('nothing the server refuses on authorization carries a detail, '
          'and the wire drops one even if a future change adds it', () async {
        // §4.13: `unauthorized` is one opaque answer for every reason, so a
        // code beside it would let a push probe what the server holds. Two
        // locks, because this is a security bound: the server writes none,
        // and `SyncPushResponse` drops any that appear.
        final result = await push({
          // A record naming somebody who is not the pusher — finding N-1's
          // case, refused by authorization rather than by validation.
          Tables.observations: [
            {...observation('obs-theirs'), 'user_id': 'somebody-else'},
          ],
        });

        final key = '${Tables.observations}/obs-theirs/$projectId';
        expect(result.outcomes[key], SyncRowOutcome.unauthorized);
        expect(result.refusals[key], isNull);

        final onTheWire = SyncPushResponse(
          applied: result.applied,
          outcomes: result.outcomes,
          highestServerSeq: result.highestServerSeq,
          // Forced, to prove the drop happens rather than merely that the
          // server did not write one.
          refusals: {
            key: const RowRefusal(
              code: RowIssueCode.textNotAName,
              field: 'first_name',
            ),
          },
        );
        expect(onTheWire.refusals, isEmpty);
        expect(onTheWire.toJson().containsKey('refusals'), isFalse);
      });
    });
  });

  group('pull', skip: databaseSkipReason, () {
    test('server-only columns never cross the wire', () async {
      // A client that stored these would depend on columns Phase 10's
      // invariant 3 forbids it from requiring.
      await push({
        Tables.observations: [observation('obs-1')],
      });
      final page = await pull(cursor: 0);
      final row = page.rows[Tables.observations]!.single;
      expect(row.containsKey('server_seq'), isFalse);
      expect(row.containsKey('received_at'), isFalse);
      expect(row.containsKey('clock_skew_flag'), isFalse);
    });

    test('pages by server_seq and reports what remains', () async {
      for (var i = 0; i < 7; i++) {
        await push({
          Tables.observations: [observation('obs-$i')],
        });
      }
      var cursor = 0;
      var delivered = 0;
      final remainingSeen = <int>[];
      while (true) {
        final page = await pull(cursor: cursor, batchSize: 3);
        final count = page.rows.values.fold(0, (s, l) => s + l.length);
        if (count == 0) break;
        delivered += count;
        remainingSeen.add(page.remaining);
        cursor = page.nextCursor;
      }
      expect(delivered, 7);
      expect(remainingSeen.last, 0);
    });

    test('an empty pull does not rewind the cursor', () async {
      await push({
        Tables.observations: [observation('obs-1')],
      });
      final first = await pull(cursor: 0);
      final second = await pull(cursor: first.nextCursor);
      expect(second.rows.values.fold(0, (s, l) => s + l.length), 0);
      expect(second.nextCursor, first.nextCursor);
    });

    test('re-pulling the same cursor returns the same rows', () async {
      // The reason ack is separate: the server must not treat "sent" as
      // "stored", so a page received but never committed comes back.
      await push({
        Tables.observations: [observation('obs-1')],
      });
      final a = await pull(cursor: 0);
      final b = await pull(cursor: 0);
      expect(
        b.rows[Tables.observations]!.map((r) => r['observation_id']),
        a.rows[Tables.observations]!.map((r) => r['observation_id']),
      );
    });

    test('another project\'s rows are never returned', () async {
      await push({
        Tables.observations: [observation('obs-mine')],
      });
      // Insert a row belonging to a different project directly, bypassing the
      // push path's scoping check.
      await connection.runTx((tx) async {
        await tx.execute(
          'INSERT INTO ${quoted(Tables.projects)} '
          '(project_id, project_name, owner_user_id, creation_date, datum, '
          'created_at, updated_at, revision, coordinate_format, '
          'triangulation_window_minutes, server_seq) '
          r"VALUES ('other', 'Other', $1, $2, 'WGS84', $2, $2, 0, 'dd', 15, 9999)",
          parameters: [userId, '2026-08-01T12:00:00.000Z'],
        );
      });
      final page = await pull(cursor: 0);
      final projects = page.rows[Tables.projects] ?? const [];
      expect(projects.map((r) => r['project_id']), isNot(contains('other')));
    });
  });

  group('cursors', skip: databaseSkipReason, () {
    const laptop = SyncCursorKey(
      userId: userId,
      deviceId: 'laptop',
      projectId: projectId,
    );
    const phone = SyncCursorKey(
      userId: userId,
      deviceId: 'phone',
      projectId: projectId,
    );

    test('two devices of one user have independent stored positions', () async {
      final store = CursorStore(connection);
      await store.acknowledge(laptop, cursor: 50, at: DateTime.now().toUtc());

      expect((await store.read(laptop))!.acknowledgedSeq, 50);
      expect(
        await store.read(phone),
        isNull,
        reason: 'a per-user cursor would have advanced the phone too',
      );
    });

    test('acknowledgement is monotonic', () async {
      final store = CursorStore(connection);
      final now = DateTime.now().toUtc();
      await store.acknowledge(laptop, cursor: 50, at: now);
      await store.acknowledge(laptop, cursor: 10, at: now);
      expect((await store.read(laptop))!.acknowledgedSeq, 50);
    });

    test('the device registry lists every device with its position', () async {
      final store = CursorStore(connection);
      final now = DateTime.now().toUtc();
      await store.acknowledge(laptop, cursor: 50, at: now);
      await store.acknowledge(phone, cursor: 20, at: now);

      final devices = await store.devicesFor(
        userId: userId,
        projectId: projectId,
      );
      expect(devices.map((d) => d.deviceId), ['laptop', 'phone']);
      expect(
        devices.firstWhere((d) => d.deviceId == 'phone').cursor.acknowledgedSeq,
        20,
      );
    });
  });
}

Future<void> _seed(Connection connection) async {
  const at = '2026-08-01T12:00:00.000Z';
  await connection.runTx((tx) async {
    await tx.execute(
      'INSERT INTO ${quoted(Tables.users)} '
      '(user_id, first_name, last_name, email, created_at, updated_at, revision) '
      r"VALUES ('user-1', 'Sam', 'Ranger', 'sam@example.com', $1, $1, 0)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.projects)} '
      '(project_id, project_name, owner_user_id, creation_date, datum, '
      'created_at, updated_at, revision, coordinate_format, '
      'triangulation_window_minutes) '
      r"VALUES ('proj-1', 'Elk', 'user-1', $1, 'WGS84', $1, $1, 0, 'dd', 15)",
      parameters: [at],
    );
  });
}

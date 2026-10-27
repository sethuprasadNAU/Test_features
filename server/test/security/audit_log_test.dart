@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack_server/tritrack_server.dart';

import '../support/database_test_config.dart';

/// §4.7's authentication audit log and its bounded retention.
///
/// **Two controls here, and the second is easy to overlook.** The log must
/// record the events §4.7 lists — but it must also *forget* them on schedule:
/// §4.7's `Violated by:` list names "retention that quietly grows without
/// bound", which is what both logs did before this task (10.13 filed the
/// traffic log's unbounded growth as Discovered Scope).
///
/// See `test/integration/postgres_sync_test.dart`'s header for how to run these.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_audit_log_test';

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
  });

  group('recording', skip: databaseSkipReason, () {
    test('every event §4.7 requires can be recorded and read back', () async {
      final log = AuthAuditLog(connection, onError: _noSilentFailures);
      for (final event in AuthAuditEvent.values) {
        await log.record(
          event,
          userId: 'user-1',
          email: 'sam@example.com',
          deviceId: 'laptop',
          sourceAddress: '203.0.113.5',
          outcome: 'ok',
          reason: 'because',
          requestId: 'trace-1',
        );
      }
      final entries = await log.recent();
      expect(
        entries.map((e) => e.event).toSet(),
        AuthAuditEvent.values.map((e) => e.db).toSet(),
      );
    });

    test('all the fields survive a round trip', () async {
      final log = AuthAuditLog(connection, onError: _noSilentFailures);
      await log.record(
        AuthAuditEvent.sessionRevoked,
        userId: 'user-1',
        email: 'sam@example.com',
        deviceId: 'lost-phone',
        sourceAddress: '203.0.113.5',
        outcome: 'sess-9',
        reason: 'device_revoked',
        requestId: 'trace-1',
      );
      final entry = (await log.recent()).single;
      expect(entry.event, 'session_revoked');
      expect(entry.userId, 'user-1');
      expect(entry.email, 'sam@example.com');
      expect(entry.deviceId, 'lost-phone');
      expect(entry.sourceAddress, '203.0.113.5');
      expect(entry.outcome, 'sess-9');
      expect(entry.reason, 'device_revoked');
      expect(entry.requestId, 'trace-1');
    });

    test('an oversized field is truncated, not written in full and not '
        'silently dropped', () async {
      // Security Model §7 D-2 (task 10.30): `sync_routes.dart` writes the
      // caller's `project_id` into `outcome` for an `authorization_denied`
      // row, and `project_id` is entirely caller-controlled. Ten denied
      // `/sync/pull` requests with a 1 MB `project_id` each wrote 10 MB to
      // this table in under a second. The genuine-denial guarantee C-5 exists
      // for still has to hold: the row is recorded, just bounded.
      final log = AuthAuditLog(connection, onError: _noSilentFailures);
      final oversized = 'x' * (maxAuditFieldLength * 10);
      await log.record(AuthAuditEvent.authorizationDenied, outcome: oversized);
      final entry = (await log.recent()).single;
      expect(entry.outcome, hasLength(maxAuditFieldLength));
      expect(entry.outcome, 'x' * maxAuditFieldLength);
    });

    test('an ordinary-sized field survives untouched', () async {
      // The bound must not clip genuine values — every real project id,
      // email, device id and trace id in this system is well under the cap.
      final log = AuthAuditLog(connection, onError: _noSilentFailures);
      await log.record(AuthAuditEvent.authorizationDenied, outcome: 'proj-1');
      final entry = (await log.recent()).single;
      expect(entry.outcome, 'proj-1');
    });

    test('forEmail answers the account-history question', () async {
      // "Was my account compromised in March?" is always scoped to one
      // identity, which is why the one-year retention exists.
      final log = AuthAuditLog(connection, onError: _noSilentFailures);
      await log.record(AuthAuditEvent.linkRequested, email: 'sam@example.com');
      await log.record(AuthAuditEvent.linkRequested, email: 'kim@example.com');
      final samEvents = await log.forEmail('sam@example.com');
      expect(samEvents, hasLength(1));
      expect(samEvents.single.email, 'sam@example.com');
    });

    test('a write failure never propagates to the caller', () async {
      // An audit write that threw would turn a logging problem into an
      // availability problem on the sign-in path. §1 ranks server availability
      // last but not at zero, and a full disk must not stop anyone signing in.
      final failures = <String>[];
      await connection.execute('DROP TABLE auth_audit_log');
      final log = AuthAuditLog(connection, onError: failures.add);
      await expectLater(
        log.record(AuthAuditEvent.linkRequested, email: 'sam@example.com'),
        completes,
      );
      expect(failures, hasLength(1));
      // The type only — a Postgres message can carry column values.
      expect(failures.single, isNot(contains('sam@example.com')));
    });

    test('a write on the connection running its own open transaction is '
        'refused, not silently dropped — and a dedicated connection avoids '
        'the collision entirely', () async {
      // Reproduces Security Model §7.3 B5 (task 10.23): the original
      // `auditDenial` shared its connection with the sync handler's own
      // `runTx`. `postgres` refuses a second statement on a connection
      // while that connection's own transaction is open, so every denial
      // audit write attempted this way was lost, silently, every time.
      final failures = <String>[];
      await connection.runTx((tx) async {
        final log = AuthAuditLog(connection, onError: failures.add);
        await log.record(AuthAuditEvent.authorizationDenied, userId: 'user-1');
      });
      expect(
        failures,
        hasLength(1),
        reason:
            'writing on `connection` while its own `runTx` is open must '
            'not succeed silently',
      );
      expect(
        await AuthAuditLog(connection, onError: _noSilentFailures).recent(),
        isEmpty,
        reason: 'the row above was refused, not merely delayed',
      );

      // The fix: a connection of its own has no transaction of its own to
      // collide with, no matter what `connection` is in the middle of.
      final dedicated = await Connection.open(
        testDatabaseConfig!.endpoint,
        settings: const ConnectionSettings(sslMode: SslMode.disable),
      );
      addTearDown(dedicated.close);
      await dedicated.execute('SET search_path TO $testSchema');

      await connection.runTx((tx) async {
        final log = AuthAuditLog(dedicated, onError: _noSilentFailures);
        await log.record(AuthAuditEvent.authorizationDenied, userId: 'user-2');
      });
      final rows = await AuthAuditLog(
        connection,
        onError: _noSilentFailures,
      ).recent();
      expect(rows, hasLength(1));
      expect(rows.single.userId, 'user-2');
    });
  });

  group(
    'the never-log rules are structural, not remembered',
    skip: databaseSkipReason,
    () {
      test('the table has no column that could hold a token', () async {
        // §4.7 rules 1 and 2. A caller *cannot* record a token through this API
        // because there is nowhere to put one — which is a stronger guarantee
        // than a code review that checks nobody did.
        final columns = await connection.execute(
          'SELECT column_name FROM information_schema.columns '
          r'WHERE table_schema = $1 AND table_name = $2',
          parameters: [testSchema, 'auth_audit_log'],
        );
        final names = columns.map((r) => r.first as String).toSet();
        for (final forbidden in ['token', 'token_hash', 'session_token']) {
          expect(names, isNot(contains(forbidden)));
        }
      });

      test('the table has no column that could hold a coordinate', () async {
        // §4.7 rule 6, the app-specific one the doc says will get broken by
        // accident. There is no latitude/longitude/bearing field to break.
        final columns = await connection.execute(
          'SELECT column_name FROM information_schema.columns '
          r'WHERE table_schema = $1 AND table_name = $2',
          parameters: [testSchema, 'auth_audit_log'],
        );
        final names = columns.map((r) => r.first as String).toSet();
        for (final forbidden in [
          'latitude',
          'longitude',
          'bearing',
          'elevation',
        ]) {
          expect(names, isNot(contains(forbidden)));
        }
      });
    },
  );

  group('retention is bounded', skip: databaseSkipReason, () {
    test('auth events older than a year are purged, newer are kept', () async {
      final now = DateTime.utc(2027, 6, 1);
      await _insertAuthEventAt(
        connection,
        now.subtract(const Duration(days: 400)),
      );
      await _insertAuthEventAt(
        connection,
        now.subtract(const Duration(days: 300)),
      );

      final result = await AuditRetentionService(
        connection,
        clock: () => now,
      ).purge();

      expect(result.authEvents, 1);
      final remaining = await AuthAuditLog(
        connection,
        onError: _noSilentFailures,
      ).recent();
      expect(remaining, hasLength(1));
      expect(
        remaining.single.occurredAt.isAfter(now.subtract(authAuditRetention)),
        isTrue,
      );
    });

    test('data-access rows older than 180 days are purged', () async {
      // Closes the gap task 10.13 filed: `sync_traffic_log` grew by one row per
      // sync request, forever.
      final now = DateTime.utc(2027, 6, 1);
      await _insertTrafficAt(
        connection,
        now.subtract(const Duration(days: 200)),
      );
      await _insertTrafficAt(
        connection,
        now.subtract(const Duration(days: 100)),
      );

      final result = await AuditRetentionService(
        connection,
        clock: () => now,
      ).purge();

      expect(result.dataAccess, 1);
      expect(await SyncTrafficLogStore(connection).recent(), hasLength(1));
    });

    test('the two windows are different, and the shorter one is not applied '
        'to the auth log', () async {
      // A single shared window would silently discard eight months of
      // account-security history — the thing "was my account compromised in
      // March?" needs in September.
      expect(authAuditRetention, const Duration(days: 365));
      expect(dataAccessRetention, const Duration(days: 180));

      final now = DateTime.utc(2027, 6, 1);
      await _insertAuthEventAt(
        connection,
        now.subtract(const Duration(days: 200)),
      );
      await AuditRetentionService(connection, clock: () => now).purge();
      expect(
        await AuthAuditLog(connection, onError: _noSilentFailures).recent(),
        hasLength(1),
        reason: 'a 200-day-old auth event is well inside its one-year window',
      );
    });

    test('purging an empty log is a harmless no-op', () async {
      final result = await AuditRetentionService(connection).purge();
      expect(result.authEvents, 0);
      expect(result.dataAccess, 0);
      expect(result.decidedJoinRequests, 0);
    });
  });

  // Task 11.79, widened by task 11.85's finding R-2. Six rejections on a fresh
  // project left six rows, and the only bound anywhere was a 200-row cap on
  // what the list routes *return* — which bounds a response and not a table.
  group('decided join requests are bounded too', skip: databaseSkipReason, () {
    test('a decision older than 30 days is swept', () async {
      final now = DateTime.utc(2027, 6, 1);
      await _insertJoinRequest(
        connection,
        id: 'old',
        decidedAt: now.subtract(const Duration(days: 40)),
      );
      await _insertJoinRequest(
        connection,
        id: 'recent',
        decidedAt: now.subtract(const Duration(days: 10)),
      );

      final result = await AuditRetentionService(
        connection,
        clock: () => now,
      ).purge();

      expect(result.decidedJoinRequests, 1);
      final left = await connection.execute(
        'SELECT request_id FROM project_join_requests',
      );
      expect(left.map((r) => r.first), ['recent']);
    });

    test('a pending request is never swept, however old', () async {
      // The one that matters most. A pending request is somebody waiting for
      // an answer; deleting it answers them by silence, and leaves them on
      // "pending" for ever — the class task 11.60 found for removed members,
      // arriving through the door meant to prevent it.
      final now = DateTime.utc(2027, 6, 1);
      await _insertJoinRequest(
        connection,
        id: 'ancient-pending',
        requestedAt: now.subtract(const Duration(days: 900)),
      );

      final result = await AuditRetentionService(
        connection,
        clock: () => now,
      ).purge();

      expect(result.decidedJoinRequests, 0);
      final left = await connection.execute(
        'SELECT request_id FROM project_join_requests',
      );
      expect(left, hasLength(1));
    });

    test('the window is 30 days and it is a knob of the same shape as the '
        'other two', () async {
      expect(decidedJoinRequestRetention, const Duration(days: 30));
      expect(
        retentionClasses.map((c) => c.table),
        containsAll(<String>[
          'auth_audit_log',
          'sync_traffic_log',
          'project_join_requests',
        ]),
        reason:
            'purge() and measure() both iterate this one list. A class missing '
            'from it is neither swept nor reported on, and nothing else would '
            'say so',
      );
    });
  });

  group(
    'the measurement is of the rows, not of the schedule',
    skip: databaseSkipReason,
    () {
      test('it reports the age of the oldest surviving row', () async {
        final now = DateTime.utc(2027, 6, 1);
        await _insertAuthEventAt(
          connection,
          now.subtract(const Duration(days: 40)),
        );
        await _insertAuthEventAt(
          connection,
          now.subtract(const Duration(days: 5)),
        );

        final readings = await AuditRetentionService(connection).measure();
        final auth = readings.firstWhere(
          (r) => r.retentionClass.table == 'auth_audit_log',
        );

        expect(auth.ageAt(now)!.inDays, 40);
      });

      test(
        'an empty class reads as empty, which is healthy and not absent',
        () async {
          // The one place this differs from task 11.78's freshness check. An empty
          // backup directory means every observation exists only on the phones
          // that recorded it; an empty audit table means there is nothing here to
          // leak.
          final readings = await AuditRetentionService(connection).measure();
          expect(readings.map((r) => r.oldest), everyElement(isNull));
          expect(
            readings.map((r) => r.ageAt(DateTime.now())),
            everyElement(isNull),
          );
        },
      );

      test('it measures the same population the sweep deletes', () async {
        // The way a green check can sit on top of a sweep that does nothing:
        // measure a set the delete does not cover. A pending join request is old
        // and is deliberately never deleted, so it must not be what the check
        // reports on either — or every server with one old pending request would
        // be permanently red for a state that is correct.
        final now = DateTime.utc(2027, 6, 1);
        await _insertJoinRequest(
          connection,
          id: 'ancient-pending',
          requestedAt: now.subtract(const Duration(days: 900)),
        );

        final readings = await AuditRetentionService(connection).measure();
        final joins = readings.firstWhere(
          (r) => r.retentionClass.table == 'project_join_requests',
        );
        expect(
          joins.oldest,
          isNull,
          reason:
              'the check reads decided_at, and this row has none. If it read '
              'requested_at the check would go red over a row it is right not '
              'to delete',
        );
      });
    },
  );
}

Future<void> _insertJoinRequest(
  Connection connection, {
  required String id,
  DateTime? requestedAt,
  DateTime? decidedAt,
}) => connection.execute(
  'INSERT INTO project_join_requests '
  '(request_id, project_id, user_id, email, requested_at, decided_at, '
  r' decision) VALUES ($1, $2, $3, $4, $5, $6, $7)',
  parameters: [
    id,
    'project-1',
    'user-$id',
    'sam@example.com',
    requestedAt ?? decidedAt ?? DateTime.utc(2027, 1, 1),
    decidedAt,
    decidedAt == null ? null : joinDecisionRejected,
  ],
);

/// For call sites in this file where the write is expected to succeed:
/// surfaces a swallowed failure as a test failure instead of silence, which
/// is the whole point of [AuthAuditLog.onError] no longer being optional.
Never _noSilentFailures(String type) =>
    fail('audit log write failed and was swallowed: $type');

Future<void> _insertAuthEventAt(Connection connection, DateTime at) =>
    connection.execute(
      'INSERT INTO auth_audit_log (occurred_at, event, email) '
      r"VALUES ($1, 'link_requested', 'sam@example.com')",
      parameters: [at],
    );

Future<void> _insertTrafficAt(Connection connection, DateTime at) =>
    connection.execute(
      'INSERT INTO sync_traffic_log (occurred_at, kind, status_code) '
      r"VALUES ($1, 'push', 200)",
      parameters: [at],
    );

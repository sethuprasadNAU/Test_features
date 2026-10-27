@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

import '../support/database_test_config.dart';

/// §4.3's two revocation granularities, against real SQL.
///
/// **This file holds task 10.14's headline acceptance criterion:** "revoking a
/// user mid-session invalidates that user's sessions on every device, verified
/// with two active sessions." A route-level test with a fake service can prove
/// the right *method* is called; only real rows prove the `WHERE` clause
/// actually reaches both devices. Revoking the session that happened to make
/// the last request, while the other phone keeps syncing, is the same as not
/// revoking — which is why the two-device case is the test that matters.
///
/// See `test/integration/postgres_sync_test.dart`'s header for how to run these.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_revocation_test';

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

  final captured = <String, String>{};
  var idCounter = 0;
  String nextId() => 'id-${idCounter++}';

  AuthService authOn(Session session) => AuthService(
    session: session,
    emailSender: _CapturingSender(captured),
    linkBaseUrl: 'http://test',
  );

  /// Signs in one device, returning its live session token.
  Future<IssuedSession> signIn(String email, String deviceId) =>
      connection.runTx((tx) async {
        final auth = authOn(tx);
        await auth.requestMagicLink(rawEmail: email, requestId: nextId());
        final token = Uri.parse(captured[email]!).queryParameters['token']!;
        final issued = await auth.redeem(
          token: token,
          deviceId: deviceId,
          sessionId: nextId(),
          newUserId: nextId(),
        );
        return issued!;
      });

  Future<ActiveSession?> validate(String token) =>
      connection.runTx((tx) => authOn(tx).validateSession(token));

  group('all-devices revocation', skip: databaseSkipReason, () {
    test(
      'revoking a user invalidates their sessions on EVERY device',
      () async {
        // The acceptance criterion, stated literally. Two devices, one person,
        // both live.
        final laptop = await signIn('sam@example.com', 'laptop');
        final phone = await signIn('sam@example.com', 'phone');
        expect(
          laptop.userId,
          phone.userId,
          reason: 'same person, same user_id',
        );
        expect(await validate(laptop.token), isNotNull);
        expect(await validate(phone.token), isNotNull);

        final revoked = await connection.runTx(
          (tx) => authOn(tx).revokeAllSessionsForUser(laptop.userId),
        );
        expect(revoked, 2, reason: 'both sessions, not just the latest');

        // The point: neither device works on its *next request*, with no
        // grace period and no exception for work in progress.
        expect(await validate(laptop.token), isNull);
        expect(
          await validate(phone.token),
          isNull,
          reason:
              'a removed member whose other phone keeps syncing is the same '
              'as not revoking at all',
        );
      },
    );

    test('another user\'s sessions are untouched', () async {
      final sam = await signIn('sam@example.com', 'laptop');
      final kim = await signIn('kim@example.com', 'laptop');
      expect(sam.userId, isNot(kim.userId));

      await connection.runTx(
        (tx) => authOn(tx).revokeAllSessionsForUser(sam.userId),
      );

      expect(await validate(sam.token), isNull);
      expect(
        await validate(kim.token),
        isNotNull,
        reason: 'revocation is scoped to one user_id',
      );
    });

    test(
      'revoking twice is idempotent and reports nothing the second time',
      () async {
        final laptop = await signIn('sam@example.com', 'laptop');
        final first = await connection.runTx(
          (tx) => authOn(tx).revokeAllSessionsForUser(laptop.userId),
        );
        final second = await connection.runTx(
          (tx) => authOn(tx).revokeAllSessionsForUser(laptop.userId),
        );
        expect(first, 1);
        expect(
          second,
          0,
          reason:
              'the WHERE clause excludes already-revoked rows, so a second call '
              'does not rewrite revoked_at and lose when it first happened',
        );
      },
    );

    test('the reason is recorded so an audit can say why', () async {
      final laptop = await signIn('sam@example.com', 'laptop');
      await connection.runTx(
        (tx) => authOn(
          tx,
        ).revokeAllSessionsForUser(laptop.userId, reason: 'membership_ended'),
      );
      final rows = await connection.execute(
        'SELECT revoked_reason FROM auth_sessions WHERE user_id = \$1',
        parameters: [laptop.userId],
      );
      expect(rows.single.first, 'membership_ended');
    });
  });

  group('per-device revocation', skip: databaseSkipReason, () {
    test('cuts off one device and leaves the other signed in', () async {
      // §4.8's device-loss mitigation: sign out the phone that went missing
      // without signing the person out of the laptop in their hand.
      final laptop = await signIn('sam@example.com', 'laptop');
      final phone = await signIn('sam@example.com', 'phone');

      final revoked = await connection.runTx(
        (tx) => authOn(tx).revokeDeviceSessions(phone.userId, 'phone'),
      );
      expect(revoked, 1);

      expect(await validate(phone.token), isNull);
      expect(
        await validate(laptop.token),
        isNotNull,
        reason: 'per-device revocation must not be all-devices in disguise',
      );
    });

    test('a device_id belonging to another user revokes nothing', () async {
      // The scoping that makes the self-service route safe: the SQL is keyed on
      // `(user_id, device_id)`, so even a forged device_id can only ever reach
      // the caller's own rows.
      final sam = await signIn('sam@example.com', 'laptop');
      final kim = await signIn('kim@example.com', 'laptop');

      final revoked = await connection.runTx(
        // Sam tries to revoke "laptop" — a device_id Kim also uses.
        (tx) => authOn(tx).revokeDeviceSessions(sam.userId, 'laptop'),
      );
      expect(revoked, 1, reason: 'only Sam\'s laptop');
      expect(await validate(sam.token), isNull);
      expect(await validate(kim.token), isNotNull);
    });

    test('signing in again on a revoked device works', () async {
      // Revocation kills credentials, not the device. Otherwise recovering a
      // "lost" phone that turned up in a coat pocket would need an admin.
      final phone = await signIn('sam@example.com', 'phone');
      await connection.runTx(
        (tx) => authOn(tx).revokeDeviceSessions(phone.userId, 'phone'),
      );
      expect(await validate(phone.token), isNull);

      final again = await signIn('sam@example.com', 'phone');
      expect(await validate(again.token), isNotNull);
      expect(again.userId, phone.userId);
    });
  });

  group('listing your own devices (task 11.35)', skip: databaseSkipReason, () {
    Future<List<ListedSession>> listFor(
      String userId, {
      String currentDeviceId = 'laptop',
      int limit = maxListedSessions,
    }) => connection.runTx(
      (tx) => authOn(tx).listSessionsForUser(
        userId,
        currentDeviceId: currentDeviceId,
        limit: limit,
      ),
    );

    test('a caller sees their own devices and nobody else\'s', () async {
      // The acceptance criterion against real rows. A route-level test proves
      // the query is keyed on the session's user; only this proves the `WHERE`
      // clause actually excludes somebody else's rows.
      final sam = await signIn('sam@example.com', 'laptop');
      await signIn('sam@example.com', 'phone');
      final kim = await signIn('kim@example.com', 'kims-laptop');

      final samsDevices = await listFor(sam.userId);
      expect(
        samsDevices.map((s) => s.deviceId),
        containsAll(['laptop', 'phone']),
      );
      expect(samsDevices.map((s) => s.deviceId), isNot(contains('kims-laptop')));
      expect(samsDevices, hasLength(2));

      final kimsDevices = await listFor(
        kim.userId,
        currentDeviceId: 'kims-laptop',
      );
      expect(kimsDevices.map((s) => s.deviceId), ['kims-laptop']);
    });

    test('the device in your hand is the one marked as such', () async {
      final sam = await signIn('sam@example.com', 'laptop');
      await signIn('sam@example.com', 'phone');

      final devices = await listFor(sam.userId, currentDeviceId: 'phone');
      final current = devices.where((d) => d.isCurrentDevice);
      expect(current, hasLength(1));
      expect(current.single.deviceId, 'phone');
    });

    test('revoking one listed device removes it and leaves the rest', () async {
      // The third acceptance criterion, end to end: the list names a device,
      // the existing per-device route takes that name, and afterwards that
      // device is gone from the list and stops working while the other does
      // not.
      final sam = await signIn('sam@example.com', 'laptop');
      final phone = await signIn('sam@example.com', 'phone');
      expect(await listFor(sam.userId), hasLength(2));

      await connection.runTx(
        (tx) => authOn(tx).revokeDeviceSessions(sam.userId, 'phone'),
      );

      expect((await listFor(sam.userId)).map((s) => s.deviceId), ['laptop']);
      expect(await validate(phone.token), isNull);
      expect(await validate(sam.token), isNotNull);
    });

    test('two sign-ins on one device are one row, not two', () async {
      // Revocation is keyed on `(user_id, device_id)` and ends both sessions
      // together, so a list that showed two rows would offer a control that
      // silently closed the row next to it.
      final first = await signIn('sam@example.com', 'phone');
      final second = await signIn('sam@example.com', 'phone');
      expect(await validate(first.token), isNotNull);
      expect(await validate(second.token), isNotNull);

      final devices = await listFor(first.userId, currentDeviceId: 'phone');
      expect(devices.map((d) => d.deviceId), ['phone']);
      expect(devices.single.isCurrentDevice, isTrue);
    });

    test('a signed-out device stops being listed', () async {
      final sam = await signIn('sam@example.com', 'laptop');
      final phone = await signIn('sam@example.com', 'phone');
      await connection.runTx((tx) => authOn(tx).signOut(phone.token));

      expect((await listFor(sam.userId)).map((s) => s.deviceId), ['laptop']);
    });

    test('an expired session is not listed as a live device', () async {
      // The list must mean "would still work if used right now" — the same
      // three conditions `validateSession` enforces. A device listed after its
      // session expired invites somebody to revoke a thing that is already
      // gone and to leave a real one alone.
      final sam = await signIn('sam@example.com', 'laptop');
      await connection.execute(
        r'UPDATE auth_sessions SET expires_at = $1 '
        r'WHERE user_id = $2 AND device_id = $3',
        parameters: [
          DateTime.now().toUtc().subtract(const Duration(days: 1)),
          sam.userId,
          'laptop',
        ],
      );

      expect(await listFor(sam.userId), isEmpty);
    });

    test('the result is bounded', () async {
      // A caller can mint device ids freely, so the row count is
      // caller-influenced — task 10.56's rule applied to a `SELECT`.
      final sam = await signIn('sam@example.com', 'laptop');
      for (var i = 0; i < 5; i++) {
        await signIn('sam@example.com', 'device-$i');
      }
      final devices = await listFor(sam.userId, limit: 3);
      expect(devices, hasLength(3));
    });
  });

  group(
    'a revoked session cannot be refreshed by being rejected',
    skip: databaseSkipReason,
    () {
      test('validating a revoked session does not move last_seen_at', () async {
        // The freshness conditions live inside the UPDATE for this reason. If a
        // rejected validation still bumped the clock, a revoked session would
        // look active in the device registry forever — and §4.3's "a session
        // cache that serves a revoked session" failure would be one refactor away.
        final laptop = await signIn('sam@example.com', 'laptop');
        final before = await connection.execute(
          'SELECT last_seen_at FROM auth_sessions WHERE user_id = \$1',
          parameters: [laptop.userId],
        );
        await connection.runTx(
          (tx) => authOn(tx).revokeAllSessionsForUser(laptop.userId),
        );

        await validate(laptop.token);
        final after = await connection.execute(
          'SELECT last_seen_at FROM auth_sessions WHERE user_id = \$1',
          parameters: [laptop.userId],
        );
        expect(after.single.first, before.single.first);
      });
    },
  );
}

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

@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

import '../support/database_test_config.dart';

/// End-to-end auth against a real Postgres — the single-use, expiry, replay and
/// enumeration properties Security Gate A checks.
///
/// Skipped unless a database is configured; see
/// `test/integration/postgres_sync_test.dart`'s header for how to run these.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_auth_test';

  var idCounter = 0;
  String nextId() => 'id-${++idCounter}';

  /// Captures links instead of sending them, so a test can read the token the
  /// user would have received.
  final captured = <String, String>{};
  final sender = _CapturingSender(captured);

  Future<T> withAuth<T>(Future<T> Function(AuthService) action) {
    return action(
      AuthService(
        session: connection,
        emailSender: sender,
        linkBaseUrl: 'http://localhost:8080',
      ),
    );
  }

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
    idCounter = 0;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
  });

  /// Requests a link and returns the token the "email" carried.
  Future<String> requestToken(String email) async {
    await withAuth(
      (a) => a.requestMagicLink(rawEmail: email, requestId: nextId()),
    );
    final url = captured[normalizeEmailForTest(email)]!;
    return Uri.parse(url).queryParameters['token']!;
  }

  group('single use and expiry', skip: databaseSkipReason, () {
    test('a token works exactly once', () async {
      final token = await requestToken('sam@example.com');

      final first = await withAuth(
        (a) => a.redeem(
          token: token,
          deviceId: 'device-A',
          sessionId: nextId(),
          newUserId: nextId(),
        ),
      );
      expect(first, isNotNull);

      // Replay: the same token a second time must fail.
      final second = await withAuth(
        (a) => a.redeem(
          token: token,
          deviceId: 'device-A',
          sessionId: nextId(),
          newUserId: nextId(),
        ),
      );
      expect(second, isNull);
    });

    test('two concurrent redemptions cannot both succeed', () async {
      // The atomic conditional UPDATE is what makes this safe; a
      // SELECT-then-UPDATE would let both through.
      final token = await requestToken('sam@example.com');
      final results = await Future.wait([
        withAuth(
          (a) => a.redeem(
            token: token,
            deviceId: 'device-A',
            sessionId: nextId(),
            newUserId: nextId(),
          ),
        ),
        withAuth(
          (a) => a.redeem(
            token: token,
            deviceId: 'device-B',
            sessionId: nextId(),
            newUserId: nextId(),
          ),
        ),
      ]);
      expect(results.where((r) => r != null), hasLength(1));
    });

    test('an expired token is refused', () async {
      final token = await requestToken('sam@example.com');
      // Advance past the 15-minute window.
      final future = DateTime.now().toUtc().add(magicLinkLifetime * 2);
      final result =
          await AuthService(
            session: connection,
            emailSender: sender,
            linkBaseUrl: 'http://localhost:8080',
            clock: () => future,
          ).redeem(
            token: token,
            deviceId: 'device-A',
            sessionId: nextId(),
            newUserId: nextId(),
          );
      expect(result, isNull);
    });

    test('an unknown token is refused', () async {
      final result = await withAuth(
        (a) => a.redeem(
          token: Tokens.generate(),
          deviceId: 'device-A',
          sessionId: nextId(),
          newUserId: nextId(),
        ),
      );
      expect(result, isNull);
    });

    test('requesting again invalidates the previous unconsumed link', () async {
      final first = await requestToken('sam@example.com');
      final second = await requestToken('sam@example.com');
      expect(first, isNot(second));

      expect(
        await withAuth(
          (a) => a.redeem(
            token: first,
            deviceId: 'device-A',
            sessionId: nextId(),
            newUserId: nextId(),
          ),
        ),
        isNull,
        reason: 'tapping resend must leave one live token, not two',
      );
      expect(
        await withAuth(
          (a) => a.redeem(
            token: second,
            deviceId: 'device-A',
            sessionId: nextId(),
            newUserId: nextId(),
          ),
        ),
        isNotNull,
      );
    });
  });

  group('tokens at rest', skip: databaseSkipReason, () {
    test('no plaintext token is stored anywhere', () async {
      final token = await requestToken('sam@example.com');
      final issued = await withAuth(
        (a) => a.redeem(
          token: token,
          deviceId: 'device-A',
          sessionId: nextId(),
          newUserId: nextId(),
        ),
      );

      final links = await connection.execute(
        'SELECT token_hash FROM auth_magic_links',
      );
      expect(links.first.first, isNot(token));
      expect(links.first.first, Tokens.hash(token));

      final sessions = await connection.execute(
        'SELECT token_hash FROM auth_sessions',
      );
      expect(sessions.first.first, isNot(issued!.token));
      expect(sessions.first.first, Tokens.hash(issued.token));
    });
  });

  group(
    'the server is authoritative for user_id',
    skip: databaseSkipReason,
    () {
      test(
        'two devices signing in to one email get the SAME user_id',
        () async {
          // The acceptance criterion, and the whole reason the server owns this
          // decision: without it the two devices rename each other forever.
          final tokenA = await requestToken('sam@example.com');
          final a = await withAuth(
            (s) => s.redeem(
              token: tokenA,
              deviceId: 'device-A',
              sessionId: nextId(),
              newUserId: nextId(),
            ),
          );

          final tokenB = await requestToken('sam@example.com');
          final b = await withAuth(
            (s) => s.redeem(
              token: tokenB,
              deviceId: 'device-B',
              sessionId: nextId(),
              newUserId: nextId(),
            ),
          );

          expect(a!.userId, b!.userId);
          expect(a.email, 'sam@example.com');
        },
      );

      test(
        'the address is normalized, so case and spacing do not fork identity',
        () async {
          final tokenA = await requestToken('Sam@Example.com');
          final a = await withAuth(
            (s) => s.redeem(
              token: tokenA,
              deviceId: 'device-A',
              sessionId: nextId(),
              newUserId: nextId(),
            ),
          );

          final tokenB = await requestToken('  sam@example.com ');
          final b = await withAuth(
            (s) => s.redeem(
              token: tokenB,
              deviceId: 'device-B',
              sessionId: nextId(),
              newUserId: nextId(),
            ),
          );

          expect(a!.userId, b!.userId);
        },
      );

      test('different addresses get different ids', () async {
        final tokenA = await requestToken('sam@example.com');
        final a = await withAuth(
          (s) => s.redeem(
            token: tokenA,
            deviceId: 'device-A',
            sessionId: nextId(),
            newUserId: nextId(),
          ),
        );
        final tokenB = await requestToken('kim@example.com');
        final b = await withAuth(
          (s) => s.redeem(
            token: tokenB,
            deviceId: 'device-B',
            sessionId: nextId(),
            newUserId: nextId(),
          ),
        );
        expect(a!.userId, isNot(b!.userId));
      });

      test('no account exists until a link is redeemed', () async {
        // Creating one at request time would make an unauthenticated endpoint a
        // database writer and a second enumeration oracle.
        await requestToken('sam@example.com');
        final before = await connection.execute(
          'SELECT count(*) FROM auth_accounts',
        );
        expect(before.first.first, 0);
      });
    },
  );

  group('sessions', skip: databaseSkipReason, () {
    Future<IssuedSession> signIn(String email, String deviceId) async {
      final token = await requestToken(email);
      final issued = await withAuth<IssuedSession?>(
        (a) => a.redeem(
          token: token,
          deviceId: deviceId,
          sessionId: nextId(),
          newUserId: nextId(),
        ),
      );
      return issued!;
    }

    test('a fresh session validates', () async {
      final session = await signIn('sam@example.com', 'device-A');
      final active = await withAuth((a) => a.validateSession(session.token));
      expect(active!.userId, session.userId);
      expect(active.deviceId, 'device-A');
    });

    test('signing in on a second device does NOT sign out the first', () async {
      final first = await signIn('sam@example.com', 'device-A');
      final second = await signIn('sam@example.com', 'device-B');

      expect(await withAuth((a) => a.validateSession(first.token)), isNotNull);
      expect(await withAuth((a) => a.validateSession(second.token)), isNotNull);
    });

    test('signing out revokes only that session', () async {
      final first = await signIn('sam@example.com', 'device-A');
      final second = await signIn('sam@example.com', 'device-B');

      await withAuth((a) => a.signOut(first.token));

      expect(await withAuth((a) => a.validateSession(first.token)), isNull);
      expect(await withAuth((a) => a.validateSession(second.token)), isNotNull);
    });

    test('revoking a user kills every device at once', () async {
      final first = await signIn('sam@example.com', 'device-A');
      final second = await signIn('sam@example.com', 'device-B');

      final revoked = await withAuth(
        (a) => a.revokeAllSessionsForUser(first.userId),
      );
      expect(revoked, 2);

      expect(await withAuth((a) => a.validateSession(first.token)), isNull);
      expect(await withAuth((a) => a.validateSession(second.token)), isNull);
    });

    test('per-device revocation spares the other device', () async {
      final first = await signIn('sam@example.com', 'device-A');
      final second = await signIn('sam@example.com', 'device-B');

      await withAuth((a) => a.revokeDeviceSessions(first.userId, 'device-A'));

      expect(await withAuth((a) => a.validateSession(first.token)), isNull);
      expect(await withAuth((a) => a.validateSession(second.token)), isNotNull);
    });

    test('an expired session stops validating', () async {
      final session = await signIn('sam@example.com', 'device-A');
      final future = DateTime.now().toUtc().add(
        sessionAbsoluteLifetime + const Duration(days: 1),
      );
      final active = await AuthService(
        session: connection,
        emailSender: sender,
        linkBaseUrl: 'http://localhost:8080',
        clock: () => future,
      ).validateSession(session.token);
      expect(active, isNull);
    });

    test(
      'an idle session stops validating even inside its absolute life',
      () async {
        final session = await signIn('sam@example.com', 'device-A');
        final future = DateTime.now().toUtc().add(
          sessionIdleLifetime + const Duration(days: 1),
        );
        final active = await AuthService(
          session: connection,
          emailSender: sender,
          linkBaseUrl: 'http://localhost:8080',
          clock: () => future,
        ).validateSession(session.token);
        expect(active, isNull);
      },
    );

    test('a revoked session is not refreshed by being rejected', () async {
      // The freshness conditions live in the UPDATE precisely so a rejected
      // session cannot have its clock bumped as a side effect.
      final session = await signIn('sam@example.com', 'device-A');
      final before = await connection.execute(
        'SELECT last_seen_at FROM auth_sessions',
      );
      await withAuth((a) => a.signOut(session.token));
      await withAuth((a) => a.validateSession(session.token));
      final after = await connection.execute(
        'SELECT last_seen_at FROM auth_sessions',
      );
      expect(after.first.first, before.first.first);
    });

    test('an unknown bearer token validates to nothing', () async {
      expect(
        await withAuth((a) => a.validateSession(Tokens.generate())),
        isNull,
      );
    });
  });

  group('cross-device link behaviour', skip: databaseSkipReason, () {
    test('the requesting device learns its link was used elsewhere', () async {
      const requestId = 'req-1';
      await withAuth(
        (a) => a.requestMagicLink(
          rawEmail: 'sam@example.com',
          requestId: requestId,
        ),
      );
      final token = Uri.parse(
        captured['sam@example.com']!,
      ).queryParameters['token']!;

      expect(
        await withAuth((a) => a.linkRequestOutcome(requestId)),
        isNull,
        reason: 'pending until someone redeems',
      );

      // A *different* device redeems.
      await withAuth(
        (a) => a.redeem(
          token: token,
          deviceId: 'device-OTHER',
          sessionId: nextId(),
          newUserId: nextId(),
        ),
      );

      expect(
        await withAuth((a) => a.linkRequestOutcome(requestId)),
        LinkRequestOutcome.consumed,
        reason: 'the requester must not wait silently forever',
      );
    });

    test(
      'an unused link resolves to expired rather than pending forever',
      () async {
        const requestId = 'req-2';
        await withAuth(
          (a) => a.requestMagicLink(
            rawEmail: 'sam@example.com',
            requestId: requestId,
          ),
        );

        final future = DateTime.now().toUtc().add(magicLinkLifetime * 2);
        final outcome = await AuthService(
          session: connection,
          emailSender: sender,
          linkBaseUrl: 'http://localhost:8080',
          clock: () => future,
        ).linkRequestOutcome(requestId);
        expect(outcome, LinkRequestOutcome.expired);
      },
    );

    test(
      'an unknown request id is indistinguishable from a pending one',
      () async {
        expect(
          await withAuth((a) => a.linkRequestOutcome('never-existed')),
          isNull,
        );
      },
    );
  });

  group('enumeration resistance', skip: databaseSkipReason, () {
    test(
      'an unregistered address is treated exactly like a registered one',
      () async {
        // Both get a link; neither creates an account until redemption. There is
        // nothing in the stored state that distinguishes "known" from "unknown"
        // at request time.
        final registeredToken = await requestToken('registered@example.com');
        await withAuth(
          (a) => a.redeem(
            token: registeredToken,
            deviceId: 'device-A',
            sessionId: nextId(),
            newUserId: nextId(),
          ),
        );

        captured.clear();
        await withAuth(
          (a) => a.requestMagicLink(
            rawEmail: 'registered@example.com',
            requestId: nextId(),
          ),
        );
        final registeredGotLink = captured.containsKey(
          'registered@example.com',
        );

        captured.clear();
        await withAuth(
          (a) => a.requestMagicLink(
            rawEmail: 'never-seen@example.com',
            requestId: nextId(),
          ),
        );
        final unknownGotLink = captured.containsKey('never-seen@example.com');

        expect(registeredGotLink, isTrue);
        expect(unknownGotLink, isTrue);
      },
    );
  });
}

/// Local copy of the shared normalizer, so a test failure points at the
/// production one rather than at shared code the test also depends on.
String normalizeEmailForTest(String email) => email.trim().toLowerCase();

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

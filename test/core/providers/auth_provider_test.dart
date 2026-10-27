import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 10.17 drove `AuthClient`/`ServerIdentityAdopter` directly against a
/// real server, and a bare crash reproduction would drive `completeSignIn`
/// itself in isolation — neither exercises the Riverpod provider layer
/// `CurrentSession.completeSignIn` actually runs inside, which is exactly
/// where the reported bug lived: `ActiveUserId.set()` (an `autoDispose`
/// notifier with no active listener, mutated via a bare
/// `ref.read(...).notifier).set(...)`) was torn down mid-`await` on a real
/// device, throwing "Cannot use the Ref of activeUserIdProvider after it has
/// been disposed." from inside `completeSignIn`. These tests drive
/// `completeSignIn` the way the app actually calls it: through
/// `ProviderContainer`, against a faked HTTP transport standing in for the
/// server, with no listener on `activeUserIdProvider` (mirroring
/// `completeSignIn`'s own bare `ref.read`).
///
/// **This does not reliably reproduce the disposal race itself** — confirmed
/// by deliberately reverting `ActiveProjectId`/`ActiveUserId` to `autoDispose`
/// with no `ref.mounted` guard and re-running: still green, even with a real
/// `Future.delayed` standing in for the network round trip. A bare
/// `ProviderContainer` schedules disposal off a zero-duration `Timer`, while
/// the real app's widget-bound `ProviderScope` schedules it off a `Vsync`
/// (frame callbacks) — the two don't race identically, so a passing unit
/// test here is not proof the crash can't happen and a failing one wouldn't
/// be proof it can. What this suite actually adds: real coverage of
/// `completeSignIn` running through the provider graph end to end (which
/// previously had none), so a genuine regression in that flow — a thrown
/// exception, a wrong final `state`, a step silently skipped — is caught
/// regardless of whether it happens to be timing-shaped. The disposal race
/// itself is closed by `keepAlive`, a fix that holds regardless of scheduler
/// timing, not by anything provable at this level — see
/// `active_selection_provider.dart`'s own doc comment.
void main() {
  setUp(installFakeSharedPreferences);

  ProviderContainer makeContainer(
    http.Client httpClient, {
    FakeSessionStore? store,
  }) {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        sessionStoreProvider.overrideWithValue(store ?? FakeSessionStore()),
        serverHttpClientProvider.overrideWith((ref) async => httpClient),
      ],
    );
    return container;
  }

  Future<void> configureServer(ProviderContainer container) =>
      container.read(serverConfigProvider.notifier).setUrl('http://test.local');

  http.Client redeemingClient({
    required String userId,
    required String email,
    int statusCode = 200,
  }) {
    return MockClient((request) async {
      // A small delay so this stands in for a real network round trip rather
      // than resolving instantly — doesn't reliably force the disposal race
      // (see this file's own doc comment), but keeps the test honest about
      // shape rather than resolving synchronously.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (request.url.path == '/auth/redeem') {
        if (statusCode != 200) {
          // The body matters as of task 11.37: a rejected token is a `400`
          // carrying `invalid_or_expired_link`, and *that* is what makes it a
          // rejection rather than a server that answered oddly. An empty body
          // here would have this stand in for a failure the real route never
          // produces.
          return http.Response(
            jsonEncode({'error': 'invalid_or_expired_link'}),
            statusCode,
          );
        }
        return http.Response(
          jsonEncode({
            'session_token': 'session-token-$userId',
            'user_id': userId,
            'email': email,
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 1))
                .toIso8601String(),
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });
  }

  test('completeSignIn succeeds through the real provider stack with no '
      'listener on activeUserIdProvider — the exact condition that crashed '
      'on a real device (task 10.4)', () async {
    final client = redeemingClient(
      userId: 'server-user-1',
      email: 'sam@example.com',
    );
    final container = makeContainer(client);
    addTearDown(container.dispose);
    await configureServer(container);

    // Deliberately no `container.listen(activeUserIdProvider, ...)` here —
    // `completeSignIn` itself only ever bare-`read`s it, and the fix must
    // hold under exactly that call pattern, not merely when a test
    // incidentally props the provider open.
    await container
        .read(currentSessionProvider.notifier)
        .completeSignIn(
          'a'.padRight(32, 'a'),
          expectedEmail: 'sam@example.com',
        );

    final session = container.read(currentSessionProvider).value;
    expect(session, isNotNull);
    expect(session!.userId, 'server-user-1');
    expect(session.email, 'sam@example.com');

    expect(await container.read(activeUserIdProvider.future), 'server-user-1');

    final user = await container.read(currentUserProvider.future);
    expect(user.userId, 'server-user-1');
  });

  /// **Task 11.62.** `SyncSchedule.resumed()` — a pure transform that forgot
  /// the last attempt time so a resumed session could sync immediately — had
  /// no caller anywhere: the value it operated on is rebuilt fresh from
  /// `SharedPreferences` on every provider rebuild and never carried across a
  /// sign-out/sign-in boundary, so nothing ever called it. The persisted
  /// value it should have cleared, `SyncStateStore.lastAttemptAt`, **does**
  /// survive that boundary, and nothing cleared it — someone who signed in
  /// again after their token was revoked mid-afternoon would wait out
  /// whatever interval the old session had left, instead of syncing at the
  /// next foreground the way `resumed()`'s own doc comment promised.
  test('completeSignIn forgets a previously-recorded sync attempt, so the '
      'next foreground finds a round due immediately', () async {
    await SyncStateStore().setLastAttemptAt(
      DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    );

    final client = redeemingClient(
      userId: 'server-user-1',
      email: 'sam@example.com',
    );
    final container = makeContainer(client);
    addTearDown(container.dispose);
    await configureServer(container);

    await container
        .read(currentSessionProvider.notifier)
        .completeSignIn(
          'a'.padRight(32, 'a'),
          expectedEmail: 'sam@example.com',
        );

    expect(await SyncStateStore().lastAttemptAt(), isNull);
  });

  test('completeSignIn throws IdentityMismatch and completes none of the '
      'later steps when the server names a different address', () async {
    final client = redeemingClient(
      userId: 'server-user-2',
      email: 'someone-else@example.com',
    );
    final container = makeContainer(client);
    addTearDown(container.dispose);
    await configureServer(container);

    await expectLater(
      container
          .read(currentSessionProvider.notifier)
          .completeSignIn(
            'b'.padRight(32, 'b'),
            expectedEmail: 'sam@example.com',
          ),
      throwsA(isA<IdentityMismatch>()),
    );

    expect(container.read(currentSessionProvider).value, isNull);
    expect(await container.read(activeUserIdProvider.future), isNull);
  });

  test('completeSignIn surfaces RedemptionRejected on a non-200 redeem '
      'response', () async {
    final client = redeemingClient(
      userId: 'server-user-3',
      email: 'sam@example.com',
      statusCode: 400,
    );
    final container = makeContainer(client);
    addTearDown(container.dispose);
    await configureServer(container);

    await expectLater(
      container
          .read(currentSessionProvider.notifier)
          .completeSignIn(
            'c'.padRight(32, 'c'),
            expectedEmail: 'sam@example.com',
          ),
      throwsA(isA<RedemptionRejected>()),
    );

    expect(container.read(currentSessionProvider).value, isNull);
  });

  test(
    'completeSignIn does NOT call a 404 a bad sign-in code (task 11.37)',
    () async {
      // The reproduced walkthrough failure, one layer up from the client. A
      // saved address with a trailing slash answers 404 on every auth route;
      // reporting that as "your code did not work" is what sent somebody to
      // request a second code against the same broken address.
      final container = makeContainer(
        MockClient((_) async => http.Response('not found', 404)),
      );
      addTearDown(container.dispose);
      await configureServer(container);

      await expectLater(
        container
            .read(currentSessionProvider.notifier)
            .completeSignIn(
              'c'.padRight(32, 'c'),
              expectedEmail: 'sam@example.com',
            ),
        throwsA(
          allOf(
            isA<AuthServerError>().having(
              (e) => e.isNotFound,
              'isNotFound',
              isTrue,
            ),
            isNot(isA<RedemptionRejected>()),
          ),
        ),
      );

      expect(container.read(currentSessionProvider).value, isNull);
    },
  );

  group('sign out everywhere (task 11.28)', () {
    /// Signs in, then answers `/auth/sessions/revoke-all` with [status].
    Future<ProviderContainer> signedIn({
      required int status,
      Object? body = const {'status': 'revoked', 'sessions_revoked': 2},
    }) async {
      final client = MockClient((request) async {
        if (request.url.path == '/auth/redeem') {
          return http.Response(
            jsonEncode({
              'session_token': 'session-token',
              'user_id': 'server-user-1',
              'email': 'sam@example.com',
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.url.path == '/auth/sessions/revoke-all') {
          return http.Response(jsonEncode(body), status);
        }
        return http.Response('not found', 404);
      });
      final container = makeContainer(client);
      await configureServer(container);
      await container
          .read(currentSessionProvider.notifier)
          .completeSignIn(
            'a'.padRight(32, 'a'),
            expectedEmail: 'sam@example.com',
          );
      expect(container.read(currentSessionProvider).value, isNotNull);
      return container;
    }

    test('revokes, clears the local session, and reports the count', () async {
      final container = await signedIn(status: 200);
      addTearDown(container.dispose);

      final revoked = await container
          .read(currentSessionProvider.notifier)
          .signOutEverywhere();

      expect(revoked, 2);
      expect(container.read(currentSessionProvider).value, isNull);
    });

    test(
      'a server that does not confirm leaves this device signed in',
      () async {
        // **The property this control lives or dies on.** `signOut` swallows a
        // failure because the local half is what is really being asked for.
        // Here the person believes their credentials are compromised, so
        // clearing this device while the server still honours every other
        // token would be a false statement about the one thing they wanted.
        // Failing loudly also leaves them able to try again.
        final container = await signedIn(status: 500, body: {'error': 'boom'});
        addTearDown(container.dispose);

        await expectLater(
          container.read(currentSessionProvider.notifier).signOutEverywhere(),
          throwsA(isA<AuthServerError>()),
        );
        expect(container.read(currentSessionProvider).value, isNotNull);
      },
    );

    test('signing out everywhere while signed out does nothing', () async {
      final container = makeContainer(
        MockClient((_) async => http.Response('not found', 404)),
      );
      addTearDown(container.dispose);
      await configureServer(container);

      expect(
        await container
            .read(currentSessionProvider.notifier)
            .signOutEverywhere(),
        0,
      );
    });
  });

  /// **Task 11.38 — the order of operations, not the entitlement.**
  ///
  /// Reproduced by hand on macOS on 2026-08-26: the server was reached, the
  /// sign-in code was consumed, and only then did storing the session fail
  /// with keychain error `-34018`. The person was left signed out, holding a
  /// code that would never work again, reading "could not reach the server".
  ///
  /// The entitlement fix that made `-34018` go away on macOS is verified
  /// elsewhere and cannot be verified here — `flutter test` has no platform
  /// channels, which is the whole reason this defect survived a phase (see
  /// `integration_test/session_store_keychain_test.dart`). **What these tests
  /// cover is the platform-independent half**: any storage failure, anywhere,
  /// reproduced the same sequence, and fixing only macOS would have left that
  /// standing.
  group('storage failure during sign-in (task 11.38)', () {
    /// Counts redemptions so a test can assert the code was never sent, not
    /// merely that sign-in failed. Those are different outcomes and only one
    /// of them costs somebody a code.
    ({http.Client client, List<String> redeemed}) countingRedeemClient({
      String userId = 'server-user-1',
      String email = 'sam@example.com',
    }) {
      final redeemed = <String>[];
      final client = MockClient((request) async {
        if (request.url.path == '/auth/redeem') {
          redeemed.add(request.body);
          return http.Response(
            jsonEncode({
              'session_token': 'session-token-$userId',
              'user_id': userId,
              'email': email,
              'expires_at': DateTime.now()
                  .toUtc()
                  .add(const Duration(hours: 1))
                  .toIso8601String(),
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('not found', 404);
      });
      return (client: client, redeemed: redeemed);
    }

    test(
      'an unusable session store aborts sign-in BEFORE the code is spent',
      () async {
        // The acceptance criterion, and the one that cost a working session:
        // "a simulated storage failure does not consume the code".
        final transport = countingRedeemClient();
        final store = FakeSessionStore(null, StorageFailMode.onProbe);
        final container = makeContainer(transport.client, store: store);
        addTearDown(container.dispose);
        await configureServer(container);

        await expectLater(
          container
              .read(currentSessionProvider.notifier)
              .completeSignIn(
                'a'.padRight(32, 'a'),
                expectedEmail: 'sam@example.com',
              ),
          throwsA(isA<SessionStorageUnavailable>()),
        );

        expect(
          transport.redeemed,
          isEmpty,
          reason:
              'The code must still be usable. Redeeming before knowing the '
              'session can be stored is what left somebody signed out with a '
              'spent code and no way to learn why.',
        );
        expect(store.ensureWritableCalls, 1);
        expect(store.writes, isEmpty);
        expect(container.read(currentSessionProvider).value, isNull);
      },
    );

    test('a store that fails only after the check reports that the code is '
        'gone, rather than blaming the server', () async {
      // The probe makes this rare; it does not make it impossible, and a
      // person whose code has been spent is owed that fact. A distinct
      // exception type is how the screen can say it — the generic path says
      // "could not reach the server", which is false in every particular.
      final transport = countingRedeemClient();
      final store = FakeSessionStore(null, StorageFailMode.onWrite);
      final container = makeContainer(transport.client, store: store);
      addTearDown(container.dispose);
      await configureServer(container);

      await expectLater(
        container
            .read(currentSessionProvider.notifier)
            .completeSignIn(
              'a'.padRight(32, 'a'),
              expectedEmail: 'sam@example.com',
            ),
        throwsA(isA<SessionStorageFailedAfterRedemption>()),
      );

      expect(
        transport.redeemed,
        hasLength(1),
        reason: 'The code really was spent here — that is the point.',
      );
      expect(store.writes, isEmpty);
      expect(
        container.read(currentSessionProvider).value,
        isNull,
        reason:
            'No session was stored, so the app must not present itself as '
            'signed in — a restart would contradict it.',
      );
    });

    test('the store is checked before the network, on every sign-in', () async {
      // Guards the ordering itself rather than one failure's outcome. A later
      // refactor that moves `ensureWritable` after `redeem` still passes both
      // tests above only by accident; this one fails.
      final transport = countingRedeemClient();
      final store = FakeSessionStore();
      final container = makeContainer(transport.client, store: store);
      addTearDown(container.dispose);
      await configureServer(container);

      await container
          .read(currentSessionProvider.notifier)
          .completeSignIn(
            'a'.padRight(32, 'a'),
            expectedEmail: 'sam@example.com',
          );

      expect(store.ensureWritableCalls, 1);
      expect(store.writes, hasLength(1));
      expect(container.read(currentSessionProvider).value, isNotNull);
    });

    test(
      'a malformed pasted code is refused without touching the store',
      () async {
        // The keychain is not consulted for input this device can reject on
        // its own — the probe writes, and writing to somebody's keychain on
        // every stray keystroke would be gratuitous.
        final transport = countingRedeemClient();
        final store = FakeSessionStore(null, StorageFailMode.onProbe);
        final container = makeContainer(transport.client, store: store);
        addTearDown(container.dispose);
        await configureServer(container);

        await expectLater(
          container
              .read(currentSessionProvider.notifier)
              .completeSignIn('not-a-code', expectedEmail: 'sam@example.com'),
          throwsA(isA<RedemptionRejected>()),
        );
        expect(store.ensureWritableCalls, 0);
        expect(transport.redeemed, isEmpty);
      },
    );
  });
}

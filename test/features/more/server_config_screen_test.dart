import 'dart:convert';
import 'dart:io' show HandshakeException;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/errors/transport_failure.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/server_config_screen.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

void main() {
  setUp(() {
    installFakeSharedPreferences();
    EditableText.debugDeterministicCursor = true;
  });

  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  Future<void> pumpScreen(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ServerConfigScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows "not configured" by default, not an error state', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
    );
    addTearDown(container.dispose);
    await pumpScreen(tester, container);

    expect(find.textContaining('Not configured'), findsOneWidget);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      '',
    );
  });

  testWidgets('loads an already-configured URL into the field and banner', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
    );
    addTearDown(container.dispose);
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');

    await pumpScreen(tester, container);

    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      'http://192.168.1.42:8080',
    );
    // `find.text`/`textContaining` also match `EditableText`'s content, so the
    // form field itself would double-count a bare URL match — assert on the
    // banner's full sentence instead of the substring both widgets share.
    expect(
      find.text('Server configured: http://192.168.1.42:8080'),
      findsOneWidget,
    );
  });

  testWidgets('an invalid URL is rejected inline and never saved', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
    );
    addTearDown(container.dispose);
    await pumpScreen(tester, container);

    await tester.enterText(find.byType(TextFormField), 'not a url');
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pump();

    // **The message names this fault, not all three** (task 11.104, item 2).
    // "not a url" has no scheme, which is one of the three faults that used to
    // share the single sentence "Enter a full URL starting with http:// or
    // https://" — right for one of them and misdirecting for the other two.
    expect(
      find.textContaining('Put https:// in front of it'),
      findsOneWidget,
    );
    expect(container.read(serverConfigProvider).value!.isConfigured, isFalse);
  });

  testWidgets('saving a valid URL persists it and updates the banner', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
    );
    addTearDown(container.dispose);
    await pumpScreen(tester, container);

    await tester.enterText(
      find.byType(TextFormField),
      'http://192.168.1.42:8080',
    );
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(
      container.read(serverConfigProvider).value!.baseUrl,
      'http://192.168.1.42:8080',
    );
    expect(find.text('Server URL saved'), findsOneWidget);
  });

  testWidgets('saving a blank field clears an existing configuration', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
    );
    addTearDown(container.dispose);
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');
    await pumpScreen(tester, container);

    await tester.enterText(find.byType(TextFormField), '');
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pumpAndSettle();

    expect(container.read(serverConfigProvider).value!.isConfigured, isFalse);
    expect(find.text('Server cleared — working offline'), findsOneWidget);
  });

  /// **Task 11.38 — what the person actually reads.**
  ///
  /// The provider tests in `test/core/providers/auth_provider_test.dart` prove
  /// the right exception is thrown. These prove the screen turns each one into
  /// a sentence that is true, because the whole defect was a true failure
  /// described by a false message: "could not reach the server", when the
  /// server had been reached, had answered, and had already spent the code.
  /// A test on the exception type alone would have passed throughout.
  group('storage failure messages (task 11.38)', () {
    http.Client redeemingClient({List<String>? redeemed}) =>
        MockClient((request) async {
          if (request.url.path == '/auth/redeem') {
            redeemed?.add(request.body);
            return http.Response(
              jsonEncode({
                'session_token': 'token',
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
          return http.Response('not found', 404);
        });

    Future<ProviderContainer> configured(
      FakeSessionStore store,
      http.Client client,
    ) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          sessionStoreProvider.overrideWithValue(store),
          serverHttpClientProvider.overrideWith((ref) async => client),
        ],
      );
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://test.local');
      return container;
    }

    /// The sign-in controls sit below the fold of the default 800x600 test
    /// viewport — a tap on them silently misses, which reads as "the button
    /// did nothing" rather than as a failed assertion. Give the screen room.
    Future<void> pumpTallScreen(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpScreen(tester, container);
    }

    Future<void> attemptSignIn(WidgetTester tester) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'sam@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Sign-in code'),
        'a' * 32,
      );
      await tester.pump();
      await tester.tap(find.text('SIGN IN THIS DEVICE'));
      // `pumpAndSettle` alone is not enough here. It stops as soon as no frame
      // is scheduled, and the interesting failure happens *after* a network
      // round trip and a database write — neither of which schedules frames —
      // so it returns before the message exists. Pump on a timer until the
      // SnackBar appears instead of guessing a duration.
      // `pumpAndSettle` alone is not enough. It advances a *fake* clock and
      // stops as soon as no frame is scheduled, while the interesting failure
      // happens after a real database write that schedules no frames and
      // needs real time to complete. `runAsync` is the only thing that lets
      // that work finish; pumping harder does not, and a test that pumps
      // harder instead just fails slower.
      for (var i = 0; i < 40 && find.byType(SnackBar).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a keychain that refuses says the code is still good', (
      tester,
    ) async {
      final redeemed = <String>[];
      final container = await configured(
        FakeSessionStore(null, StorageFailMode.onProbe),
        redeemingClient(redeemed: redeemed),
      );
      addTearDown(container.dispose);
      await pumpTallScreen(tester, container);

      await attemptSignIn(tester);

      expect(
        find.textContaining('Your code has not been used'),
        findsOneWidget,
        reason:
            'The code really is untouched — the store is checked before it is '
            'redeemed — and that is the one thing worth telling somebody, '
            'because otherwise they request a new one and hit this again.',
      );
      expect(
        find.textContaining('Could not reach the server'),
        findsNothing,
        reason: 'The exact false statement task 11.38 was reported for.',
      );
      expect(redeemed, isEmpty);
    });

    testWidgets('a keychain that fails after redeeming says the code is gone', (
      tester,
    ) async {
      final redeemed = <String>[];
      final container = await configured(
        FakeSessionStore(null, StorageFailMode.onWrite),
        redeemingClient(redeemed: redeemed),
      );
      addTearDown(container.dispose);
      await pumpTallScreen(tester, container);

      await attemptSignIn(tester);

      expect(find.textContaining('the code is now used up'), findsOneWidget);
      expect(
        find.textContaining('not with the server or the code'),
        findsOneWidget,
        reason:
            'Somebody who thinks the code was bad will spend the next one the '
            'same way. Naming this device as the problem is what stops that.',
      );
      expect(redeemed, hasLength(1), reason: 'It really was spent.');
    });

    testWidgets('a keychain that cannot be read explains itself at launch', (
      tester,
    ) async {
      // The same `-34018` on the read side, which is what an unsigned macOS
      // build hits before anybody touches a control. Previously this rendered
      // a raw PlatformException with an OSStatus in it.
      final container = await configured(
        FakeSessionStore(null, StorageFailMode.onRead),
        redeemingClient(),
      );
      addTearDown(container.dispose);
      await pumpTallScreen(tester, container);

      expect(
        find.textContaining('cannot read stored sign-ins securely'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Everything else in the app works normally'),
        findsOneWidget,
        reason:
            'Signed out is a fully supported state. A person whose keychain '
            'is broken has lost sync, not the app.',
      );
    });
  });

  /// **Task 11.108 — an untrusted certificate stops reading as "this device
  /// could not tell why."**
  ///
  /// `HandshakeException` is neither `SocketException` nor
  /// `http.ClientException`, so before this task it fell to the same
  /// catch-all task 11.104 was written to narrow one exception earlier on
  /// this exact screen. These prove the handshake path cannot silently
  /// rejoin that catch-all, and that `AuthProtocolException` — found
  /// reaching the same catch-all while enumerating it — gets its own
  /// message too.
  group('handshake and protocol failures (task 11.108)', () {
    Future<ProviderContainer> configuredWith(http.Client client) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          sessionStoreProvider.overrideWithValue(FakeSessionStore()),
          serverHttpClientProvider.overrideWith((ref) async => client),
        ],
      );
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('https://test.local');
      return container;
    }

    Future<void> pumpTallScreen(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await pumpScreen(tester, container);
    }

    Future<void> attemptSignIn(WidgetTester tester) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'sam@example.com',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Sign-in code'),
        'a' * 32,
      );
      await tester.pump();
      await tester.tap(find.text('SIGN IN THIS DEVICE'));
      for (var i = 0; i < 40 && find.byType(SnackBar).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a self-signed certificate names the real cause', (
      tester,
    ) async {
      final client = MockClient((request) async {
        throw const HandshakeException(
          'Handshake error in client (OS Error: '
          'CERTIFICATE_VERIFY_FAILED: self signed certificate)',
        );
      });
      final container = await configuredWith(client);
      addTearDown(container.dispose);
      await pumpTallScreen(tester, container);

      await attemptSignIn(tester);

      expect(
        find.textContaining('does not trust its security certificate'),
        findsOneWidget,
      );
      expect(find.textContaining('self-signed'), findsOneWidget);
      expect(
        find.textContaining('could not tell why'),
        findsNothing,
        reason:
            'The exact wrong-cause defect this task exists to fix: a '
            'certificate problem is not "this device could not tell why."',
      );
      expect(find.textContaining('Could not reach the server'), findsNothing);
    });

    testWidgets('an expired certificate names expiry, not a guess', (
      tester,
    ) async {
      final client = MockClient((request) async {
        throw const HandshakeException(
          'Handshake error in client (OS Error: '
          'CERTIFICATE_VERIFY_FAILED: certificate has expired)',
        );
      });
      final container = await configuredWith(client);
      addTearDown(container.dispose);
      await pumpTallScreen(tester, container);

      await attemptSignIn(tester);

      expect(find.textContaining('certificate has expired'), findsOneWidget);
    });

    testWidgets(
      'an unrecognized handshake failure says plainly it cannot tell',
      (tester) async {
        final client = MockClient((request) async {
          throw const HandshakeException('Handshake error in client');
        });
        final container = await configuredWith(client);
        addTearDown(container.dispose);
        await pumpTallScreen(tester, container);

        await attemptSignIn(tester);

        expect(
          find.textContaining('does not trust its security certificate'),
          findsOneWidget,
        );
        expect(
          find.textContaining('could not tell exactly why'),
          findsOneWidget,
          reason:
              'No known substring matched — this must say honestly that it '
              "cannot tell, not guess at self-signed vs. expired vs. "
              'hostname.',
        );
      },
    );

    testWidgets('a proxy answering in HTML gets its own message', (
      tester,
    ) async {
      final client = MockClient((request) async {
        return http.Response('<html>502 Bad Gateway</html>', 200);
      });
      final container = await configuredWith(client);
      addTearDown(container.dispose);
      await pumpTallScreen(tester, container);

      await attemptSignIn(tester);

      expect(
        find.textContaining('did not answer the way this app expects'),
        findsOneWidget,
      );
      expect(
        find.textContaining('could not tell why'),
        findsNothing,
        reason:
            'Found reaching the same catch-all as HandshakeException while '
            'enumerating it for task 11.108 — it gets its own message too.',
      );
    });
  });

  /// **The free-text tripwire task 11.112's acceptance criteria asks for.**
  ///
  /// `handshakeFailureMessage`'s matching is best-effort against a
  /// BoringSSL/OpenSSL message this project does not control (see its own
  /// doc comment) — a Dart or OS update can silently change that text, the
  /// branch stops matching, and the app quietly goes back to reporting the
  /// wrong cause with every other test still green, because those tests only
  /// ever exercised today's wording.
  ///
  /// This pins the substring **lists themselves**, not just their current
  /// behavior on today's sample strings: editing any entry in
  /// [handshakeExpiredSubstrings], [handshakeSelfSignedSubstrings], or
  /// [handshakeHostnameMismatchSubstrings] fails this test, which forces it
  /// to be a deliberate, reviewed choice rather than a silent side effect of
  /// some unrelated change.
  group('the free-text substrings 11.108 matches on, pinned (task 11.112)', () {
    test('the "expired" substrings have not changed', () {
      expect(handshakeExpiredSubstrings, ['expired']);
    });

    test('the "self-signed" substrings have not changed', () {
      expect(handshakeSelfSignedSubstrings, [
        'self signed',
        'self-signed',
        'unable to get local issuer certificate',
        'unable to get issuer certificate',
      ]);
    });

    test('the "hostname mismatch" substrings have not changed', () {
      expect(handshakeHostnameMismatchSubstrings, [
        'hostname',
        'does not match',
      ]);
    });
  });

  /// **Task 11.112 — the same wrong-cause defect, live on the two platforms
  /// Michael actually tests on.**
  ///
  /// iOS and macOS never throw `HandshakeException` — `CupertinoClient`
  /// (`NSURLSession`) throws `NSErrorClientException` instead, which is a
  /// plain `http.ClientException` unless caught specifically. Before this
  /// task these fell to the same "could not reach the server" branch task
  /// 11.108 fixed everywhere else.
  ///
  /// **These test the code-only half of the classification
  /// (`certificateMessageForNsError`), not the real `NSErrorClientException`
  /// catch clause.** Constructing an actual `NSError` requires linking
  /// Apple's Foundation framework, which this repo's CI
  /// (`.github/workflows/offline-suite.yml`, `runs-on: ubuntu-latest`)
  /// cannot do — so unlike the `HandshakeException` group above, a plain
  /// `flutter test` here cannot drive a `MockClient` that throws a real
  /// `NSErrorClientException` on every platform. The macOS-only file
  /// `server_config_screen_macos_test.dart` exercises the full catch clause
  /// and was run by hand on this machine (task 11.112, 2026-09-01); it
  /// cannot run on the Linux CI runner, and **iOS was not tested at all —
  /// that needs Michael and a phone.**
  group('Apple certificate failures, code-only (task 11.112)', () {
    test('a bad-date code names the real cause, not a guess', () {
      final expired = certificateMessageForNsError(
        domain: 'NSURLErrorDomain',
        code: nsUrlErrorServerCertificateHasBadDate,
      )?.explanation;
      expect(expired, contains('does not trust its security certificate'));
      expect(expired, contains('dates are wrong'));
      expect(expired, isNot(contains('could not tell')));

      final notYetValid = certificateMessageForNsError(
        domain: 'NSURLErrorDomain',
        code: nsUrlErrorServerCertificateNotYetValid,
      )?.explanation;
      expect(notYetValid, contains('dates are wrong'));
    });

    test('an untrusted or unknown-root code names self-signed', () {
      final untrusted = certificateMessageForNsError(
        domain: 'NSURLErrorDomain',
        code: nsUrlErrorServerCertificateUntrusted,
      )?.explanation;
      expect(untrusted, contains('self-signed'));
      expect(untrusted, isNot(contains('dates are wrong')));

      final unknownRoot = certificateMessageForNsError(
        domain: 'NSURLErrorDomain',
        code: nsUrlErrorServerCertificateHasUnknownRoot,
      )?.explanation;
      expect(unknownRoot, contains('self-signed'));
    });

    test(
      'a generic secure-connection failure says honestly it cannot tell',
      () {
        final message = certificateMessageForNsError(
          domain: 'NSURLErrorDomain',
          code: nsUrlErrorSecureConnectionFailed,
        )?.explanation;
        expect(message, contains('could not tell exactly why'));
      },
    );

    test('a non-certificate code is not reported as a certificate problem', () {
      // -1004: NSURLErrorCannotConnectToHost. This device never even
      // negotiated TLS, so this must fall back to "could not reach the
      // server" — not the certificate message.
      expect(
        certificateMessageForNsError(domain: 'NSURLErrorDomain', code: -1004),
        isNull,
      );
    });

    test('a code from a different error domain is never a certificate problem', () {
      expect(
        certificateMessageForNsError(
          domain: 'NSPOSIXErrorDomain',
          code: nsUrlErrorServerCertificateUntrusted,
        ),
        isNull,
      );
    });

    test(
      'the NSURLErrorDomain code numbers this task relies on, pinned',
      () {
        // Task 11.112's own note: DEVELOPMENT_PLAN.md's find-by-11.108 entry
        // numbered three of these wrong. If any of these six literals ever
        // change, every message above changes silently with them — pinned
        // here the same way the free-text lists below are.
        expect(nsUrlErrorSecureConnectionFailed, -1200);
        expect(nsUrlErrorServerCertificateHasBadDate, -1201);
        expect(nsUrlErrorServerCertificateUntrusted, -1202);
        expect(nsUrlErrorServerCertificateHasUnknownRoot, -1203);
        expect(nsUrlErrorServerCertificateNotYetValid, -1204);
      },
    );
  });

  /// **Task 11.36 — the device list, and what a person reads on it.**
  ///
  /// The e2e suite proves the route and the revocation work against a real
  /// server (`test/e2e/auth_routes_e2e_test.dart`). These prove the screen
  /// says the right things about them — which is a different question, and the
  /// one this project keeps getting wrong: a control that works while its copy
  /// describes a mechanism the code does not have is the same defect as a
  /// message naming the wrong cause.
  group('the device list (task 11.36)', () {
    final signedInAt = DateTime.utc(2026, 8, 3, 7, 22);
    final phoneLastSeen = DateTime.utc(2026, 8, 12, 9, 14);
    final laptopLastSeen = DateTime.utc(2026, 8, 14, 16, 30);

    const thisDeviceId = 'laptop-device-id';
    const otherDeviceId = 'phone-device-id';

    Map<String, Object?> sessionJson(
      String deviceId,
      DateTime lastSeen, {
      required bool isCurrent,
    }) => {
      'device_id': deviceId,
      'first_signed_in_at': signedInAt.toIso8601String(),
      'last_seen_at': lastSeen.toIso8601String(),
      'expires_at': DateTime.utc(2026, 9, 1).toIso8601String(),
      'is_current_device': isCurrent,
    };

    /// A server that lists two devices and records every revocation asked of
    /// it. [listStatus] lets a test make the list fail without touching
    /// anything else.
    http.Client sessionsClient({
      List<String>? revoked,
      int listStatus = 200,
      int revokeStatus = 200,
    }) => MockClient((request) async {
      if (request.url.path == '/auth/sessions' && request.method == 'GET') {
        if (listStatus != 200) return http.Response('nope', listStatus);
        return http.Response(
          jsonEncode({
            'sessions': [
              // Deliberately oldest-first on the wire, so "most recently used
              // first" on screen is this app's doing rather than the server's.
              sessionJson(otherDeviceId, phoneLastSeen, isCurrent: false),
              sessionJson(thisDeviceId, laptopLastSeen, isCurrent: true),
            ],
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/auth/sessions/revoke-device') {
        revoked?.add(request.body);
        if (revokeStatus != 200) return http.Response('nope', revokeStatus);
        return http.Response(
          jsonEncode({'status': 'revoked', 'sessions_revoked': 1}),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.Response('not found', 404);
    });

    Future<ProviderContainer> signedIn(http.Client client) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          sessionStoreProvider.overrideWithValue(
            FakeSessionStore(
              StoredSession(
                token: 'session-token',
                userId: 'user-1',
                email: 'sam@example.com',
                expiresAt: DateTime.now().toUtc().add(const Duration(days: 7)),
              ),
            ),
          ),
          serverHttpClientProvider.overrideWith((ref) async => client),
          deviceIdProvider.overrideWith((ref) async => thisDeviceId),
        ],
      );
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://test.local');
      return container;
    }

    Future<void> pumpTall(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ServerConfigScreen()),
        ),
      );
      // The list is fetched off a future that schedules no frames; pump on a
      // real clock until it lands rather than guessing a duration.
      for (var i = 0;
          i < 40 && find.textContaining('Last used').evaluate().isEmpty;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    Future<void> settleAfterTap(WidgetTester tester) async {
      for (var i = 0; i < 40 && find.byType(SnackBar).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('leads each row with when the device was last used', (
      tester,
    ) async {
      final container = await signedIn(sessionsClient());
      addTearDown(container.dispose);
      await pumpTall(tester, container);

      // Rendered in local time, so the expectation is built the same way
      // rather than hard-coded — a test that hard-codes UTC passes only in
      // one timezone, which is worse than not having it.
      String when(DateTime utc) => utc.toLocal().toString().substring(0, 16);

      expect(find.text('Last used ${when(laptopLastSeen)}'), findsOneWidget);
      expect(find.text('Last used ${when(phoneLastSeen)}'), findsOneWidget);
      expect(find.text('Signed in ${when(signedInAt)}'), findsNWidgets(2));
      // No label anywhere — the decision task 11.36 made, asserted so that
      // adding one is a deliberate change to this test rather than a drift.
      expect(find.text(thisDeviceId), findsOneWidget);
      expect(find.text(otherDeviceId), findsOneWidget);
    });

    testWidgets('most recently used first, whatever order the server sent', (
      tester,
    ) async {
      final container = await signedIn(sessionsClient());
      addTearDown(container.dispose);
      await pumpTall(tester, container);

      final rows = tester
          .widgetList<Text>(find.textContaining('Last used '))
          .map((t) => t.data!)
          .toList();
      String when(DateTime utc) => utc.toLocal().toString().substring(0, 16);
      expect(
        rows,
        ['Last used ${when(laptopLastSeen)}', 'Last used ${when(phoneLastSeen)}'],
        reason:
            'the server sent them oldest first; the promise on screen is most '
            'recent first, and it is this app that has to keep it',
      );
    });

    testWidgets('says these are your own devices, not the project team', (
      tester,
    ) async {
      // **Asked for after the screen was first run on real hardware
      // (2026-08-29).** Signed in on two devices under two different
      // addresses, each listed only itself — which is correct, and left a
      // reasonable person wondering whether a teammate's devices belonged
      // here. The list is per person and never per project; the screen now
      // says so instead of leaving it to be worked out.
      final container = await signedIn(sessionsClient());
      addTearDown(container.dispose);
      await pumpTall(tester, container);

      expect(find.textContaining('Only your own devices'), findsOneWidget);
      expect(
        find.textContaining("A teammate's devices never appear here"),
        findsOneWidget,
      );
      // It must not send anybody to the Members screen: that is owner-only,
      // and this screen has no way to know whether the reader owns anything.
      expect(
        find.textContaining('Members'),
        findsNothing,
        reason:
            'pointing a contributor at a screen they cannot open is the same '
            'defect as copy describing a mechanism the code does not have',
      );
    });

    testWidgets('marks the device you are holding, and only that one', (
      tester,
    ) async {
      final container = await signedIn(sessionsClient());
      addTearDown(container.dispose);
      await pumpTall(tester, container);

      expect(
        find.text('This device'),
        findsOneWidget,
        reason:
            'the whole point is that nobody signs themselves out while trying '
            'to sign out something else',
      );
    });

    testWidgets('signing out another device warns that it keeps its data', (
      tester,
    ) async {
      final revoked = <String>[];
      final container = await signedIn(sessionsClient(revoked: revoked));
      addTearDown(container.dispose);
      await pumpTall(tester, container);

      // The phone's row is the second one.
      await tester.tap(
        find.byKey(const ValueKey('revoke-device-$otherDeviceId')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Sign out that device?'), findsOneWidget);
      expect(
        find.textContaining('This device is not affected'),
        findsOneWidget,
      );
      expect(
        // Scoped to the dialog: the same sentence is on the screen behind it,
        // in the "sign out everywhere" section, and an unscoped finder that
        // matched only that one would pass with no dialog copy at all.
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining(
            'keeps the project data already downloaded',
          ),
        ),
        findsOneWidget,
        reason:
            'revoking a session stops a device syncing; it does not reach '
            'into it and delete a season of coordinates, and somebody whose '
            'phone is gone will believe it does unless told',
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await settleAfterTap(tester);

      expect(revoked, hasLength(1));
      expect(jsonDecode(revoked.single)['device_id'], otherDeviceId);
      expect(
        find.textContaining('stops syncing on its next attempt'),
        findsOneWidget,
      );
    });

    testWidgets(
      'signing out this device signs you out here and says so, rather than '
      'looking like a failure',
      (tester) async {
        final revoked = <String>[];
        final container = await signedIn(sessionsClient(revoked: revoked));
        addTearDown(container.dispose);
        await pumpTall(tester, container);

        await tester.tap(
          find.byKey(const ValueKey('revoke-device-$thisDeviceId')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sign out this device?'), findsOneWidget);
        expect(
          find.textContaining('you will be signed out here'),
          findsOneWidget,
          reason:
              'the screen behind this dialog is about to flip to "Sign in to '
              'sync", and without being told, the natural reading of that is '
              'that something went wrong',
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
        await settleAfterTap(tester);

        expect(jsonDecode(revoked.single)['device_id'], thisDeviceId);
        expect(
          find.textContaining('Signed out on this device'),
          findsOneWidget,
        );
        expect(
          container.read(currentSessionProvider).value,
          isNull,
          reason:
              'the server has destroyed this session, so a device still '
              'holding the token would believe it was signed in until its '
              'next request failed',
        );
      },
    );

    testWidgets('a list that could not be read never reads as "no devices"', (
      tester,
    ) async {
      final container = await signedIn(sessionsClient(listStatus: 404));
      addTearDown(container.dispose);
      await tester.binding.setSurfaceSize(const Size(800, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ServerConfigScreen()),
        ),
      );
      for (var i = 0;
          i < 40 &&
              find.textContaining('Could not read your signed-in devices')
                  .evaluate()
                  .isEmpty;
          i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Could not read your signed-in devices'),
        findsOneWidget,
      );
      expect(
        find.text('No signed-in devices to show.'),
        findsNothing,
        reason:
            'an unknown list must not read as an empty one — that is a check '
            'that cannot tell success from its own failure, rendered as copy',
      );
      // And it names the address rather than the network, task 11.37's rule.
      expect(
        find.textContaining('it has no sign-in service at that address'),
        findsOneWidget,
      );
    });

    testWidgets('a revocation the server refused says the device still syncs', (
      tester,
    ) async {
      final container = await signedIn(sessionsClient(revokeStatus: 500));
      addTearDown(container.dispose);
      await pumpTall(tester, container);

      await tester.tap(
        find.byKey(const ValueKey('revoke-device-$otherDeviceId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Sign out'));
      await settleAfterTap(tester);

      expect(
        find.textContaining('It is still able to sync'),
        findsOneWidget,
        reason:
            'somebody using this believes a device is where it should not be; '
            'a failure they read as success is the worst outcome it has',
      );
    });
  });
}

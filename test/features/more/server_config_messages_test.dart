import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/data/auth/auth_client.dart';
import 'package:tritrack/features/more/screens/server_config_screen.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.37, item 1 — what the person actually reads.**
///
/// `test/data/auth/auth_server_error_test.dart` proves the right exception is
/// thrown. This proves the screen turns it into a different sentence than the
/// one it shows for a network failure, which is the whole point: the defect
/// was not a missing exception type, it was one message covering two causes.
/// Somebody who is told "could not reach the server" goes and checks their
/// Wi-Fi, and on 2026-08-26 the Wi-Fi was fine and the address had a trailing
/// slash.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    EditableText.debugDeterministicCursor = true;
  });
  tearDown(() => EditableText.debugDeterministicCursor = false);

  group('serverAnsweredWithErrorMessage', () {
    test('a 404 leads with the address, because that is the usual cause', () {
      final message = serverAnsweredWithErrorMessage(
        const AuthServerError(statusCode: 404, path: '/auth/magic-link'),
      );
      expect(message, contains('no sign-in service at that address'));
      expect(message, contains('no slash'));
      expect(
        message,
        isNot(contains('Could not reach the server')),
        reason: 'The server was reached. That is the entire finding.',
      );
    });

    test('a 429 says to wait, and says it is about this device', () {
      final message = serverAnsweredWithErrorMessage(
        const AuthServerError(statusCode: 429, path: '/auth/magic-link'),
      );
      expect(message, contains('this device'));
      expect(message, contains('fifteen minutes'));
    });

    test('a 500 says plainly it is not your network and not your device', () {
      final message = serverAnsweredWithErrorMessage(
        const AuthServerError(statusCode: 500, path: '/auth/magic-link'),
      );
      expect(message, contains('not your network'));
      expect(message, contains('500'));
    });

    test('an unexpected status still names the number and blames nobody', () {
      final message = serverAnsweredWithErrorMessage(
        const AuthServerError(statusCode: 418, path: '/auth/magic-link'),
      );
      expect(message, contains('418'));
      expect(message, contains('Your network is working'));
    });

    test(
      'a 400 invalid_email is about the email address, not the server '
      'address (task 11.298)',
      () {
        // Until 11.298 this landed in the generic branch, whose "the address
        // ... is what to check" means the server URL — so somebody with an
        // accented address was sent to re-check a URL that was fine.
        final message = serverAnsweredWithErrorMessage(
          const AuthServerError(
            statusCode: 400,
            path: '/auth/magic-link',
            code: 'invalid_email',
          ),
        );
        expect(message, contains('email address'));
        expect(message, contains('accented'));
        expect(message, contains('typo'));
        expect(
          message,
          isNot(contains('Server URL')),
          reason: 'the server address is not what is wrong',
        );
        expect(message, contains('Nothing was changed'));
      },
    );

    test('a 400 with some other code stays in the generic branch', () {
      final message = serverAnsweredWithErrorMessage(
        const AuthServerError(
          statusCode: 400,
          path: '/auth/magic-link',
          code: 'malformed_body',
        ),
      );
      expect(message, contains('400'));
      expect(message, isNot(contains('email address')));
    });

    // One error per branch of `serverAnsweredWithErrorMessage`, so the two
    // property tests below cover every sentence the function can produce.
    const everyBranch = [
      AuthServerError(statusCode: 404, path: '/auth/magic-link'),
      AuthServerError(statusCode: 429, path: '/auth/magic-link'),
      AuthServerError(statusCode: 500, path: '/auth/magic-link'),
      AuthServerError(
        statusCode: 400,
        path: '/auth/magic-link',
        code: 'invalid_email',
      ),
      AuthServerError(statusCode: 418, path: '/auth/magic-link'),
    ];

    test('every branch says nothing was changed', () {
      // A person reading a failure needs to know whether they now have half a
      // sign-in. All five say so, and this asserts that as a property of the
      // function rather than one branch at a time.
      for (final error in everyBranch) {
        expect(
          serverAnsweredWithErrorMessage(error),
          contains('Nothing was changed'),
          reason: '$error',
        );
      }
    });

    test('no branch echoes the server address back', () {
      // The path is carried, the base URL is not — same rule
      // `SyncTransportException` follows. A message is a string that ends up
      // in a screenshot in a bug report.
      for (final error in everyBranch) {
        expect(
          serverAnsweredWithErrorMessage(error),
          isNot(contains('/auth/magic-link')),
          reason: '$error',
        );
      }
    });
  });

  group('on the screen', () {
    Future<ProviderContainer> configured(http.Client client) async {
      final container = ProviderContainer(
        overrides: [
          sessionStoreProvider.overrideWithValue(FakeSessionStore()),
          serverHttpClientProvider.overrideWith((ref) async => client),
        ],
      );
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://test.local');
      return container;
    }

    Future<void> requestACode(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.binding.setSurfaceSize(const Size(800, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ServerConfigScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Email'),
        'sam@example.com',
      );
      await tester.pump();
      await tester.tap(find.text('REQUEST A SIGN-IN CODE'));
      for (var i = 0; i < 40 && find.byType(SnackBar).evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('a 404 does not say the server is unreachable', (tester) async {
      final container = await configured(
        MockClient((_) async => http.Response('not found', 404)),
      );
      addTearDown(container.dispose);

      await requestACode(tester, container);

      expect(
        find.textContaining('no sign-in service at that address'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Could not reach the server'),
        findsNothing,
        reason:
            'The exact false statement this task was reported for. The server '
            'answered; it was the address that was wrong.',
      );
    });

    testWidgets('a connection that never completes DOES say unreachable', (
      tester,
    ) async {
      // The other half. If everything reported "the server answered", the
      // distinction would be just as useless in the opposite direction.
      final container = await configured(
        MockClient((_) async => throw const SocketException('No route to host')),
      );
      addTearDown(container.dispose);

      await requestACode(tester, container);

      expect(find.textContaining('Could not reach the server'), findsOneWidget);
      expect(
        find.textContaining('nothing answered at that address'),
        findsOneWidget,
      );
    });

    testWidgets('a 429 tells the person to wait rather than to retry now', (
      tester,
    ) async {
      final container = await configured(
        MockClient((_) async => http.Response('{"error":"rate_limited"}', 429)),
      );
      addTearDown(container.dispose);

      await requestACode(tester, container);

      expect(find.textContaining('fifteen minutes'), findsOneWidget);
      expect(find.textContaining('Could not reach the server'), findsNothing);
    });

    testWidgets('a 202 still reads as success, limited or not', (tester) async {
      // §4.5: the per-address limit answers with this same 202 and sends
      // nothing. The screen must not develop a way to tell — the message here
      // is identical in both cases, and that is deliberate.
      final container = await configured(
        MockClient((_) async => http.Response('{"request_id":"r1"}', 202)),
      );
      addTearDown(container.dispose);

      await requestACode(tester, container);

      expect(
        find.textContaining('A sign-in code was requested'),
        findsOneWidget,
      );
    });
  });
}

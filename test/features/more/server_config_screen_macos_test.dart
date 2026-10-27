/// **Task 11.112's macOS half, verified on a real machine.**
///
/// Split into its own file because `@TestOn` is a library annotation — it
/// cannot be scoped to one `group()` inside `server_config_screen_test.dart`,
/// which otherwise runs everywhere. Constructing a genuine `NSError`/
/// `NSErrorClientException` requires linking Apple's Foundation framework
/// through `package:objective_c`, which only exists on Darwin — `@TestOn`
/// is what makes that a declared, self-explaining skip on the Linux CI
/// runner (`.github/workflows/offline-suite.yml`, `runs-on: ubuntu-latest`)
/// rather than a silent one: that runner reports this file as not
/// applicable, never as passing.
///
/// **Run by hand on this Mac for task 11.112 (2026-09-01)** — this
/// repository's CI does not run `flutter test` on `mac-os`, so this file has
/// not yet been exercised by any automated run, only manually, on the
/// machine this task was done on. **iOS could not be tested at all: it needs
/// a physical device and Michael, not this session.**
@TestOn('mac-os')
library;

import 'package:cupertino_http/cupertino_http.dart' show NSErrorClientException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:objective_c/objective_c.dart' show NSError, StringToNSString;
import 'package:tritrack/core/errors/transport_failure.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
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

  NSErrorClientException certificateError(int code) {
    final error = NSError.errorWithDomain(
      'NSURLErrorDomain'.toNSString(),
      code: code,
    );
    return NSErrorClientException(error);
  }

  group('Apple certificate failures, full catch clause (task 11.112, macOS)', () {
    testWidgets(
      'an untrusted certificate on macOS names the real cause, not '
      '"could not reach the server"',
      (tester) async {
        final client = MockClient((request) async {
          throw certificateError(nsUrlErrorServerCertificateUntrusted);
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
        expect(find.textContaining('Could not reach the server'), findsNothing);
      },
    );

    testWidgets('an expired certificate on macOS names the dates, not a guess', (
      tester,
    ) async {
      final client = MockClient((request) async {
        throw certificateError(nsUrlErrorServerCertificateHasBadDate);
      });
      final container = await configuredWith(client);
      addTearDown(container.dispose);
      await pumpTallScreen(tester, container);

      await attemptSignIn(tester);

      expect(find.textContaining('dates are wrong'), findsOneWidget);
    });

    testWidgets(
      'a plain connection failure on macOS is still "could not reach the '
      'server", not a false certificate report',
      (tester) async {
        final client = MockClient((request) async {
          // NSURLErrorCannotConnectToHost — never negotiated TLS at all.
          throw certificateError(-1004);
        });
        final container = await configuredWith(client);
        addTearDown(container.dispose);
        await pumpTallScreen(tester, container);

        await attemptSignIn(tester);

        expect(
          find.textContaining('Could not reach the server'),
          findsOneWidget,
        );
        expect(
          find.textContaining('does not trust its security certificate'),
          findsNothing,
          reason:
              'A connection that never reached TLS must not be reported as '
              'a certificate problem.',
        );
      },
    );
  });
}

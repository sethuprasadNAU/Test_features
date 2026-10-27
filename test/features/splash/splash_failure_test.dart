import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/retry_policy.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/features/splash/splash_screen.dart';

/// **Task 11.107 — the splash screen's failure path, which had no test.**
///
/// `SplashScreen` is the first screen anybody ever sees and its only job is to
/// get out of the way. Until this task it awaited `currentUserProvider` with no
/// `try`: a failed identity read left the error unhandled, `context.go` never
/// ran, and the app sat on the brand green forever with nothing said. Combined
/// with Riverpod's 38-second default retry (task 11.105) it looked frozen for
/// most of a minute and then stayed frozen.
///
/// **A screen whose job is to get out of the way needs a test that it does so
/// when the thing it is waiting for fails.**
class _IdentityUnreadable implements Exception {
  const _IdentityUnreadable();
  @override
  String toString() => 'the local user row could not be read';
}

/// Pumps a real [SplashScreen] whose identity read fails, under the app's own
/// retry policy — so the test measures what ships, including the wait.
///
/// [failuresBeforeSuccess] is how many builds of `currentUserProvider` throw
/// before one succeeds; the default never succeeds. On success the screen
/// navigates, so the pumped widget is a real router with a marker at the
/// destination.
Future<ProviderContainer> pumpFailingSplash(
  WidgetTester tester, {
  int failuresBeforeSuccess = 1 << 30,
}) async {
  var attempts = 0;
  final container = ProviderContainer(
    retry: appRetryPolicy,
    overrides: [
      splashDurationProvider.overrideWithValue(Duration.zero),
      currentUserProvider.overrideWith((ref) async {
        if (attempts++ < failuresBeforeSuccess) throw const _IdentityUnreadable();
        return User(
          userId: 'u1',
          firstName: 'Field',
          lastName: 'User',
          email: 'someone@example.org',
          sync: SyncMeta.initial(now: DateTime.utc(2026)),
        );
      }),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => const SplashScreen()),
      GoRoute(
        path: '/map',
        builder: (_, _) => const Scaffold(body: Text(_pastSplash)),
      ),
      GoRoute(
        path: '/identity-setup',
        builder: (_, _) => const Scaffold(body: Text(_pastSplash)),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  ));
  return container;
}

/// Marker for "the splash got out of the way", which is its entire job.
const _pastSplash = 'past the splash';

void main() {
  testWidgets('a failed identity read reaches a message, not a frozen splash',
      (tester) async {
    await pumpFailingSplash(tester);

    // Nothing is said while the retries run — that is what the retry indicator
    // below is for — but the wait is bounded, and by the far side of it the
    // screen has to have said something.
    await tester.pump(kMaxAutomaticRetryDelay + const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(
      find.text(SplashScreen.failureHeadline),
      findsOneWidget,
      reason: 'the splash must say that it could not start, not sit silent',
    );
    expect(
      find.widgetWithText(FilledButton, SplashScreen.failureAction),
      findsOneWidget,
      reason: 'and must offer a way on',
    );
  });

  testWidgets('while a retry is running, the splash says it is still trying',
      (tester) async {
    await pumpFailingSplash(tester);

    // First attempt has failed and a retry is scheduled: the screen must
    // distinguish "still working" from "stopped".
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(find.text(SplashScreen.retryingLabel), findsOneWidget);
    expect(find.text(SplashScreen.failureHeadline), findsNothing);

    // Drain the scheduled retries so the test does not tear down with a
    // pending timer.
    await tester.pump(kMaxAutomaticRetryDelay + const Duration(seconds: 1));
    await tester.pumpAndSettle();
  });

  testWidgets('the failure is bounded by the app retry policy, not 38 seconds',
      (tester) async {
    await pumpFailingSplash(tester);

    await tester.pump(kMaxAutomaticRetryDelay + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(SplashScreen.failureHeadline), findsOneWidget,
        reason:
            'if this is red, the app-wide retry policy is no longer bounded '
            'and every awaited provider on every screen is back to 38 seconds');
  });

  testWidgets('"Try again" is a real way on, not just a button', (tester) async {
    // Fails the first three builds — one attempt plus the two retries the app
    // policy allows — so the screen reaches its failure state, and succeeds on
    // the fourth, which is the one the button asks for.
    await pumpFailingSplash(tester, failuresBeforeSuccess: 3);
    await tester.pump(kMaxAutomaticRetryDelay + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text(SplashScreen.failureHeadline), findsOneWidget);

    await tester.tap(find.text(SplashScreen.failureAction));
    await tester.pumpAndSettle();

    expect(find.text(_pastSplash), findsOneWidget);
    expect(find.text(SplashScreen.failureHeadline), findsNothing);
  });
}

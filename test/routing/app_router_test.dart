import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/routing/app_router.dart';

/// [dismissSnackBarsOnNavigate] on its own — task 11.42's answer to "it
/// should dismiss on the next navigation."
///
/// A minimal two-route `GoRouter`, not the app's full route table: the
/// mechanism is router-agnostic (it listens to `routerDelegate`, which
/// notifies on every navigation this router performs), so exercising it
/// against a throwaway router proves the same property without standing up
/// every screen `appRouterProvider` wires.
void main() {
  GoRouter buildRouter() => GoRouter(
    initialLocation: '/a',
    routes: [
      GoRoute(
        path: '/a',
        builder: (context, state) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Deleted'),
                    duration: const Duration(seconds: 6),
                    // Task 11.42's own fix — every real undo bar in the app
                    // sets this. Included here so this test exercises the
                    // same shape, not a simplified stand-in for it.
                    persist: false,
                    action: SnackBarAction(label: 'UNDO', onPressed: () {}),
                  ),
                );
              },
              child: const Text('delete'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/b',
        builder: (context, state) => const Scaffold(body: Text('screen B')),
      ),
    ],
  );

  testWidgets(
    'a showing undo bar is cleared the moment the app navigates away',
    (tester) async {
      final messengerKey = GlobalKey<ScaffoldMessengerState>();
      final router = buildRouter();
      final unsubscribe = dismissSnackBarsOnNavigate(router, messengerKey);
      addTearDown(unsubscribe);
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: messengerKey,
        ),
      );

      await tester.tap(find.text('delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('UNDO'),
        findsOneWidget,
        reason: 'the bar has to actually be showing for this test to mean '
            'anything',
      );

      router.go('/b');
      // Small stepped pumps, not one big jump — `clearSnackBars()` runs an
      // exit animation rather than removing the bar immediately, and
      // `flutter_test`'s fake clock delivers one frame per `pump()` call.
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.text('screen B'), findsOneWidget);
      expect(
        find.text('UNDO'),
        findsNothing,
        reason: 'an undo bar left over from the previous screen answers '
            '"undo whenever you next notice," not "undo this, right now"',
      );
    },
  );

  testWidgets(
    'without the wiring, the same bar survives navigation — the regression '
    'this task closes',
    (tester) async {
      // No `dismissSnackBarsOnNavigate` call here, deliberately: this is what
      // every undo bar in the app did before this task, because
      // `ScaffoldMessenger` sits above the whole `Router` and a route change
      // means nothing to it on its own.
      final messengerKey = GlobalKey<ScaffoldMessengerState>();
      final router = buildRouter();
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: messengerKey,
        ),
      );

      await tester.tap(find.text('delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('UNDO'), findsOneWidget);

      router.go('/b');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('screen B'), findsOneWidget);
      expect(
        find.text('UNDO'),
        findsOneWidget,
        reason: 'documents the behaviour being fixed, not the fix itself — '
            'if this ever fails, something upstream of this task already '
            'changed how ScaffoldMessenger relates to the Router',
      );
    },
  );

  testWidgets(
    'navigating with nothing showing is a harmless no-op',
    (tester) async {
      final messengerKey = GlobalKey<ScaffoldMessengerState>();
      final router = buildRouter();
      final unsubscribe = dismissSnackBarsOnNavigate(router, messengerKey);
      addTearDown(unsubscribe);
      addTearDown(router.dispose);

      await tester.pumpWidget(
        MaterialApp.router(
          routerConfig: router,
          scaffoldMessengerKey: messengerKey,
        ),
      );

      router.go('/b');
      await tester.pumpAndSettle();

      expect(find.text('screen B'), findsOneWidget);
    },
  );
}

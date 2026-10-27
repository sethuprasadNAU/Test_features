import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/routing/app_router.dart';

import '../data/fixtures.dart';
import '../support/fake_shared_preferences.dart';

/// Task 11.106: on Android, pressing the system back button/gesture from the
/// root Map tab used to do nothing at all — [TabShell] wired no handler, and
/// Flutter never calls `SystemNavigator.pop()` on your behalf. This drives
/// the real [TabShell] through a throwaway two-branch `GoRouter`, the same
/// pattern `tab_shell_layout_test.dart` uses (including its `ProviderContainer`
/// setup, needed because [TabShell] always renders `SyncStatusBanner`/
/// `CloudBackupRetiredNotice`), and simulates the OS back button the same way
/// `identity_gate_test.dart` does (`WidgetsBinding.handlePopRoute`, which is
/// what `PopScope` actually intercepts).
void main() {
  setUp(installFakeSharedPreferences);

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/tab-a',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            TabShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/tab-a', builder: (c, s) => const Text('tab A')),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/tab-b', builder: (c, s) => const Text('tab B')),
            ],
          ),
        ],
      ),
    ],
  );

  Future<ProviderContainer> readyContainer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final db = await container.read(appDatabaseProvider.future);
      await db.raw.insert(
        Tables.users,
        sampleUser(id: 'user-1', email: 'sam@example.com').toColumns(),
      );
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(currentUserProvider.future);
    });
    return container;
  }

  Future<GoRouter> pumpShell(WidgetTester tester, ProviderContainer container) async {
    final router = buildRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  /// Records every `SystemNavigator.pop()` call ([MethodCall.method] ==
  /// `'SystemNavigator.pop'`) sent on the platform channel, so a test can
  /// assert the app did or did not actually try to exit.
  List<MethodCall> interceptSystemNavigatorCalls() {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    return calls;
  }

  testWidgets(
    'back from a tab other than the first returns to the first tab, not the app',
    (tester) async {
      final calls = interceptSystemNavigatorCalls();
      final container = await readyContainer(tester);
      final router = await pumpShell(tester, container);
      router.go('/tab-b');
      await tester.pumpAndSettle();
      expect(find.text('tab B'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text('tab A'), findsOneWidget, reason: 'back should return to the first tab');
      expect(
        calls.where((c) => c.method == 'SystemNavigator.pop'),
        isEmpty,
        reason: 'a single back press from a non-root tab must not exit the app',
      );
    },
  );

  testWidgets(
    'the first back press from the first tab warns instead of exiting',
    (tester) async {
      final calls = interceptSystemNavigatorCalls();
      final container = await readyContainer(tester);
      await pumpShell(tester, container);

      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(find.text('Press back again to exit'), findsOneWidget);
      expect(
        calls.where((c) => c.method == 'SystemNavigator.pop'),
        isEmpty,
        reason: 'the first press must only warn, never exit',
      );
    },
  );

  testWidgets(
    'a second back press within the window exits the app',
    (tester) async {
      final calls = interceptSystemNavigatorCalls();
      final container = await readyContainer(tester);
      await pumpShell(tester, container);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(calls.where((c) => c.method == 'SystemNavigator.pop'), hasLength(1));
    },
  );

  testWidgets(
    'a second back press after the window elapsed warns again instead of exiting',
    (tester) async {
      final calls = interceptSystemNavigatorCalls();
      final container = await readyContainer(tester);
      await pumpShell(tester, container);

      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      await tester.binding.handlePopRoute();
      await tester.pump();

      expect(
        calls.where((c) => c.method == 'SystemNavigator.pop'),
        isEmpty,
        reason: 'a stray back press well after the first should not exit',
      );
      expect(find.text('Press back again to exit'), findsOneWidget);
    },
  );
}

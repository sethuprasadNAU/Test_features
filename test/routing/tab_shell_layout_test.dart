import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/features/more/screens/more_screen.dart';
import 'package:tritrack/routing/app_router.dart';

import '../data/fixtures.dart';
import '../support/fake_shared_preferences.dart';

/// Task 11.63: on a device with a real top inset (a notch or Dynamic
/// Island), [TabShell] was reserving that inset more than once — once inside
/// each of the two shell banners, each wrapped in its own `SafeArea`, and
/// again in whatever the active tab built (an inner `Scaffold`+`SafeArea` on
/// the map, or an `AppBar` on More, both written on the assumption they sit
/// directly under the status bar). Michael saw this as a grey strip under the
/// sync bar on the map and, separately, as an oversized "More" header — one
/// cause, reported twice before it was believed.
///
/// **The banners are gone (task 11.189) and the invariant is not.** The shell
/// still consumes the top inset exactly once, and whatever is on the tab
/// still must not consume it again; the difference is that the thing sitting
/// directly under the inset is now the tab itself. That is a *simpler* shape
/// and therefore an easier one to get wrong the next time somebody adds
/// something to the shell — which is precisely what the banners were.
///
/// This drives the real [TabShell] (public specifically so this file can
/// import it) through a throwaway two-branch `GoRouter` — one branch is the
/// real, cheap `MoreScreen` (the `AppBar` shape), the other a stand-in for
/// `MapScreen`/`CompassScreen`/etc.'s `Scaffold(body: SafeArea(...))` shape.
/// The real `MapScreen` branch needs a much heavier harness (see
/// `map_screen_test.dart`) that would only exercise the same shell code a
/// second time, so it's deliberately not used here.
///
/// **Both fixtures are run against a live sync status and against none**, and
/// the assertion is the same number both ways. Sync reports as a dot on the
/// More tab's icon now; a dot that moved the tab content down would be the
/// same defect this file was written for, arriving through a different door.
void main() {
  setUp(installFakeSharedPreferences);

  const notchHeight = 59.0; // iPhone Dynamic Island, per the task write-up.
  const probeKey = Key('tab-b-content');
  // Disambiguates MoreScreen's AppBar title from the NavigationBar's own
  // "More" destination label, which TabShell always renders regardless of
  // how many branches this throwaway router has.
  final appBarTitleFinder = find.descendant(
    of: find.byType(AppBar),
    matching: find.text('More'),
  );

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/tab-a',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            TabShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(path: '/tab-a', builder: (c, s) => const MoreScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/tab-b',
                builder: (c, s) => const Scaffold(
                  body: SafeArea(child: SizedBox(key: probeKey, height: 10)),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  /// A configured, recently-synced device: the state that puts a badge on the
  /// More tab's icon.
  final reportingStatus = SyncStatus(
    schedule: const SyncSchedule(),
    lastSuccessAt: DateTime.now().toUtc(),
  );

  /// A device with no server, which is task 10.2's invariant: no sync surface
  /// anywhere, not even a calm one.
  const silentStatus = SyncStatus(
    schedule: SyncSchedule(),
    unavailable: SyncUnavailable.notConfigured,
  );

  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    required SyncStatus syncStatus,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        syncControllerProvider.overrideWith(
          () => _FakeSyncController(syncStatus),
        ),
      ],
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

  Future<GoRouter> pumpShell(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(top: notchHeight);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
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

  testWidgets(
    'the More header sits right under the notch, not below a second inset',
    (tester) async {
      final container =
          await readyContainer(tester, syncStatus: reportingStatus);
      await pumpShell(tester, container);

      // Before task 11.63, `MoreScreen`'s `AppBar` added its own ~59px top
      // padding on top of the shell's — on the (wrong) assumption that it sat
      // directly under the status bar — which is what produced "the More
      // header is very large."
      final appBarTop = tester.getTopLeft(find.byType(AppBar)).dy;
      expect(
        appBarTop,
        closeTo(notchHeight, 1),
        reason: 'the shell consumes the notch once and the AppBar starts '
            'immediately after it, rather than after a second inset',
      );
      // And the title is inside that bar rather than pushed below it.
      expect(
        tester.getTopLeft(appBarTitleFinder).dy - appBarTop,
        lessThan(notchHeight),
      );
    },
  );

  testWidgets(
    'and it sits at exactly the same place with no sync status at all',
    (tester) async {
      final container = await readyContainer(tester, syncStatus: silentStatus);
      await pumpShell(tester, container);

      // Task 10.2's invariant, seen from the layout side: a device with no
      // server configured shows no sync surface, and the *absence* must not
      // move anything either. Before task 11.189 the equivalent risk was a
      // hidden banner leaving a stray notch-height gap where it had been.
      expect(
        tester.getTopLeft(find.byType(AppBar)).dy,
        closeTo(notchHeight, 1),
      );
      expect(
        find.byKey(const ValueKey('sync-status-tab-badge')),
        findsNothing,
        reason: 'a device that never configured a server has nothing to '
            'report, and a badge would be reporting something',
      );
    },
  );

  testWidgets(
    'a plain safe-area tab (the map/compass/record/position shape) is not '
    'inset twice',
    (tester) async {
      final container =
          await readyContainer(tester, syncStatus: reportingStatus);
      final router = await pumpShell(tester, container);
      router.go('/tab-b');
      await tester.pumpAndSettle();

      // The tab's own inner `SafeArea` should have nothing left to consume,
      // so the content lands at exactly the notch height — not zero
      // (unconsumed by the shell) and not doubled.
      expect(
        tester.getTopLeft(find.byKey(probeKey)).dy,
        closeTo(notchHeight, 1),
      );
    },
  );

  testWidgets(
    'the same safe-area tab lands in the same place with no sync status',
    (tester) async {
      final container = await readyContainer(tester, syncStatus: silentStatus);
      final router = await pumpShell(tester, container);
      router.go('/tab-b');
      await tester.pumpAndSettle();

      expect(
        tester.getTopLeft(find.byKey(probeKey)).dy,
        closeTo(notchHeight, 1),
      );
    },
  );
}

class _FakeSyncController extends SyncController {
  _FakeSyncController(this._status);

  final SyncStatus _status;

  @override
  Future<SyncStatus> build() async => _status;
}

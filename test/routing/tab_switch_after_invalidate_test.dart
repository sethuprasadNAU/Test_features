import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/routing/app_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../support/fake_shared_preferences.dart';

/// **Task 11.160 — changing tab after a Profile save must not recompute a
/// provider in the middle of a build.**
///
/// Task 11.145 reproduced this on an iPhone 17 Pro Max simulator under
/// `integration_test`, three runs, on the same two transitions each time, and
/// deliberately did not commit the probe. This is that probe made permanent
/// and made cheap: it runs under `flutter test` in well under a second.
///
/// ## Why this one *can* fail in `flutter test` when 11.144's could not
///
/// `shell_provider_chain_test.dart` explains at length that the cascade it
/// guards cannot be reproduced under the automated binding — that one needs a
/// provider to still be dirty at the instant a widget's `build` reads it, and
/// `flutter_test` always flushes the scheduled refresh first. **This defect
/// does not depend on that race at all.** riverpod pauses a hidden branch's
/// subscriptions, so the recomputation is *owed* rather than raced: it is
/// held, deterministically, until the branch is resumed, and the resume is
/// synchronous inside `_TickerModeState.didChangeDependencies`. Nothing about
/// it is timing-dependent, which is why the same failure appears here.
///
/// ## What it drives
///
/// The real [TabShell] and a real `StatefulShellRoute`, five branches, on the
/// two transitions 11.145 named — `/compass` → `/position` and `/more` →
/// `/map` — with the **real** `currentUser` → `myProjectRole` →
/// `mayWriteProjectData` chain underneath. Only the two ends are overridden
/// (the user row, and the membership lookup that would need a database); the
/// two links in the middle, which are what actually cascade, are the app's
/// own.
///
/// The branch widgets watch what the real screens watch — `/map`
/// `currentUserProvider` and `mayWriteProjectDataProvider`, `/position`
/// `mayWriteProjectDataProvider`, `/more` `currentUserProvider`, `/compass`
/// neither — rather than standing up five real screens, which would need a
/// database, a map harness and a GPS fake to exercise the same shell
/// mechanism. That list is a copy of what
/// `test/routing/shell_provider_chain_test.dart` derives from `lib/`; **if it
/// goes stale this test gets weaker rather than wrong**, and the derivation
/// next door is what notices.
void main() {
  setUp(installFakeSharedPreferences);

  const projectId = 'project-1';

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith((ref) async => sampleUser()),
        projectRoleForUserProvider.overrideWith(
          (ref, args) async => ProjectRole.owner,
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  GoRouter buildRouter(void Function(StatefulNavigationShell) captureShell) {
    Widget branch(String label, {bool user = false, bool mayWrite = false}) =>
        _BranchWatcher(
          label: label,
          watchesUser: user,
          watchesMayWrite: mayWrite,
          projectId: projectId,
        );

    return GoRouter(
      initialLocation: '/map',
      routes: [
        StatefulShellRoute(
          builder: (context, state, navigationShell) {
            captureShell(navigationShell);
            return TabShell(navigationShell: navigationShell);
          },
          navigatorContainerBuilder: keepHiddenBranchesResumed,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/map',
                  builder: (c, s) => branch('map', user: true, mayWrite: true),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/record', builder: (c, s) => branch('record')),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/compass', builder: (c, s) => branch('compass')),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/position',
                  builder: (c, s) => branch('position', mayWrite: true),
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/more',
                  builder: (c, s) => branch('more', user: true),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  /// `/map` 0, `/record` 1, `/compass` 2, `/position` 3, `/more` 4.
  for (final transition in const [(from: 2, to: 3), (from: 4, to: 0)]) {
    testWidgets(
      'saving your name on tab ${transition.from} and changing to tab '
      '${transition.to} does not write above the widget being built',
      (tester) async {
        final container = buildContainer();
        late StatefulNavigationShell shell;
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp.router(
              routerConfig: buildRouter((s) => shell = s),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Both branches have to have been visited: `IndexedStack` only keeps
        // mounted what has been shown once, and a branch that has never been
        // built has nothing paused to resume.
        shell.goBranch(transition.to);
        await tester.pumpAndSettle();
        shell.goBranch(transition.from);
        await tester.pumpAndSettle();

        final raised = <FlutterErrorDetails>[];
        final previousOnError = FlutterError.onError;
        FlutterError.onError = raised.add;

        // What a Profile save, identity setup and sign-in each do. Nothing
        // else — no server, no sync round, no `DataArrival`.
        container.invalidate(currentUserProvider);
        await tester.pump(const Duration(milliseconds: 300));

        // **The invalidation is blameless, and this is the assertion that says
        // so.** It is why the fix is in the shell's branch container and not
        // at `currentUserProvider`'s three invalidation sites: by here the
        // write has already happened and raised nothing.
        final afterInvalidate = raised.map((e) => e.exceptionAsString()).toList();

        shell.goBranch(transition.to);
        await tester.pumpAndSettle();

        final afterTabChange = raised.map((e) => e.exceptionAsString()).toList();
        FlutterError.onError = previousOnError;

        expect(
          afterInvalidate,
          isEmpty,
          reason: 'invalidating currentUserProvider raised something on its '
              'own, which would mean this defect is at the call site after all',
        );
        expect(
          afterTabChange,
          isEmpty,
          reason: 'changing tab resumed a paused branch and flushed a stale '
              'provider chain inside the build phase',
        );
      },
    );
  }

  // The two cases above drive a throwaway five-branch router, so on their own
  // they would still pass if `appRouter` were put back on
  // `StatefulShellRoute.indexedStack` — they would be proving a property of
  // [keepHiddenBranchesResumed] rather than of the app. This asks the app's
  // real route table which container it uses, and needs no screen built to do
  // it.
  test('the app\'s own tab shell uses that container', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final shellRoutes = container
        .read(appRouterProvider)
        .configuration
        .routes
        .whereType<StatefulShellRoute>()
        .toList();

    expect(
      shellRoutes,
      hasLength(1),
      reason: 'the app grew a second tab shell, and it needs the same '
          'container as the first',
    );
    expect(
      shellRoutes.single.navigatorContainerBuilder,
      same(keepHiddenBranchesResumed),
      reason: 'the tab shell is back on go_router\'s own container, which '
          'ticker-mutes hidden branches and so pauses their providers',
    );
  });
}

/// A stand-in for one tab screen: it watches exactly the providers named in
/// its constructor and renders their values, which is all the shell mechanism
/// under test can see of a screen.
class _BranchWatcher extends ConsumerWidget {
  const _BranchWatcher({
    required this.label,
    required this.watchesUser,
    required this.watchesMayWrite,
    required this.projectId,
  });

  final String label;
  final bool watchesUser;
  final bool watchesMayWrite;
  final String projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final parts = <String>[label];
    if (watchesUser) {
      parts.add('${ref.watch(currentUserProvider).value?.userId}');
    }
    if (watchesMayWrite) {
      parts.add('${ref.watch(mayWriteProjectDataProvider(projectId)).value}');
    }
    return Scaffold(body: Center(child: Text(parts.join(' '))));
  }
}

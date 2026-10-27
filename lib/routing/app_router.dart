import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../features/compass/screens/compass_screen.dart';
import '../features/identity/screens/identity_setup_screen.dart';
import '../features/map/screens/map_screen.dart';
import '../features/more/screens/animal_detail_screen.dart';
import '../features/more/screens/animals_screen.dart';
import '../features/more/screens/tags_screen.dart';
import '../features/more/screens/data_export_screen.dart';
import '../features/more/screens/log_screen.dart';
import '../features/more/screens/manage_offline_maps_screen.dart';
import '../features/more/screens/app_info_screen.dart';
import '../features/more/screens/members_screen.dart';
import '../features/more/screens/more_screen.dart';
import '../features/more/screens/observation_sharing_screen.dart';
import '../features/more/screens/offline_data_map_screen.dart';
import '../features/more/screens/pretrip_checklist_screen.dart';
import '../features/more/screens/profile_screen.dart';
import '../features/more/screens/project_setup_screen.dart';
import '../features/more/screens/join_project_screen.dart';
import '../features/more/screens/new_season_screen.dart';
import '../features/more/screens/project_members_screen.dart';
import '../features/more/screens/projects_screen.dart';
import '../features/more/screens/server_config_screen.dart';
import '../features/more/screens/sync_status_screen.dart';
import '../features/more/screens/tag_database_screen.dart';
import '../features/observations/screens/bearing_map_capture_screen.dart';
import '../features/observations/screens/observation_logging_screen.dart';
import '../features/observations/screens/record_position_preview_screen.dart';
import '../features/position_estimation/screens/position_estimation_screen.dart';
import '../features/splash/splash_screen.dart';
import 'tab_visibility.dart';
import '../widgets/sync_status_icon.dart';

part 'app_router.g.dart';

/// The key [TriTrackApp] hands to `MaterialApp.router(scaffoldMessengerKey:)`,
/// so [appRouterProvider] can reach the same [ScaffoldMessenger] to dismiss a
/// showing undo bar on navigation (task 11.42) without needing a
/// [BuildContext] of its own — a provider builder has none.
///
/// **`keepAlive`, and it has to be**: the key must be the *same instance* for
/// the whole run, or `MaterialApp.router` would attach a fresh
/// `ScaffoldMessengerState` to a key nothing else has, and the listener below
/// would dismiss nothing.
@Riverpod(keepAlive: true)
GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey(Ref ref) =>
    GlobalKey<ScaffoldMessengerState>();

/// Bottom tab bar per the hi-fi handoff: Map / Record / Compass / Position /
/// More, each an 8px dot + label. "Record" (originally labeled "Log" in the
/// handoff — renamed 2026-07-17, since it's the bearing/GPS recording form,
/// not a list) is the highest-frequency screen. The sortable list of
/// recorded observations lives under More as "Log" instead. Screens outside
/// this five (Login, Log, Tag DB Management, Sharing, Backup, Pre-Trip
/// Checklist) live under More. Login remains un-designed/unbuilt (Phase One
/// has no login flow — see [[tritrack-phase4]]'s currentUser auto-creation).
@riverpod
GoRouter appRouter(Ref ref) {
  final messengerKey = ref.watch(scaffoldMessengerKeyProvider);
  final router = GoRouter(
    initialLocation: '/splash',
    // Without this, go_router 17.3.0's `_effectiveInitialLocation` prefers a
    // platform-supplied initial route (Android's exported `MainActivity`
    // hands `getInitialRoute()`'s intent extra straight through, ahead of any
    // deep-linking flag) over `initialLocation` above — skipping `/splash`
    // and, with it, `IdentitySetupScreen`'s non-skippable gate. Task 10.77
    // (finding K-3).
    overridePlatformDefaultLocation: true,
    routes: [
      GoRoute(
        path: '/splash',
        builder: (context, state) => const SplashScreen(nextLocation: '/map'),
      ),
      // Non-skippable gate for a device with no real identity yet (fresh
      // install, or one still carrying the auto-created placeholder email) —
      // see Phase 7 of the development plan. Reached only via SplashScreen's
      // redirect, never linked from elsewhere.
      GoRoute(
        path: '/identity-setup',
        builder: (context, state) => const IdentitySetupScreen(),
      ),
      // Full-screen map preview for the record form (pushed over the tab
      // shell so it has its own back arrow). Reads/writes the shared
      // observation draft, so moving the pin flows straight back into the
      // record on return.
      GoRoute(
        path: '/record-preview',
        builder: (context, state) => const RecordPositionPreviewScreen(),
      ),
      // *Take on map* (task 11.315): a range bearing swept over today's other
      // bearings on the same collar. Pushed over the shell for the same
      // reason as Preview, and like Preview it hands its answer back through
      // the shared draft — Confirm fills the form; the person still saves.
      GoRoute(
        path: '/record-bearing-map',
        builder: (context, state) => const BearingMapCaptureScreen(),
      ),
      StatefulShellRoute(
        builder: (context, state, navigationShell) =>
            TabShell(navigationShell: navigationShell),
        navigatorContainerBuilder: keepHiddenBranchesResumed,
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/map',
                builder: (context, state) => const MapScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/record',
                builder: (context, state) => const ObservationLoggingScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/compass',
                builder: (context, state) => const CompassScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/position',
                builder: (context, state) => const PositionEstimationScreen(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/more',
                builder: (context, state) => const MoreScreen(),
                routes: [
                  GoRoute(
                    path: 'profile',
                    builder: (context, state) => const ProfileScreen(),
                  ),
                  GoRoute(
                    path: 'projects',
                    builder: (context, state) => const ProjectsScreen(),
                  ),
                  GoRoute(
                    path: 'projects/join',
                    builder: (context, state) => const JoinProjectScreen(),
                  ),
                  GoRoute(
                    path: 'projects/:projectId/members',
                    builder: (context, state) => ProjectMembersScreen(
                      projectId: state.pathParameters['projectId']!,
                    ),
                  ),
                  // Task 11.56: start next season from this project.
                  GoRoute(
                    path: 'projects/:projectId/new-season',
                    builder: (context, state) => NewSeasonScreen(
                      projectId: state.pathParameters['projectId']!,
                    ),
                  ),
                  GoRoute(
                    path: 'project-setup',
                    builder: (context, state) => const ProjectSetupScreen(),
                  ),
                  GoRoute(
                    path: 'project-setup/new',
                    builder: (context, state) =>
                        const ProjectSetupScreen(projectId: 'new'),
                  ),
                  GoRoute(
                    path: 'project-setup/:projectId',
                    builder: (context, state) => ProjectSetupScreen(
                      projectId: state.pathParameters['projectId'],
                    ),
                  ),
                  // Task 11.244. **A screen of its own, not behind Project
                  // Setup** — Michael, reviewing 11.241: *"seems like the
                  // animal's list should be on that menu as well."* The
                  // animals are the subject of the study; the collars are
                  // equipment (design §1).
                  GoRoute(
                    path: 'animals',
                    builder: (context, state) => const AnimalsScreen(),
                  ),
                  GoRoute(
                    path: 'animals/:individualId',
                    builder: (context, state) => AnimalDetailScreen(
                      individualId: state.pathParameters['individualId']!,
                    ),
                  ),
                  // Task 11.313. **A screen of its own, beside Animals** — an
                  // owner manages members more often than animals, and this
                  // used to be two taps behind Projects. The existing route
                  // above (`projects/:projectId/members`) stays; this is a
                  // second door to the same screen, for the open project.
                  GoRoute(
                    path: 'members',
                    builder: (context, state) => const MembersScreen(),
                  ),
                  // Task 11.245. **Moved off Project Setup**, which keeps
                  // none of the tags UI and goes back to being settings
                  // (design §3, Michael, 2026-09-14) — beside `animals`,
                  // because a tag is equipment and this is where a person on
                  // the More menu thinks to look for the project's own.
                  GoRoute(
                    path: 'tags',
                    builder: (context, state) => const TagsScreen(),
                  ),
                  GoRoute(
                    path: 'checklist',
                    builder: (context, state) => const PreTripChecklistScreen(),
                  ),
                  GoRoute(
                    path: 'offline-maps',
                    builder: (context, state) =>
                        const ManageOfflineMapsScreen(),
                  ),
                  GoRoute(
                    path: 'offline-data-map',
                    builder: (context, state) => const OfflineDataMapScreen(),
                  ),
                  GoRoute(
                    path: 'log',
                    builder: (context, state) => const LogScreen(),
                  ),
                  GoRoute(
                    path: 'tag-database',
                    builder: (context, state) => const TagDatabaseScreen(),
                  ),
                  GoRoute(
                    path: 'observation-sharing',
                    builder: (context, state) =>
                        const ObservationSharingScreen(),
                  ),
                  GoRoute(
                    path: 'data-export',
                    builder: (context, state) => const DataExportScreen(),
                  ),
                  GoRoute(
                    path: 'server',
                    builder: (context, state) => const ServerConfigScreen(),
                  ),
                  GoRoute(
                    path: 'app-info',
                    builder: (context, state) => const AppInfoScreen(),
                  ),
                  GoRoute(
                    path: 'sync-status',
                    builder: (context, state) => const SyncStatusScreen(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );

  ref.onDispose(dismissSnackBarsOnNavigate(router, messengerKey));
  return router;
}

/// Wires [messengerKey]'s undo bar to dismiss on every navigation [router]
/// performs — a push, a pop, a tab switch (task 11.42).
///
/// An undo bar answers "undo *this*, on *this* screen, right now" — not
/// "undo this, whenever you next happen to notice." Flutter's own
/// `ScaffoldMessenger` sits above the whole `Router` (`MaterialApp` wraps its
/// routed content in exactly one, app-wide), so nothing about leaving the
/// screen an action happened on stops its snackbar floating over whatever
/// screen comes next for the rest of its duration. `routerDelegate` notifies
/// on every navigation the router performs, so this clears the bar on all of
/// them uniformly, rather than each destination screen having to remember to
/// do it on the way in.
///
/// A plain function, not inlined in [appRouter], so a test can wire a small
/// throwaway [GoRouter] directly rather than standing up the whole app's
/// route table.
///
/// Returns the cleanup to run when [router] is disposed.
VoidCallback dismissSnackBarsOnNavigate(
  GoRouter router,
  GlobalKey<ScaffoldMessengerState> messengerKey,
) {
  void onNavigate() => messengerKey.currentState?.clearSnackBars();
  router.routerDelegate.addListener(onNavigate);
  return () => router.routerDelegate.removeListener(onNavigate);
}

/// Not underscore-private: [TabShell]'s layout (one top inset for the whole
/// shell, consumed here and not again by the tab under it) is exactly what
/// task 11.63 fixed, and `test/routing/tab_shell_layout_test.dart` builds it
/// directly, against a throwaway `GoRouter`, to keep that fix from silently
/// regressing.
/// **Task 11.160 — the tab shell's branch container, written here instead of
/// taken from `StatefulShellRoute.indexedStack`, so that changing tab cannot
/// recompute a provider in the middle of a build.**
///
/// ## What went wrong
///
/// Editing your name on the Profile screen and then tapping another tab raised
/// *"setState() or markNeedsBuild() called during build"* — every time, with no
/// server and no sync round anywhere near it. A release build does not
/// complain; it performs the write the debug build is objecting to.
///
/// The mechanism has nothing to do with any screen's code, which is why no
/// `package:tritrack` frame appears in the stack:
///
/// 1. `StatefulShellRoute.indexedStack`'s own container wraps each branch in
///    `TickerMode(enabled: isActive)`, so the four tabs you are not looking at
///    are ticker-muted.
/// 2. **riverpod 3 reads that same `TickerMode`** (`ConsumerStatefulElement.
///    _updateTickerMode`) and *pauses* every `ref.watch` subscription in a
///    muted branch. A paused subscription does not recompute; a provider whose
///    listeners are all paused goes stale and stays stale.
/// 3. A Profile save does `ref.invalidate(currentUserProvider)`. Nothing
///    happens at that moment — the four hidden branches are paused. **The
///    recomputation is owed, not cancelled.**
/// 4. Changing tab flips `TickerMode` back on, and riverpod resumes the
///    branch's subscriptions **synchronously from inside
///    `_TickerModeState.didChangeDependencies`, i.e. during the build phase.**
///    Resuming flushes the owed recomputation: `mayWriteProjectData` →
///    `myProjectRole` → `currentUser`, three nested `ProviderElement.flush`
///    levels. `currentUser` rebuilding notifies `myProjectRole`'s own
///    `Ref.watch` listener, which invalidates itself, which asks the
///    surrounding `ProviderScope` for a refresh — and that is a `setState` on
///    a widget at the root of the app while a widget far below it is building.
///
/// ## Why the fix is here and not at the three invalidation sites
///
/// `currentUserProvider` is invalidated in three places — a Profile save,
/// identity setup, and sign-in. **Patching those three would have been a
/// hand-kept list, and it would also not have worked.** The invalidation
/// itself is blameless: it raises nothing, it completes, and the fault is
/// raised by a tab change an arbitrary time later — a third of a second in the
/// reproduction, but it could be an hour. There is nothing a call site can do
/// at the moment it invalidates that changes what happens when a branch is
/// resumed. `tab_switch_after_invalidate_test.dart` asserts exactly that: it
/// checks that the invalidation raised nothing *before* driving the tab
/// change, so the "fix the call sites" answer stays visibly ruled out rather
/// than merely argued against.
///
/// It is also not the shape tasks 11.144 and 11.145 fixed, and
/// `shell_provider_chain_test.dart` cannot see it: that guard derives which
/// screens watch a provider some other provider also watches, and here the
/// screen need not watch anything of the sort — `TickerMode` enters the
/// cascade on its own.
///
/// ## What this changes, and what it costs
///
/// This is `_IndexedStackedRouteBranchContainer` from go_router 17.3.0 with
/// one thing removed: hidden branches keep `TickerMode` **enabled**. They are
/// still `Offstage`, so they are not painted, and `IndexedStack` still keeps
/// every visited branch mounted with its state intact.
///
/// **The cost is real and is stated rather than hidden: a mounted-but-hidden
/// tab keeps its provider subscriptions live and its tickers running.**
///
/// **Task 11.161 measured what that came to and paid the part worth paying.**
/// `test/routing/hidden_tab_liveness_test.dart` derives the set — it runs the
/// app twice and compares what is alive — rather than working from the three
/// examples this comment used to name. Of those three: the compass streams
/// were real and are now paused deliberately (see
/// [TabVisibility] below and the call sites it names); the compass dial was
/// real and stops on its own once no headings are arriving; **the progress
/// spinner was not real** — it was an artifact of measuring under a fake
/// clock, where a screen's loading state never resolves. What nobody had
/// named is that the compass controller listens to GPS for declination, so
/// the Compass tab held the GPS stream too. **GPS is still not paused on a
/// tab change, on purpose**: re-acquiring a fix is a person standing still,
/// and it is already paused where that cost is worth paying — when the whole
/// app is backgrounded.
///
/// **That cost was accepted deliberately, because the alternative does not
/// exist.** `TickerMode`'s notifier can only change during a build — Flutter
/// flips it from `didChangeDependencies`/`didUpdateWidget` — so there is no
/// arrangement in which a branch is resumed outside the build phase. Keeping
/// the muting therefore means keeping the defect. The remaining option,
/// guaranteeing nothing is ever stale while paused, was tried and measured:
/// holding an unpausable listener on `currentUserProvider` **does not fix
/// this**, because the stale providers are the `mayWriteProjectData` /
/// `myProjectRole` family instances further down, and enumerating a family's
/// live instances is precisely the hand-kept list this project keeps being
/// bitten by.
///
/// **The answer to hidden-tab liveness is to pause the expensive streams on
/// purpose** — rather than to get pausing as a side effect of a framework's
/// visibility heuristic, which is what produced this defect in the first
/// place. That is what [TabVisibility] is for, and it is why the pause lives
/// in the screens' `ref.watch` calls rather than in anything that touches
/// `TickerMode`: dropping a watch is an ordinary rebuild, and leaves nothing
/// owed to be settled at a bad moment.
Widget keepHiddenBranchesResumed(
  BuildContext context,
  StatefulNavigationShell navigationShell,
  List<Widget> children,
) => IndexedStack(
  index: navigationShell.currentIndex,
  children: [
    for (var i = 0; i < children.length; i++)
      Offstage(
        offstage: i != navigationShell.currentIndex,
        // Task 11.161: the branch stays mounted and its subscriptions stay
        // live, and this is how a screen finds out it is the one nobody is
        // looking at, so it can put a sensor down deliberately. See
        // [TabVisibility] for why that is not the muting 11.160 removed.
        child: TabVisibility(
          visible: i == navigationShell.currentIndex,
          child: children[i],
        ),
      ),
  ],
);

class TabShell extends StatefulWidget {
  const TabShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  /// The five tabs. `badged` marks the one that carries the sync status dot
  /// (task 11.189) — the More tab, because it is the tab Sync Status is on.
  ///
  /// Declared here rather than by index at the call site so that inserting a
  /// sixth destination cannot silently move the badge onto somebody else's
  /// tab.
  static const _destinations = [
    (icon: Icons.map_outlined, label: 'Map', badged: false),
    (icon: Icons.edit_note, label: 'Record', badged: false),
    (icon: Icons.explore_outlined, label: 'Compass', badged: false),
    (icon: Icons.my_location, label: 'Position', badged: false),
    (icon: Icons.more_horiz, label: 'More', badged: true),
  ];

  @override
  State<TabShell> createState() => _TabShellState();
}

/// Task 11.66/11.106: pressed from the root Map tab, the Android system back
/// gesture/button used to do nothing at all — each tab branch is its own
/// `Navigator`, and once a branch has nothing left of its own to pop, the
/// system back press bubbles up to here and, previously, hit no handler:
/// Flutter doesn't call `SystemNavigator.pop()` on your behalf, so the
/// activity just sat there resumed. That is the single most-used control on
/// Android, and a screen that silently swallows it reads as a freeze.
///
/// The fix follows the same two-step convention most Android apps with a
/// bottom-tab root use: back from any tab *other than* the first
/// (`navigationShell.currentIndex != 0`) returns to that first tab rather
/// than exiting outright — a stray tab tap plus one back press shouldn't
/// dump you out of the app. Only back pressed again from the first tab
/// exits, and even then only after a "press back again to exit" confirmation
/// within [_exitConfirmWindow], so a stray swipe can't exit the app by
/// accident.
///
/// **This never touches an in-progress observation.** The record form
/// (`ObservationDraftState`, `observation_form_provider.dart`) writes its
/// draft to disk on every field change, not just on an explicit save — so
/// nothing here needs to intercept leaving the Record tab specially; the
/// draft that's on disk when back is pressed is exactly the draft that's
/// there when the person returns to it, on this tab-return step or after a
/// full exit.
///
/// Gated on `defaultTargetPlatform == TargetPlatform.android`: iOS has no
/// system-level back gesture or button at this root — its back gesture only
/// ever pops a pushed screen within a tab, which each branch's own
/// `Navigator` already handles unchanged — so this leaves iOS exactly as it
/// was.
class _TabShellState extends State<TabShell> {
  static const _exitConfirmWindow = Duration(seconds: 2);

  // A `Timer`, not a `DateTime` diff — `flutter_test`'s pumped time advances
  // pending timers but not the real wall clock `DateTime.now()` reads, so a
  // diff-based window can't be exercised by a test at all.
  Timer? _exitConfirmationTimer;
  bool _awaitingExitConfirmation = false;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  @override
  void dispose() {
    _exitConfirmationTimer?.cancel();
    super.dispose();
  }

  void _handlePop() {
    if (widget.navigationShell.currentIndex != 0) {
      widget.navigationShell.goBranch(0);
      return;
    }

    if (_awaitingExitConfirmation) {
      SystemNavigator.pop();
      return;
    }

    _awaitingExitConfirmation = true;
    _exitConfirmationTimer?.cancel();
    _exitConfirmationTimer = Timer(
      _exitConfirmWindow,
      () => _awaitingExitConfirmation = false,
    );
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('Press back again to exit'),
          duration: _exitConfirmWindow,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final scaffold = Scaffold(
      // One top inset for the whole shell, consumed here rather than by the
      // tab under it as well (task 11.63). Every surface below this used to
      // carry its own `SafeArea`/`AppBar` top padding on the assumption it
      // sat directly under the status bar — true for exactly one of them at a
      // time, so whichever one wasn't first still reserved status-bar-height
      // space it didn't need, showing up as a blank strip on the map and an
      // oversized header on More.
      // **The whole shell is the screen's** (task 11.189). Two coloured
      // strips used to sit here, above every tab, and task 11.149 measured
      // what they cost the screen under them: 109 logical pixels at the
      // default text size on a 6.1-inch phone and 623 at AX5, where the
      // Record screen's scrolling form was left a viewport of zero. Sync now
      // reports as one icon on the map and a dot on the More tab below, and
      // the cloud-backup retirement notice is an entry on the More screen.
      // `app_shell_space_budget_test.dart` measures what came back.
      body: SafeArea(bottom: false, child: widget.navigationShell),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.navigationShell.currentIndex,
        onDestinationSelected: (index) => widget.navigationShell.goBranch(
          index,
          initialLocation: index == widget.navigationShell.currentIndex,
        ),
        destinations: [
          for (final d in TabShell._destinations)
            NavigationDestination(
              // Task 11.189: the sync status is visible from every screen,
              // not only from the map, which is what Michael asked for when
              // he was asked whether the bar should go app-wide. The badge
              // renders nothing at all when no server is configured — task
              // 10.2's invariant, carried by [SyncStatusBadge].
              icon: d.badged
                  ? SyncStatusBadge(child: Icon(d.icon))
                  : Icon(d.icon),
              label: d.label,
            ),
        ],
      ),
    );

    if (!_isAndroid) return scaffold;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handlePop();
      },
      child: scaffold,
    );
  }
}

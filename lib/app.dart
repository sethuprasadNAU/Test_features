import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers/arrival_refresh.dart';
import 'core/providers/auth_provider.dart';
import 'core/providers/join_request_watcher.dart';
import 'core/providers/project_deletion_provider.dart';
import 'core/providers/sync_provider.dart';
import 'core/theme/app_theme.dart';
import 'data/repositories/repository_providers.dart';
import 'data/sync/restored_project_arrival.dart';
import 'features/map/providers/download_manager.dart';
import 'features/map/providers/offline_regions_provider.dart';
import 'features/more/widgets/finish_setting_up_sheet.dart';
import 'features/more/widgets/project_deletion_dialogs.dart';
import 'routing/app_router.dart';

class TriTrackApp extends ConsumerStatefulWidget {
  const TriTrackApp({super.key});

  @override
  ConsumerState<TriTrackApp> createState() => _TriTrackAppState();
}

class _TriTrackAppState extends ConsumerState<TriTrackApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ProjectRestoration.addListener(_sayProjectsRestored);
    ProjectDeletionAnnouncement.addListener(_sayProjectsDeleted);
    // **Started here because nothing else would start it** (task 11.153).
    // `ArrivalRefresh` is what makes a membership change, a tag link or a
    // project rename that arrived from somebody else's device show up without
    // the app being restarted. It is `keepAlive`, but a `keepAlive` provider
    // nobody reads is never built at all — and the screens it refreshes are
    // exactly the ones that would never think to read it. One read, on launch,
    // before any sync can land. `arrival_refresh_started_test.dart` fails if
    // this line goes.
    ref.read(arrivalRefreshProvider);
    ref.listenManual(joinRequestWatcherProvider, _offerMapsToNewMember);
    unawaited(_syncOnForeground());
  }

  /// **Task 11.324, item 1, a member's half: the offline maps, offered once.**
  ///
  /// The owner is offered publishing and maps right after creating a project
  /// (`project_setup_screen.dart`); a member never creates it, so their moment
  /// is the first time it lands on this device after their request is
  /// accepted — the "You're in. It's on this device" arrival, on whichever
  /// open or poll saw it. Here, at the app's root, because that arrival
  /// happens wherever the person is. Offered once per project on this device
  /// ([MapsOfferedAfterJoining]), and not at all for a project with no area
  /// or whose maps are already here.
  void _offerMapsToNewMember(JoinWatch? previous, JoinWatch next) {
    for (final request in next.requests) {
      final projectId = request.projectId;
      final now = next.arrivals[request.requestId];
      if (projectId == null ||
          now?.arrival != JoinArrival.arrived ||
          !now!.projectPresent) {
        continue;
      }
      final before = previous?.arrivals[request.requestId];
      if (before?.arrival == JoinArrival.arrived && before!.projectPresent) {
        continue;
      }
      unawaited(_offerMapsFor(projectId));
    }
  }

  Future<void> _offerMapsFor(String projectId) async {
    final router = ref.read(appRouterProvider);
    final downloads = ref.read(downloadManagerProvider.notifier);
    final projects = ref.read(projectRepositoryProvider.future);
    final regionsFuture = ref.read(offlineRegionsProvider.future);
    try {
      final project = await (await projects).findById(projectId);
      final maps = project == null ? null : ProjectAreaDownload.of(project);
      if (maps == null) return;
      final regions = await regionsFuture;
      if (maps.isDownloaded(regions)) return;
      if (!await MapsOfferedAfterJoining.claim(projectId)) return;
      final context = router.routerDelegate.navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      final choice = await showFinishSettingUpSheet(
        context,
        publishAs: null,
        maps: maps,
      );
      if (choice.downloadMaps) maps.start(downloads);
    } catch (_) {
      // An offer, not a duty: the Pre-Trip Checklist still lists the maps.
    }
  }

  /// **The only thing that can still deliver a departure nothing else can**
  /// (task 11.57, item 4).
  ///
  /// Somebody who leaves a project out of signal has the departure written and
  /// pending; if they then delete their copy of the project — which task 11.54
  /// deliberately made possible — no screen in the app can reach it again, and
  /// no sync will offer it, because sync operates on the *active* project and a
  /// deleted project is never active. They stay a member on the server, no
  /// invitation can be issued to them, and nothing says so.
  ///
  /// Here, rather than on a screen, for that exact reason: this runs on cold
  /// launch and on every foreground, which is when a phone that was out of
  /// signal gets it back, and it needs no project to be open and no screen to
  /// be visited. It costs one small local query on a device with nothing stuck.
  /// See `SyncController.deliverPendingDepartures`.
  Future<void> _deliverAnyStuckDeparture(SyncController syncController) async {
    try {
      await syncController.deliverPendingDepartures();
    } catch (_) {
      // Never a reason to fail an app launch. Nothing is lost by not
      // succeeding: the rows stay pending and the next foreground asks again.
    }
  }

  /// **The only thing that can deliver a deleted project's tombstone**
  /// (task 11.289) — the same trap as the departure above, met by the
  /// project's own row.
  ///
  /// Deleting the open project sets the active project to null, a deleted
  /// project is hidden from the list and can never be selected again, and
  /// selecting a different project runs *that* project's round. So the
  /// deletion sat pending on the phone with nothing that would ever offer it,
  /// and the project stayed live on the server — for every teammate, and for
  /// every new device the owner signed in on. Michael measured it on
  /// 2026-09-20 with a project named for the purpose. Here for the reason the
  /// departure is: this runs when a phone that deleted a project out of signal
  /// gets it back, needs no project open, and costs a few local reads when
  /// nothing is stranded. See `SyncController.deliverPendingProjectChanges`.
  Future<void> _deliverAnyStrandedProjectChange(
    SyncController syncController,
  ) async {
    try {
      await syncController.deliverPendingProjectChanges();
    } catch (_) {
      // As above: the rows stay pending and the next foreground asks again.
    }
  }

  /// **Brings back a project this device holds as deleted, once its owner
  /// has restored it** (task 11.302) — the inbound half of the stranded
  /// tombstone above, and the same trap: a project hidden by its tombstone is
  /// usually not the open one, so no ordinary round would fetch the restore.
  /// After the two deliveries and before the ordinary round, for the reason
  /// those are sequenced: each runs the engine directly. Costs one local
  /// query on a device holding no deleted project. **It does not speak** —
  /// [_sayProjectsRestored] does, for every route a restore arrives by. See
  /// `SyncController.bringBackRestoredProjects`.
  Future<void> _bringBackRestoredProjects(SyncController syncController) =>
      syncController.bringBackRestoredProjects();

  /// **Tells the person when a project somebody else deleted comes back**
  /// (task 11.302), through the app's one messenger, whichever route brought
  /// it: the foreground check above, *Sync now*, the Projects list's
  /// pull-to-refresh, or the open project's own round. Listening to
  /// `ProjectRestoration` rather than to any one caller is the fix for
  /// Michael's device look of 2026-09-24, where the Mac got the project back
  /// through a route that said nothing.
  ///
  /// The member is who this is for — they lost the project without being
  /// told, and a project reappearing unexplained reads like the fault that
  /// hid it. A restore made by this same account is left unsaid: the person
  /// did it, and the screen they did it on has already told them.
  void _sayProjectsRestored(List<RestoredProjectArrival> arrivals) {
    final messengerKey = ref.read(scaffoldMessengerKeyProvider);
    unawaited(() async {
      String? me;
      try {
        me = (await ref.read(currentSessionProvider.future))?.userId;
      } catch (_) {
        me = null;
      }
      final news = [
        for (final arrival in arrivals)
          if (arrival.restoredBy == null || arrival.restoredBy != me) arrival,
      ];
      if (news.isEmpty) return;
      messengerKey.currentState?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(describeRestoredArrivals(news)),
        ),
      );
    }());
  }

  /// **Tells a member when a project they are on was deleted** (task 11.313,
  /// from task 11.302's Discovered Scope: *"a member's project disappears
  /// without a word when its owner deletes it"*).
  ///
  /// Symmetric to [_sayProjectsRestored] in every way, including which route
  /// carries the news — `ProjectDeletionAnnouncement` fires from the same
  /// merge step for the same three routes. **A deletion made by this same
  /// account is left unsaid**, the same rule the restore follows: the person
  /// did it, and the screen they did it on already told them.
  void _sayProjectsDeleted(List<ProjectDeletionArrival> arrivals) {
    final messengerKey = ref.read(scaffoldMessengerKeyProvider);
    unawaited(() async {
      String? me;
      try {
        me = (await ref.read(currentSessionProvider.future))?.userId;
      } catch (_) {
        me = null;
      }
      final news = [
        for (final arrival in arrivals)
          if (arrival.deletedBy == null || arrival.deletedBy != me) arrival,
      ];
      if (news.isEmpty) return;
      messengerKey.currentState?.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text(describeDeletedArrivals(news)),
        ),
      );
    }());
  }

  /// **The only thing in the app that starts a sync nobody asked for**
  /// (task 11.59).
  ///
  /// Until this existed, `SyncController.syncIfDue` had no caller anywhere:
  /// data left a device only when somebody opened the Sync Status screen,
  /// retried a refused record, or changed a membership. Somebody recording
  /// bearings all day and never opening that one screen had nothing on the
  /// server, while the bar said "N records waiting to sync" — which reads as
  /// *about to* and meant *not until you ask*.
  ///
  /// **Foreground only, and that is the whole mechanism.** There is no
  /// background task and task 10.8 decided against one with reasons; if the
  /// app is closed, nothing syncs at any frequency setting. The sync screen
  /// says exactly that beside the control, because a screen offering
  /// "Every 15 minutes" while the app is shut would be describing a mechanism
  /// this code does not have.
  ///
  /// `syncIfDue` respects the user's frequency, the backoff after a failure,
  /// and the terminal stops; it costs nothing on a device that has synced
  /// recently, is offline, has no server, or has automatic sync switched off.
  ///
  /// **After the departure delivery and the stranded-project delivery, not
  /// alongside them.** All three drive the sync engine against the same
  /// database, and the two deliveries run the engine directly rather than
  /// through the controller's one-round-at-a-time guard, so starting them
  /// together would put two rounds in flight at once.
  ///
  /// **Every provider this chain needs is read here, before the first
  /// `await`.** `ref` is only safe to touch while the widget is mounted, and
  /// this method runs unawaited from a lifecycle callback — by the time the
  /// second or third step would run, the app can already have been
  /// backgrounded or torn down. `SyncController` and `JoinRequestWatcher` are
  /// both `keepAlive`, so the notifiers themselves outlive this widget; only
  /// the *lookup* through `ref` needed to happen before any suspension.
  Future<void> _syncOnForeground() async {
    final syncController = ref.read(syncControllerProvider.notifier);
    final joinRequestWatcher = ref.read(joinRequestWatcherProvider.notifier);
    final deletionNotices = ref.read(projectDeletionNoticesProvider.notifier);
    await _deliverAnyStuckDeparture(syncController);
    await _deliverAnyStrandedProjectChange(syncController);
    await _bringBackRestoredProjects(syncController);
    try {
      await syncController.syncIfDue();
    } catch (_) {
      // A foreground must never fail because a server did. The status surface
      // already carries what went wrong, and the next foreground tries again.
    }
    await _checkJoinRequests(joinRequestWatcher);
    await _refreshDeletionCountdowns(deletionNotices);
  }

  /// **Whether a project this device is watching count down has moved**
  /// (task 11.290) — an owner canceled, or the date changed hands.
  ///
  /// Gated the way the join check is, and for the same reason: a device
  /// holding no deletion notice makes no request and costs one
  /// `SharedPreferences` read. The countdown is *learned* on the Projects
  /// list, which asks the server whenever it is opened or pulled; this keeps
  /// a countdown already on the phone honest between visits. Never throws.
  Future<void> _refreshDeletionCountdowns(
    ProjectDeletionNotices deletionNotices,
  ) async {
    try {
      if (!await deletionNotices.holdsACountdown()) return;
      await deletionNotices.refreshFromServer();
    } catch (_) {
      // Bookkeeping for a list; the list asks again when it is opened.
    }
  }

  /// **Whether the owner has approved this device's request to join** (task
  /// 11.83).
  ///
  /// Here, alongside the sync foreground hook, because the approval usually
  /// lands while the phone is in a pocket — so the moment the app is opened is
  /// the common real case, not the exception. It also starts the 60-second
  /// poll that covers the case where the app is already open when the owner
  /// decides.
  ///
  /// **It is not part of the sync round and could not be.** Automatic sync
  /// runs against the *active, linked* project, and somebody joining their
  /// **first** project has no linked project — so there is no loop to
  /// piggyback on and no request of `/projects/join-requests/mine` anywhere in
  /// it. `JoinRequestWatcher.checkOnForeground` never throws, and on a device
  /// that has never asked to join anything it costs one `SharedPreferences`
  /// read and reaches no server at all — the same shape as the stuck-departure
  /// delivery above.
  Future<void> _checkJoinRequests(JoinRequestWatcher joinRequestWatcher) =>
      joinRequestWatcher.checkOnForeground();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ProjectRestoration.removeListener(_sayProjectsRestored);
    ProjectDeletionAnnouncement.removeListener(_sayProjectsDeleted);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_syncOnForeground());
      return;
    }
    // **The join poll is foreground-only, and this is what makes that true**
    // (task 11.83). A `Timer.periodic` keeps firing in a backgrounded desktop
    // app, and a poll that outlives the person looking at the screen is a
    // battery cost with no purpose. The next resume starts it again if there
    // is still something outstanding.
    ref.read(joinRequestWatcherProvider.notifier).suspend();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    // The same key `appRouterProvider` dismisses a showing undo bar through
    // on every navigation (task 11.42) — passed in here so `ScaffoldMessenger`
    // itself is reachable from a provider builder, which has no `BuildContext`.
    final messengerKey = ref.watch(scaffoldMessengerKeyProvider);
    return MaterialApp.router(
      title: 'TriTrack',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
      scaffoldMessengerKey: messengerKey,
    );
  }
}

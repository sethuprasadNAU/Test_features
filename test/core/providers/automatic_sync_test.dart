import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/app.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/join_request_watcher.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sync/restored_project_arrival.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/routing/app_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.59: does anything sync when nobody asks it to?**
///
/// Until this task the answer was no. `SyncController.syncIfDue` existed,
/// documented itself as the opportunistic foreground attempt, respected the
/// schedule — and had no caller anywhere in `lib/`. A person recording
/// bearings all day and never opening the Sync Status screen had nothing on
/// the server, while the sync bar said "N records waiting to sync".
///
/// Every test below is about a round trip that either happens or does not,
/// measured by whether the device reached the server at all. The server
/// answers 500 throughout: what is being tested is whether the app *asked*,
/// not what came back.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  late List<http.BaseRequest> requests;
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));

  setUp(() async {
    db = await AppDatabase.openInMemory();
    requests = [];
  });
  tearDown(() => db.close());

  /// A container signed in as `user-1`, recording every request it makes.
  ProviderContainer signedInContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) async => db),
      // See `pumpAppShell` below: the app widget is under test, its screens
      // are not. Harmless in the plain container tests, which never build it.
      appRouterProvider.overrideWithValue(
        GoRouter(
          routes: [
            GoRoute(path: '/', builder: (_, _) => const Scaffold()),
          ],
        ),
      ),
      currentUserProvider.overrideWith(
        (ref) async => User(
          userId: 'user-1',
          firstName: 'Sam',
          lastName: 'Ranger',
          email: 'sam@example.com',
          sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1)),
        ),
      ),
      serverHttpClientProvider.overrideWith(
        (ref) async => MockClient((request) async {
          requests.add(request);
          return http.Response('{}', 500);
        }),
      ),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          StoredSession(
            token: 't',
            userId: 'user-1',
            email: 'sam@example.com',
            expiresAt: DateTime.now().add(const Duration(days: 1)),
          ),
        ),
      ),
    ],
  );

  Future<void> seedLinkedProject(ProviderContainer container) async {
    await db.raw.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': 'user-1',
      'origin_device_id': 'device-A',
    });
    await db.raw.insert(Tables.projects, {
      'project_id': 'proj-1',
      'project_name': 'Elk',
      'owner_user_id': 'user-1',
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': 'user-1',
      'origin_device_id': 'device-A',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
    await db.raw.insert(Tables.projectMemberships, {
      'membership_id': 'mem-1',
      'project_id': 'proj-1',
      'user_id': 'user-1',
      'join_date': stamp,
      'end_date': null,
      'role': 'owner',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': 'user-1',
      'origin_device_id': 'device-A',
    });
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');
    await container.read(activeProjectIdProvider.notifier).set('proj-1');
    await container.read(syncStateStoreProvider).markProjectLinked('proj-1');
  }

  group('an attempt nobody asked for', () {
    test(
      'a foreground attempt on a device that has never synced reaches the '
      'server',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedLinkedProject(container);

        // **Deliberately without reading the status first.** This is the
        // shape of the real caller: `app.dart`'s foreground hook fires on
        // cold launch, before anything has watched this provider. Until this
        // task `_run` read `state.value`, found null because the first build
        // had not finished, and silently did nothing — a sync that no-ops
        // because it was asked early is indistinguishable from one that never
        // had a caller at all.
        await container.read(syncControllerProvider.notifier).syncIfDue();

        expect(
          requests,
          isNotEmpty,
          reason: 'nothing reached the server on a foreground',
        );
      },
    );

    test('a second foreground inside the interval does not attempt again',
        () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedLinkedProject(container);

      await container.read(syncControllerProvider.notifier).syncIfDue();
      final afterFirst = requests.length;
      await container.read(syncControllerProvider.notifier).syncIfDue();

      expect(
        requests,
        hasLength(afterFirst),
        reason: 'field use foregrounds constantly between the map and the '
            'record screen; each one must not be a round trip',
      );
    });

    test(
      'and it still does not attempt again after the app is restarted',
      () async {
        // The fifteen-minute floor lived only in the controller's in-memory
        // state, so every cold launch was due — which on a phone that gets
        // relaunched all day made "Hourly" mean "hourly, plus every launch".
        final first = signedInContainer();
        await seedLinkedProject(first);
        await first.read(syncControllerProvider.notifier).syncIfDue();
        expect(requests, isNotEmpty);
        first.dispose();

        final afterRestart = requests.length;
        final second = signedInContainer();
        addTearDown(second.dispose);
        await second.read(syncControllerProvider.notifier).syncIfDue();

        expect(requests, hasLength(afterRestart));
      },
    );
  });

  group('"Only when I ask"', () {
    test('means no foreground attempt, ever', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedLinkedProject(container);
      await container.read(syncControllerProvider.future);
      await container
          .read(syncControllerProvider.notifier)
          .setFrequency(SyncFrequency.onlyWhenIAsk);

      await container.read(syncControllerProvider.notifier).syncIfDue();

      expect(requests, isEmpty);
    });

    test('does not stop the manual button', () async {
      // `syncNow` ignores the schedule entirely — the trailhead case task
      // 10.8 was designed around, and the reason the setting can be offered
      // at all.
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedLinkedProject(container);
      await container.read(syncControllerProvider.future);
      await container
          .read(syncControllerProvider.notifier)
          .setFrequency(SyncFrequency.onlyWhenIAsk);

      await container.read(syncControllerProvider.notifier).syncNow();

      expect(requests, isNotEmpty);
    });

    test('and it is still off after the app is restarted', () async {
      // The switch this replaced lived in memory only: somebody who turned
      // automatic sync off before a metered trip had it back on the next
      // time they opened the app, with the control still showing "off".
      final first = signedInContainer();
      await seedLinkedProject(first);
      await first.read(syncControllerProvider.future);
      await first
          .read(syncControllerProvider.notifier)
          .setFrequency(SyncFrequency.onlyWhenIAsk);
      first.dispose();

      final second = signedInContainer();
      addTearDown(second.dispose);
      final status = await second.read(syncControllerProvider.future);

      expect(status.schedule.frequency, SyncFrequency.onlyWhenIAsk);
      expect(status.schedule.automaticEnabled, isFalse);

      await second.read(syncControllerProvider.notifier).syncIfDue();
      expect(requests, isEmpty);
    });
  });

  /// Boots the real [TriTrackApp] — its lifecycle observer, its `initState`,
  /// its foreground hook — with the router replaced by a blank page.
  ///
  /// **The app widget is the thing under test; the screens are not.** The real
  /// router starts at the splash screen, walks the identity gate and lands on
  /// the map, which does isolate-backed database work on a timer; booting all
  /// of that to find out whether one method was called made the test hang
  /// rather than fail. `appRouterProvider` is a provider, so the tree below
  /// [TriTrackApp] can be one empty `Scaffold` while everything this test is
  /// actually about — `initState`, `didChangeAppLifecycleState`, and what they
  /// call — stays exactly the code that ships.
  /// **Everything a widget test here does must sit inside `tester.runAsync`**,
  /// including the seeding: `sqflite_common_ffi` answers through a background
  /// isolate, and a Future that crosses an isolate never completes under the
  /// fake-async pump clock. A seed written outside `runAsync` does not fail —
  /// it hangs, with no output, which is how this file first behaved.
  Future<void> pumpAppShell(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const TriTrackApp(),
      ),
    );
  }

  /// Real-time waiting, because the foreground sync is unawaited work behind a
  /// `SharedPreferences` read and an HTTP round trip — neither of which the
  /// fake-async pump clock ever advances past. Polls rather than sleeping for
  /// a guessed duration (the L-16 lesson from `map_screen_test.dart`), and
  /// still returns after the budget so the negative cases can assert silence.
  Future<void> settleRealTime(
    WidgetTester tester, {
    bool Function()? until,
    int maxTicks = 240,
  }) async {
    for (var i = 0; i < maxTicks; i++) {
      if (until != null && until()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
      await tester.pump();
    }
  }

  group('the app itself, with nobody touching a screen', () {
    testWidgets(
      'opening TriTrack syncs — no Sync Status screen, no button, no tap',
      (tester) async {
        // **The assertion the whole task is about.** Everything else here
        // tests `syncIfDue`; this tests that something *calls* it. Before task
        // 11.59 nothing in `lib/` did, and every other test in this file would
        // have passed exactly as it does now while a field tech's day of
        // bearings stayed on their phone.
        final container = signedInContainer();
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          await seedLinkedProject(container);
          await pumpAppShell(tester, container);
          await settleRealTime(tester, until: () => requests.isNotEmpty);
        });

        expect(
          requests,
          isNotEmpty,
          reason: 'opening the app synced nothing — syncIfDue has lost its '
              'caller again',
        );
      },
    );

    testWidgets('coming back to it from the background syncs too', (
      tester,
    ) async {
      final container = signedInContainer();
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await seedLinkedProject(container);
        await pumpAppShell(tester, container);
        await settleRealTime(tester, until: () => requests.isNotEmpty);
        expect(requests, isNotEmpty);
        // Let the launch round finish before asking for another: a second
        // round while the first is still in flight is refused by design, and
        // waiting for it is the test's business rather than the app's.
        await settleRealTime(
          tester,
          until: () =>
              container.read(syncControllerProvider).value?.running == false,
        );
        requests.clear();

        // An hour in a pack, then the app comes back to the front. Nothing
        // here touches a screen.
        await container
            .read(syncStateStoreProvider)
            .setLastAttemptAt(DateTime.now().toUtc().subtract(
                  const Duration(hours: 1),
                ));
        container.invalidate(syncControllerProvider);
        final reloaded = await container.read(syncControllerProvider.future);
        expect(reloaded.schedule.shouldAttemptAt(DateTime.now().toUtc()), isTrue);

        // **The whole cycle, not just the last step.** The binding starts a
        // test already `resumed` and ignores a transition to the state it is
        // already in, so sending `resumed` on its own asserts nothing at all.
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
        }
        await settleRealTime(tester, until: () => requests.isNotEmpty);
      });

      expect(requests, isNotEmpty);
    });

    testWidgets(
      'disposed mid-foreground-chain, it must not read ref afterwards '
      '(task 11.86)',
      (tester) async {
        // **Reproduces the exact trace task 11.86 found**: `_syncOnForeground`
        // awaits `syncIfDue`, then reads `ref` again for the join check
        // (`app.dart:104`, called from `app.dart:83`). Both providers are
        // faked here so the whole chain runs on a `Completer` and
        // `tester.pump()` rather than real HTTP/database/isolate work —
        // deterministic, instead of racing a real disposal against real
        // timers. Holding `syncIfDue` open and then disposing the widget
        // recreates the exact window the old code crashed in: `ref` reads
        // after `syncIfDue` returns land on a widget that is already gone.
        final syncGate = Completer<void>();
        final syncController = _HoldingSyncController(syncGate.future);
        final joinWatcher = _RecordingJoinRequestWatcher();

        final container = ProviderContainer(
          overrides: [
            syncControllerProvider.overrideWith(() => syncController),
            joinRequestWatcherProvider.overrideWith(() => joinWatcher),
            appRouterProvider.overrideWithValue(
              GoRouter(
                routes: [
                  GoRoute(path: '/', builder: (_, _) => const Scaffold()),
                ],
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        await pumpAppShell(tester, container);
        await tester.pump();
        expect(
          syncController.deliverCalled,
          isTrue,
          reason: 'the foreground chain never even started',
        );

        // Tear the app widget down while `syncIfDue` is still held open.
        await tester.pumpWidget(const SizedBox.shrink());

        // Let the held-open sync call resolve now that the widget is gone —
        // this is the exact moment the old code's `_checkJoinRequests` read
        // `ref` on a disposed widget and crashed before ever calling through
        // to the join watcher below.
        syncGate.complete();
        await tester.pump();
        await tester.pump();

        expect(
          joinWatcher.checkOnForegroundCalled,
          isTrue,
          reason: 'the join check after a disposed widget never ran — the '
              'foreground chain crashed reading `ref` on a widget that is '
              'already gone',
        );
      },
    );

    testWidgets('and does not, when the setting says only when I ask', (
      tester,
    ) async {
      final container = signedInContainer();
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await seedLinkedProject(container);
        await container.read(syncControllerProvider.future);
        await container
            .read(syncControllerProvider.notifier)
            .setFrequency(SyncFrequency.onlyWhenIAsk);
        await pumpAppShell(tester, container);
        // A fixed wait, not a poll: this one is asserting silence, and the
        // only way to be sure of silence is to wait and look.
        await settleRealTime(tester, maxTicks: 40);
      });

      expect(requests, isEmpty);
    });
  });

  group('the chosen frequency is what is waited out', () {
    test(
      '"Every time I open it" still backs off after a failure, so a dead '
      'server is not hammered',
      () async {
        // The floor this setting gives up is the one between *successful*
        // rounds — `sync_schedule_test.dart` measures that directly. The
        // backoff curve is separate and still applies: a device in a dead
        // zone must not spend its battery rediscovering that on every trip
        // between the map and the record screen.
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedLinkedProject(container);
        await container.read(syncControllerProvider.future);
        await container
            .read(syncControllerProvider.notifier)
            .setFrequency(SyncFrequency.everyForeground);

        await container.read(syncControllerProvider.notifier).syncIfDue();
        expect(requests, isNotEmpty);
        final afterFirst = requests.length;
        await container.read(syncControllerProvider.notifier).syncIfDue();

        expect(requests, hasLength(afterFirst));
      },
    );

    test('a project that was never published is not synced by a foreground',
        () async {
      // Task 10.9's rule, and automatic sync must not be the thing that
      // breaks it: a local project is published deliberately or not at all.
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedLinkedProject(container);
      await container.read(syncStateStoreProvider).clear('proj-1');

      await container.read(syncControllerProvider.notifier).syncIfDue();

      expect(requests, isEmpty);
    });
  });
}

/// Reports departures instantly and lets a test hold `syncIfDue` open behind
/// [gate] — used by the task 11.86 disposal test to control exactly when the
/// foreground chain's second step resolves, without a real HTTP round trip.
class _HoldingSyncController extends SyncController {
  _HoldingSyncController(this.gate);

  final Future<void> gate;
  bool deliverCalled = false;

  @override
  Future<SyncStatus> build() async => const SyncStatus(schedule: SyncSchedule());

  @override
  Future<int> deliverPendingDepartures() async {
    deliverCalled = true;
    return 0;
  }

  @override
  Future<int> deliverPendingProjectChanges() async => 0;

  @override
  Future<List<RestoredProjectArrival>> bringBackRestoredProjects({
    String? onlyProjectId,
  }) async => const [];

  @override
  Future<void> syncIfDue() => gate;
}

/// Records whether the foreground join check ever ran — the task 11.86
/// disposal test's positive signal that the chain reached this call safely
/// rather than crashing on a disposed widget's `ref` first.
class _RecordingJoinRequestWatcher extends JoinRequestWatcher {
  bool checkOnForegroundCalled = false;

  @override
  JoinWatch build() => const JoinWatch();

  @override
  Future<void> checkOnForeground() async {
    checkOnForegroundCalled = true;
  }
}

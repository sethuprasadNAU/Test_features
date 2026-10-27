import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/join_request_watcher.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/data_arrival.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/features/more/widgets/join_requests_card.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.83 — approved, and does the project actually arrive?**
///
/// Michael ran task 11.81's flow on two real devices on 2026-08-31. The Mac
/// created a project and showed the iPhone's request; the Mac approved it; and
/// **the project never appeared on the iPhone.** Nothing errored. The grant was
/// fine, the server was fine, `GET /projects/mine` was fine — the last mile was
/// a manual tap on a screen nobody had a reason to open, and nothing told them
/// to make it. Worse, the one element that had been tracking the request went
/// blank at the exact moment the news arrived.
///
/// Every test here asks one of the two questions that walkthrough raised:
/// **did the project arrive by itself**, and **was the person told**.
///
/// No server runs: Phase 10's invariant 5 holds here as everywhere, so this
/// drives `FakeSyncTransport`, which models the same refusal rules and — since
/// this task — the same approved-only `project_id` disclosure.
void main() {
  const bob = 'user-bob';
  const alice = 'user-alice';
  const projectId = 'proj-1';
  final now = DateTime.utc(2026, 8, 1, 12);

  late AppDatabase db;
  late FakeSyncTransport transport;

  setUp(() async {
    installFakeSharedPreferences();
    db = await AppDatabase.openInMemory();
    transport = FakeSyncTransport()
      ..sessionUserId = bob
      ..sessionEmail = 'bob@example.org'
      ..seedServerRow(Tables.users, _user(alice, 'alice@example.org', now))
      ..seedServerRow(Tables.users, _user(bob, 'bob@example.org', now))
      ..seedServerRow(Tables.projects, _project(projectId, 'Elk Winter', now))
      ..seedServerRow(
        Tables.observations,
        _observation('obs-1', projectId, alice, now),
      );
  });

  tearDown(() => db.close());

  /// Bob's device: a database, a session, and the fake server behind the one
  /// seam every membership call and the watcher reach a server through.
  Future<ProviderContainer> bobsDevice() async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) async => db),
        membershipTransportProvider.overrideWith((ref) async => transport),
        sessionStoreProvider.overrideWithValue(
          FakeSessionStore(
            StoredSession(
              token: 'token',
              userId: bob,
              email: 'bob@example.org',
              expiresAt: DateTime.now().add(const Duration(days: 1)),
            ),
          ),
        ),
      ],
    );
    // `currentSessionProvider` returns null on an unconfigured device without
    // ever reading the keychain, so the address has to be set for the session
    // to exist at all.
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');
    return container;
  }

  /// Bob asks to join with the code Alice handed him, and Alice approves.
  Future<String> requestAndApprove(
    ProviderContainer container, {
    bool approve = true,
    bool reject = false,
  }) async {
    final code = transport.enableJoining(projectId);
    final created = await container
        .read(membershipControllerProvider.notifier)
        .requestToJoin(code);
    if (reject) {
      await transport.rejectJoinRequest(
        projectId: projectId,
        requestId: created.requestId,
      );
    } else if (approve) {
      await transport.approveJoinRequest(
        projectId: projectId,
        requestId: created.requestId,
        role: ProjectRole.contributor,
      );
    }
    return created.requestId;
  }

  Future<bool> projectIsOnDevice() async {
    final rows = await db.raw.query(
      Tables.projects,
      where: 'project_id = ? AND deleted_at IS NULL',
      whereArgs: [projectId],
    );
    return rows.isNotEmpty;
  }

  group('the project arrives without anybody tapping Join', () {
    test('an approved request links and syncs the project by itself', () async {
      final container = await bobsDevice();
      addTearDown(container.dispose);
      await requestAndApprove(container);

      // Nothing on this device has been touched by a person since the request
      // was sent — this is the app coming back to the foreground.
      expect(await projectIsOnDevice(), isFalse);
      await container.read(joinRequestWatcherProvider.notifier).refresh();

      expect(
        await projectIsOnDevice(),
        isTrue,
        reason: 'the whole of task 11.83: approval must complete on its own',
      );
      expect(
        await container.read(syncStateStoreProvider).isProjectLinked(projectId),
        isTrue,
      );
      // The pull is an ordinary sync from cursor zero, so the project's
      // history came with it rather than an empty shell.
      final observations = await db.raw.query(Tables.observations);
      expect(observations, hasLength(1));
    });

    test('the second check does not join a second time', () async {
      // Two devices on one account both see the same approved request, and a
      // device that checks twice sees it twice. Neither may re-run the join:
      // it is not harmful — a join from a stored cursor is an ordinary sync —
      // but it must not treat the approval as new work.
      final container = await bobsDevice();
      addTearDown(container.dispose);
      await requestAndApprove(container);
      final watcher = container.read(joinRequestWatcherProvider.notifier);
      await watcher.refresh();
      final requestId = container
          .read(joinRequestWatcherProvider)
          .requests
          .single
          .requestId;

      expect(
        await container.read(syncStateStoreProvider).autoJoinedRequestIds(),
        {requestId},
      );
      await watcher.refresh();
      expect(
        await container.read(syncStateStoreProvider).autoJoinedRequestIds(),
        {requestId},
        reason: 'the record of having acted is written once, not per check',
      );
    });

    test(
      'a project deleted after joining does not come back on its own',
      () async {
        // `ProjectJoiner._withdrawLocalTombstone` exists because a local
        // visibility choice once outranked the server. An automatic join must
        // not use it to resurrect a project somebody deliberately deleted.
        final container = await bobsDevice();
        addTearDown(container.dispose);
        await requestAndApprove(container);
        await container.read(joinRequestWatcherProvider.notifier).refresh();
        expect(await projectIsOnDevice(), isTrue);

        await db.raw.update(
          Tables.projects,
          {'deleted_at': DbCodec.encodeUtc(now)},
          where: 'project_id = ?',
          whereArgs: [projectId],
        );

        // The approval is still approved — nothing prunes decided requests —
        // so every later check sees it again.
        await container.read(joinRequestWatcherProvider.notifier).refresh();
        expect(
          await projectIsOnDevice(),
          isFalse,
          reason: 'a deliberate deletion outranks an approval already acted on',
        );
      },
    );

    test(
      'a second approval, after a deletion, does bring the project back',
      () async {
        // The other side of the same rule. A *new* request is the person going
        // and asking again, which is the deliberate act that outranks the
        // earlier deletion — so an approval this device has never acted on is
        // acted on even though a tombstoned copy is sitting here.
        final container = await bobsDevice();
        addTearDown(container.dispose);
        final first = await requestAndApprove(container);
        await container.read(joinRequestWatcherProvider.notifier).refresh();
        await db.raw.update(
          Tables.projects,
          {'deleted_at': DbCodec.encodeUtc(now)},
          where: 'project_id = ?',
          whereArgs: [projectId],
        );

        // Asked again and approved again: a second row, a second id. Seeded on
        // the fake directly because the request route correctly refuses a second
        // request from somebody who is already a member.
        expect(transport.serverJoinRequests.single.requestId, first);
        transport.joinRequestUserIds['request-again'] = bob;
        transport.serverJoinRequests.add(
          JoinRequestSummary(
            requestId: 'request-again',
            projectId: projectId,
            email: 'bob@example.org',
            claimedName: 'Bob',
            requestedAt: DbCodec.encodeUtc(now),
            decision: joinDecisionApproved,
            decidedAt: DbCodec.encodeUtc(now),
          ),
        );

        await container.read(joinRequestWatcherProvider.notifier).refresh();
        expect(await projectIsOnDevice(), isTrue);
      },
    );
  });

  group('the poll', () {
    test(
      'runs while a request is outstanding and stops when it is decided',
      () async {
        final container = await bobsDevice();
        addTearDown(container.dispose);
        final watcher = container.read(joinRequestWatcherProvider.notifier);

        await requestAndApprove(container, approve: false);
        await watcher.check();
        expect(
          watcher.isPolling,
          isTrue,
          reason: 'a device with an outstanding request asks again in a minute',
        );

        await transport.approveJoinRequest(
          projectId: projectId,
          requestId: transport.serverJoinRequests.single.requestId,
          role: ProjectRole.contributor,
        );
        await watcher.check();
        expect(
          watcher.isPolling,
          isFalse,
          reason:
              'a poll that survives the request being decided is battery '
              'cost with no purpose',
        );
      },
    );

    test('a device with nothing outstanding never starts one', () async {
      final container = await bobsDevice();
      addTearDown(container.dispose);
      final watcher = container.read(joinRequestWatcherProvider.notifier);
      await watcher.refresh();
      expect(watcher.isPolling, isFalse);
      expect(container.read(joinRequestWatcherProvider).requests, isEmpty);
    });

    test('a second device told "you have already asked" starts watching too',
        () async {
      // One account, two devices. The phone asked; the laptop types the same
      // code and the server correctly refuses a second row. The laptop is
      // waiting on that answer just as much, so it must start watching —
      // otherwise it never learns it was let in.
      final container = await bobsDevice();
      addTearDown(container.dispose);
      final code = transport.enableJoining(projectId);
      final controller = container.read(membershipControllerProvider.notifier);
      await controller.requestToJoin(code);
      // Wipe this device's note, standing in for the second device, which
      // never made the request that wrote it.
      await container.read(syncStateStoreProvider).setJoinWorkPending(false);

      await expectLater(
        controller.requestToJoin(code),
        throwsA(
          isA<SyncTransportException>().having(
            (e) => e.reason,
            'reason',
            joinRefusalAlreadyRequested,
          ),
        ),
      );
      expect(
        await container.read(syncStateStoreProvider).joinWorkPending(),
        isTrue,
        reason: 'a refusal that means "you are already waiting" still leaves '
            'this device with something to wait for',
      );
    });

    test('a device that has never asked to join anything reaches no server '
        'on a foreground', () async {
      // **The bound that makes this defensible.** Nearly every device, nearly
      // all the time, has no join business — and one that asks the server on
      // every foreground anyway is spending somebody's cellular data on a
      // question it already knows the answer to. Task 11.59's automatic-sync
      // suite caught the first version of this doing exactly that on a device
      // whose owner had chosen "Only when I ask".
      final container = await bobsDevice();
      addTearDown(container.dispose);
      await container
          .read(joinRequestWatcherProvider.notifier)
          .checkOnForeground();
      expect(transport.myJoinRequestsCalls, 0);

      // And it does ask once there is something to ask about.
      await requestAndApprove(container, approve: false);
      await container
          .read(joinRequestWatcherProvider.notifier)
          .checkOnForeground();
      expect(transport.myJoinRequestsCalls, greaterThan(0));
    });

    test('the poll stops asking once nothing is outstanding, across a '
        'restart', () async {
      // The durable half. `requestToJoin` writes the note; a check that finds
      // the request decided and the project here clears it, so the *next* app
      // launch asks nothing at all.
      final container = await bobsDevice();
      addTearDown(container.dispose);
      await requestAndApprove(container);
      await container.read(joinRequestWatcherProvider.notifier).refresh();
      expect(
        await container.read(syncStateStoreProvider).joinWorkPending(),
        isFalse,
        reason: 'the approval is downloaded, so there is nothing left to ask',
      );

      final before = transport.myJoinRequestsCalls;
      await container
          .read(joinRequestWatcherProvider.notifier)
          .checkOnForeground();
      expect(transport.myJoinRequestsCalls, before);
    });

    test('a device with no server does nothing and says nothing', () async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) async => db),
          membershipTransportProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      final watcher = container.read(joinRequestWatcherProvider.notifier);
      await watcher.refresh();
      expect(watcher.isPolling, isFalse);
      expect(container.read(joinRequestWatcherProvider).requests, isEmpty);
    });
  });

  group('the card narrates instead of going blank', () {
    /// Renders the card alone, and — because these are widget tests —
    /// **stops the poll before the test ends.** `Timer.periodic` started
    /// inside `runAsync` outlives the pump otherwise, and a pending timer at
    /// teardown is a test that hangs rather than one that fails.
    Future<void> pumpCard(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      addTearDown(
        () => container.read(joinRequestWatcherProvider.notifier).suspend(),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: JoinRequestsCard()),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('waiting, then in — the same card, in the same place', (
      tester,
    ) async {
      // **Everything that touches the database or the transport runs inside
      // `runAsync`.** A widget test's default zone is fake-async, and the
      // sqflite ffi isolate never completes under it — so setup done outside
      // would leave an unfinished check in the watcher's queue and hang the
      // test rather than fail it.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await bobsDevice();
        await requestAndApprove(container, approve: false);
        await container.read(joinRequestWatcherProvider.notifier).check();
      });
      addTearDown(container.dispose);
      container.read(joinRequestWatcherProvider.notifier).suspend();
      await pumpCard(tester, container);
      expect(find.text('Elk Winter'), findsOneWidget);
      expect(find.textContaining('Waiting for the owner'), findsOneWidget);

      // The owner approves, somewhere else. The next check is the poll tick.
      await tester.runAsync(() async {
        await transport.approveJoinRequest(
          projectId: projectId,
          requestId: transport.serverJoinRequests.single.requestId,
          role: ProjectRole.contributor,
        );
        await container.read(joinRequestWatcherProvider.notifier).check();
      });
      container.read(joinRequestWatcherProvider.notifier).suspend();
      await tester.pump();

      // **The assertion this task exists for.** Before it, this card filtered
      // approvals out of its own list, so at this exact moment it rendered
      // nothing at all.
      expect(find.textContaining('Waiting for the owner'), findsNothing);
      expect(find.textContaining("You're in"), findsOneWidget);
      expect(find.text('Elk Winter'), findsOneWidget);
      expect(await tester.runAsync(projectIsOnDevice), isTrue);
    });

    testWidgets(
      '"open it from your projects list" is not said once the project has '
      'left that list (task 11.302\'s device look)',
      (tester) async {
        // Michael's Mac, 2026-09-24: joined, the owner then deleted the
        // project, it left the projects list — and this card went on saying
        // it was there. The arrival is remembered once; the list is not.
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await bobsDevice();
          await requestAndApprove(container);
          await container.read(joinRequestWatcherProvider.notifier).check();
        });
        addTearDown(container.dispose);
        container.read(joinRequestWatcherProvider.notifier).suspend();
        await pumpCard(tester, container);
        expect(find.textContaining('open it from your projects list'),
            findsOneWidget);

        // The owner's deletion arrives: the project's own row, tombstoned,
        // exactly as a pull stores it — and announced, as every pull is.
        Future<void> setDeleted(String? at) async {
          await db.raw.update(
            Tables.projects,
            {'deleted_at': at},
            where: 'project_id = ?',
            whereArgs: [projectId],
          );
          DataArrival.announce();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }

        await tester.runAsync(
          () => setDeleted(DbCodec.encodeUtc(now.add(const Duration(days: 1)))),
        );
        await tester.pump();
        expect(find.textContaining('open it from your projects list'),
            findsNothing);
        expect(find.textContaining('it has been deleted'), findsOneWidget);

        // And restored: the claim is true again, so it is made again.
        await tester.runAsync(() => setDeleted(null));
        await tester.pump();
        expect(find.textContaining('open it from your projects list'),
            findsOneWidget);
      },
    );

    testWidgets('a rejection is told by the same element', (tester) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await bobsDevice();
        await requestAndApprove(container, approve: false, reject: true);
        await container.read(joinRequestWatcherProvider.notifier).check();
      });
      addTearDown(container.dispose);
      await pumpCard(tester, container);
      expect(find.textContaining('turned this down'), findsOneWidget);
    });

    testWidgets(
      'an interrupted first pull says the project is not here yet, rather '
      'than saying nothing',
      (tester) async {
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await bobsDevice();
          await requestAndApprove(container);
          // **The connection goes during the first pull**, not before it:
          // reading the requests succeeded, so this device knows it is in and
          // cannot get the project. That is the state the card has to have a
          // sentence for.
          transport.failPullAfterPages = transport.pullCalls;
          await container.read(joinRequestWatcherProvider.notifier).refresh();
        });
        addTearDown(container.dispose);
        await pumpCard(tester, container);

        expect(await tester.runAsync(projectIsOnDevice), isFalse);
        expect(find.textContaining("You're in"), findsOneWidget);
        expect(
          find.textContaining("download hasn't started"),
          findsOneWidget,
          reason:
              'present-and-behind and not-here-yet are different things '
              'to be told',
        );

        // And it resumes on the next foreground rather than needing a tap.
        await tester.runAsync(() async {
          transport.failPullAfterPages = null;
          await container.read(joinRequestWatcherProvider.notifier).refresh();
        });
        expect(await tester.runAsync(projectIsOnDevice), isTrue);
      },
    );
  });
}

Map<String, Object?> _user(String id, String email, DateTime now) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'user_id': id,
    'first_name': 'Sam',
    'last_name': 'Ranger',
    'email': email,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': id,
    'origin_device_id': 'device-A',
  };
}

Map<String, Object?> _project(String id, String name, DateTime now) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'project_id': id,
    'project_name': name,
    'owner_user_id': 'user-alice',
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': 'user-alice',
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };
}

Map<String, Object?> _observation(
  String id,
  String projectId,
  String userId,
  DateTime now,
) {
  final stamp = DbCodec.encodeUtc(now);
  return {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': stamp,
    'timestamp_utc': stamp,
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };
}

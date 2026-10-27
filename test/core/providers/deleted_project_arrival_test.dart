import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/app.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/join_request_watcher.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sync/restored_project_arrival.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/routing/app_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **A member is told when their project is deleted** (task 11.313, from
/// task 11.302's Discovered Scope) — the symmetric case to
/// `restored_project_arrival_test.dart`, which this file's fixtures and
/// harness are deliberately copied from so the two stay comparable.
///
/// Until this, a deletion arriving by sync hid the project and said nothing:
/// a member's open project simply went blank. The announcement now comes
/// from the same place the restore's does — `ProjectMerger.merge`, after the
/// same commit, so every route a deletion can arrive by speaks (the
/// foreground check, *Sync now* / pull-to-refresh, and the ordinary round for
/// whichever project is open, which does not stop being open just because
/// its own row is now hidden).
///
/// **What this file also has to prove, because the copy claims it:** a
/// bearing this device recorded and had not yet sent still reaches the
/// server on the very round that brings the tombstone down. Nothing about a
/// project's own `deleted_at` gates a push of its child rows — only the
/// snapshot gate does, and a genuine member is never a snapshot holder.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  late FakeSyncTransport server;
  const me = 'user-1';
  const owner = 'user-2';
  const projectId = 'proj-1';
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));
  final deletedStamp = DbCodec.encodeUtc(DateTime.utc(2026, 9, 20, 9, 30));

  Map<String, Object?> userRow(String id, String first, String last) => {
    'user_id': id,
    'first_name': first,
    'last_name': last,
    'email': '$id@example.com',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': id,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> projectRow({required String ownerId}) => {
    'project_id': projectId,
    'project_name': 'Elk Study',
    'owner_user_id': ownerId,
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> membershipRow(String id, String userId, String role) => {
    'membership_id': id,
    'project_id': projectId,
    'user_id': userId,
    'join_date': stamp,
    'end_date': null,
    'role': role,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> observationRow(String id) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': me,
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
    'last_modified_by': me,
    'origin_device_id': 'device-A',
  };

  /// One row on this device and on the server, with the receipt a real
  /// publish would have left — so nothing is pending before the test acts.
  Future<void> seedPublished(String table, Map<String, Object?> row) async {
    await db.raw.insert(table, row);
    server.seedServerRow(table, row);
    await SyncRowReceiptStore.ensureTable(db.raw);
    final spec = syncTablesByName[table]!;
    await SyncRowReceiptStore(db.raw).record(
      projectId: projectId,
      tableName: table,
      rowKey: spec.primaryKey.map((c) => row[c]).join('/'),
      ackedUpdatedAt: row['updated_at']! as String,
      at: DateTime.utc(2026, 8, 1),
    );
  }

  setUp(() async {
    db = await AppDatabase.openInMemory();
    server = FakeSyncTransport()
      ..sessionUserId = me
      ..sessionEmail = '$me@example.com';
  });
  tearDown(() => db.close());

  ProviderContainer signedInContainer({List<Override> extra = const []}) =>
      ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) async => db),
          serverTransportProvider.overrideWith((ref) async => server),
          currentUserProvider.overrideWith(
            (ref) async => User(
              userId: me,
              firstName: 'Sam',
              lastName: 'Ranger',
              email: '$me@example.com',
              sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1)),
            ),
          ),
          sessionStoreProvider.overrideWithValue(
            FakeSessionStore(
              StoredSession(
                token: 'not-a-real-token',
                userId: me,
                email: '$me@example.com',
                expiresAt: DateTime.now().add(const Duration(days: 30)),
              ),
            ),
          ),
          ...extra,
        ],
      );

  Future<void> linkedAndOpen(ProviderContainer container) async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    await container.read(syncStateStoreProvider).markProjectLinked(projectId);
    await container.read(syncControllerProvider.future);
  }

  /// **A member's device**: user-1 is a contributor on user-2's project,
  /// published and in sync, with one bearing of their own already sent.
  Future<void> seedMemberDevice(ProviderContainer container) async {
    await seedPublished(Tables.users, userRow(me, 'Sam', 'Ranger'));
    await seedPublished(Tables.users, userRow(owner, 'Robin', 'Owner'));
    await seedPublished(Tables.projects, projectRow(ownerId: owner));
    await seedPublished(
      Tables.projectMemberships,
      membershipRow('mem-owner', owner, ownerMembershipRole),
    );
    await seedPublished(
      Tables.projectMemberships,
      membershipRow('mem-me', me, 'contributor'),
    );
    await seedPublished(Tables.observations, observationRow('obs-1'));
    await linkedAndOpen(container);
  }

  /// The owner deletes the project on *their* phone and it reaches the
  /// server — which, seen from this member's device, is a new tombstone on
  /// the server that `/projects/mine` no longer lists.
  void ownerDeletesOnTheirPhone() {
    final row = server.serverRow(Tables.projects, projectId)!;
    server.seedServerRow(Tables.projects, {
      ...row,
      'deleted_at': deletedStamp,
      'updated_at': deletedStamp,
      'revision': 1,
      'last_modified_by': owner,
    });
    server.serverProjects.removeWhere((p) => p.projectId == projectId);
  }

  Future<Map<String, Object?>> localProject() async =>
      (await db.raw.query(
        Tables.projects,
        where: 'project_id = ?',
        whereArgs: [projectId],
      )).single;

  /// Everything [ProjectDeletionAnnouncement] announces from here on.
  List<ProjectDeletionArrival> listenForDeletions() {
    final heard = <ProjectDeletionArrival>[];
    void listener(List<ProjectDeletionArrival> arrivals) =>
        heard.addAll(arrivals);
    ProjectDeletionAnnouncement.addListener(listener);
    addTearDown(() => ProjectDeletionAnnouncement.removeListener(listener));
    return heard;
  }

  group('a member\'s device', () {
    test(
      'is told, by name, when the project it is on is deleted, and its own '
      'unsent bearing still reaches the server on the same round',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedMemberDevice(container);
        // Recorded on this device and never sent — written straight to the
        // table, bypassing publish, the way an offline bearing waits.
        await db.raw.insert(Tables.observations, observationRow('obs-2'));
        expect(server.serverRow(Tables.observations, 'obs-2/$projectId'), isNull);

        final announced = listenForDeletions();
        ownerDeletesOnTheirPhone();
        await container.read(syncControllerProvider.notifier).syncNow();

        expect((await localProject())['deleted_at'], isNotNull);
        expect(announced.map((a) => a.projectId), [projectId]);
        expect(
          announced.single.deletedByName,
          'Robin Owner',
          reason: 'named, not "an owner" — the member did not do this and '
              'needs to know who did',
        );
        expect(announced.single.deletedBy, owner);
        // **Say only what is true.** The unsent bearing is not held or
        // refused by the project's own tombstone — it went up on the same
        // round that brought the tombstone down.
        expect(
          server.serverRow(Tables.observations, 'obs-2/$projectId'),
          isNotNull,
          reason: 'nothing about a project\'s own deleted_at gates a push of '
              'its child rows — the copy must not claim otherwise',
        );
      },
    );

    test(
      'the project stays the active one — a tombstone hides it, it does not '
      'close it, which is what lets a later restore still find it',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedMemberDevice(container);

        ownerDeletesOnTheirPhone();
        await container.read(syncControllerProvider.notifier).syncNow();

        expect((await localProject())['deleted_at'], isNotNull);
        expect(
          container.read(activeProjectIdProvider).value,
          projectId,
          reason: 'left alone on purpose — clearing it would stop the '
              'ordinary round that a restore rides back in on',
        );
        expect(await container.read(currentProjectProvider.future), isNull,
            reason: 'the screen goes blank; the notice is what explains it');
      },
    );
  });

  group('the app says so, with nobody touching a screen', () {
    testWidgets(
      'opening TriTrack after the project was deleted elsewhere says who '
      'deleted it',
      (tester) async {
        final container = signedInContainer(
          extra: [
            appRouterProvider.overrideWithValue(
              GoRouter(
                routes: [
                  GoRoute(path: '/', builder: (_, _) => const Scaffold()),
                ],
              ),
            ),
            joinRequestWatcherProvider.overrideWith(_QuietJoinWatcher.new),
          ],
        );
        addTearDown(container.dispose);
        const sentence =
            'Robin Owner deleted "Elk Study". Nothing you recorded in it is '
            'lost — it still reaches the server. If it is restored, it comes '
            'back by itself.';

        await tester.runAsync(() async {
          await seedMemberDevice(container);
          ownerDeletesOnTheirPhone();

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const TriTrackApp(),
            ),
          );
          for (var i = 0; i < 240; i++) {
            if (find.text(sentence).evaluate().isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
        });

        expect(find.text(sentence), findsOneWidget);
      },
    );

    testWidgets(
      'a deletion made by this same account says nothing — the person did '
      'it and was told where they did it',
      (tester) async {
        final container = signedInContainer(
          extra: [
            appRouterProvider.overrideWithValue(
              GoRouter(
                routes: [
                  GoRoute(path: '/', builder: (_, _) => const Scaffold()),
                ],
              ),
            ),
            joinRequestWatcherProvider.overrideWith(_QuietJoinWatcher.new),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          await seedMemberDevice(container);
          // Deleted from this same account's other device.
          final row = server.serverRow(Tables.projects, projectId)!;
          server.seedServerRow(Tables.projects, {
            ...row,
            'deleted_at': deletedStamp,
            'updated_at': deletedStamp,
            'revision': 1,
            'last_modified_by': me,
          });
          server.serverProjects.removeWhere((p) => p.projectId == projectId);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const TriTrackApp(),
            ),
          );
          for (var i = 0; i < 240; i++) {
            final gone = (await localProject())['deleted_at'] != null;
            if (gone) break;
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
        });

        expect((await tester.runAsync(localProject))!['deleted_at'], isNotNull);
        expect(find.textContaining('deleted "Elk Study"'), findsNothing);
      },
    );
  });
}

class _QuietJoinWatcher extends JoinRequestWatcher {
  @override
  JoinWatch build() => const JoinWatch();

  @override
  Future<void> checkOnForeground() async {}
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_membership_repository.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.301: a departure the server has already made moot is retried
/// forever.**
///
/// ## Reproduction
///
/// An owner removes a member on the server. That member's device, offline,
/// taps *Leave* — `ProjectMembershipRepository.leaveProject` closes the local
/// row, exactly as it would in the field, with no network involved. Back
/// online, the foreground flush (`SyncController.deliverPendingDepartures`,
/// called from `app.dart` on every foreground) pushes the departure and the
/// server answers with the same whole-request `403 forbidden` §4.27
/// describes for somebody it no longer regards as a member — modelled here
/// with `FakeSyncTransport.closedMembershipProjects`, the fake's own model of
/// that refusal (and of the closed-membership disclosure a follow-up pull
/// receives).
///
/// The person is off the project either way — the departure and the removal
/// land on the same end state — so a `403` here is not a failure to recover
/// from. Before this task's fix, `deliverPendingDepartures` only settles a
/// departure once a *receipt* acknowledges the pushed row, and a `403`
/// produces no receipt, so the departure is offered again on every
/// subsequent foreground, forever, and the project never unlinks.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  late FakeSyncTransport server;
  const userId = 'user-1';
  const ownerId = 'owner-1';
  const projectId = 'proj-1';
  const membershipId = 'mem-1';
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));

  setUp(() async {
    db = await AppDatabase.openInMemory();
    server = FakeSyncTransport()
      ..sessionUserId = userId
      ..sessionEmail = '$userId@example.com';

    // The project and the member's own row, seeded on the device as they
    // stood before the owner acted — an ordinary, already-published
    // membership, seen from a second account's throwaway project.
    await db.raw.insert(Tables.users, {
      'user_id': userId,
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': '$userId@example.com',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': 'device-A',
    });
    await db.raw.insert(Tables.users, {
      'user_id': ownerId,
      'first_name': 'Pat',
      'last_name': 'Owner',
      'email': '$ownerId@example.com',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': ownerId,
      'origin_device_id': 'device-B',
    });
    await db.raw.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Elk',
      'owner_user_id': ownerId,
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': ownerId,
      'origin_device_id': 'device-B',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
    await db.raw.insert(Tables.projectMemberships, {
      'membership_id': membershipId,
      'project_id': projectId,
      'user_id': userId,
      'join_date': stamp,
      'end_date': null,
      'role': 'contributor',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': 'device-A',
    });
  });
  tearDown(() => db.close());

  ProviderContainer signedInContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) async => db),
      serverTransportProvider.overrideWith((ref) async => server),
      currentUserProvider.overrideWith(
        (ref) async => User(
          userId: userId,
          firstName: 'Sam',
          lastName: 'Ranger',
          email: '$userId@example.com',
          sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1)),
        ),
      ),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          StoredSession(
            token: 'not-a-real-token',
            userId: userId,
            email: '$userId@example.com',
            expiresAt: DateTime.now().add(const Duration(days: 30)),
          ),
        ),
      ),
    ],
  );

  /// The device as it stands right after a publish: an address, the project
  /// linked (but not open — leaving a project you are not currently working
  /// in is the ordinary case, per `MembershipController.leaveProject`'s own
  /// doc comment).
  Future<void> linkedButNotOpen(ProviderContainer container) async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    await container.read(activeProjectIdProvider.notifier).set(null);
    await container.read(syncStateStoreProvider).markProjectLinked(projectId);
    await container.read(syncControllerProvider.future);
  }

  /// What the person did at the trailhead: tapped *Leave* with no signal.
  /// Writes the local closed row directly, the way `leaveProject` does before
  /// it ever tries the network.
  Future<void> leftWhileOffline() async {
    final repo = ProjectMembershipRepository(db.raw);
    await repo.leaveProject(
      projectId: projectId,
      actor: const MutationActor.user(userId),
      now: DateTime.utc(2026, 8, 2),
    );
  }

  /// What the owner did on the server, before or after the offline departure
  /// — the member is gone either way. Seeds the server's own closed row (as a
  /// removal would have written it) and switches the fake into the `403` +
  /// disclosure behaviour §4.27 describes.
  void removedByOwnerOnServer() {
    server.seedServerRow(Tables.projectMemberships, {
      'membership_id': membershipId,
      'project_id': projectId,
      'user_id': userId,
      'join_date': stamp,
      'end_date': DbCodec.encodeUtc(DateTime.utc(2026, 8, 1, 12)),
      'role': 'contributor',
      'created_at': stamp,
      'updated_at': DbCodec.encodeUtc(DateTime.utc(2026, 8, 1, 12)),
      'revision': 1,
      'last_modified_by': ownerId,
      'origin_device_id': 'device-B',
    });
    server.closedMembershipProjects.add(projectId);
  }

  test(
    'a departure refused because the owner already removed the person '
    'settles on the first foreground, and the flush stops asking',
    () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await linkedButNotOpen(container);
      await leftWhileOffline();
      removedByOwnerOnServer();

      final syncController = container.read(syncControllerProvider.notifier);
      final store = container.read(syncStateStoreProvider);

      expect(
        await store.isProjectLinked(projectId),
        isTrue,
        reason: 'the project must still be linked for the flush to have '
            'anything to do',
      );

      // Foreground #1: the flush pushes the departure, meets the `403`, and
      // must recognise that as settled rather than leaving it pending.
      await syncController.deliverPendingDepartures();
      final pushesAfterFirst = server.pushCalls;

      expect(
        pushesAfterFirst,
        1,
        reason: 'the first foreground should attempt the departure exactly '
            'once',
      );
      expect(
        await store.isProjectLinked(projectId),
        isFalse,
        reason: 'a self-departure refused with 403 is the outcome the '
            'caller wanted — the project should have unlinked on the spot',
      );

      // Foregrounds #2 and #3: with the project unlinked, nothing should be
      // offered again — this is the loop the task exists to close.
      await syncController.deliverPendingDepartures();
      await syncController.deliverPendingDepartures();

      expect(
        server.pushCalls,
        pushesAfterFirst,
        reason: 'the flush kept asking on every foreground after the '
            'departure was already settled',
      );
    },
  );

  test(
    'an ordinary self-departure (nobody removed the person) still reaches '
    'the server and unlinks — reproduction found this broken for every '
    'departure, not only a refused one',
    () async {
      // No removal on the server at all: this is the everyday case
      // `MembershipController.leaveProject`'s own doc claims was already
      // working. It was not — `SyncEngine.offersNothingFor` (task 11.237)
      // reads this device's own membership row, which `leaveProject` closes
      // *before* ever trying to push it, so every self-departure's own push
      // was silently offering zero rows and never reaching the server at
      // all. This test pins the fix for that, separately from the `403`
      // case above.
      final container = signedInContainer();
      addTearDown(container.dispose);
      await linkedButNotOpen(container);
      await leftWhileOffline();
      // The server still has the member's row open — it never learned of
      // the departure until this push.
      server.seedServerRow(Tables.projectMemberships, {
        'membership_id': membershipId,
        'project_id': projectId,
        'user_id': userId,
        'join_date': stamp,
        'end_date': null,
        'role': 'contributor',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': 'device-A',
      });

      final syncController = container.read(syncControllerProvider.notifier);
      final store = container.read(syncStateStoreProvider);

      await syncController.deliverPendingDepartures();

      expect(
        server.pushCalls,
        1,
        reason: 'the departure row was never offered to the server at all',
      );
      expect(
        server.serverRow(Tables.projectMemberships, '$membershipId/$projectId')?['end_date'],
        isNotNull,
        reason: "the server's own row should now show the departure",
      );
      expect(
        await store.isProjectLinked(projectId),
        isFalse,
        reason: 'a confirmed departure should unlink the project',
      );
    },
  );

  test(
    'an ordinary refusal (no signal) leaves the departure pending, retried '
    'next foreground',
    () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await linkedButNotOpen(container);
      await leftWhileOffline();
      // No removal on the server: the owner never acted, and this device
      // simply has no signal. The departure must stay pending — this is not
      // "treat every refusal as done", only a self-departure's own `403`.
      server.permanentFailure = const SyncTransportException('unreachable');

      final syncController = container.read(syncControllerProvider.notifier);
      final store = container.read(syncStateStoreProvider);

      await syncController.deliverPendingDepartures();

      expect(
        await store.isProjectLinked(projectId),
        isTrue,
        reason: 'an unreachable server must not be read as a settled '
            'departure',
      );
    },
  );
}

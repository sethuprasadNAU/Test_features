import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/data/sync/sync_dropped_rows.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/data/sync/unknown_columns.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 10.8's headline promise, at the provider level: **the app is fully
/// usable with sync unavailable or permanently failing**, and nothing about
/// reading local data waits on it.
void main() {
  setUp(installFakeSharedPreferences);

  ProviderContainer makeContainer() => ProviderContainer(
    overrides: [sessionStoreProvider.overrideWithValue(FakeSessionStore())],
  );

  test(
    'with no server configured, sync reports unavailable and does nothing',
    () async {
      // Task 10.2's invariant reaches this far: no server URL means no sync
      // machinery at all, not a sync that fails.
      final container = makeContainer();
      addTearDown(container.dispose);

      final status = await container.read(syncControllerProvider.future);
      expect(status.isAvailable, isFalse);
      expect(status.unavailable, SyncUnavailable.notConfigured);
      expect(status.running, isFalse);
    },
  );

  test('syncNow is a harmless no-op when nothing is configured', () async {
    // The manual button must never throw into the UI just because there is no
    // server — being unconfigured is a supported state, not an error.
    final container = makeContainer();
    addTearDown(container.dispose);
    await container.read(syncControllerProvider.future);

    await expectLater(
      container.read(syncControllerProvider.notifier).syncNow(),
      completes,
    );
    final status = await container.read(syncControllerProvider.future);
    expect(status.running, isFalse);
    expect(status.lastError, isNull);
  });

  test('configured but signed out is its own state, not a failure', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');

    final status = await container.read(syncControllerProvider.future);
    expect(status.unavailable, SyncUnavailable.signedOut);
    // Signed out is not "broken" — the indicator must not cry wolf.
    expect(status.looksBroken, isFalse);
  });

  test('one failure is not "broken" — that is a dead zone', () async {
    // No connectivity is the normal field state. A UI that reports it as
    // failure trains people to ignore the indicator.
    const status = SyncStatus(schedule: SyncSchedule(consecutiveFailures: 1));
    expect(status.looksBroken, isFalse);
  });

  test('repeated failures do look broken', () {
    const status = SyncStatus(schedule: SyncSchedule(consecutiveFailures: 3));
    expect(status.looksBroken, isTrue);
  });

  test('a terminal failure looks broken immediately', () {
    const status = SyncStatus(
      schedule: SyncSchedule(stoppedReason: 'unauthorized'),
    );
    expect(status.looksBroken, isTrue);
  });

  group('SyncStatus.health', () {
    // Task 10.12's acceptance criterion: offline, version-refused, and
    // broken must be distinguishable, not all collapse to "failed."
    test('a version refusal is versionRefused even after repeated attempts', () {
      const status = SyncStatus(
        schedule: SyncSchedule(consecutiveFailures: 5),
        lastError: 'schema_version_mismatch',
        lastErrorMessage: 'Update the app to continue syncing.',
        lastFailure: SyncFailureCause.refusedWithRemedy,
      );
      expect(status.health, SyncHealth.versionRefused);
    });

    test('repeated ordinary failures are broken', () {
      const status = SyncStatus(
        schedule: SyncSchedule(consecutiveFailures: 3),
        lastError: 'unreachable',
        lastFailure: SyncFailureCause.unreachable,
      );
      expect(status.health, SyncHealth.broken);
    });

    test('a single transient failure is offline, not broken', () {
      const status = SyncStatus(
        schedule: SyncSchedule(consecutiveFailures: 1),
        lastError: 'unreachable',
        lastFailure: SyncFailureCause.unreachable,
      );
      expect(status.health, SyncHealth.offline);
    });

    test('no error at all is healthy', () {
      const status = SyncStatus(schedule: SyncSchedule());
      expect(status.health, SyncHealth.healthy);
    });

    // Found on real hardware 2026-08-27: a round that discarded a record the
    // server sent reported "Synced." Nothing distinguished it from a clean
    // round because nothing counted it.
    test('a record the pull discarded is never healthy', () {
      const status = SyncStatus(
        schedule: SyncSchedule(),
        droppedOnArrivalCount: 1,
      );
      expect(status.health, SyncHealth.recordsMissing);
    });

    test('a held record still outranks a discarded one', () {
      // A held record exists on this device and nowhere else; a discarded one
      // is safe on the server and on whoever wrote it. If both are true, the
      // more urgent message wins.
      const status = SyncStatus(
        schedule: SyncSchedule(),
        heldCount: 1,
        droppedOnArrivalCount: 1,
      );
      expect(status.health, SyncHealth.rowsRefused);
    });

    test('and a discarded record outranks merely being offline', () {
      const status = SyncStatus(
        schedule: SyncSchedule(consecutiveFailures: 1),
        lastError: 'unreachable',
        lastFailure: SyncFailureCause.unreachable,
        droppedOnArrivalCount: 2,
      );
      expect(status.health, SyncHealth.recordsMissing);
    });
  });

  // Task 11.114: "Synced 21 hours ago" in a calm colour, against a server the
  // app had never successfully contacted. Staleness alone — no failure, no
  // held row, nothing — must change the bar once 24 hours have passed since
  // the last successful sync.
  group('SyncStatus.health — staleness (task 11.114)', () {
    test('under 24 hours since the last success is still healthy', () {
      final status = SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc().subtract(
          const Duration(hours: 23),
        ),
      );
      expect(status.health, SyncHealth.healthy);
    });

    test(
      'a project that has never synced is not "stale" — there is nothing '
      'to have gone stale yet',
      () {
        const status = SyncStatus(schedule: SyncSchedule());
        expect(status.health, SyncHealth.healthy);
      },
    );

    test(
      'past 24 hours with records pending is red and names the count',
      () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc().subtract(
            const Duration(hours: 25),
          ),
          pendingCount: 47,
        );
        expect(status.health, SyncHealth.staleRecordsPending);
      },
    );

    test(
      'past 24 hours with nothing pending is amber, not red — Michael\'s '
      'decision that colour follows what is at risk',
      () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc().subtract(
            const Duration(hours: 25),
          ),
        );
        expect(status.health, SyncHealth.staleNothingPending);
      },
    );

    test(
      'staleness alone changes what was previously a calm "offline" too, '
      'not only "healthy"',
      () {
        final status = SyncStatus(
          schedule: const SyncSchedule(consecutiveFailures: 1),
          lastError: 'unreachable',
          lastFailure: SyncFailureCause.unreachable,
          lastSuccessAt: DateTime.now().toUtc().subtract(
            const Duration(hours: 25),
          ),
        );
        expect(status.health, SyncHealth.staleNothingPending);
      },
    );

    test('a dismissal from just now suppresses it', () {
      final status = SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: DateTime.now().toUtc().subtract(
          const Duration(hours: 25),
        ),
        staleDismissedAt: DateTime.now().toUtc(),
      );
      expect(status.health, SyncHealth.healthy);
    });

    test(
      'a dismissal from more than a day ago (past the next 04:00 local) has '
      'expired',
      () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: DateTime.now().toUtc().subtract(
            const Duration(hours: 25),
          ),
          staleDismissedAt: DateTime.now().toUtc().subtract(
            const Duration(days: 2),
          ),
        );
        expect(status.health, SyncHealth.staleNothingPending);
      },
    );

    // **The acceptance criterion the task write-up calls out by name.** A
    // dismissal must never be able to reach — let alone silence — any health
    // value other than the two staleness ones. Every one of these already has
    // its own non-calm base classification, so staleness's override (which
    // only ever fires from [SyncHealth.healthy] or [SyncHealth.offline]) can
    // never touch it — this test is what makes that structural guarantee an
    // explicit, checked fact rather than an accident of how the getter
    // happens to be written today.
    group('the dismiss cannot silence any non-staleness condition', () {
      final ancientSuccess = DateTime.now().toUtc().subtract(
        const Duration(days: 10),
      );
      final freshDismissal = DateTime.now().toUtc();

      test('a held record', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          heldCount: 1,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.rowsRefused);
      });

      test('records missing on arrival', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          droppedOnArrivalCount: 1,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.recordsMissing);
      });

      test('a rejected certificate', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          lastFailure: SyncFailureCause.certificateRejected,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.certificateRejected);
      });

      test('an ended membership', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          lastFailure: SyncFailureCause.membershipEnded,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.membershipEnded);
      });

      test('a refused address', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          unavailable: SyncUnavailable.serverAddressRefused,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.serverAddressRefused);
      });

      test('a session end', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          lastFailure: SyncFailureCause.sessionEnded,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.sessionEnded);
      });

      test('a version refusal', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          lastFailure: SyncFailureCause.refusedWithRemedy,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.versionRefused);
      });

      test('repeated ordinary failures (broken)', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(consecutiveFailures: 3),
          lastSuccessAt: ancientSuccess,
          lastFailure: SyncFailureCause.unreachable,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.broken);
      });

      test('access refused', () {
        final status = SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: ancientSuccess,
          lastFailure: SyncFailureCause.accessRefused,
          staleDismissedAt: freshDismissal,
        );
        expect(status.health, SyncHealth.accessRefused);
      });
    });
  });

  group('pendingCount and hasUnrecognizedFields', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.openInMemory();
    });

    tearDown(() => db.close());

    ProviderContainer makeFullContainer() => ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) async => db),
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

    Future<void> seedProject(ProviderContainer container) async {
      final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));
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
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      await container.read(activeProjectIdProvider.notifier).set('proj-1');
      await container.read(syncStateStoreProvider).markProjectLinked('proj-1');
    }

    test('counts rows never offered to the server as pending', () async {
      final container = makeFullContainer();
      addTearDown(container.dispose);
      await seedProject(container);

      final status = await container.read(syncControllerProvider.future);
      // Users + Projects rows seeded above, neither ever pushed.
      expect(status.pendingCount, greaterThan(0));
      expect(status.hasUnrecognizedFields, isFalse);
    });

    test('reports held unknown-column values (task 10.18 minor skew)', () async {
      final container = makeFullContainer();
      addTearDown(container.dispose);
      await seedProject(container);
      await UnknownColumnStore.ensureTable(db.raw);
      await UnknownColumnStore(db.raw).hold(
        'proj-1',
        syncTablesByName[Tables.projects]!,
        {'project_id': 'proj-1'},
        {'some_future_field': 'value'},
      );

      final status = await container.read(syncControllerProvider.future);
      expect(status.hasUnrecognizedFields, isTrue);
    });

    test(
      'a dropped row from an earlier session is counted the moment the app '
      'opens, not only after a round that finds one (task 11.44)',
      () async {
        await SyncDroppedRowStore.ensureTable(db.raw);
        await SyncDroppedRowStore(db.raw).record(
          projectId: 'proj-1',
          issue: const RowIssue(
            table: Tables.observations,
            primaryKeyValue: 'obs-1',
            field: 'signal_strength',
            message: 'unknown value "blisteringly_loud"',
          ),
          at: DateTime.utc(2026, 8, 1, 12),
        );

        // A brand-new container reading the same database — the whole point:
        // nothing about this drop was carried over in memory from a prior
        // `SyncController`, exactly as an app restart would not carry it.
        final container = makeFullContainer();
        addTearDown(container.dispose);
        await seedProject(container);

        final status = await container.read(syncControllerProvider.future);
        expect(status.droppedOnArrivalCount, 1);
        expect(status.health, SyncHealth.recordsMissing);
      },
    );
  });

  group('leaving a project stops this device syncing it (task 11.28)', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.openInMemory();
    });

    tearDown(() => db.close());

    /// A container whose every sync attempt is refused `403 forbidden` — what
    /// the server answers once it has taken somebody's departure and they are
    /// no longer a member.
    /// The same device and session, with the server answering as [client]
    /// says — [refusedContainer] is this with every route a `403`.
    ProviderContainer containerAnswering(
      http.Client client, {
      List<Override> alsoOverride = const [],
    }) => ProviderContainer(
      overrides: [
        ...alsoOverride,
        appDatabaseProvider.overrideWith((ref) async => db),
        currentUserProvider.overrideWith(
          (ref) async => User(
            userId: 'user-1',
            firstName: 'Sam',
            lastName: 'Ranger',
            email: 'sam@example.com',
            sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1)),
          ),
        ),
        serverHttpClientProvider.overrideWith((ref) async => client),
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

    ProviderContainer refusedContainer() => containerAnswering(
      MockClient((_) async => http.Response('{"error":"forbidden"}', 403)),
    );

    Future<void> seed(
      ProviderContainer container, {
      required bool stillAMember,
    }) async {
      final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));
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
        // The whole difference between the two cases below.
        'end_date': stillAMember ? null : stamp,
        'role': 'contributor',
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

    test('a refusal after we left unlinks the project', () async {
      // The offline case, which on a field device is the normal one: somebody
      // leaves at the end of a track, the departure goes out days later, and
      // from the sync after that the server refuses the project. Left linked,
      // the app would keep attempting it forever and report a bare `403`.
      final container = refusedContainer();
      addTearDown(container.dispose);
      await seed(container, stillAMember: false);

      await container.read(syncControllerProvider.future);
      await container.read(syncControllerProvider.notifier).syncNow();

      expect(
        await container.read(syncStateStoreProvider).isProjectLinked('proj-1'),
        isFalse,
      );
    });

    test(
      'and reports leaving, not breakage — the measured half of task 11.54',
      () async {
        // **This is the finding, as a test.** `_unlinkIfWeAlreadyLeft` fired
        // correctly (the test above proves it), and the status surface then
        // reported `SyncHealth.broken` anyway, because the 403 was terminal
        // and nothing re-read the state the unlink had just changed. Michael
        // saw the repeated-failure branch — "Sync has failed repeatedly. If
        // this continues, contact whoever manages your project server" — for
        // a project he had chosen to leave. The control worked and said
        // nothing, which is half a control.
        final container = refusedContainer();
        addTearDown(container.dispose);
        await seed(container, stillAMember: false);

        await container.read(syncControllerProvider.future);
        await container.read(syncControllerProvider.notifier).syncNow();

        final status = await container.read(syncControllerProvider.future);
        expect(status.health, SyncHealth.membershipEnded);
        expect(status.health, isNot(SyncHealth.broken));
        // And it still renders: a banner that vanishes is the same silence
        // in a different shape.
        expect(status.isWorthShowing, isTrue);
        expect(status.unavailable, SyncUnavailable.leftProject);
      },
    );

    test(
      'a fresh app start on a project the person left says so too',
      () async {
        // The restart case, and the reason the answer is derived from the
        // membership rows rather than remembered: unlinking cleared every
        // flag in `SyncStateStore`, so a later `build` has only the closed
        // stint to go on. Without this it reported `notLinked` — which the
        // banner hides entirely, so the explanation lasted exactly as long as
        // the app was open.
        final first = refusedContainer();
        addTearDown(first.dispose);
        await seed(first, stillAMember: false);
        await first.read(syncControllerProvider.future);
        await first.read(syncControllerProvider.notifier).syncNow();

        // A brand-new container over the same database and preferences.
        final second = refusedContainer();
        addTearDown(second.dispose);
        await second
            .read(serverConfigProvider.notifier)
            .setUrl('http://192.168.1.42:8080');
        await second.read(activeProjectIdProvider.notifier).set('proj-1');

        final status = await second.read(syncControllerProvider.future);
        expect(status.unavailable, SyncUnavailable.leftProject);
        expect(status.health, SyncHealth.membershipEnded);
      },
    );

    test(
      'a project never joined at all is still silent, not "you left it"',
      () async {
        // The half that keeps the derivation honest. "No open membership" is
        // true of every project this device has never put on a server, and
        // telling somebody they left one of those would be a confident wrong
        // answer — the thing this task exists to stop.
        final container = refusedContainer();
        addTearDown(container.dispose);
        await seed(container, stillAMember: false);
        await container.read(syncStateStoreProvider).clear('proj-1');
        await db.raw.delete(Tables.projectMemberships);

        final status = await container.read(syncControllerProvider.future);
        expect(status.unavailable, SyncUnavailable.notLinked);
        expect(status.isWorthShowing, isFalse);
      },
    );

    test(
      'a refusal on a project this person was never on is access refused, '
      'not a departure — the round\'s half of the question (task 11.305)',
      () async {
        // The sibling of "a project never joined at all is still silent"
        // above, for the other path. That test holds `build` to the narrow
        // question; nothing held `_run` to it, and `_run` asked "no open
        // row?" instead — true of a closed row *and* of no row at all — so
        // a linked project the signed-in person has no record on (the one
        // route: a different account's project left linked after sign-out)
        // was unlinked on its first refusal, and the person told they had
        // left it. The device knows nothing here that would let it say why
        // the server refused, so the answer is the least specific true one.
        final container = refusedContainer();
        addTearDown(container.dispose);
        final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));
        for (final id in ['user-1', 'user-2']) {
          await db.raw.insert(Tables.users, {
            'user_id': id,
            'first_name': 'Sam',
            'last_name': 'Ranger',
            'email': '$id@example.com',
            'created_at': stamp,
            'updated_at': stamp,
            'revision': 0,
            'last_modified_by': id,
            'origin_device_id': 'device-A',
          });
        }
        // Somebody else's project, with only their row on it.
        await db.raw.insert(Tables.projects, {
          'project_id': 'proj-1',
          'project_name': 'Elk',
          'owner_user_id': 'user-2',
          'creation_date': stamp,
          'datum': 'WGS84',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 0,
          'last_modified_by': 'user-2',
          'origin_device_id': 'device-B',
          'coordinate_format': 'dd',
          'triangulation_window_minutes': 15,
        });
        await db.raw.insert(Tables.projectMemberships, {
          'membership_id': 'mem-2',
          'project_id': 'proj-1',
          'user_id': 'user-2',
          'join_date': stamp,
          'end_date': null,
          'role': 'owner',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 0,
          'last_modified_by': 'user-2',
          'origin_device_id': 'device-B',
        });
        await container
            .read(serverConfigProvider.notifier)
            .setUrl('http://192.168.1.42:8080');
        await container.read(activeProjectIdProvider.notifier).set('proj-1');
        final store = container.read(syncStateStoreProvider);
        await store.markProjectLinked('proj-1');
        await store.setCursor('proj-1', 42);

        await container.read(syncControllerProvider.future);
        await container.read(syncControllerProvider.notifier).syncNow();

        final status = await container.read(syncControllerProvider.future);
        expect(status.lastFailure, SyncFailureCause.accessRefused);
        expect(status.health, SyncHealth.accessRefused);
        expect(status.unavailable, isNull);
        // And nothing was undone: still linked, cursor kept.
        expect(await store.isProjectLinked('proj-1'), isTrue);
        expect(await store.cursor('proj-1'), 42);
      },
    );

    test('a refusal while we are still a member changes nothing', () async {
      // The half that keeps this narrow. A `403` is also what a member
      // *removed by an owner* sees, and their membership row still reads open
      // because the pull that would have closed it is the thing being refused.
      // Unlinking on the refusal alone would quietly stop syncing a project
      // somebody may be about to be re-added to.
      final container = refusedContainer();
      addTearDown(container.dispose);
      await seed(container, stillAMember: true);

      await container.read(syncControllerProvider.future);
      await container.read(syncControllerProvider.notifier).syncNow();

      expect(
        await container.read(syncStateStoreProvider).isProjectLinked('proj-1'),
        isTrue,
      );
    });

    test(
      'and it says the server refused, rather than that sync is broken',
      () async {
        // The third of the four states this task's classification had to
        // separate. A member removed by an owner whose device has not pulled
        // the news gets exactly this, and "sync has failed repeatedly,
        // contact whoever manages your server" is the wrong instruction for
        // it — the server is working, and it is answering a question about
        // authorization.
        final container = refusedContainer();
        addTearDown(container.dispose);
        await seed(container, stillAMember: true);

        await container.read(syncControllerProvider.future);
        await container.read(syncControllerProvider.notifier).syncNow();

        final status = await container.read(syncControllerProvider.future);
        expect(status.lastFailure, SyncFailureCause.accessRefused);
        expect(status.health, SyncHealth.accessRefused);
      },
    );

    test(
      'a good round on a device that cannot read its own membership rows '
      'is still a good round (task 11.335)',
      () async {
        // `_signedInPersonHasLeft` promises that a question it cannot answer
        // answers **no**. It used to `return _weHaveLeft(...)` from inside
        // its `try` without `await`, so a failure of that Future skipped its
        // `catch` and surfaced in the round instead: a person whose sync had
        // just succeeded would have been shown a failure about a project they
        // are on. `_weHaveLeft` has a catch of its own today, so nothing in
        // the current code can fail that Future — which makes this a guard on
        // the *promise* rather than a repro of a live fault. It was watched
        // red by giving `_weHaveLeft` a way to fail during a round (see the
        // task 11.335 entry in `TASK_COMMS.md`) and removing the `await`.
        final container = containerAnswering(
          MockClient((request) async {
            final body = request.body.isEmpty
                ? <String, Object?>{}
                : jsonDecode(request.body) as Map<String, Object?>;
            Map<String, Object?> answer() => switch (request.url.path) {
              '/sync/push' => SyncPushResponse(
                applied: 0,
                outcomes: const {},
                highestServerSeq: 42,
              ).toJson(),
              '/sync/pull' => SyncPullResponse(
                rows: const {},
                nextCursor: body['cursor'] as int,
                remaining: 0,
              ).toJson(),
              _ => const SyncEnvelope().toJson(),
            };
            return http.Response(
              jsonEncode(answer()),
              200,
              headers: const {'content-type': 'application/json'},
            );
          }),
          // The sync round reads the database directly; it is the
          // controller's own question that goes through this repository, so
          // this fails that question and nothing else.
          alsoOverride: [
            projectMembershipRepositoryProvider.overrideWith(
              (ref) async => throw StateError('membership rows unreadable'),
            ),
          ],
        );
        addTearDown(container.dispose);
        await seed(container, stillAMember: true);
        await container.read(syncControllerProvider.future);

        await container.read(syncControllerProvider.notifier).syncNow();

        final status = await container.read(syncControllerProvider.future);
        expect(status.lastFailure, isNull);
        expect(status.unavailable, isNull);
        expect(status.lastError, isNull);
      },
    );
  });

  group('dismissStaleness (task 11.114)', () {
    test(
      'persists the dismissal so a fresh build (a restart) still honours it',
      () async {
        final container = makeContainer();
        addTearDown(container.dispose);
        await container
            .read(serverConfigProvider.notifier)
            .setUrl('http://192.168.1.42:8080');
        await container.read(syncControllerProvider.future);
        await container.read(syncControllerProvider.notifier).dismissStaleness();

        final dismissedAt = await container
            .read(syncStateStoreProvider)
            .staleDismissedAt();
        expect(dismissedAt, isNotNull);
        expect(
          DateTime.now().toUtc().difference(dismissedAt!).inMinutes,
          lessThan(1),
        );
      },
    );
  });

  /// **The classification itself** (task 11.54).
  ///
  /// Unit tests rather than provider ones, because the point of pulling this
  /// out of `SyncController` was that "why did this fail" stopped being
  /// reconstructed from three fields at the moment somebody rendered it.
  group('classifySyncFailure', () {
    test('a socket-level failure is "no network"', () {
      expect(
        classifySyncFailure(
          const SyncTransportException(SyncTransportException.unreachable),
          departed: false,
        ),
        SyncFailureCause.unreachable,
      );
    });

    test('a body this app cannot read is not "no network"', () {
      // Both arrive with no status code, and before this they were told apart
      // by nothing at all.
      expect(
        classifySyncFailure(
          const SyncTransportException('malformed_response'),
          departed: false,
        ),
        SyncFailureCause.serverRejected,
      );
    });

    test('a 403 splits on whether this device says the person has left', () {
      // `departed` is `ProjectMembershipRepository.hasDeparted`'s answer — a
      // closed row and no open one. **Not** "no open row" (task 11.305):
      // that is also true of somebody with no row at all, and the round that
      // read it as a departure unlinked another account's project. The
      // three-state derivation itself is pinned in `has_departed_test.dart`;
      // this is only the split.
      const refusal = SyncTransportException(
        SyncTransportException.serverRejected,
        statusCode: 403,
      );
      expect(
        classifySyncFailure(refusal, departed: true),
        SyncFailureCause.membershipEnded,
      );
      expect(
        classifySyncFailure(refusal, departed: false),
        SyncFailureCause.accessRefused,
      );
    });

    test('a 401 is a session end whatever the membership says', () {
      // Checked before the 403 split on purpose: a revoked session is refused
      // on every project, so reading it as a project-level refusal would tell
      // somebody they had been removed from a project they are still on.
      expect(
        classifySyncFailure(
          const SyncTransportException('unauthorized', statusCode: 401),
          departed: true,
        ),
        SyncFailureCause.sessionEnded,
      );
    });

    test('a refusal carrying its own remedy keeps it', () {
      expect(
        classifySyncFailure(
          const SyncTransportException(
            syncRefusalSchemaVersion,
            statusCode: 409,
            detail: {'client_schema_major': 1, 'server_schema_major': 2},
          ),
          departed: false,
        ),
        SyncFailureCause.refusedWithRemedy,
      );
    });
  });
}

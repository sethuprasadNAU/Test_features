import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sync/remembered_sync_failure.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **The sync bar must not forget it was failing** (task 11.116).
///
/// Before this, `SyncController.build` restored only the frequency setting and
/// the last-attempt stamp. The failure cause and the failure count lived in
/// memory alone, so an ongoing, genuine refusal became a calm "Synced" bar on
/// **every app restart and every rebuild of the provider** — and a phone
/// reclaiming a backgrounded app is a restart, so a device whose sync had been
/// refused for a week could show a calm bar several times a day.
///
/// The tests below are written against the two events that reset it: a fresh
/// `ProviderContainer` over the same database and preferences (a restart), and
/// `invalidate` on the same container (a rebuild, which does not need the app
/// to close at all).
void main() {
  setUp(installFakeSharedPreferences);

  group('a failure written down survives a restart', () {
    late AppDatabase db;

    setUp(() async {
      db = await AppDatabase.openInMemory();
    });

    tearDown(() => db.close());

    /// A container whose every request is answered `500`.
    ///
    /// Deliberately **not** the `403` the neighbouring suite uses: a refusal
    /// after leaving a project is derived from the membership rows on every
    /// build and was already durable, so it could not show this defect. A
    /// server fault is the ordinary ongoing failure — the one that lived only
    /// in memory.
    ProviderContainer container() => ProviderContainer(
      overrides: [
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
        serverHttpClientProvider.overrideWith(
          (ref) async => MockClient(
            (_) async => http.Response('{"error":"boom"}', 500),
          ),
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

    Future<void> seedDatabase() async {
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
        'end_date': null,
        'role': 'contributor',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': 'user-1',
        'origin_device_id': 'device-A',
      });
    }

    Future<ProviderContainer> open() async {
      final c = container();
      addTearDown(c.dispose);
      await c
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      await c.read(activeProjectIdProvider.notifier).set('proj-1');
      await c.read(syncStateStoreProvider).markProjectLinked('proj-1');
      await c.read(syncControllerProvider.future);
      return c;
    }

    /// Fails [times] rounds in a row, as one continuous run of bad luck.
    Future<void> failRepeatedly(ProviderContainer c, int times) async {
      for (var i = 0; i < times; i++) {
        await c.read(syncControllerProvider.notifier).syncNow();
      }
    }

    test(
      'restarting the app mid-failure does not produce a calm bar',
      () async {
        // **This is the finding, as a test.** Three refusals in a row is
        // "broken" — the one state worth alarming somebody over. Before this
        // task, closing and reopening the app turned that into
        // `SyncHealth.healthy` with a "Synced" line, having just been told
        // three times that nothing was getting through.
        await seedDatabase();
        final first = await open();
        await failRepeatedly(first, 3);
        expect(
          (await first.read(syncControllerProvider.future)).health,
          SyncHealth.broken,
          reason: 'the live session must see the failure it was just told',
        );

        // A brand-new container over the same database and the same
        // preferences: an app restart.
        final second = await open();
        final status = await second.read(syncControllerProvider.future);

        expect(status.health, isNot(SyncHealth.healthy));
        expect(status.health, SyncHealth.broken);
        expect(status.remembered?.consecutiveFailures, 3);
        expect(status.remembered?.cause, SyncFailureCause.serverRejected);
      },
    );

    test('and neither does a rebuild of the provider', () async {
      // The cheaper half of the same defect, and the reason it happens
      // several times a day rather than once: a rebuild does not need the app
      // to close, or even to leave the foreground.
      await seedDatabase();
      final c = await open();
      await failRepeatedly(c, 3);

      c.invalidate(syncControllerProvider);
      final status = await c.read(syncControllerProvider.future);

      expect(status.health, SyncHealth.broken);
      expect(status.remembered?.consecutiveFailures, 3);
    });

    test(
      'a restored failure says it has not been re-tested, and a live one does '
      'not',
      () async {
        // **The decision this task had to make, as a test.** A remembered
        // failure is shown — discarding it is the defect — but it is shown as
        // remembered, because "the server is refusing us" and "the server was
        // refusing us when we last tried" are different facts to somebody
        // deciding whether to walk half a mile for signal.
        await seedDatabase();
        final first = await open();
        await failRepeatedly(first, 1);
        expect(
          (await first.read(syncControllerProvider.future))
              .failureIsRemembered,
          isFalse,
          reason: 'this session tried; the failure is current, not remembered',
        );

        final second = await open();
        final status = await second.read(syncControllerProvider.future);
        expect(status.failureIsRemembered, isTrue);
        // And the severity is not softened along with the tense: one failure
        // was "offline" before the restart and is still "offline" after it.
        expect(status.health, SyncHealth.offline);
      },
    );

    test('the count keeps going across a restart, rather than restarting', () async {
      // Two failures, a restart, one more: three, and therefore broken.
      // Before this the counter reset with the process, so the threshold that
      // separates a dead zone from a fault could only ever be reached inside
      // one uninterrupted session — a device refused every hour for a week
      // reported a single transient blip for as long as it kept being
      // relaunched.
      await seedDatabase();
      final first = await open();
      await failRepeatedly(first, 2);
      expect(
        (await first.read(syncControllerProvider.future)).health,
        SyncHealth.offline,
      );

      final second = await open();
      await failRepeatedly(second, 1);
      final status = await second.read(syncControllerProvider.future);
      expect(status.remembered?.consecutiveFailures, 3);
      expect(status.health, SyncHealth.broken);
    });

    test('the round that succeeds is the one that forgets it', () async {
      // The mirror defect: a bar reporting a refusal the server has stopped
      // making is as wrong as one reporting none while it continues.
      //
      // Asserted against `SyncEngine` rather than the provider, because the
      // clearing is deliberately written on the same line as the success
      // stamp — so that **every** caller of the engine forgets the failure at
      // the moment it stops being true, including a round for a project that
      // is not the open one. A provider-level test would only prove it for
      // the one call site the provider makes.
      final store = SyncStateStore(prefs: SharedPreferencesAsync());
      await store.setRememberedFailure(
        'proj-1',
        RememberedSyncFailure(
          cause: SyncFailureCause.serverRejected,
          consecutiveFailures: 5,
          recordedAt: DateTime.utc(2026, 8, 25),
        ),
      );

      await SyncEngine(
        db: db.raw,
        transport: FakeSyncTransport(),
        state: store,
        deviceId: 'device-A',
        userId: 'user-1',
      ).run('proj-1');

      expect(
        await store.rememberedFailure('proj-1'),
        isNull,
        reason: 'a later restart must not resurrect it',
      );
      expect(await store.lastSuccessAt('proj-1'), isNotNull);
    });

    test('leaving a project forgets its remembered failure', () async {
      // `SyncStateStore.clear` is what the leave path calls once the server
      // confirms the departure (not sign-out — task 11.304 measured that and
      // `sign_out_leaves_sync_state_test.dart` holds it). A device that later
      // rejoins must not be told its sync is broken on the strength of a
      // refusal from before it left.
      await seedDatabase();
      final c = await open();
      await failRepeatedly(c, 2);

      await c.read(syncStateStoreProvider).clear('proj-1');

      expect(
        await c.read(syncStateStoreProvider).rememberedFailure('proj-1'),
        isNull,
      );
    });

    test(
      'changing the sync frequency mid-failure does not produce a calm bar '
      '(task 11.117)',
      () async {
        // The second instance task 11.117 found, discovered by accident while
        // fixing the first: `setFrequency`'s rebuild listed every field but
        // the failure ones, so tapping the frequency control on the sync
        // screen reset a broken bar to healthy with no restart involved at
        // all — the cheapest possible way to reach this defect.
        await seedDatabase();
        final c = await open();
        await failRepeatedly(c, 3);
        expect(
          (await c.read(syncControllerProvider.future)).health,
          SyncHealth.broken,
        );

        await c
            .read(syncControllerProvider.notifier)
            .setFrequency(SyncFrequency.hourly);

        final status = await c.read(syncControllerProvider.future);
        expect(
          status.health,
          SyncHealth.broken,
          reason:
              'changing a setting is not evidence the server started '
              'answering',
        );
        expect(status.remembered?.consecutiveFailures, 3);
        expect(status.schedule.frequency, SyncFrequency.hourly);
      },
    );
  });

  /// The durable record on its own, without a provider around it.
  group('RememberedSyncFailure', () {
    test('survives a round trip through storage', () {
      final at = DateTime.utc(2026, 8, 25, 14, 30);
      final decoded = RememberedSyncFailure.decode(
        RememberedSyncFailure(
          cause: SyncFailureCause.certificateRejected,
          consecutiveFailures: 4,
          stoppedReason: 'unauthorized',
          recordedAt: at,
        ).encode(),
      );
      expect(decoded, isNotNull);
      expect(decoded!.cause, SyncFailureCause.certificateRejected);
      expect(decoded.consecutiveFailures, 4);
      expect(decoded.stoppedReason, 'unauthorized');
      expect(decoded.recordedAt, at);
    });

    test('every cause has a distinct stable id, and every id reads back', () {
      // The stored id is what a renamed Dart value would silently break, and
      // breaking it resets the bar to calm — the defect this task closes. A
      // duplicate id would do the same to whichever cause lost the race.
      final ids = SyncFailureCause.values.map((c) => c.id).toSet();
      expect(ids.length, SyncFailureCause.values.length);
      for (final cause in SyncFailureCause.values) {
        expect(SyncFailureCause.fromId(cause.id), cause);
      }
    });

    test('an unreadable record reads as no memory at all', () {
      // Null rather than a partial record, in every direction: a cause with
      // no count behind it is a calm bar wearing a failure's clothes, and the
      // cost of null is one round trip on the next foreground.
      expect(RememberedSyncFailure.decode(null), isNull);
      expect(RememberedSyncFailure.decode('not json'), isNull);
      expect(RememberedSyncFailure.decode('{}'), isNull);
      expect(
        RememberedSyncFailure.decode('{"cause":"a_cause_from_the_future",'
            '"consecutive_failures":2,"recorded_at":"2026-08-25T00:00:00Z"}'),
        isNull,
      );
      expect(
        RememberedSyncFailure.decode(
          '{"cause":"unreachable","recorded_at":"2026-08-25T00:00:00Z"}',
        ),
        isNull,
      );
      expect(
        RememberedSyncFailure.decode(
          '{"cause":"unreachable","consecutive_failures":2}',
        ),
        isNull,
      );
    });

    test('the threshold for "broken" is read from the durable count', () {
      RememberedSyncFailure at(int failures) => RememberedSyncFailure(
        cause: SyncFailureCause.unreachable,
        consecutiveFailures: failures,
        recordedAt: DateTime.utc(2026, 8, 25),
      );
      expect(at(brokenAfterFailures - 1).looksBroken, isFalse);
      expect(at(brokenAfterFailures).looksBroken, isTrue);
      // A terminal stop is enough on its own, whatever the count.
      expect(
        RememberedSyncFailure(
          cause: SyncFailureCause.refusedWithRemedy,
          consecutiveFailures: 1,
          stoppedReason: 'version_unsupported',
          recordedAt: DateTime.utc(2026, 8, 25),
        ).looksBroken,
        isTrue,
      );
    });
  });
}

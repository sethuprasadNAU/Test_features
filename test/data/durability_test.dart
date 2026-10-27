import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/fake_session_store.dart';
import '../support/fake_shared_preferences.dart';
import 'sync/fake_sync_transport.dart';

/// Task 10.19's invariant: **no failure path deletes local data.** A version
/// mismatch, a denied push, a revoked or expired session, and a local sign-out
/// all leave the field record untouched — stated as a guarantee in several
/// doc comments already (`SyncSchemaVersionException`, `CurrentSession.
/// signOut`), proven here so a future change that quietly adds a `DELETE`
/// somewhere in one of these paths fails a test instead of shipping.
///
/// Sync's own "an unreachable server changes nothing locally" is already
/// covered by `sync_engine_test.dart`; this file covers the refusal shapes
/// that one doesn't — a *terminal* version refusal and an authorization
/// denial — plus the two paths that don't go through `SyncEngine` at all.
void main() {
  group('a terminal version refusal changes nothing locally', () {
    late AppDatabase appDb;
    late FakeSyncTransport transport;
    late SyncStateStore state;
    const projectId = 'proj-1';

    setUp(() async {
      installFakeSharedPreferences();
      appDb = await AppDatabase.openInMemory();
      transport = FakeSyncTransport();
      state = SyncStateStore(prefs: SharedPreferencesAsync());
      final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));
      await appDb.raw.insert(Tables.users, {
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
      await appDb.raw.insert(Tables.projects, {
        'project_id': projectId,
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
    });

    tearDown(() => appDb.close());

    SyncEngine engine() => SyncEngine(
      db: appDb.raw,
      transport: transport,
      state: state,
      deviceId: 'device-A',
      userId: 'user-1',
    );

    test('a schema-version refusal leaves every local row exactly as it was',
        () async {
      final usersBefore = await appDb.raw.query(Tables.users);
      final projectsBefore = await appDb.raw.query(Tables.projects);

      transport.permanentFailure = const SyncTransportException(
        syncRefusalSchemaVersion,
        statusCode: 409,
        detail: {'client_schema_version': 5, 'server_schema_version': 6},
      );

      await expectLater(
        engine().run(projectId),
        throwsA(
          isA<SyncTransportException>().having((e) => e.isTerminal, 'isTerminal', isTrue),
        ),
      );

      expect(await appDb.raw.query(Tables.users), usersBefore);
      expect(await appDb.raw.query(Tables.projects), projectsBefore);
    });

    test('an authorization denial (membership removed) leaves local rows '
        'exactly as they were', () async {
      final usersBefore = await appDb.raw.query(Tables.users);
      final projectsBefore = await appDb.raw.query(Tables.projects);

      // 403 is what a removed membership looks like from the client's side —
      // the server's `RowAuthorizer`/`ProjectAuthorizer` refusing rather than
      // a version or cursor problem.
      transport.permanentFailure = const SyncTransportException(
        'server_rejected',
        statusCode: 403,
      );

      await expectLater(
        engine().run(projectId),
        throwsA(
          isA<SyncTransportException>().having((e) => e.isTerminal, 'isTerminal', isTrue),
        ),
      );

      expect(await appDb.raw.query(Tables.users), usersBefore);
      expect(await appDb.raw.query(Tables.projects), projectsBefore);
    });
  });

  group('session lifecycle changes nothing locally', () {
    setUp(installFakeSharedPreferences);

    ProviderContainer makeContainer(AppDatabase db, SessionStore sessionStore) =>
        ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) async => db),
            sessionStoreProvider.overrideWithValue(sessionStore),
          ],
        );

    Future<void> seedLocalProject(AppDatabase db) async {
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
    }

    test('a locally-expired session is dropped without touching the '
        'database', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      await seedLocalProject(db);
      final before = await db.raw.query(Tables.users);

      final expired = StoredSession(
        token: 'expired-token',
        userId: 'user-1',
        email: 'sam@example.com',
        expiresAt: DateTime.utc(2020, 1, 1),
      );
      final container = makeContainer(db, FakeSessionStore(expired));
      addTearDown(container.dispose);
      await container.read(serverConfigProvider.notifier).setUrl(
        'http://test.local',
      );

      final session = await container.read(currentSessionProvider.future);
      expect(session, isNull, reason: 'the expired session must be dropped');
      expect(await db.raw.query(Tables.users), before);
    });

    test('signOut clears the session but removes nothing from the database',
        () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      await seedLocalProject(db);
      final before = await db.raw.query(Tables.users);

      final active = StoredSession(
        token: 'active-token',
        userId: 'user-1',
        email: 'sam@example.com',
        expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
      );
      final sessionStore = FakeSessionStore(active);
      final container = makeContainer(db, sessionStore);
      addTearDown(container.dispose);
      // No server configured — signOut's own doc comment says this must not
      // trap anyone in a signed-in state, so it has to complete regardless.
      await container.read(currentSessionProvider.future);

      await container.read(currentSessionProvider.notifier).signOut();

      expect(container.read(currentSessionProvider).value, isNull);
      expect(await sessionStore.read(), isNull);
      // The point of the test: local data survives sign-out untouched.
      expect(await db.raw.query(Tables.users), before);
    });
  });
}

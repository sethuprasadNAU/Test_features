import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/project_publisher.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// **A device pointed at a restored or rebuilt server used to report a clean
/// sync and deliver nothing, in both directions** — task 11.51, reproduced by
/// task 11.54 in this file, and fixed by task 11.58.
///
/// ## What was reproduced here, and what it still is not
///
/// The *mechanism*, at the engine, against the fake transport every client
/// sync test uses. It is **not** a run against a live server brought back
/// with its volumes removed or restored from an archive; the server half is
/// pinned by `server/test/sync/database_identity_test.dart` and by
/// `scripts/backup_restore_drill.sh`'s check that a restore does not inherit
/// the identifier, and nothing yet puts the two halves together over the
/// network.
///
/// ## The mechanism, and the fix
///
/// The bookmark — "I have read this server's records up to 4,812" — and the
/// row receipts — "the server has this row" — were both kept per project, and
/// nothing beside them said **which database** they were about. Point the app
/// at a database whose numbering starts again at 1 and it asks for "anything
/// after 4,812", is told "nothing", and reports success; and its receipts keep
/// every row the old database once confirmed off the push, which, unlike the
/// bookmark, never heals.
///
/// The server now names its database on every push and pull (a value minted
/// once, and not carried across a restore). The device keeps that name beside
/// the bookmark, and when an answer names a different one it forgets the
/// bookmark, the receipts and the holds, and runs the round again from the
/// top. The tests below are the three original findings turned round, plus
/// the edges the fix has — including the two it cannot see, pinned so nobody
/// mistakes them for covered.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 8, 1, 12);
  final stamp = DbCodec.encodeUtc(now);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport()..databaseId = 'old-database';
    state = SyncStateStore(prefs: SharedPreferencesAsync());
    await appDb.raw.insert(Tables.users, {
      'user_id': userId,
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
    });
    await appDb.raw.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Elk',
      'owner_user_id': userId,
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': 0,
      'last_modified_by': userId,
      'origin_device_id': deviceId,
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
  });

  tearDown(() => appDb.close());

  SyncEngine engine() => SyncEngine(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  Map<String, Object?> observation(String id) => {
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
    'origin_device_id': deviceId,
  };

  String obsKey(String id) => '$id/$projectId';

  Future<bool> onDevice(String id) async => (await appDb.raw.query(
    Tables.observations,
    where: 'observation_id = ?',
    whereArgs: [id],
  )).isNotEmpty;

  test(
    'a bookmark from the old database no longer makes a rebuilt server look '
    'empty: the device starts over and the teammate\'s bearing arrives',
    () async {
      // A season against the old database: three bearings, so this device's
      // bookmark is past 1, 2 and 3 in the old numbering.
      for (final id in ['obs-a', 'obs-b', 'obs-c']) {
        transport.seedServerRow(Tables.observations, observation(id));
      }
      await engine().run(projectId);
      final oldCursor = await state.cursor(projectId);
      expect(oldCursor, greaterThanOrEqualTo(3));
      expect(await state.databaseId(projectId), 'old-database');

      // Rebuilt. The new database's numbering starts again at 1, and a
      // teammate's bearing is its first row — at a number *below* this
      // device's bookmark, which is the whole of the original finding.
      transport.replaceDatabase('new-database');
      transport.seedServerRow(Tables.observations, observation('obs-remote'));

      final report = await engine().run(projectId);

      expect(report.serverDatabaseChanged, isTrue);
      expect(
        await onDevice('obs-remote'),
        isTrue,
        reason: 'before task 11.58 the device asked the new database for '
            'rows after $oldCursor, was told there were none, and reported '
            'success',
      );
      expect(await state.databaseId(projectId), 'new-database');
      // The status screen's sentence reads this; a restore it cannot date is
      // a restore it cannot mention.
      expect(await state.databaseChangedAt(projectId), isNotNull);
    },
  );

  test(
    'a receipt from the old database no longer keeps a local row off the '
    'new one',
    () async {
      await appDb.raw.insert(Tables.observations, observation('obs-local'));
      await engine().run(projectId);
      // Delivered to the old database, and receipted for it.
      expect(
        await SyncRowReceiptStore(appDb.raw).ackedUpdatedAt(
          projectId: projectId,
          tableName: Tables.observations,
          rowKey: obsKey('obs-local'),
        ),
        stamp,
      );

      transport.replaceDatabase('new-database');
      await engine().run(projectId);

      // The half that never healed: a stale receipt is never contradicted by
      // anything the new database sends, so without the reset this row stayed
      // on this device alone for good.
      expect(
        transport.serverRow(Tables.observations, obsKey('obs-local')),
        isNotNull,
        reason: 'the row is on this device and nowhere else, and was '
            'considered delivered — to a database that no longer exists',
      );
    },
  );

  test('a hold the old database earned no longer keeps a row off the new '
      'one', () async {
    // The third statement about one database that task 11.58's brief did not
    // name: "that server would not take this row". Found by asking which of
    // the device's stores describe the server rather than the device.
    await appDb.raw.insert(Tables.observations, observation('obs-held'));
    transport.refuseRows['${Tables.observations}/${obsKey('obs-held')}'] =
        SyncRowOutcome.unauthorized;
    await engine().run(projectId);
    expect(await SyncHeldRowStore(appDb.raw).heldCount(projectId), 1);

    transport
      ..replaceDatabase('new-database')
      ..refuseRows.clear();
    final report = await engine().run(projectId);

    expect(
      transport.serverRow(Tables.observations, obsKey('obs-held')),
      isNotNull,
    );
    expect(report.heldCount, 0);
  });

  test('the same database answering again changes nothing', () async {
    // The steady state, and the reason a reset must be keyed on a *change*:
    // a device that re-fetched the project every round would be worse than
    // the defect.
    transport.seedServerRow(Tables.observations, observation('obs-a'));
    await engine().run(projectId);
    final cursor = await state.cursor(projectId);
    final pulls = transport.pullCalls;

    final report = await engine().run(projectId);

    expect(report.serverDatabaseChanged, isFalse);
    expect(await state.cursor(projectId), cursor);
    expect(report.pulled, 0);
    expect(transport.pullCalls, pulls + 1);
    expect(await state.databaseChangedAt(projectId), isNull);
  });

  test(
    'two databases answering at one address is a failure, and has a cause',
    () async {
      // Not a restore: the round that had just started over meets a third
      // answer. This is the only way the cause is reachable, and it is
      // reachable — which is what task 11.54 asked of it.
      await state.setDatabaseId(projectId, 'database-A');
      await appDb.raw.insert(Tables.observations, observation('obs-local'));
      var flip = false;
      transport.databaseIdPerResponse = () =>
          (flip = !flip) ? 'database-B' : 'database-A';

      Object? thrown;
      try {
        await engine().run(projectId);
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isA<SyncTransportException>());
      final error = thrown! as SyncTransportException;
      expect(error.reason, SyncTransportException.serverDatabaseChanged);
      expect(error.isTerminal, isFalse, reason: 'the fix is on the server');
      expect(
        classifySyncFailure(error, departed: false),
        SyncFailureCause.serverDatabaseChanged,
      );
      expect(error.userMessage, contains('two different servers'));
    },
  );

  test('a server that does not say which database it is concludes nothing',
      () async {
    // Task 10.18's newer-app-older-server direction. Null is "cannot say",
    // and a device that reset on it would re-fetch the project on every round
    // against every server not yet updated.
    await state.setDatabaseId(projectId, 'database-A');
    await state.setCursor(projectId, 7);
    transport.databaseId = null;

    final report = await engine().run(projectId);

    expect(report.serverDatabaseChanged, isFalse);
    expect(await state.databaseId(projectId), 'database-A');
    expect(await state.cursor(projectId), 7);
  });

  test(
    'LIMIT, pinned: a device with nothing stored adopts whatever answers — so '
    'a server replaced before the device updated is still invisible',
    () async {
      // Every linked project on its first round after this build installs.
      // It has nothing to compare with, and guessing "changed" would re-fetch
      // every project on every device on update day. What this costs is the
      // original finding, for a server replaced *before* the update: pinned
      // so that nobody reads the fix as covering it.
      await state.setCursor(projectId, 4812);
      transport.databaseId = 'new-database';
      transport.seedServerRow(Tables.observations, observation('obs-remote'));

      final report = await engine().run(projectId);

      expect(report.serverDatabaseChanged, isFalse);
      expect(await state.databaseId(projectId), 'new-database');
      expect(await onDevice('obs-remote'), isFalse);
    },
  );

  test(
    'unlinking keeps the identifier with the receipts, so a rejoin against a '
    'different database is noticed',
    () async {
      // `SyncStateStore.clear` keeps the receipts (a rejoin should not
      // re-upload a project the server already has). The identifier is what
      // says which server "already has" means, so it has to stay with them —
      // cleared alone, it would be the one combination that could not tell.
      await appDb.raw.insert(Tables.observations, observation('obs-local'));
      await engine().run(projectId);
      await state.clear(projectId);
      expect(await state.databaseId(projectId), 'old-database');

      transport.replaceDatabase('new-database');
      await state.markProjectLinked(projectId);
      await engine().run(projectId);

      expect(
        transport.serverRow(Tables.observations, obsKey('obs-local')),
        isNotNull,
      );
    },
  );

  test(
    're-publishing onto a different database forgets the old one\'s receipts',
    () async {
      // The other writer of receipts. A publish sends every row whatever the
      // receipts say, so the harm is narrower: a row the *new* database
      // refuses keeps the old database's receipt, and when somebody later
      // taps "Try again" that receipt still matches and the row is never
      // offered. Only reachable after an unlink, which is why the identifier
      // survives one.
      await appDb.raw.insert(Tables.observations, observation('obs-local'));
      await engine().run(projectId);
      await state.clear(projectId);

      transport.replaceDatabase('new-database');
      transport.refuseRows['${Tables.observations}/${obsKey('obs-local')}'] =
          SyncRowOutcome.unauthorized;
      await ProjectPublisher(
        db: appDb.raw,
        transport: transport,
        state: state,
        deviceId: deviceId,
        userId: userId,
      ).publish(projectId, now: now);

      expect(await state.databaseId(projectId), 'new-database');
      expect(
        await SyncRowReceiptStore(appDb.raw).ackedUpdatedAt(
          projectId: projectId,
          tableName: Tables.observations,
          rowKey: obsKey('obs-local'),
        ),
        isNull,
        reason: 'the old database\'s receipt would keep this row off every '
            'push after a retry',
      );
      // A publish is somebody's own act, not news about the server.
      expect(await state.databaseChangedAt(projectId), isNull);
    },
  );

  test(
    'the sync bookkeeping now records which database it belongs to, and '
    'every key is still per project',
    () async {
      // This test used to assert the absence: "if a server identity is ever
      // added, this test is the thing that has to change". It was added.
      await engine().run(projectId);
      await state.setLastSuccessAt(projectId, now);
      await state.markProjectLinked(projectId);

      final keys = await SharedPreferencesAsync().getKeys();
      expect(keys, contains('sync_database_id_v1_$projectId'));
      for (final key in keys) {
        expect(key.endsWith(projectId), isTrue, reason: key);
      }
    },
  );
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/project_publisher.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// Task 10.9's publish acceptance criteria, against a fake transport
/// (Phase 10's invariant 5): publishing an offline-created project uploads it
/// in full, publishing twice is a no-op the second time, and a large project
/// is chunked without violating the server's foreign-key order.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 8, 1, 12);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
    state = SyncStateStore(prefs: SharedPreferencesAsync());
    await _seedProject(appDb, now: now);
  });

  tearDown(() => appDb.close());

  ProjectPublisher publisher() => ProjectPublisher(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  Future<void> insertObservation(String id) => appDb.raw.insert(
    Tables.observations,
    _observation(id, projectId: projectId, userId: userId, now: now),
  );

  test('uploads the whole project and marks it linked', () async {
    await insertObservation('obs-1');
    await insertObservation('obs-2');

    final report = await publisher().publish(projectId, now: now);

    expect(report.alreadyLinked, isFalse);
    // Users + Projects + 2 observations.
    expect(report.rowsUploaded, 4);
    expect(await state.isProjectLinked(projectId), isTrue);
    expect(transport.serverRow('Observations', _obsKey('obs-1')), isNotNull);
    expect(transport.serverRow('Observations', _obsKey('obs-2')), isNotNull);
    expect(transport.serverRow('Projects', projectId), isNotNull);
  });

  test('publishing an already-linked project is a no-op', () async {
    await insertObservation('obs-1');
    await publisher().publish(projectId, now: now);
    final pushesAfterFirst = transport.pushCalls;

    final second = await publisher().publish(projectId, now: now);

    expect(second.alreadyLinked, isTrue);
    expect(second.rowsUploaded, 0);
    expect(transport.pushCalls, pushesAfterFirst);
  });

  test('chunks uploads while preserving FK-safe table order', () async {
    for (var i = 0; i < 5; i++) {
      await insertObservation('obs-$i');
    }

    await publisher().publish(projectId, now: now, batchSize: 2);

    expect(transport.pushCalls, greaterThan(1));
    // Every table referenced by an early push must already exist on the
    // server by the time a later push references it — in particular, Users
    // and Projects (parents) must land before any Observations (children)
    // that reference them, even though each push is its own transaction.
    for (final push in transport.pushes) {
      if (push.rows.containsKey('Observations')) {
        expect(transport.serverRow('Users', userId), isNotNull);
        expect(transport.serverRow('Projects', projectId), isNotNull);
      }
    }
    expect(transport.serverRowCount, 2 + 5); // user + project + 5 observations
    expect(await state.isProjectLinked(projectId), isTrue);
  });

  group('a refused row is never silently lost (finding D-3, task 10.28)', () {
    // Publish had the same hole the sync engine did, reached by the *first*
    // thing a user does with a server: it ignored per-row outcomes entirely,
    // marked the project linked, set the watermark to the moment of upload —
    // past every refused row — and reported a count of rows "uploaded" that was
    // really a count of rows sent.
    final refusedKey = '${Tables.observations}/${_obsKey('obs-refused')}';

    test('the refusal is reported and the row is held', () async {
      await insertObservation('obs-refused');
      await insertObservation('obs-ok');
      transport.refuseRows[refusedKey] = SyncRowOutcome.unauthorized;

      final report = await publisher().publish(projectId, now: now);

      expect(report.everythingReachedTheServer, isFalse);
      expect(report.refused, hasLength(1));
      expect(report.refused.single.outcomeKey, refusedKey);
      expect(report.refused.single.reason, HeldRowReason.notPermitted);
      expect(await SyncHeldRowStore(appDb.raw).heldCount(projectId), 1);

      // The row is on this device and nowhere else...
      expect(transport.serverRow(Tables.observations, _obsKey('obs-refused')), isNull);
      expect(
        await appDb.raw.query(
          Tables.observations,
          where: 'observation_id = ?',
          whereArgs: ['obs-refused'],
        ),
        hasLength(1),
      );
      // ...and the rest of the project published normally. Refusing to link
      // would leave the accepted rows unable to sync and the refused one unable
      // to ever be retried — strictly worse.
      expect(transport.serverRow(Tables.observations, _obsKey('obs-ok')), isNotNull);
      expect(await state.isProjectLinked(projectId), isTrue);
    });

    test('no progress is recorded for the refused row', () async {
      final older = now.subtract(const Duration(days: 2));
      await appDb.raw.insert(
        Tables.observations,
        _observation('obs-refused', projectId: projectId, userId: userId, now: older),
      );
      await insertObservation('obs-ok');
      transport.refuseRows[refusedKey] = SyncRowOutcome.unauthorized;

      await publisher().publish(projectId, now: now);

      // Publish used to set a single watermark to `now`, putting every refused
      // row permanently behind the selection window; task 10.28 clamped it back
      // to the earliest refusal. Task 10.33 replaced the watermark with per-row
      // receipts, so the invariant is stated directly: the refused row has none
      // and is therefore still pending, while the row beside it does.
      final receipts = SyncRowReceiptStore(appDb.raw);
      expect(
        await receipts.ackedUpdatedAt(
          projectId: projectId,
          tableName: Tables.observations,
          rowKey: _obsKey('obs-refused'),
        ),
        isNull,
      );
      expect(
        await receipts.ackedUpdatedAt(
          projectId: projectId,
          tableName: Tables.observations,
          rowKey: _obsKey('obs-ok'),
        ),
        isNotNull,
      );
      expect(
        await SyncEngine.pendingRowCount(appDb.raw, projectId, userId),
        0,
        reason: 'the refused row is held, not merely waiting',
      );
    });

    test('a fully-accepted publish reports plainly', () async {
      await insertObservation('obs-1');
      final report = await publisher().publish(projectId, now: now);

      expect(report.refused, isEmpty);
      expect(report.everythingReachedTheServer, isTrue);
      expect(await SyncHeldRowStore(appDb.raw).heldCount(projectId), 0);
    });

    test('a row the server says nothing about is held', () async {
      await insertObservation('obs-refused');
      transport.ignoreRows.add(refusedKey);

      final report = await publisher().publish(projectId, now: now);
      expect(report.refused.single.reason, HeldRowReason.unaccounted);
      expect(await SyncHeldRowStore(appDb.raw).heldCount(projectId), 1);
    });
  });

  test(
    'an interrupted publish leaves the project unlinked, retry succeeds',
    () async {
      await insertObservation('obs-1');
      transport.failNextCalls = 1;

      await expectLater(
        publisher().publish(projectId, now: now),
        throwsA(isA<SyncTransportException>()),
      );
      expect(await state.isProjectLinked(projectId), isFalse);

      final retry = await publisher().publish(projectId, now: now);
      expect(retry.alreadyLinked, isFalse);
      expect(await state.isProjectLinked(projectId), isTrue);
    },
  );

  group('a first publish of a project two people have touched (task 11.43)', () {
    // **Found on real hardware, 2026-08-27, and this group is the fix.**
    // Publishing offered the teammate's `Users` row, their address history and
    // their membership row — three records the server refuses from any device
    // but their own, every time — so the very first thing anybody does with a
    // server produced a warning about records that were never this device's to
    // send and that no action could ever clear.
    //
    // The state seeded here is what a device actually holds after a colleague
    // has been on the project: their identity, their address history, their
    // membership, and a replica of a bearing they recorded (task 6.3).
    const teammateId = 'user-2';

    setUp(() async {
      final stamp = DbCodec.encodeUtc(now);
      await appDb.raw.insert(Tables.users, {
        'user_id': teammateId,
        'first_name': 'Kim',
        'last_name': 'Ruiz',
        'email': 'kim@example.com',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': teammateId,
        'origin_device_id': 'device-B',
      });
      await appDb.raw.insert(Tables.userEmails, {
        'user_email_id': 'email-1',
        'user_id': teammateId,
        'email': 'kim.ruiz@example.com',
        'recorded_at': stamp,
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': teammateId,
        'origin_device_id': 'device-B',
      });
      await appDb.raw.insert(Tables.projectMemberships, {
        'membership_id': 'membership-1',
        'project_id': projectId,
        'user_id': teammateId,
        'join_date': stamp,
        'end_date': null,
        'role': 'contributor',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': userId,
        'origin_device_id': deviceId,
      });
    });

    /// Every `table/rowKey` the publish put on the wire.
    Set<String> offeredKeys() => {
      for (final push in transport.pushes)
        for (final entry in push.rows.entries)
          for (final row in entry.value)
            '${entry.key}/${syncRowKey(syncTablesByName[entry.key]!, row)}',
    };

    test('produces no refused record — the headline', () async {
      await insertObservation('obs-mine');

      // Armed the way the real server behaves, so a regression that starts
      // offering these rows again fails here rather than passing quietly.
      for (final key in [
        '${Tables.users}/$teammateId',
        '${Tables.userEmails}/email-1',
        '${Tables.projectMemberships}/membership-1/$projectId',
      ]) {
        transport.refuseRows[key] = SyncRowOutcome.unauthorized;
      }

      final report = await publisher().publish(projectId, now: now);

      expect(report.refused, isEmpty);
      expect(report.everythingReachedTheServer, isTrue);
      expect(await SyncHeldRowStore(appDb.raw).held(projectId), isEmpty);
    });

    test("none of the teammate's own records are offered", () async {
      await publisher().publish(projectId, now: now);
      final offered = offeredKeys();

      expect(offered, isNot(contains('${Tables.users}/$teammateId')));
      expect(offered, isNot(contains('${Tables.userEmails}/email-1')));
      expect(
        offered,
        isNot(
          contains('${Tables.projectMemberships}/membership-1/$projectId'),
        ),
      );

      // And the project itself still goes up, which is the half a filter that
      // withheld everything would also satisfy.
      expect(offered, contains('${Tables.users}/$userId'));
      expect(offered, contains('${Tables.projects}/$projectId'));
    });

    test('the next sync does not re-offer them either', () async {
      // Fixing only the publisher would have left the very next sync putting
      // the same three rows back on the wire and holding them, which is why
      // both paths read one rule.
      //
      // **The refusals are armed before the publish, and that is not
      // decoration.** Armed afterwards, this test passed with the filter
      // removed: the fake server accepted the three rows, wrote receipts, and
      // the next sync had no reason to re-offer them — so it measured nothing.
      // Armed first, the unfixed code holds them at publish and the hold
      // survives into the sync, which is the actual symptom.
      for (final key in [
        '${Tables.users}/$teammateId',
        '${Tables.userEmails}/email-1',
        '${Tables.projectMemberships}/membership-1/$projectId',
      ]) {
        transport.refuseRows[key] = SyncRowOutcome.unauthorized;
      }
      await publisher().publish(projectId, now: now);
      transport.pushes.clear();

      final report = await SyncEngine(
        db: appDb.raw,
        transport: transport,
        state: state,
        deviceId: deviceId,
        userId: userId,
      ).run(projectId);

      expect(report.heldCount, 0);
      expect(offeredKeys(), isNot(contains('${Tables.users}/$teammateId')));
    });

    test(
      "a colleague's bearing is still offered, refused and held — deliberately",
      () async {
        // The other half of the rule, and the one that must not quietly
        // change. A replica of a bearing they recorded is field data the
        // server cannot obtain any other way, so it goes up, is refused by
        // task 11.24's rule, and is held with a reason — §4.17's accepted
        // cost, which is stated in terms of the user being *told*. Withholding
        // it would be the silent omission the held-row store exists to prevent.
        await appDb.raw.insert(
          Tables.observations,
          _observation('obs-theirs', projectId: projectId, userId: teammateId,
              now: now),
        );
        transport.refuseRows['${Tables.observations}/${_obsKey('obs-theirs')}'] =
            SyncRowOutcome.unauthorized;

        final report = await publisher().publish(projectId, now: now);

        expect(
          offeredKeys(),
          contains('${Tables.observations}/${_obsKey('obs-theirs')}'),
        );
        expect(report.refused.single.tableName, Tables.observations);
        expect(report.refused.single.reason, HeldRowReason.notPermitted);
        expect(await SyncHeldRowStore(appDb.raw).held(projectId), hasLength(1));
      },
    );
  });

  test(
    "a project recording somebody else as its owner cannot be published",
    () async {
      // Reachable by restoring somebody else's `.zip` backup. Every other table
      // has a foreign key into `Projects`, so without that row the upload fails
      // partway with a constraint violation from the database — this says so
      // before anything is sent, which is the same statement the publish
      // confirmation already makes on screen (task 11.28).
      await appDb.raw.insert(Tables.users, {
        'user_id': 'somebody-else',
        'first_name': 'Kim',
        'last_name': 'Ruiz',
        'email': 'kim@example.com',
        'created_at': DbCodec.encodeUtc(now),
        'updated_at': DbCodec.encodeUtc(now),
        'revision': 0,
        'last_modified_by': 'somebody-else',
        'origin_device_id': 'device-B',
      });
      await appDb.raw.update(
        Tables.projects,
        {'owner_user_id': 'somebody-else'},
        where: 'project_id = ?',
        whereArgs: [projectId],
      );

      expect(
        () => publisher().publish(projectId, now: now),
        throwsA(isA<PublishNotYoursToMake>()),
      );
      expect(transport.pushes, isEmpty);
      expect(await state.isProjectLinked(projectId), isFalse);
    },
  );
}

Future<void> _seedProject(AppDatabase db, {required DateTime now}) async {
  final stamp = DbCodec.encodeUtc(now);
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
}

Map<String, Object?> _observation(
  String id, {
  required String projectId,
  required String userId,
  required DateTime now,
}) {
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
    'notes': 'local',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };
}

/// Since task 10.35 `Observations` is keyed `(observation_id, project_id)`, so
/// the protocol row key for one of these rows is `<id>/<project id>`.
String _obsKey(String observationId) => '$observationId/proj-1';

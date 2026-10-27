import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// Found on real hardware on 2026-08-27, the day task 11.41 shipped: a Mac
/// synced, reported **success**, and the teammate's bearings were not there.
///
/// ## What the pull was doing
///
/// `SyncEngine._pull` handed each page to `ProjectMerger` and **discarded the
/// merge report**. The merger refuses a row whose values this build's
/// `RowValidator` does not recognise, and a row scoped to a different project;
/// both are correct refusals. What was not correct is what happened next: the
/// row was counted in `SyncRunReport.pulled` (which counted rows *on the
/// wire*, and whose own doc comment said "rows merged into the local
/// database"), a receipt was written for it, the cursor was acked past it, and
/// the app reported a clean sync.
///
/// So a colleague's bearing could disappear between the wire and the database
/// with nothing said anywhere and no way to ask. That is finding D-3's asset —
/// an irreplaceable field record present in one place and reported as being in
/// two — reached from the **inbound** direction, where there was no instrument
/// of any kind.
///
/// **The most likely way to reach it is a build skew**, which is exactly the
/// state a phone and a laptop are in during development: the phone sends an
/// enum value the laptop's build has never heard of.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 8, 27, 12);
  final stamp = DbCodec.encodeUtc(now);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
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

  Map<String, Object?> observation(
    String id, {
    String signalStrength = 'strong',
    String? projectOverride,
  }) => {
    'observation_id': id,
    'project_id': projectOverride ?? projectId,
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
    'signal_strength': signalStrength,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-B',
  };

  group('a row the server sent that this build will not store', () {
    setUp(() {
      transport.seedServerRow(Tables.projects, {
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

    test('is reported, not counted as arrived', () async {
      // A value from a newer build. The row is well-formed on the wire and
      // this build simply cannot read it.
      transport.seedServerRow(
        Tables.observations,
        observation('obs-future', signalStrength: 'blisteringly_loud'),
      );

      final report = await engine().run(projectId);

      expect(
        report.droppedOnArrival,
        isNotEmpty,
        reason: 'a discarded record was reported as though it arrived',
      );
      expect(report.droppedOnArrival.single.table, Tables.observations);
      expect(report.droppedOnArrival.single.field, 'signal_strength');
      expect(
        report.everythingArrived,
        isFalse,
        reason: 'nothing may report a clean pull while a row was discarded',
      );

      // And the row genuinely is not here — the point of the whole test.
      final stored = await appDb.raw.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-future'],
      );
      expect(stored, isEmpty);
    });

    test('is not included in the count of rows stored', () async {
      transport.seedServerRow(
        Tables.observations,
        observation('obs-good'),
      );
      transport.seedServerRow(
        Tables.observations,
        observation('obs-future', signalStrength: 'blisteringly_loud'),
      );

      final report = await engine().run(projectId);

      expect(
        report.storedFromServer,
        1,
        reason: 'only one of the two rows could actually be stored',
      );
      expect(
        report.pulled,
        greaterThan(report.storedFromServer),
        reason:
            'the delivered count and the stored count must be allowed to '
            'differ — collapsing them is what hid this',
      );
    });

    test('does not make the round look like it changed something', () async {
      // `changedAnything` gates the refresh that tells the map to re-read.
      // Counting a discarded row as a change would have the map re-query for
      // nothing; counting a stored one as no change is how the map went stale
      // in the first place.
      //
      // Settle first, so the round under test is a *pull* with nothing of its
      // own to push — otherwise the push's own applied rows decide the answer
      // and the pull side is never measured.
      await engine().run(projectId);

      transport.seedServerRow(
        Tables.observations,
        observation('obs-future', signalStrength: 'blisteringly_loud'),
      );
      expect((await engine().run(projectId)).changedAnything, isFalse);

      transport.seedServerRow(Tables.observations, observation('obs-good'));
      expect((await engine().run(projectId)).changedAnything, isTrue);
    });

    // **Not covered here: the merger's other refusal branch**, which drops a
    // delivered row scoped to a different project. `FakeSyncTransport.pull`
    // filters by the project scope column exactly as the real server does, so
    // a well-behaved transport can never deliver one — the branch is a
    // defence against a *misbehaving* server, and reaching it needs a
    // deliberately hostile fake rather than this one. Recorded rather than
    // faked, because a test that had to break the fake to pass would be
    // measuring the fake.

    test('a clean round reports nothing dropped', () async {
      // The direction that keeps this from becoming noise.
      transport.seedServerRow(Tables.observations, observation('obs-good'));

      final report = await engine().run(projectId);
      expect(report.droppedOnArrival, isEmpty);
      expect(report.everythingArrived, isTrue);
      expect(report.storedFromServer, greaterThan(0));
      // Not `== pulled`: a page legitimately re-delivers rows this device
      // already has in the same or a newer version, and the merger skips
      // those. Skipped is neither stored nor dropped, and conflating it with
      // either would make this number wrong in the other direction.
      expect(report.storedFromServer, lessThanOrEqualTo(report.pulled));
    });
  });

  group('a drop survives past the round that found it (task 11.44)', () {
    setUp(() {
      transport.seedServerRow(Tables.projects, {
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

    test('the total survives a later round that drops nothing new', () async {
      transport.seedServerRow(
        Tables.observations,
        observation('obs-future', signalStrength: 'blisteringly_loud'),
      );
      final first = await engine().run(projectId);
      expect(first.droppedCount, 1);

      // Nothing new to drop this round — the old bug's blind spot exactly:
      // `droppedOnArrival` (this round's list) is empty, and before this task
      // that was the only signal the app had.
      final second = await engine().run(projectId);
      expect(second.droppedOnArrival, isEmpty);
      expect(
        second.droppedCount,
        1,
        reason: 'a round that drops nothing new must not say everything '
            'arrived while an earlier drop is still missing',
      );
      expect(second.everythingArrived, isFalse);
    });

    test(
      'the total is durable independent of any report — a fresh engine '
      'answers it the moment it is asked, the way a restarted app would',
      () async {
        transport.seedServerRow(
          Tables.observations,
          observation('obs-future', signalStrength: 'blisteringly_loud'),
        );
        await engine().run(projectId);

        // A brand-new `SyncEngine`, reading only the database — nothing
        // carried over in memory, exactly as `SyncController.build()` reads
        // it after the app reopens.
        expect(await SyncEngine.droppedRowCount(appDb.raw, projectId), 1);
      },
    );

    test('naming which record and which rule is durable, not just a count', () async {
      transport.seedServerRow(
        Tables.observations,
        observation('obs-future', signalStrength: 'blisteringly_loud'),
      );
      await engine().run(projectId);

      final rows = await appDb.raw.query(
        'Sync_Dropped_Rows',
        where: 'project_id = ? AND resolved_at_utc IS NULL',
        whereArgs: [projectId],
      );
      expect(rows, hasLength(1));
      expect(rows.single['table_name'], Tables.observations);
      expect(rows.single['field'], 'signal_strength');
      expect(rows.single['message'], contains('blisteringly_loud'));
    });

    test('resolves once the record changes into something this build stores', () async {
      transport.seedServerRow(
        Tables.observations,
        observation('obs-future', signalStrength: 'blisteringly_loud'),
      );
      await engine().run(projectId);
      expect(await SyncEngine.droppedRowCount(appDb.raw, projectId), 1);

      // The same row, corrected — a later edit on whoever's device wrote it,
      // arriving at a new `server_seq` the way any ordinary update does.
      transport.seedServerRow(Tables.observations, observation('obs-future'));
      final report = await engine().run(projectId);

      expect(report.droppedCount, 0);
      expect(report.everythingArrived, isTrue);
      expect(await SyncEngine.droppedRowCount(appDb.raw, projectId), 0);
      final stored = await appDb.raw.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-future'],
      );
      expect(stored, isNotEmpty);
    });
  });
}

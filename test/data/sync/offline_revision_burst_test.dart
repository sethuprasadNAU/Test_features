import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/base_repository.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// **The measurement task 11.159 was told to take before designing anything:
/// how does a real offline burst of edits actually reach the server?**
///
/// The question is not academic. The candidate remedy for "a row pushed at an
/// absurd `revision` wins last-write-wins forever" was to bound the *increment*
/// — refuse a push whose `revision` exceeds the server's stored one by more
/// than N — on the argument that a ceiling has to anticipate a row's whole
/// lifetime while a delta only has to anticipate one push. **That argument
/// holds only if one push carries a bounded number of edits.** If a device off
/// the network for a field season coalesces a hundred edits into one row, the
/// delta is a lifetime guess wearing a different hat and is no safer than the
/// ceiling it replaced.
///
/// So this file measures rather than reasons, and it **prints what it found**
/// — an instrument whose last words are a finding, not a name. Every number in
/// task 11.159's report comes from here.
void main() {
  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 9, 5, 12);

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
    state = SyncStateStore(prefs: SharedPreferencesAsync());
    await _seedLocalProject(appDb, now: now);
  });

  tearDown(() => appDb.close());

  SyncEngine engine() => SyncEngine(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  /// A real repository over `Observations`, so every edit below goes through
  /// the app's own `revision = revision + 1` rather than a test's imitation of
  /// it. Measuring a hand-written UPDATE would measure this file.
  BaseRepository repository() => BaseRepository(
    appDb.raw,
    table: Tables.observations,
    pk: const ['observation_id', 'project_id'],
    rule: MutationRule.author,
  );

  Map<String, Object?> observation(String id) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': DbCodec.encodeUtc(now),
    'timestamp_utc': DbCodec.encodeUtc(now),
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'notes': 'first',
    'created_at': DbCodec.encodeUtc(now),
    'updated_at': DbCodec.encodeUtc(now),
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': deviceId,
  };

  /// The `revision` the server ended up holding for [id].
  int serverRevision(String id) =>
      transport.serverRow(Tables.observations, '$id/$projectId')!['revision']!
          as int;

  /// Every `Observations` row the last push put on the wire, by id.
  Map<String, int> offeredRevisions() {
    final offered = <String, int>{};
    for (final row
        in transport.pushes.last.rows[Tables.observations] ?? const []) {
      offered[row['observation_id']! as String] = row['revision']! as int;
    }
    return offered;
  }

  group('how an offline burst arrives', () {
    test('fifty offline edits to ONE row arrive as one row, not fifty — '
        'so the jump the server sees is the edit count, unbounded by anything '
        'in the push', () async {
      await appDb.raw.insert(Tables.observations, observation('obs-1'));
      await engine().run(projectId);
      final afterFirstSync = serverRevision('obs-1');

      // The dead zone. Fifty ordinary corrections to one observation, each
      // through the repository the app itself uses.
      const editsMade = 50;
      for (var i = 0; i < editsMade; i++) {
        await repository().updateByKey(
          {'observation_id': 'obs-1', 'project_id': projectId},
          {'notes': 'correction $i'},
          actor: MutationActor.user(userId),
          deviceId: deviceId,
          now: now.add(Duration(minutes: i + 1)),
        );
      }

      await engine().run(projectId);
      final offered = offeredRevisions();
      final jump = serverRevision('obs-1') - afterFirstSync;

      // ignore: avoid_print
      print(
        'MEASURED — $editsMade offline edits to one row arrived as '
        '${offered.length} pushed row(s) carrying revision '
        '${offered['obs-1']}; the server saw a single jump of $jump from '
        'the revision it already held ($afterFirstSync). The push sends the '
        "row's CURRENT STATE, never an edit log, so N offline edits to one "
        'row are one row whose revision advanced by N. A delta bound of N '
        'therefore refuses a device that made more than N corrections '
        'between syncs — which is a guess about how long somebody is off '
        'the network, i.e. a ceiling wearing a different hat.',
      );

      expect(
        offered.length,
        1,
        reason: 'the push coalesces: one row, not one row per edit',
      );
      expect(jump, editsMade);
    });

    test(
      'fifty offline edits to fifty DIFFERENT rows arrive as fifty rows each '
      'advanced by one — the burst is wide, not tall',
      () async {
        for (var i = 0; i < 50; i++) {
          await appDb.raw.insert(Tables.observations, observation('obs-$i'));
        }
        await engine().run(projectId);

        for (var i = 0; i < 50; i++) {
          await repository().updateByKey(
            {'observation_id': 'obs-$i', 'project_id': projectId},
            {'notes': 'corrected'},
            actor: MutationActor.user(userId),
            deviceId: deviceId,
            now: now.add(const Duration(minutes: 1)),
          );
        }
        await engine().run(projectId);

        final jumps = {
          for (var i = 0; i < 50; i++) serverRevision('obs-$i') - 1,
        };

        // ignore: avoid_print
        print(
          'MEASURED — 50 offline edits spread over 50 rows arrived as 50 rows, '
          'each advanced by exactly ${jumps.single}. The ordinary field '
          'shape — many observations touched once — produces no large jump at '
          'all. Only repeated correction of the SAME row does, which is why '
          'the first measurement is the one that matters.',
        );

        expect(jumps, {1});
      },
    );

    test(
      'the batch limit does not split one row\'s advance: a push that cannot '
      'carry every row still carries each row whole',
      () async {
        // 12 rows, a batch limit of 5. If a limit could split a row's history
        // the delta would arrive in pieces and a bound could be applied per
        // piece; it cannot, because there is no history on the wire.
        for (var i = 0; i < 12; i++) {
          await appDb.raw.insert(Tables.observations, observation('obs-$i'));
        }
        await engine().run(projectId);
        for (var i = 0; i < 12; i++) {
          for (var edit = 0; edit < 7; edit++) {
            await repository().updateByKey(
              {'observation_id': 'obs-$i', 'project_id': projectId},
              {'notes': 'correction $edit'},
              actor: MutationActor.user(userId),
              deviceId: deviceId,
              now: now.add(Duration(minutes: edit + 1)),
            );
          }
        }

        final pushesBefore = transport.pushes.length;
        await engine().run(projectId, batchSize: 5);

        final firstPush = transport.pushes[pushesBefore];
        final rowsInFirstPush =
            (firstPush.rows[Tables.observations] ?? const []).length;
        final advances = {
          for (final row in firstPush.rows[Tables.observations] ?? const [])
            (row['revision']! as int) - 1,
        };

        // ignore: avoid_print
        print(
          'MEASURED — with a push batch limit of 5, the first push carried '
          '$rowsInFirstPush observation row(s), each already advanced by '
          '${advances.join(', ')}. A batch limit bounds how many ROWS a push '
          'carries and cannot bound how far ONE row has moved: the wire has no '
          'edit history to split. So there is no push-shaped ceiling on the '
          'jump, and nothing in the protocol makes one available.',
        );

        expect(advances, {7});
      },
    );

    test('a row this device accepted from an untrusted import is pushed at the '
        'revision the import let in — up to 3,999,000,000 — so a server-side '
        'refusal above any smaller number would strand a row the app itself '
        'admitted', () async {
      // §4.19 clause 3's own ceiling, the largest revision the share/import
      // path will accept onto this device. Nothing downstream of the import
      // knows the row arrived that way.
      final imported = observation('obs-imported')
        ..['revision'] = UntrustedImportRules.maxImportedRevision;
      await appDb.raw.insert(Tables.observations, imported);

      await engine().run(projectId);
      final offered = offeredRevisions();

      // ignore: avoid_print
      print(
        'MEASURED — a row admitted by the import path at revision '
        '${UntrustedImportRules.maxImportedRevision} was pushed verbatim '
        '(offered revision ${offered['obs-imported']}). The import ceiling '
        'is a client-side consent decision; the sync push knows nothing '
        'about it. Any server ceiling below '
        '${UntrustedImportRules.maxImportedRevision} — and any delta bound '
        'at all, since the server holds no copy of a freshly imported row — '
        'would refuse this row forever, leaving it stuck on the holder\'s '
        "device behind a red bar. That is the stranding this task's brief "
        'forbids.',
      );

      expect(offered['obs-imported'], UntrustedImportRules.maxImportedRevision);
    });

    test('a first push of a row the server has never seen carries no delta at '
        'all — an insert has nothing to be measured against', () async {
      final absurd = observation('obs-pinned')
        ..['revision'] = 4611686018427387904;
      await appDb.raw.insert(Tables.observations, absurd);
      await engine().run(projectId);

      // ignore: avoid_print
      print(
        'MEASURED — a row at revision 4611686018427387904 (2^62) that the '
        'server has never seen was accepted as an INSERT, where there is no '
        'existing revision to compare against. A delta bound is silent here '
        'by construction: it can only judge a row the server already holds. '
        'The pin is available on the very first push of a new row, which is '
        'the cheapest way to perform it.',
      );

      expect(serverRevision('obs-pinned'), 4611686018427387904);
    });
  });
}

Future<void> _seedLocalProject(AppDatabase db, {required DateTime now}) async {
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

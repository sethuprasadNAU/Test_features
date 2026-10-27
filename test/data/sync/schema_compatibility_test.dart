import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/project_exporter.dart';
import 'package:tritrack/data/sync/project_merger.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/data/sync/unknown_columns.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'backup_builders.dart';
import 'fake_sync_transport.dart';

/// Task 10.18: an app one schema **minor** behind syncs without losing data.
///
/// The claim under test is narrow and load-bearing: a value this build has no
/// column for survives a full pull → edit → push round trip **byte-identical**.
/// Not "is still present", not "compares equal after coercion" — identical, so
/// that whatever the newer build wrote is what the newer build reads back.
///
/// This is the compatibility floor. It only protects builds that ship with it,
/// so nothing here can be added later for devices already in the field.
void main() {
  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';
  final now = DateTime.utc(2026, 8, 1, 12);
  final stamp = DbCodec.encodeUtc(now);

  late AppDatabase appDb;
  late FakeSyncTransport transport;
  late SyncStateStore state;

  setUp(() async {
    installFakeSharedPreferences();
    appDb = await AppDatabase.openInMemory();
    transport = FakeSyncTransport();
    state = SyncStateStore(prefs: SharedPreferencesAsync());
    await _seedProject(appDb, stamp);
  });

  tearDown(() => appDb.close());

  SyncEngine engine() => SyncEngine(
    db: appDb.raw,
    transport: transport,
    state: state,
    deviceId: deviceId,
    userId: userId,
  );

  /// An observation as a *newer* build would write it: every column this build
  /// knows, plus ones it has never heard of.
  Map<String, Object?> futureObservation({
    String id = 'obs-1',
    int revision = 1,
    String notes = 'from the newer app',
    Map<String, Object?> extra = const {
      'habitat_code': 'PJ-WOODLAND',
      'detection_confidence': 0.875,
      'observer_count': 3,
    },
  }) => {
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
    'notes': notes,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': 'device-NEW',
    ...extra,
  };

  group('unknown columns survive a round trip', () {
    test(
      'a pulled unknown value comes back byte-identical after a local edit',
      () async {
        // The acceptance criterion, start to finish. Before this task the pull
        // would have been refused outright; before preservation existed it would
        // have succeeded and quietly emptied three columns on the push.
        final incoming = futureObservation();
        transport.seedServerRow(Tables.observations, incoming);

        await engine().run(projectId);

        // The row landed; the columns this build has no place for did not.
        final stored = await appDb.raw.query(Tables.observations);
        expect(stored.single['notes'], 'from the newer app');
        expect(stored.single.containsKey('habitat_code'), isFalse);

        // A perfectly ordinary local edit — the case that used to destroy the
        // held values, because the push wrote the whole row back without them.
        await appDb.raw.update(
          Tables.observations,
          {
            'notes': 'edited in the field',
            'revision': 2,
            'updated_at': DbCodec.encodeUtc(now.add(const Duration(hours: 1))),
          },
          where: 'observation_id = ?',
          whereArgs: ['obs-1'],
        );
        // No nudge needed: the edit changed `updated_at`, so no receipt matches
        // the row any more and the next push offers it (task 10.33).

        await engine().run(projectId);

        final pushedRow = transport.serverRow(
          Tables.observations,
          'obs-1/$projectId',
        )!;
        expect(pushedRow['notes'], 'edited in the field');
        for (final column in const [
          'habitat_code',
          'detection_confidence',
          'observer_count',
        ]) {
          expect(
            jsonEncode(pushedRow[column]),
            jsonEncode(incoming[column]),
            reason: '$column must return byte-identical, not merely present',
          );
        }
      },
    );

    test(
      'held values ride along in a backup, not just over the wire',
      () async {
        // A backup that dropped them would be the same destruction one file
        // removed: restore it and the newer build's columns are gone.
        transport.seedServerRow(Tables.observations, futureObservation());
        await engine().run(projectId);

        final backup = await ProjectExporter.collect(
          appDb.raw,
          projectId,
          now: now,
        );
        final row = backup.rowsFor(Tables.observations).single;
        expect(row['habitat_code'], 'PJ-WOODLAND');
      },
    );

    test(
      'a losing row does not clobber the values held for the winner',
      () async {
        // Last-write-wins governs the held values exactly as it governs the real
        // columns — an incoming row that loses changes nothing, including here.
        transport.seedServerRow(Tables.observations, futureObservation());
        await engine().run(projectId);

        await ProjectMerger(appDb.raw).merge(
          makeBackup({
            Tables.observations: [
              futureObservation(
                revision: 0,
                notes: 'stale',
                extra: const {'habitat_code': 'WRONG'},
              ),
            ],
          }, schemaVersion: latestSchemaVersion),
        );

        final held = await appDb.raw.query(UnknownColumnStore.table);
        final habitat = held.firstWhere(
          (r) => r['column_name'] == 'habitat_code',
        );
        expect(jsonDecode(habitat['value_json'] as String), 'PJ-WOODLAND');
      },
    );

    test(
      'a column absent from a winning row leaves its held value alone',
      () async {
        // Parity with a build that *does* know the column: `UPDATE` writes only
        // the columns the row carried, so an omitted one is untouched. An older
        // build must behave the same, not more destructively and not less.
        transport.seedServerRow(Tables.observations, futureObservation());
        await engine().run(projectId);

        await ProjectMerger(appDb.raw).merge(
          makeBackup(
            {
              Tables.observations: [
                futureObservation(
                  revision: 9,
                  notes: 'newer, but silent about habitat',
                  extra: const {'detection_confidence': 0.5},
                ),
              ],
            },
            schemaVersion: latestSchemaVersion,
            // The manifest names the project the rows are actually in. It used
            // to be left at the builder's default, which nothing read — until
            // task 10.73 scoped the merge to it (the gate's fact (c): a file
            // whose manifest named project A rewrote a row in project B).
            projectId: projectId,
          ),
          // The newer row replaces `notes`, so §4.19 rule 4's gate applies
          // (task 10.73). This test is about what an *applied* update does to a
          // held value, so consent is given here and the gate itself is covered
          // in `backup_restore_overwrite_test.dart`.
          confirmChanges: true,
        );

        final rows = [
          Map<String, Object?>.of(
            (await appDb.raw.query(Tables.observations)).single,
          ),
        ];
        await UnknownColumnStore(
          appDb.raw,
        ).attach(projectId, syncTablesByName[Tables.observations]!, rows);
        expect(rows.single['habitat_code'], 'PJ-WOODLAND');
        expect(rows.single['detection_confidence'], 0.5);
      },
    );
  });

  group('promotion on upgrade', () {
    test('a held value moves into its column once the column exists', () async {
      // Promotion is written once against `tableSpecs` rather than per column,
      // so this is really asserting that *any* future addition is covered
      // without someone remembering to write a step for it. `notes` stands in
      // for a column that did not exist when the value was held.
      await appDb.raw.insert(Tables.observations, {
        ...futureObservation(extra: const {}),
        // Null, matching a real `ADD COLUMN` that nothing backfilled:
        // promotion refuses to overwrite a non-null column (task 10.76), so
        // the stand-in has to start null or it would not exercise this path.
        'notes': null,
      });
      await appDb.raw.insert(UnknownColumnStore.table, {
        'table_name': Tables.observations,
        'row_key': jsonEncode(['obs-1', projectId]),
        'column_name': 'notes',
        'project_id': projectId,
        'value_json': jsonEncode('promoted'),
      });

      final promoted = await UnknownColumnStore(appDb.raw).promote();

      expect(promoted, 1);
      final row = (await appDb.raw.query(Tables.observations)).single;
      expect(row['notes'], 'promoted');
      expect(await appDb.raw.query(UnknownColumnStore.table), isEmpty);
    });

    test('a value held across two minor bumps still promotes', () async {
      // Each held value is an independent entry keyed by column, so one that
      // sat through several upgrades promotes on whichever one first declares
      // its column — while a column still unknown keeps waiting rather than
      // being discarded as stale.
      await appDb.raw.insert(Tables.observations, {
        ...futureObservation(extra: const {}),
        'notes': null, // null, as a real un-backfilled `ADD COLUMN` would be.
      });
      for (final column in const ['notes', 'still_unknown']) {
        await appDb.raw.insert(UnknownColumnStore.table, {
          'table_name': Tables.observations,
          'row_key': jsonEncode(['obs-1', projectId]),
          'column_name': column,
          'project_id': projectId,
          'value_json': jsonEncode('held'),
        });
      }

      await UnknownColumnStore(appDb.raw).promote();
      // A second upgrade's promotion pass must be a safe no-op, not a rerun
      // that overwrites what the user has since edited.
      expect(await UnknownColumnStore(appDb.raw).promote(), 0);

      final held = await appDb.raw.query(UnknownColumnStore.table);
      expect(held.single['column_name'], 'still_unknown');
    });

    test(
      'promote never overwrites a column a migration already backfilled',
      () async {
        // Task 10.76 (finding K-5): promotion used to write unconditionally,
        // which meant a stale held value could clobber whatever a migration's
        // own `UPDATE` had just computed for the newly declared column (schema
        // v4's `Tags.color_hex` backfill is the exact shape named in the
        // finding). A non-null column already means something wrote it since
        // the value was held, so promotion must lose to it, not overwrite it.
        await appDb.raw.insert(Tables.observations, {
          ...futureObservation(extra: const {}),
          'notes': 'backfilled by migration',
        });
        await appDb.raw.insert(UnknownColumnStore.table, {
          'table_name': Tables.observations,
          'row_key': jsonEncode(['obs-1', projectId]),
          'column_name': 'notes',
          'project_id': projectId,
          'value_json': jsonEncode('stale held value'),
        });

        final promoted = await UnknownColumnStore(appDb.raw).promote();

        expect(promoted, 0);
        final row = (await appDb.raw.query(Tables.observations)).single;
        expect(row['notes'], 'backfilled by migration');
        // Not left behind to retry forever, either — it lost, and that is final.
        expect(await appDb.raw.query(UnknownColumnStore.table), isEmpty);
      },
    );

    test('promote quarantines rather than repeats when a held value cannot be '
        'written', () async {
      // The unrecoverable-brick case task 10.76 exists to close: before this,
      // an unwritable value threw *inside* `onOpen`, and the entry was only
      // deleted after a *successful* update — so the failure repeated on
      // every single launch and the database never opened again. A JSON
      // object can never bind as a column value, so it stands in for "a value
      // this build cannot write" without needing a real type mismatch.
      await appDb.raw.insert(Tables.observations, {
        ...futureObservation(extra: const {}),
        'notes': null,
      });
      await appDb.raw.insert(UnknownColumnStore.table, {
        'table_name': Tables.observations,
        'row_key': jsonEncode(['obs-1', projectId]),
        'column_name': 'notes',
        'project_id': projectId,
        'value_json': jsonEncode({'nested': 'object'}),
      });

      final promoted = await UnknownColumnStore(appDb.raw).promote();

      expect(promoted, 0);
      expect(await appDb.raw.query(UnknownColumnStore.table), isEmpty);
      final quarantined = await appDb.raw.query(
        UnknownColumnStore.quarantineTable,
      );
      expect(quarantined, hasLength(1));
      expect(quarantined.single['column_name'], 'notes');

      // The next launch's promotion pass must not throw and must not find
      // anything left over to retry — the whole point of quarantining it.
      expect(await UnknownColumnStore(appDb.raw).promote(), 0);
    });
  });

  group('project scoping (task 10.76, finding K-5)', () {
    test('a value held through one project is never attached while exporting '
        'a different one', () async {
      // `Users`, `User_Emails` and `Tags` are globally keyed — the same row
      // is legitimately shared across projects. Without scoping, a value
      // this device only ever learned via project A would ride out in
      // project B's own export or push just because they share a row, which
      // is a live channel for data project B was never sent.
      await UnknownColumnStore.ensureTable(appDb.raw);
      final table = syncTablesByName[Tables.tags]!;
      const row = {'tag_id': 'tag-1'};
      await UnknownColumnStore(
        appDb.raw,
      ).hold('project-A', table, row, {'internal_note': 'sensitive'});

      final rowsForB = [Map<String, Object?>.of(row)];
      await UnknownColumnStore(appDb.raw).attach('project-B', table, rowsForB);
      expect(rowsForB.single.containsKey('internal_note'), isFalse);

      final rowsForA = [Map<String, Object?>.of(row)];
      await UnknownColumnStore(appDb.raw).attach('project-A', table, rowsForA);
      expect(rowsForA.single['internal_note'], 'sensitive');
    });
  });

  group('bounds (task 10.76, finding K-5)', () {
    test('hold refuses a column name past the bound', () async {
      await UnknownColumnStore.ensureTable(appDb.raw);
      final table = syncTablesByName[Tables.observations]!;
      final longName = 'x' * (UnknownColumnStore.maxColumnNameLength + 1);
      await UnknownColumnStore(appDb.raw).hold(
        projectId,
        table,
        {'observation_id': 'obs-1', 'project_id': projectId},
        {longName: 'value'},
      );
      expect(await appDb.raw.query(UnknownColumnStore.table), isEmpty);
    });

    test('hold refuses a value past the size bound', () async {
      await UnknownColumnStore.ensureTable(appDb.raw);
      final table = syncTablesByName[Tables.observations]!;
      final longValue = 'x' * (UnknownColumnStore.maxValueJsonLength + 1);
      await UnknownColumnStore(appDb.raw).hold(
        projectId,
        table,
        {'observation_id': 'obs-1', 'project_id': projectId},
        {'oversized': longValue},
      );
      expect(await appDb.raw.query(UnknownColumnStore.table), isEmpty);
    });

    test('hold refuses to grow the table past maxEntries', () async {
      await UnknownColumnStore.ensureTable(appDb.raw);
      final filler = appDb.raw.batch();
      for (var i = 0; i < UnknownColumnStore.maxEntries; i++) {
        filler.insert(UnknownColumnStore.table, {
          'table_name': Tables.observations,
          'row_key': 'filler-$i',
          'column_name': 'filler',
          'project_id': projectId,
          'value_json': jsonEncode('x'),
        });
      }
      await filler.commit(noResult: true);

      await UnknownColumnStore(appDb.raw).hold(
        projectId,
        syncTablesByName[Tables.observations]!,
        {'observation_id': 'obs-new', 'project_id': projectId},
        {'new_unknown_column': 'value'},
      );

      final count = (await appDb.raw.rawQuery(
        'SELECT COUNT(*) AS c FROM ${UnknownColumnStore.table}',
      )).first['c'];
      expect(count, UnknownColumnStore.maxEntries);
    });
  });

  group('the holding table is client-only', () {
    test('it is not part of the shared schema and never syncs', () {
      // Deliberately outside `Tables` / `tableSpecs` / `syncTables`, and so
      // outside `latestSchemaVersion` — the same reason the server keeps its
      // bookkeeping tables out of the shared version (task 10.11). A table only
      // one side needs must not force a bump every device has to chase.
      expect(Tables.all, isNot(contains(UnknownColumnStore.table)));
      expect(tableSpecsByName.keys, isNot(contains(UnknownColumnStore.table)));
      expect(syncTablesByName.keys, isNot(contains(UnknownColumnStore.table)));
    });

    test('it exists on a freshly opened database', () async {
      // Created with IF NOT EXISTS on every open rather than by a migration.
      final rows = await appDb.raw.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [UnknownColumnStore.table],
      );
      expect(rows, hasLength(1));
    });
  });

  group('unknown tables cannot wedge the cursor', () {
    test(
      'a page of only-unknown-table rows still advances the cursor',
      () async {
        // `decodeRows` drops rows for tables this build has never heard of, so
        // such a page decodes to zero rows while the server is holding plenty
        // more behind it. Stopping on an empty page would park the cursor there
        // permanently: sync dead, no error, nothing to notice. Data safety was
        // never the risk here — a wedged sync was.
        final stalling = _UnknownTableTransport(
          realRow: futureObservation(extra: const {}),
        );
        final syncEngine = SyncEngine(
          db: appDb.raw,
          transport: stalling,
          state: state,
          deviceId: deviceId,
          userId: userId,
        );

        final report = await syncEngine.run(projectId);

        expect(
          report.cursor,
          2,
          reason: 'the cursor moved past the opaque page',
        );
        expect(report.pulled, 1);
        expect(await appDb.raw.query(Tables.observations), hasLength(1));
      },
    );
  });
}

/// Serves one page containing only a table this build does not know, then a
/// page with a real row behind it.
class _UnknownTableTransport implements SyncTransport {
  _UnknownTableTransport({required this.realRow});

  final Map<String, Object?> realRow;
  int _calls = 0;

  @override
  Future<SyncPullResponse> pull(SyncPullRequest request) async {
    _calls++;
    if (_calls == 1) {
      return SyncPullResponse(
        // Decodes to nothing on this build; the server still moved past it.
        rows: decodeRows(const {
          'Acoustic_Recordings': [
            {'recording_id': 'rec-1'},
          ],
        }),
        nextCursor: 1,
        remaining: 1,
      );
    }
    if (_calls == 2) {
      return SyncPullResponse(
        rows: {
          Tables.observations: [Map<String, Object?>.of(realRow)],
        },
        nextCursor: 2,
        remaining: 0,
      );
    }
    return SyncPullResponse(
      rows: const {},
      nextCursor: request.cursor,
      remaining: 0,
    );
  }

  @override
  Future<SyncPushResponse> push(SyncPushRequest request) async =>
      SyncPushResponse(applied: 0, outcomes: {}, highestServerSeq: null);

  @override
  Future<void> ack(SyncAckRequest request) async {}

  @override
  Future<List<ProjectSummary>> listMyProjects() async => const [];

  @override
  Future<List<DeletedProjectSummary>> listMyDeletedProjects() async =>
      const [];

  // Task 11.81's joining surface. This transport exists to exercise one pull
  // path; nothing here reaches it, and throwing rather than returning an empty
  // answer is what makes that a failure instead of a silent pass if it ever
  // does. `FakeSyncTransport` is the one with a working implementation.
  @override
  Future<JoinSettings> joinSettings(String projectId) =>
      throw UnimplementedError();

  @override
  Future<JoinSettings> updateJoinSettings({
    required String projectId,
    bool? joiningEnabled,
    int? teamSizeLimit,
  }) => throw UnimplementedError();

  @override
  Future<RotateJoinCodeResponse> rotateJoinCode({
    required String projectId,
    bool clearPending = false,
  }) => throw UnimplementedError();

  @override
  Future<List<JoinRequestSummary>> joinRequests(String projectId) =>
      throw UnimplementedError();

  @override
  Future<void> approveJoinRequest({
    required String projectId,
    required String requestId,
    required ProjectRole role,
  }) => throw UnimplementedError();

  @override
  Future<void> rejectJoinRequest({
    required String projectId,
    required String requestId,
  }) => throw UnimplementedError();

  @override
  Future<void> readmitMember({
    required String projectId,
    required String userId,
    required ProjectRole role,
  }) => throw UnimplementedError();

  @override
  Future<JoinRequestCreatedResponse> requestToJoin({
    required String code,
    String? claimedName,
  }) => throw UnimplementedError();

  @override
  Future<List<MyJoinRequest>> myJoinRequests() => throw UnimplementedError();

  @override
  Future<ProjectDeletionStanding> projectDeletion(String projectId) =>
      throw UnimplementedError();

  @override
  Future<ProjectDeletionStanding> setProjectDeletion(
    String projectId,
    ProjectDeletionAction action,
  ) => throw UnimplementedError();
}

Future<void> _seedProject(AppDatabase db, String stamp) async {
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

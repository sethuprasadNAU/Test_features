@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Task 10.11's tombstone-retention policy, against real Postgres.
///
/// **Every fixture that expects a purge backdates `received_at`** (task
/// 11.291). The window is measured on the server's clock — when it accepted
/// the delete — and a push stamps that column `now()`, so a tombstone with a
/// 2020 `deleted_at` and no `receivedLongAgo` call is, to the sweep, seconds
/// old. Until 2026-09-21 these fixtures aged rows by `deleted_at` alone;
/// three of them went red on the rule change and the rest had quietly become
/// vacuous (nothing old enough to purge, so "not refused" proved nothing).
///
/// The headline test is `a device offline past the window cannot resurrect a
/// deleted observation` — the acceptance criterion, and the failure mode the
/// whole policy exists to prevent. The rest establish that the guard is not
/// achieved by simply refusing everyone: a device that keeps syncing is never
/// stranded, a joining device can still join, and a fresh project is never
/// affected.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_retention_test';

  const alice = 'user-alice';
  const projectA = 'proj-a';
  const staleDevice = 'device-shelved';
  const activeDevice = 'device-current';

  /// Comfortably past the 24-month window.
  final longAgo = DateTime.utc(2020, 1, 1);
  final now = DateTime.utc(2026, 8, 5);

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
    await _seed(connection);
  });

  Map<String, Object?> observation(
    String id, {
    String projectId = projectA,
    String userId = alice,
    int revision = 1,
    String? deletedAt,
  }) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': '2020-01-01T12:00:00.000Z',
    'timestamp_utc': '2020-01-01T12:00:00.000Z',
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': '2020-01-01T12:00:00.000Z',
    'updated_at': '2020-01-01T12:00:00.000Z',
    'deleted_at': deletedAt,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': staleDevice,
  };

  Future<PushResult> pushAs(
    String userId, {
    required String projectId,
    required SyncRows rows,
  }) => connection.runTx((tx) async {
    final access = await ProjectAuthorizer.resolve(
      tx,
      projectId: projectId,
      userId: userId,
    );
    return SyncService(session: tx).applyPush(
      projectId: projectId,
      rows: rows,
      authorizer: RowAuthorizer(
        session: tx,
        projectId: projectId,
        userId: userId,
        access: access,
      ),
    );
  });

  Future<void> acknowledge(
    String deviceId, {
    required int cursor,
    required DateTime at,
  }) => connection.runTx(
    (tx) => CursorStore(tx).acknowledge(
      const SyncCursorKey(
        userId: alice,
        deviceId: '',
        projectId: projectA,
      ).copyForDevice(deviceId),
      cursor: cursor,
      at: at,
    ),
  );

  Future<bool> observationExists(String id) async {
    final result = await connection.execute(
      'SELECT 1 FROM ${quoted(Tables.observations)} '
      r'WHERE observation_id = $1',
      parameters: [id],
    );
    return result.isNotEmpty;
  }

  Future<TombstonePurgeReport> purge() =>
      connection.runTx((tx) => TombstoneRetentionService(tx).purge(now: now));

  /// Backdates the server's own receipt of [id] — the clock the window is
  /// measured on (task 11.291). A push stamps `received_at = now()` from the
  /// database's clock, so a test that wants a tombstone to be *old as the
  /// server has known it* has to say so explicitly; nothing else in a test
  /// can move that column.
  Future<void> receivedLongAgo(String id, {DateTime? at}) async {
    await connection.execute(
      'UPDATE ${quoted(Tables.observations)} SET received_at = \$1 '
      r'WHERE observation_id = $2',
      parameters: [at ?? longAgo, id],
    );
  }

  group('the resurrection case', skip: databaseSkipReason, () {
    test('a device offline past the window cannot resurrect a deleted '
        'observation', () async {
      // The acceptance criterion, staged exactly as it happens in the field.
      //
      // 1. Both devices are current and hold observation obs-1.
      final created = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [observation('obs-1')],
        },
      );
      final seqAfterCreate = created.highestServerSeq!;
      await acknowledge(staleDevice, cursor: seqAfterCreate, at: longAgo);
      await acknowledge(activeDevice, cursor: seqAfterCreate, at: now);

      // 2. The shelved device goes into a drawer. Someone deletes obs-1.
      final deleted = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation(
              'obs-1',
              revision: 2,
              deletedAt: '2020-06-01T12:00:00.000Z',
            ),
          ],
        },
      );
      await acknowledge(
        activeDevice,
        cursor: deleted.highestServerSeq!,
        at: now,
      );

      // 3. Two years pass. The tombstone is purged.
      await receivedLongAgo('obs-1');
      final report = await purge();
      expect(report.purgedAnything, isTrue);
      expect(
        await observationExists('obs-1'),
        isFalse,
        reason:
            'the tombstone itself is gone — that is what makes the '
            'device dangerous rather than merely behind',
      );

      // 4. The shelved device comes back and tries to push its still-live
      //    copy. Without the guard this is an INSERT: the server has no row
      //    to compare against, so obs-1 returns from the dead.
      await expectLater(
        connection.runTx(
          (tx) => TombstoneRetentionService(tx).assertDeviceMayPush(
            userId: alice,
            deviceId: staleDevice,
            projectId: projectA,
          ),
        ),
        throwsA(isA<StaleCursorException>()),
      );

      expect(
        await observationExists('obs-1'),
        isFalse,
        reason: 'the deleted observation must stay deleted',
      );
    });

    test('an incremental pull from below the floor is refused', () async {
      // Two tombstones, so the floor lands above the first row's sequence and
      // "below the floor" is unambiguous — with a single row the floor equals
      // that row's own sequence and there is no position below it to test.
      final created = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
            observation('obs-2', deletedAt: '2020-06-01T12:00:00.000Z'),
          ],
        },
      );
      await acknowledge(staleDevice, cursor: 1, at: longAgo);
      await receivedLongAgo('obs-1');
      await receivedLongAgo('obs-2');
      await purge();
      final floor = await connection.runTx(
        (tx) => TombstoneRetentionService(tx).floorFor(projectA),
      );
      expect(floor, created.highestServerSeq);
      expect(floor, greaterThan(1));

      await expectLater(
        connection.runTx(
          (tx) => TombstoneRetentionService(
            tx,
          ).assertCursorIsFresh(projectId: projectA, cursor: 1),
        ),
        throwsA(isA<StaleCursorException>()),
      );

      // And a device already at the floor is not refused — the guard is
      // "below what was purged", not "not exactly current".
      await connection.runTx(
        (tx) => TombstoneRetentionService(
          tx,
        ).assertCursorIsFresh(projectId: projectA, cursor: floor),
      );
    });

    test('a full re-pull from cursor zero is always allowed', () async {
      // A joining device is asking for current state rather than claiming to
      // hold it, so a missing tombstone contradicts nothing. Refusing this
      // would break ProjectJoiner on exactly the old projects a new device
      // most needs to join.
      await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
          ],
        },
      );
      await receivedLongAgo('obs-1');
      final report = await purge();
      expect(
        report.purgedAnything,
        isTrue,
        reason: 'the floor has to be above zero for this to test anything',
      );

      await connection.runTx(
        (tx) => TombstoneRetentionService(
          tx,
        ).assertCursorIsFresh(projectId: projectA, cursor: 0),
      );
    });
  });

  group(
    'the guard does not strand devices that keep syncing',
    skip: databaseSkipReason,
    () {
      test('an active device holds the purge back, however far behind it '
          'is', () async {
        // Age alone is not sufficient. This device is current (it synced
        // today) but sits below a six-year-old tombstone because it joined
        // recently — purging past it would strand a perfectly healthy device.
        final created = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
            ],
          },
        );
        expect(created.highestServerSeq, greaterThan(0));
        await acknowledge(activeDevice, cursor: 0, at: now);
        // Old by the server's clock too, so the holdback is the only thing
        // keeping it — without this line the test passes for the wrong
        // reason (the row is simply not old enough yet).
        await receivedLongAgo('obs-1');

        final report = await purge();

        expect(
          report.purgedAnything,
          isFalse,
          reason: 'an in-window device below the tombstone holds it back',
        );
        expect(await observationExists('obs-1'), isTrue);
        await connection.runTx(
          (tx) => TombstoneRetentionService(tx).assertDeviceMayPush(
            userId: alice,
            deviceId: activeDevice,
            projectId: projectA,
          ),
        );
      });

      test('a device that has caught up is never refused', () async {
        final created = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
            ],
          },
        );
        await acknowledge(
          activeDevice,
          cursor: created.highestServerSeq!,
          at: now,
        );
        await receivedLongAgo('obs-1');
        final report = await purge();
        expect(
          report.purgedAnything,
          isTrue,
          reason: 'the floor has to be above zero for this to test anything',
        );

        await connection.runTx(
          (tx) => TombstoneRetentionService(tx).assertDeviceMayPush(
            userId: alice,
            deviceId: activeDevice,
            projectId: projectA,
          ),
        );
      });

      test(
        'a project that has never been purged never refuses anyone',
        () async {
          // A freshly published project has a floor of zero, so the publisher —
          // which sets its cursor from its own push and never acknowledges a
          // pull — is not caught by a guard aimed at shelved devices.
          await pushAs(
            alice,
            projectId: projectA,
            rows: {
              Tables.observations: [observation('obs-1')],
            },
          );

          expect(
            await connection.runTx(
              (tx) => TombstoneRetentionService(tx).floorFor(projectA),
            ),
            0,
          );
          await connection.runTx(
            (tx) => TombstoneRetentionService(tx).assertDeviceMayPush(
              userId: alice,
              deviceId: 'device-never-seen-before',
              projectId: projectA,
            ),
          );
        },
      );
    },
  );

  group('the upgrade path', skip: databaseSkipReason, () {
    test('a database bootstrapped before this table existed gains it on the '
        'next start', () async {
      // The bug this task actually hit: `PostgresMigrations.run` created
      // server-only tables only in its bootstrap branch, so an already-running
      // server saw a recorded version it already had, returned early, and
      // never got `tombstone_purge_floor` — every push then 500'd. Simulated
      // here by dropping the table from a migrated database and re-running.
      await connection.execute('DROP TABLE tombstone_purge_floor');

      await PostgresMigrations.run(connection);

      expect(
        await connection.runTx(
          (tx) => TombstoneRetentionService(tx).floorFor(projectA),
        ),
        0,
        reason: 'the table must exist again, and read as never-purged',
      );
    });

    test(
      're-running migrations on an up-to-date database is a no-op',
      () async {
        // The other half: ensuring server-only tables on every start must not
        // fail or destroy anything when they are all already present.
        await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [observation('obs-1')],
          },
        );

        await PostgresMigrations.run(connection);

        expect(await observationExists('obs-1'), isTrue);
      },
    );
  });

  group(
    'the window is the server\'s clock, not the device\'s (task 11.291)',
    skip: databaseSkipReason,
    () {
      test('a tombstone the server has held past the window is purged, whatever '
          'the device\'s own deletion stamp says', () async {
        // Deleted on the device a month ago by its clock — but the server has
        // held this tombstone for six years. Every device that syncs at all
        // has had six years to receive it, which is the only fact the window
        // is about. Under the rule this replaced, the recent device stamp kept
        // it forever.
        final recentlyDeleted = now
            .subtract(const Duration(days: 30))
            .toIso8601String();
        await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-1', deletedAt: recentlyDeleted),
            ],
          },
        );
        await receivedLongAgo('obs-1');

        final report = await purge();

        expect(report.purgedAnything, isTrue);
        expect(await observationExists('obs-1'), isFalse);
      });

      test('a tombstone the device stamped years ago but the server received '
          'today is kept', () async {
        // The first-run case on a real server: a record deleted on a phone
        // before the server existed, uploaded when the project was published.
        // Its `deleted_at` is six years old; the server has known about the
        // deletion for seconds, so no device can have "missed" it yet. Under
        // the rule this replaced it was purgeable at once — and a device with
        // a wrong clock could make any fresh deletion purgeable the same way.
        final created = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
            ],
          },
        );
        expect(created.highestServerSeq, greaterThan(0));
        // No device has a recorded position, so nothing holds the purge back
        // except the window itself.

        final report = await purge();

        expect(report.purgedAnything, isFalse);
        expect(await observationExists('obs-1'), isTrue);
        expect(
          await connection.runTx(
            (tx) => TombstoneRetentionService(tx).floorFor(projectA),
          ),
          0,
          reason: 'nothing was purged, so nobody can be refused',
        );
      });
    },
  );

  group(
    'the measurement the healthcheck reads (task 11.291)',
    skip: databaseSkipReason,
    () {
      Future<TombstoneRetentionReading> measure() =>
          TombstoneRetentionService(connection).measure(now: now);

      test(
        'an empty server: nothing held, nothing eligible, nobody refused',
        () async {
          final reading = await measure();
          expect(reading.heldTombstones, 0);
          expect(reading.untilFirstPurge, isNull);
          expect(reading.eligibleTombstones, 0);
          expect(reading.mostOverdueBy, isNull);
          expect(reading.devicesNextSweepWouldRefuse, 0);
          expect(reading.devicesAlreadyRefused, 0);
        },
      );

      test('a tombstone inside the window is held, not eligible, and the '
          'reading says how long until it is', () async {
        final recentlyDeleted = now
            .subtract(const Duration(days: 30))
            .toIso8601String();
        await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-1', deletedAt: recentlyDeleted),
            ],
          },
        );
        await receivedLongAgo(
          'obs-1',
          at: now.subtract(const Duration(days: 100)),
        );

        final reading = await measure();

        expect(reading.heldTombstones, 1);
        expect(reading.eligibleTombstones, 0);
        expect(reading.mostOverdueBy, isNull);
        expect(
          reading.untilFirstPurge,
          tombstoneRetention - const Duration(days: 100),
        );
      });

      test('eligible rows are counted by the sweep\'s own predicate, and the '
          'device the sweep would refuse is counted with them', () async {
        final created = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
              observation('obs-2', deletedAt: '2020-06-01T12:00:00.000Z'),
            ],
          },
        );
        await receivedLongAgo(
          'obs-1',
          at: now.subtract(const Duration(days: 800)),
        );
        await receivedLongAgo(
          'obs-2',
          at: now.subtract(const Duration(days: 740)),
        );
        // Away longer than the window, sitting below both tombstones.
        await acknowledge(staleDevice, cursor: 1, at: longAgo);
        // Current, and already past both — does not hold them back.
        await acknowledge(
          activeDevice,
          cursor: created.highestServerSeq!,
          at: now,
        );

        final reading = await measure();

        expect(reading.eligibleTombstones, 2);
        expect(reading.eligibleProjectIds, {projectA});
        expect(reading.mostOverdueBy, const Duration(days: 70));
        expect(reading.heldBackByActiveDevices, 0);
        expect(reading.devicesNextSweepWouldRefuse, 1);
        expect(reading.projectsNextSweepWouldRefuseOn, {projectA});
        expect(reading.devicesAlreadyRefused, 0);

        // The sweep runs. What was "would be refused" is now "is refused", and
        // nothing is left eligible.
        final report = await purge();
        expect(report.rowsPurged, 2);
        final after = await measure();
        expect(after.eligibleTombstones, 0);
        expect(after.mostOverdueBy, isNull);
        expect(after.devicesNextSweepWouldRefuse, 0);
        expect(after.devicesAlreadyRefused, 1);
      });

      test(
        'a row an active device has not received is held back, not overdue',
        () async {
          await pushAs(
            alice,
            projectId: projectA,
            rows: {
              Tables.observations: [
                observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
              ],
            },
          );
          await receivedLongAgo('obs-1');
          await acknowledge(activeDevice, cursor: 0, at: now);

          final reading = await measure();

          expect(reading.eligibleTombstones, 0);
          expect(
            reading.mostOverdueBy,
            isNull,
            reason:
                'the holdback keeping a row is the design working, not a '
                'sweep that has stopped',
          );
          expect(reading.heldBackByActiveDevices, 1);
          expect(reading.devicesNextSweepWouldRefuse, 0);
        },
      );
    },
  );

  group('what purging does and does not remove', skip: databaseSkipReason, () {
    test('live rows are never purged, however old', () async {
      await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [observation('obs-live')],
        },
      );
      await receivedLongAgo('obs-live');

      await purge();

      expect(await observationExists('obs-live'), isTrue);
    });

    test('a tombstone inside the window is kept', () async {
      final recentlyDeleted = now
          .subtract(const Duration(days: 30))
          .toIso8601String();
      await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-1', deletedAt: recentlyDeleted),
          ],
        },
      );

      final report = await purge();

      expect(report.purgedAnything, isFalse);
      expect(await observationExists('obs-1'), isTrue);
    });

    test('the floor never regresses', () async {
      final created = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-1', deletedAt: '2020-06-01T12:00:00.000Z'),
          ],
        },
      );
      await receivedLongAgo('obs-1');
      await purge();
      final first = await connection.runTx(
        (tx) => TombstoneRetentionService(tx).floorFor(projectA),
      );
      expect(first, created.highestServerSeq);

      // A second run with nothing left to purge must not lower the floor —
      // a regressing floor would let the server claim it can still describe
      // deletes it has already destroyed.
      await purge();

      expect(
        await connection.runTx(
          (tx) => TombstoneRetentionService(tx).floorFor(projectA),
        ),
        first,
      );
    });
  });
}

extension on SyncCursorKey {
  SyncCursorKey copyForDevice(String deviceId) =>
      SyncCursorKey(userId: userId, deviceId: deviceId, projectId: projectId);
}

Future<void> _seed(Connection connection) async {
  final at = DateTime.utc(2020, 1, 1, 12);
  await connection.runTx((tx) async {
    await tx.execute(
      'INSERT INTO ${quoted(Tables.users)} '
      '(user_id, first_name, last_name, email, created_at, updated_at, '
      'revision) '
      r"VALUES ('user-alice', 'Alice', 'Ranger', 'alice@example.com', $1, $1, 0)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.projects)} '
      '(project_id, project_name, owner_user_id, creation_date, datum, '
      'created_at, updated_at, revision, coordinate_format, '
      'triangulation_window_minutes) '
      r"VALUES ('proj-a', 'Field', 'user-alice', $1, 'WGS84', $1, $1, 0, "
      r"'dd', 15)",
      parameters: [at],
    );
  });
}

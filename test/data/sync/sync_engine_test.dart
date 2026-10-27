import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';
import 'package:tritrack/data/sync/sync_engine.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/data/sync/sync_state_store.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';
import 'fake_sync_transport.dart';

/// Task 10.8's acceptance criteria, all against a fake transport with no server
/// (Phase 10's invariant 5):
///
/// - a sync failure leaves the local database exactly as it was;
/// - the app is fully usable with sync permanently failing;
/// - and the inbound direction goes through `ProjectMerger` unchanged.
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

  Map<String, Object?> observation(
    String id, {
    int revision = 1,
    String? updatedAt,
    String notes = 'local',
  }) => {
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
    'notes': notes,
    'created_at': DbCodec.encodeUtc(now),
    'updated_at': updatedAt ?? DbCodec.encodeUtc(now),
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': deviceId,
  };

  Future<void> insertLocal(Map<String, Object?> row) =>
      appDb.raw.insert(Tables.observations, row);

  group('push', () {
    test(
      'offers locally-changed rows and records what the server applied',
      () async {
        await insertLocal(observation('obs-1'));
        final report = await engine().run(projectId);

        expect(report.pushed, greaterThan(0));
        expect(report.applied, greaterThan(0));
        expect(transport.serverRow(Tables.observations, _obsKey('obs-1')), isNotNull);
      },
    );

    test(
      'a row that loses last-write-wins is reported, not swallowed',
      () async {
        // Silent loss is the wrong default for a primary scientific record.
        transport.seedServerRow(
          Tables.observations,
          observation('obs-1', revision: 9, notes: 'server'),
        );
        await insertLocal(observation('obs-1', revision: 1));

        final report = await engine().run(projectId);
        expect(report.lostToServer, contains(_obsRef('obs-1')));
      },
    );

    test(
      'a row that loses last-write-wins is durably recorded with what '
      'replaced it',
      () async {
        transport.seedServerRow(
          Tables.observations,
          observation('obs-1', revision: 9, notes: 'server'),
        );
        await insertLocal(observation('obs-1', revision: 1, notes: 'local'));

        await engine().run(projectId);

        final conflicts = await SyncConflictStore(
          appDb.raw,
        ).unreviewed(projectId);
        final match = conflicts.singleWhere(
          (c) => c.tableName == Tables.observations,
        );
        expect(match.localSnapshot['notes'], 'local');
        expect(match.incomingSnapshot?['notes'], 'server');
        final changed = match.changedFields;
        expect(
          changed.any(
            (f) => f.field == 'notes' && f.was == 'local' && f.replacedBy == 'server',
          ),
          isTrue,
        );

        // And the row now authoritative locally really is the server's.
        final local = await appDb.raw.query(
          Tables.observations,
          where: 'observation_id = ?',
          whereArgs: ['obs-1'],
        );
        expect(local.single['notes'], 'server');
      },
    );

    test('a confirmed row is not re-offered by the next sync', () async {
      // An old row and a current one. Both are offered once and accepted, and
      // neither comes back — selection is "what the server has not confirmed",
      // not "what is newer than a mark" (task 10.33).
      await insertLocal(
        observation(
          'obs-old',
          updatedAt: DbCodec.encodeUtc(now.subtract(const Duration(days: 5))),
        ),
      );
      await insertLocal(observation('obs-current'));

      await engine().run(projectId);
      expect(
        transport.pushes.first.rows[Tables.observations]!.map(
          (r) => r['observation_id'],
        ),
        containsAll(['obs-old', 'obs-current']),
      );

      transport.pushes.clear();
      await engine().run(projectId);
      final reoffered = transport.pushes.isEmpty
          ? <Object?>[]
          : (transport.pushes.first.rows[Tables.observations] ?? const []).map(
              (r) => r['observation_id'],
            );
      expect(reoffered, isNot(contains('obs-old')));
      expect(reoffered, isNot(contains('obs-current')));
    });

    test('rows sharing one timestamp all go up, however small the batch',
        () async {
      // What the `>=` watermark bias used to buy, asserted directly instead.
      // Over-pushing costs bandwidth and under-pushing loses an observation, so
      // the old scheme re-offered every row sharing the boundary timestamp —
      // which also meant enough rows on one timestamp could fill every batch
      // forever and never let a later one through. A bulk import writes exactly
      // that shape: many rows carrying one sender's clock (task 6.3).
      final shared = DbCodec.encodeUtc(now.subtract(const Duration(days: 3)));
      for (var i = 0; i < 6; i++) {
        await insertLocal(observation('obs-tied-$i', updatedAt: shared));
      }

      for (var round = 0; round < 6; round++) {
        await engine().run(projectId, batchSize: 2);
      }
      for (var i = 0; i < 6; i++) {
        expect(
          transport.serverRow(Tables.observations, _obsKey('obs-tied-$i')),
          isNotNull,
        );
      }
    });

    test('an unchanged re-offer records no phantom overwritten edit', () async {
      // The server answers `lost_to_server` for any row it did not apply,
      // including one identical to its stored copy — but nothing was
      // superseded, and recording that as "an edit you made was superseded" is
      // how a review surface fills with noise and stops being read. Task 10.33
      // made re-offers rare rather than every-round; this asserts the guard
      // still holds when one does happen.
      await insertLocal(observation('obs-1'));
      await engine().run(projectId);
      await engine().run(projectId);

      final conflicts = await SyncConflictStore(appDb.raw).unreviewed(projectId);
      expect(conflicts, isEmpty);
    });

    test('forgetting the receipts re-offers every row', () async {
      // The escape hatch `SyncStateStore.resetPushWatermark` used to be.
      await insertLocal(observation('obs-1'));
      await engine().run(projectId);
      await SyncRowReceiptStore(appDb.raw).forgetProject(projectId);
      transport.pushes.clear();

      await engine().run(projectId);
      expect(transport.pushes.first.rowCount, greaterThan(0));
    });

    test('an accepted row is not offered again', () async {
      // The other half of task 10.33, and what makes the batch limit safe: a
      // confirmed row leaves the pending set, so every round makes forward
      // progress. The old `>=` watermark re-offered every row sharing the
      // boundary timestamp, which with enough rows on one timestamp could
      // consume every batch forever.
      await insertLocal(observation('obs-1'));
      await engine().run(projectId);
      transport.pushes.clear();

      final report = await engine().run(projectId);
      expect(report.pushed, 0);
      expect(transport.pushes, isEmpty, reason: 'nothing left to offer');
    });
  });

  group('the batch limit cannot strand a row (task 10.33)', () {
    // Found by a regression test written for task 10.28. `_collectChangedRows`
    // walked tables in FK order under one shared batch limit and the watermark
    // then advanced to the highest row *offered* — so rows in later tables the
    // limit never reached sat below the new watermark and were never selected
    // again. Not a refusal, not a conflict, not counted as pending: a record
    // that exists only on the device while the app reports a clean sync.

    /// Fills tables the push walks **before** `Observations`, with [count]
    /// tags and the project links that make them this project's, so a small
    /// batch is exhausted before the walk ever reaches a bearing.
    ///
    /// **This helper has now been rewritten twice by narrowings of the push,
    /// which is worth noticing rather than just fixing.** It originally filled
    /// `Users` with unreferenced rows; task 11.41 made a global row a
    /// candidate only when the project reaches it, so each filler had to be
    /// given a membership; task 11.43 stopped a device offering a `Users` or
    /// `Project_Memberships` row about anybody but the signed-in user at all,
    /// so neither works. Tags are the durable choice: they are shared project
    /// vocabulary that this device may genuinely author, which is precisely the
    /// side of 11.43's rule that is not going to move.
    ///
    /// Each tag needs its `Project_Tags` link or it is not reachable from this
    /// project and fills nothing — the 11.41 condition, still in force. Both
    /// tables sit ahead of `Observations` in the walk, so the [count] here
    /// produces `2 * count` rows of filler.
    Future<void> fillEarlyTable(int count, {required DateTime at}) async {
      final stamp = DbCodec.encodeUtc(at);
      for (var i = 0; i < count; i++) {
        await appDb.raw.insert(Tables.tags, {
          'tag_id': 'tag-filler-$i',
          'project_id': projectId,
          'lineage_id': 'tag-filler-$i',
          'frequency_mhz': 150.100 + i,
          'tag_name': 'Filler $i',
          'status': 'active',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 0,
          'last_modified_by': userId,
          'origin_device_id': deviceId,
        });
      }
    }

    test('a row a full batch never reached is offered by the next round',
        () async {
      // The stranded row is deliberately *older* than everything that fills the
      // batch, which is what put it below the advancing watermark.
      final older = DbCodec.encodeUtc(now.subtract(const Duration(days: 7)));
      await insertLocal(observation('obs-stranded', updatedAt: older));
      await fillEarlyTable(6, at: now);

      // Round after round with a batch far too small to reach Observations in
      // one go. Under the watermark scheme the first round advanced past
      // `obs-stranded` and no later round ever selected it again.
      for (var round = 0; round < 6; round++) {
        await engine().run(projectId, batchSize: 3);
      }

      expect(
        transport.serverRow(Tables.observations, _obsKey('obs-stranded')),
        isNotNull,
        reason: 'the batch limit stranded a row below the watermark',
      );
    });

    test(
      'an imported older-clock replica is uploaded, however far the device '
      'has moved on',
      () async {
        // The realistic trigger, and it needs no batch limit at all. Task 6.3
        // copies the sender's sync clock verbatim onto an imported replica, so
        // a colleague's observation shared today carries *last week's*
        // `updated_at` — below the watermark of any device that has ever
        // synced.
        await insertLocal(observation('obs-mine'));
        await engine().run(projectId);
        expect(transport.serverRow(Tables.observations, _obsKey('obs-mine')), isNotNull);

        // Now the colleague's record arrives, dated a week ago.
        await insertLocal(
          observation(
            'obs-replica',
            updatedAt: DbCodec.encodeUtc(now.subtract(const Duration(days: 7))),
            notes: 'from a colleague',
          ),
        );

        await engine().run(projectId);
        expect(
          transport.serverRow(Tables.observations, _obsKey('obs-replica')),
          isNotNull,
          reason: "a colleague's record must not be stranded by its own clock",
        );
      },
    );

    test('a row the batch never reached is counted as pending, not as synced',
        () async {
      final older = DbCodec.encodeUtc(now.subtract(const Duration(days: 7)));
      await insertLocal(observation('obs-stranded', updatedAt: older));
      await fillEarlyTable(6, at: now);
      await engine().run(projectId, batchSize: 3);

      // The number the status line shows has to be the number of rows the next
      // push will actually offer — a stranded row used to be in neither.
      expect(
        await SyncEngine.pendingRowCount(appDb.raw, projectId, userId),
        greaterThan(0),
      );
    });

    test('no project size wedges the push', () async {
      // The reason the obvious interim patch (clamp the shared limit to the
      // truncation point) was rejected: it trades silent loss for a stalled
      // sync on any project bigger than one batch.
      for (var i = 0; i < 12; i++) {
        await insertLocal(
          observation(
            'obs-$i',
            updatedAt: DbCodec.encodeUtc(now.add(Duration(minutes: i))),
          ),
        );
      }
      await fillEarlyTable(6, at: now);

      var rounds = 0;
      while (await SyncEngine.pendingRowCount(appDb.raw, projectId, userId) > 0) {
        await engine().run(projectId, batchSize: 3);
        rounds++;
        expect(
          rounds,
          lessThan(30),
          reason: 'the push stopped making progress',
        );
      }
      for (var i = 0; i < 12; i++) {
        expect(transport.serverRow(Tables.observations, _obsKey('obs-$i')), isNotNull);
      }
    });

    test('rows the batch never reached survive an interrupted round', () async {
      // The push writes receipts only for rows the server accounted for, so a
      // round that dies mid-flight leaves everything it never sent pending.
      for (var i = 0; i < 5; i++) {
        await insertLocal(observation('obs-$i'));
      }
      transport.permanentFailure = const SyncTransportException('unreachable');
      await expectLater(
        engine().run(projectId, batchSize: 2),
        throwsA(isA<SyncTransportException>()),
      );

      transport.permanentFailure = null;
      for (var round = 0; round < 8; round++) {
        await engine().run(projectId, batchSize: 2);
      }
      for (var i = 0; i < 5; i++) {
        expect(transport.serverRow(Tables.observations, _obsKey('obs-$i')), isNotNull);
      }
    });
  });

  group('a refused row is never silently lost (finding D-3, task 10.28)', () {
    // The path this group exists for, end to end: a user saves a colleague's
    // shared observation, which writes a faithful replica of the colleague's
    // row (task 6.3). On the next sync task 10.20's row-naming invariant
    // refuses it — correctly — because that colleague is not on this project.
    // Before this task, the row was dropped from the response, the watermark
    // advanced past it, it was never re-offered, and the app said "Synced."
    //
    // Nothing in the fake transport could deny a row until now, which is
    // exactly why 700+ passing tests never saw it.
    final refusedAt = DbCodec.encodeUtc(now.subtract(const Duration(days: 2)));
    final refusedKey = _obsRef('obs-refused');

    Future<void> seedRefusedAndOkRows() async {
      await insertLocal(
        observation('obs-refused', updatedAt: refusedAt, notes: 'replica'),
      );
      await insertLocal(observation('obs-ok'));
      transport.refuseRows[refusedKey] = SyncRowOutcome.unauthorized;
    }

    test('the refused row survives locally and never reaches the server', () async {
      await seedRefusedAndOkRows();
      await engine().run(projectId);

      final local = await appDb.raw.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-refused'],
      );
      expect(local.single['notes'], 'replica');
      expect(transport.serverRow(Tables.observations, _obsKey('obs-refused')), isNull);
      // ...and the rest of the push was unaffected: a refusal must not hold up
      // the data that *can* go.
      expect(transport.serverRow(Tables.observations, _obsKey('obs-ok')), isNotNull);
    });

    test('the refusal is reported, with a reason', () async {
      await seedRefusedAndOkRows();
      final report = await engine().run(projectId);

      expect(report.refused, hasLength(1));
      expect(report.refused.single.outcomeKey, refusedKey);
      expect(report.refused.single.reason, HeldRowReason.notPermitted);
      expect(report.refused.single.rowUpdatedAt, refusedAt);
      // And it is not misfiled as a last-write-wins loss, which is the opposite
      // situation: a lost row *is* on the server.
      expect(report.lostToServer, isNot(contains(refusedKey)));
    });

    test('the refusal is durably held, not just tallied', () async {
      await seedRefusedAndOkRows();
      await engine().run(projectId);

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held, hasLength(1));
      expect(held.single.rowKey, _obsKey('obs-refused'));
      expect(held.single.reason, HeldRowReason.notPermitted);
      expect(held.single.heldUpdatedAt, refusedAt);
    });

    test('no progress is recorded past the refused row', () async {
      await seedRefusedAndOkRows();
      await engine().run(projectId);

      // Task 10.28 asserted this as "the watermark was clamped to the refused
      // row's timestamp". There is no watermark now (task 10.33), and the
      // invariant it approximated is stated directly: the refused row has no
      // receipt, so nothing has recorded it as reaching the server — while the
      // accepted row beside it has one.
      expect(await _receiptFor(appDb, projectId, 'obs-refused'), isNull);
      expect(await _receiptFor(appDb, projectId, 'obs-ok'), isNotNull);
    });

    test('no run can report success while the row is held', () async {
      await seedRefusedAndOkRows();
      final first = await engine().run(projectId);
      expect(first.heldCount, 1);
      expect(first.everythingReachedTheServer, isFalse);

      // The round *after* the refusal is the one that used to lie: it refuses
      // nothing new, so a report built only from this round's outcomes looks
      // perfectly clean. The durable count is what carries the truth forward.
      final second = await engine().run(projectId);
      expect(second.refused, isEmpty);
      expect(second.heldCount, 1);
      expect(
        second.everythingReachedTheServer,
        isFalse,
        reason: 'a later clean round must not clear a standing refusal',
      );

      // Including across a restart: nothing about this lives in memory.
      expect(await SyncEngine.heldRowCount(appDb.raw, projectId), 1);
    });

    test('a held row is not re-offered while it is unchanged', () async {
      // "Held and explained," not "retried forever": the refusal is permanent
      // until somebody changes the project's membership, so re-sending the same
      // bytes every few minutes achieves nothing.
      await seedRefusedAndOkRows();
      await engine().run(projectId);
      transport.pushes.clear();

      await engine().run(projectId);
      final offered = transport.pushes
          .expand((p) => p.rows[Tables.observations] ?? const [])
          .map((r) => r['observation_id']);
      expect(offered, isNot(contains('obs-refused')));
      // Nor is anything else: task 10.28's clamp used to drag the accepted rows
      // around it back onto the wire every round, which was the price of a
      // watermark that could not represent one held row. With per-row receipts
      // there is nothing left to offer at all.
      expect(offered, isEmpty);
    });

    test('a held row does not also count as pending upload', () async {
      // Two different statements with two different remedies — "it will go on
      // its own" and "it will not" — so one row must not appear in both.
      await insertLocal(observation('obs-refused', notes: 'replica'));
      transport.refuseRows[refusedKey] = SyncRowOutcome.unauthorized;
      await engine().run(projectId);

      final pending = await SyncEngine.pendingRowCount(appDb.raw, projectId, userId);
      // Zero, not two: the seeded Users and Projects rows were accepted and
      // have receipts, so they are no longer waiting for anything. Under the
      // watermark scheme they sat on the boundary timestamp and the `>=` bias
      // re-offered them every round, so "pending" included two rows that were
      // already on the server. The held observation is in neither number.
      expect(pending, 0);
    });

    test('editing a held row puts it back on the wire', () async {
      await seedRefusedAndOkRows();
      await engine().run(projectId);

      // The user corrects the record (or anything else touches it).
      await appDb.raw.update(
        Tables.observations,
        {
          'notes': 'corrected',
          'revision': 2,
          'updated_at': DbCodec.encodeUtc(now.add(const Duration(hours: 1))),
        },
        where: 'observation_id = ?',
        whereArgs: ['obs-refused'],
      );
      transport.refuseRows.clear();
      transport.pushes.clear();

      final report = await engine().run(projectId);
      final offered = transport.pushes
          .expand((p) => p.rows[Tables.observations] ?? const [])
          .map((r) => r['observation_id']);
      expect(offered, contains('obs-refused'));
      expect(transport.serverRow(Tables.observations, _obsKey('obs-refused')), isNotNull);

      // Accepted, so it stops being held — a warning that outlives its cause
      // is the next silent-loss bug waiting to happen.
      expect(report.heldCount, 0);
      expect(report.everythingReachedTheServer, isTrue);
      final rows = await appDb.raw.query(SyncHeldRowStore.table);
      expect(rows.single['resolved_at_utc'], isNotNull);
    });

    test('releasing a held row re-offers it as it stands', () async {
      // What the status screen's "Try again" does, for the case the app cannot
      // detect: the project owner has added the colleague, so the same bytes
      // will now be accepted.
      await seedRefusedAndOkRows();
      await engine().run(projectId);
      await engine().run(projectId);

      await SyncHeldRowStore(appDb.raw).release(
        projectId: projectId,
        tableName: Tables.observations,
        rowKey: _obsKey('obs-refused'),
      );
      transport.refuseRows.clear();
      transport.pushes.clear();

      final report = await engine().run(projectId);
      expect(transport.serverRow(Tables.observations, _obsKey('obs-refused')), isNotNull);
      expect(report.heldCount, 0);
    });

    test('a still-refused row is held again, not duplicated', () async {
      await seedRefusedAndOkRows();
      await engine().run(projectId);
      await SyncHeldRowStore(appDb.raw).release(
        projectId: projectId,
        tableName: Tables.observations,
        rowKey: _obsKey('obs-refused'),
      );

      final report = await engine().run(projectId);
      expect(report.heldCount, 1);
      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held, hasLength(1));
      expect(held.single.refusalCount, 2);
      expect(held.single.heldUpdatedAt, refusedAt);
    });

    test('held rows do not stall a batch behind them', () async {
      // The failure this guards against is worse than the one it comes from: if
      // held rows consumed batch slots, a batch whose earliest rows are all held
      // would come back empty, the watermark would not move, and every row
      // behind them would be stranded — one refused record stopping sync
      // altogether.
      for (var i = 0; i < 2; i++) {
        await insertLocal(
          observation(
            'obs-held-$i',
            updatedAt: DbCodec.encodeUtc(now.add(const Duration(hours: 1))),
          ),
        );
        transport.refuseRows[_obsRef('obs-held-$i')] =
            SyncRowOutcome.unauthorized;
      }
      final first = await engine().run(projectId);
      expect(first.heldCount, 2);

      // New work arrives behind the two held rows, which now sit at the
      // watermark — so they are the first thing any batch selects.
      for (var i = 0; i < 3; i++) {
        await insertLocal(
          observation(
            'obs-later-$i',
            updatedAt: DbCodec.encodeUtc(now.add(Duration(hours: 2 + i))),
          ),
        );
      }

      // A batch size the two held rows would fill entirely on their own.
      for (var round = 0; round < 3; round++) {
        await engine().run(projectId, batchSize: 2);
      }
      for (var i = 0; i < 3; i++) {
        expect(
          transport.serverRow(Tables.observations, _obsKey('obs-later-$i')),
          isNotNull,
          reason: 'obs-later-$i never got past the held rows',
        );
      }
      expect(await SyncEngine.heldRowCount(appDb.raw, projectId), 2);
    });

    test('a row rejected as invalid is held too', () async {
      await insertLocal(observation('obs-refused', updatedAt: refusedAt));
      transport.refuseRows[refusedKey] = SyncRowOutcome.invalid;

      final report = await engine().run(projectId);
      expect(report.refused.single.reason, HeldRowReason.rejected);
      expect(report.heldCount, 1);
      expect(await _receiptFor(appDb, projectId, 'obs-refused'), isNull);
    });

    test('a row the server says nothing about is held, not assumed applied', () async {
      // Version skew: the server drops rows for a table it does not know, so
      // the outcome map simply has no entry. Silence is not consent.
      await insertLocal(observation('obs-refused', updatedAt: refusedAt));
      transport.ignoreRows.add(refusedKey);

      final report = await engine().run(projectId);
      expect(report.refused.single.reason, HeldRowReason.unaccounted);
      expect(report.refused.single.rowUpdatedAt, refusedAt);
      expect(report.heldCount, 1);
      expect(await _receiptFor(appDb, projectId, 'obs-refused'), isNull);
      expect(transport.serverRow(Tables.observations, _obsKey('obs-refused')), isNull);
    });

    test("a refused replica of a colleague's bearing is held — the case that "
        'actually happens', () async {
      // Importing a colleague's observation writes a `Users` row naming them
      // *and* their bearing, in one transaction (task 6.3). Task 11.24's rule
      // refuses the bearing, because a record that names an author must name
      // the caller.
      //
      // **This test has been corrected twice by findings, and both are worth
      // keeping in view.** It first inserted only the `Users` row, on the
      // reasoning that `Users` is global "so it goes up on every sync" — true
      // at the time, and task 11.41's defect. It then refused that `Users` row,
      // which was task 11.43's defect: a device no longer offers a record about
      // somebody else's identity at all, because the server keeps that record
      // itself and refuses every device that offers one. So the row that is
      // *legitimately* offered and refused here is the colleague's **bearing** —
      // field data the server has no other way to obtain, held and named and
      // clearing when their own device sends it. That is §4.17's accepted cost,
      // and it is the case this test now measures.
      final stamp = DbCodec.encodeUtc(now.subtract(const Duration(days: 3)));
      await appDb.raw.insert(Tables.users, {
        'user_id': 'user-colleague',
        'first_name': 'Ada',
        'last_name': 'Ruiz',
        'email': 'ada@example.com',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': 'user-colleague',
        'origin_device_id': 'device-B',
      });
      await insertLocal({
        ...observation('obs-colleague', notes: "the colleague's replica"),
        'user_id': 'user-colleague',
        'last_modified_by': 'user-colleague',
        'updated_at': stamp,
      });
      transport.refuseRows['${Tables.observations}/${_obsKey('obs-colleague')}'] =
          SyncRowOutcome.unauthorized;

      final report = await engine().run(projectId);
      expect(report.heldCount, 1);
      expect(report.refused.single.tableName, Tables.observations);
      expect(
        await SyncRowReceiptStore(appDb.raw).ackedUpdatedAt(
          projectId: projectId,
          tableName: Tables.observations,
          rowKey: _obsKey('obs-colleague'),
        ),
        isNull,
      );

      // And the colleague's `Users` row was never put on the wire — task
      // 11.43. Offering it would have produced a second refusal about a record
      // the server maintains itself, with nothing the user could do about it.
      final offered = {
        for (final push in transport.pushes)
          for (final entry in push.rows.entries)
            for (final row in entry.value)
              '${entry.key}/${syncRowKey(syncTablesByName[entry.key]!, row)}',
      };
      expect(offered, isNot(contains('${Tables.users}/user-colleague')));

      final local = await appDb.raw.query(
        Tables.users,
        where: 'user_id = ?',
        whereArgs: ['user-colleague'],
      );
      expect(local, hasLength(1), reason: 'the replica is kept');
    });

    test('a refusal is recorded before any progress is', () async {
      // The hold is written before any receipt, so a crash between the two
      // re-offers rows rather than forgetting them. Asserted the only way it
      // can be from outside: the hold exists whenever a receipt does.
      await insertLocal(observation('obs-refused', updatedAt: refusedAt));
      await insertLocal(observation('obs-ok'));
      transport.refuseRows[refusedKey] = SyncRowOutcome.unauthorized;
      await engine().run(projectId);

      expect(
        await SyncRowReceiptStore(appDb.raw).count(projectId),
        greaterThan(0),
      );
      expect(await SyncEngine.heldRowCount(appDb.raw, projectId), 1);
    });
  });

  group('pull', () {
    test('merges server rows into the local database', () async {
      transport.seedServerRow(
        Tables.observations,
        observation('obs-remote', notes: 'from another device'),
      );

      final report = await engine().run(projectId);
      expect(report.pulled, greaterThan(0));

      final local = await appDb.raw.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-remote'],
      );
      expect(local.single['notes'], 'from another device');
    });

    test('a pulled row does not beat a newer local edit', () async {
      // `preferIncoming` is deliberately not used — last-write-wins is the rule.
      await insertLocal(observation('obs-1', revision: 9, notes: 'local wins'));
      transport.seedServerRow(
        Tables.observations,
        observation('obs-1', revision: 2, notes: 'stale server'),
      );

      await engine().run(projectId);
      final local = await appDb.raw.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-1'],
      );
      expect(local.single['notes'], 'local wins');
    });

    test('pages until exhausted, acking each page', () async {
      for (var i = 0; i < 7; i++) {
        transport.seedServerRow(Tables.observations, observation('obs-$i'));
      }
      final report = await engine().run(projectId, batchSize: 3);

      // Every seeded observation arrived. (The total pulled is higher: this
      // device's own pushed Users/Projects rows come back too, which is
      // correct — it has to learn the server's authoritative copy — and they
      // merge to no-ops.)
      final local = await appDb.raw.query(Tables.observations);
      expect(local.length, 7);
      expect(report.pagesPulled, greaterThan(1));
      expect(transport.ackedCursors, isNotEmpty);
      // Acks are monotonic.
      for (var i = 1; i < transport.ackedCursors.length; i++) {
        expect(
          transport.ackedCursors[i],
          greaterThan(transport.ackedCursors[i - 1]),
        );
      }
    });

    test('progress reports pages and a decreasing remaining count', () async {
      for (var i = 0; i < 7; i++) {
        transport.seedServerRow(Tables.observations, observation('obs-$i'));
      }
      final seen = <SyncProgress>[];
      await engine().run(projectId, batchSize: 3, onProgress: seen.add);

      final pulling = seen.where((p) => p.phase == SyncPhase.pulling).toList();
      expect(pulling, isNotEmpty);
      expect(seen.last.phase, SyncPhase.done);
      // An indeterminate spinner is what this replaces.
      expect(pulling.map((p) => p.rowsRemaining).last, 0);
    });

    test('the cursor advances only after a page commits', () async {
      transport.seedServerRow(Tables.observations, observation('obs-1'));
      expect(await state.cursor(projectId), 0);
      await engine().run(projectId);
      expect(await state.cursor(projectId), greaterThan(0));
    });
  });

  group('failure leaves the local database exactly as it was', () {
    test('an unreachable server changes nothing locally', () async {
      await insertLocal(observation('obs-1'));
      final before = await appDb.raw.query(Tables.observations);
      final usersBefore = await appDb.raw.query(Tables.users);

      transport.permanentFailure = const SyncTransportException('unreachable');
      await expectLater(
        engine().run(projectId),
        throwsA(isA<SyncTransportException>()),
      );

      expect(await appDb.raw.query(Tables.observations), before);
      expect(await appDb.raw.query(Tables.users), usersBefore);
    });

    test(
      'a failure mid-pull keeps the pages already committed and no more',
      () async {
        for (var i = 0; i < 9; i++) {
          transport.seedServerRow(Tables.observations, observation('obs-$i'));
        }
        // Two pages succeed, then the link drops.
        transport.failPullAfterPages = 2;

        await expectLater(
          engine().run(projectId, batchSize: 3),
          throwsA(isA<SyncTransportException>()),
        );

        // Some pages committed, not all — a partial result, kept.
        final partial = (await appDb.raw.query(Tables.observations)).length;
        expect(partial, greaterThan(0));
        expect(partial, lessThan(9));
        final cursorAfterFailure = await state.cursor(projectId);
        expect(cursorAfterFailure, greaterThan(0));

        // Resuming from the stored cursor completes the rest — nothing lost, and
        // it does not restart from zero.
        transport.failPullAfterPages = null;
        await engine().run(projectId, batchSize: 3);
        expect((await appDb.raw.query(Tables.observations)).length, 9);
        expect(await state.cursor(projectId), greaterThan(cursorAfterFailure));
      },
    );

    test(
      'a failed push records no progress for unsent rows',
      () async {
        await insertLocal(observation('obs-1'));
        transport.permanentFailure = const SyncTransportException(
          'unreachable',
        );
        await expectLater(
          engine().run(projectId),
          throwsA(isA<SyncTransportException>()),
        );
        expect(await SyncRowReceiptStore(appDb.raw).count(projectId), 0);

        // Recovering offers the row that never made it.
        transport.permanentFailure = null;
        final report = await engine().run(projectId);
        expect(report.applied, greaterThan(0));
        expect(transport.serverRow(Tables.observations, _obsKey('obs-1')), isNotNull);
      },
    );

    test(
      'sync permanently failing leaves local reads and writes working',
      () async {
        // The headline promise: the app is fully usable with sync broken.
        transport.permanentFailure = const SyncTransportException(
          'unreachable',
        );

        for (var attempt = 0; attempt < 3; attempt++) {
          await expectLater(
            engine().run(projectId),
            throwsA(isA<SyncTransportException>()),
          );
        }

        // Recording still works...
        await insertLocal(observation('obs-after-failure'));
        // ...and reading still works.
        final rows = await appDb.raw.query(Tables.observations);
        expect(
          rows.map((r) => r['observation_id']),
          contains('obs-after-failure'),
        );
        // ...and the cursor never moved.
        expect(await state.cursor(projectId), 0);
      },
    );
  });

  group('project scoping', () {
    test('another project\'s local rows are not pushed', () async {
      await _seedSecondProject(appDb, now: now);
      await insertLocal(observation('obs-mine'));
      await appDb.raw.insert(Tables.observations, {
        ...observation('obs-other'),
        'project_id': 'proj-2',
      });

      await engine().run(projectId);
      final pushed = transport.pushes.first.rows[Tables.observations]!.map(
        (r) => r['observation_id'],
      );
      expect(pushed, contains('obs-mine'));
      expect(pushed, isNot(contains('obs-other')));
    });
  });
}

/// The `updated_at` the server has confirmed for one observation, or null if it
/// has confirmed none — the successor to "where is the watermark?" (task 10.33).
Future<String?> _receiptFor(
  AppDatabase db,
  String projectId,
  String observationId,
) => SyncRowReceiptStore(db.raw).ackedUpdatedAt(
      projectId: projectId,
      tableName: Tables.observations,
      rowKey: _obsKey(observationId),
    );

/// Since task 10.35 `Observations` is keyed `(observation_id, project_id)`, so
/// the protocol row key for one of these rows is `<id>/<project id>` — the
/// format `syncRowKey` produces and every store, receipt and outcome map uses.
String _obsKey(String observationId) => '$observationId/proj-1';

/// [_obsKey] as the server reports it in a push response's outcome map.
String _obsRef(String observationId) =>
    '${Tables.observations}/${_obsKey(observationId)}';

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

Future<void> _seedSecondProject(AppDatabase db, {required DateTime now}) async {
  final stamp = DbCodec.encodeUtc(now);
  await db.raw.insert(Tables.projects, {
    'project_id': 'proj-2',
    'project_name': 'Deer',
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

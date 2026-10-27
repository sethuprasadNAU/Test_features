import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/sync_held_rows_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// [SyncHeldRowStore] on its own — task 10.28's memory of "the server refused
/// this row," which is what made finding D-3 possible to fix rather than only
/// possible to notice.
void main() {
  late AppDatabase appDb;
  const projectId = 'proj-1';
  final now = DateTime.utc(2026, 8, 1, 12);

  setUp(() async {
    appDb = await AppDatabase.openInMemory();
    await SyncHeldRowStore.ensureTable(appDb.raw);
  });

  tearDown(() => appDb.close());

  SyncHeldRowStore store() => SyncHeldRowStore(appDb.raw);

  Future<void> hold({
    String rowKey = 'obs-1',
    HeldRowReason reason = HeldRowReason.notPermitted,
    String? updatedAt = '2026-08-01T12:00:00.000Z',
    DateTime? at,
  }) => store().hold(
    projectId: projectId,
    tableName: Tables.observations,
    rowKey: rowKey,
    reason: reason,
    rowUpdatedAt: updatedAt,
    at: at ?? now,
  );

  test('a held row is remembered with its reason and timestamp', () async {
    await hold();

    final held = await store().held(projectId);
    expect(held, hasLength(1));
    expect(held.single.tableName, Tables.observations);
    expect(held.single.rowKey, 'obs-1');
    expect(held.single.reason, HeldRowReason.notPermitted);
    expect(held.single.heldUpdatedAt, '2026-08-01T12:00:00.000Z');
    expect(held.single.refusalCount, 1);
    expect(await store().heldCount(projectId), 1);
  });

  test('repeated refusals of one row update it rather than accumulate', () async {
    // The bound task 10.30 had to add server-side, applied here by
    // construction: a refusal is a remote decision that could repeat without
    // limit, so the local record of it is per-row, not per-event.
    for (var i = 0; i < 25; i++) {
      await hold(at: now.add(Duration(minutes: i)));
    }

    final held = await store().held(projectId);
    expect(held, hasLength(1));
    expect(held.single.refusalCount, 25);
    expect(held.single.firstHeldAtUtc, now);
    expect(held.single.lastRefusedAtUtc, now.add(const Duration(minutes: 24)));
  });

  test('resolving stops it counting but keeps the record', () async {
    await hold();
    await store().resolve(
      projectId: projectId,
      tableName: Tables.observations,
      rowKey: 'obs-1',
      at: now,
    );

    expect(await store().heldCount(projectId), 0);
    expect(await store().held(projectId), isEmpty);
    final all = await appDb.raw.query(SyncHeldRowStore.table);
    expect(all, hasLength(1), reason: 'the history is kept, not deleted');
    expect(all.single['resolved_at_utc'], isNotNull);
  });

  test('a refusal after a resolution reopens the same record', () async {
    await hold();
    await store().resolve(
      projectId: projectId,
      tableName: Tables.observations,
      rowKey: 'obs-1',
      at: now,
    );
    await hold(at: now.add(const Duration(days: 1)));

    expect(await store().heldCount(projectId), 1);
    expect(await appDb.raw.query(SyncHeldRowStore.table), hasLength(1));
  });

  test('release clears the suppression without clearing the hold', () async {
    // "Try again" is not "it worked": the row stays counted as not-synced until
    // the server actually takes it.
    await hold();
    await store().release(
      projectId: projectId,
      tableName: Tables.observations,
      rowKey: 'obs-1',
    );

    expect(await store().heldCount(projectId), 1);
    expect((await store().held(projectId)).single.heldUpdatedAt, isNull);
    expect(
      (await store().heldSignatures(projectId))['${Tables.observations}/obs-1'],
      isNull,
    );
  });

  test('signatures carry the offered timestamp, keyed as the wire keys', () async {
    await hold(rowKey: 'obs-1');
    await hold(rowKey: 'obs-2', updatedAt: '2026-08-02T12:00:00.000Z');

    expect(await store().heldSignatures(projectId), {
      '${Tables.observations}/obs-1': '2026-08-01T12:00:00.000Z',
      '${Tables.observations}/obs-2': '2026-08-02T12:00:00.000Z',
    });
  });

  test('holds are scoped to their project', () async {
    await hold();
    await store().hold(
      projectId: 'proj-2',
      tableName: Tables.observations,
      rowKey: 'obs-9',
      reason: HeldRowReason.rejected,
      rowUpdatedAt: null,
      at: now,
    );

    expect(await store().heldCount(projectId), 1);
    expect(await store().heldCount('proj-2'), 1);
    expect((await store().held(projectId)).single.rowKey, 'obs-1');
  });

  group('releasing for retry', () {
    // The rules behind the status screen's "Try again". Until task 10.33 this
    // had to lift two barriers — the hold's suppression *and* the push
    // watermark, which had moved past the row's timestamp — or the button did
    // nothing a user could see. There is no watermark now: selection is "what
    // the server has not confirmed", and a refused row was never confirmed, so
    // lifting the suppression is the whole job.

    Future<HeldRow> heldRow() async => (await store().held(projectId)).single;

    test('lifts suppression so the next push offers the row again', () async {
      await hold();

      await releaseHeldRowForRetry(
        db: appDb.raw,
        projectId: projectId,
        row: await heldRow(),
      );

      // Null, not deleted: a retry is not a resolution, so the row stays
      // counted until the server actually takes it — but it no longer matches
      // the selection's suppression clause.
      expect((await heldRow()).heldUpdatedAt, isNull);
      expect(await store().heldCount(projectId), 1);
    });

    test('a row with no known timestamp needs no special case', () async {
      // This used to fall back to re-offering the entire project, because there
      // was no timestamp to rewind the watermark to. Nothing to rewind now.
      await hold(updatedAt: null);

      await releaseHeldRowForRetry(
        db: appDb.raw,
        projectId: projectId,
        row: await heldRow(),
      );

      expect((await heldRow()).heldUpdatedAt, isNull);
      expect(await store().heldCount(projectId), 1);
    });
  });

  group('outcome classification', () {
    test('accepted outcomes are not held', () {
      expect(HeldRowReason.forOutcome(SyncRowOutcome.inserted), isNull);
      expect(HeldRowReason.forOutcome(SyncRowOutcome.updated), isNull);
      // A lost row is on the server in a newer version — recorded as a
      // conflict, not as a held row.
      expect(HeldRowReason.forOutcome(SyncRowOutcome.lostToServer), isNull);
    });

    test('every refusal outcome maps to a held reason', () {
      // The two that used to hit `continue` and vanish
      // (`sync_engine.dart:201-202` before task 10.28).
      expect(
        HeldRowReason.forOutcome(SyncRowOutcome.unauthorized),
        HeldRowReason.notPermitted,
      );
      expect(
        HeldRowReason.forOutcome(SyncRowOutcome.invalid),
        HeldRowReason.rejected,
      );
    });

    test('every outcome the protocol defines is classified', () {
      // `forOutcome` is an exhaustive switch, so this is really asserting that
      // no future outcome can be added without a decision being made about it:
      // if one is, this file stops compiling.
      for (final outcome in SyncRowOutcome.values) {
        expect(
          () => HeldRowReason.forOutcome(outcome),
          returnsNormally,
          reason: '$outcome has no classification',
        );
      }
    });

    test('every reason still classifies to a distinct stored value', () {
      // The user-facing sentence this used to assert on lives in
      // `HeldRowDetails` since task 11.41 — it has to read the record to say
      // anything useful, and an enum value cannot. Its copy is asserted in
      // `held_row_details_test.dart`, against a real record, which is the only
      // place the properties are meaningful.
      //
      // What is left here is the property this enum does own: a stable stored
      // value per reason, because it is written to a local table.
      final stored = HeldRowReason.values.map((r) => r.db).toList();
      expect(stored.toSet(), hasLength(stored.length));
      for (final reason in HeldRowReason.values) {
        expect(HeldRowReason.fromDb(reason.db), reason);
      }
    });
  });

  group('row keys', () {
    test('round-trips a simple key', () {
      // `Users` is one of the two tables still globally keyed — it is not
      // project-scoped, so a user id names one row anywhere in the database.
      // (`Tags` was a third until task 11.219 made it project-scoped, which
      // is why this case reaches for `Users` now.)
      final table = syncTablesByName[Tables.users]!;
      final key = syncRowKey(table, {'user_id': 'user-1'});
      expect(key, 'user-1');
      final where = syncRowKeyWhere(table, key)!;
      expect(where.where, 'user_id = ?');
      expect(where.args, ['user-1']);
    });

    test('round-trips a composite key', () {
      // The id leads and the scope follows — see `syncTables` for why.
      final table = syncTablesByName[Tables.tags]!;
      final key = syncRowKey(table, {
        'tag_id': 'tag-1',
        'project_id': 'proj-1',
      });
      expect(key, 'tag-1/proj-1');
      final where = syncRowKeyWhere(table, key)!;
      expect(where.where, 'tag_id = ? AND project_id = ?');
      expect(where.args, ['tag-1', 'proj-1']);
    });

    test('a project-scoped row is keyed by id and project together (10.35)',
        () {
      final table = syncTablesByName[Tables.observations]!;
      final key = syncRowKey(table, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
      });
      expect(key, 'obs-1/proj-1');
      final where = syncRowKeyWhere(table, key)!;
      expect(where.where, 'observation_id = ? AND project_id = ?');
      expect(where.args, ['obs-1', 'proj-1']);
      // The same id in another project is a different row, and must not
      // collide with this one.
      expect(
        syncRowKey(table, {'observation_id': 'obs-1', 'project_id': 'proj-2'}),
        isNot(key),
      );
    });

    test('an unkeyable row gets the same placeholder the server reports', () {
      final table = syncTablesByName[Tables.observations]!;
      expect(
        syncRowKey(table, {'observation_id': '', 'project_id': 'proj-1'}),
        unkeyableRowKey,
      );
      expect(syncRowKey(table, const {}), unkeyableRowKey);
      // Half a key names no row either — the failure task 10.35 exists to make
      // impossible.
      expect(syncRowKey(table, {'observation_id': 'obs-1'}), unkeyableRowKey);
      expect(syncRowKeyWhere(table, unkeyableRowKey), isNull);
    });
  });
}

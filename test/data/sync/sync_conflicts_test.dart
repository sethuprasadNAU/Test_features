import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';

/// [SyncConflictStore] is task 10.12's durable half of "an edit you made was
/// superseded" — separate from the engine test that proves *when* a conflict
/// gets recorded, this proves the store itself behaves as a small append-only
/// log: nothing is lost on review, and the generic field-diff is correct.
void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.openInMemory();
  });

  tearDown(() => db.close());

  test('a recorded conflict is returned unreviewed until marked otherwise', () async {
    final store = SyncConflictStore(db.raw);
    await SyncConflictStore.ensureTable(db.raw);

    await store.record(
      projectId: 'proj-1',
      tableName: 'Observations',
      rowKey: 'Observations/obs-1',
      localSnapshot: {'observation_id': 'obs-1', 'notes': 'local'},
      incomingSnapshot: {'observation_id': 'obs-1', 'notes': 'server'},
      detectedAtUtc: DateTime.utc(2026, 8, 7),
    );

    final unreviewed = await store.unreviewed('proj-1');
    expect(unreviewed, hasLength(1));
    expect(unreviewed.single.tableName, 'Observations');

    await store.markReviewed(unreviewed.single.id);
    expect(await store.unreviewed('proj-1'), isEmpty);
  });

  test('conflicts are scoped to their project', () async {
    final store = SyncConflictStore(db.raw);
    await SyncConflictStore.ensureTable(db.raw);

    await store.record(
      projectId: 'proj-1',
      tableName: 'Observations',
      rowKey: 'Observations/obs-1',
      localSnapshot: const {},
      incomingSnapshot: const {},
      detectedAtUtc: DateTime.utc(2026, 8, 7),
    );

    expect(await store.unreviewed('proj-2'), isEmpty);
    expect(await store.unreviewed('proj-1'), hasLength(1));
  });

  test('changedFields reports only fields that actually differ', () {
    final conflict = SyncConflict(
      id: 1,
      tableName: 'Observations',
      rowKey: 'Observations/obs-1',
      detectedAtUtc: DateTime.utc(2026, 8, 7),
      localSnapshot: {
        'observation_id': 'obs-1',
        'notes': 'local edit',
        'signal_strength': 'strong',
      },
      incomingSnapshot: {
        'observation_id': 'obs-1',
        'notes': 'server edit',
        'signal_strength': 'strong',
      },
    );

    final changed = conflict.changedFields;
    expect(changed, hasLength(1));
    expect(changed.single.field, 'notes');
    expect(changed.single.was, 'local edit');
    expect(changed.single.replacedBy, 'server edit');
  });

  test('changedFields is empty when the replacement was never found', () {
    final conflict = SyncConflict(
      id: 1,
      tableName: 'Observations',
      rowKey: 'Observations/obs-1',
      detectedAtUtc: DateTime.utc(2026, 8, 7),
      localSnapshot: {'notes': 'local edit'},
      incomingSnapshot: null,
    );

    expect(conflict.changedFields, isEmpty);
  });
}

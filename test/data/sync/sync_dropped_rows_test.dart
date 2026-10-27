import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_dropped_rows.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// [SyncDroppedRowStore] on its own — task 11.44's memory of "this device
/// would not store this record when the server sent it," the inbound mirror
/// of [SyncHeldRowStore] built to task 10.28's own shape.
void main() {
  late AppDatabase appDb;
  const projectId = 'proj-1';
  final now = DateTime.utc(2026, 8, 28, 12);

  setUp(() async {
    appDb = await AppDatabase.openInMemory();
    await SyncDroppedRowStore.ensureTable(appDb.raw);
  });

  tearDown(() => appDb.close());

  SyncDroppedRowStore store() => SyncDroppedRowStore(appDb.raw);

  RowIssue issue({
    String table = Tables.observations,
    String primaryKeyValue = 'obs-1',
    String field = 'signal_strength',
    String message = 'unknown value "blisteringly_loud"',
  }) => RowIssue(
    table: table,
    primaryKeyValue: primaryKeyValue,
    field: field,
    message: message,
  );

  Future<void> drop({RowIssue? issue_, DateTime? at}) => store().record(
    projectId: projectId,
    issue: issue_ ?? issue(),
    at: at ?? now,
  );

  test('a dropped row is remembered with its field and message', () async {
    await drop();

    final dropped = await store().dropped(projectId);
    expect(dropped, hasLength(1));
    expect(dropped.single.tableName, Tables.observations);
    expect(dropped.single.rowKey, 'obs-1');
    expect(dropped.single.field, 'signal_strength');
    expect(dropped.single.message, 'unknown value "blisteringly_loud"');
    expect(dropped.single.dropCount, 1);
    expect(await store().droppedCount(projectId), 1);
  });

  test('repeated drops of one row update it rather than accumulate', () async {
    // The same bound task 10.30 forced server-side and task 10.28 built
    // client-side for holds: a broken or hostile server could resend the same
    // page endlessly, so the local record is per-row, not per-event.
    for (var i = 0; i < 25; i++) {
      await drop(at: now.add(Duration(minutes: i)));
    }

    final dropped = await store().dropped(projectId);
    expect(dropped, hasLength(1));
    expect(dropped.single.dropCount, 25);
    expect(dropped.single.firstDroppedAtUtc, now);
    expect(
      dropped.single.lastDroppedAtUtc,
      now.add(const Duration(minutes: 24)),
    );
  });

  test('a later drop updates the recorded field and message', () async {
    await drop(issue_: issue(field: 'signal_strength'));
    await drop(
      issue_: issue(field: 'position_source', message: 'unknown value "x"'),
      at: now.add(const Duration(minutes: 1)),
    );

    final dropped = await store().dropped(projectId);
    expect(dropped, hasLength(1));
    expect(dropped.single.field, 'position_source');
    expect(dropped.single.message, 'unknown value "x"');
  });

  test('resolving stops it counting but keeps the record', () async {
    await drop();
    await store().resolve(
      projectId: projectId,
      tableName: Tables.observations,
      rowKey: 'obs-1',
      at: now,
    );

    expect(await store().droppedCount(projectId), 0);
    expect(await store().dropped(projectId), isEmpty);
    final all = await appDb.raw.query(SyncDroppedRowStore.table);
    expect(all, hasLength(1), reason: 'the history is kept, not deleted');
    expect(all.single['resolved_at_utc'], isNotNull);
  });

  test('a drop after a resolution reopens the same record', () async {
    await drop();
    await store().resolve(
      projectId: projectId,
      tableName: Tables.observations,
      rowKey: 'obs-1',
      at: now,
    );
    await drop(at: now.add(const Duration(days: 1)));

    expect(await store().droppedCount(projectId), 1);
    expect(await appDb.raw.query(SyncDroppedRowStore.table), hasLength(1));
  });

  test('drops are scoped to their project', () async {
    await drop();
    await store().record(
      projectId: 'proj-2',
      issue: issue(primaryKeyValue: 'obs-9'),
      at: now,
    );

    expect(await store().droppedCount(projectId), 1);
    expect(await store().droppedCount('proj-2'), 1);
    expect((await store().dropped(projectId)).single.rowKey, 'obs-1');
  });
}

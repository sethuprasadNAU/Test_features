import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.124 — storing *which part* of a record the server refused, and the
/// in-place upgrade that puts the columns on a database that predates them.
///
/// ## The upgrade this file exists for
///
/// `Sync_Held_Rows` is a **client-only** table: it is not in `tableSpecs`, it
/// does not move with `latestSchemaVersion`, and it is created by
/// `ensureTable` on every open rather than by a numbered migration (see the
/// class note on [SyncHeldRowStore]). So "the schema bump ships with its own
/// populated-database upgrade test" means this file rather than a
/// `schema_vN_migration_test.dart` — same obligation, different mechanism.
/// The rows in it are the memory that field data has not reached the server,
/// so the assertion that matters is that **the upgrade keeps every one of
/// them**.
void main() {
  const projectId = 'proj-1';
  final now = DateTime.utc(2026, 9, 2, 12);

  group('the in-place upgrade of a populated table', () {
    /// The table exactly as a build before task 11.124 created it — written
    /// out here rather than reached for from the code, because the point is
    /// to reproduce a shape the code no longer produces. A test that built it
    /// from today's DDL would be upgrading a table that needed no upgrade.
    const createPreviousTable = '''
CREATE TABLE Sync_Held_Rows (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id TEXT NOT NULL,
  table_name TEXT NOT NULL,
  row_key TEXT NOT NULL,
  reason TEXT NOT NULL,
  held_updated_at TEXT,
  first_held_at_utc TEXT NOT NULL,
  last_refused_at_utc TEXT NOT NULL,
  refusal_count INTEGER NOT NULL DEFAULT 1,
  resolved_at_utc TEXT
)''';

    late Database db;

    setUp(() async {
      sqfliteFfiInit();
      db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      await db.execute(createPreviousTable);
      await db.execute(
        'CREATE UNIQUE INDEX Sync_Held_Rows_identity '
        'ON Sync_Held_Rows (project_id, table_name, row_key)',
      );
      // A device holding two records, one of them refused four times — the
      // state this upgrade must not cost anybody.
      await db.insert(SyncHeldRowStore.table, {
        'project_id': projectId,
        'table_name': Tables.observations,
        'row_key': 'obs-1',
        'reason': 'rejected',
        'held_updated_at': '2026-09-01T08:00:00.000Z',
        'first_held_at_utc': '2026-09-01T08:00:00.000Z',
        'last_refused_at_utc': '2026-09-02T08:00:00.000Z',
        'refusal_count': 4,
      });
      await db.insert(SyncHeldRowStore.table, {
        'project_id': projectId,
        'table_name': Tables.users,
        'row_key': 'user-1',
        'reason': 'not_permitted',
        'held_updated_at': null,
        'first_held_at_utc': '2026-09-01T09:00:00.000Z',
        'last_refused_at_utc': '2026-09-01T09:00:00.000Z',
        'refusal_count': 1,
      });
    });

    tearDown(() => db.close());

    test('every held row survives the upgrade, with everything it recorded '
        'about the refusal intact', () async {
      await SyncHeldRowStore.ensureTable(db);

      final held = await SyncHeldRowStore(db).held(projectId);
      expect(held, hasLength(2));

      final observation = held.firstWhere(
        (r) => r.tableName == Tables.observations,
      );
      expect(observation.rowKey, 'obs-1');
      expect(observation.reason, HeldRowReason.rejected);
      expect(observation.heldUpdatedAt, '2026-09-01T08:00:00.000Z');
      expect(observation.refusalCount, 4);
      expect(observation.firstHeldAtUtc, DateTime.utc(2026, 9, 1, 8));
      expect(observation.lastRefusedAtUtc, DateTime.utc(2026, 9, 2, 8));

      final user = held.firstWhere((r) => r.tableName == Tables.users);
      expect(user.reason, HeldRowReason.notPermitted);
      expect(user.heldUpdatedAt, isNull);
      expect(user.refusalCount, 1);
    });

    test('a row held before the columns existed reads as "no detail", which '
        'is what reaches task 11.122\'s honest default', () async {
      await SyncHeldRowStore.ensureTable(db);

      final held = await SyncHeldRowStore(db).held(projectId);
      expect(held.every((r) => r.issueCode == null), isTrue);
      expect(held.every((r) => r.issueField == null), isTrue);
      // Task 11.267's second channel, added the same way and read the same
      // way — a row held before it existed carries no rule either.
      expect(held.every((r) => r.interlockRule == null), isTrue);
    });

    test('the upgrade adds every column it declares, not merely the first '
        'one somebody remembered', () async {
      await SyncHeldRowStore.ensureTable(db);

      final columns = {
        for (final c in await db.rawQuery(
          'PRAGMA table_info(${SyncHeldRowStore.table})',
        ))
          c['name'],
      };
      for (final added in SyncHeldRowStore.addedColumns) {
        expect(columns, contains(added), reason: '$added was not added');
      }
    });

    test('running it a second time is a no-op rather than an error — it runs '
        'on every open', () async {
      await SyncHeldRowStore.ensureTable(db);
      await SyncHeldRowStore.ensureTable(db);
      await SyncHeldRowStore.ensureTable(db);

      expect(await SyncHeldRowStore(db).held(projectId), hasLength(2));
    });

    test('an upgraded table can then store a detail, so the upgrade is not '
        'merely structural', () async {
      await SyncHeldRowStore.ensureTable(db);

      await SyncHeldRowStore(db).hold(
        projectId: projectId,
        tableName: Tables.observations,
        rowKey: 'obs-1',
        reason: HeldRowReason.rejected,
        rowUpdatedAt: '2026-09-02T12:00:00.000Z',
        at: now,
        issueCode: RowIssueCode.textTooLong,
        issueField: 'notes',
      );

      final held = await SyncHeldRowStore(db).held(projectId);
      final observation = held.firstWhere(
        (r) => r.tableName == Tables.observations,
      );
      expect(observation.issueCode, RowIssueCode.textTooLong);
      expect(observation.issueField, 'notes');
      // Still one row: this was the same record refused again.
      expect(held, hasLength(2));
      expect(observation.refusalCount, 5);
    });
  });

  group('what a fresh table stores', () {
    late AppDatabase appDb;

    setUp(() async {
      appDb = await AppDatabase.openInMemory();
      await SyncHeldRowStore.ensureTable(appDb.raw);
    });

    tearDown(() => appDb.close());

    Future<void> hold({RowIssueCode? code, String? field}) =>
        SyncHeldRowStore(appDb.raw).hold(
          projectId: projectId,
          tableName: Tables.users,
          rowKey: 'user-1',
          reason: HeldRowReason.rejected,
          rowUpdatedAt: '2026-09-02T12:00:00.000Z',
          at: now,
          issueCode: code,
          issueField: field,
        );

    test('a detail is stored and read back', () async {
      await hold(code: RowIssueCode.textNotAName, field: 'first_name');

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.issueCode, RowIssueCode.textNotAName);
      expect(held.single.issueField, 'first_name');
    });

    test('a refusal with no detail stores none', () async {
      await hold();

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.issueCode, isNull);
      expect(held.single.issueField, isNull);
    });

    test('a later refusal that explains nothing clears an earlier detail, '
        'rather than leaving yesterday\'s answer on screen', () async {
      await hold(code: RowIssueCode.textNotAName, field: 'first_name');
      await hold();

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.issueCode, isNull);
      expect(held.single.issueField, isNull);
      expect(held.single.refusalCount, 2);
    });

    test('a code written by a newer build reads back as no code, not as a '
        'crash', () async {
      await hold(code: RowIssueCode.textNotAName, field: 'first_name');
      // Exactly what a build that ships a code this one predates would leave
      // behind. Written straight to the column, because no API on this build
      // can produce it — which is the situation being tested.
      await appDb.raw.update(SyncHeldRowStore.table, {
        SyncHeldRowStore.issueCodeColumn: 'text_not_a_haiku',
      });

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.issueCode, isNull);
    });
  });

  // Task 11.267 — the second channel, stored beside the first and read back
  // the same way.
  group('the interlock rule, the second channel', () {
    late AppDatabase appDb;

    setUp(() async {
      appDb = await AppDatabase.openInMemory();
      await SyncHeldRowStore.ensureTable(appDb.raw);
    });

    tearDown(() => appDb.close());

    Future<void> hold({String? interlockRule}) =>
        SyncHeldRowStore(appDb.raw).hold(
          projectId: projectId,
          tableName: Tables.deployments,
          rowKey: 'dep-1',
          reason: HeldRowReason.rejected,
          rowUpdatedAt: '2026-09-02T12:00:00.000Z',
          at: now,
          interlockRule: interlockRule,
        );

    test('a rule is stored and read back', () async {
      await hold(interlockRule: DeploymentInterlock.ruleId);

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.interlockRule, DeploymentInterlock.ruleId);
    });

    test('a refusal with no rule stores none', () async {
      await hold();

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.interlockRule, isNull);
    });

    test('a later refusal that names no rule clears an earlier one, rather '
        'than leaving yesterday\'s answer on screen', () async {
      await hold(interlockRule: DeploymentInterlock.ruleId);
      await hold();

      final held = await SyncHeldRowStore(appDb.raw).held(projectId);
      expect(held.single.interlockRule, isNull);
      expect(held.single.refusalCount, 2);
    });
  });
}

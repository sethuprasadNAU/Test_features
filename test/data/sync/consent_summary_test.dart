import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/sync/consent_summary.dart';
import 'package:tritrack/data/sync/merge_report.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **Task 10.87 — the consent dialog's per-table summary, and finding L-5.**
///
/// L-5: the 40-item list was cut in `syncTables` declaration order, so forty
/// cosmetic renames on `Users` pushed a coordinate rewrite on `Observations`
/// below the fold. The summary has one line per table in a declared order,
/// so there is no fold and the order is not the file's.
void main() {
  MergeFieldChange change(
    String table,
    String rowKey,
    String column, {
    Object? was = 'old',
    Object? becomes = 'new',
  }) => MergeFieldChange(
    table: table,
    rowKey: rowKey,
    column: column,
    was: was,
    becomes: becomes,
  );

  group('the declared order covers every synced table', () {
    test('tableOrder is a permutation of syncTables — derived, refusing '
        'an empty derivation', () {
      final synced = syncTables.map((t) => t.name).toSet();
      expect(synced, isNotEmpty, reason: 'syncTables derived as empty');
      expect(ConsentSummary.tableOrder.toSet(), synced,
          reason: 'a table added to the schema needs a place in the consent '
              'order — it sorts last today, which is a silent choice');
      expect(ConsentSummary.tableOrder.length, synced.length,
          reason: 'a duplicate in tableOrder');
    });

    test('every synced table has a written label, not its column name', () {
      for (final t in syncTables) {
        expect(ConsentSummary.tableLabel(t.name), isNot(contains('_')),
            reason: t.name);
        expect(ConsentSummary.countOf(t.name, 1), isNot(contains('_')));
        expect(ConsentSummary.countOf(t.name, 2), isNot(endsWith('ys')),
            reason: 'a plural nobody would write');
      }
      expect(ConsentSummary.countOf(Tables.users, 1), '1 person');
      expect(ConsentSummary.countOf(Tables.users, 2), '2 people');
      expect(ConsentSummary.countOf(Tables.nonDetections, 3),
          '3 no-signal entries');
    });
  });

  group('finding L-5: the file cannot choose what is seen first', () {
    test('forty Users renames and one coordinate rewrite → the coordinate '
        'rewrite is the first line, and there are two lines', () {
      final padded = [
        for (var i = 0; i < 40; i++)
          change(Tables.users, 'user-$i', 'last_name'),
        change(Tables.observations, 'obs-1/project-1', 'latitude',
            was: 35.19, becomes: 0.0),
      ];
      final summary = ConsentSummary.of(padded);
      expect(summary, hasLength(2));
      expect(summary.first.table, Tables.observations);
      expect(summary.first.columns, ['latitude']);
      expect(summary.last.table, Tables.users);
      expect(summary.last.records, 40);
    });

    test('a table the order does not name sorts last and is not dropped', () {
      final summary = ConsentSummary.of([
        change('Some_Future_Table', 'x', 'y'),
        change(Tables.users, 'u', 'last_name'),
      ]);
      expect(summary.map((t) => t.table), [Tables.users, 'Some_Future_Table']);
    });
  });

  group('at 1,000 rows', () {
    test('a thousand rewritten bearings are one line with the numbers on it',
        () {
      final changes = [
        for (var i = 0; i < 1000; i++) ...[
          change(Tables.observations, 'obs-$i/p', 'latitude',
              was: 35.0, becomes: 0.0),
          change(Tables.observations, 'obs-$i/p', 'longitude',
              was: -111.0, becomes: 0.0),
        ],
        for (var i = 0; i < 12; i++)
          change(Tables.observations, 'obs-$i/p', 'deleted_at',
              was: null, becomes: '2026-09-13T00:00:00.000Z'),
      ];
      final summary = ConsentSummary.of(changes);
      expect(summary, hasLength(1));
      final line = summary.single;
      expect(line.records, 1000);
      expect(line.values, 2012);
      expect(line.removed, 12);
      expect(line.columns, ['deleted_at', 'latitude', 'longitude']);
    });

    test('a membership ended is counted as removed, via the table\'s own '
        'deactivation columns', () {
      final summary = ConsentSummary.of([
        change(Tables.projectMemberships, 'm-1/p', 'end_date',
            was: null, becomes: '2026-09-01'),
      ]);
      expect(summary.single.removed, 1);
    });
  });
}

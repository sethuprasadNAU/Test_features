import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **Task 11.158 — the measurement that licenses the refusal.**
///
/// An instrument that reports "zero rows affected" is worth exactly as much
/// as its ability to report something else. This project has a standing rule
/// about that: a check that cannot distinguish success from its own failure
/// is not a check. So the cases here are, in order: a healthy database (the
/// answer is zero, and it is zero *because Postgres could not have stored a
/// word in a `double precision` column*), a drifted one (the answer is not
/// zero, and it names the column), and a database missing a column (the
/// answer is "could not check", which is neither of the other two).
void main() {
  /// A stand-in database. [types] gives `information_schema`'s answer for
  /// `table.column`; [counts] answers any `count(*)` whose SQL contains one
  /// of its keys.
  Future<List<List<Object?>>> Function(String) fake({
    required Map<String, String> types,
    Map<String, int> counts = const {},
  }) {
    return (sql) async {
      if (sql.contains('pg_control_system')) {
        return [
          ['7300000000000000001'],
        ];
      }
      if (sql.contains('information_schema.columns')) {
        return [
          for (final entry in types.entries)
            [
              entry.key.split('.').first,
              entry.key.split('.').last,
              entry.value,
            ],
        ];
      }
      for (final entry in counts.entries) {
        if (sql.contains(entry.key)) {
          return [
            [entry.value],
          ];
        }
      }
      return [
        [0],
      ];
    };
  }

  /// Every numeric column, typed the way `postgresType` creates it.
  Map<String, String> healthyTypes() => {
    for (final spec in tableSpecs)
      for (final column in spec.columns)
        if (column.type != ColumnType.text)
          '${spec.name}.${column.name}': postgresType(column.type).toLowerCase(),
  };

  test('a healthy database answers zero, and says why it is structurally zero',
      () {
    // Not a claim that a scan found nothing. `double precision` and `bigint`
    // refuse `'north'` at insert time, so the zero is what the column types
    // make impossible.
    return measureNumericPopulation(
      deployment: 'test',
      query: fake(types: healthyTypes()),
    ).then((report) {
      expect(report.scannedTotal, 0);
      expect(report.unanswered, isEmpty);
      expect(report.columns.every((c) => c.typeForbidsIt), isTrue);
      final text = describeNumericPopulation(report);
      expect(text, contains('could never have been stored here'));
      expect(text, contains('Total rows the new rule would newly refuse: 0'));
      expect(text, contains('Deployment: test'));
      // The two lines that stop a zero being filed against the wrong
      // database (task 11.141).
      expect(text, contains('Database cluster id: 7300000000000000001'));
      expect(text, contains('this database holds no rows at all'));
    });
  });

  test('a column that drifted to text is scanned, counted and named',
      () async {
    // **The detection proof.** Without this the instrument could return zero
    // for every database on Earth and nobody would know.
    final types = healthyTypes()
      ..['${Tables.observations}.latitude'] = 'text';
    final report = await measureNumericPopulation(
      deployment: 'test',
      query: fake(types: types, counts: {'"latitude"': 4}),
    );
    expect(report.scannedTotal, 4);
    final text = describeNumericPopulation(report);
    expect(text, contains('${Tables.observations}.latitude is text'));
    expect(text, contains('Rows found: 4'));
    expect(text, contains('Total rows the new rule would newly refuse: 4'));
    expect(text, contains('Stop and ask'));
  });

  test('a column the database does not have reads as "could not check", '
      'never as zero', () async {
    final types = healthyTypes()..remove('${Tables.observations}.elevation');
    final report = await measureNumericPopulation(
      deployment: 'test',
      query: fake(types: types),
    );
    expect(
      report.unanswered.map((c) => '${c.table}.${c.column}'),
      contains('${Tables.observations}.elevation'),
    );
    final text = describeNumericPopulation(report);
    expect(text, contains('COULD NOT CHECK'));
    expect(text, contains('That is not the same as zero rows found'));
  });

  test('the two floors are counted separately from the wrong-type question',
      () async {
    // A negative revision and a zero-minute window are storable in Postgres
    // today — `bigint` accepts both — so unlike the wrong-type case these
    // have to be counted rather than reasoned about.
    final report = await measureNumericPopulation(
      deployment: 'test',
      query: fake(
        types: healthyTypes(),
        counts: {
          'revision < 0': 2,
          'triangulation_window_minutes <= 0': 1,
        },
      ),
    );
    expect(report.scannedTotal, 0, reason: 'no column drifted');
    expect(report.nonPositiveWindowRows, 1);
    expect(report.negativeRevisionRows.values.every((v) => v == 2), isTrue);
    expect(report.floorTotal, greaterThan(0));
    expect(
      describeNumericPopulation(report),
      contains('triangulation window of zero or less: 1'),
    );
  });

  test('a database with rows in it does not get the empty-database note',
      () async {
    final report = await measureNumericPopulation(
      deployment: 'test',
      query: fake(types: healthyTypes(), counts: {'count(*) FROM': 3}),
    );
    expect(report.totalSharedRows, greaterThan(0));
    expect(
      describeNumericPopulation(report),
      isNot(contains('holds no rows at all')),
    );
  });

  test('the columns examined come from the schema, not from a typed list',
      () async {
    // The reason this is a mode of the server binary rather than a SQL
    // snippet: a list of ninety-odd column names in a shell script is a
    // hand-maintained list, and it fails by measuring a smaller database
    // than the one it says it measured.
    final report = await measureNumericPopulation(
      deployment: 'test',
      query: fake(types: healthyTypes()),
    );
    final declared = [
      for (final spec in tableSpecs)
        for (final column in spec.columns)
          if (column.type != ColumnType.text) '${spec.name}.${column.name}',
    ];
    expect(
      report.columns.map((c) => '${c.table}.${c.column}').toList(),
      declared,
    );
    expect(declared, isNotEmpty);
  });
}

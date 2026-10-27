/// **Task 11.158's measurement: how many stored rows would the widened
/// numeric rule newly refuse?**
///
/// ## Why this exists at all
///
/// Until task 11.158 a numeric column holding something that is not a number
/// — `{"latitude": "north"}` — was refused by nothing: `RowValidator` read it
/// with `_num`, got null, and skipped the column. Closing that newly refuses
/// rows that sync today, and this project has a rule about what a widened rule
/// does to rows already in the field. **Measure, then refuse.** This is the
/// measurement, and it is written as a mode of the server binary rather than a
/// SQL snippet in a report for two reasons:
///
/// 1. **The list of numeric columns is derived from `tableSpecs`, never
///    typed.** A hand-written list of ninety-odd columns in a shell script is
///    exactly the hand-maintained list this project keeps finding wrong, and
///    it would be wrong the first time somebody adds a column.
/// 2. **It runs where the database is.** The runtime image carries no Dart
///    SDK and no psql; the server binary is already there.
///
/// ## What it measures, and what it cannot
///
/// It reads **the server's database**, which is the union of everything every
/// device has ever successfully pushed. It cannot read a phone. A row sitting
/// unsynced on a device is not counted here and would meet the new rule on its
/// next push — that limit is printed in the output rather than left to be
/// discovered.
///
/// **Naming the deployment is not decoration** (task 11.141): a run against a
/// throwaway local stack must not be textually indistinguishable from a run
/// against the beta server, or a reassuring zero gets filed against the wrong
/// database.
library;

import 'package:tritrack_sync/tritrack_sync.dart';

import 'postgres_schema.dart';

/// The Postgres types that make a non-numeric value **impossible to store**.
///
/// This is the heart of the answer. `postgresType` maps every
/// [ColumnType.real] to `double precision` and every [ColumnType.integer] to
/// `bigint`, and Postgres refuses `'north'` for either at insert time — so for
/// a column carrying one of these types the count is zero *structurally*,
/// not because a scan happened to find nothing. A column that has drifted to
/// `text` is the only way the count could be anything else, and that case is
/// scanned rather than assumed.
const Set<String> _numericPostgresTypes = {
  'double precision',
  'bigint',
  'integer',
  'smallint',
  'numeric',
  'real',
};

/// One numeric column's answer.
class NumericColumnFinding {
  const NumericColumnFinding({
    required this.table,
    required this.column,
    required this.liveType,
    required this.nonNumericRows,
  });

  final String table;
  final String column;

  /// The type Postgres reports, or null when the column is not in the live
  /// database at all.
  final String? liveType;

  /// Rows holding a value the new rule would refuse, or null when the
  /// question could not be answered for this column.
  final int? nonNumericRows;

  /// True when the column's live type makes a non-number unstorable.
  bool get typeForbidsIt =>
      liveType != null && _numericPostgresTypes.contains(liveType);
}

/// The whole answer, ready to print.
class NumericPopulationReport {
  const NumericPopulationReport({
    required this.deployment,
    required this.clusterIdentifier,
    required this.totalSharedRows,
    required this.columns,
    required this.negativeRevisionRows,
    required this.nonPositiveWindowRows,
  });

  /// Which database this is about — host, database name, and the server's own
  /// idea of where it is. Printed first, every run.
  final String deployment;

  /// **Postgres's own permanent identifier for this database cluster**, set
  /// once at `initdb` and never again.
  ///
  /// The deployment string alone is not enough and that is not a small point:
  /// under compose the host is the service name, so a throwaway local stack
  /// and the beta server both call themselves `postgres:5432`, and a
  /// reassuring zero measured against an empty laptop database reads exactly
  /// like a zero measured against the real one. This number differs between
  /// them. Null when the cluster would not answer.
  final String? clusterIdentifier;

  /// How many rows the shared tables hold in total — the second half of the
  /// same question. A database with nothing in it cannot have anything wrong
  /// in it, and an operator should be able to see which of those two facts
  /// they are reading.
  final int? totalSharedRows;

  final List<NumericColumnFinding> columns;

  /// `revision < 0`, per table, for the tables that have any.
  final Map<String, int> negativeRevisionRows;

  /// `Projects.triangulation_window_minutes <= 0`.
  final int? nonPositiveWindowRows;

  Iterable<NumericColumnFinding> get unanswered =>
      columns.where((c) => c.nonNumericRows == null);

  int get scannedTotal => columns
      .map((c) => c.nonNumericRows ?? 0)
      .fold(0, (a, b) => a + b);

  int get floorTotal =>
      negativeRevisionRows.values.fold(0, (a, b) => a + b) +
      (nonPositiveWindowRows ?? 0);
}

/// Runs the measurement. [query] takes SQL and returns rows of column values —
/// injected so this can be exercised without a database.
Future<NumericPopulationReport> measureNumericPopulation({
  required String deployment,
  required Future<List<List<Object?>>> Function(String sql) query,
}) async {
  // One round trip for every column's live type. `information_schema` is the
  // only place that answers "what could this column hold", and asking it is
  // what turns "a non-number cannot be stored" from a claim about the code
  // into an observation about this database.
  // Asked before anything else, because everything below is only meaningful
  // once a person knows which database it is about (task 11.141).
  String? clusterIdentifier;
  try {
    final rows = await query(
      'SELECT system_identifier::text FROM pg_control_system()',
    );
    clusterIdentifier = rows.isEmpty ? null : '${rows.first.first}';
  } on Object {
    // Not fatal, and not silently absent either: a managed Postgres may not
    // expose this, and the report says so where the number would have been.
    clusterIdentifier = null;
  }

  final liveTypes = <String, String>{};
  final typeRows = await query(
    "SELECT table_name, column_name, data_type FROM information_schema.columns "
    "WHERE table_schema = current_schema()",
  );
  for (final row in typeRows) {
    liveTypes['${row[0]}.${row[1]}'] = '${row[2]}';
  }

  final findings = <NumericColumnFinding>[];
  final negativeRevision = <String, int>{};
  int? window;

  for (final spec in tableSpecs) {
    for (final column in spec.columns) {
      if (column.type == ColumnType.text) continue;
      final live = liveTypes['${spec.name}.${column.name}'];
      int? count;
      if (live == null) {
        // Not in this database. Reported as unanswered rather than as zero:
        // "no rows were read" and "zero rows were found" are different facts
        // and one of them is not evidence.
        count = null;
      } else if (_numericPostgresTypes.contains(live)) {
        // Structurally zero — Postgres would have refused the insert.
        count = 0;
      } else {
        // Drifted to a string type. Now the scan is the only honest answer.
        final scanned = await query(
          'SELECT count(*) FROM ${quoted(spec.name)} '
          'WHERE ${quoted(column.name)} IS NOT NULL '
          "AND ${quoted(column.name)}::text !~ "
          r"'^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$'",
        );
        count = scanned.isEmpty ? null : (scanned.first.first as int?);
      }
      findings.add(
        NumericColumnFinding(
          table: spec.name,
          column: column.name,
          liveType: live,
          nonNumericRows: count,
        ),
      );

      // The two floors task 11.158 added. Unlike the wrong-type case these
      // are storable in Postgres today, so they are counted rather than
      // reasoned about.
      if (column.name == 'revision' && live != null) {
        final rows = await query(
          'SELECT count(*) FROM ${quoted(spec.name)} WHERE revision < 0',
        );
        negativeRevision[spec.name] = (rows.first.first as int?) ?? 0;
      }
      if (spec.name == Tables.projects &&
          column.name == 'triangulation_window_minutes' &&
          live != null) {
        final rows = await query(
          'SELECT count(*) FROM ${quoted(spec.name)} '
          'WHERE triangulation_window_minutes <= 0',
        );
        window = (rows.first.first as int?) ?? 0;
      }
    }
  }

  // One count over the shared tables, so "zero bad rows" and "zero rows"
  // cannot be read as the same answer.
  int? totalSharedRows;
  try {
    var total = 0;
    for (final spec in tableSpecs) {
      if (!liveTypes.keys.any((k) => k.startsWith('${spec.name}.'))) continue;
      final rows = await query('SELECT count(*) FROM ${quoted(spec.name)}');
      total += (rows.first.first as int?) ?? 0;
    }
    totalSharedRows = total;
  } on Object {
    totalSharedRows = null;
  }

  return NumericPopulationReport(
    deployment: deployment,
    clusterIdentifier: clusterIdentifier,
    totalSharedRows: totalSharedRows,
    columns: findings,
    negativeRevisionRows: negativeRevision,
    nonPositiveWindowRows: window,
  );
}

/// The printed answer.
///
/// **The interpretation is printed with the number, not left for afterwards**
/// — task 11.158's own instruction, and the reason is that a measurement whose
/// meaning is agreed after the fact is a number somebody argues about.
String describeNumericPopulation(NumericPopulationReport report) {
  final out = StringBuffer()
    ..writeln('TriTrack — rows the numeric rule would newly refuse '
        '(task 11.158)')
    ..writeln('Deployment: ${report.deployment}')
    ..writeln('Database cluster id: '
        '${report.clusterIdentifier ?? 'not available from this Postgres'}')
    ..writeln('Rows in the shared tables: '
        '${report.totalSharedRows ?? 'could not be counted'}')
    ..writeln('Columns examined: ${report.columns.length}')
    ..writeln();
  if (report.totalSharedRows == 0) {
    out
      ..writeln('   NOTE: this database holds no rows at all. Everything '
          'below is zero because')
      ..writeln('   there is nothing here, which is a different fact from '
          'nothing being wrong.')
      ..writeln('   Check the cluster id above against the server you meant '
          'to measure.')
      ..writeln();
  }

  final unanswered = report.unanswered.toList();
  final drifted =
      report.columns.where((c) => c.liveType != null && !c.typeForbidsIt);

  out
    ..writeln('1. A numeric column holding something that is not a number')
    ..writeln('   Rows found: ${report.scannedTotal}');
  if (drifted.isEmpty) {
    out.writeln('   Every numeric column in this database is a numeric '
        'Postgres type, so');
    out.writeln('   a value like "north" could never have been stored here. '
        'The zero above');
    out.writeln('   is what the column types make impossible, not what a '
        'scan happened');
    out.writeln('   to miss.');
  } else {
    for (final c in drifted) {
      final n = c.nonNumericRows;
      out.writeln('   ${c.table}.${c.column} is ${c.liveType} and holds '
          '${n ?? 'an unknown number of'} such row${n == 1 ? '' : 's'}');
    }
  }
  out.writeln();

  out
    ..writeln('2. Rows below the two floors task 11.158 added')
    ..writeln('   revision below zero: '
        '${report.negativeRevisionRows.values.fold(0, (a, b) => a + b)}')
    ..writeln('   triangulation window of zero or less: '
        '${report.nonPositiveWindowRows ?? 'not checked'}');
  for (final entry in report.negativeRevisionRows.entries) {
    if (entry.value > 0) {
      out.writeln('   ${entry.key}: ${entry.value}');
    }
  }
  out.writeln();

  if (unanswered.isNotEmpty) {
    out
      ..writeln('COULD NOT CHECK — ${unanswered.length} column(s) are not in '
          'this database:')
      ..writeln('   ${unanswered.map((c) => '${c.table}.${c.column}').join(', ')}')
      ..writeln('   No rows were read for these. That is not the same as '
          'zero rows found.')
      ..writeln();
  }

  final total = report.scannedTotal + report.floorTotal;
  out
    ..writeln('WHAT THIS NUMBER MEANS — decided before it was measured')
    ..writeln('   Total rows the new rule would newly refuse: $total')
    ..writeln()
    ..writeln('   0        Ship the refusal. Nothing on this server is '
        'affected, and every')
    ..writeln('            month it waits the population grows and the '
        'migration gets harder.')
    ..writeln('   1 to ~20 Ship the refusal, and correct the named rows by '
        'hand first —')
    ..writeln('            they are listed above by table.')
    ..writeln('   many     Stop and ask. A repair pass has to ship before '
        'the refusal does,')
    ..writeln('            or those rows are stranded on the devices holding '
        'them.')
    ..writeln()
    ..writeln('LIMIT — this reads the server, which is everything every '
        'device has')
    ..writeln('   successfully pushed. It cannot read a phone. A row still '
        'waiting on a')
    ..writeln('   device is not counted here and would meet the new rule on '
        'its next push.');
  return out.toString();
}

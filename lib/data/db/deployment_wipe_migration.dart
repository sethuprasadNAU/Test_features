import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'schema.dart';

/// Schema v17 (task 11.243): runs [schemaV17Statements] and **says what it
/// deleted**.
///
/// The statements are the migration; this wrapper exists because this one
/// destroys data on purpose (design §9) and **a destructive step that does
/// not announce itself is the defect this project has been chasing all week
/// in a new costume.** A migration that empties nine tables and prints
/// nothing is indistinguishable from one that emptied none — and here the two
/// are as far apart as a result can be.
///
/// So it counts every row it is about to delete, per table, and prints the
/// numbers. Like schema v14's and v16's censuses, a fresh create prints
/// nothing: there is nothing to delete and a census of zeroes is noise.
abstract final class DeploymentWipeMigration {
  // ignore: avoid_print
  static void _print(String line) => print(line);

  /// Applies schema v17. Called from the migration list; not for direct use.
  static Future<void> apply(
    DatabaseExecutor db,
    int fromVersion, {
    void Function(String line) log = _print,
  }) async {
    final report = await wipe(db);
    if (fromVersion > 0) {
      for (final line in report.report()) {
        log(line);
      }
    }
  }

  /// Runs the v17 statements and returns the census. Public and separately
  /// callable, the way `TagScopeMigration.fork` and
  /// `IndividualBackfillMigration.backfill` are: **a number a migration
  /// reports only into a log is a number no test can assert.**
  static Future<DeploymentWipeReport> wipe(DatabaseExecutor db) async {
    final deleted = <String, int>{};
    for (final table in [
      ...deploymentWipeTables,
      Tables.individuals,
      Tables.tags,
      kTagLibraryTable,
    ]) {
      deleted[table] = await _count(db, table);
    }
    final batch = db.batch();
    for (final statement in schemaV17Statements()) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
    return DeploymentWipeReport(
      deleted: deleted,
      // Read back rather than assumed. A statement list that quietly failed
      // to empty something would otherwise be reported as a clean wipe, which
      // is the same shape as an instrument that cannot fail.
      remaining: {
        for (final table in deleted.keys) table: await _count(db, table),
      },
    );
  }

  static Future<int> _count(DatabaseExecutor db, String table) async =>
      (await db.rawQuery('SELECT COUNT(*) AS c FROM $table')).first['c'] as int;
}

/// What the v17 wipe deleted, as numbers a test can assert and a log can
/// carry.
class DeploymentWipeReport {
  const DeploymentWipeReport({required this.deleted, required this.remaining});

  /// Rows present in each table **before** the wipe, tombstones included.
  final Map<String, int> deleted;

  /// Rows present afterwards — every one of them zero, or the wipe is wrong.
  final Map<String, int> remaining;

  /// Total rows destroyed.
  int get total => deleted.values.fold(0, (a, b) => a + b);

  /// Tables that still hold rows. Empty, or the migration did not do what it
  /// says.
  List<String> get notEmptied => [
    for (final entry in remaining.entries)
      if (entry.value > 0) entry.key,
  ];

  /// The lines the migration prints, in order. **The last line is the
  /// finding**, and the finding here is a number of destroyed rows and the
  /// instruction that goes with it.
  List<String> report() => [
    'schema v17: tags are equipment now and the tag/animal link is a dated '
        'Deployments row. THIS MIGRATION DELETES DATA ON PURPOSE '
        '(ANIMALS_AND_DEPLOYMENTS_DESIGN.md §9).',
    for (final entry in deleted.entries)
      if (entry.value > 0) '  deleted ${entry.value} row(s) from ${entry.key}',
    if (notEmptied.isEmpty)
      'schema v17: $total row(s) deleted; your projects, team and sign-in are '
          'untouched. Re-enter your collars and animals.'
    else
      'schema v17: $total row(s) deleted — MISMATCH: '
          '${notEmptied.join(', ')} still hold rows and should be empty',
  ];
}

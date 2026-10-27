import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'schema.dart';

/// Schema v16 (task 11.240): runs [schemaV16Statements] and prints what it
/// moved.
///
/// The statements are the migration; this wrapper exists for the reason
/// schema v14 and v15 are run-bodied rather than statement lists — a
/// migration that creates one row per existing tag and prints nothing is
/// indistinguishable from one that created none, and that is this project's
/// founding defect met in the worst possible place. So it counts before and
/// after, and the count is the finding.
///
/// **What it does not decide.** Which tags are one animal. One individual
/// per tag, no name-matching anywhere — see `schemaV16Statements`.
abstract final class IndividualBackfillMigration {
  // ignore: avoid_print
  static void _print(String line) => print(line);

  /// Applies schema v16. Called from the migration list; not for direct use.
  ///
  /// [log] follows `TagScopeMigration.apply`'s reasoning: `print` by default
  /// so the census is visible in a device log, in CI, and to a `Zone` a test
  /// installs. A fresh create (`fromVersion == 0`) prints nothing — there is
  /// nothing to backfill and a census of zeroes is noise; an upgrade always
  /// prints, including one that finds no tags, because "nothing to do" is a
  /// result and an absent line is not.
  static Future<void> apply(
    DatabaseExecutor db,
    int fromVersion, {
    void Function(String line) log = _print,
  }) async {
    final report = await backfill(db);
    if (fromVersion > 0) {
      for (final line in report.report()) {
        log(line);
      }
    }
  }

  /// Runs the v16 statements and returns the census. Public and separately
  /// callable, the way `TagScopeMigration.fork` is: a number a migration
  /// reports only into a log is a number no test can assert.
  static Future<IndividualBackfillReport> backfill(DatabaseExecutor db) async {
    final tagsBefore = await _count(db, Tables.tags);
    final batch = db.batch();
    for (final statement in schemaV16Statements()) {
      batch.execute(statement);
    }
    await batch.commit(noResult: true);
    final individuals = await _count(db, Tables.individuals);
    final linked = (await db.rawQuery(
      'SELECT COUNT(*) AS c FROM ${Tables.tags} t '
      'JOIN ${Tables.individuals} i '
      'ON i.individual_id = t.individual_id AND i.project_id = t.project_id',
    )).first['c'] as int;
    return IndividualBackfillReport(
      tags: tagsBefore,
      individuals: individuals,
      linkedTags: linked,
    );
  }

  static Future<int> _count(DatabaseExecutor db, String table) async =>
      (await db.rawQuery('SELECT COUNT(*) AS c FROM $table')).first['c']
          as int;
}

/// What the v16 backfill did, as numbers a test can assert and a log can
/// carry.
class IndividualBackfillReport {
  const IndividualBackfillReport({
    required this.tags,
    required this.individuals,
    required this.linkedTags,
  });

  /// Tag rows found before the migration ran, tombstones included.
  final int tags;

  /// Individuals rows after — one per tag, or the migration is wrong.
  final int individuals;

  /// Tags whose `individual_id` resolves to a row in their own project after
  /// the rebuild — every one of them, or the migration is wrong.
  final int linkedTags;

  /// The lines the migration prints, in order. The last line is the finding.
  List<String> report() => [
    'schema v16: $tags tag row(s) found; $individuals individual(s) created, '
        'one per tag, none merged by name; $linkedTags tag(s) now name their '
        'animal'
        '${individuals == tags && linkedTags == tags ? '' : ' — MISMATCH: '
            'every tag should have produced exactly one individual and '
            'now name it'}',
  ];
}

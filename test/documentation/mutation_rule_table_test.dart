import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.17: the "Authorization rules (repository layer)" table in
/// `TriTrack_Technical_Context.md` is prose that restates `tableMutationRules`
/// (`packages/tritrack_sync/lib/src/mutation_rules.dart`) for a human reader.
/// Task 11.7 added `Observation_Exclusions` to the code and never to the
/// table, and nothing failed — the code has [assertEveryTableHasAMutationRule]
/// as a backstop against a forgotten table, and the document had no
/// equivalent. This test reads the document's own Markdown at run time and
/// fails if it names a rule the enum doesn't have, or lists a different set
/// of tables under a rule than the code does. Deleting either half — a row
/// from the document, or an entry from `tableMutationRules` — turns one of
/// these two tests red.
const _docPath = 'CLAUDE_DOCS/TriTrack_Technical_Context.md';

const _tableHeader = '| Rule | Governing column | Tables | Meaning |';

/// Parses the Markdown table into rule name -> the set of table names listed
/// under it, straight from the document's text — never hand-copied, so it
/// cannot itself go stale the way the prose did.
Map<String, Set<String>> _parseRuleTable(List<String> docLines) {
  final headerIndex = docLines.indexWhere((l) => l.trim() == _tableHeader);
  if (headerIndex == -1) {
    fail(
      'Could not find the rule table header ("$_tableHeader") in '
      '$_docPath. Either the table was removed, or its wording changed — '
      'update this test to match the new heading.',
    );
  }
  final result = <String, Set<String>>{};
  // headerIndex + 1 is the "| --- | --- | --- | --- |" separator row.
  for (var i = headerIndex + 2; i < docLines.length; i++) {
    final line = docLines[i];
    if (!line.trimLeft().startsWith('|')) break;
    final cells = line.split('|').map((c) => c.trim()).toList();
    final ruleName = cells[1].replaceAll('`', '').trim();
    final tables = cells[3].split(',').map((t) => t.trim()).toSet();
    result[ruleName] = tables;
  }
  return result;
}

void main() {
  final docLines = File(_docPath).readAsLinesSync();
  final docTable = _parseRuleTable(docLines);

  test('the document names exactly the rules MutationRule declares', () {
    expect(
      docTable.keys.toSet(),
      MutationRule.values.map((r) => r.name).toSet(),
      reason:
          'A MutationRule was added, removed, or renamed in mutation_rules.dart '
          'without updating the "Authorization rules" table in $_docPath.',
    );
  });

  test('the document\'s table lists match tableMutationRules exactly', () {
    final codeTable = <String, Set<String>>{};
    tableMutationRules.forEach((table, rule) {
      codeTable.putIfAbsent(rule.name, () => {}).add(table);
    });
    expect(
      docTable,
      codeTable,
      reason:
          '$_docPath\'s rule table has drifted from tableMutationRules in '
          'mutation_rules.dart — a table was added, moved to a different '
          'rule, or removed on one side but not the other. Update the '
          'document\'s table (or the code) so they agree.',
    );
  });
}

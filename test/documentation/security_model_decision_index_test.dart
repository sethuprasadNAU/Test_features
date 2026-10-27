/// Task 11.179 — **the security model's decision index lists the decisions.**
///
/// `TriTrack_Security_Model.md` ends in an *Appendix — decision index*: one row
/// per decision, naming the section, the tasks that implemented it, the gate
/// that reviewed it, and a verdict. It is the closest thing this project has to
/// a contents page for its security decisions, which is exactly why a reader
/// treats absence from it as absence.
///
/// **Does the index have a code-side truth? No — and saying so is half of what
/// this file is for.** Nothing under `lib/` or `server/` can be read to check a
/// single cell. "Implemented by" names task numbers; "Gate" names a gate
/// letter; the verdict column is argument. No enumeration of the code produces
/// any of them, and a check that pretended otherwise would be measuring
/// something it had invented.
///
/// **What it does have is a document-side truth, and that is where the one
/// measured defect lived.** Every row's `§` is a heading of the same document,
/// and every top-level decision in section 4 ought to have a row. Task 11.159
/// found four that did not — §4.26, §4.27, §4.28 and §4.29 — and wrote a
/// paragraph into the appendix saying so, ending *"nothing derives this table
/// from the sections above it, so nothing will notice the next one."* That
/// sentence is correct and it is prose, and `CLAUDE.md`'s standing rule is that
/// a reopen condition which can be expressed as a check must be. This is the
/// check; task 11.179 added the four missing rows so it could pass.
///
/// ## The two directions, and why both are needed
///
/// - **A decision with no row** is the measured defect: the section exists, the
///   index does not mention it, and a reader scanning the index concludes there
///   is no such decision.
/// - **A row naming no section** is the citation defect one document over: the
///   pointer survives the thing it points at. It has not happened here yet,
///   which is the cheapest possible moment to make it impossible.
///
/// ## What this deliberately does not check
///
/// **The verdict column, which is where the judgement actually lives.** A row
/// can name the right section and say something two gate rounds out of date;
/// §4.6's row said exactly that until task 11.150 re-derived it. Only a person
/// re-reading catches that, and this file must not be mistaken for having
/// caught it — a document with a checker teaches its reader that it is checked,
/// so the appendix now states in its own body which column is derived and which
/// four are not.
///
/// **Sub-sections are not required to have rows.** §4.4.1 through §4.4.4 refine
/// §4.4 rather than deciding separately, and requiring a row each would turn a
/// contents page into a duplicate of the document. A sub-section *may* have a
/// row — §4.9.2 and §4.15.1 do, because both supersede rather than refine — and
/// then it is checked like any other row.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _modelPath = 'CLAUDE_DOCS/TriTrack_Security_Model.md';
const String _appendixHeading = '## Appendix — decision index';

/// `### 4.7 Audit logging…` — a top-level decision. `#### 4.4.1 …` and
/// `### 4.9.1 …` are refinements and are matched by [_anySectionHeading].
final RegExp _topLevelDecision = RegExp(r'^#{2,4} (4\.\d+) ');
final RegExp _anySectionHeading = RegExp(r'^#{2,4} (4(?:\.\d+)+) ');

/// A row of the appendix table: `| 4.7 | Audit logging… | 10.14 | C | … |`.
final RegExp _indexRow = RegExp(r'^\| (4(?:\.\d+)+) \|');

void main() {
  late List<String> lines;
  late Set<String> topLevelDecisions;
  late Set<String> everySection;
  late Map<String, int> indexRows;

  setUpAll(() {
    final file = File(_modelPath);
    expect(
      file.existsSync(),
      isTrue,
      reason:
          '$_modelPath is missing. It is the authority for security decisions '
          'in Phase 10 and Phase 11; nothing below means anything without it.',
    );
    lines = file.readAsLinesSync();

    topLevelDecisions = {};
    everySection = {};
    for (final line in lines) {
      final top = _topLevelDecision.firstMatch(line);
      if (top != null) topLevelDecisions.add(top.group(1)!);
      final any = _anySectionHeading.firstMatch(line);
      if (any != null) everySection.add(any.group(1)!);
    }

    final start = lines.indexWhere((l) => l.trim() == _appendixHeading);
    if (start < 0) {
      fail(
        'Could not find "$_appendixHeading" in $_modelPath. That appendix is '
        'the index this file checks; if it was renamed, rename it here too '
        'rather than leaving a test that reads nothing and passes.',
      );
    }
    indexRows = {};
    for (var i = start + 1; i < lines.length; i++) {
      if (lines[i].startsWith('## ')) break;
      final match = _indexRow.firstMatch(lines[i]);
      if (match != null) indexRows[match.group(1)!] = i + 1;
    }
  });

  group('the security model\'s decision index (task 11.179)', () {
    // Both checks below are satisfied by reading nothing, so the read asserts
    // itself first — and it asserts what it found rather than that it found
    // something.
    test('the appendix and the section headings were both read', () {
      expect(
        topLevelDecisions.length,
        greaterThan(25),
        reason:
            'Only ${topLevelDecisions.length} top-level section 4 decisions '
            'were found in $_modelPath. There were 30 on 2026-09-06 and this '
            'document only grows. A count this low means the heading pattern '
            'stopped matching, and then "every decision has a row" is a claim '
            'about almost nothing.',
      );
      expect(
        indexRows.length,
        greaterThan(25),
        reason:
            'Only ${indexRows.length} rows were read out of the decision '
            'index. There were 32 on 2026-09-06. A table this short means the '
            'row pattern stopped matching, and every decision would then look '
            'unlisted.',
      );
      // ignore: avoid_print
      print(
        '${topLevelDecisions.length} top-level decisions, '
        '${everySection.length} section 4 headings in all, '
        '${indexRows.length} index rows',
      );
    });

    test('every top-level decision has a row in the index', () {
      final missing = (topLevelDecisions.difference(indexRows.keys.toSet()))
          .toList()
        ..sort();
      expect(
        missing,
        isEmpty,
        reason:
            'These section 4 decisions have no row in "$_appendixHeading": '
            '${missing.map((n) => '§$n').join(', ')}.\n'
            'The index is the closest thing this document has to a contents '
            'page, so a reader scanning it concludes the decision does not '
            'exist. Add a row naming the section, the tasks that implemented '
            'it and whether a gate has reviewed it — and if no gate has, say '
            'that in the verdict cell rather than leaving it blank.\n'
            'Task 11.159 found four of these and recorded it as a paragraph; '
            'this test exists because a paragraph waits to be remembered.',
      );
    });

    test('every row of the index names a section that exists', () {
      final dangling = <String>[];
      for (final entry in indexRows.entries) {
        if (everySection.contains(entry.key)) continue;
        dangling.add('  line ${entry.value}: §${entry.key}');
      }
      expect(
        dangling,
        isEmpty,
        reason:
            'These rows of "$_appendixHeading" name a section this document '
            'does not have:\n${dangling.join('\n')}\n'
            'Either the section was renumbered — repoint the row — or the '
            'decision was withdrawn, in which case say so in the row rather '
            'than deleting it: the index is also the record of what was once '
            'decided.',
      );
    });
  });
}

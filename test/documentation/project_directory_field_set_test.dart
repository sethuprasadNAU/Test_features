import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Task 11.64, finding P-1: `GET /projects/mine` returns a row whose fields
/// nothing described. It was attacked as a *route* at four gates — a stranger
/// cannot reach it, a revoked session cannot, a removed member no longer sees
/// the project — and never as a **read**, so "does it leak?" had no statement
/// to falsify. Security Model §4.28 is that statement, and this test is what
/// stops the statement and the code drifting apart.
///
/// It reads §4.28's own Markdown tables at run time and compares each to the
/// wire shape the server actually emits — [ProjectSummary.toJson] for
/// `GET /projects/mine`, and since task 11.292 [DeletedProjectSummary.toJson]
/// for `GET /projects/deleted/mine`, whose table is §4.28.1's. **Both
/// directions fail:** adding a field to a model without amending the section,
/// and amending the section without changing the model. The first is the one
/// that matters, because a field added to a response nobody documented is
/// exactly how a disclosure gets made by nobody in particular.
///
/// **Two tables, so each is tied to its route.** A table is read only if the
/// paragraph above its header names the route it describes, so
/// the two cannot be swapped — or a third added under the wrong heading —
/// without this going red. A derivation that matched tables to models by
/// position alone would pass with the tables exchanged.
///
/// The live half of this check is in
/// `server/test/integration/member_authorization_test.dart` (five keys on a
/// real `/projects/mine` response) and
/// `server/test/integration/deleted_project_directory_test.dart` (four keys on
/// a real `/projects/deleted/mine` response). This one runs in plain
/// `flutter test` and needs no Docker, so the rule is measured on every run
/// rather than only when somebody brings a stack up.
const _docPath = 'CLAUDE_DOCS/TriTrack_Security_Model.md';

const _sectionHeading =
    '### 4.28 What a row of `GET /projects/mine` may carry';

/// Where §4.28 ends: the next `###` heading. Its `####` subsections are part
/// of it, which is where the second route's table lives.
const _nextSectionPrefix = '### 4.29';

const _tableHeader = '| Field | What it is | Why the caller may have it |';

/// One field table of §4.28, with the route the text above it names.
class _FieldTable {
  const _FieldTable({required this.route, required this.fields, required this.line});

  final String route;
  final Set<String> fields;
  final int line;
}

/// Every field table in §4.28 (subsections included), in document order,
/// straight from the document's text — never hand-copied here, so this test
/// cannot itself go stale the way the prose it guards did.
List<_FieldTable> _documentedTables(List<String> docLines) {
  final sectionIndex = docLines.indexWhere(
    (l) => l.trim().startsWith(_sectionHeading),
  );
  if (sectionIndex == -1) {
    fail(
      'Could not find "$_sectionHeading" in $_docPath. Either §4.28 was '
      'removed — in which case the field set of GET /projects/mine is once '
      'again undocumented, and finding P-1 is reopened — or its heading '
      'changed, in which case update this test to match.',
    );
  }
  var end = docLines.indexWhere(
    (l) => l.trim().startsWith(_nextSectionPrefix),
    sectionIndex,
  );
  if (end == -1) end = docLines.length;

  final tables = <_FieldTable>[];
  final routePattern = RegExp(r'`(GET /projects/[a-z/]+)`');
  for (var i = sectionIndex; i < end; i++) {
    if (docLines[i].trim() != _tableHeader) continue;
    // The paragraph above the header — the contiguous non-blank lines
    // nearest it — must name the route.
    var above = i - 1;
    while (above > sectionIndex && docLines[above].trim().isEmpty) {
      above--;
    }
    var first = above;
    while (first - 1 > sectionIndex && docLines[first - 1].trim().isNotEmpty) {
      first--;
    }
    final paragraph = docLines.sublist(first, above + 1).join(' ');
    final route = routePattern.firstMatch(paragraph)?.group(1);
    if (route == null) {
      fail(
        'The field table at $_docPath line ${i + 1} is not introduced by a '
        'paragraph naming its route (expected a `GET /projects/...` in '
        'backticks on lines ${first + 1}-${above + 1}). Without that, this '
        'test cannot tell which model the table describes, and a table '
        'matched by position alone would pass with two tables swapped.',
      );
    }
    final fields = <String>{};
    // i + 1 is the "| --- | --- | --- |" separator row.
    for (var j = i + 2; j < end; j++) {
      final line = docLines[j];
      if (!line.trimLeft().startsWith('|')) break;
      final cells = line.split('|').map((c) => c.trim()).toList();
      fields.add(cells[1].replaceAll('`', '').replaceAll('**', '').trim());
    }
    tables.add(_FieldTable(route: route, fields: fields, line: i + 1));
  }
  return tables;
}

void main() {
  final docLines = File(_docPath).readAsLinesSync();
  final tables = _documentedTables(docLines);
  final byRoute = {for (final t in tables) t.route: t};

  test('§4.28 holds exactly one field table per directory route', () {
    expect(
      tables,
      isNotEmpty,
      reason:
          'Parsed no field tables out of §4.28. A derivation that silently '
          'returns nothing reports full agreement with any model at all — '
          'fix this parser rather than letting an empty set pass.',
    );
    expect(
      tables.map((t) => t.route).toList(),
      ['GET /projects/mine', 'GET /projects/deleted/mine'],
      reason:
          'Expected §4.28 to carry one table for GET /projects/mine and one '
          '(§4.28.1) for GET /projects/deleted/mine, in that order. Found: '
          '${tables.map((t) => '${t.route} (line ${t.line})').join(', ')}. '
          'A third directory route needs its own table, its own model, and a '
          'line in this test.',
    );
    for (final table in tables) {
      expect(
        table.fields,
        isNotEmpty,
        reason: 'The table for ${table.route} (line ${table.line}) has no rows.',
      );
    }
  });

  test('§4.28 names exactly the fields a /projects/mine row carries', () {
    const summary = ProjectSummary(
      projectId: 'p',
      projectName: 'n',
      ownerUserId: 'o',
      role: 'owner',
    );
    expect(
      summary.toJson().keys.toSet(),
      byRoute['GET /projects/mine']?.fields,
      reason:
          'The wire shape of GET /projects/mine has drifted from Security '
          'Model §4.28. If a field was added, §4.28 is the place the decision '
          'to disclose it gets made and written down — see its rule on what '
          'may never appear here. If a field was removed, amend §4.28 too, so '
          'the document keeps describing the response that exists.',
    );
  });

  test(
    '§4.28.1 names exactly the fields a /projects/deleted/mine row carries',
    () {
      const summary = DeletedProjectSummary(
        projectId: 'p',
        projectName: 'n',
        deletedAt: null,
      );
      expect(
        summary.toJson().keys.toSet(),
        byRoute['GET /projects/deleted/mine']?.fields,
        reason:
            'The wire shape of GET /projects/deleted/mine has drifted from '
            'Security Model §4.28.1. A field added to this route is a '
            'disclosure decision, and that subsection names two fields that '
            'may never appear here (owner_user_id, role) as well as the list '
            '§4.28 already forbids. Amend the subsection first.',
      );
    },
  );
}

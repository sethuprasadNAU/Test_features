/// **Task 11.84 item 2: §4.2 of the permissions matrix, derived rather than
/// edited.**
///
/// Task 11.81 changed six membership operations and rewrote rows M2–M5 by hand,
/// then added a row by hand. That stopped `PERMISSIONS_MATRIX.md` being false on
/// the day it was written, which is not the same thing as it staying true — and
/// this project's oldest rule is that **a hand-maintained list is already
/// wrong.** Tasks 11.23 and 11.25 established the answer: enumerate the code and
/// diff it against the document, in both directions, as a committed check rather
/// than as a procedure somebody remembers to re-run.
///
/// Task 11.25 derived the matrix's *structural* claims — every synced table has
/// a mutation rule, every table's audit column names the caller. It deliberately
/// did not touch §4's named operations, and said so. This closes the membership
/// half of that gap: **the routes are enumerated from the server's source, and
/// the document must account for every one of them.**
///
/// ## What is derived, and from where
///
/// 1. **The route inventory.** Every `router.<method>('<path>', …)` declared in
///    `project_routes.dart`, plus the session routes in `auth_routes.dart` —
///    the ones §4.2's last row is about. Nothing here is a hand-kept list of
///    routes; adding a route to either file adds it here.
/// 2. **Whether each route is owner-gated**, read off the presence of a
///    `_requireOwner(` call inside that route's handler body.
/// 3. **The document's rows**, parsed out of §4.2's Markdown table at run time.
///
/// ## What is checked
///
/// - Row identifiers are unique and ascend. Both halves caught a real defect
///   when this test was first written: **two different rows were both numbered
///   M9**, and one of them sat between M5 and M6.
/// - Every route in the inventory is named, verbatim and with its method, in
///   exactly one row's Source cell. This is the direction that catches a route
///   the document has never heard of.
/// - Every route-shaped string in §4.2 names a route the server actually
///   declares. This is the direction that catches a row describing something
///   that was deleted — the class task 11.84 item 1 had to clean up by hand.
/// - **An owner-gated route's row must read `no` for stranger, viewer and
///   contributor, and `yes` for owner.** This is the one verdict in the grid
///   that can be read off the code rather than argued, and it is the verdict a
///   hand-written row is most likely to get wrong.
///
/// ## What is *not* derived, said plainly
///
/// The Screen/Device columns, the Unknown column, and every Notes cell are
/// prose. No test reads them. A row can still be wrong about what a screen
/// does; this closes the part that has a machine-checkable answer, and leaves
/// the rest visibly not closed rather than implying it is.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

const _docPath = 'CLAUDE_DOCS/PERMISSIONS_MATRIX.md';
const _projectRoutesPath = 'server/lib/src/projects/project_routes.dart';
const _authRoutesPath = 'server/lib/src/auth/auth_routes.dart';

/// The section this test governs, and the one after it, so the parser knows
/// where to stop rather than running into the next table.
const _sectionHeading = '### 4.2 People and roles';
const _nextSectionPrefix = '### 4.3';

/// Session routes are the only ones outside `project_routes.dart` that §4.2
/// covers — its last row is "see the devices you are signed in on". Sign-in,
/// magic links and sign-out are authentication, not membership, and live in
/// their own part of the security model.
const _sessionRoutePrefix = '/auth/sessions';

/// A route as the server declares it.
class _Route {
  const _Route({
    required this.method,
    required this.path,
    required this.ownerGated,
    required this.file,
    required this.line,
  });

  final String method;
  final String path;
  final bool ownerGated;
  final String file;
  final int line;

  /// The exact text a Source cell must contain. Deliberately the code's own
  /// path, placeholders included — a document that writes `<id>` where the code
  /// writes `<projectId>` is one rename away from being unfindable, and a
  /// citation nobody can follow is the thing this whole file is about.
  String get citation => '$method $path';

  @override
  String toString() => '$citation ($file:$line)';
}

final _routeDeclaration = RegExp(
  r"""router\.(get|post|put|delete)\(\s*'([^']+)'""",
);

/// Reads every route out of a Dart source file, deciding owner-gating by
/// looking at the text between one declaration and the next.
List<_Route> _routesIn(String path, {bool Function(String)? keep}) {
  final source = File(path);
  if (!source.existsSync()) {
    fail(
      '$path does not exist. If the server was reorganised, update the paths '
      'at the top of this test — do not delete the check.',
    );
  }
  final text = source.readAsStringSync();
  final matches = _routeDeclaration.allMatches(text).toList();
  if (matches.isEmpty) {
    fail(
      'Found no `router.<method>(...)` declarations in $path. Either the file '
      'no longer mounts routes, or the way routes are declared changed and '
      'this test can no longer see them — which would make it pass by finding '
      'nothing, so it fails instead.',
    );
  }
  final routes = <_Route>[];
  for (var i = 0; i < matches.length; i++) {
    final match = matches[i];
    final routePath = match.group(2)!;
    if (keep != null && !keep(routePath)) continue;
    final end = i + 1 < matches.length ? matches[i + 1].start : text.length;
    var body = text.substring(match.end, end);
    // **Stop at the end of the enclosing function.** Route handlers are
    // indented; the file's top-level declarations are not. Without this the
    // *last* route in a file swallows everything after it — which is how this
    // check first reported that a stranger's "ask to join" route was
    // owner-gated, having found the body of `_requireOwner` itself. The
    // derivation disagreeing with an obviously-correct row is what surfaced
    // the defect in the reader; a narrower corpus would have hidden it.
    final functionEnd = body.indexOf('\n}\n');
    if (functionEnd != -1) body = body.substring(0, functionEnd);
    routes.add(
      _Route(
        method: match.group(1)!.toUpperCase(),
        path: routePath,
        ownerGated: body.contains('_requireOwner('),
        file: path,
        line: '\n'.allMatches(text.substring(0, match.start)).length + 1,
      ),
    );
  }
  return routes;
}

/// One parsed row of §4.2's grid.
class _MatrixRow {
  const _MatrixRow({
    required this.id,
    required this.operation,
    required this.stranger,
    required this.viewer,
    required this.contributor,
    required this.owner,
    required this.source,
    required this.line,
  });

  final String id;
  final String operation;
  final String stranger;
  final String viewer;
  final String contributor;
  final String owner;
  final String source;
  final int line;

  /// The document writes verdicts with emphasis and parentheticals —
  /// `**yes, their own row**`, `no ("already a member")`. The first word is the
  /// verdict; the rest is why.
  static String _verdict(String cell) {
    final bare = cell.replaceAll('*', '').trim().toLowerCase();
    final match = RegExp(r'^(yes|no|own|new|n/a|\?)').firstMatch(bare);
    return match?.group(1) ?? bare;
  }

  String get strangerVerdict => _verdict(stranger);
  String get viewerVerdict => _verdict(viewer);
  String get contributorVerdict => _verdict(contributor);
  String get ownerVerdict => _verdict(owner);
}

List<_MatrixRow> _parseSection42(List<String> docLines) {
  final start = docLines.indexWhere((l) => l.trim() == _sectionHeading);
  if (start == -1) {
    fail(
      'Could not find "$_sectionHeading" in $_docPath. Either the section was '
      'renamed or renumbered — update this test to match — or it was removed, '
      'which is a much larger question than a test failure.',
    );
  }
  final rows = <_MatrixRow>[];
  for (var i = start + 1; i < docLines.length; i++) {
    final line = docLines[i];
    if (line.trim().startsWith(_nextSectionPrefix)) break;
    if (!line.trimLeft().startsWith('|')) continue;
    final cells = line.split('|').map((c) => c.trim()).toList();
    // A pipe-delimited row yields a leading and trailing empty cell.
    if (cells.length < 13) continue;
    final id = cells[1].replaceAll('*', '').trim();
    if (!RegExp(r'^M\d+$').hasMatch(id)) continue; // header and separator rows
    rows.add(
      _MatrixRow(
        id: id,
        operation: cells[2],
        stranger: cells[3],
        viewer: cells[4],
        contributor: cells[5],
        owner: cells[6],
        source: cells[11],
        line: i + 1,
      ),
    );
  }
  if (rows.isEmpty) {
    fail(
      'Parsed no `M`-numbered rows out of $_sectionHeading in $_docPath. The '
      'table\'s shape changed and this test can no longer read it — which '
      'would otherwise make every check below pass vacuously.',
    );
  }
  return rows;
}

/// Any `METHOD /path` the document cites, so the reverse direction can ask
/// whether the server declares it.
final _citationPattern = RegExp(
  r'\b(GET|POST|PUT|DELETE) (/[A-Za-z0-9/<>_\-]+)',
);

void main() {
  final docLines = File(_docPath).readAsLinesSync();
  final rows = _parseSection42(docLines);

  final inventory = [
    ..._routesIn(_projectRoutesPath),
    ..._routesIn(
      _authRoutesPath,
      keep: (path) => path.startsWith(_sessionRoutePrefix),
    ),
  ];

  group('§4.2 is derived from the server\'s routes', () {
    test('row identifiers are unique', () {
      final seen = <String, int>{};
      final duplicates = <String>[];
      for (final row in rows) {
        final first = seen[row.id];
        if (first != null) {
          duplicates.add(
            '${row.id} is used at line $first ("${rows.firstWhere((r) => r.line == first).operation}") '
            'and again at line ${row.line} ("${row.operation}")',
          );
        } else {
          seen[row.id] = row.line;
        }
      }
      expect(
        duplicates,
        isEmpty,
        reason:
            'Two rows of §4.2 share an identifier, so a citation of that '
            'identifier elsewhere points at two different operations:\n'
            '${duplicates.map((d) => '  - $d').join('\n')}',
      );
    });

    test('row identifiers ascend', () {
      final numbers = rows
          .map((r) => int.parse(r.id.substring(1)))
          .toList(growable: false);
      final sorted = [...numbers]..sort();
      expect(
        numbers,
        sorted,
        reason:
            'The rows of §4.2 are out of order '
            '(${rows.map((r) => r.id).join(', ')}). A reader looking up a row '
            'by number scans for it in order, and a row filed out of sequence '
            'reads as absent.',
      );
    });

    test('every route the server declares is named in a row', () {
      final sourceText = rows.map((r) => r.source).join('\n');
      final missing = inventory
          .where((route) => !sourceText.contains(route.citation))
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'These routes exist on the server and no row of §4.2 cites them, '
            'so the document does not account for something a caller can '
            'reach:\n'
            '${missing.map((r) => '  - $r').join('\n')}\n\n'
            'Cite each one in the Source cell of the row it belongs to, '
            'written exactly as the code declares it — method, then path, '
            'placeholders included.',
      );
    });

    test('every route a row names is one the server declares', () {
      final declared = inventory.map((r) => r.citation).toSet();
      final unknown = <String>[];
      for (final row in rows) {
        for (final match in _citationPattern.allMatches(row.source)) {
          final citation = '${match.group(1)} ${match.group(2)}';
          if (!declared.contains(citation)) {
            unknown.add('${row.id} (line ${row.line}) cites $citation');
          }
        }
      }
      expect(
        unknown,
        isEmpty,
        reason:
            'These rows cite routes the server does not mount. Either the '
            'route was deleted and the row was not updated, or the citation '
            'does not match the code\'s own spelling of the path:\n'
            '${unknown.map((u) => '  - $u').join('\n')}\n\n'
            'Declared routes are:\n'
            '${(declared.toList()..sort()).map((d) => '  - $d').join('\n')}',
      );
    });

    test('an owner-gated route\'s row says owner-only', () {
      final disagreements = <String>[];
      for (final route in inventory.where((r) => r.ownerGated)) {
        final owning = rows.where((r) => r.source.contains(route.citation));
        for (final row in owning) {
          void check(String column, String verdict, String expected) {
            if (verdict != expected) {
              disagreements.add(
                '${row.id} (line ${row.line}) reads "$verdict" for $column, '
                'but ${route.citation} is gated by _requireOwner at '
                '${route.file}:${route.line}, so it must read "$expected"',
              );
            }
          }

          check('stranger', row.strangerVerdict, 'no');
          check('viewer', row.viewerVerdict, 'no');
          check('contributor', row.contributorVerdict, 'no');
          check('owner', row.ownerVerdict, 'yes');
        }
      }
      expect(
        disagreements,
        isEmpty,
        reason:
            'The document disagrees with the server about who may do these '
            'things. The server is right:\n'
            '${disagreements.map((d) => '  - $d').join('\n')}',
      );
    });
  });

  group('the derivation can fail', () {
    // Task 10.65's rule, and 11.45's: a check that cannot be shown failing is
    // not evidence. Each of these corrupts the input the way a real drift
    // would and requires the machinery to notice.

    test('a duplicated identifier is caught', () {
      final ids = ['M1', 'M2', 'M2', 'M3'];
      final seen = <String>{};
      final duplicates = ids.where((id) => !seen.add(id)).toList();
      expect(duplicates, ['M2']);
    });

    test('an out-of-order identifier is caught', () {
      final numbers = [1, 2, 5, 3];
      expect(numbers, isNot(orderedEquals([...numbers]..sort())));
    });

    test('the route reader finds owner-gating and its absence', () {
      // Read against the real file rather than a fixture: a parser proven on
      // invented text is proven against the wrong thing.
      final routes = _routesIn(_projectRoutesPath);
      expect(
        routes.where((r) => r.ownerGated),
        isNotEmpty,
        reason:
            'No route in $_projectRoutesPath was read as owner-gated. Either '
            'every owner check was removed — which is a security defect, not a '
            'test failure — or `_requireOwner` was renamed and this test now '
            'reports every route as open to anyone.',
      );
      expect(
        routes.where((r) => !r.ownerGated),
        isNotEmpty,
        reason:
            'Every route in $_projectRoutesPath was read as owner-gated, '
            'including the one a stranger uses to ask to join. The gating '
            'detector is matching something it should not.',
      );
    });

    test('a verdict cell is read down to its first word', () {
      expect(_MatrixRow._verdict('**yes, their own row**'), 'yes');
      expect(_MatrixRow._verdict('no ("already a member")'), 'no');
      expect(_MatrixRow._verdict('n/a — not a project operation'), 'n/a');
      expect(_MatrixRow._verdict('yes'), 'yes');
    });
  });

  // Task 11.123 registers its groups here rather than in a second file, so
  // that there is exactly one route enumerator in this repository and the
  // two documents cannot be checked against two different readings of the
  // server.
  mainTask11123();
  mainTask11302();
}

// ---------------------------------------------------------------------------
// Task 11.123 — the same enumerator, aimed at a second document, plus the
// provenance markers that say where the derivation stops.
//
// §4.2 above covers *membership*, so its inventory is deliberately narrow:
// `project_routes.dart` plus the session routes. §4.21.2 of the security model
// claims something wider — "a verdict per endpoint" — so its inventory is
// **every route the server declares, from every file under `server/lib/` that
// mounts one.** Same reader, same both-directions diff, different corpus.
//
// **Why a wider corpus is a different check and not the same one twice.** A
// route-shaped instrument aimed at §4.3–4.5 of the permissions matrix would
// find nothing to disagree with and pass forever: those are sync-path writes
// keyed on tables and columns, not on routes. That is the reason §4.3–4.5 are
// labelled hand-kept rather than given a check that cannot fail.

const _securityModelPath = 'CLAUDE_DOCS/TriTrack_Security_Model.md';
const _serverLibDir = 'server/lib';

const _isolationHeading =
    '#### 4.21.2 Cross-project isolation — a verdict per endpoint';
const _isolationNextPrefix = '#### 4.21.3';

const _provenanceHeading = '## Where the derivation stops';

/// Every `.dart` file under `server/lib` that declares at least one route.
///
/// **Not a hand-kept list of files**, which is the whole point: adding
/// `server/lib/src/reports/report_routes.dart` tomorrow puts its routes in
/// this inventory without anybody editing this test, and therefore requires a
/// row in §4.21.2.
List<File> _serverSourceFiles() {
  final dir = Directory(_serverLibDir);
  if (!dir.existsSync()) {
    fail(
      '$_serverLibDir does not exist. If the server moved, update the path — '
      'do not delete the check, which would otherwise pass by scanning '
      'nothing.',
    );
  }
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// Matches both spellings the server uses: `router.get('/x', …)` and the
/// diagnostics router's local `get('/x', …)` helper, which exists so that
/// every diagnostics route is registered through the loopback-and-token
/// gates rather than around them.
///
/// The leading `/` in the path literal is what keeps this from matching an
/// ordinary `get(` on a map or a future.
final _anyRouteDeclaration = RegExp(
  r"""(?:router\.)?\b(get|post|put|delete)\(\s*'(/[^']*)'""",
);

/// Every route the server declares, across the whole of `server/lib`.
List<_Route> _wholeServerInventory() {
  final routes = <_Route>[];
  final filesWithRouters = <String>[];
  final filesWithRoutes = <String>[];
  for (final file in _serverSourceFiles()) {
    final text = file.readAsStringSync();
    // `File.path` on this platform is already repo-relative because the suite
    // runs from the repository root; normalised so the failure text reads the
    // same everywhere.
    final path = file.path.replaceAll(r'\', '/');
    if (text.contains('Router()')) filesWithRouters.add(path);
    var found = false;
    for (final match in _anyRouteDeclaration.allMatches(text)) {
      found = true;
      routes.add(
        _Route(
          method: match.group(1)!.toUpperCase(),
          path: match.group(2)!,
          // Irrelevant to §4.21.2 and deliberately not read there: the owner
          // gate is §4.2's question. Left false rather than half-derived.
          ownerGated: false,
          file: path,
          line: '\n'.allMatches(text.substring(0, match.start)).length + 1,
        ),
      );
    }
    if (found) filesWithRoutes.add(path);
  }
  if (routes.isEmpty) {
    fail(
      'Found no route declarations anywhere under $_serverLibDir. Either the '
      'server stopped mounting routes, or the way they are declared changed '
      'and this scan can no longer see them — which would make every check '
      'below pass by finding nothing, so it fails instead.',
    );
  }
  // **A derivation must refuse a result it cannot have got honestly.** A file
  // that builds a `Router()` and yields no routes to this scan is a file
  // declaring them in a spelling the regex above does not know — the exact
  // shape that would let a whole family of endpoints go unlisted while every
  // check here stayed green.
  final silent = filesWithRouters
      .where((f) => !filesWithRoutes.contains(f))
      .toList();
  if (silent.isNotEmpty) {
    fail(
      'These files construct a shelf `Router()` and this scan read no routes '
      'out of them:\n${silent.map((f) => '  - $f').join('\n')}\n\n'
      'Either they mount routes in a spelling `_anyRouteDeclaration` does not '
      'match — in which case those endpoints are invisible to §4.21.2 and the '
      'pattern must be widened — or the router is built and never populated.',
    );
  }
  return routes;
}

/// One parsed row of §4.21.2 — the Route cell, and where it is.
class _IsolationRow {
  const _IsolationRow({required this.route, required this.line});

  final String route;
  final int line;
}

List<_IsolationRow> _parseIsolationTable(List<String> docLines) {
  final start = docLines.indexWhere((l) => l.trim() == _isolationHeading);
  if (start == -1) {
    fail(
      'Could not find "$_isolationHeading" in $_securityModelPath. Either the '
      'section was renamed or renumbered — update this test — or it was '
      'removed, which is a much larger question than a test failure.',
    );
  }
  final rows = <_IsolationRow>[];
  for (var i = start + 1; i < docLines.length; i++) {
    final line = docLines[i];
    if (line.trim().startsWith(_isolationNextPrefix)) break;
    if (!line.trimLeft().startsWith('| `')) continue;
    final cells = line.split('|').map((c) => c.trim()).toList();
    if (cells.length < 4) continue;
    rows.add(_IsolationRow(route: cells[1], line: i + 1));
  }
  if (rows.isEmpty) {
    fail(
      'Parsed no rows out of $_isolationHeading in $_securityModelPath. The '
      "table's shape changed and this test can no longer read it — which "
      'would otherwise make every check below pass vacuously.',
    );
  }
  return rows;
}

/// Citations as §4.21.2 writes them: `` `GET /path` ``.
final _backtickedCitation = RegExp(
  r'`(GET|POST|PUT|DELETE) (/[A-Za-z0-9/<>_\-*]*)`',
);

/// A heading and the provenance marker that follows it, if any.
class _MarkedSection {
  const _MarkedSection({
    required this.heading,
    required this.line,
    required this.marker,
  });

  final String heading;
  final int line;

  /// `'Derived'`, `'Hand-kept'`, or null when the heading carries neither.
  final String? marker;
}

final _markerPattern = RegExp(r'^\*\*\*(Derived|Hand-kept)\*\*\*');

List<_MarkedSection> _markedSections(List<String> docLines) {
  final sections = <_MarkedSection>[];
  for (var i = 0; i < docLines.length; i++) {
    if (!RegExp(r'^#{2,4} ').hasMatch(docLines[i])) continue;
    String? marker;
    // The marker sits on its own line within the three lines below the
    // heading — immediately after it, or after one blank line. Anything
    // further down is prose that happens to be emphasised.
    for (var j = i + 1; j < docLines.length && j <= i + 3; j++) {
      final match = _markerPattern.firstMatch(docLines[j].trim());
      if (match != null) {
        marker = match.group(1);
        break;
      }
      if (docLines[j].trim().isEmpty) continue;
      break;
    }
    sections.add(
      _MarkedSection(heading: docLines[i].trim(), line: i + 1, marker: marker),
    );
  }
  return sections;
}

/// The section numbers the security model's registry claims are derived.
Set<String> _registryDerivedSections(List<String> docLines) {
  final start = docLines.indexWhere(
    (l) => l.trim().startsWith(_provenanceHeading),
  );
  if (start == -1) {
    fail(
      'Could not find "$_provenanceHeading" in $_securityModelPath. That '
      'section is the only place this document says which of its 300-odd '
      'headings are checked by a test and which are prose, so its absence is '
      'the defect task 11.123 exists to have fixed.',
    );
  }
  final numbers = <String>{};
  for (var i = start + 1; i < docLines.length; i++) {
    final line = docLines[i].trim();
    if (line.startsWith('---')) break;
    if (!line.startsWith('| §')) continue;
    final match = RegExp(r'^\| §([0-9.]+)').firstMatch(line);
    if (match != null) numbers.add(match.group(1)!);
  }
  if (numbers.isEmpty) {
    fail(
      'The registry under "$_provenanceHeading" names no derived sections. '
      'Either its table changed shape and this test can no longer read it, or '
      'nothing is derived any more — and only one of those is a documentation '
      'change.',
    );
  }
  return numbers;
}

String? _sectionNumberOf(String heading) =>
    RegExp(r'^#{2,4} ([0-9]+(?:\.[0-9]+)*)').firstMatch(heading)?.group(1);

void mainTask11123() {
  final matrixLines = File(_docPath).readAsLinesSync();
  final modelLines = File(_securityModelPath).readAsLinesSync();
  final inventory = _wholeServerInventory();
  final isolationRows = _parseIsolationTable(modelLines);

  group('§4.21.2 is derived from the whole server, not from §4.2\'s slice', () {
    test('every route the server declares has a verdict', () {
      final cited = isolationRows.map((r) => r.route).join('\n');
      final missing = inventory
          .where((route) => !cited.contains('`${route.citation}`'))
          .toList();
      expect(
        missing,
        isEmpty,
        reason:
            'These routes exist on the server and §4.21.2 gives no verdict for '
            'any of them. §2.4\'s likely breach is exactly this — one endpoint '
            'that checks authenticated and forgets authorized for this '
            'project — and the standing rule is that silence about an endpoint '
            'is not a verdict:\n'
            '${missing.map((r) => '  - $r').join('\n')}\n\n'
            'Read the handler and write the row. If the reading finds the '
            'isolation is not actually enforced, that is a finding for '
            'SECURITY_SCOPE_AND_EXIT.md and a Gate C question, not a row.',
      );
    });

    test('every route §4.21.2 names is one the server declares', () {
      final declared = inventory.map((r) => r.citation).toSet();
      final unknown = <String>[];
      for (final row in isolationRows) {
        for (final match in _backtickedCitation.allMatches(row.route)) {
          final citation = '${match.group(1)} ${match.group(2)}';
          if (!declared.contains(citation)) {
            unknown.add('line ${row.line} cites $citation');
          }
        }
      }
      expect(
        unknown,
        isEmpty,
        reason:
            'These rows of §4.21.2 give a verdict for a route the server does '
            'not mount. That is how the table came to carry four invitation '
            'routes for a week after tasks 11.81 and 11.84 deleted them:\n'
            '${unknown.map((u) => '  - $u').join('\n')}\n\n'
            'Declared routes are:\n'
            '${(declared.toList()..sort()).map((d) => '  - $d').join('\n')}',
      );
    });

    test('no route has two verdicts', () {
      final duplicates = <String>[];
      for (final route in inventory) {
        final owning = isolationRows
            .where((r) => r.route.contains('`${route.citation}`'))
            .toList();
        if (owning.length > 1) {
          duplicates.add(
            '${route.citation} is given a verdict at lines '
            '${owning.map((r) => r.line).join(' and ')}',
          );
        }
      }
      expect(
        duplicates,
        isEmpty,
        reason:
            'A route with two rows has two verdicts, and nothing says which '
            'one a reader should believe:\n'
            '${duplicates.map((d) => '  - $d').join('\n')}',
      );
    });
  });

  group('both documents say where the derivation stops', () {
    test('every heading of the permissions matrix is marked', () {
      final sections = _markedSections(matrixLines);
      expect(
        sections,
        isNotEmpty,
        reason:
            'Read no headings out of $_docPath, so this check would pass '
            'without examining anything.',
      );
      final unmarked = sections.where((s) => s.marker == null).toList();
      expect(
        unmarked.map((s) => '${s.heading} (line ${s.line})').toList(),
        isEmpty,
        reason:
            'These headings of $_docPath say neither ***Derived*** nor '
            '***Hand-kept***. A reader has no way to tell whether anything '
            'checks them, and one derived section teaches a reader to trust '
            'the rest.',
      );
    });

    test('§4.2 is marked derived and §4.3–4.5 are not', () {
      final byNumber = {
        for (final s in _markedSections(matrixLines))
          if (_sectionNumberOf(s.heading) != null)
            _sectionNumberOf(s.heading)!: s,
      };
      expect(
        byNumber['4.2']?.marker,
        'Derived',
        reason:
            '§4.2 is checked by this very file, so it must say so. If the '
            'check was removed, the marker must change with it.',
      );
      for (final number in ['4.3', '4.4', '4.5']) {
        expect(
          byNumber[number]?.marker,
          'Hand-kept',
          reason:
              '§$number is sync-path writes gated by RowAuthorizer and by '
              'table declarations — a different enumeration from routes. '
              'Marking it derived would be claiming a check that does not '
              'exist, and building a route-shaped one would be a check that '
              'cannot fail.',
        );
      }
    });

    test('the security model\'s registry and its markers agree', () {
      final claimed = _registryDerivedSections(modelLines);
      final marked = <String>{
        for (final s in _markedSections(modelLines))
          if (s.marker == 'Derived' && _sectionNumberOf(s.heading) != null)
            _sectionNumberOf(s.heading)!,
      };
      expect(
        marked,
        claimed,
        reason:
            'The registry under "$_provenanceHeading" and the ***Derived*** '
            'markers in the body of $_securityModelPath disagree.\n'
            '  claimed by the registry: ${(claimed.toList()..sort()).join(', ')}\n'
            '  marked in the body:      ${(marked.toList()..sort()).join(', ')}\n\n'
            'The registry is the only statement this document makes about '
            'which of its 300-odd headings a test reads. If it and the body '
            'can drift, it is worth nothing.',
      );
    });
  });

  group('the §4.21.2 derivation can fail', () {
    // Watched red in both directions before this was believed. Each of these
    // corrupts one side the way real drift would and requires the machinery
    // to notice — a green instrument has demonstrated that it does not fire,
    // and nothing else.

    test('a route with no row is caught', () {
      final cited = isolationRows.map((r) => r.route).join('\n');
      const invented = 'GET /projects/<projectId>/exports';
      expect(
        cited.contains('`$invented`'),
        isFalse,
        reason:
            'This check adds a route the document has never heard of and '
            'requires the "no verdict" direction to notice it. If the '
            'document actually gained that row, pick another route here.',
      );
      final withInvented = [
        ...inventory,
        _Route(
          method: 'GET',
          path: '/projects/<projectId>/exports',
          ownerGated: false,
          file: 'invented',
          line: 0,
        ),
      ];
      final missing = withInvented
          .where((route) => !cited.contains('`${route.citation}`'))
          .toList();
      expect(missing.map((r) => r.citation).toSet(), {invented});
    });

    test('a row with no route is caught', () {
      final declared = inventory.map((r) => r.citation).toSet();
      const fabricated = '| `POST /projects/invites/redeem` | none | gone |';
      final unknown = <String>[];
      for (final match in _backtickedCitation.allMatches(
        fabricated.split('|')[1],
      )) {
        final citation = '${match.group(1)} ${match.group(2)}';
        if (!declared.contains(citation)) unknown.add(citation);
      }
      expect(
        unknown,
        ['POST /projects/invites/redeem'],
        reason:
            'The reverse direction must notice a row for a route that was '
            'deleted — which is the state §4.21.2 was actually in, for four '
            'rows, for a week.',
      );
    });

    test('an unmarked heading is caught', () {
      final marked = _markedSections([
        '## 1. A section somebody wrote',
        '',
        'Prose with no marker.',
        '',
        '## 2. A section that says',
        '',
        '***Hand-kept*** — nothing reads this.',
      ]);
      expect(marked.map((s) => s.marker), [null, 'Hand-kept']);
    });

    test('the scan refuses a file that builds a router and declares nothing',
        () {
      // The real corpus is what proves the scanner; this proves the guard's
      // arithmetic without inventing a file on disk.
      const withRouters = ['a.dart', 'b.dart'];
      const withRoutes = ['a.dart'];
      expect(
        withRouters.where((f) => !withRoutes.contains(f)).toList(),
        ['b.dart'],
      );
    });
  });
}

// ---------------------------------------------------------------------------
// Task 11.302 — a route whose body chooses what it does. §4.21.2 is derived
// route by route, and **a new action on an existing route adds no route**, so
// the checks above cannot see one: `restore` could have shipped on
// `POST /projects/<projectId>/deletion` with the row still saying the body
// carries three actions. This reads the row's line and requires every action
// the shared enum declares — the same enum the server's `switch` is
// exhaustive over — to be named in it, in backticks.

const _deletionRoute = '`POST /projects/<projectId>/deletion`';

/// The wire names in [wires] that [verdictLine] does not name in backticks.
List<String> _unnamedActions(String verdictLine, Iterable<String> wires) => [
  for (final wire in wires)
    if (!verdictLine.contains('`$wire`')) wire,
];

void mainTask11302() {
  final modelLines = File(_securityModelPath).readAsLinesSync();
  final isolationRows = _parseIsolationTable(modelLines);

  group('§4.21.2 names every action a route\'s body can carry', () {
    test('the deletion route\'s verdict names every ProjectDeletionAction', () {
      final owning = isolationRows
          .where((r) => r.route.contains(_deletionRoute))
          .toList();
      expect(
        owning,
        hasLength(1),
        reason: '§4.21.2 must give $_deletionRoute exactly one row',
      );
      final line = modelLines[owning.single.line - 1];
      final missing = _unnamedActions(
        line,
        ProjectDeletionAction.values.map((a) => a.wire),
      );
      expect(
        missing,
        isEmpty,
        reason:
            'The server accepts these actions on $_deletionRoute and '
            '§4.21.2\'s verdict for it (line ${owning.single.line} of '
            '$_securityModelPath) does not say what any of them does or who '
            'may ask for it: ${missing.join(', ')}. An action is a new thing '
            'the route can be made to do, and the verdict is where it is '
            'argued — write it there, in backticks, before shipping it.',
      );
    });

    test('the check can fail', () {
      expect(
        _unnamedActions('`schedule` and `cancel`, and restore in prose', [
          'schedule',
          'cancel',
          'restore',
        ]),
        ['restore'],
      );
    });
  });
}

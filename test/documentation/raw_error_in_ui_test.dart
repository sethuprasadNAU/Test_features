import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **No user-visible string is built by pasting in a caught exception.**
///
/// Task 11.105 follow-up, 2026-08-31, at Michael's decision after the sweep
/// found sixty of these rather than the three that were reported.
///
/// ## The defect
///
/// `'Import failed — nothing was saved. $e'` renders, on a real phone:
///
/// > Import failed — nothing was saved. DatabaseException(UNIQUE constraint
/// > failed: Tags.tag_id) sql 'INSERT INTO Tags (tag_id, tag_name,
/// > frequency_mhz) VALUES (?, ?, ?)' args [f4a2-9c1…, Collar 12, 150.520]
///
/// It means nothing to a biologist, says nothing to do, and puts the database's
/// internals and the person's own field data on a screen that may be
/// photographed and emailed to somebody for help.
///
/// ## Why a check and not a comment
///
/// **Task 11.46 already fixed this once and wrote twenty lines saying it must
/// never come back** — in `projects_screen.dart`, for the publish path. Nobody
/// swept for the other forty-five. That is the third time this project has
/// fixed one copy of a fact and missed another, and it is the shape task 11.98
/// established the answer for: **a checked rule, where an exception has to be
/// argued for rather than merely overlooked.**
///
/// ## What it does
///
/// Every `.dart` file under `lib/` has comments stripped ([stripComments]) and
/// is scanned for a string literal interpolating a variable bound by a `catch
/// (…)` clause or an `error:`/`onError:` callback. Anything not exempt below
/// fails.
///
/// ## What is exempt, and why
///
/// - **Developer logging.** `debugPrint` and anything inside `if (kDebugMode)`.
///   A debug build is a different audience with a different need, and the raw
///   text still has to reach a console for anybody to diagnose anything.
/// - **Chaining a cause into a new exception** — `throw
///   BackupFormatException('… ($e)')`. That is not display. Whether the result
///   reaches a person is decided at the *display* site, which this check
///   already governs.
/// - **[_argued]**, the named list below. Empty, deliberately: the sweep left
///   nothing that needed an argument. An entry here must say what a person
///   reads and why the raw text is right for them.
///
/// ## What it does not catch
///
/// It is textual. It sees `'$e'` where `e` came from a `catch`; it does not see
/// `'${failure.toString()}'` on a variable assigned from one three lines
/// earlier, and it cannot tell a `Text` widget from a log call except by the
/// exemptions above. It closes the specific shape that has now recurred three
/// times. It is not a proof that no raw error can ever reach a screen.
const List<_Argued> _argued = [];

class _Argued {
  const _Argued({
    required this.file,
    required this.line,
    required this.reason,
  });

  final String file;
  final int line;
  final String reason;
}

/// Variables bound to a caught error: `catch (e)`, `catch (e, st)`,
/// `error: (e, st)`, `onError: (e, st)`.
final _binders = [
  RegExp(r'\bcatch\s*\(\s*([A-Za-z_]\w*)'),
  RegExp(r'\b(?:error|onError)\s*:\s*\(\s*([A-Za-z_]\w*)\s*,'),
];

/// A `throw` of a new exception built from the cause — chaining, not display.
final _chainedThrow = RegExp(r'\bthrow\s+[A-Z]\w*\s*\(');

void main() {
  test('no user-visible string in lib/ is built from a caught exception', () {
    final offences = <String>[];

    for (final file in dartFilesUnder('lib')) {
      final source = stripComments(file.readAsStringSync());
      for (final binder in _binders) {
        for (final match in binder.allMatches(source)) {
          final name = match.group(1)!;
          if (name == '_') continue;
          final scope = _scopeAfter(source, match.end);
          for (final hit in _rawInterpolationsOf(name).allMatches(scope)) {
            final absolute = match.end + hit.start;
            final line = '\n'.allMatches(source.substring(0, absolute)).length + 1;
            final statement = _statementAround(scope, hit.start);
            if (_isExempt(statement)) continue;
            if (_argued.any((a) => a.file == file.path && a.line == line)) {
              continue;
            }
            final offence = '${file.path}:$line — ${statement.trim()}';
            if (!offences.contains(offence)) offences.add(offence);
          }
        }
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          'A caught exception is being pasted into a string a person will '
          'read. The raw text can carry an SQL statement and the person\'s own '
          'field data, and it tells them nothing to do.\n\n'
          'Use describeFailure(e, fallback: …) from '
          'lib/core/errors/failure_message.dart, or the LoadFailure widget for '
          'a .when(error: …) branch. If the raw text is genuinely right here, '
          'add an entry to _argued in this file saying what a person reads and '
          'why.\n\n${offences.join('\n')}',
    );
  });

  test('the arguments list has no stale entries', () {
    // An entry that no longer matches anything is a licence nobody is using,
    // and the next person to read this file would take it as evidence that
    // the site still exists. Currently the list is empty and this passes
    // trivially — kept so it starts working the moment somebody adds one.
    for (final entry in _argued) {
      final matched = dartFilesUnder(
        'lib',
      ).any((f) => f.path == entry.file);
      expect(
        matched,
        isTrue,
        reason:
            '_argued names ${entry.file}, which no longer exists. Remove the '
            'entry.',
      );
      expect(
        entry.reason,
        isNotEmpty,
        reason: 'every entry must say why, in words',
      );
    }
  });
}

/// Matches the exception's **own string form** being interpolated — `$e`,
/// `${e}`, `${e.toString()}` — and deliberately not a named field.
///
/// **`'${e.statusCode}'` and `'${e.message}'` are not this defect.** Reading a
/// named field is an author choosing one specific value; pasting the whole
/// object is the thing that drags an SQL statement and somebody's field data
/// onto the screen. `data_export_screen.dart` interpolates two integers off a
/// `SchemaTooNewException` to tell a person which data-format version their
/// backup is, which is exactly the right thing to do and would be absurd to
/// forbid.
///
/// The hole this leaves: `'${e.cause}'`, where the field is itself an
/// exception. Nothing in `lib/` does that outside a `debugPrint` today, and
/// closing it properly needs types rather than text.
RegExp _rawInterpolationsOf(String name) {
  final n = RegExp.escape(name);
  return RegExp(r'\$' '$n' r'(?![\w.])'
      r'|\$\{\s*' '$n' r'\s*\}'
      r'|\$\{\s*' '$n' r'\.toString\(\)\s*\}');
}

/// Whether this statement is one of the exempt shapes.
bool _isExempt(String statement) =>
    statement.contains('debugPrint') ||
    statement.contains('kDebugMode') ||
    _chainedThrow.hasMatch(statement);

/// The `{…}` block a binder introduces, or a bounded slice of an expression
/// body when there is no block (an `error: (e, _) => Text(…)` arrow).
String _scopeAfter(String source, int from) {
  // Step past the rest of the parameter list first. `from` sits just after the
  // binder's name and comma, so the very next `)` is the one closing
  // `(e, _)` — **not a boundary of anything.** Scanning from here without
  // skipping it returned a two-character scope, and the check reported "all
  // clear" on a file that still had the defect in it. See the note in the
  // arrow branch below.
  var cursor = from;
  var parens = 0;
  while (cursor < source.length) {
    final c = source[cursor];
    if (c == '(') parens++;
    if (c == ')') {
      if (parens == 0) {
        cursor++;
        break;
      }
      parens--;
    }
    cursor++;
  }

  // A block body: `catch (e) { … }`, or `error: (e, _) { … }`.
  final brace = source.indexOf('{', cursor);
  final arrow = source.indexOf('=>', cursor);
  final blockFirst = brace != -1 && (arrow == -1 || brace < arrow);
  if (blockFirst && brace - cursor < 40) {
    var depth = 0;
    for (var i = brace; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}') {
        depth--;
        if (depth == 0) return source.substring(cursor, i + 1);
      }
    }
  }
  if (arrow == -1) return '';

  // An arrow body: read to the end of the expression by balancing brackets,
  // stopping at the `)` or `,` that closes the enclosing call.
  //
  // **This was a fixed 600-character window, and it was blind.** In
  // `server_config_screen.dart` an `error: (e, _) => Text(…)` branch chooses
  // between a 420-character authored sentence and `'Could not read sign-in
  // state: $e'`, and the `$e` sat past the 600th character. **A check that
  // cannot distinguish success from its own failure is not a check**, and an
  // arbitrary constant in the middle of one is where that starts.
  var depth = 0;
  for (var i = arrow + 2; i < source.length; i++) {
    final c = source[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) return source.substring(cursor, i);
      depth--;
    }
    if (c == ',' && depth == 0) return source.substring(cursor, i);
  }
  return source.substring(cursor);
}

/// The statement containing [offset], for the failure message and for the
/// exemption test. Bounded by the nearest `;`, `{` or `}` either side —
/// **except braces belonging to a `${…}` interpolation.**
///
/// That exception is not a nicety. Without it, `debugPrint('answered
/// ${e.statusCode}: $e')` has its statement cut at the brace inside
/// `${e.statusCode}`, the slice no longer contains the word `debugPrint`, and
/// two developer log lines in `server_config_screen.dart` were reported as
/// defects. **A check that misreports where a statement begins reports the
/// wrong file to whoever has to fix it.**
String _statementAround(String scope, int offset) {
  final inInterpolation = _interpolationSpans(scope);
  bool boundary(int i) =>
      ';{}'.contains(scope[i]) && !inInterpolation.contains(i);

  var start = offset;
  while (start > 0 && !boundary(start - 1)) {
    start--;
  }
  var end = offset;
  while (end < scope.length && !boundary(end)) {
    end++;
  }
  return scope.substring(start, end).replaceAll('\n', ' ');
}

/// Every character index inside a `${…}` interpolation, braces included.
Set<int> _interpolationSpans(String scope) {
  final inside = <int>{};
  for (var i = 0; i + 1 < scope.length; i++) {
    if (scope[i] != r'$' || scope[i + 1] != '{') continue;
    var depth = 0;
    for (var j = i + 1; j < scope.length; j++) {
      if (scope[j] == '{') depth++;
      if (scope[j] == '}') depth--;
      inside.add(j);
      if (depth == 0) break;
    }
  }
  return inside;
}

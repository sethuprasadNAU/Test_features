/// Task 11.199 — **the guard for a defect shape this project fixed one screen
/// at a time, five times, and then went looking for.**
///
/// Every closed value set in `package:tritrack_sync`'s `enums.dart` carries a
/// `db` field: the exact string SQLite stores, the `CHECK` constraint enforces,
/// the sync wire carries and the CSV export writes. **Several of those strings
/// happen to read as English** — `good`, `active`, `directional` — and that
/// coincidence is the whole defect. A screen that prints one looks fine to
/// whoever wrote it, right up until the reader meets `suspected_bounce` or
/// `regular_pulse`, underscore and all, or until somebody stores `co_owner` and
/// every screen that ever printed the token starts showing an identifier to a
/// biologist.
///
/// ## What was actually there when this was written
///
/// Task 11.196 handed this task **two** remaining sites and asked for the count
/// to be re-derived rather than inherited. Derived on 2026-09-08, the answer was
/// **six live sites in four files**, and four of them had never been reported:
///
/// | File | What a person saw |
/// | --- | --- |
/// | `observation_sharing_screen.dart` | `Signal: regular_pulse · medium` |
/// | `observation_sharing_screen.dart` | `Type: directional` |
/// | `tag_database_screen.dart` | the tag-status field, read-only: `malfunction` |
/// | `tag_database_screen.dart` | the tag-status wheel's four choices |
/// | `project_setup_screen.dart` | a project tag's subtitle: `· lost` |
/// | `log_screen.dart` | the supersede picker's rows: `omnidirectional` |
///
/// **The four nobody reported are the argument for this file.** Every earlier
/// fix was somebody noticing a word on a screenshot; noticing does not scale to
/// a screen a beta tester opens once.
///
/// ## The two conditions, and how each tells a display from a store
///
/// **1. No stored token in the presentation layer.** Nothing under
/// `lib/features/` or `lib/widgets/` reads `.db` at all, except the entries in
/// [_storedValueUsesInPresentation], each with a reason. **The separation is by
/// layer rather than by cleverness**: a repository, a model's `toDb`, a CSV
/// column, a sync payload and a test are all *correct* uses of the stored
/// spelling, and every one of them lives outside those two directories. So the
/// rule needs no judgement about what a particular `.db` is for, and no list of
/// which enums are "display enums" — it is the same question the file's own
/// directory already answers.
///
/// **2. One spelling per vocabulary.** For every enum in `enums.dart` with a
/// `db` field ([enumsWithStoredValues], derived — not a list typed here), a
/// `switch` arm or map entry keyed on one of its members and yielding a string
/// literal is a *mapping*. Each vocabulary names one owning file in
/// [_vocabularyOwners]; a mapping anywhere else fails unless it is on
/// [_mappingsThatAreNotVocabulary] with a reason.
///
/// ## Where this is blind, stated rather than discovered later
///
/// - **It reads switch arms and map entries, not every expression that could
///   produce a word.** `(CoordinateFormat.dd, 'DD')` in a list of records is a
///   display mapping and this does not see it; nor would `if (x == E.m) return
///   'word'`. Condition 1 is the mechanical half and condition 2 is a net with
///   a known mesh size.
/// - **It cannot tell a bad word from a good one.** A screen showing *Faulty*
///   for a tag stored as `malfunction` passes this and is still a mapping
///   nobody wrote down (task 11.194's "Extreme" defect). That needs a reader.
/// - **`server/` is out of scope and deliberately**: no server prose is shown
///   to a user (§4.13), so the server writes stored values into audit reasons
///   and JSON bodies as a matter of course.
/// - **`ProjectRole` has a second, narrower guard of its own** —
///   `role_vocabulary_test.dart`, task 11.99 — which checks all of `lib/` for
///   `role.db` rather than only the presentation layer, because that enum
///   leaked into refusal copy written in repositories. This file does not
///   replace it: condition 1 here would not look in `lib/data/`.
/// - **`invitation_vocabulary_test.dart` (task 11.98) is a different check and
///   was pointed at this class twice by mistake.** It scans for the words of a
///   *removed feature*. Its own doc comment now says so.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// Enums that carry a stored spelling, read out of the shared package rather
/// than listed here.
///
/// **Derived, and it refuses an empty answer.** A list typed into a test is the
/// hand-maintained control this project keeps finding wrong; and a search that
/// finds nothing and a subject that contains nothing are indistinguishable from
/// the inside, so the derivation asserts its own scope before anything uses it.
Map<String, List<String>> enumsWithStoredValues() {
  const path = 'packages/tritrack_sync/lib/src/enums.dart';
  final source = stripComments(File(path).readAsStringSync());
  final result = <String, List<String>>{};
  for (final match in RegExp(r'enum (\w+) \{(.*?)\n\}', dotAll: true)
      .allMatches(source)) {
    final body = match.group(2)!;
    if (!body.contains('final String db;')) continue;
    final members = RegExp(r'^\s*(\w+)\(', multiLine: true)
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toList();
    if (members.isEmpty) continue;
    result[match.group(1)!] = members;
  }
  return result;
}

/// The one file that spells each vocabulary for a person.
///
/// An enum with no entry here is one nothing in `lib/` maps to words today —
/// which the scan discovers rather than this list asserting it. The moment
/// something does, this test names the file it is in and asks for a decision.
const Map<String, String> _vocabularyOwners = {
  'BearingQuality': 'lib/core/format/observation_quality_display.dart',
  'SignalStrength': 'lib/core/format/observation_quality_display.dart',
  'ObservationType': 'lib/core/format/observation_quality_display.dart',
  'SignalType': 'lib/core/format/observation_quality_display.dart',
  'TagStatus': 'lib/core/text/tag_status_labels.dart',
  // Task 11.241: the animal's two vocabularies, spelled beside the collar's.
  'IndividualStatus': 'lib/core/text/tag_status_labels.dart',
  'IndividualSex': 'lib/core/text/tag_status_labels.dart',
  'ProjectRole': 'lib/core/text/role_labels.dart',
  'ObservationExclusionKind': 'lib/data/analysis/analysis_eligibility.dart',
};

/// A `.db` read inside the presentation layer that is a write to storage.
const List<_Allowed> _storedValueUsesInPresentation = [
  _Allowed(
    file: 'lib/features/observations/providers/observation_form_provider.dart',
    reason:
        'Serialises the half-finished Record form to disk so a person does not '
        'lose it, and reads it back with `fromDb`. This is storage that happens '
        'to live under lib/features/ because the draft belongs to that screen — '
        'nothing here reaches a widget.',
  ),
];

/// A switch on a stored value that yields a string which is **not a name for
/// that value**, and so is not a second spelling of the vocabulary.
const List<_Allowed> _mappingsThatAreNotVocabulary = [
  _Allowed(
    file: 'lib/core/format/coordinate_formatter.dart',
    reason:
        'Switches on CoordinateFormat to format a *coordinate*. The strings are '
        'latitudes and longitudes, not names for "dd" and "dms".',
  ),
  _Allowed(
    file: 'lib/data/repositories/observation_exclusion_repository.dart',
    reason:
        'Switches on ObservationExclusionKind to say *who is permitted* to do '
        'each — "an owner of this project". That is the role gradient in words, '
        'not a name for the kind.',
  ),
  _Allowed(
    file: 'lib/features/observations/screens/observation_logging_screen.dart',
    reason:
        'Two mappings, both deliberate and both documented at the call site. '
        'The SAVE button caption per RecordType is an instruction, not the '
        'record type\'s name (that is RecordType.label). And '
        '_signalStrengthShortLabel abbreviates the shared words to fit a '
        '120-pixel roller column — "Med", "V. strong" — which task 11.194 '
        'settled as a fact about the column rather than about the value, after '
        'the previous abbreviation ("Extreme") turned out to be a synonym the '
        'CSV export disagreed with.',
  ),
];

class _Allowed {
  const _Allowed({required this.file, required this.reason});
  final String file;
  final String reason;
}

/// An identifier, `)` or `]` then `.db` — a property read, so `super.db` and a
/// constructor's `this.db` are matched too and a filename like
/// `'tri_track.db'` inside a string is not (there are none in these two
/// directories; the allowlist is where one would be argued for).
final _storedValueRead = RegExp(r'[A-Za-z0-9_)\]]\??\.db\b');

const _presentationLayer = ['lib/features', 'lib/widgets'];

/// Widget-defining files outside [_presentationLayer], each with a reason
/// condition 1 above does not need to see them.
///
/// **Task 11.192's answer to this file's own stated limitation** — *"the day
/// somebody writes a widget under `lib/core/`... that rule is quietly
/// narrower than it reads."* Measured 2026-09-08: it already had, twice.
/// Neither reads a stored value today (asserted below, alongside this file),
/// but condition 1's scan of `_presentationLayer` would not have noticed if
/// either one started.
const List<String> _widgetsOutsidePresentationLayer = [
  // TriTrackApp / _TriTrackAppState: app-shell scaffolding (theme, routing,
  // lifecycle observer) — no screen content, no domain vocabulary.
  'lib/app.dart',
  // TabShell / _TabShellState: the bottom-nav shell around the four tabs —
  // route wiring, no domain vocabulary.
  'lib/routing/app_router.dart',
];

final _widgetSuperclass = RegExp(
  r'\bextends\s+(StatelessWidget|StatefulWidget|ConsumerWidget|'
  r'ConsumerStatefulWidget|HookConsumerWidget|HookWidget|CustomPainter|'
  r'State<|ConsumerState<|HookState<)',
);

void main() {
  final enums = enumsWithStoredValues();

  test('the enum derivation reached the shared package', () {
    // Not a threshold somebody picked: these four are the vocabularies this
    // task and task 11.99 actually fixed, so a derivation that cannot see them
    // is not the derivation this file's other two tests think they are running.
    expect(
      enums.keys,
      containsAll(['BearingQuality', 'SignalType', 'TagStatus', 'ProjectRole']),
    );
    for (final entry in enums.entries) {
      expect(entry.value, isNotEmpty, reason: '${entry.key} parsed no members');
    }
    for (final owned in _vocabularyOwners.keys) {
      expect(
        enums.keys,
        contains(owned),
        reason:
            '$owned is in _vocabularyOwners but no longer exists in '
            'enums.dart. Remove its entry.',
      );
      expect(
        File(_vocabularyOwners[owned]!).existsSync(),
        isTrue,
        reason: '${_vocabularyOwners[owned]} no longer exists.',
      );
    }
  });

  test(
    "condition 1's own assumption — every widget lives under "
    '_presentationLayer, except a named few — is checked rather than '
    'merely believed',
    () {
      for (final f in _widgetsOutsidePresentationLayer) {
        final file = File(f);
        expect(file.existsSync(), isTrue, reason: '$f is gone; remove its entry.');
        final stripped = stripComments(file.readAsStringSync());
        expect(
          _widgetSuperclass.hasMatch(stripped),
          isTrue,
          reason:
              '$f no longer defines a widget. Remove its entry — an '
              'allowlist that keeps entries nothing needs is a list nobody '
              'reads.',
        );
        expect(
          _storedValueRead.hasMatch(stripped),
          isFalse,
          reason:
              "$f now reads a stored database value, and condition 1's scan "
              'of _presentationLayer does not cover it because it lives '
              'outside lib/features/ and lib/widgets/. Move the read behind '
              'the owning vocabulary file in _vocabularyOwners, or move this '
              'file under lib/features/ or lib/widgets/.',
        );
      }

      final offenders = <String>[];
      for (final source in dartFilesUnder('lib')) {
        final relative = _relative(source.path);
        if (_presentationLayer.any((root) => relative.startsWith('$root/'))) {
          continue;
        }
        if (_widgetsOutsidePresentationLayer.contains(relative)) continue;
        final stripped = stripComments(source.readAsStringSync());
        if (_widgetSuperclass.hasMatch(stripped)) {
          offenders.add(relative);
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'These define a widget outside lib/features/ and lib/widgets/, '
            'so the check above (nothing in the presentation layer reads a '
            'stored database value) does not scan them:\n'
            '${offenders.map((o) => '  - $o').join('\n')}\n\n'
            'Move the file under lib/features/ or lib/widgets/, or — if it '
            'genuinely belongs where it is — add it to '
            '_widgetsOutsidePresentationLayer with a one-line reason, the '
            'same way _storedValueUsesInPresentation documents an exception '
            'to the sibling rule.',
      );
    },
  );

  test(
    'nothing in the presentation layer reads a stored database value, except '
    'the named writes to storage',
    () {
      for (final allowed in _storedValueUsesInPresentation) {
        final file = File(allowed.file);
        expect(file.existsSync(), isTrue, reason: '${allowed.file} is gone.');
        expect(
          _storedValueRead.hasMatch(stripComments(file.readAsStringSync())),
          isTrue,
          reason:
              '${allowed.file} no longer reads a stored value. Remove its '
              'entry — an allowlist that keeps entries nothing needs is a list '
              'nobody reads.',
        );
      }

      final offenders = <String>[];
      for (final root in _presentationLayer) {
        for (final source in dartFilesUnder(root)) {
          final relative = _relative(source.path);
          if (_storedValueUsesInPresentation.any((a) => a.file == relative)) {
            continue;
          }
          final stripped = stripComments(source.readAsStringSync());
          for (final match in _storedValueRead.allMatches(stripped)) {
            offenders.add('$relative:${_lineOf(stripped, match.start)}');
          }
        }
      }

      expect(
        offenders,
        isEmpty,
        reason:
            'These read an enum\'s stored database value inside the layer that '
            'draws things:\n${offenders.map((o) => '  - $o').join('\n')}\n\n'
            '`.db` is a storage spelling — what the SQLite column holds, what '
            'the CHECK constraint enforces, what the sync wire carries and what '
            'the CSV export writes. Some of those strings read as English, '
            'which is the only reason six screens printed one at a person '
            'without anybody noticing. Show a word instead: the owning file for '
            'each vocabulary is listed in _vocabularyOwners in this test, and '
            'a vocabulary with no owner yet needs one written rather than a '
            'word invented at the call site. If this really is a write to '
            'storage that happens to live here, add it to '
            '_storedValueUsesInPresentation with a one-line reason.',
      );
    },
  );

  test('each vocabulary is spelled in exactly one file', () {
    for (final allowed in _mappingsThatAreNotVocabulary) {
      expect(
        File(allowed.file).existsSync(),
        isTrue,
        reason: '${allowed.file} is gone; remove its entry.',
      );
    }
    final allowedFiles = {
      for (final a in _mappingsThatAreNotVocabulary) a.file,
    };
    final stillMapping = <String>{};

    final offenders = <String>[];
    for (final source in dartFilesUnder('lib')) {
      final relative = _relative(source.path);
      final stripped = stripComments(source.readAsStringSync());
      for (final entry in enums.entries) {
        for (final match in _mappingArm(entry.key, entry.value)
            .allMatches(stripped)) {
          if (!_yieldsAStringLiteral(stripped, match.end)) continue;
          if (allowedFiles.contains(relative)) {
            stillMapping.add(relative);
            continue;
          }
          if (_vocabularyOwners[entry.key] == relative) continue;
          offenders.add(
            '$relative:${_lineOf(stripped, match.start)} maps ${entry.key} '
            '(owner: ${_vocabularyOwners[entry.key] ?? 'none declared yet'})',
          );
        }
      }
    }

    for (final allowed in _mappingsThatAreNotVocabulary) {
      expect(
        stillMapping,
        contains(allowed.file),
        reason:
            '${allowed.file} no longer maps any stored value to a string. '
            'Remove its entry from _mappingsThatAreNotVocabulary.',
      );
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'These turn a stored value into words outside the file that owns '
          'that vocabulary:\n${offenders.map((o) => '  - $o').join('\n')}\n\n'
          'One vocabulary, one file. Two copies is two spellings waiting to '
          'drift, and this app has shipped that twice: the same signal '
          'strength read "Moderate" in the edit dialog, "Med" on the Record '
          'roller and "medium" on the Position screen, and a role read '
          '"owner" one screen and "Owner — also manages members" the next. '
          'Read the owning file instead. If these strings are not *names for '
          'the value* — a coordinate formatted by its format, a button '
          'caption, a sentence about who may do something — add the file to '
          '_mappingsThatAreNotVocabulary with a reason saying which.',
    );
  });
}

/// `case E.m:`, `E.m =>`, `E.m || E.other =>`, `E.m:` in a map literal.
///
/// **A mapping is a switch arm or a map entry**, which is narrow on purpose: it
/// is the shape that produces one word per value, and it does not match
/// `x == E.m ? 'a' : 'b'` or a named argument, both of which are everywhere.
RegExp _mappingArm(String name, List<String> members) => RegExp(
      '(?:case\\s+)?$name\\.(?:${members.join('|')})\\b'
      '(?:\\s*\\|\\|\\s*$name\\.\\w+)*\\s*(?:=>|:)',
    );

/// Whether the arm beginning at [start] yields a string literal.
///
/// Reads to the end of the arm — the first `,` or `;` at bracket depth zero,
/// the next `case`, or the brace that closes the switch — so a quote belonging
/// to the *next* arm is never attributed to this one. That is this project's
/// standing rule about delimiters: a split that runs "up to the next one" gets
/// the last element wrong.
bool _yieldsAStringLiteral(String source, int start) {
  var depth = 0;
  for (var i = start; i < source.length; i++) {
    final c = source[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth == 0) return false;
      depth--;
    } else if (depth == 0 && (c == ',' || c == ';')) {
      return false;
    } else if (depth == 0 && source.startsWith('case ', i)) {
      return false;
    } else if (c == "'" || c == '"') {
      return true;
    }
  }
  return false;
}

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

String _relative(String path) =>
    path.startsWith('./') ? path.substring(2) : path;

// **Task 11.200.** `lib/core/theme/app_theme.dart` builds its [ColorScheme]
// from an explicit argument list. Every member it does not pass still *works*
// — Flutter's getters fall back rather than throwing — so an omission is
// invisible from the call site and produces a colour that is plausible and
// wrong. `onSurfaceVariant` was omitted for the life of this app: 83 call
// sites asked for "muted" and were handed full-strength body text, including
// the one control Michael described in words ("light grey by default").
//
// Nothing failed, because nothing was wrong by any assertion anybody had
// written. This is that assertion. It derives both halves — what the theme
// passes, and what `lib/` asks for — and refuses an empty derivation on
// either side, because a search that finds nothing and a subject that
// contains nothing are indistinguishable from the inside.
//
// A member that is used and not passed must be argued for in
// [_knownFallbacks] below, which names what it currently falls back to. That
// list is the outstanding work, not an exemption: every entry is a place
// where the app is drawing a colour nobody chose. **Task 11.201 emptied it.**
//
// This guard asks whether a member was *passed*. It says nothing about
// whether the value passed is any good, and a token can be defined and still
// unreadable — see `theme_contrast_test.dart`, which asserts measured
// contrast ratios rather than the presence of an argument.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Members used in `lib/` that [_AppTheme] does not pass, each with the value
/// Flutter's getter falls back to and a verdict. **Adding a row here is a
/// decision to ship a colour nobody picked; say why.**
///
/// **Empty since task 11.201**, which defined the six this list held. It is
/// deliberately kept rather than deleted: an empty escape hatch beside a
/// green guard says *nothing is being substituted today*, and the test below
/// refuses a row that has stopped being true, so it cannot silently become a
/// place to park an omission.
const _knownFallbacks = <String, String>{};

void main() {
  group('every ColorScheme member lib/ uses is one the theme chose', () {
    late Set<String> passed;
    late Map<String, Set<String>> usedByMember;

    setUpAll(() {
      passed = _membersPassedByAppTheme();
      usedByMember = _membersUsedUnderLib();
    });

    test('the derivation reached both of its subjects', () {
      // Neither number is a threshold somebody picked: the theme demonstrably
      // passes the roles this app is built on, and `lib/` demonstrably reads
      // the scheme in many places. A regex that stopped matching would report
      // a clean app, which is the failure this guard exists to make loud.
      expect(
        passed,
        containsAll(<String>['primary', 'onPrimary', 'surface', 'onSurface', 'outline']),
        reason: 'AppTheme\'s ColorScheme argument list was not parsed — the '
            'guard below would pass by finding nothing. Check the regex in '
            '_membersPassedByAppTheme against app_theme.dart.',
      );
      expect(
        usedByMember.keys,
        containsAll(<String>['onSurface', 'onSurfaceVariant', 'primary']),
        reason: 'No ColorScheme reads were found under lib/, which cannot be '
            'true. Check _membersUsedUnderLib.',
      );
    });

    test('onSurfaceVariant is passed, and means something other than onSurface', () {
      // The specific regression this task closed, named so a later edit that
      // drops the line fails with the reason rather than with a colour diff.
      expect(
        passed,
        contains('onSurfaceVariant'),
        reason: 'onSurfaceVariant is not passed to the ColorScheme, so it '
            'falls back to onSurface and every "muted" label in the app — '
            'including the Record screen\'s Irregular/Malfunctioning checkbox '
            'label, which was asked for as "light grey by default" — renders '
            'as full-strength body text. See task 11.200.',
      );
    });

    test('no member is used that the theme neither passes nor accounts for', () {
      final unexplained = <String, Set<String>>{
        for (final entry in usedByMember.entries)
          if (!passed.contains(entry.key) && !_knownFallbacks.containsKey(entry.key))
            entry.key: entry.value,
      };
      expect(
        unexplained,
        isEmpty,
        reason: 'These ColorScheme members are read in lib/ but never passed '
            'in app_theme.dart, so Flutter is silently substituting another '
            'colour. Either pass them in the ColorScheme, or add a row to '
            '_knownFallbacks in this file naming what they fall back to and '
            'why that is acceptable.',
      );
    });

    test('_knownFallbacks does not outlive the omissions it documents', () {
      // A row that is no longer needed is a row that teaches the next reader
      // the app has a problem it has already fixed.
      final stale = _knownFallbacks.keys
          .where((m) => passed.contains(m) || !usedByMember.containsKey(m))
          .toList();
      expect(
        stale,
        isEmpty,
        reason: 'These members are either passed by the theme now or no '
            'longer read anywhere in lib/. Delete their rows from '
            '_knownFallbacks.',
      );
    });
  });
}

/// The named arguments `AppTheme` passes to its `ColorScheme(...)`.
Set<String> _membersPassedByAppTheme() {
  final source = File('lib/core/theme/app_theme.dart').readAsStringSync();
  final start = source.indexOf('ColorScheme(');
  if (start < 0) return const <String>{};
  // Balance parentheses from the constructor call so the scan stops at the
  // end of the argument list rather than "up to the next thing that looks
  // like one" — this repository has been bitten by delimiting that way.
  var depth = 0;
  var end = start;
  for (var i = source.indexOf('(', start); i < source.length; i++) {
    if (source[i] == '(') depth++;
    if (source[i] == ')') {
      depth--;
      if (depth == 0) {
        end = i;
        break;
      }
    }
  }
  final args = _withoutComments(source.substring(start, end));
  return RegExp(r'(?:^|[(,])\s*([a-z][A-Za-z0-9]*)\s*:', multiLine: true)
      .allMatches(args)
      .map((m) => m.group(1)!)
      .where((name) => name != 'alpha')
      .toSet();
}

/// Every ColorScheme member read anywhere under `lib/`, mapped to the files
/// that read it. Comments are stripped first: a comment naming a token is a
/// discussion of it, not a call site, and this file itself is proof that such
/// comments exist.
Map<String, Set<String>> _membersUsedUnderLib() {
  final used = <String, Set<String>>{};
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));
  // `Theme.of(context).colorScheme.x`, `theme.colorScheme.x`, and the local
  // `final scheme = ...colorScheme;` that most of this app uses.
  final direct = RegExp(r'colorScheme\s*\.\s*([a-z][A-Za-z0-9]*)');
  final viaLocal = RegExp(r'\bscheme\s*\.\s*([a-z][A-Za-z0-9]*)');
  for (final file in files) {
    final source = _withoutComments(file.readAsStringSync());
    for (final re in [direct, viaLocal]) {
      for (final match in re.allMatches(source)) {
        final member = match.group(1)!;
        if (member == 'copyWith' || member == 'harmonized') continue;
        (used[member] ??= <String>{}).add(file.path);
      }
    }
  }
  return used;
}

String _withoutComments(String source) => source
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

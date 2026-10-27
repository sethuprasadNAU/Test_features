import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// Task 11.324, item 5 — **"signal" means the tag's radio signal, and only
/// that.**
///
/// Michael, reviewing the printed guide (2026-10-02): in this app "signal" is
/// the tag — a *no signal* record, signal strength, an irregular signal — and
/// the same word was also being used for the phone's coverage ("Try again with
/// signal"). A tracker reading "no signal" on one screen and "with signal" on
/// the next has to work out which radio is meant. So every sentence about the
/// phone's connection says **cell or wifi coverage**, or **no connection**.
///
/// **What it does.** Every `.dart` file under `lib/` has its comments blanked
/// ([stripComments]) and its wrapped string literals joined — `'… with '` on
/// one line and `'signal.'` on the next is one sentence to a reader, and was
/// one of the fifteen this task rewrote. The joined text is searched for the
/// phrasings that can only mean coverage: *with*, *has*, *have*, *need(s) a*,
/// *without*, *there is* or *get(s)* immediately before the word.
///
/// **What it cannot see.** "No signal" is the tag's record type, so a sentence
/// that says *no signal* about the phone is indistinguishable here from one
/// about a collar; the same for a phrasing nobody has written yet ("once you
/// are back in signal"). Both need a person reading. This closes the shape the
/// fifteen sentences actually had.
final _coverageSignal = RegExp(
  r'\b(with|has|have|had|without|there is|get|gets|need an?|needs an?)'
  r'\s+signal\b',
  caseSensitive: false,
);

/// A closing quote, optional whitespace and a newline, then the same quote
/// opening again: Dart's adjacent-literal concatenation, as it appears in
/// wrapped copy.
final _adjacentLiterals = RegExp(r"""(['"])\s*\n\s*(r?)\1""");

void main() {
  test('no user-visible sentence in lib/ uses "signal" for phone coverage', () {
    final offenders = <String>[];
    for (final source in dartFilesUnder('lib')) {
      final joined = stripComments(
        source.readAsStringSync(),
      ).replaceAll(_adjacentLiterals, '');
      for (final m in _coverageSignal.allMatches(joined)) {
        final start = (m.start - 50).clamp(0, joined.length);
        final end = (m.end + 20).clamp(0, joined.length);
        offenders.add(
          '${source.path}: …'
          '${joined.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}…',
        );
      }
    }
    expect(
      offenders,
      isEmpty,
      reason:
          'These sentences use "signal" for the phone\'s connection:\n'
          '${offenders.map((o) => '  - $o').join('\n')}\n\n'
          'In TriTrack "signal" is the tag\'s radio signal (task 11.324, '
          'Michael\'s decision). Say "cell or wifi coverage", or "no '
          'connection", for the phone.',
    );
  });
}

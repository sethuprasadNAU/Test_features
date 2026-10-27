import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// Task 11.324, item 4 — **TriTrack has one central server, so help comes
/// from TriTrack support** (`CLAUDE.md`, standing decision 3, Michael
/// 2026-10-02: "We are moving to a central server not a project specific
/// server deployment").
///
/// Thirteen sentences told a person to ask "whoever runs the server" (or
/// "whoever manages your project server") — somebody a field tech on the
/// central server has no way to find. This keeps that phrasing out of the
/// app's strings. It reads comment-stripped source with wrapped literals
/// joined, the same way `signal_means_the_tag_test.dart` does.
///
/// It does not see a new phrasing of the same idea ("ask your server's
/// administrator"); that needs a person reading.
final _serverOperator = RegExp(
  r'\bwhoever\s+(runs|manages)\b',
  caseSensitive: false,
);

final _adjacentLiterals = RegExp(r"""(['"])\s*\n\s*(r?)\1""");

void main() {
  test('no sentence in lib/ sends a person to "whoever runs the server"', () {
    final offenders = <String>[];
    for (final source in dartFilesUnder('lib')) {
      final joined = stripComments(
        source.readAsStringSync(),
      ).replaceAll(_adjacentLiterals, '');
      for (final m in _serverOperator.allMatches(joined)) {
        final start = (m.start - 40).clamp(0, joined.length);
        final end = (m.end + 40).clamp(0, joined.length);
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
          'These sentences send a person to whoever runs the server:\n'
          '${offenders.map((o) => '  - $o').join('\n')}\n\n'
          'TriTrack runs one central server (CLAUDE.md, standing decision 3), '
          'so a person cannot find its operator; send them to TriTrack '
          'support (More → App Info) instead.',
    );
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/workflow_triggers.dart';

/// **GitHub's checks are paused, and a pause that nothing reads back is a
/// workflow that quietly stopped running.** Task 11.325 (2026-10-02): Michael
/// is making many commits a day, so every workflow starts only by hand and the
/// checks run as one batch on his own machines (`scripts/nightly_check.sh`).
/// Task 11.221 had done the same to one schedule on 2026-09-10 and the
/// reminder to restore it was a sentence; it came back only because a later
/// task happened to open the file.
///
/// **Each paused workflow carries a dated notice and keeps the triggers it had
/// as a comment**, so restoring is a copy. This file holds the notice and the
/// real triggers to each other, in both directions, plus the one line in
/// `RELEASE_CHECKLIST.md` that tells a person when to restore:
///
///  - a workflow with no automatic trigger and no notice is a *silent* pause;
///  - a notice over a workflow that has automatic triggers again is a stale
///    pause (somebody restored it and left the notice, or the reverse);
///  - a pause whose saved copy holds no automatic trigger would "restore"
///    nothing;
///  - the checklist line exists exactly while some workflow is paused.
///
/// **Not tested here: that the saved triggers are the right ones.** That was
/// read by hand when the pause was written; the saved block is copied from the
/// file's own prior text.
const _workflowDirectory = '.github/workflows';
const _checklist = 'CLAUDE_DOCS/RELEASE_CHECKLIST.md';

/// The sentence in the checklist that says GitHub's checks are paused.
const _checklistMarker = "GitHub's checks are paused";

List<File> _workflows() =>
    Directory(_workflowDirectory)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

void main() {
  final workflows = _workflows();

  test('the derivation found the workflows', () {
    expect(
      workflows,
      isNotEmpty,
      reason:
          'no workflow was found under $_workflowDirectory, so every check '
          'below would pass over nothing.',
    );
  });

  for (final file in workflows) {
    final name = file.uri.pathSegments.last;
    final source = file.readAsStringSync();
    final notice = pauseNotice.firstMatch(source);
    final live = onBlock(source);
    final automatic = automaticTriggers(live);

    test('$name: its pause, if any, is declared, and matches its triggers', () {
      expect(
        live,
        isNotEmpty,
        reason: '$name has no `on:` block this test could read.',
      );

      if (notice == null) {
        expect(
          automatic,
          isNotEmpty,
          reason:
              '$name starts on nothing but the Run workflow button and carries '
              'no `# PAUSED <date> (task …):` notice. That is a silent pause: '
              'a check nobody was told stopped. Say why and keep the old '
              'triggers beside it (see any other workflow here), or restore '
              'them.',
        );
        return;
      }

      final kind = notice.group(1);
      final saved = savedTriggers(source);
      expect(
        saved,
        isNotNull,
        reason:
            '$name says it is $kind but has no "Saved triggers, exactly as '
            'they were:" block, so there is nothing to restore from.',
      );
      expect(
        automaticTriggers(saved!),
        isNotEmpty,
        reason:
            '$name says it is $kind, but the triggers it saved hold nothing '
            'that starts it without a person, so restoring it would change '
            'nothing.',
      );

      if (kind == 'PAUSED') {
        expect(
          automatic,
          isEmpty,
          reason:
              '$name is marked PAUSED but still starts on '
              '${automatic.join(', ')}. Either the notice is stale (somebody '
              'restored the triggers and left it) or the pause is not what it '
              'says.',
        );
      } else {
        expect(
          automatic,
          isNotEmpty,
          reason:
              '$name is marked NARROWED but starts on nothing automatic; that '
              'is PAUSED, and should say so.',
        );
        expect(
          automatic,
          {'push'},
          reason:
              '$name is marked NARROWED, which this project uses for one case: '
              'a workflow that still publishes on a push to a named path. It '
              'starts on ${automatic.join(', ')}.',
        );
        expect(
          RegExp(r'^    paths:', multiLine: true).hasMatch(live),
          isTrue,
          reason:
              '$name is NARROWED to a push, and a narrowing is a `paths:` '
              'filter; without one it is every push, which is not narrowed.',
        );
      }
    });
  }

  test('the checklist says GitHub\'s checks are paused exactly while some are',
      () {
    final anyDeclared = workflows.any(
      (f) => pauseNotice.hasMatch(f.readAsStringSync()),
    );
    final text = File(_checklist).readAsStringSync();
    expect(
      text.contains(_checklistMarker),
      anyDeclared,
      reason: anyDeclared
          ? 'a workflow carries a pause notice and $_checklist has no line '
              'containing "$_checklistMarker", so nothing tells a person to '
              'restore the triggers before a release.'
          : 'no workflow is paused any more, but $_checklist still says '
              '"$_checklistMarker". Remove the line, or it will send somebody '
              'to restore something that is not off.',
    );
  });

  group('the readers this test and its neighbors depend on', () {
    // A guard built on a parser that returns nothing reports full coverage of
    // nothing, so the parser is pinned by a workflow of its own.
    const paused = '''
name: x

# PAUSED 2026-10-02 (task 11.325): by hand only.
on:
  workflow_dispatch:
#
# Saved triggers, exactly as they were:
# on:
#   push:
#     paths:
#       - 'a/**'
#   pull_request:
#   workflow_dispatch:

jobs:
  j:
    runs-on: ubuntu-latest
''';

    test('the live block ignores the saved comment', () {
      expect(automaticTriggers(onBlock(paused)), isEmpty);
      expect(onBlock(paused), isNot(contains('push')));
    });

    test('the saved block is read back as an on: block', () {
      final saved = savedTriggers(paused)!;
      expect(automaticTriggers(saved), {'push', 'pull_request'});
      expect(saved, contains("- 'a/**'"));
    });

    test('a notice is found, and a bare workflow has none', () {
      expect(pauseNotice.firstMatch(paused)!.group(1), 'PAUSED');
      expect(pauseNotice.hasMatch('name: x\non:\n  push:\n'), isFalse);
    });
  });
}

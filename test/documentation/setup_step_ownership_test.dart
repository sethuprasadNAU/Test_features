import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.52, landed by task 11.40 — **the guard that fails when a setup step
/// is copied instead of pointed at.**
///
/// A setup step is something a person must do to get something running.
/// `CLAUDE_DOCS/SETUP_OWNERSHIP.md` says which file owns each one. This test
/// reads that document's table at run time and enforces it.
///
/// **What it exists to stop.** Task 11.38 replaced "copy the template and fill
/// in your Team ID" with a command that writes the file — and
/// `macos/Runner/Configs/Signing.xcconfig.example` still carried the old
/// instruction, with `README.md` still sending people to it. **The instruction
/// 11.38 was reported for was sitting untouched in the one place the README
/// believed it had closed.** Task 11.37 fixed that instance and added a test
/// for that one sentence; this is the class. Four more live copies were found
/// and removed on 2026-08-29, of which two were *executable and wrong*.
///
/// **Both directions fail, and that is the point.** A new copy fails. So does
/// an owner that has stopped containing its own step — because then every
/// pointer at it points at nothing, which is the failure mode a
/// pointers-instead-of-copies rule trades for, and it should be loud. So does
/// a listed exemption that no longer applies, because an exemption nobody can
/// justify is how the next copy gets waved through.
///
/// Nothing here is hand-listed. Add a row to the document and it is enforced;
/// there is no list in this file to keep in step, which would be the same
/// defect one level up.
const _docPath = 'CLAUDE_DOCS/SETUP_OWNERSHIP.md';

const _tableHeader =
    '| Step | Owner | Signature | Copies allowed, and why |';

/// Files the search never reads.
///
/// The first three are **append-only records of what was said at the time**,
/// not instructions anybody follows — rewriting history in them to satisfy a
/// guard would be falsifying the record. The fourth is the ownership document
/// itself, which has to quote every signature to declare it.
const _excludedFiles = {
  'CLAUDE_DOCS/DEVELOPMENT_PLAN.md',
  'CLAUDE_DOCS/TriTrack_Security_Model.md',
  'CLAUDE_DOCS/TASK_COMMS.md',
  _docPath,
};

/// One row of the guarded table.
class _OwnedStep {
  _OwnedStep({
    required this.step,
    required this.owner,
    required this.signature,
    required this.allowed,
  });

  final String step;
  final String owner;
  final String signature;
  final Set<String> allowed;

  Set<String> get permitted => {owner, ...allowed};
}

/// Anything shaped like a repository-relative path — used to pull the allowed
/// files out of a prose cell without needing the prose to be machine-written.
/// Backticked tokens that are flags, package names or compose arguments do not
/// match, because none of them ends in a `.extension`.
final _pathLike = RegExp(r'^[A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-]+)*\.[A-Za-z]+$');

Iterable<String> _backticked(String cell) =>
    RegExp(r'`([^`]+)`').allMatches(cell).map((m) => m.group(1)!);

List<_OwnedStep> _readTable(List<String> lines) {
  final headerIndex = lines.indexWhere((l) => l.trim() == _tableHeader);
  if (headerIndex == -1) {
    fail(
      'Could not find the guarded table in $_docPath — no line reads exactly:\n'
      '  $_tableHeader\n\n'
      'Either the table was removed, in which case no setup step has an '
      'enforced owner any more and task 11.52 is reopened, or its header '
      'changed and this test needs to match. Do not "fix" this by deleting '
      'the test.',
    );
  }
  final steps = <_OwnedStep>[];
  // headerIndex + 1 is the `| --- |` separator.
  for (var i = headerIndex + 2; i < lines.length; i++) {
    final line = lines[i].trim();
    if (!line.startsWith('|')) break;
    final cells = line
        .split('|')
        .map((c) => c.trim())
        .where((c) => c.isNotEmpty)
        .toList();
    if (cells.length != 4) continue;
    final owner = _backticked(cells[1]).firstWhere(
      _pathLike.hasMatch,
      orElse: () => fail(
        'The "${cells[0]}" row names no owning file. The Owner cell must '
        'contain a repository-relative path in backticks — that is the whole '
        'content of the rule this table states.',
      ),
    );
    final signature = _backticked(cells[2]).firstOrNull;
    if (signature == null) {
      fail(
        'The "${cells[0]}" row has no signature in backticks. A row in the '
        'guarded table without one is a row this test silently skips, which '
        'is the shape of a check that cannot fail.',
      );
    }
    steps.add(
      _OwnedStep(
        step: cells[0],
        owner: owner,
        signature: signature,
        // `None.` means none, and the sentence after it is free prose — a
      // path mentioned there is being *explained*, not exempted. Without
      // this the explanation of a copy that was just removed reads as
      // permission to put it back, which is how the exemption list rots.
      allowed: cells[3].startsWith('None')
          ? const <String>{}
          : _backticked(cells[3]).where(_pathLike.hasMatch).toSet(),
      ),
    );
  }
  return steps;
}

/// Every file **the repository actually tracks**.
///
/// `git ls-files` rather than a directory walk, for a reason that showed up
/// the first time this ran: the walk read the developer's own untracked
/// `.env`, found a setup command in a comment they had copied there, and
/// failed the build over a file no instruction has ever come from. Tracked
/// files are exactly the set somebody could be instructed by, and the set is
/// derived rather than kept in step with `.gitignore` by hand.
List<String> _repositoryTextFiles() {
  // `--others --exclude-standard` as well as the cached set: a file that has
  // just been written and not yet staged is exactly where a fresh copy of a
  // setup step arrives, and a guard that only sees committed files would pass
  // on the commit that introduces one and fail on the next. `--exclude-standard`
  // is what keeps `.env` and build output out.
  final result = Process.runSync('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ]);
  if (result.exitCode != 0) {
    fail(
      '`git ls-files` failed (${result.stderr}). This test searches the '
      'tracked file set; it cannot fall back to walking the tree, because '
      'that reads untracked local files — which is how it failed the first '
      'time it ran.',
    );
  }
  return (result.stdout as String)
      .split('\u0000')
      .where((p) => p.isNotEmpty && !_excludedFiles.contains(p))
      .toList();
}

void main() {
  group('one file owns each setup step (task 11.52)', () {
    late List<_OwnedStep> steps;
    late List<String> files;

    setUpAll(() {
      final doc = File(_docPath);
      expect(
        doc.existsSync(),
        isTrue,
        reason:
            '$_docPath is missing. It is the only statement of which file owns '
            'which setup step, and without it this test enforces nothing.',
      );
      steps = _readTable(doc.readAsLinesSync());
      expect(
        steps,
        isNotEmpty,
        reason:
            'The guarded table in $_docPath parsed to zero rows. A derivation '
            'that matches nothing reports full coverage of nothing — fix the '
            'parse rather than accepting a green run.',
      );
      files = _repositoryTextFiles();
      expect(
        files.length,
        greaterThan(200),
        reason:
            'Only ${files.length} files were found to search, which is far '
            'fewer than this repository holds. The walk is broken, and a '
            'search over almost nothing finds almost nothing.',
      );
    });

    test('every owner still contains the step it owns', () {
      for (final step in steps) {
        final owner = File(step.owner);
        expect(
          owner.existsSync(),
          isTrue,
          reason:
              '$_docPath says ${step.owner} owns "${step.step}", and that file '
              'does not exist. Every pointer at it is now pointing at nothing.',
        );
        expect(
          owner.readAsStringSync().contains(step.signature),
          isTrue,
          reason:
              '${step.owner} owns "${step.step}" but no longer contains '
              '`${step.signature}`.\n\n'
              'Trading copies for pointers means the owner has to keep '
              'holding the thing. If the step genuinely moved, move the '
              'ownership row with it; if it was deleted, delete the row. What '
              'must not happen is several files pointing at a file that no '
              'longer says it.',
        );
      }
    });

    test('nothing else spells out a step somebody else owns', () {
      for (final step in steps) {
        final holders = files
            .where((f) => _contains(f, step.signature))
            .toSet();
        final unexpected = holders.difference(step.permitted);
        expect(
          unexpected,
          isEmpty,
          reason:
              'These files spell out "${step.step}", which ${step.owner} '
              'owns:\n'
              '${unexpected.map((f) => "  - $f").join("\n")}\n\n'
              'Searched for: `${step.signature}`\n\n'
              'A pointer that goes stale is a broken link. **A copy that goes '
              'stale is wrong instructions somebody follows** — and this '
              'project has now shipped four of those at once, two of which '
              'could be executed and were wrong. Either replace the copy with '
              'a pointer at ${step.owner}, or add the file to the "Copies '
              'allowed, and why" cell in $_docPath **with the reason**. '
              'Writing the reason down is the part that matters: "we looked at '
              'it and decided yes" and "we never looked" are '
              'indistinguishable a year later.',
        );
      }
    });

    test('every allowed copy is still there', () {
      for (final step in steps) {
        for (final allowed in step.allowed) {
          expect(
            File(allowed).existsSync() && _contains(allowed, step.signature),
            isTrue,
            reason:
                '$_docPath lists $allowed as an allowed copy of '
                '"${step.step}", and it no longer contains '
                '`${step.signature}`.\n\n'
                'Delete the exemption. A list of files permitted to hold a '
                'copy, half of which no longer do, is a list nobody reads — '
                'and an exemption nobody reads is how the next copy gets '
                'waved through.',
          );
        }
      }
    });
  });
}

/// Whether [path] holds [signature], treating anything unreadable as text-free
/// rather than as a failure — a binary asset cannot carry an instruction.
bool _contains(String path, String signature) {
  try {
    return File(path).readAsStringSync().contains(signature);
  } on FileSystemException {
    return false;
  } on FormatException {
    return false;
  }
}

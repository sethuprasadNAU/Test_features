/// Task 11.179 — **the citations in `CLAUDE_DOCS/` name files that exist, and
/// there are fewer of them every month.**
///
/// The planning documents cite the code the way a paper cites a page:
/// `some_file.dart:42`. Task 11.123 counted **712** of those across
/// `CLAUDE_DOCS/*.md` and measured what was wrong with them. Two things were,
/// and two things were not, and this file is built around that difference.
///
/// **What was wrong: 22 named a file that no longer exists.** Every one was a
/// feature that had been deleted — the cloud backup (`3a9a2c8`), the
/// per-address invitations (task 11.81), a command file removed when its task
/// closed. Nothing pointed a reader at the wrong line of a real file; they
/// pointed at nothing at all. That is a cheap check and a real defect, and it
/// is the second test below. **It found more than dead links:** two rows of
/// `PERMISSIONS_MATRIX.md` were still describing cloud backup as a live
/// capability eight days after the code was deleted, and the dead citation is
/// what made them visible.
///
/// **What was not wrong: the line numbers.** Not one of the 712 pointed past
/// the end of its file. A "the line number is in range" check would have gone
/// green on the day it was written against every citation in the repository
/// and caught nothing — **the check-that-cannot-fail class** — and it would be
/// worse than no check at all, because a document with a citation checker
/// teaches its reader that the citations are checked. It is deliberately not
/// built. What actually rots is the *content* of a cited line, silently, and
/// no arithmetic on line numbers can see that.
///
/// **So the second half is a ratchet rather than a checker.** A line number is
/// a claim that cannot be verified and cannot announce its own decay, so the
/// remedy is to stop writing new ones: cite the line's *content* — a function
/// name, a constant, the sentence itself — which a reader can search for and
/// which fails visibly when it is gone. That is the shape
/// `UNEXERCISED_CONTROLS.md`'s uid-70 and diagnostics entries were rewritten
/// into on 2026-09-06, both of which had rotted in the same week. Rewriting
/// the ~700 that already exist buys little; stopping the next 700 buys the
/// whole benefit. So: **the count per document may fall and may never rise.**
///
/// ## Why a number in a file is allowed here
///
/// This project distrusts a hand-kept number, and it is right to. The argument
/// that this one is safe has two halves, and both are about *direction*.
///
/// **It is not a hand-kept list.** [_citationBudget] holds no citations. The
/// test recomputes the real count from the documents on every run and
/// compares. Nothing here can be true-in-the-file and false-in-the-repository;
/// the numbers are only a ceiling.
///
/// **It can only be edited downward by ordinary work.** Removing citations
/// makes it red and the fix is to lower a number, which is a fact somebody has
/// just established. *Adding* citations makes it red and the fix is **not** to
/// raise the number — it is to write the citation differently. So forgetting
/// to maintain this file can only ever produce a red saying "you added
/// citations", never a silent pass.
///
/// Compare `app_shell_harness_default_test.dart`'s per-file counts, which move
/// **up** during ordinary work: adding a test there obliges an edit to a
/// ledger in another directory where no new decision is being made. In that
/// file's first four days every one of the five edits to its list was such a
/// bump, and the one time a task did not make it, `flutter test` was red on
/// `main` for two commits. **A ratchet that must be edited during normal work
/// will eventually be edited without thought, or not at all.** This one must
/// not become that. If some future document genuinely must quote line numbers,
/// that is the moment to re-argue this whole check — not the moment to raise a
/// number.
///
/// ## What this does not check
///
/// - **Whether a cited line still says what the document claims.** Nothing
///   here can; that is the reason for the ratchet rather than an omission from
///   it.
/// - **Ambiguous citations.** `AndroidManifest.xml:16` matches three tracked
///   files and `TriTrack_Technical_Context.md:243` matches two. Each names a
///   file that exists, which is all this check claims. The count is printed on
///   every run so it is visible, and it does not fail.
/// - **Citations into a package's source.** A pub-cache path is not a file in
///   this repository and never will be, so it must not be written in the
///   `path:NN` shape at all — name the package and the file inside it. There
///   is deliberately **no allowlist** for these: an allowlist is a hand-kept
///   list, and the alternative here costs one sentence of prose.
/// - **Anything outside `CLAUDE_DOCS/*.md`.** `README.md`, `website/` and the
///   source tree are not scanned. This is about the planning documents, which
///   are where the citations live.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The file extensions a `path:NN` citation can end in.
///
/// Derived from what the documents actually cite rather than from a guess: any
/// text file in this repository somebody might quote a line of. A citation in
/// an extension not on this list is invisible to both halves of this check —
/// which fails in the permissive direction, and is the right way round for a
/// ratchet that must never be raised by accident.
const List<String> _citableExtensions = [
  'dart',
  'py',
  'sh',
  'yml',
  'yaml',
  'md',
  'json',
  'sql',
  'ts',
  'js',
  'txt',
  'html',
  'css',
  'kt',
  'swift',
  'xml',
  'plist',
  'toml',
  'cfg',
  'conf',
];

final RegExp _citation = RegExp(
  '([A-Za-z0-9_./-]+\\.(?:${_citableExtensions.join('|')})):([0-9]+)',
);

/// The ceiling on `path:NN` citations per document. **May fall. May not rise.**
///
/// Measured 2026-09-06 by task 11.179, after that task fixed the citations
/// naming files that no longer exist. Every number here is the real count on
/// that day, not a rounded-up allowance — a ceiling with slack in it would let
/// citations be added silently, which is the one thing this is for.
///
/// A document absent from this map has a ceiling of zero: a document that has
/// never carried a `path:NN` citation must not start.
const Map<String, int> _citationBudget = {
  // 249 -> 248 by task 11.219, which closed the one citation naming the
  // deleted project_tag_repository.dart.
  'DEVELOPMENT_PLAN.md': 248,
  'JOIN_CODE_AND_APPROVAL_DESIGN.md': 31,
  // 171 -> 156 by task 11.219: §7's tag rows lost the cross-project
  // machinery they cited, and T7 (adopt an unused tag) became a struck-through
  // row rather than a live capability with code behind it.
  // 156 -> 155 by task 11.246: one path:NN in the new §4.7 rewritten to a
  // symbol citation before it could raise the count.
  // 155 -> 154 by task 11.313: M1's `projects_screen.dart:102` line-number
  // citation (already stale — the row had moved) rewritten to name the
  // Members menu item instead, alongside the new `members_screen.dart`.
  'PERMISSIONS_MATRIX.md': 154,
  'TASK_COMMS.md': 20,
  'TriTrack_Security_Model.md': 157,
  'UNEXERCISED_CONTROLS.md': 66,
  'WEBSITE_COMMS.md': 4,
};

class _Citation {
  const _Citation(this.document, this.line, this.path, this.lineNumber);

  final String document;
  final int line;
  final String path;
  final String lineNumber;

  String get text => '$path:$lineNumber';
  String get where => '$document:$line';
}

/// Every file the repository tracks, plus files written and not yet staged.
///
/// `--others --exclude-standard` as well as `--cached` for the reason
/// `setup_step_ownership_test.dart` gives: a document and the file it cites are
/// often written in the same commit, and a guard that saw only committed files
/// would fail on the commit that introduces both.
List<String> _repositoryFiles() {
  final result = Process.runSync('git', [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
  ]);
  if (result.exitCode != 0) {
    fail(
      '`git ls-files` failed (${result.stderr}). This test resolves citations '
      'against the tracked file set and must not fall back to walking the '
      'tree: a directory walk sees the pub cache, build output and the '
      "developer's own untracked scratch files, any of which could make a "
      'dead citation look alive.',
    );
  }
  return (result.stdout as String)
      .split('\u0000')
      .where((p) => p.isNotEmpty)
      .toList();
}

List<_Citation> _citationsIn(File document) {
  final name = document.uri.pathSegments.last;
  final citations = <_Citation>[];
  final lines = document.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    for (final match in _citation.allMatches(lines[i])) {
      citations.add(_Citation(name, i + 1, match.group(1)!, match.group(2)!));
    }
  }
  return citations;
}

void main() {
  late List<String> repositoryFiles;
  late Map<String, List<_Citation>> byDocument;

  setUpAll(() {
    repositoryFiles = _repositoryFiles();

    final directory = Directory('CLAUDE_DOCS');
    expect(
      directory.existsSync(),
      isTrue,
      reason:
          'CLAUDE_DOCS/ is missing. Every claim below is about the documents '
          'in it, so an absent directory would make this test pass having '
          'read nothing.',
    );

    byDocument = {};
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.md')) continue;
      final name = entity.uri.pathSegments.last;
      byDocument[name] = _citationsIn(entity);
    }
  });

  group('planning-document citations (task 11.179)', () {
    // A search that finds nothing and a subject that contains nothing are
    // indistinguishable from the inside, and only one of them is true. Both
    // checks below are satisfied by an empty scan, so the scan asserts itself
    // first — and it asserts what it found, not merely that it found
    // something, because a regex that had stopped matching would still find
    // the files.
    test('the scan reached the documents and found citations in them', () {
      expect(
        byDocument.length,
        greaterThan(10),
        reason:
            'Only ${byDocument.length} Markdown files were found in '
            'CLAUDE_DOCS/. There were 20 on 2026-09-06. Something narrowed '
            'what this test reads, and both checks below pass trivially on an '
            'empty scan.',
      );
      expect(
        repositoryFiles.length,
        greaterThan(100),
        reason:
            'git ls-files returned only ${repositoryFiles.length} paths. Every '
            'citation would then look dead, or — under a checkout narrow '
            'enough — nothing would be scanned at all.',
      );
      final total = byDocument.values.fold<int>(0, (n, c) => n + c.length);
      expect(
        total,
        greaterThan(500),
        reason:
            'Only $total path:NN citations were found across CLAUDE_DOCS/. '
            'There were 698 on 2026-09-06 and the count only falls slowly. A '
            'number this low means the regex stopped matching, not that the '
            'documents were rewritten.',
      );
      // ignore: avoid_print
      print(
        'scanned ${byDocument.length} documents, $total citations, against '
        '${repositoryFiles.length} repository files',
      );
    });

    test('every citation names a file that exists', () {
      final dead = <_Citation>[];
      final ambiguous = <_Citation>[];

      for (final citations in byDocument.values) {
        for (final citation in citations) {
          final path = citation.path;
          if (repositoryFiles.contains(path)) continue;

          // A citation is usually written relative to the repository root, but
          // the documents also cite by the tail of a path or by bare filename.
          // Both are honoured: the question this check asks is whether the
          // file exists, and a unique tail answers it.
          var candidates =
              repositoryFiles.where((f) => f.endsWith('/$path')).toList();
          if (candidates.isEmpty) {
            final base = path.split('/').last;
            candidates = repositoryFiles
                .where((f) => f.split('/').last == base)
                .toList();
          }
          if (candidates.isEmpty) {
            dead.add(citation);
          } else if (candidates.length > 1) {
            ambiguous.add(citation);
          }
        }
      }

      // Ambiguity is reported and never failed: each of these names a file
      // that exists, which is the whole of what this check claims.
      // ignore: avoid_print
      print('${ambiguous.length} citations resolve to more than one file');

      expect(
        dead,
        isEmpty,
        reason:
            'These citations name a file no longer in the repository:\n'
            '${dead.map((c) => '  ${c.where}  ->  ${c.text}').join('\n')}\n'
            'Each one is either a file that MOVED — repoint it — or a claim '
            'that DIED with the code it described, in which case say so in '
            'the document rather than leaving a link to nothing. Do not just '
            'delete the line number: a citation to a deleted feature is part '
            "of that feature's record, and the fix task 11.179 used was to "
            'name the commit that removed it.\n'
            'If the target is a file in a pub package rather than in this '
            'repository, do not write it in the path:NN shape at all — name '
            'the package and the file inside it, in prose.',
      );
    });

    test('no document gained a path:NN citation', () {
      final risen = <String>[];
      for (final entry in byDocument.entries) {
        final budget = _citationBudget[entry.key] ?? 0;
        final actual = entry.value.length;
        if (actual > budget) {
          risen.add(
            '  ${entry.key}: $budget allowed, $actual found '
            '(+${actual - budget})',
          );
        }
      }

      expect(
        risen,
        isEmpty,
        reason:
            'These documents gained path:NN citations:\n${risen.join('\n')}\n'
            '\n'
            'A line number is a claim nothing can verify and nothing can '
            'announce the decay of — the line moves, or its content changes, '
            "and the citation goes on looking correct. Cite the line's "
            'CONTENT instead: the function name, the constant, the sentence. '
            'A reader can search for that, and it fails visibly when it is '
            'gone.\n'
            '\n'
            'The fix is to rewrite the new citation, NOT to raise the number '
            'in _citationBudget. That number is a ceiling that only ever '
            'falls; raising it is a decision to keep writing citations that '
            'rot, and it needs an argument in this file rather than an edit '
            'to a map.',
      );

      final fallen = <String>[];
      for (final entry in _citationBudget.entries) {
        final actual = byDocument[entry.key]?.length;
        if (actual != null && actual < entry.value) {
          fallen.add('  ${entry.key}: ${entry.value} -> $actual');
        }
      }
      if (fallen.isNotEmpty) {
        // Not a failure. Lowering the ceiling is somebody's deliberate act,
        // and this is the run that tells them the number to write.
        // ignore: avoid_print
        print(
          'citation counts have fallen below their ceiling; lower these in '
          '_citationBudget:\n${fallen.join('\n')}',
        );
      }
    });
  });
}

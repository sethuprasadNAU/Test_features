import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.69 — **the guard that fails when a package is analysed without its
/// dependencies resolved.**
///
/// ## What went wrong, in one sentence
///
/// The offline workflow ran `flutter pub get` at the repository root and then
/// `flutter analyze`, which walks the whole tree — including `server/`, which
/// is its own package with its own `pubspec.yaml`. Nothing had ever run
/// `dart pub get` there on a clean checkout, so the analyzer could not resolve
/// `package:postgres` or `package:tritrack_server` and reported 1,284 errors
/// in code that was completely fine. It passed on the development machine
/// because `server/.dart_tool/package_config.json` was sitting there from an
/// earlier manual `dart pub get`, and that file is not in git.
///
/// **A file that is not committed is not part of the build.**
///
/// ## Why a test and not just the two lines in the workflow
///
/// The two lines fix today's instance. The next package added to this
/// repository — a second shared package, a tool, a second server — would land
/// with exactly the same defect, and it would look like 1,300 real errors in
/// somebody's pull request rather than a missing setup step. Task 10.66's
/// standing criterion is to fix the class.
///
/// The set is derived from the filesystem, not typed here: every directory
/// holding a `pubspec.yaml` that is not the repository root must be named in
/// an explicit `dart pub get --directory` line in the workflow. There is
/// deliberately **no exemption for a package the root resolve already covers**
/// — an exemption list is the same hand-maintained list one layer up, and a
/// redundant `dart pub get` costs seconds.
///
/// The other honest fix for the original failure was
/// `exclude: [server/**]` in `analysis_options.yaml`. That was rejected: it
/// would have turned the workflow green by making it stop looking at the
/// server, and **no workflow runs `dart analyze` inside `server/` either** —
/// the Server suite runs tests. Excluding would have left the server
/// unanalysed everywhere. If somebody ever does add an `exclude:` there, this
/// test does not catch it; the last case below is what does.
///
/// ## Asked of git, not the disk — task 11.312 item 6
///
/// This used to walk the disk (`Directory.listSync(recursive: true)`), which
/// answers a different question than "every package in the repository": it
/// also finds a `pubspec.yaml` inside a stray copy, a `git worktree` sitting
/// under the checkout, or any other directory that happens to be there but is
/// not part of the repository. Task 11.311 hit this — a throwaway worktree
/// left `flutter test` red for every window until it was removed. Defect
/// vocabulary entry 18: *"a check that says it reads every file in the
/// repository must ask git what that means"* — so this reads
/// `git ls-files --cached --others --exclude-standard`, the tracked files
/// plus the untracked-but-not-ignored ones (so a new package not yet
/// committed is still caught), the same derivation
/// `container_count_test.dart` already uses for the same reason.
void main() {
  late String workflow;

  /// Every `pubspec.yaml` this repository actually has, as the directory
  /// holding it (`''` for the root). Git-derived: `--cached` for what is
  /// committed, `--others --exclude-standard` for what is not yet committed
  /// but not ignored either, which is what makes a worktree under
  /// `.claude/worktrees/` (excluded via `.git/info/exclude`) invisible here
  /// while a genuinely new, not-yet-committed package still is not.
  List<String> pubspecPackageDirs() {
    final result = Process.runSync('git', [
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
    ]);
    expect(
      result.exitCode,
      0,
      reason: '`git ls-files` failed: ${result.stderr}',
    );
    final dirs = <String>[];
    for (final path in (result.stdout as String).split('\u0000')) {
      if (path.isEmpty || !path.endsWith('pubspec.yaml')) continue;
      // Anything under a build/tool output directory is not a package this
      // repository ships — `.dart_tool` in particular holds a copy of every
      // dependency's own pubspec. Git-tracked/untracked-but-not-ignored
      // output should not include these, but the exclusion is kept as a
      // second line of defense rather than assumed from that alone.
      if (path.split('/').any(
        (segment) =>
            segment == '.dart_tool' ||
            segment == 'build' ||
            segment == '.symlinks' ||
            segment.startsWith('.git'),
      )) {
        continue;
      }
      final dir = path == 'pubspec.yaml'
          ? ''
          : path.substring(0, path.length - '/pubspec.yaml'.length);
      if (dir.isEmpty) continue; // the root, covered by `flutter pub get`
      dirs.add(dir);
    }
    return dirs;
  }

  setUpAll(() {
    final file = File('.github/workflows/offline-suite.yml');
    expect(
      file.existsSync(),
      isTrue,
      reason:
          'offline-suite.yml is the workflow this test constrains; if it moved '
          'or was renamed, this test moves with it rather than being deleted',
    );
    workflow = file.readAsStringSync();
  });

  test('every package in the repository has its dependencies resolved before '
      'flutter analyze walks it', () {
    final packageDirs = pubspecPackageDirs();

    expect(
      packageDirs,
      isNotEmpty,
      reason:
          'this repository has at least `server/` and '
          '`packages/tritrack_sync`; finding none means the search above is '
          'broken, and a search that finds nothing reports full coverage — '
          'which is this project\'s standing finding, not a passing test',
    );

    for (final dir in packageDirs) {
      expect(
        workflow,
        contains('dart pub get --directory $dir'),
        reason:
            '`$dir` is its own package with its own pubspec.yaml, and '
            '`flutter analyze` at the repository root walks into it. Without '
            '`dart pub get --directory $dir` in offline-suite.yml, a clean '
            'checkout has no package_config.json there and every symbol in '
            'that package is reported undefined — 1,284 errors in working '
            'code, which is what happened on 2026-08-30. It passes on a '
            'machine where somebody has run `dart pub get` by hand, because '
            'that file is not in git.',
      );
    }
  });

  /// **Task 11.43 (reopened), the same class one step further on.** Resolving
  /// a package's dependencies is not the same as running its tests, and
  /// `packages/tritrack_sync` had the first and not the second: `flutter test`
  /// does not walk into it, and no workflow ran `dart test` there, so 313
  /// tests over the declarations *both* the app and the server are built from
  /// had never run on a clean checkout. It was found while adding a guard to
  /// that package — and a guard no workflow runs is not a guard.
  ///
  /// The allowlist below is deliberately an **explicit, reasoned** one rather
  /// than an absence of a check (the shape task 11.98 settled on): a package
  /// whose tests a *different* workflow runs has to be argued for here, by
  /// name, rather than merely not turning up.
  test('every package with tests has them run by a workflow', () {
    /// Packages whose suites another workflow owns. Each entry says which.
    const runElsewhere = {
      // `server-suite.yml` runs `scripts/run_server_tests_docker.sh`, which
      // brings up a throwaway Postgres first — these tests cannot run in the
      // offline workflow, whose whole claim is that nothing is listening.
      'server': 'server-suite.yml',
    };

    final tested = <String>[
      for (final dir in pubspecPackageDirs())
        if (Directory('$dir/test').existsSync()) dir,
    ];

    expect(
      tested,
      isNotEmpty,
      reason:
          'at least `server/` and `packages/tritrack_sync` have test '
          'directories; finding none means the search is broken, and a search '
          'that finds nothing reports full coverage',
    );

    for (final dir in tested) {
      if (runElsewhere.containsKey(dir)) continue;
      expect(
        workflow,
        contains('cd $dir && dart test'),
        reason:
            '`$dir` has a test directory and no workflow runs it. '
            '`flutter test` at the root does not walk into another package, '
            'so those tests pass only on somebody\'s machine. Add '
            '`cd $dir && dart test` to offline-suite.yml, or add `$dir` to '
            'the allowlist above naming the workflow that does run it.',
      );
    }
  });

  test('the root analysis options exclude exactly the four folders that hold '
      'no Dart this project writes, and nothing else', () {
    // **Task 11.335 narrowed this from "excludes nothing".** Flutter 3.47's
    // `flutter analyze` writes these four exclusions into
    // `analysis_options.yaml` itself ("Upgrading analysis_options.yaml to
    // exclude build and platform directories") and does it again on every run
    // while they are missing, so reverting them only trades a red test for a
    // file that changes under whoever runs the analyzer next.
    //
    // **Why allowing them gives up nothing:** `build/` is output;
    // `android/`, `ios/` and `macos/` hold Kotlin, Swift and generated plugin
    // registrants. The next test asks git whether that is still true.
    //
    // **What is still refused, and why** (the original reasoning, kept):
    // `flutter analyze` reporting every symbol in `server/` as undefined had
    // two fixes, and only resolving the dependencies is a fix. Nothing else in
    // CI analyses `server/`, so an `exclude:` naming it would leave it
    // unanalysed by every workflow while the tick went green. Any entry other
    // than the four below fails here.
    expect(
      excludedPatterns(File('analysis_options.yaml').readAsStringSync()),
      unorderedEquals(allowedExclusions),
      reason:
          'analysis_options.yaml excludes something other than the four '
          'folders the Flutter tool adds. Excluding a directory is a reduction '
          'in what is analysed, not a fix for a resolution failure — say here '
          'what coverage was deliberately given up, and why something else '
          'covers it, before changing allowedExclusions',
    );
  });

  test('the excluded folders hold no Dart file', () {
    // The condition the allowance above rests on, asked of git (defect
    // vocabulary entry 18) so that a new, not-yet-committed file counts too.
    final result = Process.runSync('git', [
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
    ]);
    expect(
      result.exitCode,
      0,
      reason: '`git ls-files` failed: ${result.stderr}',
    );
    final hidden = [
      for (final path in (result.stdout as String).split('\u0000'))
        if (path.endsWith('.dart') &&
            allowedExclusions.any(
              (glob) => path.startsWith(glob.replaceFirst('**', '')),
            ))
          path,
    ];
    expect(
      hidden,
      isEmpty,
      reason:
          'these Dart files sit under a folder analysis_options.yaml '
          'excludes, so `flutter analyze` is not looking at them',
    );
  });

  test('the exclusion reader can fail: it sees an extra entry, a missing '
      'entry, and no block at all', () {
    // A guard that reads a file by hand must be seen to disagree with one,
    // or an empty list would pass the "exactly these" check by being empty
    // in the same way the file is.
    const withServer =
        'include: x\nanalyzer:\n  exclude:\n    - build/**\n    - server/**\n'
        'linter:\n  rules:\n';
    expect(excludedPatterns(withServer), ['build/**', 'server/**']);
    expect(
      excludedPatterns(withServer),
      isNot(unorderedEquals(allowedExclusions)),
    );
    expect(excludedPatterns('include: x\nlinter:\n  rules:\n'), isEmpty);
    expect(
      excludedPatterns('analyzer:\n  exclude:\n    - "build/**"\n'),
      ['build/**'],
    );
  });
}

/// The four folders Flutter 3.47's `flutter analyze` excludes on its own.
const allowedExclusions = ['build/**', 'android/**', 'ios/**', 'macos/**'];

/// The entries of the `exclude:` list in [yaml], in order — empty when there
/// is none. Reads the list items under an `exclude:` key and stops at the
/// first line that is not one, comments and blanks aside.
List<String> excludedPatterns(String yaml) {
  final lines = yaml.split('\n');
  final entries = <String>[];
  var inList = false;
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (!inList) {
      inList = line == 'exclude:';
      continue;
    }
    if (!line.startsWith('- ')) break;
    entries.add(
      line.substring(2).trim().replaceAll(RegExp('^["\']|["\']\$'), ''),
    );
  }
  return entries;
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// **`.claude/settings.json` names a script that lives somewhere else, and
/// nothing on the script's side knows it is named.** Task 11.180 wired
/// `scripts/pre_commit_suite.sh` in as a `PreToolUse` hook so that a commit
/// cannot go in on a red tree the way commit `1d4bfd5` did.
///
/// That is this project's recorded coupling class, on its third instance: a
/// compose `healthcheck:` naming a flag `bin/server.dart` provides, a runbook
/// line naming a degradation report, and a harness patching a line it does not
/// own. **A rename here fails silently in the worst direction** — the hook
/// stops running, every commit is allowed, and the only symptom is the absence
/// of a line nobody was reading anyway.
void main() {
  test('every command a Claude hook names exists and can be run', () {
    final settingsFile = File('.claude/settings.json');
    expect(settingsFile.existsSync(), isTrue,
        reason: '.claude/settings.json is where this project wires its hooks; '
            'if it has moved, re-derive this test against wherever it went '
            'rather than deleting it');

    final settings =
        jsonDecode(settingsFile.readAsStringSync()) as Map<String, dynamic>;
    final hooks = settings['hooks'] as Map<String, dynamic>?;

    final commands = <String>[];
    for (final matchers in (hooks ?? const {}).values) {
      for (final matcher in matchers as List<dynamic>) {
        for (final hook
            in (matcher as Map<String, dynamic>)['hooks'] as List<dynamic>) {
          final command = (hook as Map<String, dynamic>)['command'];
          if (command is String) commands.add(command);
        }
      }
    }

    // **Refuse an empty derivation.** A settings file with no hooks in it and
    // a parse that found none look identical from here, and only one of them
    // is a decision somebody made.
    expect(
      commands,
      isNotEmpty,
      reason:
          'no hook commands were found in .claude/settings.json at all. Either '
          'the hooks were deliberately removed — in which case say so and '
          'delete this test — or this parse no longer understands the file, '
          'and it has been passing on an empty set.',
    );

    for (final command in commands) {
      final script = _scriptPathIn(command);
      expect(
        File(script).existsSync(),
        isTrue,
        reason:
            'a hook in .claude/settings.json runs "$command", and $script is '
            'not in the tree. The hook silently stops firing when this '
            'happens: nothing refuses, and every commit is simply allowed '
            'through. Point the hook at wherever the script went.',
      );
      expect(
        _isExecutable(script),
        isTrue,
        reason: '$script is named by a hook but is not executable, so the hook '
            'fails to run rather than failing to pass',
      );
    }
  });

  test('the pre-commit suite hook is still wired', () {
    final settings = File('.claude/settings.json').readAsStringSync();
    expect(
      settings,
      contains('pre_commit_suite.sh'),
      reason:
          'task 11.180 wired scripts/pre_commit_suite.sh in as a PreToolUse '
          'hook because `flutter test` was red on main at commit 1d4bfd5 and '
          'the commit went in past it. Removing it is a legitimate decision — '
          'the task wrote down what it costs — but it has to be a decision, '
          'which is what this line makes it.',
    );
  });

  /// **The hook must not exit 0 when it cannot read its own input — task
  /// 11.182.** Until then its payload reader was `except Exception:
  /// sys.exit(0)` with `2>/dev/null` after it, so an unreadable payload gave
  /// an empty command string, which failed the is-this-a-commit grep, which
  /// exited 0. **That is byte-for-byte what a genuine non-commit does**, and a
  /// session makes hundreds of those, so a parse failure would never have been
  /// noticed: the instrument built to enforce this project's discipline could
  /// not distinguish success from its own failure.
  ///
  /// Task 11.182 watched all five of these refuse by hand. **This group is
  /// what stops that being a one-off observation** — the refusal is a
  /// behaviour somebody could revert while every other test here stayed green,
  /// because nothing else asks the script a question it cannot answer.
  ///
  /// **No payload below is a commit.** A commit payload would send this test
  /// into a nested `flutter test`.
  group('the pre-commit hook refuses a payload it cannot read', () {
    const script = 'scripts/pre_commit_suite.sh';

    ProcessResult run(String payload) {
      // The hook reads its payload from stdin and `Process.runSync` cannot
      // supply one, so it arrives through a file redirect instead. `$0`/`$1`
      // rather than interpolation: one of these payloads is deliberately
      // malformed and none of them belongs in a shell string.
      final payloadFile = File(
          '${Directory.systemTemp.path}/tritrack-hook-payload-${payload.hashCode}');
      payloadFile.writeAsStringSync(payload);
      try {
        return Process.runSync(
          'bash',
          ['-c', 'exec "\$0" < "\$1"', script, payloadFile.path],
          // Keep the trace out of whatever a developer or CI is accumulating.
          environment: {
            'TRITRACK_PRECOMMIT_TRACE':
                '${Directory.systemTemp.path}/tritrack-precommit-hook-test.log',
          },
        );
      } finally {
        payloadFile.deleteSync();
      }
    }

    for (final entry in const {
      'not JSON at all': 'this is not json',
      'an empty payload': '',
      'JSON with no tool_input': '{}',
      'a tool_input with no command': '{"tool_input":{}}',
      'a command that is not a string': '{"tool_input":{"command":123}}',
    }.entries) {
      test('${entry.key} is refused, not waved through', () {
        final result = run(entry.value);
        expect(
          result.exitCode,
          2,
          reason:
              'the hook was given ${entry.key} and exited ${result.exitCode}. '
              'Exit 0 here means every commit is allowed through while the '
              'hook reports nothing, which is the state task 11.181 measured '
              'and misdiagnosed. Stdout: ${result.stdout}\n'
              'Stderr: ${result.stderr}',
        );
        expect(
          '${result.stderr}',
          contains('pre-commit suite:'),
          reason: 'a refusal that does not name itself is a refusal nobody can '
              'act on; the message is the whole point of exiting 2',
        );
      });
    }

    test('a readable payload that is not a commit is still silently allowed',
        () {
      // The control. Without it, a hook that refused *everything* would pass
      // every test above — two things failing the same way is not a
      // comparison.
      final result = run('{"tool_input":{"command":"ls -la"}}');
      expect(result.exitCode, 0,
          reason: 'a Bash call that is not a commit is none of this hook\'s '
              'business and must cost nothing. Stderr: ${result.stderr}');
      expect('${result.stdout}'.trim(), isEmpty,
          reason: 'the hook should say nothing at all about a non-commit');
    });
  });

  /// **A commit that names its paths takes the working tree, not the index —
  /// task 11.325 item 3.** `git commit -- <path>` is the form `CLAUDE.md`
  /// requires, and until 2026-10-02 the hook asked only what was *staged*, so an
  /// edit that was never staged was committed without the hook looking: a stale
  /// generated file went onto a throwaway branch with no refusal (task 11.318),
  /// and the hook went straight to `flutter test` with `build_runner` never
  /// started (task 11.325, watched by hand). `scripts/lib/commit_scope.py`
  /// answers "what will this command take", and these cases are that answer.
  ///
  /// **Each case runs in a throwaway git repository**, never this one: the
  /// answer depends on what is staged and what is not, and this working tree is
  /// shared with other windows and is never in a state a test can rely on.
  group('the pre-commit hook asks what a commit will take', () {
    late Directory repo;

    ProcessResult git(List<String> args) => Process.runSync(
          'git',
          ['-C', repo.path, ...args],
          environment: {
            'GIT_AUTHOR_NAME': 't',
            'GIT_AUTHOR_EMAIL': 't@example.com',
            'GIT_COMMITTER_NAME': 't',
            'GIT_COMMITTER_EMAIL': 't@example.com',
          },
        );

    void write(String path, String text) {
      final file = File('${repo.path}/$path');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    /// What the helper prints for [command], as a map; `worktree_generated`
    /// collects into a list because it can repeat.
    Map<String, Object> scope(String command) {
      final scriptPath = File('scripts/lib/commit_scope.py').absolute.path;
      final commandFile = File('${repo.path}/../command-${repo.hashCode}.txt')
        ..writeAsStringSync(command);
      try {
        final result = Process.runSync('bash', [
          '-c',
          'python3 "\$0" "\$1" < "\$2"',
          scriptPath,
          repo.path,
          commandFile.path,
        ]);
        expect(result.exitCode, 0,
            reason: 'commit_scope.py failed on "$command": ${result.stderr}');
        final out = <String, Object>{};
        for (final line in '${result.stdout}'.trim().split('\n')) {
          final at = line.indexOf('=');
          final key = line.substring(0, at);
          final value = line.substring(at + 1);
          if (key == 'worktree_generated') {
            (out.putIfAbsent(key, () => <String>[]) as List<String>).add(value);
          } else {
            out[key] = value;
          }
        }
        return out;
      } finally {
        commandFile.deleteSync();
      }
    }

    setUp(() {
      repo = Directory.systemTemp.createTempSync('tritrack-commit-scope-');
      git(['init', '-q', '-b', 'main']);
      write('lib/a.dart', 'void a() {}\n');
      write('lib/a.g.dart', '// generated\n');
      write('CLAUDE_DOCS/notes.md', 'notes\n');
      write('pubspec.yaml', 'name: t\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'baseline']);
    });

    tearDown(() => repo.deleteSync(recursive: true));

    test('a plain commit takes what is staged and nothing else', () {
      write('lib/a.dart', 'void a() { /* unstaged */ }\n');
      final result = scope('git commit -m x');
      expect(result['mode'], 'index');
      expect(result['generated_check'], 'no',
          reason: 'nothing under lib/ is staged, so a plain commit does not '
              'take lib/a.dart however modified it is on disk');
      expect(result['analyze'], 'no');
    });

    test('a commit that names a lib/ path takes its unstaged edit — the gap',
        () {
      write('lib/a.dart', 'void a() { /* unstaged */ }\n');
      final result = scope('git commit -m x -- lib/a.dart');
      expect(result['mode'], 'pathspec');
      expect(result['generated_check'], 'yes',
          reason: 'this is the case the hook missed: nothing is staged, the '
              'commit names lib/a.dart, so it takes an edit the index never '
              'showed. A "no" here is the stale generated file that went onto '
              'a branch unrefused.');
      expect(result['analyze'], 'yes');
    });

    test('naming only a Markdown file does not drag a lib/ edit in', () {
      write('lib/a.dart', 'void a() { /* somebody else, mid-thought */ }\n');
      write('CLAUDE_DOCS/notes.md', 'changed\n');
      final result = scope('git commit -m x -- CLAUDE_DOCS/notes.md');
      expect(result['generated_check'], 'no',
          reason: 'a pathspec commit ignores every other edit, and this tree '
              'is shared: refusing one window\'s Markdown commit over another '
              'window\'s half-written Dart is the false refusal that sends '
              'people to the escape hatch');
      expect(result['analyze'], 'no');
    });

    test('a staged lib/ file is still taken by a plain commit', () {
      write('lib/a.dart', 'void a() { /* staged */ }\n');
      git(['add', 'lib/a.dart']);
      final result = scope('git commit -m x');
      expect(result['generated_check'], 'yes');
      expect(result['analyze'], 'yes');
    });

    test('commit -a takes every tracked change, staged or not', () {
      write('lib/a.dart', 'void a() { /* unstaged */ }\n');
      expect(scope('git commit -am x')['generated_check'], 'yes');
      expect(scope('git commit --all -m x')['generated_check'], 'yes');
    });

    test('a named generated file is reported as read from the working tree',
        () {
      write('lib/a.g.dart', '// regenerated, never staged\n');
      final result = scope('git commit -m x -- lib/a.g.dart');
      expect(result['worktree_generated'], ['lib/a.g.dart'],
          reason: 'the index holds the old text and the disk holds what will '
              'be committed; the generated-files check must compare the '
              'second, or a correctly regenerated file reads as stale');
    });

    test('a double dash inside the message is not a pathspec', () {
      write('lib/a.dart', 'void a() { /* unstaged */ }\n');
      final result = scope("git commit -m 'fix -- lib/a.dart'");
      expect(result['mode'], 'index');
      expect(result['generated_check'], 'no');
    });

    test('a pathspec commit inside a chain and a heredoc message is found',
        () {
      write('lib/a.dart', 'void a() { /* unstaged */ }\n');
      const command = 'git add CLAUDE_DOCS/notes.md && git commit -m "\$(cat <<\'EOF\'\n'
          'Fix it -- really\n\nCo-Authored-By: x\nEOF\n)" -- lib/a.dart && git log -- CLAUDE_DOCS/';
      final result = scope(command);
      expect(result['mode'], 'pathspec');
      expect(result['generated_check'], 'yes');
    });

    test('a command it cannot read takes everything, never nothing', () {
      write('lib/a.dart', 'void a() { /* unstaged */ }\n');
      final result = scope("git commit -m 'unbalanced");
      expect(result['mode'], 'unparsed');
      expect(result['generated_check'], 'yes',
          reason: '"could not tell" must not read as "nothing to check" — the '
              'rule the payload reader above was fixed under');
    });

    test('analyze runs for a package file and not for prose', () {
      write('pubspec.yaml', 'name: t\nversion: 2\n');
      write('CLAUDE_DOCS/notes.md', 'changed\n');
      expect(scope('git commit -m x -- pubspec.yaml')['analyze'], 'yes');
      expect(scope('git commit -m x -- CLAUDE_DOCS/notes.md')['analyze'], 'no');
    });
  });
}

String _scriptPathIn(String command) {
  // Quoting is the caller's business — `"$CLAUDE_PROJECT_DIR"/scripts/x.sh`
  // and `"$CLAUDE_PROJECT_DIR/scripts/x.sh"` are the same path and this test
  // is not the place to have an opinion about which.
  final unquoted = command.replaceAll('"', '').replaceAll("'", '');
  final match = RegExp(r'\S*scripts/\S+').firstMatch(unquoted);
  expect(match, isNotNull,
      reason: 'this test only knows how to check hook commands that run a '
          'script under scripts/; "$command" is a shape it has not seen, and '
          'it must be taught rather than skipped');
  return match!.group(0)!.replaceAll(r'$CLAUDE_PROJECT_DIR/', '');
}

bool _isExecutable(String path) {
  final mode = FileStat.statSync(path).mode;
  return mode & 0x40 != 0; // owner execute
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.330 — **a check that finds its line can still report it missing.**
///
/// ## What went wrong, in one sentence
///
/// `docker logs "$CONTAINER" 2>&1 | grep -qi "starttls required"` printed
/// "the relay's log does not confirm STARTTLS was required" in a night whose
/// own printed log contained that line, and passed on the next five runs.
///
/// ## Why
///
/// `grep -q` stops at its first match and exits. If the program feeding it
/// writes anything afterwards, that write finds nobody reading and the program
/// is killed with SIGPIPE, exit status 141. Without `pipefail` a pipeline's
/// status is the last command's, which is grep's 0, so nothing shows. **With
/// `set -o pipefail` the pipeline's status is the first failure, so a *found*
/// line reads as a failed check.** Whether it happens depends on how much the
/// producer still has to write when grep leaves, which is why it comes and
/// goes: measured on the gate VM against a real four-line `docker logs`, 49
/// runs in 300 reported a line that was there as missing. Captured first
/// (`out="$(docker logs …)"; grep -q … <<<"$out"`), 0 in 300.
///
/// **A check that can read "found" as "missing" is a broken instrument: it
/// teaches everybody to re-run reds**, which is the habit this project spends
/// the most effort preventing.
///
/// ## What this guards
///
/// In every shell script that sets `pipefail`, a pipeline whose *last* stage
/// stops reading before its input ends: `grep` with `-q`, `-m` or `-l` (or
/// their long names), `head`, `sed` with a `q` command, `awk` with `exit`,
/// and `read`. Not every one is a live bug — a `printf` of a short variable
/// finishes writing before the reader looks — but **"short" is a property of
/// the data, not of the line**, and a variable that holds a command's output
/// is one long answer away from the same failure. So the rule is the shape,
/// and the fix is a shape that cannot misread:
///
///  - `grep -q X <<<"$value"` (no pipeline at all), or
///  - `… | grep X >/dev/null` / `grep -c` (reads everything, so the producer
///    is never cut off), or
///  - `… | sed -n '1p'` in place of `head -n1`.
///
/// **Not caught, and said so:** a consumer written in another language that
/// returns early (`python3 -c`, `jq -e`), a shell function that wraps
/// `grep -q`, and a pipeline built inside a string handed to another shell.
/// The first two need a different instrument; the third is only seen when the
/// string is in a script that itself sets `pipefail`, because this reads the
/// text, not the meaning.
///
/// **The corpus is asked of git** (`ls-files --cached --others
/// --exclude-standard`), not a hand-written list, so a script added tomorrow
/// is constrained today.
void main() {
  group('the matcher', () {
    // A broken control for each consumer. A guard whose matcher could not see
    // the shape it exists for would pass over the whole repository and say
    // nothing (defect vocabulary 34, 101).
    const mustFlag = <String, String>{
      'the one that failed in the night':
          'if docker logs "\$C" 2>&1 | grep -qi "starttls required"; then',
      'combined flags, q last': 'x | grep -iq foo',
      'combined flags, q first': 'x | grep -qE "a|b"',
      'combined flags, q in the middle': 'x | grep -Eqi foo',
      'long name': 'x | grep --quiet foo',
      'max count': 'URL="\$(printf "%s" "\$C" | grep -m1 http)"',
      'max count with a space': 'x | grep -m 1 http',
      'files-with-matches': 'x | grep -l foo',
      'head with a count': 'x | head -n 1',
      'head, short form': 'F="\$(ls -1 d | head -1)"',
      'sed that quits': "x | sed -n '1q'",
      'sed that quits on a match': "x | sed '/ready/q'",
      'awk that exits': "x | awk '{print; exit}'",
      'read': 'x | read -r first',
      'a pipe at the end of the line':
          'docker logs c 2>&1 |\n    grep -q ready',
      'a backslash continuation': 'docker logs c 2>&1 \\\n  | grep -q ready',
    };
    mustFlag.forEach((name, line) {
      test('flags: $name', () {
        expect(
          earlyExitPipelines('set -o pipefail\n$line\n'),
          isNotEmpty,
          reason: 'this line is the shape the guard exists for:\n$line',
        );
      });
    });

    // And the shapes that are the fix, or merely look similar. A matcher that
    // flagged these would make the fix impossible to land.
    const mustNotFlag = <String, String>{
      'here-string': 'grep -q "starttls required" <<<"\$out"',
      'grep to /dev/null': 'docker logs c 2>&1 | grep -i "starttls" >/dev/null',
      'grep -c': 'n="\$(x | grep -c foo)"',
      'grep -v': 'x | grep -v foo',
      'grep -E with an alternation in quotes': "x | grep -E 'a|b' >/dev/null",
      'an or-list, not a pipe': 'false || grep -q foo file',
      'grep -q on a file': 'grep -q foo "\$file"',
      'sed printing the first line': "x | sed -n '1p'",
      'sed substitution that mentions q': "x | sed 's/q/Q/'",
      'tail': 'x | tail -n 1',
      'awk that reads everything': "x | awk 'NR==1'",
      'a comment': '# x | grep -q foo',
      'cut': 'x | cut -d, -f1',
    };
    mustNotFlag.forEach((name, line) {
      test('does not flag: $name', () {
        expect(
          earlyExitPipelines('set -o pipefail\n$line\n'),
          isEmpty,
          reason: 'this line is not the hazardous shape:\n$line',
        );
      });
    });

    test('a heredoc body is not shell', () {
      const script =
          'set -o pipefail\npython3 - <<\'PY\'\nx = a | head\nPY\necho done\n';
      expect(earlyExitPipelines(script), isEmpty);
    });

    test('a script that does not set pipefail is out of scope', () {
      expect(setsPipefail('x | grep -q foo\n'), isFalse);
      expect(setsPipefail('set -euo pipefail\n'), isTrue);
      expect(setsPipefail('# set -o pipefail is why\n'), isFalse);
    });

    test('reports the line the pipeline starts on', () {
      final found = earlyExitPipelines('set -o pipefail\n\nfoo |\n  head -n1\n');
      expect(found.single.line, 3);
    });
  });

  group('the repository', () {
    test('the derivation found the scripts that set pipefail', () {
      final scripts = _shellScripts();
      final withPipefail = [
        for (final s in scripts)
          if (setsPipefail(s.source)) s.path,
      ];
      expect(
        withPipefail.length,
        greaterThan(20),
        reason:
            'only ${withPipefail.length} script(s) were found that set '
            'pipefail. At the time of writing there are over thirty, so a '
            'count this low means the listing or the pipefail test broke and '
            'every check below is passing over nothing.',
      );
    });

    test('no script that sets pipefail ends a pipeline on an early exit', () {
      final scripts = _shellScripts();
      final found = <String>[];
      for (final s in scripts) {
        if (!setsPipefail(s.source)) continue;
        for (final hit in earlyExitPipelines(s.source)) {
          found.add('  ${s.path}:${hit.line}: ${hit.text}');
        }
      }
      expect(
        found,
        isEmpty,
        reason:
            'These pipelines end in a command that stops reading early '
            '(grep -q / -m / -l, head, sed …q, awk …exit, read), in a script '
            'that sets pipefail. If the producer writes anything after the '
            'consumer leaves, it is killed by SIGPIPE and the pipeline '
            'reports FAILURE for a line that was FOUND, one run in a few. '
            'Task 11.330 measured 49 in 300 on a real `docker logs`.\n'
            'Fix the shape, not the line: `grep -q X <<<"\$value"`, or '
            '`… | grep X >/dev/null`, or `sed -n 1p` for `head -n1`.\n'
            '${found.join('\n')}',
      );
    });
  });
}

class _Script {
  _Script(this.path, this.source);
  final String path;
  final String source;
}

class EarlyExit {
  EarlyExit(this.line, this.text);

  /// 1-based line the pipeline starts on.
  final int line;
  final String text;
}

/// Every tracked-or-uncommitted shell script, and every workflow (whose `run:`
/// blocks are shell). Asked of git, so ignored build output is not read.
List<_Script> _shellScripts() {
  final listed = Process.runSync('git', [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
  ]);
  expect(
    listed.exitCode,
    0,
    reason:
        'git could not list the repository, so this check has no corpus: '
        '${listed.stderr}',
  );
  final out = <_Script>[];
  for (final path in (listed.stdout as String).split('\n')) {
    if (path.isEmpty) continue;
    if (path.startsWith('CLAUDE_DOCS/')) continue;
    final isShell = path.endsWith('.sh');
    final isWorkflow =
        path.startsWith('.github/workflows/') && path.endsWith('.yml');
    if (!isShell && !isWorkflow) continue;
    final file = File(path);
    if (!file.existsSync()) continue;
    out.add(_Script(path, file.readAsStringSync()));
  }
  return out;
}

/// Whether a script's *code* (not a comment) turns `pipefail` on.
bool setsPipefail(String source) {
  for (final line in source.split('\n')) {
    final t = line.trimLeft();
    if (t.startsWith('#')) continue;
    if (RegExp(r'\bpipefail\b').hasMatch(t) &&
        RegExp(r'\b(set|bash|sh)\b').hasMatch(t)) {
      return true;
    }
  }
  return false;
}

/// The pipelines in [source] whose last stage can stop reading early.
List<EarlyExit> earlyExitPipelines(String source) {
  final lines = source.split('\n');
  final out = <EarlyExit>[];

  // Logical lines: comments and heredoc bodies dropped, `\` and trailing-`|`
  // continuations joined, remembering the line each began on.
  final logical = <(int, String)>[];
  String? heredocEnd;
  var i = 0;
  while (i < lines.length) {
    final start = i + 1;
    var text = lines[i];
    i++;
    if (heredocEnd != null) {
      if (text.trim() == heredocEnd) heredocEnd = null;
      continue;
    }
    if (text.trimLeft().startsWith('#')) continue;
    while (i < lines.length &&
        (RegExp(r'\\\s*$').hasMatch(text) ||
            RegExp(r'(?<!\|)\|\s*$').hasMatch(text) ||
            lines[i].trimLeft().startsWith('|') &&
                !lines[i].trimLeft().startsWith('||'))) {
      text = '${text.replaceFirst(RegExp(r'\\\s*$'), ' ')} ${lines[i].trim()}';
      i++;
    }
    final heredoc = RegExp(r'<<-?\s*[\x27"]?([A-Za-z_][A-Za-z0-9_]*)[\x27"]?')
        .firstMatch(text);
    if (heredoc != null) heredocEnd = heredoc.group(1);
    logical.add((start, text));
  }

  for (final (lineNo, text) in logical) {
    // A `|` that is a pipe: not `||`, not `\|` inside a pattern.
    final pipes = RegExp(r'(?<![|\\])\|(?!\|)').allMatches(text).toList();
    for (final p in pipes) {
      final stage = _stageFrom(text, p.end);
      if (_stopsEarly(stage.trim())) {
        out.add(EarlyExit(lineNo, text.trim()));
        break;
      }
    }
  }
  return out;
}

/// The text of the pipeline stage that starts at [from]: up to the next pipe,
/// `;`, `&&` or closing `)` that is not inside quotes, so the `;` in
/// `awk '{print; exit}'` does not end the stage.
String _stageFrom(String text, int from) {
  var single = false;
  var double = false;
  for (var k = from; k < text.length; k++) {
    final c = text[k];
    if (c == '\\' && !single) {
      k++;
      continue;
    }
    if (c == "'" && !double) single = !single;
    if (c == '"' && !single) double = !double;
    if (single || double) continue;
    if (c == '|' || c == ';' || c == ')') return text.substring(from, k);
    if (c == '&' && k + 1 < text.length && text[k + 1] == '&') {
      return text.substring(from, k);
    }
  }
  return text.substring(from);
}

bool _stopsEarly(String stage) {
  final words = stage.split(RegExp(r'\s+'));
  if (words.isEmpty) return false;
  final command = words.first;

  if (command == 'head' || command == 'read') return true;

  if (command == 'grep' || command == 'egrep' || command == 'fgrep') {
    // Options come before the pattern. Skip the argument of the options that
    // take one, so `-e 'q'` is read as a pattern, not as `-q`.
    var j = 1;
    while (j < words.length && words[j].startsWith('-')) {
      final w = words[j];
      if (w == '--') break;
      if (w.startsWith('--')) {
        if (const {'--quiet', '--silent', '--files-with-matches'}
                .contains(w) ||
            w.startsWith('--max-count')) {
          return true;
        }
      } else {
        final cluster = w.substring(1);
        if (cluster.contains(RegExp('[qml]'))) return true;
        if (RegExp('[efABC]\$').hasMatch(cluster)) j++; // takes an argument
      }
      j++;
    }
    return false;
  }

  if (command == 'sed') {
    // A `q` command: `1q`, `$q`, `/re/q`, or a lone `q`, at the end of the
    // script or before a `;` or `}`. `s/q/Q/` does not match because the
    // `q` there is followed by `/`.
    return RegExp(r'''(?:^|[\x27" ;{}\d$/])q\s*(?:[\x27";}]|$)''')
        .hasMatch(stage);
  }

  if (command == 'awk' || command == 'gawk' || command == 'mawk') {
    return RegExp(r'\bexit\b').hasMatch(stage);
  }

  return false;
}

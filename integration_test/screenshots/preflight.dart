// **Does this harness assemble the app's environment from the app's own
// configuration?** (`/w-10` item 0, from task 11.142.)
//
// ## The defect this exists to stop happening again
//
// `harness.dart` builds a `ProviderContainer` and pumps `TriTrackApp` into it.
// A container built with no `retry:` silently runs Riverpod's default retry
// policy — **ten attempts over 38.2 seconds**. `main.dart` runs
// `appRetryPolicy`, which is three attempts and under two seconds.
//
// That difference published a wrong picture. On a device with no server the
// project Members screen's two server-backed sections fail immediately with
// `not_configured`; under the app's policy their explanation renders in about
// 1.6 seconds. Under Riverpod's default they spin for twenty. `/w-11` saw the
// twenty seconds, concluded that *"their providers never resolve"*, wrote that
// into a readiness comment, filed it as an app defect — and
// `project-members.png` was published showing a state a person on a phone
// never sees for more than a couple of seconds. **Task 11.142 went looking for
// the two spinners and found the harness.**
//
// The general form, which is why this is a check rather than a fixed line:
// **a harness that assembles the app's environment itself is measuring a
// different app unless it assembles it from the app's configuration**, and
// everything it observes before that is evidence about the harness.
//
// ## Why it is here rather than in `test/`
//
// `test/documentation/retry_policy_applied_test.dart` asks the same question
// of `lib/` and cannot see this harness: it scans for `ProviderScope(`, which
// is not what a harness builds. Widening it into `integration_test/` would put
// a **content-lane** file into the **code lane's** red, which is task 11.118's
// lesson — a guard that fails on a file its owner is not looking at fails in
// the wrong window.
//
// **And it is a script rather than a test, which is a constraint and not a
// preference.** `flutter test` refuses a file under `integration_test/`: it
// treats the directory as needing a device, and asks for `-d`. So this follows
// `review.dart` — plain Dart, run by `regenerate.sh` before every capture,
// with the same exit-code contract:
//
//   0  the harness matches the app
//   1  it does not, and the run should not start
//   2  the check could not run at all — **not a pass**
//
// Usage:
//   dart run integration_test/screenshots/preflight.dart

import 'dart:io';

/// The app's own policy, by name. Containment of `retry:` alone would be
/// satisfied by `retry: (c, e) => null` — a policy, and not the app's.
const String appPolicy = 'appRetryPolicy';

// **`exit()`, not a returned `int`.** Dart ignores a value returned from
// `main`, so an earlier draft of this file printed all three failure lines and
// exited 0 — a check that could report a finding and could not fail, which is
// the exact shape this directory keeps deleting. Watched red before and after
// the fix.
void main() => exit(_run());

int _run() {
  final directory = Directory('integration_test/screenshots');
  if (!directory.existsSync()) {
    stderr.writeln('preflight: no integration_test/screenshots directory. '
        'Run this from the repository root.');
    return 2;
  }

  final files = directory
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    stderr.writeln('preflight: no Dart files under '
        'integration_test/screenshots, so this check has nothing to read and '
        'is reporting that rather than a pass.');
    return 2;
  }

  final offences = <String>[];
  for (final file in files) {
    if (file.path.endsWith('preflight.dart')) continue;
    final source = _withoutComments(file.readAsStringSync());
    for (final match in RegExp(r'ProviderContainer\(').allMatches(source)) {
      final end =
          match.end + 400 > source.length ? source.length : match.end + 400;
      final tail = source.substring(match.end, end);
      final call = tail.contains(');') ? tail.split(');').first : tail;
      if (call.contains('retry:')) continue;
      final line = '\n'.allMatches(source.substring(0, match.start)).length + 1;
      offences.add('${file.path}:$line');
    }
  }

  final harness = File('integration_test/screenshots/harness.dart');
  if (!harness.existsSync()) {
    stderr.writeln('preflight: harness.dart is gone, so the check that it '
        'builds its container with the app\'s policy cannot be made.');
    return 2;
  }
  final harnessSource = _withoutComments(harness.readAsStringSync());
  final usesAppPolicy = harnessSource.contains('retry: $appPolicy');

  if (offences.isEmpty && usesAppPolicy) {
    // **The last thing an instrument says is what it found**, not its own
    // name — `CLAUDE.md`'s rule about five-line tails.
    stdout.writeln('preflight: ${files.length} harness file(s) read; every '
        'ProviderContainer sets a retry policy, and harness.dart uses the '
        'app\'s own $appPolicy.');
    return 0;
  }

  for (final offence in offences) {
    stderr.writeln('preflight: $offence builds a ProviderContainer with no '
        '`retry:`, so it runs Riverpod\'s default of ten attempts over 38.2 '
        'seconds where the app gives up in under two. Every screen waited on '
        'by that container is being waited on by a rule the app does not '
        'have.');
  }
  if (!usesAppPolicy) {
    stderr.writeln('preflight: harness.dart does not pass `retry: $appPolicy`. '
        'A different policy is allowed, but it has to be argued for by '
        'changing this check rather than by editing one line of the harness.');
  }
  stderr.writeln('preflight: the capture run has not started. Fix the above '
      'first — pictures taken now would be of states nobody on a phone sees.');
  return 1;
}

/// [source] with `//` comments blanked, so a rule quoted in prose is not read
/// as code. Line comments only: this directory's files carry long doc comments
/// and no block comments, and a half-implemented block-comment stripper would
/// be worse than none.
String _withoutComments(String source) => source
    .split('\n')
    .map((line) {
      final index = line.indexOf('//');
      if (index < 0) return line;
      // Not inside a string literal: a `//` after an odd number of quotes is
      // part of a URL or a path, not a comment.
      final before = line.substring(0, index);
      final quotes = "'".allMatches(before).length;
      if (quotes.isOdd) return line;
      return before;
    })
    .join('\n');

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **Task 11.107 — the policy has to actually be installed.**
///
/// `appRetryPolicy` bounds every awaited provider in the app to under two
/// seconds of backoff before a failure can be reported. It does that only where
/// it is passed to a `ProviderScope`. A `ProviderScope` written without
/// `retry:` silently falls back to Riverpod's default — ten attempts, 38.2
/// seconds — and nothing about that code looks wrong, which is the same
/// property that let the two defects in task 11.66 sit unnoticed.
///
/// So: every `ProviderScope` in `lib/` must name a retry policy. This is one
/// scope today (`main.dart`); the check exists for the second one.
///
/// **What it does not catch.** It is textual, and it says nothing about
/// `ProviderContainer`s built in tests — `test/support/app_boot_helper.dart`
/// passes the policy so a full-app widget test measures what ships, but a test
/// that builds its own bare container is measuring Riverpod's default, and that
/// is often exactly what a test wants.
void main() {
  test('every ProviderScope in lib/ sets an explicit retry policy', () {
    final offences = <String>[];

    for (final file in dartFilesUnder('lib')) {
      final source = stripComments(file.readAsStringSync());
      for (final match in RegExp(r'ProviderScope\(').allMatches(source)) {
        // The constructor call, up to the end of its argument list. Scopes in
        // this app are written in one call; a nested-paren walk is more
        // machinery than the one site justifies.
        final tail = source.substring(match.end, match.end + 400 > source.length
            ? source.length
            : match.end + 400);
        final call = tail.contains(');') ? tail.split(');').first : tail;
        if (call.contains('retry:')) continue;
        final line =
            '\n'.allMatches(source.substring(0, match.start)).length + 1;
        offences.add('${file.path}:$line');
      }
    }

    expect(
      offences,
      isEmpty,
      reason:
          'A ProviderScope with no `retry:` runs Riverpod\'s default of ten '
          'attempts and 38.2 seconds of silence before any failure on any '
          'screen can be reported. Pass `appRetryPolicy` from '
          'lib/core/providers/retry_policy.dart, or, if this scope genuinely '
          'needs different behaviour, say so in the argument rather than '
          'omitting it.',
    );
  });
}

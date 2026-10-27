import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.236 — **the four providers task 11.235's fix shape was copied
/// into: [heldRowRetryProvider], and the three read bare that sat one
/// `await` away from the same failure.**
///
/// `test/core/providers/no_ref_after_await_in_owner_repair_test.dart` reads
/// `app_context_provider.dart` for the same reason and is the pattern this
/// copies: a shape is one edit from being undone, so this reads the source
/// rather than trusting a comment to survive the next change.
void main() {
  /// The text of one top-level (or class-body) function or method, from its
  /// signature line to the matching closing brace, with comment-only lines
  /// stripped first (task 11.173's rule: a splitter that does not know what
  /// a comment is attaches a preamble to the wrong element, and a `ref.` in a
  /// doc comment is exactly that trap here).
  String functionBody(
    String path,
    String signaturePattern, {
    int occurrence = 0,
  }) {
    final source = File(path).readAsStringSync();
    final stripped = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    final matches = RegExp(
      signaturePattern,
      multiLine: true,
    ).allMatches(stripped).toList();
    expect(
      matches.length,
      greaterThan(occurrence),
      reason: 'no match ($occurrence-th of pattern "$signaturePattern") in '
          '$path — the function this check reads may have moved or been '
          'renamed; move the check with it rather than deleting it',
    );
    final start = matches[occurrence].start;
    // The pattern always ends at the parameter list's opening `(` — found by
    // its own match, not by `stripped.indexOf`, because a record return type
    // (`({int waiting, ...})`) has `{`/`}` of its own *before* the parameter
    // list, and the naive "first `{` after start" this used to do closed on
    // the return type's brace rather than the function body's.
    final paramsOpen = matches[occurrence].end - 1;
    var parenDepth = 0;
    var paramsClose = -1;
    for (var i = paramsOpen; i < stripped.length; i++) {
      final c = stripped[i];
      if (c == '(') parenDepth++;
      if (c == ')') {
        parenDepth--;
        if (parenDepth == 0) {
          paramsClose = i;
          break;
        }
      }
    }
    expect(paramsClose, greaterThan(-1), reason: '$path: unbalanced parens');
    final open = stripped.indexOf('{', paramsClose);
    var depth = 0;
    for (var i = open; i < stripped.length; i++) {
      final c = stripped[i];
      if (c == '{') depth++;
      if (c == '}') depth--;
      if (depth == 0) return stripped.substring(start, i + 1);
    }
    fail('$path: unbalanced braces from $signaturePattern');
  }

  /// Every `ref.watch(`/`ref.read(` call in [body] happens before its first
  /// `await` — the shape [_ensureOwnerMembership] (task 11.235) and
  /// [heldRowRetry] (task 11.236) were both broken without.
  void expectNoRefTouchAfterFirstAwait(String body, String label) {
    final firstAwait = body.indexOf('await ');
    final calls = [
      ...'ref.watch('.allMatches(body),
      ...'ref.read('.allMatches(body),
      ...'ref.invalidate('.allMatches(body),
    ];
    expect(
      calls,
      isNotEmpty,
      reason: '$label: no ref.watch/ref.read/ref.invalidate found at all — '
          'this check would pass vacuously if the body no longer calls '
          '`ref` the way it did when this test was written',
    );
    if (firstAwait == -1) return; // nothing awaited, so nothing can race it
    for (final call in calls) {
      expect(
        call.start,
        lessThan(firstAwait),
        reason: '$label: a ref call at offset ${call.start} sits after the '
            'first `await` (at $firstAwait) — an auto-disposing provider '
            'read bare, with no listener, may already be disposed by then '
            '(tasks 11.235, 11.236)',
      );
    }
  }

  test('heldRowRetry issues every ref call before its first await', () {
    final body = functionBody(
      'lib/core/providers/sync_held_rows_provider.dart',
      r'^HeldRowRetry heldRowRetry\(',
    );
    expectNoRefTouchAfterFirstAwait(body, 'heldRowRetry');
  });

  test(
    'strandedRecordCount issues every ref.watch before its first await',
    () {
      final body = functionBody(
        'lib/core/providers/membership_provider.dart',
        r'^Future<\(\{[^\n]*\}\)> strandedRecordCount\(',
      );
      expectNoRefTouchAfterFirstAwait(body, 'strandedRecordCount');
    },
  );

  test('serverHttpClient issues every ref.watch before its first await', () {
    final body = functionBody(
      'lib/core/providers/server_http_client_provider.dart',
      r'^Future<http\.Client\?> serverHttpClient\(',
    );
    expectNoRefTouchAfterFirstAwait(body, 'serverHttpClient');
  });

  test(
    'myProjectStanding (mayWriteProjectData\'s dependency) issues every ref '
    'call before its first await',
    () {
      final body = functionBody(
        'lib/core/providers/app_context_provider.dart',
        r'^Future<ProjectStanding> myProjectStanding\(',
      );
      expectNoRefTouchAfterFirstAwait(body, 'myProjectStanding');
    },
  );
}

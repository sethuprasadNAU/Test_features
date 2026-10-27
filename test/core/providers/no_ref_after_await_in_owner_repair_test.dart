import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 11.235 — **the owner-membership repair takes no `Ref`, and the three
/// providers that call it issue every `ref.watch` before their first `await`.**
///
/// The + button on the tag database did nothing on Michael's phone because
/// `_ensureOwnerMembership` did `ref.watch` after an `await`, inside a loop,
/// from an auto-disposing provider that a bare `ref.read(...future)` had
/// already let go of. The fix is a shape — no `Ref` reaches the repair, and
/// the callers register their dependencies while the `Ref` is certainly
/// alive — and a shape is one edit from being undone. This reads the source
/// and refuses that edit.
///
/// **Measured, not assumed (probe run 2026-09-12):** in a Flutter
/// `ProviderContainer`, an auto-disposing provider read with no listener is
/// disposed one microtask after the read returns. A `ref.*` after **one**
/// `await` of an already-resolved future still ran; after **two** it threw,
/// and after any real gap (a timer, a database call) it threw. So "before
/// the first `await`" is the only position this check can defend without
/// counting hops.
void main() {
  final source =
      File('lib/core/providers/app_context_provider.dart').readAsStringSync();

  /// The text of one top-level function, from its signature line to the
  /// matching closing brace. Comments are stripped first so a `ref.` in a
  /// doc comment is not read as a call (the rule task 11.173 established for
  /// every splitter in this repository).
  String functionBody(String name) {
    final stripped = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');
    final sig = RegExp('^Future<[^\\n]*>\\s+$name\\(', multiLine: true);
    final match = sig.firstMatch(stripped);
    expect(match, isNotNull, reason: '$name is no longer declared in the file '
        'this check reads — move the check with it rather than deleting it');
    final start = match!.start;
    final open = stripped.indexOf('{', start);
    var depth = 0;
    for (var i = open; i < stripped.length; i++) {
      final c = stripped[i];
      if (c == '{') depth++;
      if (c == '}') depth--;
      if (depth == 0) return stripped.substring(start, i + 1);
    }
    fail('$name: unbalanced braces');
  }

  test('_ensureOwnerMembership takes no Ref and uses none', () {
    final body = functionBody('_ensureOwnerMembership');
    final params = body.substring(0, body.indexOf(')') + 1);
    expect(params, isNot(contains('Ref ')),
        reason: 'the repair must run on values resolved by its caller, so '
            'that disposing the caller cannot interrupt it half-way');
    expect(body, isNot(contains('ref.')),
        reason: 'a `ref.` inside the repair is the exact line that broke the '
            '+ button (task 11.235)');
  });

  for (final provider in ['projectById', 'allProjects']) {
    test('$provider issues every ref.watch before its first await on the '
        'database', () {
      final body = functionBody(provider);
      // The one sanctioned way to reach the repair: resolve its inputs first.
      expect(body, contains('_ownerRepairInputs(ref)'),
          reason: '$provider must gather the repair\'s inputs before any '
              'await, through the shared helper, or the shape this test '
              'guards has been reintroduced by hand');
      final firstAwait = body.indexOf('await ');
      final helperCall = body.indexOf('_ownerRepairInputs(ref)');
      expect(firstAwait, greaterThan(-1));
      expect(helperCall, lessThan(firstAwait),
          reason: '$provider calls _ownerRepairInputs after an await — an '
              'auto-disposing provider may already be dead by then');
      final repairCall = body.indexOf('_ensureOwnerMembership(');
      expect(repairCall, greaterThan(-1));
      expect(body.substring(repairCall), isNot(contains('ref.')),
          reason: '$provider touches its Ref after the repair has started');
    });
  }

  test('currentProject fetches the repair inputs after its awaits, and is '
      'keepAlive — the annotation is what makes that order legal', () {
    // It must not open the database when there is no active project (screen
    // tests pumping without one rely on that), so it cannot issue the
    // repair's watches up front. The order is safe only because nothing
    // disposes a keep-alive provider mid-build: the exception is a coupling
    // to the annotation, not a licence, and this reads the annotation.
    final body = functionBody('currentProject');
    expect(body, contains('_ownerRepairInputs(ref)'));
    final declaration = source.indexOf('Future<Project?> currentProject(');
    final preceding = source.substring(0, declaration).trimRight();
    expect(preceding, endsWith('@Riverpod(keepAlive: true)'),
        reason: 'currentProject watches after awaits; without keepAlive a '
            'bare read of it would fail the way allProjects did (11.235)');
    final repairCall = body.indexOf('_ensureOwnerMembership(');
    expect(body.substring(repairCall), isNot(contains('ref.')));
  });

  test('_ownerRepairInputs issues both watches before it awaits either', () {
    final body = functionBody('_ownerRepairInputs');
    final firstAwait = body.indexOf('await ');
    final watches = 'ref.watch('.allMatches(body).toList();
    expect(watches.length, 2, reason: 'two inputs, two watches');
    for (final w in watches) {
      expect(w.start, lessThan(firstAwait),
          reason: 'a ref.watch after an await in this helper is the defect '
              'the helper exists to remove');
    }
  });
}

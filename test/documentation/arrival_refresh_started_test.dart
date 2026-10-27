import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/dart_source.dart';

/// **A `keepAlive` provider nobody reads is never built at all.**
///
/// `ArrivalRefresh` (task 11.153) is what makes a membership change, a tag link
/// or a project rename that arrived from somebody else's device show up without
/// the app being restarted. It works by subscribing to `DataArrival` in its own
/// `build`, so **it does nothing whatsoever until something reads it once** —
/// and the screens it refreshes are exactly the ones with no reason to.
///
/// One line in `lib/app.dart` does that read. Delete it and every test in
/// `arrival_refresh_test.dart` still passes, because those construct the
/// provider themselves; the only thing that changes is the shipped app, where
/// the feature is silently absent. **That is the gap this file exists for**, and
/// it is the same shape as a detection proof whose patch target got refactored
/// away (CLAUDE.md, tasks 11.125 and 11.128): a coupling nothing fails on.
///
/// It reads for the literal call. **A refactor that moves the read into a
/// helper will fail this**, which is the safe direction — somebody is then
/// looking at this comment rather than at a feature that quietly stopped
/// existing.
void main() {
  test('lib/app.dart starts the arrival refresher on launch', () {
    final source = stripComments(File('lib/app.dart').readAsStringSync());

    expect(
      source,
      contains("import 'core/providers/arrival_refresh.dart';"),
      reason:
          'lib/app.dart no longer imports the arrival refresher, so it cannot '
          'be starting it. Nothing else in the app reads it, so a membership '
          'change or a tag link arriving by sync is invisible until the app is '
          'restarted — which is exactly the defect task 11.153 closed, with no '
          'other test able to notice it had come back.',
    );
    expect(
      source,
      contains('ref.read(arrivalRefreshProvider)'),
      reason:
          'lib/app.dart no longer reads arrivalRefreshProvider. It is a '
          'keepAlive provider, which means it is never built until something '
          'reads it, which means DataArrival is announcing to nobody. Restore '
          'the read in initState, or — if the read has deliberately moved '
          'somewhere else — point this check at wherever it now lives.',
    );
    expect(
      source.indexOf('ref.read(arrivalRefreshProvider)'),
      lessThan(source.indexOf('_syncOnForeground()')),
      reason:
          'The refresher is started after the launch sync is kicked off, so a '
          'round that finishes first announces to nobody and the first pull '
          'after a cold start is the one that goes unseen.',
    );
  });
}

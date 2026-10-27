import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';

import '../../support/fake_shared_preferences.dart';

/// Task 11.236, item 3 — **the harness boundary that cost task 11.235 twenty
/// minutes, given a name and a short deadline instead of a comment nobody
/// reads.**
///
/// Most of this project's widget tests "pump a screen bare" — no active
/// project set, no `appDatabaseProvider` override — and that is only safe
/// because [currentProjectProvider] returns `null` **without ever opening the
/// database** when there is no active project id (see its own doc comment in
/// `app_context_provider.dart`). Nothing checked that before this file: task
/// 11.235's first attempt at a fix broke it, and one test file hung for ten
/// minutes per test rather than failing, because `testWidgets` pins its own
/// timeout that `flutter test --timeout` cannot override.
///
/// **This is a plain `test`, not a `testWidgets`, on purpose.** A
/// `testWidgets` runs under a fake clock nothing here would advance if the
/// boundary broke, so `.timeout()` below would never get a chance to fire —
/// which is exactly how the ten-minute hang happened in the first place. A
/// plain `test` runs on the real event loop, where a real timeout works.
void main() {
  setUp(installFakeSharedPreferences);

  test(
    'currentProjectProvider resolves with no active project set, without '
    'ever needing the database',
    () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      // Deliberately not set: this is the state every widget test that pumps
      // a screen bare starts in. No `appDatabaseProvider` override and no
      // faked `path_provider` either — if this provider ever opens the real
      // database on this path, resolving it needs a plugin channel nothing
      // here answers, and the await below never completes on its own.
      final result = await container
          .read(currentProjectProvider.future)
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => throw TestFailure(
              'currentProjectProvider did not resolve within 5 seconds with '
              'no active project set. That is the boundary most of this '
              "project's widget tests depend on without saying so: with no "
              'active project, this provider must return null without '
              'touching the database at all. A widget test that crosses '
              'this boundary does not fail the way this one just would — it '
              'hangs for ten minutes under `testWidgets`\' own timeout, '
              'which `flutter test --timeout` cannot override (task '
              '11.236). If this genuinely needs to open the database now, '
              'say so in the provider\'s own doc comment and fix the widget '
              'tests that assumed otherwise.',
            ),
          );

      expect(result, isNull);
    },
  );
}

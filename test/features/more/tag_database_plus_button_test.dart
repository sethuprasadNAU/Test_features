import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/retry_policy.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/more/screens/tag_database_screen.dart';
import 'package:tritrack/widgets/tag_form.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/tag_library_priming.dart';

/// Task 11.235 — **the + button on the tag database did nothing, on a device
/// that holds a project.**
///
/// The device log named the mechanism: `allProjectsProvider` is
/// auto-disposing, its body calls `_ensureOwnerMembership` once per project,
/// and that helper `ref.watch`ed **after** an `await`. The screen reaches it
/// through `ref.read(allProjectsProvider.future)` — a read with no listener
/// behind it — so the provider is disposed while its body is still running,
/// the next `ref.watch` throws `Cannot use the Ref of allProjectsProvider
/// after it has been disposed`, and the future the dialog was waiting on
/// never delivers a dialog.
///
/// **Why the file next door never saw it:** `tag_database_screen_test.dart`
/// pre-resolves `allProjectsProvider` with **no projects in the database**, so
/// the loop that does the `ref.watch` never runs; and the one group there that
/// does seed projects holds `container.listen(allProjectsProvider, …)` for the
/// test's lifetime — a workaround its own comment describes — which is exactly
/// the subscription the app's screen does not have. This test goes through
/// the screen's own path, with a project present and nothing else holding the
/// provider alive, which is the phone's situation.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    EditableText.debugDeterministicCursor = true;
  });
  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  /// A device with [projects] projects on it and an empty tag library. The
  /// container is built from the app's own retry policy (task 11.142's rule:
  /// a harness that takes Riverpod's default is measuring a different app).
  /// **Nothing here reads `allProjectsProvider`** — the screen's tap is the
  /// first thing that does, as on the phone.
  Future<ProviderContainer> deviceWithProjects(
    WidgetTester tester, {
    required int projects,
  }) async {
    final container = ProviderContainer(
      retry: appRetryPolicy,
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final user = await container.read(currentUserProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      for (var i = 0; i < projects; i++) {
        // No membership row: this is the shape `_ensureOwnerMembership`
        // exists to repair, so its write path runs rather than short-circuits.
        await projectRepo.insert(
          sampleProject(id: 'p$i', ownerUserId: user.userId),
        );
      }
      await primeTagLibrary(container);
    });
    return container;
  }

  /// Pumped inside the tab shell at phone geometry — the screen lives on the
  /// More tab in the app, and the assertions here rest on a button being
  /// tappable and a dialog or snackbar being visible.
  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) =>
      pumpInAppShell(
        tester,
        container: container,
        screen: const TagDatabaseScreen(),
        tabIndex: 4, // Map / Record / Compass / Position / **More**
      );

  /// Taps + and gives the real database chain behind it time to finish. The
  /// delay is real wall-clock inside `runAsync`, as every FAB-tap test in
  /// `tag_database_screen_test.dart` does it.
  Future<void> tapPlus(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byType(FloatingActionButton));
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();
    });
  }

  testWidgets(
    'a tap that cannot open the form says so, rather than doing nothing',
    (tester) async {
      // The provider is fixed above; this stands in for whatever breaks that
      // path next. The failure is deliberately one `describeFailure` cannot
      // explain, so the screen's own fallback sentence is what must appear.
      final container = ProviderContainer(
        retry: appRetryPolicy,
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          allProjectsProvider.overrideWith(
            (ref) async => throw StateError('the projects list broke'),
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        await primeTagLibrary(container);
      });
      await pumpScreen(tester, container);

      await tapPlus(tester);

      expect(find.byType(TagEditDialog), findsNothing);
      expect(
        find.text(kTagFormCouldNotOpenMessage),
        findsOneWidget,
        reason: 'for ten days the button failed with no message at all; a '
            'person who taps and gets nothing has nothing to report',
      );
      expect(
        find.textContaining('StateError'),
        findsNothing,
        reason: 'the sentence is written for a person, not pasted from the '
            'exception (task 11.105\'s rule)',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final count in [1, 3]) {
    testWidgets(
      'tapping + opens the tag form on a device with $count project(s)',
      (tester) async {
        final container = await deviceWithProjects(tester, projects: count);
        await pumpScreen(tester, container);

        await tapPlus(tester);

        expect(
          tester.takeException(),
          isNull,
          reason: 'the phone logged "Cannot use the Ref of allProjectsProvider '
              'after it has been disposed" on every tap',
        );
        expect(
          find.byType(TagEditDialog),
          findsOneWidget,
          reason: 'Michael tapped + and nothing happened — the dialog is the '
              'whole point of the button',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}

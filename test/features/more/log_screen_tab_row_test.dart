import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/more/screens/log_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/text_scale_probe.dart' show iosTextScales, textScaleName;

/// Task 11.168 — `log_screen.dart`'s `TabBar` (`Tab(text: 'Log', ...)` /
/// `Tab(text: 'Team', ...)`) used the framework's default icon+text tab
/// height, a fixed 72.0 logical pixels that does not grow with the ambient
/// text scale. Task 11.167 found it overflowing that fixed box by about a
/// pixel at AX3 (2.35x) and more from there, while deliberately leaving it
/// alone (`log_screen_sort_filter_label_test.dart` silences overflow from
/// this row so it cannot mask a regression in the row that task's fix
/// covers). This is that row's own guard.
///
/// The fix measures the tab's own icon + label at the ambient scale and
/// gives `Tab.height`/the `TabBar`'s `PreferredSize` exactly that — the same
/// "does this box need to be fixed at all" answer task 11.164 gave a pinned
/// bar, applied here because a `Tab` has no second line to wrap into the way
/// task 11.167's sort/filter labels did.
void main() {
  setUp(installFakeSharedPreferences);

  Future<ProviderContainer> pumpAtScale(
    WidgetTester tester, {
    required double textScale,
  }) async {
    final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
    final bob = sampleUser(id: 'user-bob', email: 'bob@example.com');

    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith((ref) async => bob),
        currentProjectProvider.overrideWith((ref) async => project),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(Tables.users, bob.toColumns());
      await db.insert(Tables.projects, project.toColumns());
      await container.read(historyDataProvider(project.projectId).future);
      container.listen(mayWriteProjectDataProvider(project.projectId), (_, _) {});
      await container.read(mayWriteProjectDataProvider(project.projectId).future);
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const LogScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
      textScale: textScale,
    );
    return container;
  }

  for (final scale in iosTextScales) {
    testWidgets('the tab row holds at ${textScaleName(scale)}', (tester) async {
      await pumpAtScale(tester, textScale: scale);

      expect(tester.takeException(), isNull,
          reason: 'the tab row overflowed at ${textScaleName(scale)}');
    });
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart' show CompassEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/more/screens/pretrip_checklist_screen.dart';

import '../../data/fixtures.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 7.5 acceptance criterion: the checklist's "Identity configured" row
/// reflects real state — green only when identity is genuinely set, not a
/// placeholder.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    required String email,
    String? server,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        // No real platform implementation under test — see the identical
        // reasoning in observation_logging_screen_test.dart's readyContainer.
        compassHeadingProvider.overrideWith((ref) => const Stream<CompassEvent>.empty()),
        accelerometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        magnetometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);

      await userRepo.insert(sampleUser(id: 'user-1', email: email));
      await projectRepo.insert(sampleProject());
      await tagRepo.insert(sampleTag());
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(activeProjectIdProvider.notifier).set('project-1');
      if (server != null) {
        await container.read(serverConfigProvider.notifier).setUrl(server);
      }

      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});

      await container.read(currentUserProvider.future);
      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
    });

    return container;
  }

  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: PreTripChecklistScreen()),
      ),
    );
    // Bounded pumps rather than pumpAndSettle: the map-tile/DEM
    // FutureBuilders and the compass controller can leave the pump loop
    // wanting more frames than pumpAndSettle tolerates.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('shows a green identity row with name and email for a real identity', (tester) async {
    final container = await readyContainer(tester, email: 'sam@example.com');
    await pumpScreen(tester, container);

    expect(find.text('Identity configured'), findsOneWidget);
    expect(find.text('Sam Ranger · sam@example.com'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsWidgets);
  });

  testWidgets('shows a not-ok identity row for a placeholder user', (tester) async {
    final container = await readyContainer(tester, email: 'field-user-abc@local.tritrack');
    await pumpScreen(tester, container);

    expect(find.text('Identity configured'), findsOneWidget);
    expect(find.textContaining('Not set'), findsOneWidget);

    final identityCard = find.ancestor(of: find.text('Identity configured'), matching: find.byType(Card));
    expect(find.descendant(of: identityCard, matching: find.byIcon(Icons.error_outline)), findsOneWidget);
  });

  /// Task 11.324, item 1: *Later* on "Finish setting up" leaves publishing and
  /// the area's offline maps here, so these two rows have to check them.
  testWidgets('WATCHED RED: the project area\'s offline maps are a row of '
      'their own, not done, with the size', (tester) async {
    final container = await readyContainer(tester, email: 'sam@example.com');
    await pumpScreen(tester, container);
    // The saved-areas list reads the disk; wait for it, bounded.
    for (var i = 0; i < 40 && find.text('Checking…').evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }

    expect(find.text("Offline maps for this project's area"), findsOneWidget);
    final card = find.ancestor(
      of: find.text("Offline maps for this project's area"),
      matching: find.byType(Card),
    );
    expect(find.descendant(of: card, matching: find.byIcon(Icons.error_outline)),
        findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining(RegExp(r'about \d+ MB'))),
      findsOneWidget,
    );
    expect(find.descendant(of: card, matching: find.text('Download')),
        findsOneWidget);
  });

  testWidgets('WATCHED RED: with a server, an unpublished project says so and '
      'where to publish it', (tester) async {
    final container = await readyContainer(
      tester,
      email: 'sam@example.com',
      server: 'https://tritrack.example.edu',
    );
    await pumpScreen(tester, container);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();

    expect(find.text('Published to the server'), findsOneWidget);
    final card = find.ancestor(
      of: find.text('Published to the server'),
      matching: find.byType(Card),
    );
    expect(find.descendant(of: card, matching: find.byIcon(Icons.error_outline)),
        findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.textContaining('Publish to server')),
      findsOneWidget,
    );
  });

  testWidgets('with no server, publishing is not on the list — working '
      'offline is a whole way to use the app', (tester) async {
    final container = await readyContainer(tester, email: 'sam@example.com');
    await pumpScreen(tester, container);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(find.text('Published to the server'), findsNothing);
  });
}

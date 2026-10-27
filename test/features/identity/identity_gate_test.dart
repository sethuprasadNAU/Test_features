import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer, UncontrolledProviderScope;
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/features/identity/screens/identity_setup_screen.dart';

import '../../data/fixtures.dart';
import '../../support/app_boot_helper.dart';
import '../../support/complete_identity_setup.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 7.6: the first-run gate really is non-skippable, and completing it
/// on a device that already has a placeholder identity (a fresh install, or
/// one that predates Phase 7) migrates that existing user_id in place rather
/// than orphaning whatever it already recorded — the two acceptance
/// criteria task 7.1 set out that hadn't been exercised end-to-end yet.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('a fresh install lands on the identity screen, not the tab shell', (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);

    expect(find.text('Set up your identity'), findsOneWidget);
    for (final tabLabel in ['Map', 'Record', 'Compass', 'Position', 'More']) {
      expect(find.text(tabLabel), findsNothing);
    }
  });

  testWidgets('the system back gesture cannot dismiss the identity gate', (tester) async {
    // Pushed onto a real two-entry Navigator stack (rather than the full app,
    // which routes here via `context.go` and never gives Navigator.maybePop
    // anything to pop to regardless of PopScope) so a pop attempt has
    // somewhere to go if it isn't blocked.
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(currentUserProvider.future);
    });

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const IdentitySetupScreen())),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Set up your identity'), findsOneWidget);

    // Mimics the OS back button/gesture (`WidgetsBinding.handlePopRoute`),
    // which is what `PopScope` actually intercepts — a bare
    // `Navigator.maybePop()` call bypasses that route and pops regardless.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('Set up your identity'), findsOneWidget, reason: 'PopScope(canPop: false) must refuse the pop');
  });

  testWidgets('an empty required field blocks continuing past the gate', (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);

    await tester.tap(find.text('CONTINUE'));
    await tester.pump();

    expect(find.text('First name is required'), findsOneWidget);
    expect(find.text('Set up your identity'), findsOneWidget);
  });

  testWidgets('an invalid email blocks continuing past the gate', (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);

    await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Test');
    await tester.enterText(find.widgetWithText(TextFormField, 'Last name'), 'User');
    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'not-an-email');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pump();

    expect(find.text('Enter a valid email address'), findsOneWidget);
    expect(find.text('Set up your identity'), findsOneWidget);
  });

  /// **Task 11.122, item 1 — the other half of "either screen".**
  ///
  /// The gate is where most people type their name for the first time, and
  /// until this task it accepted anything non-empty. A name carrying a
  /// bidirectional override saved here, and the server refused the whole
  /// `Users` row on the next sync — which, for a first-run identity, is the
  /// row every observation on this device is attributed to.
  testWidgets('a name with a bidirectional override blocks continuing', (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);

    // U+202E written as an escape: a literal one is invisible in a diff,
    // which is exactly why it is worth refusing.
    await tester.enterText(
        find.widgetWithText(TextFormField, 'First name'), 'Test\u202EUser');
    await tester.enterText(find.widgetWithText(TextFormField, 'Last name'), 'User');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Email'), 'test@example.com');
    await tester.pump();
    await tester.tap(find.text('CONTINUE'));
    await tester.pump();

    // Task 11.89 made this message name the character it objected to, so the
    // wording asserted here is the *property* the screen has to have rather
    // than the sentence it happens to say: the person is told the character is
    // one they cannot see, and told the remedy that works for one.
    expect(find.textContaining('hidden character'), findsOneWidget);
    expect(find.textContaining('U+202E'), findsOneWidget);
    expect(find.text('Set up your identity'), findsOneWidget);
  });

  testWidgets(
      'completing identity on a placeholder device keeps the same user_id and existing attribution',
      (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);

    late final String placeholderId;
    await tester.runAsync(() async {
      final placeholder = await container.read(currentUserProvider.future);
      expect(placeholder.hasPlaceholderIdentity, isTrue);
      placeholderId = placeholder.userId;

      // Prior records already exist on this "device" under the placeholder
      // id, exactly the scenario 7.1's migration requirement is about: a
      // pre-Phase-7 install with real project/tag/observation data attributed
      // to the auto-created user.
      final db = await container.read(appDatabaseProvider.future);
      await db.raw.insert(
          Tables.projects, sampleProject(id: 'project-1', ownerUserId: placeholderId).toColumns());
      await db.raw.insert(Tables.tags, sampleTag(id: 'tag-1').toColumns());
      await db.raw.insert(
        Tables.observations,
        sampleObservation(
          id: 'obs-1',
          projectId: 'project-1',
          userId: placeholderId,
          tagId: 'tag-1',
          sessionId: null,
        ).toColumns(),
      );
    });

    await completeIdentitySetup(tester);

    await tester.runAsync(() async {
      final updated = await container.read(currentUserProvider.future);
      expect(updated.userId, placeholderId, reason: 'must update the existing row in place, not mint a new user');
      expect(updated.hasPlaceholderIdentity, isFalse);
      expect(updated.email, 'test.user@example.com');

      final db = await container.read(appDatabaseProvider.future);
      final obs = (await db.raw
              .query(Tables.observations, where: 'observation_id = ?', whereArgs: ['obs-1']))
          .single;
      expect(obs['user_id'], placeholderId, reason: 'prior attribution must survive the migration');
    });
  });
}

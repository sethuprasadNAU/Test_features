import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/more/screens/profile_screen.dart';

import '../../data/fixtures.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Widget-level coverage stays scoped to form/dialog behavior that doesn't
/// require a completed save round-trip — same reasoning as
/// `project_setup_screen_test.dart`: `sqflite_common_ffi`'s worker isolate
/// reliably hangs a `testWidgets` pump once `currentUserProvider` (which
/// `ProfileScreen` itself watches) gets invalidated and has to do a fresh
/// real DB read to recompute. The actual persistence logic — record the old
/// address on an email change, update in place otherwise — is factored into
/// `ProfileEditor` specifically so it can be covered with a plain `test()`
/// instead; see `test/data/repositories/profile_editor_test.dart`.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    EditableText.debugDeterministicCursor = true;
  });

  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  /// Seeds a known local user (rather than letting `currentUserProvider`
  /// auto-create a placeholder) and pre-resolves everything `ProfileScreen`
  /// reads on first build, so nothing needs a fresh FFI call mid-test.
  Future<ProviderContainer> readyContainer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      final db = await container.read(appDatabaseProvider.future);
      await db.raw.insert(
        Tables.users,
        sampleUser(id: 'user-1', email: 'sam@example.com').toColumns(),
      );
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(currentUserProvider.future);
      await container.read(deviceIdProvider.future);
      await container.read(userRepositoryProvider.future);
      await container.read(userEmailRepositoryProvider.future);
    });
    return container;
  }

  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ProfileScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('loads the current user into the form', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'First name')).controller!.text,
        'Sam');
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Last name')).controller!.text,
        'Ranger');
    expect(tester.widget<TextFormField>(find.widgetWithText(TextFormField, 'Email')).controller!.text,
        'sam@example.com');
  });

  testWidgets('an empty name is rejected inline, matching 7.1', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    await tester.enterText(find.widgetWithText(TextFormField, 'First name'), '');
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pump();

    expect(find.text('First name is required'), findsOneWidget);
  });

  testWidgets('an invalid email is rejected inline, matching 7.1', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'not-an-email');
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pump();

    expect(find.text('Enter a valid email address'), findsOneWidget);
  });

  testWidgets('saving without an email change shows no warning dialog', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    await tester.enterText(find.widgetWithText(TextFormField, 'First name'), 'Samantha');
    await tester.pump();

    // With no email change, SAVE goes straight into the real (uncached) save
    // chain rather than pausing on a confirm dialog — that chain must run to
    // completion inside `runAsync`, or its continuation throws
    // "used ref after unmount" once the next test's `pumpWidget` tears this
    // tree down. Bounded pumps, not `pumpAndSettle`: saving invalidates
    // `currentUserProvider`, which `ProfileScreen` itself watches, and that
    // recompute's real DB read is bound to the zone the widget was
    // originally built in (outside this block) rather than this tap's — so
    // it never settles.
    await tester.runAsync(() async {
      await tester.tap(find.text('SAVE'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();
    });

    expect(find.text('Change email?'), findsNothing);
  });

  testWidgets('changing the email shows a warning dialog naming the old address', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'new@example.com');
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pump();

    expect(find.text('Change email?'), findsOneWidget);
    expect(find.textContaining('sam@example.com'), findsOneWidget);
  });

  testWidgets('canceling an email change leaves the record untouched', (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    await tester.enterText(find.widgetWithText(TextFormField, 'Email'), 'new@example.com');
    await tester.pump();
    await tester.tap(find.text('SAVE'));
    await tester.pump();

    expect(find.text('Change email?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    // Bounded pumps, not `pumpAndSettle`: the still-focused email field's
    // cursor/dialog-dismiss transition can leave something scheduling frames
    // indefinitely, and closing the dialog is all this test needs settled.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // A fresh `db.raw.query` is always real I/O regardless of whether the
    // `appDatabaseProvider` future itself is cached — must run in `runAsync`
    // like every other real DB read in this suite.
    await tester.runAsync(() async {
      final db = await container.read(appDatabaseProvider.future);
      final rows = await db.raw.query(Tables.users, where: 'user_id = ?', whereArgs: ['user-1']);
      expect(rows.single['email'], 'sam@example.com');
      expect(await db.raw.query(Tables.userEmails), isEmpty);
    });
  });

  /// **Task 11.122, item 1 — the way out has to exist.**
  ///
  /// Pointing `validateRequiredName` at the rule the server enforces creates
  /// a case that did not exist while the check was "is it empty": a name
  /// **already stored** that the screen now refuses. Task 11.89 widens that
  /// rule again and makes it commonplace.
  ///
  /// A profile screen that will not submit because of a value it loaded is a
  /// screen nobody can get out of — and the only way out of this one is the
  /// very field being refused. So this asserts the whole escape: the screen
  /// loads the bad value, says so plainly, accepts a correction, and writes
  /// it. If any one of those four failed, the person would be stuck with a
  /// name the server will not take and no way to change it.
  group('a stored name the rule now refuses can still be corrected', () {
    /// The same seed as `readyContainer`, with a first name carrying U+202E
    /// — written as an escape, because a literal one is invisible in a diff.
    Future<ProviderContainer> containerWithABadStoredName(
      WidgetTester tester,
    ) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        final db = await container.read(appDatabaseProvider.future);
        await db.raw.insert(Tables.users, {
          ...sampleUser(id: 'user-1', email: 'sam@example.com').toColumns(),
          // Straight into SQLite, deliberately bypassing `RowValidator`: this
          // is the row an older build wrote before the screen checked, which
          // is exactly the state this group is about.
          'first_name': 'Sam\u202ERanger',
        });
        await container.read(activeUserIdProvider.notifier).set('user-1');
        await container.read(currentUserProvider.future);
        await container.read(deviceIdProvider.future);
        await container.read(userRepositoryProvider.future);
        await container.read(userEmailRepositoryProvider.future);
      });
      return container;
    }

    testWidgets('it loads, and saving it unchanged is refused with a remedy', (
      tester,
    ) async {
      final container = await containerWithABadStoredName(tester);
      await pumpScreen(tester, container);

      expect(
        tester
            .widget<TextFormField>(
              find.widgetWithText(TextFormField, 'First name'),
            )
            .controller!
            .text,
        'Sam\u202ERanger',
        reason:
            'The field has to show the offending value. A screen that hides '
            'it is one where the remedy cannot be carried out.',
      );

      await tester.tap(find.text('SAVE'));
      await tester.pump();

      // Task 11.89: the message now names the character. What matters to the
      // person reading it has not changed — it is invisible, and retyping is
      // the remedy — so that is what is asserted, rather than the sentence.
      expect(find.textContaining('hidden character'), findsOneWidget);
      expect(find.textContaining('type it again'), findsOneWidget);
    });

    testWidgets('retyping the name lets the save go through', (tester) async {
      final container = await containerWithABadStoredName(tester);
      await pumpScreen(tester, container);

      await tester.enterText(
        find.widgetWithText(TextFormField, 'First name'),
        'Sam',
      );
      await tester.pump();

      // The email is unchanged, so SAVE goes straight into the real save
      // chain with no confirm dialog — same `runAsync` handling and same
      // reasoning as the "saving without an email change" test above.
      await tester.runAsync(() async {
        await tester.tap(find.text('SAVE'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.pump();
      });

      await tester.runAsync(() async {
        final db = await container.read(appDatabaseProvider.future);
        final rows = await db.raw.query(
          Tables.users,
          where: 'user_id = ?',
          whereArgs: ['user-1'],
        );
        expect(
          rows.single['first_name'],
          'Sam',
          reason:
              'The escape from a refused stored name is the field itself. If '
              'this row still holds the old value, there is no escape.',
        );
      });
    });
  });

  group('where sign-in lives (task 11.37, item 2)', () {
    testWidgets('the screen says sign-in is not here and names where it is', (
      tester,
    ) async {
      // Both screens ask for an email and offer Save, and only one of them
      // signs you in. On 2026-08-26 that was enough for a reasonable person to
      // conclude sign-in had never been built.
      final container = await readyContainer(tester);
      await pumpScreen(tester, container);

      expect(find.textContaining('Looking for sign-in?'), findsOneWidget);
      expect(find.textContaining('Server Connection'), findsOneWidget);
      expect(
        find.textContaining('only how this device labels your own records'),
        findsOneWidget,
        reason:
            'The email here is local identity and stays. What was missing was '
            'anything saying so.',
      );
    });

    testWidgets('tapping it actually arrives at Server Connection', (
      tester,
    ) async {
      // Asserted by navigating rather than by matching the path string,
      // because a wrong path is exactly the defect a string comparison would
      // agree with.
      final container = await readyContainer(tester);
      final router = GoRouter(
        initialLocation: '/more/profile',
        routes: [
          GoRoute(
            path: '/more/profile',
            builder: (_, _) => const ProfileScreen(),
          ),
          GoRoute(
            path: '/more/server',
            builder: (_, _) => const Scaffold(
              body: Center(child: Text('Server Connection reached')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.textContaining('Looking for sign-in?'));
      await tester.pumpAndSettle();

      expect(find.text('Server Connection reached'), findsOneWidget);
    });
  });
}

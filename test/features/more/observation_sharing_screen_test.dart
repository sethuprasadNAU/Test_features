import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/core/format/observation_quality_display.dart';
import 'package:tritrack/data/models/tag_version.dart';
import 'package:tritrack/data/sharing/observation_share.dart';
import 'package:tritrack/features/more/screens/observation_sharing_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Strips a v2 payload's identity block, producing the v1 shape an older app
/// build would have sent — the only way to get a genuine v1 payload now that
/// `ObservationShare.encode` always emits the current version.
String _downgradeToV1(String payload) {
  final json = jsonDecode(utf8.decode(base64Decode(payload.substring('TT1:'.length))))
      as Map<String, Object?>;
  json
    ..['v'] = 1
    ..remove('observation_id')
    ..remove('observer_user_id')
    ..remove('observer_email')
    ..remove('position_source')
    ..remove('position_accuracy_m')
    ..remove('created_at')
    ..remove('updated_at')
    ..remove('revision')
    ..remove('last_modified_by')
    ..remove('origin_device_id');
  return 'TT1:${base64Encode(utf8.encode(jsonEncode(json)))}';
}

void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  /// The preview card is a plain `ListView(children:)`, which is a sliver
  /// underneath — so anything past the bottom of the surface is never inflated
  /// into the element tree at all, not merely scrolled out of `find`'s view.
  /// The role-aware group below has needed this since task 11.14; task 11.32
  /// added a line to the card saying whether the tag values are what the
  /// bearing was recorded against, which pushed the two tests above it over
  /// the same edge.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('parsing a well-formed payload previews it and flags an unknown tag',
      (tester) async {
    useTallSurface(tester);
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ObservationSharingScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final payload = ObservationShare.encode(
      sampleObservation(),
      tag: sampleTag(),
      observer: sampleUser(),
    );

    await tester.enterText(find.byType(TextField), payload);
    await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Tag not known locally.'), findsOneWidget);
    expect(find.textContaining('Coco'), findsWidgets);
  });

  /// **Task 11.193 — the sender's answer about the signal, or no line at all.**
  ///
  /// The line only renders when the payload carries an answer, which is
  /// exactly the shape that can quietly stop rendering and take a sentence
  /// nobody is watching with it. Both answers are shown, because *"nothing
  /// wrong with the signal"* is a statement the sender made rather than an
  /// absence — and a payload from an older build says neither, which is the
  /// honest rendering of one that could not carry it.
  testWidgets("the paste screen says what the sender heard, and says nothing "
      'when the payload does not know', (tester) async {
    useTallSurface(tester);
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ObservationSharingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> parse(bool? flag) async {
      await tester.enterText(
        find.byType(TextField),
        ObservationShare.encode(
          sampleObservation(signalIrregular: flag),
          tag: sampleTag(),
          observer: sampleUser(),
        ),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await parse(true);
    expect(find.textContaining('flagged this signal as Malfunctioning'),
        findsOneWidget);

    await parse(false);
    expect(find.textContaining('nothing wrong with the signal'), findsOneWidget);
    expect(find.textContaining('flagged this signal as Malfunctioning'),
        findsNothing);

    await parse(null);
    expect(find.textContaining('flagged this signal as Malfunctioning'),
        findsNothing);
    expect(find.textContaining('nothing wrong with the signal'), findsNothing);
  });

  /// **Task 11.199 — the paste screen shows words, and says which field a
  /// weak answer came from.**
  ///
  /// This card printed `Signal: regular_pulse · medium` and `Type:
  /// directional` — two of the six raw stored tokens the guard in
  /// `test/documentation/stored_value_display_test.dart` found in `lib/`. That
  /// guard is the durable half and it is mechanical; this is the half that
  /// says what a person actually reads, including the part no scan can check:
  /// the *legacy* mode field appears **only** when the payload carries no mode
  /// name, and it says where it came from rather than presenting itself as the
  /// record's mode.
  testWidgets('the preview card shows words, and names the legacy field only '
      'when the payload has no mode name', (tester) async {
    useTallSurface(tester);
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ObservationSharingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> parse(String payload) async {
      await tester.enterText(find.byType(TextField), payload);
      await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    // A sender who could not say what the mode was called: `signal_type` is
    // the only mode information the record carries, so it is transcribed and
    // attributed.
    await parse(ObservationShare.encode(
      sampleObservation(),
      tag: sampleTag(),
      observer: sampleUser(),
    ));
    expect(find.text('Pulse mode: not recorded in this payload'), findsOneWidget);
    expect(
      find.textContaining("older signal field says ${defaultPulseModeNames[0]}"),
      findsOneWidget,
    );
    // The two lines this task rewrote. Asserted as whole strings rather than
    // by the absence of a token: a token that is missing because the whole
    // card failed to build looks identical to one that was replaced.
    expect(find.text('Type: ${RecordType.directional.label}'), findsOneWidget);
    expect(find.text('Signal: ${signalStrengthLabel(SignalStrength.medium)} · '
        '${bearingQualityLabel(BearingQuality.good)}'), findsOneWidget);

    // A sender whose device knew the mode: the line above has already said the
    // true thing, so the legacy field is not offered as a second description
    // of it — and it is the one that would be wrong on a tag's third mode.
    await parse(ObservationShare.encode(
      sampleObservation(pulseMode: 2),
      tag: sampleTag(pulseMode1Name: 'Normal', pulseMode2Name: 'Mortality'),
      observer: sampleUser(),
      recorded: RecordedTagState(
        tag: sampleTag(pulseMode1Name: 'Normal', pulseMode2Name: 'Mortality'),
        version: sampleTagVersion(
          pulseMode1Name: 'Normal',
          pulseMode2Name: 'Mortality',
        ),
      ),
    ));
    expect(find.text('Pulse mode: Mortality'), findsOneWidget);
    expect(find.textContaining('older signal field says'), findsNothing);
  });

  testWidgets('an invalid payload shows a parse error, not an exception', (tester) async {
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ObservationSharingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'not a real payload');
    await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Not a TriTrack share payload'), findsOneWidget);
  });

  testWidgets('a v1 payload previews with a provenance warning (task 6.3/6.4)',
      (tester) async {
    useTallSurface(tester);
    final container = ProviderContainer(
      overrides: [appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ObservationSharingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    final v1Payload = _downgradeToV1(
      ObservationShare.encode(sampleObservation(), tag: sampleTag(), observer: sampleUser()),
    );
    await tester.enterText(find.byType(TextField), v1Payload);
    await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // v1 still parses and previews (the "falls back" half of "decodes, falls
    // back, warns") — it does not just fail like a malformed payload.
    expect(find.textContaining('Coco'), findsWidgets);
    // ...but visibly warns that provenance can't be preserved, *before* the
    // user commits to saving a record that may duplicate the sender's.
    expect(find.textContaining('older app version'), findsOneWidget);
    expect(find.textContaining('may duplicate'), findsOneWidget);
  });

  group('role-aware controls (task 11.14)', () {
    /// Seeds an owner-created project, membership for [actingUser] at [role],
    /// and — when [matchingTag] is true — a tag matching `sampleTag()`
    /// exactly, so the payload resolves to a match and "Save observation"
    /// (rather than "Create tag") is the button under test.
    Future<ProviderContainer> readyContainer(
      WidgetTester tester, {
      required User actingUser,
      required ProjectRole role,
      required bool matchingTag,
    }) async {
      final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
      final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);

      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider.overrideWith((ref) async => actingUser),
        ],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(Tables.users, owner.toColumns());
        await db.insert(Tables.users, actingUser.toColumns());
        await db.insert(Tables.projects, project.toColumns());
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: actingUser.userId,
            role: role,
          ).toColumns(),
        );
        if (matchingTag) {
          // Task 11.218: matching is scoped to the active project's tags.
          // Task 11.219: that is one row now — a tag belongs to a project
          // rather than being linked into it.
          await db.insert(
            Tables.tags,
            sampleTag(id: 'tag-1', projectId: project.projectId).toColumns(),
          );
        }
        await container.read(activeProjectIdProvider.notifier).set(project.projectId);
        // Pre-resolved for the same reason `tag_database_screen_test.dart`
        // pre-resolves `mayCreateTagProvider`: a fresh FFI call triggered
        // after pumping never resolves inside `testWidgets`' fake-async zone.
        await container.read(currentProjectProvider.future);
        // `projectActiveTagsProvider` is autoDispose — a bare `.future` read
        // with no listener disposes it the instant this completes, so the
        // widget's own `ref.watch` below starts a fresh, unresolved read
        // inside the fake-async pump. `container.listen` (same pattern as
        // `record_screen_pulse_modes_test.dart` and friends) keeps it alive.
        container.listen(projectActiveTagsProvider(project.projectId), (_, _) {});
        await container.read(projectActiveTagsProvider(project.projectId).future);
        // Listened for the same reason, and it matters more since task
        // 11.219: the screen's "Create tag" gate reads this provider
        // directly now (creating a tag here puts it straight into the
        // active project), where it used to read the non-autoDispose
        // `mayCreateTagProvider`, which stayed cached whether or not
        // anybody listened.
        container.listen(
          mayWriteProjectDataProvider(project.projectId),
          (_, _) {},
        );
        await container.read(mayWriteProjectDataProvider(project.projectId).future);
      });

      return container;
    }

    Future<void> pumpAndParse(WidgetTester tester, ProviderContainer container) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ObservationSharingScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final payload = ObservationShare.encode(
        sampleObservation(),
        tag: sampleTag(),
        observer: sampleUser(),
      );
      await tester.enterText(find.byType(TextField), payload);
      await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
      await tester.pumpAndSettle();
    }

    testWidgets('a viewer sees "Create tag" disabled, with a reason', (tester) async {
      useTallSurface(tester);
      final viewer = sampleUser(id: 'user-viewer', email: 'viewer@example.com');
      final container = await readyContainer(
        tester,
        actingUser: viewer,
        role: ProjectRole.viewer,
        matchingTag: false,
      );
      await pumpAndParse(tester, container);

      expect(tester.takeException(), isNull);
      expect(find.text('Tag not known locally.'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Create tag')).onPressed,
        isNull,
      );
      // Task 11.138: on the control, not in a tooltip a phone never opens.
      expect(
        find.text('Viewers cannot create tags — ask an owner to change your role.'),
        findsOneWidget,
      );
    });

    testWidgets('a contributor sees "Create tag" enabled', (tester) async {
      useTallSurface(tester);
      final contributor = sampleUser(id: 'user-contributor', email: 'contributor@example.com');
      final container = await readyContainer(
        tester,
        actingUser: contributor,
        role: ProjectRole.contributor,
        matchingTag: false,
      );
      await pumpAndParse(tester, container);

      expect(tester.takeException(), isNull);
      expect(
        tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Create tag')).onPressed,
        isNotNull,
      );
    });

    testWidgets('a viewer sees "Save observation" disabled, with a reason', (tester) async {
      useTallSurface(tester);
      final viewer = sampleUser(id: 'user-viewer', email: 'viewer@example.com');
      final container = await readyContainer(
        tester,
        actingUser: viewer,
        role: ProjectRole.viewer,
        matchingTag: true,
      );
      await pumpAndParse(tester, container);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Matches local tag'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save observation')).onPressed,
        isNull,
      );
      // Task 11.138: on the control, not in a tooltip a phone never opens.
      expect(
        find.text('Viewers cannot save observations — ask an owner to change your role.'),
        findsOneWidget,
      );
    });

    testWidgets('a contributor sees "Save observation" enabled', (tester) async {
      useTallSurface(tester);
      final contributor = sampleUser(id: 'user-contributor', email: 'contributor@example.com');
      final container = await readyContainer(
        tester,
        actingUser: contributor,
        role: ProjectRole.contributor,
        matchingTag: true,
      );
      await pumpAndParse(tester, container);

      expect(tester.takeException(), isNull);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save observation')).onPressed,
        isNotNull,
      );
    });

    testWidgets(
      '[Task 11.218] a tag matching by frequency/name/pulse but linked only '
      'to a different project is not matched — this used to check the whole '
      'device\'s tag list, so a pasted record could name another project\'s '
      'tag and be held',
      (tester) async {
        useTallSurface(tester);
        final owner = sampleUser(id: 'user-owner', email: 'owner@example.com');
        final contributor = sampleUser(
          id: 'user-contributor',
          email: 'contributor@example.com',
        );
        final project = sampleProject(id: 'project-1', ownerUserId: owner.userId);
        final otherProject = sampleProject(
          id: 'project-2',
          ownerUserId: owner.userId,
        );

        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
            currentUserProvider.overrideWith((ref) async => contributor),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          await db.insert(Tables.users, owner.toColumns());
          await db.insert(Tables.users, contributor.toColumns());
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(Tables.projects, otherProject.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(
              projectId: project.projectId,
              userId: contributor.userId,
              role: ProjectRole.contributor,
            ).toColumns(),
          );
          // The tag matches the payload exactly, but it belongs to
          // `project-2` — a different project from the one active below.
          await db.insert(
            Tables.tags,
            sampleTag(
              id: 'tag-1',
              projectId: otherProject.projectId,
            ).toColumns(),
          );
          await container
              .read(activeProjectIdProvider.notifier)
              .set(project.projectId);
          await container.read(currentProjectProvider.future);
          container.listen(
            projectActiveTagsProvider(project.projectId),
            (_, _) {},
          );
          await container.read(
            projectActiveTagsProvider(project.projectId).future,
          );
            container.listen(
            mayWriteProjectDataProvider(project.projectId),
            (_, _) {},
          );
          await container.read(
            mayWriteProjectDataProvider(project.projectId).future,
          );
        });

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: ObservationSharingScreen()),
          ),
        );
        await tester.pumpAndSettle();

        final payload = ObservationShare.encode(
          sampleObservation(),
          tag: sampleTag(),
          observer: sampleUser(),
        );
        await tester.enterText(find.byType(TextField), payload);
        await tester.tap(find.widgetWithText(FilledButton, 'Parse'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('Tag not known locally.'), findsOneWidget);
        expect(find.textContaining('Matches local tag'), findsNothing);
      },
    );
  });
}

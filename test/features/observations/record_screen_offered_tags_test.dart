import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack/widgets/wheel_picker.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.249 — the Record screen offers only collars on an animal today,
/// shows frequency and name, and can be sorted by either.**
///
/// Michael, on his phone, 2026-09-14: he linked two collars to one animal in
/// turn and the wheel offered both, though one had come off a month before.
/// `tag_ids_audible_on_test.dart` holds the rule at its boundaries; this
/// file holds the screen — every record type, both tag-selecting widgets,
/// the empty state the filter creates, the sort switch, and the quick-add
/// that now puts a collar on an animal in the same act.
///
/// ## The list of surfaces is derived, not written
///
/// The plan named *bearing, no-signal, note, truth point* and then said a
/// list of four written down is the shape this project keeps being wrong
/// about. So the walk below is over [RecordType.values] — the enum the
/// screen's own toggle is built from — and asserts on each one that the
/// removed collar is nowhere on the form and the live one is. Two widgets
/// select a collar on this screen (`grep` on 2026-09-14: the
/// `WheelPicker<Tag>` and the no-signal `CheckboxListTile` list, both in
/// `observation_logging_screen.dart`); the walk reaches both because the
/// enum reaches both.
void main() {
  setUp(installFakeSharedPreferences);

  final today = DateTime.now();
  final lastMonth = DateTime(today.year, today.month - 1, today.day);
  // The day after `lastMonth`: a collar that came off last month and one
  // that went on the next day are a handover recorded a day apart, which
  // the interlock permits. On the *same* bare day they would overlap for
  // the whole of it and be refused (task 11.263, design §6a).
  final dayAfterLastMonth = DateTime(today.year, today.month - 1, today.day + 1);
  final lastYear = DateTime(today.year - 1, today.month, today.day);

  /// Seeds one project with:
  ///  - `tag-live`  150.100 MHz "Live"   — on Marie since the day after last
  ///                                       month's removal
  ///  - `tag-off`   150.200 MHz "Off"    — on Marie last year, off last month
  ///  - `tag-boxed` 150.300 MHz "Boxed"  — never on anything
  /// plus, when [legacyHandover] is set:
  ///  - `tag-old`   150.400 MHz "Old"    — on Kea, off **today** (bare day)
  ///  - `tag-new`   150.500 MHz "New"    — on Kea from **today** (bare day)
  ///    **planted past the interlock**, which refuses that pair since task
  ///    11.263 — it is what a build with the one-day allowance wrote, and
  ///    the wheel still has to read it honestly.
  Future<ProviderContainer> setUpScreen(
    WidgetTester tester, {
    bool legacyHandover = false,
    // A same-day handover with a time on the swap (task 11.251) — set an
    // hour ago, so "Old" has already left the wheel.
    bool timedHandover = false,
    bool linkNothing = false,
    RecordType recordType = RecordType.directional,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassHeadingProvider.overrideWith(
          (ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0])),
        ),
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
      final individuals = await container.read(individualRepositoryProvider.future);
      final deployments = await container.read(deploymentRepositoryProvider.future);
      await userRepo.insert(sampleUser());
      await projectRepo.insert(sampleProject());
      await tagRepo.insert(sampleTag(id: 'tag-live', tagName: 'Live', frequencyMhz: 150.1));
      await tagRepo.insert(sampleTag(id: 'tag-off', tagName: 'Off', frequencyMhz: 150.2));
      await tagRepo.insert(sampleTag(id: 'tag-boxed', tagName: 'Boxed', frequencyMhz: 150.3));
      if (!linkNothing) {
        await individuals.insert(sampleIndividual(id: 'marie', name: 'Marie'));
        await deployments.link(sampleDeployment(
          id: 'd-off', tagId: 'tag-off', individualId: 'marie',
          attachedDate: lastYear, removedDate: lastMonth,
        ));
        await deployments.link(sampleDeployment(
          id: 'd-live', tagId: 'tag-live', individualId: 'marie',
          attachedDate: dayAfterLastMonth,
        ));
      }
      if (legacyHandover) {
        await tagRepo.insert(sampleTag(id: 'tag-old', tagName: 'Old', frequencyMhz: 150.4));
        await tagRepo.insert(sampleTag(id: 'tag-new', tagName: 'New', frequencyMhz: 150.5));
        await individuals.insert(sampleIndividual(id: 'kea', name: 'Kea'));
        await deployments.link(sampleDeployment(
          id: 'd-old', tagId: 'tag-old', individualId: 'kea',
          attachedDate: lastMonth, removedDate: deploymentDateFor(today),
        ));
        // Straight into the table, past the rule — see the fixture comment.
        await deployments.insertRow(sampleDeployment(
          id: 'd-new', tagId: 'tag-new', individualId: 'kea',
          attachedDate: deploymentDateFor(today),
        ).toColumns());
      }
      if (timedHandover) {
        final swapAt = today.subtract(const Duration(hours: 1));
        await tagRepo.insert(sampleTag(id: 'tag-old', tagName: 'Old', frequencyMhz: 150.4));
        await tagRepo.insert(sampleTag(id: 'tag-new', tagName: 'New', frequencyMhz: 150.5));
        await individuals.insert(sampleIndividual(id: 'kea', name: 'Kea'));
        await deployments.link(sampleDeployment(
          id: 'd-old', tagId: 'tag-old', individualId: 'kea',
          attachedDate: lastMonth, removedDate: swapAt,
        ));
        await deployments.link(sampleDeployment(
          id: 'd-new', tagId: 'tag-new', individualId: 'kea',
          attachedDate: swapAt,
        ));
      }
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(activeProjectIdProvider.notifier).set('project-1');
      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});
      container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
      container.listen(observationFormProvider, (_, _) {});
      container.listen(myProjectStandingProvider('project-1'), (_, _) {});
      container.listen(tagWheelSortSettingProvider, (_, _) {});
      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(observationFormProvider.future);
      await container.read(myProjectStandingProvider('project-1').future);
      await container.read(tagWheelSortSettingProvider.future);
      await container.read(currentUserProvider.future);
      await container.read(deviceIdProvider.future);
    });
    if (recordType != RecordType.directional) {
      container.read(observationFormProvider.notifier).setRecordType(recordType);
    }
    if (recordType == RecordType.note) {
      // A Note starts as a general note with no tag and no wheel; the walk
      // below is about what the wheel offers, so this one is given a tag —
      // the same as un-ticking "General note (no tag)".
      container.read(observationFormProvider.notifier).setTag('tag-live');
    }
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ObservationLoggingScreen(),
      tabIndex: 1, // Map / **Record** / Compass / Position / More
    );
    return container;
  }

  /// The collars the screen is offering, wherever it offers them, by their
  /// tag ID: the wheel's items, or the no-signal checklist's rows. Reads the
  /// widget, not the text, so a collar scrolled out of the wheel's three
  /// visible rows still counts as offered — being on the wheel is the claim.
  List<String> offeredTagNames(WidgetTester tester) {
    final wheel = find.byType(WheelPicker<Tag>);
    if (wheel.evaluate().isNotEmpty) {
      return [
        for (final t in tester.widget<WheelPicker<Tag>>(wheel).items)
          if (t.tagName.isNotEmpty) t.tagName,
      ];
    }
    // The checklist's line is "150.100 MHz · Marie" — frequency and animal,
    // no tag ID — so the row is mapped back to its collar by frequency.
    const byFrequency = {
      '150.100': 'Live', '150.200': 'Off', '150.300': 'Boxed',
      '150.400': 'Old', '150.500': 'New',
    };
    return [
      for (final tile in tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)))
        byFrequency[((tile.title as Text).data!).split(' MHz').first]!,
    ];
  }

  // =====================================================================
  // 1. Only collars on an animal today, on every record type.
  // =====================================================================
  for (final type in RecordType.values) {
    testWidgets('${type.label}: a collar taken off last month is not offered, '
        'a collar never linked is not offered, the live one is', (tester) async {
      await setUpScreen(tester, recordType: type);
      final offered = offeredTagNames(tester);
      expect(offered, ['Live'],
          reason: '${type.label} offers exactly the collar on an animal '
              'today. "Off" came off last month; "Boxed" has never been on '
              'anything. Offered: $offered');
      // And by text, which is what a person sees: the removed collar's
      // frequency is nowhere on the form.
      expect(find.textContaining('150.200'), findsNothing);
      expect(find.textContaining('150.300'), findsNothing);
    });
  }

  testWidgets('a Note with no tag ticked still hides the wheel, and ticking '
      'it back offers the same collars', (tester) async {
    final container = await setUpScreen(tester, recordType: RecordType.note);
    expect(offeredTagNames(tester), ['Live']);
    container.read(observationFormProvider.notifier).clearTag();
    await tester.pumpAndSettle();
    expect(find.byType(WheelPicker<Tag>), findsNothing);
    container.read(observationFormProvider.notifier).setTag('tag-live');
    await tester.pumpAndSettle();
    expect(offeredTagNames(tester), ['Live']);
  });

  // =====================================================================
  // 2. A legacy bare-day pair: both collars, on the wheel and on the
  //    checklist, and nothing said about it.
  // =====================================================================
  testWidgets('a bare-day pair from an older build lists BOTH of the '
      'animal\'s collars — the one that came off today and the one that went '
      'on — and no prompt or chooser above the wheel (task 11.263)',
      (tester) async {
    await setUpScreen(tester, legacyHandover: true);
    expect(offeredTagNames(tester), ['Live', 'Old', 'New'],
        reason: 'the wheel is not claiming which collar Kea is wearing, it is '
            'listing what can be heard, and for this pair that is two. This '
            'app can no longer write the pair (design §6a); reading one that '
            'exists honestly is §4a\'s contested rule, unchanged.');
    // Tasks 11.260 and 11.262 built a line above the wheel for exactly this
    // state, offering to set the removal time. 11.263 deleted it: the state
    // cannot be created here any more, and a control that fires only on
    // legacy rows is machinery serving nothing. Asserted by key so a later
    // task cannot quietly bring it back.
    expect(find.byKey(const ValueKey('record-handover-time-prompt')), findsNothing);
    expect(find.byKey(const ValueKey('record-handover-set-time')), findsNothing);
    expect(find.textContaining('set a removal time'), findsNothing);
  });

  testWidgets('the no-signal checklist offers both collars of the legacy '
      'pair too, and Select all ticks only what is offered', (tester) async {
    final container = await setUpScreen(tester, legacyHandover: true,
        recordType: RecordType.noSignal);
    expect(offeredTagNames(tester), ['Live', 'Old', 'New']);
    await tester.tap(find.text('Select all'));
    await tester.pumpAndSettle();
    final ticked = container.read(observationFormProvider).value!.noSignalTagIds;
    expect(ticked.toSet(), {'tag-live', 'tag-old', 'tag-new'},
        reason: 'a no-signal record on a collar that is in a box, or came '
            'off last month, would be a claim about a frequency nobody was '
            'listening for');
  });

  testWidgets('a timed handover an hour ago offers only the new collar',
      (tester) async {
    await setUpScreen(tester, timedHandover: true);
    expect(offeredTagNames(tester), ['Live', 'New'],
        reason: 'the timed swap already resolved the moment; Old has left '
            'the wheel');
  });

  // =====================================================================
  // 3. Frequency and name. Nothing else.
  // =====================================================================
  testWidgets('the wheel\'s line is frequency and animal — no pulse rate, no '
      'tag ID — and leads with whatever the wheel is sorted by', (tester) async {
    await setUpScreen(tester);
    final wheel = tester.widget<WheelPicker<Tag>>(find.byType(WheelPicker<Tag>));
    final live = wheel.items.firstWhere((t) => t.tagId == 'tag-live');
    expect(wheel.labelBuilder(live), '150.100 MHz · Marie',
        reason: 'Michael: "Don\'t need bpm" and "the tag ID isn\'t needed on '
            'that scroll wheel. Just the animal name and tag frequency." The '
            'rate is on the collar\'s details and under the MODE wheel; the '
            'ID is what the Tag Database is for.');
    expect(find.textContaining('Live'), findsNothing,
        reason: 'the tag ID is nowhere on the form');

    await tester.tap(find.byKey(const ValueKey('tag-wheel-sort-animal')));
    await tester.pumpAndSettle();
    final byAnimal = tester.widget<WheelPicker<Tag>>(find.byType(WheelPicker<Tag>));
    expect(byAnimal.labelBuilder(live), 'Marie · 150.100 MHz',
        reason: 'sorted by animal, the animal leads the line');
    // The fixture collar has a 40 bpm primary mode. The only "40 bpm" on the
    // form is the selected mode's line under the rollers, which is not this
    // task's subject — so it is asserted by position: nowhere inside the wheel.
    expect(
      find.descendant(of: find.byType(WheelPicker<Tag>), matching: find.textContaining('bpm')),
      findsNothing,
    );
  });

  testWidgets('the no-signal checklist\'s line is frequency and name too', (tester) async {
    await setUpScreen(tester, recordType: RecordType.noSignal);
    final title = tester.widget<Text>(
      find.descendant(of: find.byType(CheckboxListTile), matching: find.byType(Text)).first,
    );
    expect(title.data, '150.100 MHz · Marie');
  });

  // =====================================================================
  // 4. Sort by frequency or by animal.
  // =====================================================================
  testWidgets('the switch sorts the wheel by animal, and back by frequency, '
      'and the choice survives a restart', (tester) async {
    // Three live collars whose frequency order and animal order disagree:
    //   150.100 Live  (Marie)
    //   150.400 Old   (Kea)   — the handover pair, both on Kea today
    //   150.500 New   (Kea)
    // By frequency: Live, Old, New. By animal: Kea's two (frequency-ordered
    // within the animal), then Marie's.
    final container = await setUpScreen(tester, legacyHandover: true);
    expect(offeredTagNames(tester), ['Live', 'Old', 'New']);

    final byFrequency = find.byKey(const ValueKey('tag-wheel-sort-frequency'));
    final byAnimal = find.byKey(const ValueKey('tag-wheel-sort-animal'));
    expect(byFrequency, findsOneWidget);
    expect(byAnimal, findsOneWidget);
    // The chosen order is told to a screen reader as "selected" —
    // `IconButton` derives the semantics flag from `isSelected` — and drawn
    // as the filled button, a shape and not only a colour.
    expect(tester.widget<IconButton>(byFrequency).isSelected, isTrue);
    expect(tester.widget<IconButton>(byAnimal).isSelected, isFalse);

    await tester.tap(byAnimal);
    await tester.pumpAndSettle();
    expect(offeredTagNames(tester), ['Old', 'New', 'Live'],
        reason: 'by animal: Kea before Marie, and Kea\'s two collars in '
            'frequency order');
    expect(tester.widget<IconButton>(byAnimal).isSelected, isTrue);
    expect(tester.widget<IconButton>(byFrequency).isSelected, isFalse);

    // Persisted: a fresh read of the setting says animal.
    final stored = await tester.runAsync(
      () => container.read(tagWheelSortSettingProvider.future),
    );
    expect(stored, TagWheelSort.animal);

    await tester.tap(byFrequency);
    await tester.pumpAndSettle();
    expect(offeredTagNames(tester), ['Live', 'Old', 'New']);
  });

  testWidgets('the sort switch uses the Tag Database and Animals icons, at '
      'the wheel\'s height, beside it', (tester) async {
    await setUpScreen(tester);
    final wheel = tester.getRect(find.byType(WheelPicker<Tag>));
    final freq = find.byKey(const ValueKey('tag-wheel-sort-frequency'));
    final animal = find.byKey(const ValueKey('tag-wheel-sort-animal'));
    expect(
      tester.widget<Icon>(find.descendant(of: freq, matching: find.byType(Icon))).icon,
      Icons.podcasts,
      reason: 'the More tab\'s Tag Database icon',
    );
    expect(
      tester.widget<Icon>(find.descendant(of: animal, matching: find.byType(Icon))).icon,
      Icons.pets,
      reason: 'the More tab\'s Animals icon',
    );
    for (final button in [freq, animal]) {
      final r = tester.getRect(button);
      expect(r.left, greaterThanOrEqualTo(wheel.right),
          reason: 'beside the wheel, to its right');
      expect(r.top, greaterThanOrEqualTo(wheel.top - 0.5));
      expect(r.bottom, lessThanOrEqualTo(wheel.bottom + 0.5),
          reason: 'inside the wheel\'s height');
    }
  });

  // =====================================================================
  // 5. The empty state the filter creates.
  // =====================================================================
  testWidgets('tags that are on nobody get their own sentence, naming the '
      'way in', (tester) async {
    await setUpScreen(tester, linkNothing: true);
    expect(find.text('No tag is on an animal today'), findsOneWidget);
    expect(find.textContaining('More > Animals'), findsOneWidget,
        reason: 'the sentence names where a collar gets put on an animal, '
            'or it reads as the app having lost the tags just typed');
    expect(find.text('No tags in this project yet'), findsNothing,
        reason: 'that sentence is for a project with no equipment at all, '
            'and this one has three collars');
    expect(find.widgetWithText(FilledButton, '+ Quick-add tag'), findsOneWidget);
  });

  // =====================================================================
  // 6. Quick-add puts the collar on an animal in the same act.
  // =====================================================================
  testWidgets('quick-add writes the tag, an animal of the same name and a '
      'deployment from today — and the wheel offers the collar at once',
      (tester) async {
    final container = await setUpScreen(tester, linkNothing: true);
    expect(find.text('No tag is on an animal today'), findsOneWidget);

    // The dialog checks the person's standing first — a database read — so
    // the tap needs real time before the form appears.
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '+ Quick-add tag'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.text('Quick-add tag'), findsOneWidget);
    // The dialog says what it makes, in one line, and asks for the collar
    // and the animal separately — Michael, 2026-09-14, after one field had
    // put the same word on both.
    expect(find.textContaining('Adds the tag to the Tag Library and the animal'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Tag ID'), 'S-07');
    await tester.enterText(find.widgetWithText(TextField, 'Frequency (MHz)'), '151.000');
    await tester.enterText(find.widgetWithText(TextField, 'Animal name'), 'Sage');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      // The write and the refresh both touch the database; give them real
      // time, then let the screen rebuild.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
    });
    await tester.pumpAndSettle();

    // The three rows, read back through the repositories.
    final (tag, animals, deployments) = await tester.runAsync(() async {
      final tags = await (await container.read(tagRepositoryProvider.future)).findByProject('project-1');
      final animals = await (await container.read(individualRepositoryProvider.future)).findByProject('project-1');
      final deployments = await (await container.read(deploymentRepositoryProvider.future)).findByProject('project-1');
      return (tags.firstWhere((t) => t.tagName == 'S-07'), animals, deployments);
    }) as (Tag, List<dynamic>, List<dynamic>);
    expect(tag.frequencyMhz, 151.0);
    expect(animals.map((a) => a.name), ['Sage'],
        reason: 'one animal, with the name typed in its own field, and no other');
    expect(tag.tagName, 'S-07',
        reason: 'the Tag ID field is what names the collar in the Tag Database');
    expect(deployments, hasLength(1));
    expect(deployments.single.tagId, tag.tagId);
    expect(deployments.single.individualId, animals.single.individualId);
    // Task 11.331: "today" is the field's, not the phone's. The project's
    // area is around Flagstaff, so the row records Arizona's zone and its day
    // starts at Arizona's midnight — under every zone the suite runs in.
    // (Until v20 this compared with the phone's own midnight, which was the
    // rule then; the night's UTC and Auckland runs are what showed it stale.)
    expect(deployments.single.timeZone, 'America/Phoenix');
    expect(
      (deployments.single.attachedDate as DateTime).isAtSameMomentAs(
        deploymentDateFor(DateTime.now(), 'America/Phoenix'),
      ),
      isTrue,
      reason: 'on it from today, the way the Animals screen\'s link defaults',
    );
    expect(deployments.single.removedDate, isNull);

    // And the wheel now offers it — the whole point of writing three rows.
    expect(find.text('No tag is on an animal today'), findsNothing);
    expect(offeredTagNames(tester), ['S-07']);
    expect(
      tester.widget<WheelPicker<Tag>>(find.byType(WheelPicker<Tag>)).labelBuilder(tag),
      '151.000 MHz · Sage',
      reason: 'the frequency and the animal; the collar\'s ID lives in the '
          'Tag Library',
    );
  });

  testWidgets('WATCHED RED (task 11.324): quick-add with a Tag ID this '
      'project already has offers the existing tag by default, and using it '
      'writes no second tag — the animal wears the existing one', (tester) async {
    final container = await setUpScreen(tester, linkNothing: true);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '+ Quick-add tag'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Tag ID'), 'boxed ');
    await tester.enterText(
        find.widgetWithText(TextField, 'Frequency (MHz)'), '151.000');
    await tester.enterText(find.widgetWithText(TextField, 'Animal name'), 'Sage');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Use the existing tag'),
        findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Create anyway'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Use the existing tag'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    final (tags, animals, deployments) = await tester.runAsync(() async {
      final tags = await (await container.read(tagRepositoryProvider.future)).findByProject('project-1');
      final animals = await (await container.read(individualRepositoryProvider.future)).findByProject('project-1');
      final deployments = await (await container.read(deploymentRepositoryProvider.future)).findByProject('project-1');
      return (tags, animals, deployments);
    }) as (List<Tag>, List<dynamic>, List<dynamic>);
    expect(tags.map((t) => t.tagName).toList()..sort(), ['Boxed', 'Live', 'Off'],
        reason: 'no second tag with the Tag ID Boxed');
    expect(animals.map((a) => a.name), ['Sage']);
    expect(deployments.single.tagId, 'tag-boxed',
        reason: 'what Quick add does with a reused tag: the new animal wears it');
    expect(
      await tester.runAsync(
        () => container.read(lastObservationTagIdProvider.future),
      ),
      'tag-boxed',
      reason: 'the wheel starts on the tag the person chose to use',
    );
  });

  // =====================================================================
  // 7. A draft that outlived a deployment.
  // =====================================================================
  testWidgets('a no-signal draft that still names a collar taken off since '
      'is pruned to what the checklist shows, before it can be saved',
      (tester) async {
    // The draft persists across days. Tick the collar that came off last
    // month *before* the screen is built — what Tuesday's draft looks like
    // on Wednesday — and the screen must not carry it into the record.
    final container = await setUpScreen(tester, recordType: RecordType.noSignal);
    container.read(observationFormProvider.notifier)
        .setNoSignalTags(['tag-live', 'tag-off', 'tag-boxed']);
    await tester.pumpAndSettle();
    expect(container.read(observationFormProvider).value!.noSignalTagIds, ['tag-live'],
        reason: 'the ids the checklist cannot show are gone from the draft, '
            'so the count, the ticks and the record agree');
    expect(find.text('TAGS NOT HEARD (1)'), findsOneWidget);
  });
}

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/project_time_zone_provider.dart';
import 'package:tritrack/core/time/device_time_zone.dart';
import 'package:tritrack/core/providers/individuals_provider.dart';
import 'package:tritrack/core/providers/tag_view_refresh.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/deployment.dart';
import 'package:tritrack/data/repositories/deployment_linking.dart'
    show formatLinkInstant;
import 'package:tritrack/data/repositories/deployment_repository.dart';
import 'package:tritrack/data/repositories/individual_repository.dart';
import 'package:tritrack/data/repositories/tag_library_repository.dart';
import 'package:tritrack/data/repositories/tag_repository.dart';
import 'package:tritrack/features/more/screens/animal_detail_screen.dart';
import 'package:tritrack/features/more/screens/animals_screen.dart';
import 'package:tritrack/features/more/screens/tag_database_screen.dart'
    show tagLibraryProvider;
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart' show phoneSize;
import '../../support/fake_shared_preferences.dart';

/// **Task 11.244 — More → Animals, and §5a's linking flow on a screen.**
///
/// Michael's case throughout: Marie is wearing 150.321 and is about to be
/// recaptured and given 150.523. Kea is a second animal wearing nothing, and
/// 150.700 is a collar on the shelf.
///
/// The two assertions this file exists for are the same pair
/// `deployment_linking_test.dart` holds, one layer up: **the recapture goes
/// through on the screen**, and **the confirmation names the collar the
/// person did not touch** before it does.
void main() {
  setUp(installFakeSharedPreferences);

  const projectId = 'project-1';
  const owner = 'user-owner';
  late ProviderContainer container;
  late AppDatabase database;

  Future<void> resolve() async {
    container.listen(projectTagsProvider(projectId), (_, _) {});
    await container.read(projectTagsProvider(projectId).future);
    container.listen(projectIndividualsProvider(projectId), (_, _) {});
    await container.read(projectIndividualsProvider(projectId).future);
    container.listen(projectDeploymentsProvider(projectId), (_, _) {});
    await container.read(projectDeploymentsProvider(projectId).future);
    container.listen(myProjectStandingProvider(projectId), (_, _) {});
    await container.read(myProjectStandingProvider(projectId).future);
    container.listen(isProjectOwnerProvider(projectId), (_, _) {});
    await container.read(isProjectOwnerProvider(projectId).future);
    container.listen(tagLibraryProvider, (_, _) {});
    await container.read(tagLibraryProvider.future);
    // Task 11.331: the project's zone, which the screen reads "today" in.
    container.listen(projectTimeZoneProvider(projectId), (_, _) {});
    await container.read(projectTimeZoneProvider(projectId).future);
  }

  /// Seeds the project and returns a container the screens can be pumped in.
  ///
  /// [wearing] is Marie's open deployment — the row §5a's rule 2 closes.
  Future<void> seed(
    WidgetTester tester, {
    ProjectRole role = ProjectRole.owner,
    bool wearing = true,

    /// Seeds Marie a deployment with no attached date — design §4's case,
    /// which covers no interval and attributes nothing. Seeded here rather
    /// than written after the pump, because the providers resolve once in
    /// this helper and a row inserted afterwards would not be in them.
    bool undated = false,
  }) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const creator = 'user-creator';
    // Task 11.331: the project's zone is this process's own, so every date
    // this file computes with the phone's clock is the field's date too —
    // which is what these tests were written to assume, and what the clock
    // matrix varies. `field_zone_screen_test.dart` is where the two differ.
    final project = sampleProject(
      id: projectId,
      ownerUserId: role == ProjectRole.owner ? owner : creator,
    ).copyWith(timeZone: deviceTimeZone());
    container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentProjectProvider.overrideWith((ref) async => project),
        currentUserProvider.overrideWith(
          (ref) async => sampleUser(id: owner, email: 'owner@x.com'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      database = await container.read(appDatabaseProvider.future);
      final db = database.raw;
      await db.insert(
        Tables.users,
        sampleUser(id: owner, email: 'owner@x.com').toColumns(),
      );
      if (role != ProjectRole.owner) {
        await db.insert(
          Tables.users,
          sampleUser(id: creator, email: 'creator@x.com').toColumns(),
        );
      }
      await db.insert(Tables.projects, project.toColumns());
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(userId: owner, role: role).toColumns(),
      );
      if (role != ProjectRole.owner) {
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            id: 'm-creator',
            userId: creator,
            role: ProjectRole.owner,
          ).toColumns(),
        );
      }
      final seeder = role == ProjectRole.owner ? owner : creator;
      final individuals = IndividualRepository(db);
      await individuals.insert(
        sampleIndividual(id: 'marie', name: 'Marie', modifiedBy: seeder),
      );
      await individuals.insert(
        sampleIndividual(
          id: 'kea',
          name: 'Kea',
          colorHex: TagColorPalette.colors[1],
          modifiedBy: seeder,
        ),
      );
      for (final (id, freq) in [
        ('collar-a', 150.321),
        ('collar-b', 150.523),
        ('collar-c', 150.700),
      ]) {
        await db.insert(
          Tables.tags,
          sampleTag(
            id: id,
            tagName: freq.toStringAsFixed(3),
            frequencyMhz: freq,
            modifiedBy: seeder,
          ).toColumns(),
        );
      }
      if (wearing) {
        await DeploymentRepository(db).link(
          sampleDeployment(
            id: 'marie-current',
            tagId: 'collar-a',
            individualId: 'marie',
            attachedDate: DateTime(2026, 1, 15),
            modifiedBy: seeder,
          ),
        );
      }
      if (undated) {
        await DeploymentRepository(db).link(
          sampleDeployment(
            id: 'undated',
            tagId: 'collar-c',
            individualId: 'marie',
            noAttachedDate: true,
            modifiedBy: seeder,
          ),
        );
      }
      await resolve();
    });
  }

  Future<void> pumpList(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: AnimalsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDetail(WidgetTester tester, String id) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: AnimalDetailScreen(individualId: id)),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Runs an interaction on the real clock, the way the sibling animal tests
  /// do: these screens do sqflite round trips and a widget test's fake clock
  /// never finishes one (see CLAUDE.md).
  Future<void> act(WidgetTester tester, Future<void> Function() body) async {
    await tester.runAsync(() async {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      await resolve();
    });
    await tester.pumpAndSettle();
  }

  /// **Task 11.268, item 3**: a deployment row's actions moved behind a `⋮`
  /// menu. Every test that used to tap `set_attached_<id>` etc. directly now
  /// opens the menu for that row first — the item is not in the tree until
  /// then.
  Future<void> openDeploymentMenu(WidgetTester tester, String deploymentId) async {
    await tester.tap(find.byKey(ValueKey('deployment_menu_$deploymentId')));
    await tester.pumpAndSettle();
  }

  group('the list', () {
    testWidgets('every animal is a row, with its status and tag count',
        (tester) async {
      await seed(tester);
      await pumpList(tester);

      expect(find.byKey(const ValueKey('animals_row_marie')), findsOneWidget);
      expect(find.byKey(const ValueKey('animals_row_kea')), findsOneWidget);
      expect(find.text('Marie'), findsOneWidget);
      expect(find.textContaining('1 tag'), findsOneWidget);
      expect(
        find.textContaining('0 tags'),
        findsOneWidget,
        reason:
            'an animal with no tag is an ordinary row, not a '
            'half-finished one — design §1 from the other side',
      );
    });

    testWidgets('the + is a FloatingActionButton in the lower right, '
        'matching the rest of the app', (tester) async {
      // Task 11.248: "every other screen puts + in the lower right" — read
      // from the code, `projects_screen.dart` and `tag_database_screen.dart`
      // both use a bare FloatingActionButton(child: Icon(Icons.add)).
      await seed(tester);
      await pumpList(tester);

      final fab = tester.widget<FloatingActionButton>(
        find.byKey(const ValueKey('add_animal')),
      );
      expect(fab.onPressed, isNotNull);
      expect(find.text('Add animal'), findsNothing);
    });

    testWidgets('Add animal creates one, and it is unknown rather than alive',
        (tester) async {
      await seed(tester);
      await pumpList(tester);

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('add_animal')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('new_animal_name')),
          'Ruru',
        );
        await tester.tap(find.byKey(const ValueKey('new_animal_add')));
      });

      final stored = await tester.runAsync(
        () => IndividualRepository(database.raw).findByProject(projectId),
      );
      final ruru = stored!.firstWhere((i) => i.name == 'Ruru');
      expect(
        ruru.status,
        IndividualStatus.unknown,
        reason:
            'nothing has been observed about this animal — `unknown` is the '
            'honest default (design §5), and nothing derives it from a '
            "tag's status because there is no tag",
      );
      expect(find.text('Ruru'), findsOneWidget);
    });

    testWidgets('a viewer cannot add an animal, the + is disabled and the '
        'reason is on the screen — never a tooltip', (tester) async {
      await seed(tester, role: ProjectRole.viewer);
      await pumpList(tester);

      final fab = tester.widget<FloatingActionButton>(
        find.byKey(const ValueKey('add_animal')),
      );
      expect(fab.onPressed, isNull);
      expect(find.textContaining('Viewers cannot add an animal'), findsOneWidget);
      expect(
        find.byType(Tooltip),
        findsNothing,
        reason: 'a disabled control says why on the screen, never in a '
            'tooltip — disabled_reason.dart',
      );
    });
  });

  group('an animal, and its tags', () {
    testWidgets('the tags are listed with their dates', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      expect(find.text('Tags'), findsOneWidget);
      expect(find.textContaining('150.321'), findsOneWidget);
      expect(
        find.textContaining('On since 2026-01-15'),
        findsOneWidget,
        reason: 'an open deployment says so rather than showing a blank',
      );
    });

    testWidgets('an animal with no tag says so', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'kea');
      expect(find.text('No tag has been on this animal.'), findsOneWidget);
    });

    testWidgets('DELIBERATE: a tag with no attached date says it is on no '
        'bearings', (tester) async {
      // Design §4's counter-intuitive case, on a screen. A row that simply
      // left the date blank would leave somebody to discover from a map with
      // fewer rays than expected that the deployment attributes nothing.
      await seed(tester, wearing: false, undated: true);
      await pumpDetail(tester, 'marie');
      expect(
        find.textContaining('this tag is on no bearings'),
        findsOneWidget,
      );
    });

    testWidgets('the current tag is first and marked, derived from dates '
        'rather than row order', (tester) async {
      // `DeploymentRepository.findByProject` orders oldest-attached-first, so
      // the provider hands the screen the *closed* deployment before the
      // *open* one — "call the first row current" would name the wrong tag.
      // Only reading the dates (no removed date, or the interval contains
      // today) gets it right.
      await seed(tester);
      await tester.runAsync(() async {
        await DeploymentRepository(database.raw).link(
          sampleDeployment(
            id: 'marie-earlier',
            tagId: 'collar-c',
            individualId: 'marie',
            attachedDate: DateTime(2025, 6, 1),
            removedDate: DateTime(2025, 12, 1),
            modifiedBy: owner,
          ),
        );
        // `DeploymentRepository.link` does not itself announce `DataArrival`
        // — `seed`'s own deployments work because they are written before
        // the first `resolve()` ever runs. This one is added afterwards, so
        // it needs the same nudge a real screen gets from `refreshTagViews`.
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');

      final cards = tester.widgetList<Card>(find.byType(Card)).toList();
      expect(cards, hasLength(2), reason: 'two deployment rows');
      // The open one (collar-a, no removed date) is current — not the
      // earlier, closed one the raw query lists first.
      expect(find.text('Current'), findsOneWidget);
      final currentRow = find.ancestor(
        of: find.text('Current'),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(of: currentRow, matching: find.textContaining('150.321')),
        findsOneWidget,
        reason: 'the open deployment is current, not the closed one that '
            'sorts first by attached date',
      );
      expect(
        tester.getTopLeft(currentRow).dy,
        lessThan(tester.getTopLeft(find.byType(Card).last).dy),
        reason: 'current sorts first on screen, opposite the raw row order',
      );
    });

    testWidgets('the attached date is editable, and a back-dated edit that '
        'creates an overlap is refused', (tester) async {
      await seed(tester);
      // A second deployment whose attached date already overlaps
      // 'marie-current' (open since 2026-01-15). Written straight to the table — bypassing
      // `DeploymentRepository.link`'s own interlock check — the way a row
      // from an older device or a broken sync could arrive: already wrong,
      // and waiting for somebody to touch it.
      await tester.runAsync(() async {
        await database.raw.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'marie-second',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: DateTime(2026, 1, 20),
            modifiedBy: owner,
          ).toColumns(),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');

      expect(
        find.byKey(const ValueKey('deployment_menu_marie-second')),
        findsOneWidget,
        reason: 'attached date is editable, same as removed date',
      );
      final before = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-second', projectId: projectId),
      );

      // WATCHED RED: open the date picker and confirm the pre-filled date
      // (the row's own already-conflicting attached date) unchanged — an
      // edit that re-saves it must still be checked, and refused with the
      // same sentence a link gets. The row on screen must not move.
      //
      // **The whole interaction is one `runAsync` block**, from the tap that
      // starts `_setAttached` through the tap that lets its `await`s past
      // the database resolve. `_setAttached`'s continuation keeps whatever
      // zone was current when the first tap invoked it — wrapping only the
      // later tap leaves the real `repo.update()` call awaiting inside the
      // fake-async zone, where it never completes (CLAUDE.md: never await
      // the database from the test body).
      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-second');
        await tester.tap(
          find.byKey(const ValueKey('set_attached_marie-second')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      // Not `act()`/`pumpAndSettle()` from here — either would run real time
      // forward far enough for the SnackBar's own auto-dismiss timer to
      // finish, leaving nothing to assert on.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        find.textContaining('wearing two tags at once'),
        findsOneWidget,
        reason: 'the interlock applies to an edit exactly as it does to a '
            'link — §6, and the screen shows the same refusal sentence',
      );
      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-second', projectId: projectId),
      );
      expect(
        after!.attachedDate,
        before!.attachedDate,
        reason: 'a refused edit must not change the row',
      );
    });
  });

  group('§5a — linking a tag', () {
    testWidgets('THE RECAPTURE: the confirmation names the collar the person '
        'did not touch, and the link goes through', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');
      // Truncated to the second, the same way the written instant is, so a
      // link that starts and is written inside one second still compares.
      final t = clock.now();
      final startedAt = DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await tester.pumpAndSettle();
        // Only the free collars are offered: 150.321 is on Marie today.
        // **Scoped to the dialog** — the collar's own row is on the screen
        // behind it, which is the whole point of the screen.
        final dialog = find.byType(SimpleDialog);
        expect(
          find.descendant(of: dialog, matching: find.text('150.523 MHz · 150.523')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('150.700 MHz · 150.700')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: dialog, matching: find.text('150.321 MHz · 150.321')),
          findsNothing,
          reason:
              'offering a collar the interlock would refuse a moment later '
              'wastes the time this whole flow exists to save',
        );
        await tester.tap(find.byKey(const ValueKey('link_tag_collar-b')));
        await tester.pumpAndSettle();
      });

      // **The sentence §5a asks for**, before anything is written.
      expect(find.textContaining('Link 150.523 to Marie, attached'), findsOneWidget);
      expect(
        find.textContaining("Marie's 150.321 will be recorded as removed"),
        findsOneWidget,
        reason: 'the confirmation is not politeness — it exists because this '
            'writes to a row the person did not touch',
      );
      expect(
        find.textContaining('a record you did not open'),
        findsOneWidget,
      );
      // Nothing has happened yet.
      final before = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('marie', projectId: projectId),
      );
      expect(before, hasLength(1));
      expect(before!.single.removedDate, isNull);

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('confirm_link')));
      });

      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('marie', projectId: projectId),
      );
      expect(after, hasLength(2));
      final old = after!.firstWhere((d) => d.deploymentId == 'marie-current');
      expect(
        old.removedDate,
        isNotNull,
        reason: "the old collar came off as the new one went on — §5a's rule 2",
      );
      final now = after.firstWhere((d) => d.tagId == 'collar-b');
      expect(now.removedDate, isNull);
      expect(
        now.attachedDate!.difference(old.removedDate!).inDays,
        0,
        reason:
            'the same instant: an overlap of nothing — the interlock never '
            'fires on the ordinary case (and since task 11.263 it tolerates '
            'no overlap at all, so the time is what makes this pass)',
      );
      // **§4a rule 2 (task 11.251): a swap carries a time, and the same
      // instant closes the outgoing collar and opens the incoming one.**
      // The confirmation offered it prefilled with now, and the person
      // accepted it with the same tap they always made.
      expect(
        deploymentEndHasTime(now.attachedDate!),
        isTrue,
        reason: 'the incoming end is an instant, not a bare day',
      );
      expect(
        now.attachedDate!.isAtSameMomentAs(old.removedDate!),
        isTrue,
        reason: 'the two ends cannot disagree — they are one value',
      );
      expect(
        deploymentDateFor(now.attachedDate!),
        deploymentDateFor(clock.now()),
        reason: 'and it is today, the day the plan named',
      );
      // **To the second, not rounded down to the minute** — Michael's grey
      // bearing on B, 2026-09-15: a swap written as the start of its minute
      // sits *before* a bearing taken seconds earlier in that minute, and
      // that bearing then belongs to nobody. The instant must not precede
      // the moment this test started the link.
      expect(
        now.attachedDate!.isBefore(startedAt),
        isFalse,
        reason: 'a swap confirmed at 14:32:50 is 14:32:50, not 14:32:00 — '
            'written ${now.attachedDate}, the link started at $startedAt',
      );
    });

    testWidgets('THE SWAP TIME: the recapture confirmation shows a time, '
        'prefilled with now, with a way to change it', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link_tag_collar-b')));
        await tester.pumpAndSettle();
      });

      // The sentence carries the instant — `2026-09-15 14:32`, not a bare
      // date — on both ends, and the button is there for the person who got
      // to the truck an hour after the swap.
      final timed = RegExp(r'attached \d{4}-\d{2}-\d{2} \d{2}:\d{2}\.');
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && timed.hasMatch(w.data ?? ''),
        ),
        findsOneWidget,
        reason: 'the confirmation names the time it will write',
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Text &&
              RegExp(r'removed \d{4}-\d{2}-\d{2} \d{2}:\d{2}\.')
                  .hasMatch(w.data ?? ''),
        ),
        findsOneWidget,
        reason: 'and the same time for the collar that comes off',
      );
      expect(find.byKey(const ValueKey('change_swap_time')), findsOneWidget);
      expect(find.text('Change time'), findsOneWidget);
    });

    testWidgets('an animal wearing nothing gets a one-line confirmation',
        (tester) async {
      await seed(tester, wearing: false);
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link_tag_collar-a')));
      });

      expect(find.textContaining('Link 150.321 to Marie, attached'), findsOneWidget);
      expect(
        find.textContaining('will be recorded as removed'),
        findsNothing,
        reason: 'there is nothing unexpected to warn about',
      );
      // **And no time** (task 11.251): a collar from the shelf onto a bare
      // animal is not a swap, and a time there could only lose the
      // morning's bearings to nobody. The date stays a whole day.
      expect(find.byKey(const ValueKey('change_swap_time')), findsNothing);
      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('confirm_link')));
      });
      final written = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('marie', projectId: projectId),
      );
      expect(deploymentEndHasTime(written!.single.attachedDate!), isFalse,
          reason: 'date-only, exactly as before this task');
    });

    testWidgets("THE TAG'S SWAP: a collar taken off Kea today is offered for "
        'Marie today, and the confirmation offers the time even though Marie '
        'wears nothing', (tester) async {
      // Michael's own flow, 2026-09-15: tag 2 comes off animal B on B's
      // screen (a removed date, today), then goes onto animal A here. A has
      // nothing to close, so §5a's sentence is one line — but this *is* a
      // swap, and without a time every bearing tag 2 took today after the
      // link would be contested between the two animals.
      //
      // **Task 11.263: the removal on B's screen carries a time.** With the
      // one-day allowance gone, a removal recorded as a bare day covers the
      // whole of today and makes the collar busy all day — asserted in the
      // next test. The rule is that a same-day handover requires a time, and
      // B's screen offered one prefilled with now.
      //
      // **"An hour ago" only if that is still today** (task 11.273, the same
      // shape task 11.269 found in `seedTouchingPair`). Run this suite within
      // an hour of local midnight and `DateTime.now().subtract(1h)` lands on
      // yesterday — `_departureOn` correctly reads that as a different day
      // from today's `attachedDate` and this stops being a same-day swap at
      // all, so the test's own assumption breaks, not the app. Clamped to one
      // minute after local midnight instead, which stays earlier than `now`
      // and stays today.
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        final now = clock.now();
        final wanted = now.subtract(const Duration(hours: 1));
        final removed = deploymentDateFor(wanted).isAtSameMomentAs(
          deploymentDateFor(now),
        )
            ? wanted
            : DateTime(now.year, now.month, now.day, 0, 1);
        await DeploymentRepository(database.raw).link(
          sampleDeployment(
            id: 'kea-until-today',
            tagId: 'collar-a',
            individualId: 'kea',
            attachedDate: DateTime(2026, 1, 15),
            removedDate: removed,
            modifiedBy: owner,
          ),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await tester.pumpAndSettle();
        // **Offered.** The picker asks the interlock's own arithmetic, with
        // the instant the swap would carry: the collar came off an hour ago
        // and goes on now.
        expect(
          find.descendant(
            of: find.byType(SimpleDialog),
            matching: find.byKey(const ValueKey('link_tag_collar-a')),
          ),
          findsOneWidget,
          reason: 'removed an hour ago is free to link now — the same-day move',
        );
        await tester.tap(find.byKey(const ValueKey('link_tag_collar-a')));
        await tester.pumpAndSettle();
      });

      expect(find.textContaining('will be recorded as removed'), findsNothing,
          reason: 'Marie wears nothing; there is no second row to amend');
      expect(find.byKey(const ValueKey('change_swap_time')), findsOneWidget,
          reason: 'but the collar came off another animal today, so the time '
              'is what says whose the afternoon\'s bearings are');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('confirm_link')));
      });
      final hers = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('marie', projectId: projectId),
      );
      expect(deploymentEndHasTime(hers!.single.attachedDate!), isTrue);
    });

    testWidgets("a collar taken off Kea today as a BARE DAY is not offered "
        'for Marie today (task 11.263) — a same-day handover requires a time, '
        'and the way in is a time on the removal', (tester) async {
      // The consequence of design §6a a reader will take for a defect, so it
      // is pinned with its reason: Kea's removal covers the whole of today,
      // any deployment of collar-a starting today would share some of it,
      // and the write would refuse — so the picker withholds the collar
      // rather than offer a refusal. Nothing on Marie's screen says why;
      // the picker hides, it does not explain. The repair is on Kea's
      // screen: Edit removed date → today → Set a time.
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        await DeploymentRepository(database.raw).link(
          sampleDeployment(
            id: 'kea-until-today',
            tagId: 'collar-a',
            individualId: 'kea',
            attachedDate: DateTime(2026, 1, 15),
            removedDate: deploymentDateFor(clock.now()),
            modifiedBy: owner,
          ),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await tester.pumpAndSettle();
        final dialog = find.byType(SimpleDialog);
        expect(
          find.descendant(
            of: dialog,
            matching: find.byKey(const ValueKey('link_tag_collar-a')),
          ),
          findsNothing,
          reason: 'busy all day: its bare-day removal covers the whole of it',
        );
        // The others are still offered; the dialog is not empty.
        expect(
          find.descendant(
            of: dialog,
            matching: find.byKey(const ValueKey('link_tag_collar-b')),
          ),
          findsOneWidget,
        );
      });
    });

    testWidgets('cancelling writes nothing', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link_tag_collar-b')));
        // The confirmation waits on `plan()`, which is a database read: a
        // `pumpAndSettle` alone does not wait for it, even on the real clock.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cancel_link')));
      });

      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('marie', projectId: projectId),
      );
      expect(after, hasLength(1));
      expect(after!.single.removedDate, isNull);
    });
  });

  group('linking in one step (task 11.321)', () {
    // Michael, 2026-09-30: linking a tag took three places — the Tag Library,
    // the project, then the animal. Kea wears nothing; the library holds
    // Rex (150.900, on no project) and a library copy of 150.700's collar,
    // which the project already has and so is not offered twice.
    Future<void> seedLibrary(WidgetTester tester) async {
      await tester.runAsync(() async {
        final library = TagLibraryRepository(database.raw);
        await library.insert(sampleTagLibraryEntry(
          id: 'lib-rex',
          lineageId: 'l-rex',
          tagName: 'Rex',
          frequencyMhz: 150.900,
        ));
        await library.insert(sampleTagLibraryEntry(
          id: 'lib-c',
          lineageId: 'collar-c',
          tagName: '150.700',
          frequencyMhz: 150.700,
        ));
        container.invalidate(tagLibraryProvider);
        await resolve();
      });
    }

    testWidgets('WATCHED RED: the picker offers this project\'s tags, then the '
        'Tag Library\'s, then New tag…', (tester) async {
      await seed(tester);
      await seedLibrary(tester);
      await pumpDetail(tester, 'kea');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });
      final dialog = find.byType(SimpleDialog);
      final texts = [
        for (final w in tester.widgetList<Text>(
          find.descendant(of: dialog, matching: find.byType(Text)),
        ))
          w.data,
      ];
      expect(texts, [
        'Which tag goes on Kea?',
        'On this project',
        '150.523 MHz · 150.523',
        '150.700 MHz · 150.700',
        'From your Tag Library',
        '150.900 MHz · Rex',
        'New tag…',
      ], reason: 'Michael\'s order; 150.321 is on Marie, and the library\'s '
          'copy of 150.700 is already this project\'s 150.700');
    });

    testWidgets('a Tag Library tag is copied in and linked in one action',
        (tester) async {
      await seed(tester);
      await seedLibrary(tester);
      await pumpDetail(tester, 'kea');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link_library_lib-rex')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });
      expect(find.textContaining('Link Rex to Kea, attached'), findsOneWidget);
      expect(find.byKey(const ValueKey('link_copies_tag')), findsOneWidget,
          reason: 'the copy is said at the moment the person reads (§2.5)');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('confirm_link')));
      });
      final tags = await tester.runAsync(
        () => TagRepository(database.raw).findByProject(projectId),
      );
      final rex = tags!.singleWhere((t) => t.tagName == 'Rex');
      expect(rex.lineageId, 'l-rex');
      final hers = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('kea', projectId: projectId),
      );
      expect(hers!.single.tagId, rex.tagId);
    });

    testWidgets('cancelling the confirmation copies nothing in', (tester) async {
      await seed(tester);
      await seedLibrary(tester);
      await pumpDetail(tester, 'kea');
      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link_library_lib-rex')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cancel_link')));
      });
      final tags = await tester.runAsync(
        () => TagRepository(database.raw).findByProject(projectId),
      );
      expect(tags!.where((t) => t.tagName == 'Rex'), isEmpty);
    });

    testWidgets('New tag… creates the tag on the project and links it',
        (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'kea');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link_new_tag')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });
      expect(find.text('Also add to project'), findsNothing,
          reason: 'the tag goes on this animal\'s project; there is no choice');
      await act(tester, () async {
        await tester.enterText(
          find.widgetWithText(TextField, 'Tag ID'),
          'Zed',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Frequency (MHz)'),
          '151.111',
        );
        await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Save'),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });
      expect(find.textContaining('Link Zed to Kea, attached'), findsOneWidget);
      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('confirm_link')));
      });
      final tags = await tester.runAsync(
        () => TagRepository(database.raw).findByProject(projectId),
      );
      final zed = tags!.singleWhere((t) => t.tagName == 'Zed');
      expect(zed.frequencyMhz, 151.111);
      final hers = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('kea', projectId: projectId),
      );
      expect(hers!.single.tagId, zed.tagId);
    });

    testWidgets('WATCHED RED (task 11.324): New tag… with a Tag ID this '
        'project already has offers the existing tag by default, and using '
        'it links that tag and creates nothing', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'kea');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('link_new_tag')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextField, 'Tag ID'),
          '150.523',
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Frequency (MHz)'),
          '151.111',
        );
        await tester.tap(find.descendant(
          of: find.byType(AlertDialog),
          matching: find.widgetWithText(FilledButton, 'Save'),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });
      // Michael's rule: the existing tag is the default, the second tag is
      // the deliberate choice.
      expect(
        find.widgetWithText(FilledButton, 'Use the existing tag'),
        findsOneWidget,
      );
      expect(find.widgetWithText(TextButton, 'Create anyway'), findsOneWidget);
      await act(tester, () async {
        await tester.tap(
          find.widgetWithText(FilledButton, 'Use the existing tag'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });
      expect(find.textContaining('Link 150.523 to Kea, attached'),
          findsOneWidget);
      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('confirm_link')));
      });
      final tags = await tester.runAsync(
        () => TagRepository(database.raw).findByProject(projectId),
      );
      expect(tags!.where((t) => t.tagName == '150.523'), hasLength(1),
          reason: 'no second tag with the same Tag ID');
      expect(tags.where((t) => t.frequencyMhz == 151.111), isEmpty);
      final hers = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('kea', projectId: projectId),
      );
      expect(hers!.single.tagId, 'collar-b');
    });
  });

  group('linking on a date the person chooses (task 11.322)', () {
    // Michael, 2026-09-30: a collar is sometimes entered a day or two after it
    // went on, and the bearings in between must get the right animal. The
    // link defaults to today and the date can be changed, with every rule a
    // link already had. "Now" is pinned to 2026-03-20 14:00 so the date
    // picker opens in March whatever day the suite runs.
    final pinned = DateTime(2026, 3, 20, 14);

    Future<void> openConfirmation(
      WidgetTester tester,
      String animalId,
      String tagId,
    ) async {
      await pumpDetail(tester, animalId);
      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('link_tag')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('link_tag_$tagId')));
      });
    }

    /// Opens the date picker from the confirmation and taps March [day].
    Future<void> changeDateTo(WidgetTester tester, int day) async {
      await tester.tap(find.byKey(const ValueKey('link_change_date')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('$day'));
      await tester.pumpAndSettle();
      await act(tester, () async {
        await tester.tap(find.text('OK'));
      });
      // The picker closing resumes the screen on the fake clock, and it then
      // re-plans the link against the database, which needs real time.
      await act(tester, () async {});
    }

    Future<List<Deployment>> written(WidgetTester tester, String animalId) async {
      return (await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual(animalId, projectId: projectId),
      ))!;
    }

    testWidgets('the date is today unless it is changed, and says so',
        (tester) async {
      await withClock(Clock.fixed(pinned), () async {
        await seed(tester, wearing: false);
        await openConfirmation(tester, 'kea', 'collar-a');

        expect(find.byKey(const ValueKey('link_date')), findsOneWidget);
        expect(find.text('2026-03-20 (today)'), findsOneWidget);
        await act(tester, () async {
          await tester.tap(find.byKey(const ValueKey('confirm_link')));
        });
        final rows = await written(tester, 'kea');
        expect(formatLinkInstant(rows.single.attachedDate!), '2026-03-20');
      });
    });

    testWidgets('WATCHED RED: a back-dated link that overlaps another '
        "animal's deployment of the tag is refused, and writes nothing",
        (tester) async {
      await withClock(Clock.fixed(pinned), () async {
        await seed(tester, wearing: false);
        await tester.runAsync(() async {
          // Collar B was on Marie from 1 to 12 March, and is free now.
          await DeploymentRepository(database.raw).link(sampleDeployment(
            id: 'marie-b',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: DateTime(2026, 3, 1),
            removedDate: DateTime(2026, 3, 12, 9),
            modifiedBy: owner,
          ));
          refreshTagViewsIn(container, projectId: projectId);
          await resolve();
        });
        await openConfirmation(tester, 'kea', 'collar-b');
        await changeDateTo(tester, 10);

        expect(find.textContaining('attached 2026-03-10'), findsOneWidget);
        await act(tester, () async {
          await tester.tap(find.byKey(const ValueKey('confirm_link')));
        });

        expect(find.byType(SnackBar), findsOneWidget,
            reason: 'the interlock refuses 10 March: Marie wore collar B '
                'until the 12th');
        expect(await written(tester, 'kea'), isEmpty,
            reason: 'a refused link writes nothing');
      });
    });

    testWidgets('a back-dated link on an animal wearing nothing writes the '
        'chosen day, as a day', (tester) async {
      await withClock(Clock.fixed(pinned), () async {
        await seed(tester, wearing: false);
        await openConfirmation(tester, 'kea', 'collar-a');
        await changeDateTo(tester, 10);

        expect(find.text('2026-03-10'), findsOneWidget);
        expect(find.textContaining('(today)'), findsNothing);
        expect(find.byKey(const ValueKey('change_swap_time')), findsNothing,
            reason: 'nothing else is on this animal, so there is no swap '
                'and no time to name');
        await act(tester, () async {
          await tester.tap(find.byKey(const ValueKey('confirm_link')));
        });
        final rows = await written(tester, 'kea');
        expect(rows.single.attachedDate, isNotNull);
        expect(formatLinkInstant(rows.single.attachedDate!), '2026-03-10');
        expect(deploymentEndHasTime(rows.single.attachedDate!), isFalse);
      });
    });

    testWidgets('a back-dated swap asks for a time (noon, never the wall '
        'clock), names the bearings it moves, and writes both ends',
        (tester) async {
      await withClock(Clock.fixed(pinned), () async {
        await seed(tester); // Marie wears collar-a since 15 January.
        await tester.runAsync(() async {
          await database.raw.insert(
            Tables.observations,
            sampleObservation(
              id: 'obs-after',
              userId: owner,
              tagId: 'collar-a',
              sessionId: null,
              tagVersionId: null,
              timestampUtc: DateTime(2026, 3, 15, 12),
            ).toColumns(),
          );
        });
        await openConfirmation(tester, 'marie', 'collar-b');

        await tester.tap(find.byKey(const ValueKey('link_change_date')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await act(tester, () async {
          await tester.tap(find.text('OK'));
        });
        await act(tester, () async {});
        expect(find.byType(TimePickerDialog), findsOneWidget,
            reason: 'the old collar comes off as the new one goes on, so '
                'a bare 10 March would overlap itself');
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();

        expect(find.textContaining('attached 2026-03-10 12:00'), findsOneWidget,
            reason: 'noon, offered as a question — 14:00 is the wall clock '
                'and must not appear');
        await act(tester, () async {
          await tester.tap(find.byKey(const ValueKey('confirm_link')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });

        expect(
          find.text('This changes which animal some bearings belong to'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            '1 bearing taken on 150.321 since 2026-03-10 will no longer be '
            'credited to Marie.',
          ),
          findsOneWidget,
        );
        await act(tester, () async {
          await tester.tap(find.byKey(const ValueKey('confirm_reattribution')));
        });

        final rows = await written(tester, 'marie');
        final old = rows.firstWhere((d) => d.tagId == 'collar-a');
        final added = rows.firstWhere((d) => d.tagId == 'collar-b');
        expect(formatLinkInstant(old.removedDate!), '2026-03-10 12:00');
        expect(formatLinkInstant(added.attachedDate!), '2026-03-10 12:00');
      });
    });

    testWidgets('Cancel at the bearings warning writes nothing',
        (tester) async {
      await withClock(Clock.fixed(pinned), () async {
        await seed(tester);
        await tester.runAsync(() async {
          await database.raw.insert(
            Tables.observations,
            sampleObservation(
              id: 'obs-after',
              userId: owner,
              tagId: 'collar-a',
              sessionId: null,
              tagVersionId: null,
              timestampUtc: DateTime(2026, 3, 15, 12),
            ).toColumns(),
          );
        });
        await openConfirmation(tester, 'marie', 'collar-b');
        await tester.tap(find.byKey(const ValueKey('link_change_date')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await act(tester, () async {
          await tester.tap(find.text('OK'));
        });
        await act(tester, () async {});
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await act(tester, () async {
          await tester.tap(find.byKey(const ValueKey('confirm_link')));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });
        await act(tester, () async {
          await tester.tap(find.text('Cancel'));
        });

        final rows = await written(tester, 'marie');
        expect(rows.single.tagId, 'collar-a');
        expect(rows.single.removedDate, isNull,
            reason: 'the old collar is still on, untouched');
      });
    });

    testWidgets("the date cannot go before the animal's current tag went on, "
        'and the picker says why', (tester) async {
      await withClock(Clock.fixed(pinned), () async {
        await seed(tester); // collar-a on Marie since 2026-01-15
        await openConfirmation(tester, 'marie', 'collar-b');
        await tester.tap(find.byKey(const ValueKey('link_change_date')));
        await tester.pumpAndSettle();

        expect(
          find.textContaining(
            'Not before the current tag went on, 2026-01-15',
          ),
          findsOneWidget,
        );
      });
    });
  });

  group("Michael's device look, 2026-09-15 — three things on the animal's "
      'screen after a same-day swap', () {
    // Tag 3 was linked to B, closing tag 2 at 14:32. Michael saw tag 2 still
    // marked Current beside tag 3, tag 3 listed *below* tag 2, and the row's
    // buttons running off the right edge of the phone.
    Future<void> seedSwap(WidgetTester tester) async {
      await seed(tester, wearing: false);
      final now = clock.now();
      final swapAt = now.subtract(const Duration(minutes: 5));
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        await repo.link(sampleDeployment(
          id: 'marie-older',
          tagId: 'collar-c',
          individualId: 'marie',
          attachedDate: DateTime(2025, 6, 1),
          removedDate: DateTime(2025, 12, 1),
          modifiedBy: owner,
        ));
        await repo.link(sampleDeployment(
          id: 'marie-off-today',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
          removedDate: swapAt,
          modifiedBy: owner,
        ));
        await repo.link(sampleDeployment(
          id: 'marie-on-today',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: swapAt,
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
    }

    testWidgets('only the tag that has not come off is Current — the one '
        'taken off five minutes ago is not, however much of today it spans',
        (tester) async {
      await seedSwap(tester);
      await pumpDetail(tester, 'marie');
      expect(find.text('Current'), findsOneWidget);
      final currentRow = find.ancestor(
        of: find.text('Current'),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(of: currentRow, matching: find.textContaining('150.523')),
        findsOneWidget,
        reason: 'tag 3 (150.523) went on at the swap; tag 2 (150.321) came '
            'off at it and is not current, whatever the day-granular '
            'question says',
      );
    });

    testWidgets('a date-only removal dated today is not Current either', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        await DeploymentRepository(database.raw).link(sampleDeployment(
          id: 'off-today-date-only',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
          removedDate: deploymentDateFor(clock.now()),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');
      expect(find.text('Current'), findsNothing,
          reason: 'somebody recorded it as off today; "Current" means not '
              'yet recorded as off');
    });

    testWidgets('the newest tag is on top and the oldest at the bottom', (tester) async {
      await seedSwap(tester);
      await pumpDetail(tester, 'marie');
      double top(String freq) => tester.getTopLeft(find.ancestor(
            of: find.textContaining(freq),
            matching: find.byType(Card),
          ).first).dy;
      expect(top('150.523'), lessThan(top('150.321')),
          reason: 'the tag that went on today is above the one that came off today');
      expect(top('150.321'), lessThan(top('150.700')),
          reason: 'and last year\'s tag is at the bottom');
    });

    testWidgets('the row\'s actions are behind a ⋮ menu that fits a '
        '6.1-inch phone closed, and its opened items fit too (task 11.268)',
        (tester) async {
      await seed(tester);
      tester.view.physicalSize = phoneSize * 3;
      tester.view.devicePixelRatio = 3.0;
      await pumpDetail(tester, 'marie');
      expect(tester.takeException(), isNull,
          reason: 'a RenderFlex overflow is an exception in a widget test');
      final menuButton = tester.getTopRight(
        find.byKey(const ValueKey('deployment_menu_marie-current')),
      );
      expect(menuButton.dx, lessThanOrEqualTo(phoneSize.width),
          reason: 'a menu of one icon fits at every width; the four '
              'buttons it replaces did not');

      await tester.tap(
        find.byKey(const ValueKey('deployment_menu_marie-current')),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull,
          reason: 'a RenderFlex overflow is an exception in a widget test');
      final unlinkItem = tester.getTopRight(
        find.byKey(const ValueKey('unlink_marie-current')),
      );
      expect(unlinkItem.dx, lessThanOrEqualTo(phoneSize.width),
          reason: 'the opened menu itself must fit on Michael\'s phone too');
    });
  });

  group('the removal day carries a time when it is today (task 11.251, '
      'reworked by 11.261)', () {
    testWidgets('Set removed date, today: a choice follows, and Set a time '
        'then OK writes the instant', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');
      final t = clock.now();
      final startedAt = DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-current');
        await tester.tap(find.byKey(const ValueKey('set_removed_marie-current')));
        await tester.pumpAndSettle();
        // The date picker, pre-filled with today.
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        // **The day-or-time choice**, because the day picked is today — the
        // outgoing end of a swap, on the screen of the animal it comes off.
        // Task 11.261: three explicit buttons, not a time picker whose
        // Cancel doubled as "the day alone".
        expect(find.text('When did the tag come off?'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-current', projectId: projectId),
      );
      expect(row!.removedDate, isNotNull);
      expect(deploymentEndHasTime(row.removedDate!), isTrue,
          reason: 'the instant, not midnight');
      expect(row.removedDate!.isBefore(startedAt), isFalse,
          reason: 'accepted as offered: to the second, not the minute\'s start '
              '— written ${row.removedDate}, started $startedAt');
      expect(deploymentDateFor(row.removedDate!), deploymentDateFor(clock.now()));
      // And the row says so — a value that decides which animal an
      // afternoon's bearings belong to is shown, not hidden in a date.
      expect(
        find.textContaining(formatLinkInstant(row.removedDate!)),
        findsOneWidget,
      );
    });

    testWidgets('Day only writes the date with no time, no time picker '
        'opened', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-current');
        await tester.tap(find.byKey(const ValueKey('set_removed_marie-current')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('removed_day_only')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-current', projectId: projectId),
      );
      expect(row!.removedDate, isNotNull, reason: 'the date was chosen');
      expect(deploymentEndHasTime(row.removedDate!), isFalse,
          reason: 'a whole day — what a removal was before this task');
    });

    testWidgets('Cancel abandons the whole edit — nothing is written, '
        'unlike the old "Cancel for the day only"', (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-current');
        await tester.tap(find.byKey(const ValueKey('set_removed_marie-current')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('removed_day_or_time_cancel')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-current', projectId: projectId),
      );
      expect(row!.removedDate, isNull,
          reason: 'a person who wanted to abandon the edit now has a '
              'button that means that, rather than being read as choosing '
              'the day alone');
    });
  });

  group('"Day only" is withheld where it would overlap (task 11.263, design '
      '§6a)', () {
    /// Marie wore collar-a from January until two hours from now, when
    /// collar-b goes on — both timed, touching, legal. Editing collar-a's
    /// removal to today *as a bare day* would cover the whole of today and
    /// overlap collar-b's afternoon; the dialog therefore offers no "Day
    /// only". Setting a time (now) ends collar-a before collar-b starts.
    ///
    /// **"Two hours from now" only if that is still today.** Run this suite
    /// within two hours of local midnight and `DateTime.now().add(2h)`
    /// silently lands on tomorrow — the row is no longer "today" by
    /// [deploymentDateFor], `_setRemoved` correctly takes its past/future-day
    /// branch instead of the today branch, and the test's own assumption
    /// (not the app) is what breaks. Clamped to one minute before local
    /// midnight instead, which stays later than `now` and stays today.
    Future<void> seedTouchingPair(WidgetTester tester) async {
      await seed(tester, wearing: false);
      final now = clock.now();
      final wanted = now.add(const Duration(hours: 2));
      final later = deploymentDateFor(wanted).isAtSameMomentAs(
        deploymentDateFor(now),
      )
          ? wanted
          : DateTime(now.year, now.month, now.day, 23, 59);
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        await repo.link(
          sampleDeployment(
            id: 'marie-a',
            tagId: 'collar-a',
            individualId: 'marie',
            attachedDate: DateTime(2026, 1, 15),
            removedDate: later,
            modifiedBy: owner,
          ),
        );
        await repo.link(
          sampleDeployment(
            id: 'marie-b',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: later,
            modifiedBy: owner,
          ),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');
      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-a');
        await tester.tap(find.byKey(const ValueKey('set_removed_marie-a')));
        await tester.pumpAndSettle();
        // The date picker, pre-filled with the row's own day — today.
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      });
    }

    testWidgets('the choice offers Set a time and Cancel, says why, and has '
        'no Day only', (tester) async {
      await seedTouchingPair(tester);
      expect(find.text('When did the tag come off?'), findsOneWidget);
      expect(find.byKey(const ValueKey('removed_day_only')), findsNothing,
          reason: 'a bare day would overlap collar-b, and the write would '
              'refuse it — a choice that cannot succeed is not offered');
      expect(find.byKey(const ValueKey('removed_pick_time')), findsOneWidget);
      expect(find.byKey(const ValueKey('removed_day_or_time_cancel')),
          findsOneWidget);
      expect(find.textContaining('needs a time'), findsOneWidget,
          reason: 'the sentence says why the day is not on offer');
      // Cancel still abandons — the person who wanted out can get out.
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('removed_day_or_time_cancel')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();
      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-a', projectId: projectId),
      );
      expect(row!.removedDate!.isAfter(clock.now()), isTrue,
          reason: 'nothing was written; the removal is still two hours out');
    });

    testWidgets('Set a time then OK writes the instant, and the pair no '
        'longer overlaps', (tester) async {
      // The floor is taken **before** the helper taps "Set removed date",
      // because that tap is where the screen captures its own `now` (the
      // value `swapInstantNow` writes). Taken afterwards it raced the
      // screen across a whole-second boundary and failed about one run in
      // six (task 11.264, measured 2 of 7).
      final t = clock.now();
      final startedAt = DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
      await seedTouchingPair(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        // The reattribution count is zero here (no bearings), so no second
        // confirmation; the write goes straight through.
        await resolve();
      });
      await tester.pumpAndSettle();
      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-a', projectId: projectId),
      );
      expect(deploymentEndHasTime(row!.removedDate!), isTrue);
      expect(row.removedDate!.isBefore(startedAt), isFalse);
      expect(row.removedDate!.isAfter(clock.now()), isFalse,
          reason: 'now, not the two-hours-out value it had');
    });

    testWidgets('Set a time then cancelling the time picker abandons the '
        'edit — there is no bare day to fall back to', (tester) async {
      await seedTouchingPair(tester);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();
      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-a', projectId: projectId),
      );
      expect(row!.removedDate!.isAfter(clock.now()), isTrue,
          reason: 'where "Day only" was on offer, cancelling the picker '
              'falls back to the day (task 11.261); where it was not, '
              'falling back would write the very thing that was withheld');
    });
  });

  group('re-picking the same attached day keeps the swap time (task '
      '11.264)', () {
    /// The same touching pair as the group above — collar-a off Marie at a
    /// time, collar-b on at that instant — but nothing tapped yet.
    Future<DateTime> seedSwappedPair(WidgetTester tester) async {
      await seed(tester, wearing: false);
      final swap = clock.now().subtract(const Duration(hours: 2));
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        await repo.link(
          sampleDeployment(
            id: 'marie-a',
            tagId: 'collar-a',
            individualId: 'marie',
            attachedDate: DateTime(2026, 1, 15),
            removedDate: swap,
            modifiedBy: owner,
          ),
        );
        await repo.link(
          sampleDeployment(
            id: 'marie-b',
            tagId: 'collar-b',
            individualId: 'marie',
            attachedDate: swap,
            modifiedBy: owner,
          ),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');
      return swap;
    }

    testWidgets('WATCHED RED: Edit attached date, OK on the pre-filled day, '
        'leaves a timed swap as it was — neither refused nor widened to a '
        'bare day', (tester) async {
      final swap = await seedSwappedPair(tester);
      // Before task 11.264 this dropped the time: the incoming collar's
      // start became midnight, which overlaps the outgoing collar's morning
      // under design §6a, and a row that was correct was refused for an
      // edit that changed nothing. Same one-block `runAsync` shape as the
      // back-dated edit test above, and for the same reason.
      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-b');
        await tester.tap(find.byKey(const ValueKey('set_attached_marie-b')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('wearing two tags at once'), findsNothing,
          reason: 'the pair still touches at the swap instant; nothing to '
              'refuse');
      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-b', projectId: projectId),
      );
      expect(row!.attachedDate!.isAtSameMomentAs(swap), isTrue,
          reason: 'the picker offers days, and the person picked the day '
              'the row already had — its time is not theirs to lose');
      expect(deploymentEndHasTime(row.attachedDate!), isTrue);
    });
  });

  group('a past-day handover can be recorded (task 11.265, design §6b)', () {
    /// **Why the "other" row starts already timed, not bare.** A bare day
    /// claims the *whole* of its day (§6, `DeploymentInterlock`'s own
    /// docs), so a bare-day removal and a bare-day attach on the same date
    /// always overlap — no time chosen for either one alone can escape a
    /// bare day sitting on the other end. A real handover needs a time on
    /// *both* ends (the interlock's own refusal sentence says so). This
    /// group seeds the far end already correctly timed — as it would be
    /// once *its own* editor has been used the same way — so each test
    /// exercises exactly what task 11.265 adds: **a control that can name
    /// a time on a past day where none existed before**, ending in a
    /// write that actually succeeds.
    testWidgets('WATCHED RED until task 11.265: back-dating the attached '
        'date onto a day the outgoing collar already covers now offers a '
        'time instead of a refusal naming a control that does not exist',
        (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        // Collar 1 came off Kea on the 10th at 09:00 — already correctly
        // timed, as it would be after `_setRemoved`'s own past-day branch
        // has been used.
        await repo.link(sampleDeployment(
          id: 'kea-a',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 1),
          removedDate: DateTime(2026, 1, 10, 9),
          modifiedBy: owner,
        ));
        // Collar 2 was linked and dated the 15th — wrong; it actually went
        // on the 10th too, and needs correcting.
        await repo.link(sampleDeployment(
          id: 'kea-b',
          tagId: 'collar-b',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 15),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'kea');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'kea-b');
        await tester.tap(find.byKey(const ValueKey('set_attached_kea-b')));
        await tester.pumpAndSettle();
        // Same month as the row's own date (January), so no calendar
        // navigation is needed — the same trick the sibling tests in this
        // file use to stay independent of the real current date.
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      });

      // **The hole task 11.265 closes**: a time is offered, never a bare
      // refusal naming an action nothing on this screen provides.
      expect(find.text('When did the tag go on?'), findsOneWidget);
      expect(find.byKey(const ValueKey('removed_day_only')), findsNothing,
          reason: 'a bare day on the 10th would overlap collar-a\'s removal '
              '— never offered');
      expect(
        find.text(
          'Another collar already covers part of 2026-01-10, so this one '
          'needs a time — the moment it happened.',
        ),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        // Accept the offered time unchanged — asserting *what* it offers,
        // not just that a picker appeared. Noon is after collar-a's 09:00
        // removal, so this is a genuine, resolvable handover.
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('wearing two tags at once'), findsNothing,
          reason: 'a past-day swap can now be recorded end to end');
      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('kea-b', projectId: projectId),
      );
      expect(row!.attachedDate, isNotNull);
      expect(deploymentEndHasTime(row.attachedDate!), isTrue,
          reason: 'a time, not a bare day — that is what let it through');
      final local = row.attachedDate!.toLocal();
      expect(DateTime(local.year, local.month, local.day),
          DateTime(2026, 1, 10));
      expect(TimeOfDay.fromDateTime(local), const TimeOfDay(hour: 12, minute: 0),
          reason: 'the picker is never prefilled with the wall clock on a '
              'past day (design §6b) — noon is the neutral default, not a '
              'measurement, and this asserts nothing silently substituted '
              '"now" instead');
    });

    testWidgets('the symmetric case: back-dating a removal onto a day the '
        'incoming collar already covers also offers a time, and accepting '
        'it succeeds', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        // Collar 1's removal is seeded already wrong — a bare day on the
        // 10th that conflicts with collar-b's timed attach below — exactly
        // task 11.264's finding: an already-refused pair sitting on the
        // device, waiting for somebody to touch it. Written straight to
        // the table, bypassing the interlock, the way that test's sibling
        // "the attached date is editable" does for the same reason.
        await database.raw.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'kea-a',
            tagId: 'collar-a',
            individualId: 'kea',
            attachedDate: DateTime(2026, 1, 1),
            removedDate: DateTime(2026, 1, 10),
            modifiedBy: owner,
          ).toColumns(),
        );
        // Collar 2 is already correctly attached the 10th at 14:00 — as it
        // would be once its own editor has been used, or entered right
        // the first time.
        await database.raw.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'kea-b',
            tagId: 'collar-b',
            individualId: 'kea',
            attachedDate: DateTime(2026, 1, 10, 14),
            modifiedBy: owner,
          ).toColumns(),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'kea');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'kea-a');
        await tester.tap(find.byKey(const ValueKey('set_removed_kea-a')));
        await tester.pumpAndSettle();
        // The picker starts at the row's own removed date — already
        // January — so tapping "10" needs no calendar navigation, the same
        // trick the sibling tests in this file use.
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      });

      expect(find.text('When did the tag come off?'), findsOneWidget);
      expect(find.byKey(const ValueKey('removed_day_only')), findsNothing,
          reason: 'a bare day on the 10th would overlap collar-b\'s attach '
              '— never offered');
      expect(
        find.text(
          'Another collar already covers part of 2026-01-10, so this one '
          'needs a time — the moment it happened.',
        ),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        // Noon is before collar-b's 14:00 attach — resolvable.
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('wearing two tags at once'), findsNothing);
      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('kea-a', projectId: projectId),
      );
      expect(deploymentEndHasTime(row!.removedDate!), isTrue);
      final local = row.removedDate!.toLocal();
      expect(DateTime(local.year, local.month, local.day),
          DateTime(2026, 1, 10));
      expect(TimeOfDay.fromDateTime(local), const TimeOfDay(hour: 12, minute: 0));
    });

    testWidgets('cancelling the time picker abandons the edit — nothing is '
        'written', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        await repo.link(sampleDeployment(
          id: 'kea-a',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 1),
          removedDate: DateTime(2026, 1, 10, 9),
          modifiedBy: owner,
        ));
        await repo.link(sampleDeployment(
          id: 'kea-b',
          tagId: 'collar-b',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 15),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'kea');
      final before = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('kea-b', projectId: projectId),
      );

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'kea-b');
        await tester.tap(find.byKey(const ValueKey('set_attached_kea-b')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('kea-b', projectId: projectId),
      );
      expect(after!.attachedDate, before!.attachedDate,
          reason: 'cancelling the time picker abandons the whole edit — '
              'there is no bare day to fall back to, the same as '
              '_setRemoved\'s own past-day branch');
    });

    testWidgets('cancelling the "needs a time" dialog itself abandons the '
        'edit too', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        await repo.link(sampleDeployment(
          id: 'kea-a',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 1),
          removedDate: DateTime(2026, 1, 10, 9),
          modifiedBy: owner,
        ));
        await repo.link(sampleDeployment(
          id: 'kea-b',
          tagId: 'collar-b',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 15),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'kea');
      final before = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('kea-b', projectId: projectId),
      );

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'kea-b');
        await tester.tap(find.byKey(const ValueKey('set_attached_kea-b')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('removed_day_or_time_cancel')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('kea-b', projectId: projectId),
      );
      expect(after!.attachedDate, before!.attachedDate,
          reason: 'the whole edit is abandoned, matching task 11.261\'s '
              'rule that Cancel always means Cancel');
    });
  });

  group('two never-timed rows deadlock, and one confirmation closes it '
      '(task 11.270, design §6b)', () {
    /// **WATCHED RED**: before task 11.270 this scenario is refused with the
    /// interlock's ordinary sentence, because a single time on collar-b's
    /// attached date alone still leaves collar-a's bare-day removal
    /// claiming the whole of the 10th.
    testWidgets('correcting the attached date onto a day the animal\'s own '
        'bare-day removal already covers offers one confirmation for both '
        'rows, and accepting it writes both', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        // Collar 1 came off Kea on the 10th — a bare day, because nothing
        // else was on the 10th when it was set.
        await repo.link(sampleDeployment(
          id: 'kea-a',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 1),
          removedDate: DateTime(2026, 1, 10),
          modifiedBy: owner,
        ));
        // Collar 2 was linked and dated the 15th — wrong; it actually went
        // on the 10th too, and needs correcting.
        await repo.link(sampleDeployment(
          id: 'kea-b',
          tagId: 'collar-b',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 15),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'kea');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'kea-b');
        await tester.tap(find.byKey(const ValueKey('set_attached_kea-b')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        // Accept the offered noon, unchanged — the neutral default, never
        // the wall clock, on a past day.
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      });

      // **The deadlock task 11.270 closes**: one confirmation, naming both
      // collars and the shared instant, rather than a bare time picker for
      // collar-b alone that the interlock would only refuse a moment later.
      expect(find.text('Record both ends of this handover?'), findsOneWidget);
      expect(
        find.text(
          "Kea's 150.321 will be recorded as removed 2026-01-10 12:00, and "
          "150.523 as attached the same moment. Neither is written until "
          "you confirm.",
        ),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('confirm_handover')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('wearing two tags at once'), findsNothing,
          reason: 'a refusal here would mean the deadlock was not closed');
      final repo = DeploymentRepository(database.raw);
      final a = await tester.runAsync(
        () => repo.findById('kea-a', projectId: projectId),
      );
      final b = await tester.runAsync(
        () => repo.findById('kea-b', projectId: projectId),
      );
      expect(deploymentEndHasTime(a!.removedDate!), isTrue);
      expect(deploymentEndHasTime(b!.attachedDate!), isTrue);
      expect(a.removedDate, b.attachedDate,
          reason: 'the same instant closes one and opens the other — an '
              'overlap of nothing, exactly the ordinary handover');
      final local = a.removedDate!.toLocal();
      expect(DateTime(local.year, local.month, local.day),
          DateTime(2026, 1, 10));
      expect(TimeOfDay.fromDateTime(local), const TimeOfDay(hour: 12, minute: 0));
    });

    testWidgets('the symmetric case: correcting the removed date onto a day '
        'the animal\'s own bare-day attach already covers also joins into '
        'one confirmation', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        // Both rows are seeded already wrong together — collar-a's removal
        // overlapping collar-b's open-ended attach — the same way task
        // 11.264's finding put it: an already-refused pair sitting on the
        // device, waiting for somebody to touch it. Written straight to the
        // table, bypassing the interlock, the way the sibling 11.265 test
        // above does for the same reason.
        // Collar 2 is already correctly on the 10th — a bare day.
        await database.raw.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'kea-b',
            tagId: 'collar-b',
            individualId: 'kea',
            attachedDate: DateTime(2026, 1, 10),
            modifiedBy: owner,
          ).toColumns(),
        );
        // Collar 1's removal is wrong — the 15th — and needs correcting to
        // the 10th too.
        await database.raw.insert(
          Tables.deployments,
          sampleDeployment(
            id: 'kea-a',
            tagId: 'collar-a',
            individualId: 'kea',
            attachedDate: DateTime(2026, 1, 1),
            removedDate: DateTime(2026, 1, 15),
            modifiedBy: owner,
          ).toColumns(),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'kea');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'kea-a');
        await tester.tap(find.byKey(const ValueKey('set_removed_kea-a')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
      });

      expect(find.text('Record both ends of this handover?'), findsOneWidget);
      expect(
        find.text(
          "Kea's 150.321 will be recorded as removed 2026-01-10 12:00, and "
          "150.523 as attached the same moment. Neither is written until "
          "you confirm.",
        ),
        findsOneWidget,
      );

      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('confirm_handover')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('wearing two tags at once'), findsNothing);
      final repo = DeploymentRepository(database.raw);
      final a = await tester.runAsync(
        () => repo.findById('kea-a', projectId: projectId),
      );
      final b = await tester.runAsync(
        () => repo.findById('kea-b', projectId: projectId),
      );
      expect(a!.removedDate, b!.attachedDate);
    });

    testWidgets('cancelling the joint confirmation writes neither row',
        (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        final repo = DeploymentRepository(database.raw);
        await repo.link(sampleDeployment(
          id: 'kea-a',
          tagId: 'collar-a',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 1),
          removedDate: DateTime(2026, 1, 10),
          modifiedBy: owner,
        ));
        await repo.link(sampleDeployment(
          id: 'kea-b',
          tagId: 'collar-b',
          individualId: 'kea',
          attachedDate: DateTime(2026, 1, 15),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'kea');
      final repo = DeploymentRepository(database.raw);
      final beforeA = await tester.runAsync(
        () => repo.findById('kea-a', projectId: projectId),
      );
      final beforeB = await tester.runAsync(
        () => repo.findById('kea-b', projectId: projectId),
      );

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'kea-b');
        await tester.tap(find.byKey(const ValueKey('set_attached_kea-b')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cancel_handover')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      final afterA = await tester.runAsync(
        () => repo.findById('kea-a', projectId: projectId),
      );
      final afterB = await tester.runAsync(
        () => repo.findById('kea-b', projectId: projectId),
      );
      expect(afterA!.removedDate, beforeA!.removedDate,
          reason: 'a refusal — or here, a cancel — applies neither row');
      expect(afterB!.attachedDate, beforeB!.attachedDate);
    });
  });

  group('editing and clearing a removed date (task 11.261)', () {
    testWidgets('a removal already set gets "Edit removed date" and "Clear '
        'removed date" rather than no editor at all', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        await DeploymentRepository(database.raw).link(sampleDeployment(
          id: 'marie-closed',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
          removedDate: DateTime(2026, 2, 1),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');
      await openDeploymentMenu(tester, 'marie-closed');

      expect(find.text('Edit removed date'), findsOneWidget,
          reason: 'before this task the row had no way to change a removed '
              'date once set — only "Remove record", which says something '
              'different and destructive');
      expect(find.byKey(const ValueKey('clear_removed_marie-closed')),
          findsOneWidget);
    });

    testWidgets('the removed-date picker says why it will not go before the '
        'attached date (task 11.268, item 5)', (tester) async {
      // Read 2026-09-17: the floor was already correct — a collar cannot
      // come off before it went on — but silent about it. A greyed
      // calendar with no reason reads as a defect.
      await seed(tester);
      await pumpDetail(tester, 'marie');
      await openDeploymentMenu(tester, 'marie-current');
      await tester.tap(
        find.byKey(const ValueKey('set_removed_marie-current')),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Not before it went on, 2026-01-15'),
        findsOneWidget,
        reason: 'marie-current was attached on 2026-01-15 in the seed',
      );
    });

    testWidgets('editing a removed date to a past day that overlaps offers '
        'a time (task 11.265), and a deep overlap is still refused after '
        'one is set, watched red', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        final db = DeploymentRepository(database.raw);
        await db.link(sampleDeployment(
          id: 'marie-closed',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
          removedDate: DateTime(2026, 2, 1),
          modifiedBy: owner,
        ));
        // A second collar on Marie that starts right after the first one
        // closes and stays on indefinitely — editing the first one's
        // removed date forward into this interval must be refused, the same
        // as any other edit, even once a time can be named for it.
        await db.link(sampleDeployment(
          id: 'marie-second',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: DateTime(2026, 2, 2),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');
      final before = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-closed', projectId: projectId),
      );

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-closed');
        await tester.tap(find.byKey(const ValueKey('set_removed_marie-closed')));
        await tester.pumpAndSettle();
        // Pick a day well inside collar-b's interval.
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        // **The hole task 11.265 closes**: a past day (2026-02-10, nowhere
        // near "today") that already overlaps another deployment as a bare
        // day now offers a time rather than being written as a bare day and
        // refused with no way forward.
        expect(find.text('When did the tag come off?'), findsOneWidget);
        expect(find.byKey(const ValueKey('removed_day_only')), findsNothing,
            reason: 'a bare day on 2026-02-10 would overlap collar-b, so it '
                'is never on offer');
        expect(find.textContaining('2026-02-10'), findsOneWidget,
            reason: 'the explanation names the day, not "today" — this one '
                'is not today');
        await tester.tap(find.byKey(const ValueKey('removed_pick_time')));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(find.textContaining('wearing two tags at once'), findsOneWidget,
          reason: 'collar-b covers every moment from 2026-02-02 onward, so '
              'naming a time on the 10th does not stop 2026-02-10 falling '
              'inside it — the interlock still refuses the write, and the '
              'sentence now names an action the person can actually take');
      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-closed', projectId: projectId),
      );
      expect(after!.removedDate, before!.removedDate,
          reason: 'a refused edit must not change the row');
    });

    testWidgets('editing a removed date to a past day that does NOT overlap '
        'still writes a bare day, no time picker opened (§4b unchanged)',
        (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        // Removed date already set to a bare day (2026-01-15), nothing else
        // on Marie's calendar — deterministic regardless of the real
        // current date, the same reason the sibling test above starts from
        // an already-dated row rather than today's picker default.
        await DeploymentRepository(database.raw).link(sampleDeployment(
          id: 'marie-open',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 1),
          removedDate: DateTime(2026, 1, 15),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-open');
        await tester.tap(find.byKey(const ValueKey('set_removed_marie-open')));
        await tester.pumpAndSettle();
        // Pick a different day in the same month — still nothing else on
        // Marie's calendar.
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      expect(find.byType(TimePickerDialog), findsNothing,
          reason: 'nothing needs a time here — §4b still applies');
      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-open', projectId: projectId),
      );
      expect(row!.removedDate, isNotNull);
      expect(deploymentEndHasTime(row.removedDate!), isFalse,
          reason: 'a bare day, unchanged from before task 11.265');
    });

    testWidgets('Clear removed date reopens the deployment — "I recorded it '
        'off and it is still on her"', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        await DeploymentRepository(database.raw).link(sampleDeployment(
          id: 'marie-closed',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
          removedDate: DateTime(2026, 2, 1),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await openDeploymentMenu(tester, 'marie-closed');
        await tester.tap(find.byKey(const ValueKey('clear_removed_marie-closed')));
      });

      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-closed', projectId: projectId),
      );
      expect(row!.removedDate, isNull,
          reason: 'today\'s only route was Remove record, which says the '
              'collar was never on this animal — clearing says instead that '
              'the removal was recorded wrong');
    });

    testWidgets('clearing a removed date that would put two open collars on '
        'one animal is refused by the interlock', (tester) async {
      await seed(tester);
      // Marie already wears collar-a (open, from `seed`). Give her a second,
      // closed deployment of a different collar — clearing its removed date
      // would put two open collars on her at once, which §6 forbids.
      await tester.runAsync(() async {
        await DeploymentRepository(database.raw).link(sampleDeployment(
          id: 'marie-closed',
          tagId: 'collar-b',
          individualId: 'marie',
          attachedDate: DateTime(2025, 6, 1),
          removedDate: DateTime(2025, 12, 1),
          modifiedBy: owner,
        ));
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');
      final before = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-closed', projectId: projectId),
      );

      await act(tester, () async {
        await openDeploymentMenu(tester, 'marie-closed');
        await tester.tap(find.byKey(const ValueKey('clear_removed_marie-closed')));
      });

      expect(find.textContaining('wearing two tags at once'), findsOneWidget,
          reason: 'reopening a deployment is re-checked by the interlock '
              'exactly like any other edit');
      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-closed', projectId: projectId),
      );
      expect(after!.removedDate, before!.removedDate,
          reason: 'a refused clear must not change the row');
    });

    testWidgets('a non-zero reattribution count is named before the write, '
        'and Cancel leaves the row alone', (tester) async {
      await seed(tester, wearing: false);
      await tester.runAsync(() async {
        await DeploymentRepository(database.raw).link(sampleDeployment(
          id: 'marie-closed',
          tagId: 'collar-a',
          individualId: 'marie',
          attachedDate: DateTime(2026, 1, 15),
          removedDate: DateTime(2026, 1, 20),
          modifiedBy: owner,
        ));
        // A bearing taken on the 25th — inside the *new* interval this test
        // moves the removal into, but not the old one, so moving the date
        // re-attributes it.
        await database.raw.insert(
          Tables.observations,
          sampleObservation(
            id: 'obs-affected',
            userId: owner,
            tagId: 'collar-a',
            sessionId: null,
            tagVersionId: null,
            timestampUtc: DateTime(2026, 1, 25, 12),
          ).toColumns(),
        );
        refreshTagViewsIn(container, projectId: projectId);
        await resolve();
      });
      await pumpDetail(tester, 'marie');

      await tester.runAsync(() async {
        await openDeploymentMenu(tester, 'marie-closed');
        await tester.tap(find.byKey(const ValueKey('set_removed_marie-closed')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('27'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OK'));
        // `_confirmReattribution` does a real database round trip before
        // the warning dialog appears — `pumpAndSettle` alone does not wait
        // for that (CLAUDE.md: never await the database from the test body,
        // and the same real-time gap applies to a `runAsync` block that
        // pumps too early).
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
      });

      expect(find.textContaining('1 bearing'), findsOneWidget,
          reason: 'the count is named — this is a change to a record the '
              'bearing did not open, the way §5a names the second row a '
              'link touches');

      await tester.runAsync(() async {
        await tester.tap(find.text('Cancel'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pumpAndSettle();
        await resolve();
      });
      await tester.pumpAndSettle();

      final row = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findById('marie-closed', projectId: projectId),
      );
      expect(row!.removedDate!.isAtSameMomentAs(DateTime(2026, 1, 20)), isTrue,
          reason: 'cancelling the reattribution warning must not write '
              'the new date');
    });
  });

  group('withdrawing a collar record', () {
    testWidgets('Remove record says what it is and is not, then unlinks',
        (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await openDeploymentMenu(tester, 'marie-current');
        await tester.tap(
          find.byKey(const ValueKey('unlink_marie-current')),
        );
        await tester.pumpAndSettle();
        // The sentence has to separate the two acts, because they look the
        // same and mean opposite things.
        expect(
          find.textContaining('set a removed date instead'),
          findsOneWidget,
        );
        expect(find.textContaining('Bearings do not move'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('confirm_unlink')));
      });

      final after = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .findByIndividual('marie', projectId: projectId),
      );
      expect(after, isEmpty);
    });
  });

  group('deleting an animal', () {
    testWidgets('the confirmation says no bearing moves, and none does',
        (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('delete_animal')));
        await tester.pumpAndSettle();
        expect(find.textContaining('No bearing moves'), findsOneWidget);
        expect(find.textContaining('cannot be undone'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('confirm_delete_animal')));
      });

      final animals = await tester.runAsync(
        () => IndividualRepository(database.raw).findByProject(projectId),
      );
      expect(animals!.map((a) => a.name), ['Kea']);
      // The collar is back on the shelf, which is an ordinary state for a
      // transmitter (design §1).
      final free = await tester.runAsync(
        () => DeploymentRepository(database.raw)
            .latestAnimalForTag('collar-a', projectId: projectId),
      );
      expect(free, isNull);
    });

    testWidgets(
      'a contributor cannot delete — the control is disabled and the '
      'screen names what they can still do (task 11.255)',
      (tester) async {
        await seed(tester, role: ProjectRole.contributor);
        await pumpDetail(tester, 'marie');

        final button = tester.widget<OutlinedButton>(
          find.byKey(const ValueKey('delete_animal')),
        );
        expect(button.onPressed, isNull);
        expect(
          find.textContaining('Only a project owner can delete an animal'),
          findsOneWidget,
        );
        expect(
          find.textContaining('rename it or withdraw its tags'),
          findsOneWidget,
          reason: '11.244\'s "a contributor may correct a mistake" stays '
              'true for everything short of deleting the record',
        );

        // Refused, and nothing moved: the Save button still works for the
        // same contributor, so this is not a screen-wide lockout.
        final animals = await tester.runAsync(
          () => IndividualRepository(database.raw).findByProject(projectId),
        );
        expect(animals!.map((a) => a.name), containsAll(['Marie', 'Kea']));
      },
    );
  });

  group('an unsaved field edit is guarded on the way out (task 11.268, '
      'item 1)', () {
    /// **The only real defect among task 11.268's eight items.** Read
    /// 2026-09-17: there was no `PopScope` and no unsaved-changes guard at
    /// all, so editing the name and tapping back discarded it silently.
    /// Pushes the screen onto a real route, so `Navigator.maybePop` runs
    /// the same should-pop machinery the system back gesture does — a
    /// `MaterialApp(home: ...)` with nothing to pop to would not exercise
    /// `PopScope` at all.
    final navigatorKey = GlobalKey<NavigatorState>();

    Future<void> pumpDetailPushed(WidgetTester tester, String id) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: SizedBox()),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => AnimalDetailScreen(individualId: id),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('WATCHED RED: editing the name and backing out without '
        'saving prompts to discard, rather than losing it silently',
        (tester) async {
      await seed(tester);
      await pumpDetailPushed(tester, 'marie');

      await tester.enterText(
        find.byKey(const ValueKey('individual_name')),
        'Marie II',
      );
      await tester.pump();

      // The system back gesture / button — `maybePop` runs `PopScope`'s
      // `canPop`/`onPopInvokedWithResult` exactly as a real back does.
      navigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsOneWidget,
          reason: 'an edit is in progress and nothing has saved it — '
              'popping must not just happen');
      expect(find.byKey(const ValueKey('individual_name')), findsOneWidget,
          reason: 'the screen is still open; the pop was held');

      // Keep editing: the screen stays, the draft survives.
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('Marie II'), findsOneWidget);

      // Now really leave: Discard pops for real, and nothing was written.
      navigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('discard_animal_edit')));
      await tester.pumpAndSettle();

      final row = await tester.runAsync(
        () => IndividualRepository(database.raw)
            .findByProject(projectId)
            .then((all) => all.firstWhere((a) => a.individualId == 'marie')),
      );
      expect(row!.name, 'Marie',
          reason: 'Discard means discard — the unsaved name never wrote');
    });

    testWidgets('Save first, then back out: nothing to discard, no prompt',
        (tester) async {
      await seed(tester);
      await pumpDetailPushed(tester, 'marie');

      await tester.enterText(
        find.byKey(const ValueKey('individual_name')),
        'Marie II',
      );
      await tester.pump();
      await act(tester, () async {
        await tester.tap(find.byKey(const ValueKey('animal_save')));
      });

      navigatorKey.currentState!.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Discard changes?'), findsNothing,
          reason: 'the draft was saved; there is nothing left to lose');
      expect(find.byKey(const ValueKey('individual_name')), findsNothing,
          reason: 'the screen actually popped this time');
    });
  });

  group('colour writes on tap, independent of Save (task 11.268, item 2)',
      () {
    testWidgets('picking a colour writes immediately, without needing '
        'Save and without saving an unrelated unsaved name edit',
        (tester) async {
      await seed(tester);
      await pumpDetail(tester, 'marie');

      // An unsaved name edit sits in the draft the whole time — tapping a
      // colour swatch must not silently save it.
      await tester.enterText(
        find.byKey(const ValueKey('individual_name')),
        'Marie II',
      );
      await tester.pump();

      await act(tester, () async {
        await tester.tap(
          find.byKey(ValueKey('tag_color_swatch_${TagColorPalette.colors[2]}')),
        );
      });

      final row = await tester.runAsync(
        () => IndividualRepository(database.raw)
            .findByProject(projectId)
            .then((all) => all.firstWhere((a) => a.individualId == 'marie')),
      );
      expect(row!.colorHex, TagColorPalette.colors[2],
          reason: 'colour writes on tap, no Save needed');
      expect(row.name, 'Marie',
          reason: 'the unsaved name draft must not have been swept along');
      // And the draft is still there for the person to finish and save.
      expect(find.text('Marie II'), findsOneWidget);
    });
  });

  // **Task 11.271.** This file has had three time-of-day defects (tasks
  // 11.269 — twice — and 11.273), all in this same "which calendar day is
  // this instant" logic. `flutter test` samples one moment of the day, so
  // `scripts/repeat_suite.sh` running this file ten times in one evening
  // never varied the one thing that mattered. These tests pin the clock
  // instead.
  //
  // Two different mechanisms, for two different defects:
  //
  // - **`animal_detail_screen.dart`'s `_now` getter reads `clock.now()`**
  //   (this task's one production seam), so `withClock` below controls what
  //   "now" is for any on-screen "is this today" comparison — the shape of
  //   task 11.273's bug (`clock.now().subtract(1h)` assumed it stayed
  //   today).
  // - **Which calendar day a *stored* instant falls on is controlled by the
  //   real process timezone, not by `withClock`.** `DeploymentRepository`
  //   round-trips every date through `DbCodec.encodeUtcOrNull`/
  //   `decodeUtcOrNull` (`.toUtc()` / `.toLocal()`), and those always ask
  //   the real OS/ICU timezone database — `withClock` cannot reach them.
  //   `deploymentDateFor`'s job is to undo that conversion; task 11.269's
  //   bug was one call site (`_setAttached`'s date picker) that skipped it
  //   and used the raw stored instant instead. Reproducing *that* shape
  //   needs the process itself running under a real, different TZ — see
  //   `scripts/clock_matrix_test.sh`, which is what actually varies it by
  //   launching `flutter test` three times, once per case below, under the
  //   TZ each case names.
  //
  // Run any other way — a plain `flutter test`, an IDE run button — a case
  // whose required TZ does not match whatever TZ the process actually
  // started under reports itself skipped, naming what it needed, rather
  // than silently passing under the wrong zone.
  group('clock matrix — fixed clocks for date-boundary logic (task 11.271)',
      () {
    // Arizona (America/Phoenix) does not observe DST and Michael's
    // deployments do not leave it, so -7 is exact year-round — chosen
    // because it is the timezone every incident to date (11.269, 11.273)
    // was actually found in. Tokyo does not observe DST either, so +9 is
    // exact year-round — chosen only to flip the sign of the offset
    // `deploymentDateFor`'s `.toLocal()` applies; nothing about this project
    // runs there.
    const phoenixOffset = Duration(hours: -7);
    const tokyoOffset = Duration(hours: 9);

    final matrix = [
      (
        name: 'just before local midnight, America/Phoenix (UTC-7)',
        requiredTz: 'America/Phoenix',
        requiredOffset: phoenixOffset,
        fixedNow: DateTime(2026, 9, 16, 23, 55),
        reason:
            'Both of task 11.269\'s defects were found running the suite in '
            'the evening in this zone. A swap two hours before this "now" '
            '(21:55) sits in [17:00, 24:00) local — the window where a '
            'UTC-negative zone\'s toUtc() has already crossed into the next '
            'calendar day, which is exactly what the raw-instant picker bug '
            'needed.',
      ),
      (
        name: 'just after local midnight, America/Phoenix (UTC-7)',
        requiredTz: 'America/Phoenix',
        requiredOffset: phoenixOffset,
        fixedNow: DateTime(2026, 9, 17, 0, 5),
        reason:
            'Task 11.273\'s own defect: "now" is inside the first hour after '
            'local midnight, so "an hour ago" (23:05 the day before) lands '
            'on yesterday. Also still inside the wide window above, so '
            '11.269\'s shape reproduces here too.',
      ),
      (
        name: 'shortly after local midnight, Asia/Tokyo (UTC+9)',
        requiredTz: 'Asia/Tokyo',
        requiredOffset: tokyoOffset,
        fixedNow: DateTime(2026, 9, 17, 3, 0),
        reason:
            'Flips the sign: a UTC-positive zone\'s local day runs AHEAD of '
            'UTC from local midnight until the offset has elapsed — here, '
            '[00:00, 09:00). A swap two hours before this "now" (01:00) '
            'sits inside that window, so the same raw-instant picker bug '
            'reproduces from the opposite direction — the direction '
            '11.269\'s own incident (found only in a UTC-negative zone) '
            'never exercised.',
      ),
    ];

    for (final kase in matrix) {
      testWidgets(
        "11.269's picker: OK on the pre-filled day keeps the swap time — "
        '${kase.name}',
        (tester) async {
          if (DateTime.now().timeZoneOffset != kase.requiredOffset) {
            markTestSkipped(
              'requires the process to have started under TZ=${kase.requiredTz} '
              '(UTC offset ${kase.requiredOffset}); this process is at '
              '${DateTime.now().timeZoneOffset}. Run via '
              'scripts/clock_matrix_test.sh, not flutter test directly. '
              '(${kase.reason})',
            );
            return;
          }
          await withClock(Clock.fixed(kase.fixedNow), () async {
            await seed(tester, wearing: false);
            final swap = clock.now().subtract(const Duration(hours: 2));
            // **No sibling deployment on purpose** (unlike
            // `seedSwappedPair`, which this borrows its shape from). With
            // one to overlap, the wrong day the pre-fix bug offers can land
            // inside it and route through `_askDayOrTime` instead of
            // writing directly — a second dialog this test does not drive,
            // which reads as a false pass rather than the bug it is meant
            // to catch. With nothing to overlap, a wrong day always writes
            // directly, in either offset direction.
            await tester.runAsync(() async {
              final repo = DeploymentRepository(database.raw);
              await repo.link(sampleDeployment(
                id: 'marie-b',
                tagId: 'collar-b',
                individualId: 'marie',
                attachedDate: swap,
                modifiedBy: owner,
              ));
              refreshTagViewsIn(container, projectId: projectId);
              await resolve();
            });
            await pumpDetail(tester, 'marie');
            await tester.runAsync(() async {
              await openDeploymentMenu(tester, 'marie-b');
              await tester.tap(
                  find.byKey(const ValueKey('set_attached_marie-b')));
              await tester.pumpAndSettle();
              await tester.tap(find.text('OK'));
              await Future<void>.delayed(const Duration(milliseconds: 300));
            });
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));

            final row = await tester.runAsync(
              () => DeploymentRepository(database.raw)
                  .findById('marie-b', projectId: projectId),
            );
            expect(
              row!.attachedDate!.isAtSameMomentAs(swap),
              isTrue,
              reason: 'the picker offers days, and the person picked the '
                  'day the row already had — its time is not theirs to '
                  'lose (${kase.name})',
            );
            expect(deploymentEndHasTime(row.attachedDate!), isTrue);
          });
        },
      );
    }

    testWidgets(
      "11.273's same-day swap: fixed to just after local midnight, the "
      'clamp keeps a collar taken off Kea an hour ago on today, and the '
      'swap still gets its time',
      (tester) async {
        const kase = (
          name: 'just after local midnight, America/Phoenix (UTC-7)',
          requiredTz: 'America/Phoenix',
        );
        if (DateTime.now().timeZoneOffset != phoenixOffset) {
          markTestSkipped(
            'requires the process to have started under TZ=${kase.requiredTz} '
            '(UTC offset $phoenixOffset); this process is at '
            '${DateTime.now().timeZoneOffset}. Run via '
            'scripts/clock_matrix_test.sh, not flutter test directly.',
          );
          return;
        }
        // **Not the naive "an hour ago" task 11.273 found broken** — that
        // reproduces the old bug (see the "watched red" note in this task's
        // report; kept out of the permanent suite because it would assert
        // the wrong thing on purpose). This is the fixed shape, the same
        // clamp `seedTouchingPair` and this file's real "THE TAG'S SWAP"
        // test both use: at a real clock the clamp only ever matters within
        // an hour of local midnight, so it had only ever been exercised by
        // accident of when the suite happened to run. Fixed to 00:05, the
        // clamp is exercised every time this runs.
        await withClock(Clock.fixed(DateTime(2026, 9, 17, 0, 5)), () async {
          await seed(tester, wearing: false);
          await tester.runAsync(() async {
            final now = clock.now();
            final wanted = now.subtract(const Duration(hours: 1));
            final removed = deploymentDateFor(wanted).isAtSameMomentAs(
              deploymentDateFor(now),
            )
                ? wanted
                : DateTime(now.year, now.month, now.day, 0, 1);
            await DeploymentRepository(database.raw).link(
              sampleDeployment(
                id: 'kea-until-today',
                tagId: 'collar-a',
                individualId: 'kea',
                attachedDate: DateTime(2026, 1, 15),
                removedDate: removed,
                modifiedBy: owner,
              ),
            );
            refreshTagViewsIn(container, projectId: projectId);
            await resolve();
          });
          await pumpDetail(tester, 'marie');

          await act(tester, () async {
            await tester.tap(find.byKey(const ValueKey('link_tag')));
            await tester.pumpAndSettle();
            expect(
              find.descendant(
                of: find.byType(SimpleDialog),
                matching: find.byKey(const ValueKey('link_tag_collar-a')),
              ),
              findsOneWidget,
              reason: 'removed shortly before midnight is free to link now '
                  '— the same-day move, once the clamp keeps the removal '
                  'on today rather than letting "an hour ago" fall to '
                  'yesterday',
            );
            await tester.tap(find.byKey(const ValueKey('link_tag_collar-a')));
            await tester.pumpAndSettle();
          });

          // **The actual defect surface.** `_departureOn` has to recognize
          // collar-a's removal as *today's*, or the confirmation offers no
          // way to stamp a time and every bearing collar-a takes today is
          // left contested between Kea and Marie — silently, since nothing
          // refuses the link itself.
          expect(
            find.byKey(const ValueKey('change_swap_time')),
            findsOneWidget,
            reason: 'the collar came off Kea inside the same local day, so '
                'the confirmation must offer a time — not treat this as an '
                'ordinary bare-day link',
          );

          await act(tester, () async {
            await tester.tap(find.byKey(const ValueKey('confirm_link')));
          });
          final hers = await tester.runAsync(
            () => DeploymentRepository(database.raw)
                .findByIndividual('marie', projectId: projectId),
          );
          expect(deploymentEndHasTime(hers!.single.attachedDate!), isTrue,
              reason: 'a same-day swap carries a real instant, never a bare '
                  'day, or the afternoon\'s bearings would be attributed to '
                  'nobody');
        });
      },
    );
  });
}

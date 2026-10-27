import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/features/position_estimation/screens/position_estimation_screen.dart';

import '../../../data/fixtures.dart';
import '../../../support/app_shell_harness.dart';
import '../../../support/fake_shared_preferences.dart';
import '../../../support/text_scale_probe.dart';

/// Task 11.109 — the acceptance criterion this screen never had.
///
/// Michael found the Position screen on hardware with **no bearing row
/// visible at all**. Nothing was wrong with any one widget: a summary line, a
/// cautions banner, a sort bar, a selection row and a save button had each
/// been added by a task that justified it, and the lower panel was a fixed
/// 5/11 of the screen, so every one of them came out of the bearings list's
/// own height. **The defect was the total**, which is why no test caught it —
/// every test on this screen asks whether a control is present and correct,
/// and none of them asks whether the screen still works with all of them on
/// it at once.
///
/// This file asks that. It renders the real screen inside the real app shell
/// at real phone geometry and measures the bearings list. The rules it holds
/// are written at the top of `position_estimation_screen.dart`; the two that
/// matter most are that **the list's height is a floor and not a remainder**,
/// and that **a condition (the cautions) never takes space from the subject**.
///
/// A note on the numbers. Under `flutter test` there are no real fonts: every
/// glyph is a square of the font size, so an observer name wraps where it
/// would not on a device and a bearing row measures ~82 logical pixels
/// instead of the ~64 a real two-line dense `ListTile` takes. That makes this
/// harness *harsher* than a phone, never kinder, so the row counts asserted
/// below are lower bounds on what a person actually sees. Every assertion is
/// written against the row height measured in the run rather than against a
/// constant, so it stays true either way.
void main() {
  setUp(installFakeSharedPreferences);
  // Task 11.205 gave this screen its first `TilesNotLoadingBand`, and this
  // test harness runs with a real `CachedTileProvider` against no real
  // network — so tile requests genuinely fail here, and without a reset
  // `TileFetchHealth.instance` trips to failing and stays there across
  // tests in this file. Every other screen that carries the band already
  // resets it in setUp/tearDown (`map_screen_space_budget_test.dart`,
  // `offline_data_map_space_budget_test.dart`, and others); this screen
  // never needed to before.
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);


  // Geometry lives in `test/support/app_shell_harness.dart` — 393x852, a
  // 59pt status bar and a 34pt home indicator — shared with the Main Map and
  // Record screen budgets so all three measure the same phone.

  /// Panel furniture declared by `_EstimationContentState`: header row 46 +
  /// controls row 40 + save row 64 + the 1.5px rule against the map. Asserted below rather than trusted — if
  /// somebody adds a permanent row to the panel, this is the number that
  /// moves and this is the test that says so.
  const declaredChromeHeight = 151.5;

  /// The extra the save row takes for a viewer, who is told there why saving
  /// is unavailable (task 11.138). `_saveReasonHeight` in the screen.
  const declaredSaveReasonHeight = 52.0;

  /// What one two-line dense bearing row takes on a device. The test font
  /// wraps observer names and measures ~82 instead; assertions written in
  /// device pixels use this, assertions about what is actually on screen in
  /// this run use the measured height.
  const designRowHeight = 64.0;

  Future<ProviderContainer> seed({
    required int bearings,
    required bool longSpan,
    required bool degenerate,
    required bool syncLive,
    // Task 11.138: gives the acting user a viewer membership, which is the
    // only state in which the save row carries a second line saying why
    // saving is unavailable. That line is the one thing on this panel whose
    // height depends on *who is holding the phone*, so the budget has to be
    // measured twice.
    bool asViewer = false,
  }) async {
    final project = sampleProject(id: 'project-1', ownerUserId: 'user-1');
    final user = sampleUser(id: 'user-1', email: 'a@example.com')
        .copyWith(firstName: 'Alice', lastName: 'Vega');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    final viewer = sampleUser(
      id: 'user-viewer',
      email: 'v@example.com',
    ).copyWith(firstName: 'Val', lastName: 'Reed');
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        if (syncLive)
          syncControllerProvider.overrideWith(LiveSyncStatusController.new),
        // A *second* person, not [user]. `readProjectRole` falls back to the
        // project's `owner_user_id` when the acting user is the creator, so
        // giving the creator a viewer membership row resolves to owner anyway
        // and this test would have measured the wrong panel.
        // Task 11.237: and otherwise the *owner*, explicitly. The device's
        // own fresh user used to resolve to "this device cannot say" and be
        // permitted; now somebody the rows do not name holds a read-only
        // snapshot, and the save row would carry the snapshot refusal —
        // which is a third panel, not the one this file measures.
        currentUserProvider.overrideWith(
          (ref) async => asViewer ? viewer : user,
        ),
      ],
    );
    final userRepo = await container.read(userRepositoryProvider.future);
    final projectRepo = await container.read(projectRepositoryProvider.future);
    final tagRepo = await container.read(tagRepositoryProvider.future);
    final obsRepo = await container.read(observationRepositoryProvider.future);
    await userRepo.insert(user);
    await projectRepo.insert(project);
    await tagRepo.insert(tag);

    final base = DateTime.utc(2026, 8, 31, 12);
    for (var i = 0; i < bearings; i++) {
      final o = sampleObservation(
        id: 'obs-$i',
        projectId: project.projectId,
        userId: user.userId,
        tagId: tag.tagId,
        sessionId: null,
        // `degenerate` piles every observer onto nearly one point with nearly
        // one bearing, which is what makes the solver raise several cautions
        // at once — the worst case for the panel, and the case that left the
        // list with nothing.
        latitude: degenerate ? 35.10 + i * 0.00001 : 35.10 + i * 0.004,
        longitude: degenerate ? -111.70 + i * 0.00001 : -111.70 + i * 0.006,
      ).copyWith(
        trueNorthBearing: degenerate ? 90.0 + i * 0.05 : 60.0 + (i * 37) % 120,
        magneticBearing: degenerate ? 90.0 + i * 0.05 : 60.0 + (i * 37) % 120,
        timestampUtc: base.add(Duration(minutes: longSpan ? i * 30 : i)),
        timestampLocal: base.add(Duration(minutes: longSpan ? i * 30 : i)),
          );
      await obsRepo.insert(o);
    }
    if (asViewer) {
      await userRepo.insert(viewer);
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
          projectId: project.projectId,
          userId: viewer.userId,
          role: ProjectRole.viewer,
        ).toColumns(),
      );
    }
    await container
        .read(activeProjectIdProvider.notifier)
        .set(project.projectId);
    // Pre-resolved outside the fake-async zone for the same reason
    // `position_estimation_screen_test.dart` does it: a fresh FFI call
    // triggered after pumping never completes inside `testWidgets`. The
    // `listen` is what holds the autoDispose family alive across the await
    // — without it the element is torn down mid-build and the read throws
    // `UnmountedRefException` rather than answering (task 11.105's shape).
    // For every caller since task 11.237: the screen reads the standing for
    // everybody, not only for a viewer.
    container.listen(myProjectStandingProvider(project.projectId), (_, _) {});
    await container.read(myProjectStandingProvider(project.projectId).future);
    return container;
  }

  /// The screen inside the *shell it actually runs in* — the real [TabShell],
  /// via `pumpInAppShell` (task 11.110 moved this out of this file so the
  /// Main Map and the Record screen measure against the same shell, and so
  /// that shell is the production widget rather than a copy of its shape).
  ///
  /// [syncLive] gives the app a live sync status. **Until task 11.189 that
  /// switched on both of the shell's conditional bands, which cost this
  /// screen about 76 logical pixels between them at the default text size
  /// and far more above it.** Those bands are gone — sync is an icon on the
  /// Main Map and a dot on the More tab now, and neither is on this screen —
  /// so what it switches on here is nothing at all. It is kept, and still
  /// passed by the tests that measure this screen's floor, because *that* is
  /// the assertion: the shell no longer takes anything from this screen in
  /// any sync state.
  Future<void> pumpInShell(
    WidgetTester tester,
    ProviderContainer container, {
    bool syncLive = false,
    double textScale = 1.0,
    DeviceGeometry geometry = phoneGeometry,
  }) async {
    await pumpInAppShell(
      tester,
      container: container,
      screen: const PositionEstimationScreen(),
      tabIndex: 3, // Map / Record / Compass / **Position** / More
      textScale: textScale,
      geometry: geometry,
    );
  }

  /// This screen draws a live map, and under `flutter test` every tile fetch
  /// fails. Those failures are reported as framework errors, and a test that
  /// renders the screen more than once collects enough of them that the
  /// binding refuses to say which exception mattered — which would hide the
  /// layout overflow this file exists to notice. Drop exactly the image-load
  /// noise and leave every other error reported. Installed from inside the
  /// test body, because the binding replaces `FlutterError.onError` when the
  /// body starts and a `setUp` handler would be thrown away.
  void silenceTileLoadErrors() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  /// What the person actually sees: the bearings list's viewport, the height
  /// of one row in this run, and how many whole rows fit inside the viewport.
  ({double listHeight, double rowHeight, int wholeRows, double panelHeight}) measure(
    WidgetTester tester,
  ) {
    final list = find.byType(ListView);
    expect(list, findsOneWidget, reason: 'the bearings list must be built at all');
    final listRect = tester.getRect(list);
    final panelRect = tester.getRect(find.byKey(const ValueKey('bearings-panel')));

    var rowHeight = 0.0;
    var whole = 0;
    for (final element in find.byType(CheckboxListTile).evaluate()) {
      final r = tester.getRect(find.byWidget(element.widget));
      rowHeight = math.max(rowHeight, r.height);
      if (r.top >= listRect.top - 0.5 && r.bottom <= listRect.bottom + 0.5) {
        whole++;
      }
    }
    return (
      listHeight: listRect.height,
      rowHeight: rowHeight,
      wholeRows: whole,
      panelHeight: panelRect.height,
    );
  }

  Future<ProviderContainer> setUpScreen(
    WidgetTester tester, {
    required int bearings,
    bool longSpan = false,
    bool degenerate = false,
    bool syncLive = false,
    bool asViewer = false,
    double textScale = 1.0,
    DeviceGeometry geometry = phoneGeometry,
  }) async {
    silenceTileLoadErrors();
    final container = await tester.runAsync(
      () => seed(
        bearings: bearings,
        longSpan: longSpan,
        degenerate: degenerate,
        syncLive: syncLive,
        asViewer: asViewer,
      ),
    );
    addTearDown(container!.dispose);
    await pumpInShell(
      tester,
      container,
      syncLive: syncLive,
      textScale: textScale,
      geometry: geometry,
    );
    return container;
  }

  testWidgets(
      'the bearings list shows whole rows on a 6.1-inch phone with a realistic '
      'number of bearings', (tester) async {
    await setUpScreen(tester, bearings: 12);
    final m = measure(tester);

    expect(
      m.wholeRows,
      greaterThanOrEqualTo(2),
      reason: 'with 12 bearings on a 393x852 phone the list showed ZERO whole rows '
          'before task 11.109. Two is the floor under the test font, which wraps '
          'observer names and so measures rows ~28% taller than a device does; a '
          'phone shows three. If this has dropped, something was given permanent '
          'space that has to give it back — read the space budget at the top of '
          'position_estimation_screen.dart.',
    );
    expect(
      m.listHeight,
      greaterThanOrEqualTo(2 * m.rowHeight),
      reason: 'the list viewport must be at least two rows tall, whatever a row '
          'measures in this run',
    );
  });

  testWidgets('the panel furniture is the height the split calculation assumes',
      (tester) async {
    await setUpScreen(tester, bearings: 12);
    final m = measure(tester);
    final chrome = m.panelHeight - m.listHeight;

    expect(
      chrome,
      closeTo(declaredChromeHeight, 1.0),
      reason: 'The default map/panel split is computed from this number '
          '(_panelChromeHeight in position_estimation_screen.dart). If you have '
          'added a permanent row to the bearings panel, the list did not grow to '
          'make room for it — it shrank. Either put the new thing in a row that '
          'already exists, on the map, or in a sheet (rule 4), or change both '
          'numbers deliberately and re-run this file.',
    );
  });

  /// **Task 11.138 — what the save row's disabled reason costs, measured.**
  ///
  /// A viewer cannot save a position estimate. Before this task the reason was
  /// in a `Tooltip`, which a phone never opens, so they got a greyed SAVE
  /// POSITION and nothing to read. The sentence is on the control now, and it
  /// is not free: it is a second line inside a **fixed-height** save row, so
  /// the row had to grow or the sentence would have rendered as an overflow
  /// stripe rather than as a reason.
  ///
  /// This is the measurement the acceptance criterion asks for, taken at
  /// 6.1-inch phone geometry in the test font — which wraps text wider than a
  /// device does, so this number is an upper bound on what a person pays.
  /// Nobody who can save pays anything: the first test above measures the
  /// same panel at [declaredChromeHeight] and it has not moved.
  testWidgets('a viewer pays the declared price for the save row\'s reason, '
      'and no more', (tester) async {
    await setUpScreen(tester, bearings: 12, asViewer: true);
    final m = measure(tester);
    final chrome = m.panelHeight - m.listHeight;

    expect(
      find.text(
        'Viewers cannot save a position estimate — ask an owner to change '
        'your role.',
      ),
      findsOneWidget,
      reason: 'the reason has to be on the control, not in a tooltip',
    );
    expect(
      chrome,
      closeTo(declaredChromeHeight + declaredSaveReasonHeight, 1.0),
      reason:
          'The viewer panel\'s furniture must be exactly the owner\'s plus '
          '_saveReasonHeight (position_estimation_screen.dart). If this has '
          'moved, the reason line wrapped to a height the fixed save row was '
          'not widened for — which does not merely look wrong, it overflows.',
    );
    expect(
      m.wholeRows,
      greaterThanOrEqualTo(2),
      reason:
          'a viewer reads this screen and cannot write to it, so the '
          'bearings list is the whole of what it is for. Paying for the '
          'reason line must not cost them the second row.',
    );
  });

  testWidgets('cautions cost the bearings list nothing', (tester) async {
    // Geometry and timing chosen so the solver raises several cautions at
    // once — the state a person most wants to inspect the bearings in.
    await setUpScreen(tester, bearings: 8, longSpan: true, degenerate: true);
    final m = measure(tester);

    expect(find.textContaining('cautions'), findsOneWidget,
        reason: 'the degenerate fixture is meant to raise cautions');
    expect(
      m.panelHeight - m.listHeight,
      closeTo(declaredChromeHeight, 1.0),
      reason: 'A caution is a condition, not a fixture (rule 3): it lives in a '
          'header row that exists anyway. Before task 11.109 the cautions were '
          'an amber banner above the list, and turning them on took the list '
          'from one visible row to none — on exactly the geometry that makes a '
          'person want to look at the bearings hardest. The panel furniture '
          'must measure the same with cautions showing as without.',
    );
    expect(m.wholeRows, greaterThanOrEqualTo(2),
        reason: 'whole bearing rows must survive the worst-case cautions');
  });

  // One render per test on purpose: this screen's tile provider leaves timers
  // behind, so pumping two configurations inside one test body fails on a
  // pending timer rather than on anything about layout.
  for (final n in [2, 3, 5, 12, 25]) {
    testWidgets('$n bearings: the list still shows whole rows', (tester) async {
      await setUpScreen(tester, bearings: n);
      final m = measure(tester);
      // Two assertions, because the test font inflates a row and the design
      // guarantee is written in device pixels. `designRowHeight` is what a
      // real two-line dense `ListTile` takes on a phone; `m.rowHeight` is
      // what this run measured, which is larger.
      expect(
        m.listHeight / designRowHeight,
        greaterThanOrEqualTo(math.min(n, 2).toDouble()),
        reason: 'the list viewport must hold at least two bearing rows at '
            'device metrics, at every realistic bearing count — not only at '
            'the two the screenshot fixture happens to seed',
      );
      expect(
        m.wholeRows,
        greaterThanOrEqualTo(n >= 3 ? 2 : 1),
        reason: 'whole rows must be visible under the harsher test font too',
      );
    });
  }

  // ---------------------------------------------------------------------
  // The map half — task 11.110. 11.109 measured the panel and deliberately
  // left this alone; the same accretion had already happened here.
  // ---------------------------------------------------------------------

  /// Everything drawn over the map, **derived from the `Stack`'s own
  /// children** (task 11.166) rather than listed here by hand.
  ///
  /// This used to be two keys under a comment claiming *the clear-band
  /// assertion below is what will notice if you did not add yours*. **It
  /// would not have**, and could not: an overlay missing from the list makes
  /// the band measure *larger* than it is, so a forgotten overlay reads as a
  /// healthier screen. Two were already missing — this map's legend card
  /// (`_showLegend`) and its measure-mode overlay, neither of them keyed.
  ///
  /// See [clearBandOverStack] for how the set is derived and what it refuses.
  double clearMapBand(WidgetTester tester) =>
      clearBandOverStack(tester, const ValueKey('position-map'));

  /// The floor. A ray crossing is the thing being looked for, and the two
  /// rays that make it arrive from different directions, so a band under
  /// about two finger-widths cannot show a crossing and its neighbourhood at
  /// once. 96 is three 32pt marker heights — the marker at each observer, the
  /// crossing, and room to see they are not the same point.
  const clearBandFloor = 96.0;

  /// The whole map floor — the control row across the top, the bottom-left
  /// readout column, and [clearBandFloor] between them. Task 11.147 asserts
  /// the split against it across the text-size ladder.
  ///
  /// **Measured from the bands that are actually drawn, not mirrored from a
  /// constant** (task 11.148). It used to be written here as `8 + 48 + 94 +
  /// 96`, copying `_minMapHeight` in `position_estimation_screen.dart` —
  /// which was fine while both were constants and became a second wrong
  /// answer the moment the screen started measuring its readout column
  /// instead of predicting it. Asking the run how tall the two bands came out
  /// keeps this true at every text size without a second copy of anything.
  double minMapHeightIn(WidgetTester tester) {
    final top = tester.getRect(find.byKey(const ValueKey('position-map-top-band')));
    final bottom =
        tester.getRect(find.byKey(const ValueKey('position-map-bottom-band')));
    // Each band's own inset from the edge it sits against: 8 at the top, 12
    // at the bottom, matching the `Positioned` insets on the screen.
    return (top.height + 8.0) + (bottom.height + 12.0) + clearBandFloor;
  }

  // **Task 11.203 broke both tests below and task 11.204 fixed them, by
  // changing the measurement rather than the screen.**
  //
  // 11.203 moved the map-type selector into a second 48-pixel corner square,
  // stacked above the legend button. That cost the clear band ~56 pixels at
  // every text size — not because the square was wide, but because
  // [clearBandOverStack] charged every overlay the map's full width whatever
  // its own width, so a stacked pair of corner buttons cost the band exactly
  // what a full-width band of the same height would.
  //
  // **That was the tool disagreeing with rule 4 of the MAP SPACE BUDGET**,
  // which said in as many words that a control joining a corner cluster costs
  // the clear band nothing. Both texts were deliberate; neither had gone
  // stale; nothing could separate them until 11.203 built the first overlay on
  // this screen that was not full width. **11.204 settled the pair**: an
  // overlay is charged the width it covers, and the clear region is floored in
  // both directions ([kClearRegionMinWidth]), which is what makes "corners are
  // free" safe to write down. See `app_shell_harness.dart`.
  //
  // So the band is back over its floor — **161.8 at the default text size**,
  // which is *more* than the ~96 this screen had before 11.203, because the
  // north arrow and the two side columns had been charged full width all
  // along too. **The map did not gain a pixel. The arithmetic stopped charging
  // for pixels that were never covered.**
  const clearBandNow = 161.8;

  testWidgets('the map keeps a clear band with nothing drawn over it',
      (tester) async {
    await setUpScreen(tester, bearings: 12);
    final clear = clearMapBand(tester);
    printOnFailure('clear map band: $clear logical pixels');
    expect(
      clear,
      moreOrLessEquals(clearBandNow, epsilon: 0.5),
      reason: 'The map half of this screen carries a basemap toggle across the '
          'top, a north arrow and two buttons down the sides, and a column of '
          'readouts along the bottom — and task 11.109 made the map area '
          'smaller. This is the height of the tallest horizontal band with '
          'nothing over it: the part of the map you can actually read a ray '
          'crossing in. Read the MAP SPACE BUDGET at the top of '
          'position_estimation_screen.dart before adding anything here.\n'
          'It must meet $clearBandFloor — see the task 11.203/11.204 note '
          'above `clearBandNow` for why this number moved twice.',
    );
  });

  testWidgets('the shell does not take the map below its floor',
      (tester) async {
    // **Task 11.135 measured this state and then declined to add anything to
    // it.** With both shell banners live the clear band here was **101
    // logical pixels against a floor of 96** — five pixels of headroom. The
    // tiles-not-arriving band that four other maps in the app now show
    // measures 48 pixels and would sit below the top row, cutting the
    // largest remaining strip to **45**: less than half the floor. So this
    // screen says nothing when tiles stop arriving, deliberately, and the
    // number is written down here so the next person does not have to
    // re-measure it to find out why. See the MAP SPACE BUDGET at the top of
    // `position_estimation_screen.dart` for the rest of the verdict.
    //
    // **Task 11.189 deleted the two banners** and this screen got their
    // space back, so the five pixels of headroom above is a floor rather
    // than the current figure. **The floor is unchanged and this test is
    // kept**, pointed at the thing that is now true: whatever the sync state,
    // the shell takes nothing off the top of this screen. That is the
    // assertion that goes red the day somebody puts a third band up there,
    // which is exactly what the two banners were.
    //
    // **See the task 11.203/11.204 note above `clearBandNow`** for why this
    // number moved down and then back up past `clearBandFloor`.
    await setUpScreen(tester, bearings: 12, syncLive: true);
    final clear = clearMapBand(tester);
    printOnFailure('clear map band with the sync surface live: $clear');
    expect(
      clear,
      moreOrLessEquals(clearBandNow, epsilon: 0.5),
      reason: 'A conditional band appearing is the variable, not a list '
          'growing (task 11.109). Nothing the shell shows may take this map '
          'below its floor.',
    );
  });

  testWidgets('the "tap a ray" hint does not occupy permanent map space',
      (tester) async {
    await setUpScreen(tester, bearings: 12);
    expect(
      find.textContaining('include or exclude'),
      findsNothing,
      reason: 'Onboarding copy is read once and paid for forever (MAP SPACE '
          'BUDGET rule 2). This sentence now lives as the legend card\'s '
          'footnote, behind the legend button. If you are adding a new '
          '"did you know you can…" line, it goes there too.',
    );

    await tester.tap(find.byType(MapLegendButton));
    await tester.pump();
    expect(
      find.textContaining('include or exclude'),
      findsOneWidget,
      reason: 'and it must still be reachable — a hint nobody can find is '
          'not a saving, it is a deletion',
    );
  });

  testWidgets('dragging the panel header resizes the split', (tester) async {
    await setUpScreen(tester, bearings: 12);
    final before = measure(tester);

    // The grab target is the whole header row, not just the pill.
    final handle = find.byKey(const ValueKey('position-panel-resize'));
    expect(handle, findsOneWidget,
        reason: 'the panel must have a grab target — this screen never had one, '
            'which is why dragging it up did nothing on hardware');

    await tester.drag(handle, const Offset(0, -160));
    await tester.pump();
    final up = measure(tester);
    expect(up.listHeight, greaterThan(before.listHeight + 100),
        reason: 'dragging the header up must enlarge the bearings list');
    expect(up.wholeRows, greaterThan(before.wholeRows));

    // Down to the panel's floor, but not past the snap point. **The open
    // panel's floor still holds** — task 11.204 added a state *below* it, it
    // did not soften it.
    await tester.drag(handle, const Offset(0, 200));
    await tester.pump();
    final down = measure(tester);
    expect(down.listHeight, lessThan(up.listHeight),
        reason: 'dragging the header down must give the room back to the map');
    expect(
      down.listHeight,
      greaterThanOrEqualTo(designRowHeight),
      reason: 'Dragged down but not closed, the list must still hold one '
          'whole bearing row. A fractional floor would not have done this: a '
          'quarter of a 6.1-inch phone is less than this panel\'s furniture, '
          'so the drag would have been able to reproduce by hand the state '
          'task 11.109 exists to remove.',
    );
  });

  // =====================================================================
  // Task 11.204 — the panel closed.
  //
  // Michael: *"the non-map part of the screen should be minimizable if the
  // drag is pulled all the way down... there should still be the little grey
  // bar that allows the user to pull it back up."*
  //
  // **Two things about this state are not in the request and are asserted
  // here anyway.** A panel reachable only by a drag gesture is unreachable by
  // anybody using a screen reader, so the bar is a button with a label that
  // says what it does *now* — "Resize the bearings list" is false when the
  // list is not there. And a caution must not disappear with the panel: the
  // panel is closed precisely when somebody is working the map, which is when
  // the geometry is changing, so "Geometry too degenerate to estimate"
  // vanishing silently is the state this exists to prevent.
  // =====================================================================

  final collapsedHandle = find.byKey(const ValueKey('position-panel-expand'));

  /// Drag the panel shut. Far past the snap point on purpose — the whole
  /// point of the state is that it is where "all the way down" ends up.
  ///
  /// **Dragged from the top of the strip, not from the handle's centre.** Above
  /// the ordinary text-size slider the panel scrolls as one and its header row
  /// is taller than the panel is, so `tester.drag` on the handle would start
  /// the gesture at a point clipped off the bottom of the screen — and hit the
  /// map. That is a fact about `getCenter`, not about the screen: on a device
  /// the visible top of the strip is what a thumb lands on.
  Future<void> closeThePanel(WidgetTester tester) async {
    final panel = tester.getRect(find.byKey(const ValueKey('bearings-panel')));
    await tester.dragFrom(
      panel.topCenter + const Offset(0, 6),
      const Offset(0, 900),
    );
    await tester.pump();
  }

  testWidgets('dragging the panel all the way down closes it', (tester) async {
    await setUpScreen(tester, bearings: 12);
    final open = measure(tester);
    await closeThePanel(tester);

    expect(find.byType(ListView), findsNothing,
        reason: 'closed, the panel is the grab-handle strip and nothing else');
    final panel = tester.getRect(find.byKey(const ValueKey('bearings-panel')));
    expect(panel.height, lessThan(open.panelHeight),
        reason: 'the closed panel must be smaller than the panel it replaced');
    expect(
      panel.height,
      greaterThanOrEqualTo(48.0),
      reason: 'The pill is 4 logical pixels tall and the strip is what a '
          'gloved hand has to hit. 48 is this project\'s floor for a touch '
          'target, and it is the strip that has to meet it, not the pill.',
    );
    expect(collapsedHandle, findsOneWidget,
        reason: '"there should still be the little grey bar"');
  });

  testWidgets('the closed panel is a labelled button, not only a gesture',
      (tester) async {
    await setUpScreen(tester, bearings: 12);
    final semantics = tester.ensureSemantics();
    await closeThePanel(tester);

    // **The assertion is about the label, because the label is the defect.**
    // A `Semantics(button: true)` with the open panel's wording would pass a
    // "is it reachable" check and still tell somebody the control resizes a
    // list that is not on the screen.
    expect(
      find.bySemanticsLabel('Show the bearings list'),
      findsOneWidget,
      reason: 'a closed panel reachable only by a drag is a bearings list '
          'that has disappeared for anybody using a screen reader',
    );
    expect(
      find.bySemanticsLabel('Resize the bearings list'),
      findsNothing,
      reason: 'the open panel\'s label is false once the list is gone',
    );

    await tester.tap(collapsedHandle);
    await tester.pump();
    expect(find.byType(ListView), findsOneWidget,
        reason: 'and tapping it must actually re-open the panel');
    semantics.dispose();
  });

  testWidgets('re-opening restores the height it had, not a default',
      (tester) async {
    await setUpScreen(tester, bearings: 12);
    final handle = find.byKey(const ValueKey('position-panel-resize'));

    // Make the panel a height it would never have chosen for itself, so
    // "restored" and "recomputed the default" cannot look the same.
    await tester.drag(handle, const Offset(0, -160));
    await tester.pump();
    final resized = measure(tester);

    await closeThePanel(tester);
    await tester.tap(collapsedHandle);
    await tester.pump();

    expect(
      measure(tester).panelHeight,
      moreOrLessEquals(resized.panelHeight, epsilon: 0.5),
      reason: 'A panel that re-opens at its default has thrown away a resize '
          'the person made on purpose. The stored fraction is deliberately '
          'not cleared when the panel closes, and this is what says so.',
    );
  });

  testWidgets('a caution does not vanish with the panel', (tester) async {
    await setUpScreen(tester, bearings: 8, longSpan: true, degenerate: true);
    expect(find.byType(ListView), findsOneWidget);
    await closeThePanel(tester);

    final glyph =
        find.byKey(const ValueKey('position-panel-collapsed-cautions'));
    expect(glyph, findsOneWidget,
        reason: 'Closed, this panel is what a person is looking at while they '
            'tap rays on the map — which is exactly when the geometry '
            'changes. A caution that disappears with the panel is a caution '
            'nobody is told about at the moment it starts applying.');

    // **A shape and a word, not a colour** — amber alone says nothing to
    // roughly one man in twelve, and there is no legend on this strip.
    expect(
      tester.widget<IconButton>(glyph).icon,
      isA<Icon>().having((i) => i.icon, 'icon', Icons.warning_amber_rounded),
    );
    expect(tester.widget<IconButton>(glyph).tooltip, contains('caution'));

    // The same sheet the open panel's cautions button opens, not a second one.
    await tester.tap(glyph);
    await tester.pumpAndSettle();
    expect(find.textContaining('They do not stop you saving the estimate'),
        findsOneWidget);
  });

  testWidgets('closing the panel survives a tag change', (tester) async {
    await setUpScreen(tester, bearings: 12);
    await closeThePanel(tester);
    expect(collapsedHandle, findsOneWidget);

    // The tag selector re-creates `_EstimationContent` by key; the closed
    // state is held above it for the same reason the drag fraction is.
    final dropdown = find.byType(DropdownButton<String>);
    if (dropdown.evaluate().isNotEmpty) {
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      final items = find.byType(DropdownMenuItem<String>).hitTestable();
      if (items.evaluate().length > 1) {
        await tester.tap(items.at(1));
        await tester.pumpAndSettle();
      } else {
        Navigator.of(tester.element(dropdown)).pop();
        await tester.pumpAndSettle();
      }
    }
    expect(collapsedHandle, findsOneWidget,
        reason: 'closing the panel is something the person did, and a tag '
            'change is not them undoing it');
  });

  testWidgets('nothing on the panel overflows at phone width', (tester) async {
    await setUpScreen(tester, bearings: 25, longSpan: true, degenerate: true);
    // A layout overflow surfaces as a pending exception in the test binding.
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // Task 11.139 — the same panel, at the text size somebody's phone is
  // actually set to.
  //
  // **Nothing in this app or its screenshot harness had ever been rendered
  // at a text scale other than 1.0.** Task 11.138 sized this panel's save row
  // by measuring its sentence once, at the default, and wrote the number into
  // a fixed-height box; task 11.139 measured what that box does at the sizes
  // an iPhone can be set to. A viewer's panel **striped at xLarge — the first
  // stop on the slider above the default** — and went on striping at every
  // size above it.
  //
  // The ladder is `iosTextScalesUpward`: the seven Dynamic Type sizes on the
  // ordinary slider and the five Larger Accessibility Sizes below them. A
  // floor is reported as one of those stops rather than as a decimal, because
  // "1.27" is not a setting anybody's phone has.
  //
  // **Measured in the test font, which is about twice Roboto's width** (task
  // 11.133), so a panel wraps and stripes here at a size where a real phone
  // would not. Every floor below is therefore a **lower bound** on the real
  // one: the phone has at least this much headroom, probably more. **Nobody
  // has yet checked one of these against a device** — that is the one thing
  // this measurement is missing, and it is written in the task's report.
  // =====================================================================

  /// **The largest text size at which this panel shows neither an overflow
  /// stripe nor silently-cut text**, measured with both shell banners live —
  /// the state a real device is usually in.
  ///
  /// Before task 11.139: a viewer struck the stripe at **xLarge, one notch
  /// above the default**, and an owner had the tag bar cutting the bottom off
  /// the frequency and the tag name from **xxLarge** with nothing to show for
  /// it. Both of those are gone.
  ///
  /// Task 11.139 left it at AX2 for an owner and xxxLarge for a viewer, where
  /// the panel's furniture plus one bearing row stopped fitting above the
  /// map's own floor. **Task 11.147 is where that stopped being a ceiling:**
  /// Michael's decision is that the lower panel scrolls as one and the map
  /// keeps its 96-pixel floor, so there is no size at which the panel is
  /// asked to hold more than it has room for. **The whole ladder is clean,
  /// for both roles.**
  ///
  /// Written as the ladder's own fractions rather than as rounded decimals:
  /// AX5 is 53/17 = 3.1176…, and `scale <= 3.12` would have been false for
  /// the very stop it names.
  ///
  /// **Task 11.149 raised it the last stop, and this screen did not change.**
  /// The app shell's banners used to wrap without bound; they are now held to
  /// a quarter of the shell, so the panel has a body to scroll in even at
  /// AX5.
  const cleanThrough = <bool, double>{
    false: 53 / 17, // owner — AX5, the whole ladder
    true: 53 / 17, // viewer, who pays for the sentence saying why they cannot save
  };

  /// **The largest text size at which the map still gets its floor.**
  ///
  /// Through AX1 this is task 11.147's remedy working: the panel scrolls and
  /// the map keeps the floor. Above it the whole body left to map and panel
  /// together is smaller than that floor — 323 pixels at AX2 against a floor
  /// of about 400, 143 at AX3 — because the app shell's banners and
  /// navigation bar and this screen's tag selector have taken the rest.
  /// **Nothing in the split can fix that**, and that is why it is recorded
  /// here rather than asserted flat.
  ///
  /// **This came down a stop in task 11.148, and the reason is that the floor
  /// got honest rather than that the screen got worse.** The floor used to be
  /// the constant 246 at every text size; it is now the map's furniture
  /// measured at the size the phone is actually set to, so at AX2 it is about
  /// 400 and the 323-pixel body cannot meet it. It could not meet it before
  /// either — the clear band there was 42 pixels against a floor of 96 — the
  /// arithmetic simply did not know. **What changed at AX2 is what the screen
  /// does once the floor is unmeetable:** the split falls back to giving the
  /// panel 60%, so the map is 129 pixels there where the wrong floor used to
  /// buy it 299. Neither is a readable map. That fallback is unchanged by
  /// this task and it is the app-shell finding's to fix (task 11.149).
  ///
  /// **Task 11.149 moved it up one more stop, to AX2, by giving this screen
  /// back the body the shell had taken.** The body available to map and panel
  /// together went from 143 logical pixels at AX3 to 423, and from nothing at
  /// AX5 to 345.
  ///
  /// **Task 11.189 moved it two more, to AX4, by deleting the shell's
  /// banners outright.** Measured with the sync surface live: the body is now
  /// 583.5 pixels at AX3 against a floor of 457, and 512.5 at AX4 against a
  /// floor of 465 — so the map holds its floor at both, where before it fell
  /// back to 60% of a body nothing could fit in.
  ///
  /// **Task 11.205 closed the last gap, to AX5 — the whole ladder — and not
  /// by touching this split at all.** `_TagSelectorBar`'s label was a bare
  /// `Text` with no `maxLines`/`overflow`, so at extreme text scales it
  /// wrapped to several lines and the bar's `BoxConstraints(minHeight: 52)`
  /// let it grow to fit them — eating directly into the body left for map and
  /// panel, silently, at exactly the sizes this ladder is about. Giving the
  /// tag selector a `Flexible` + `TextOverflow.ellipsis` label (needed
  /// anyway, once the label carried a `TagColorSwatch` too) stopped it
  /// wrapping at all. **Measured with the sync surface live: at AX5 the body
  /// is now 615.5 pixels against the map's 545-pixel floor — up from the
  /// 491-pixel body recorded above, with the floor itself unchanged.** The
  /// map gets its full floor there now; nothing about `_panelFractionWhenNothingFits`
  /// changed, it simply stopped being needed.
  const mapFloorHoldsThrough = 53 / 17; // AX5 — the whole ladder

  /// **Task 11.147 — the assertion that had to arrive with the remedy.**
  ///
  /// A scrollable panel cannot show the overflow stripe, so the check above
  /// would have gone green because the failure mode was removed rather than
  /// because the screen became usable. That is the shape task 11.139 named on
  /// the Main Map — *a screen whose furniture floats over its subject cannot
  /// fail loudly* — and it is this project's oldest rule about checks that
  /// cannot tell success from their own blindness.
  ///
  /// So the ladder asserts **reachability** as well as absence of damage:
  /// with the panel scrolled to it, the last bearing row and the save control
  /// must each come into the panel — as much of each as the panel is tall
  /// enough to hold. Scrolling is only an acceptable remedy if everything is
  /// still gettable at.
  ///
  /// **"As much as the panel is tall enough to hold" is not a hedge; it is
  /// the measurement.** At AX1 the panel is 148 logical pixels and one
  /// bearing row is 175, so "fully inside the panel" is not a thing any code
  /// could achieve — that is a *legibility* limit, and it is asserted
  /// separately below by [wholeRowFitsAt] so that it is recorded rather
  /// than absorbed into this check. Conflating the two would have made this
  /// one unsatisfiable and taught somebody to relax it.
  ///
  /// **What this still cannot see.** It cannot tell whether somebody would
  /// find the scroll — there is no affordance asserted here beyond the drag
  /// pill that was already in the header — and it cannot tell whether a row
  /// showing its top two-thirds says enough to act on. Those are judgements
  /// for a device, not measurements for a harness.
  Future<void> assertReachable(
    WidgetTester tester, {
    required bool expected,
    required double scale,
  }) async {
    final panelRect =
        tester.getRect(find.byKey(const ValueKey('bearings-panel')));
    // The panel's content sits below its 1.5-pixel rule against the map, so
    // "scrolled fully into the panel" means into the box below that line.
    // Comparing against the outer rect made every stop fail by exactly 1.5.
    final content = Rect.fromLTRB(
      panelRect.left,
      panelRect.top + 1.5,
      panelRect.right,
      panelRect.bottom,
    );
    // In the fixed-frame panel this is the bearings list; in the
    // scroll-as-one panel it is the column, and the list inside it does not
    // scroll at all. `.first` is the outer one either way.
    final scroller = find
        .descendant(
          of: find.byKey(const ValueKey('bearings-panel')),
          matching: find.byType(Scrollable),
        )
        .first;

    Future<bool> canReach(Finder target) async {
      try {
        await tester.scrollUntilVisible(target, 60, scrollable: scroller);
      } catch (_) {
        return false;
      }
      if (target.evaluate().isEmpty) return false;
      // **`scrollUntilVisible` stops when the target *exists*, not when it is
      // fully in view** — the list is lazy, so a row is built the moment its
      // first pixel enters the cache extent, and where a 60-pixel step
      // happens to land decides how much of it is showing. Task 11.189 found
      // that out the hard way: it gave this screen 57 more logical pixels of
      // body by deleting the app shell's banners, the steps landed
      // differently, and the last row came to rest 15 pixels past the bottom
      // of the panel — reported as *unreachable* at the default text size,
      // which it plainly is not.
      //
      // So the scroll above finds it and this brings it in. The question
      // being asked is unchanged and is the one task 11.147 chose scrolling
      // for: **can somebody get to it at all**, not where one arbitrary
      // gesture stops.
      await tester.ensureVisible(target);
      await tester.pumpAndSettle();
      final rect = tester.getRect(target);
      final overlap =
          math.min(rect.bottom, content.bottom) - math.max(rect.top, content.top);
      // As much of it as the panel is tall enough to hold — see the note
      // above on why "fully inside" is not achievable at every size.
      return overlap >= math.min(rect.height, content.height) - 0.5 &&
          overlap > 0;
    }

    // `obs-0` is the oldest observation and the panel's default sort is by
    // time, so this is the row at the far end of the list from where the
    // panel opens — the one a clamped panel loses first.
    final row = await canReach(find.byKey(const ValueKey('bearing-row-obs-0')));
    final save = await canReach(find.byType(FilledButton));
    printOnFailure('${textScaleName(scale)}: last row reachable $row, '
        'save control reachable $save');
    expect(
      row && save,
      expected,
      reason: 'At ${textScaleName(scale)} the far end of the bearings list is '
          '${row ? '' : 'not '}reachable by scrolling and the save control is '
          '${save ? '' : 'not '}reachable.\n'
          'Task 11.147 chose scrolling over clamping precisely so that no '
          'bearing is lost at a large text size — a bearing somebody has to '
          'scroll to is still a bearing they have, and one they cannot reach '
          'at all is not. SAVE POSITION is the terminal action of the screen; '
          'somebody who can reach every bearing and not the button has been '
          'given a read-only screen without being told.\n'
          'If this has stopped being reachable at a size where it used to be, '
          'that is the remedy failing and it is the whole point of the task. '
          'If it has *become* reachable above the recorded ceiling, the app '
          'shell gave this screen its body back — raise the recorded number, '
          'because a stale one understates the app.',
    );
  }

  /// **The largest text size at which anything in the panel can be reached at
  /// all.** Above it there is no panel to scroll: the body left to map and
  /// panel together is 2.5 logical pixels at AX4 and nothing at AX5, so the
  /// bearings list has no viewport and the save button has nowhere to be.
  /// **That is a fact about the app shell, not about this screen's split**,
  /// and it is recorded rather than skipped so that nobody reads a green run
  /// as "the Position screen works at AX5".
  ///
  /// **Task 11.149: it is now the whole ladder.** The sentence above was
  /// literally true when it was written — the body was 2.5 logical pixels at
  /// AX4 and nothing at AX5 — and it was a fact about the app shell, which is
  /// exactly where it got fixed. Every bearing and the save control are
  /// reachable by scrolling at every text size an iPhone can be set to.
  const reachableThrough = 53 / 17; // AX5 — the whole ladder

  /// **The largest text size at which one whole bearing row fits in the
  /// panel at once** — the legibility half of the remedy, kept apart from the
  /// reachability half above because the two fail for different reasons and
  /// only one of them is fixable by anything on this screen.
  ///
  /// Michael's decision buys *reachability* at every size. It does not buy
  /// this, and it could not have: at AX1 the whole body left to map and panel
  /// together is 394 logical pixels, the map holds its floor — 329 of them,
  /// once task 11.148 made that floor honest about the readout column at this
  /// text size — and one bearing row at that text size is 175, taller than
  /// the 65 left over. **No split of 394 pixels shows a whole row and a
  /// readable map.**
  ///
  /// Recorded rather than asserted away, and asserted in **both** directions:
  /// if a later change makes a whole row fit at AX1, this record is wrong and
  /// understates the screen, which is how a ranking of screens goes wrong.
  ///
  /// Measured in the test font, so — as everywhere in this file — a real
  /// phone does at least this well and probably better. **Nobody has looked
  /// at one.**
  ///
  /// ## Why this was a set, and why it is a run of stops again
  ///
  /// **Task 11.149** found it could not be a threshold. The screen is not
  /// monotonic in text size: through AX2 the map held its floor and the panel
  /// paid for it, and from AX3 the body was smaller than the map's floor on
  /// its own, so `_panelFractionWhenNothingFits` handed the panel 60% and a
  /// whole row briefly fitted again — in a panel sitting over a map with a
  /// 12-pixel clear band. **That yes was not good news**, and a threshold
  /// would have quietly claimed it was.
  ///
  /// **Task 11.189 removed the app shell's two banners, and the set became a
  /// run.** Measured with the sync surface live on a 6.1-inch phone:
  ///
  /// | text size | panel | one row | whole row fits | was |
  /// |---|---|---|---|---|
  /// | Large (default) | 376 | 82 | yes | yes |
  /// | xLarge | 376 | 88 | yes | yes |
  /// | xxLarge | 337 | 94 | yes | yes |
  /// | xxxLarge | 330 | 102 | yes | yes |
  /// | AX1 | 273 | 148 | **yes** | no |
  /// | AX2 | 241 | 205 | **yes** | no |
  /// | AX3 | 127 | 244 | **no** | yes |
  /// | AX4 | 48 | 326 | no | no |
  /// | AX5 | 295 | 416 | no | no |
  ///
  /// **Two stops gained and one lost, and the lost one is the good news.**
  /// AX1 and AX2 gained a whole readable row because the panel got real room.
  /// AX3 lost its "yes", and that yes was the fallback: the body there is now
  /// large enough for the map to hold its 457-pixel floor, so the panel gets
  /// what is left instead of 60% of a body nothing could fit in. **A row that
  /// stopped fitting because the map stopped giving up is a screen that got
  /// better, not worse** — which is precisely why this file was told to check
  /// *why* before editing this set.
  ///
  /// It is kept as a set rather than rewritten as a threshold: the
  /// non-monotonicity is a property of the split, not of the shell, and the
  /// fallback that produced it is still there for any body too small for the
  /// map's floor.
  ///
  /// Taken **from [iosTextScales] by position** rather than written out as
  /// fractions, so the values compared here are the identical doubles the
  /// ladder loops over and an exact `contains` is safe. The names are
  /// asserted below, so reordering the ladder fails loudly instead of
  /// silently moving which stops this claims.
  final wholeRowFitsAt = {
    iosTextScales[3], // Large — the default
    iosTextScales[4], // xLarge
    iosTextScales[5], // xxLarge
    iosTextScales[6], // xxxLarge
    iosTextScales[7], // AX1 — gained by task 11.189
    iosTextScales[8], // AX2 — gained by task 11.189
  };
  test('the whole-row set names the text sizes its table claims', () {
    expect(
      wholeRowFitsAt.map(textScaleName).toList(),
      [
        'Large (default) (1.00x)',
        'xLarge (1.12x)',
        'xxLarge (1.24x)',
        'xxxLarge (1.35x)',
        'AX1 (1.65x)',
        'AX2 (1.94x)',
      ],
      reason: 'The set above indexes into the iOS text-size ladder. If the '
          'ladder is reordered or a stop is added, these indices now name '
          'different text sizes than the table in the comment claims — which '
          'would make this file quietly assert something nobody measured.',
    );
  });

  /// **The largest text size at which the map's clear band still meets
  /// [clearBandFloor]** — task 11.148, and the property the map floor exists
  /// to buy in the first place.
  ///
  /// `mapFloorHoldsThrough` asserts that the *split* leaves the map
  /// `minMapHeight` pixels. That is the means; this is the end. The two came
  /// apart because the reservation inside `minMapHeight` for the bottom
  /// readout column was a constant while the column is text: task 11.147
  /// measured the band at **101 logical pixels at the default and 93 at
  /// xLarge, the first notch up**, with the map's height unchanged at 246
  /// the whole way. The split was doing exactly what it was told and the
  /// thing it was told was wrong.
  ///
  /// **Measured at AX1, one stop above the ordinary slider**, which is a
  /// notch further than the task asked for. The acceptance was the ordinary
  /// slider — the sizes a great many people use — and the measurement came
  /// out better than that, so this records what it is rather than what was
  /// asked. Above it the whole body is smaller than the map's floor on its
  /// own (see [mapFloorHoldsThrough]) and no split of any kind can produce a
  /// band: that is task 11.149's shell finding, not this screen's.
  ///
  /// **AX2 since task 11.149, and AX4 since task 11.189** — both for the same
  /// reason: the app shell gave the body back, first by bounding its two
  /// banners and then by deleting them. Measured with the sync surface live:
  /// **105.8 at the default, 97.8 at xLarge, and 96.0 at every stop from
  /// xxLarge through AX4**, which is the floor exactly, because the split
  /// gives the map precisely what the band needs and no more.
  ///
  /// **AX5 is the one stop it misses, at 12 logical pixels**, and that is
  /// `_panelFractionWhenNothingFits` speaking: one bearing row there is 416
  /// pixels and the map's own floor is 545, against a body of 491. **No
  /// split of 491 pixels produces both**, which is a fact about a phone and
  /// a text size rather than about this screen's arithmetic.
  ///
  /// **Task 11.203 took it to nowhere on the ladder and task 11.204 put it
  /// back, at AX4** — and the second of those changed the measurement rather
  /// than the screen, so it is worth being exact about what moved.
  ///
  /// 11.203 moved the map-type selector off the top band into a second corner
  /// square, stacked above the legend button, exactly as asked. But
  /// [clearBandOverStack] charged **every** overlay the map's full width for
  /// its full height, whatever the overlay's actual width, so a corner cluster
  /// two 48-pixel rows tall cost the band what a full-width band of the same
  /// height would: **49.8 at the default, 40.0 from xxLarge on** — a flat
  /// ~56-pixel loss at every stop.
  ///
  /// 11.204 settled that against rule 4 of the MAP SPACE BUDGET, which had
  /// been saying the opposite in the screen's own header for a year. An
  /// overlay now costs the width it covers, and the clear region is floored in
  /// both directions ([kClearRegionMinWidth]) so that "corners are free"
  /// cannot become "an edge may be ringed with furniture". Measured with the
  /// sync surface live: **161.8 at the default, 153.8 at xLarge, and 152.0 at
  /// every stop from xxLarge through AX4.**
  ///
  /// **Those are larger than the 105.8 / 96.0 recorded above, and no pixel of
  /// map was gained.** The north arrow and the two side columns are not
  /// full-width either and never were; they had simply always been charged as
  /// though they were. **A floor that got easier to clear is a finding, not a
  /// bonus** — this screen has about 56 more pixels of measured band than the
  /// old arithmetic credited it with, and rule 1 says that is headroom to be
  /// spent deliberately, if at all, rather than a reason to stop measuring.
  ///
  /// **AX5 used to be the exception, at 12 logical pixels, because the map
  /// itself was only 138 pixels tall there** — squeezed by
  /// `_panelFractionWhenNothingFits`, whose full-width furniture then left
  /// almost nothing between top and bottom. **Task 11.205 removed the
  /// squeeze rather than the furniture.** `_TagSelectorBar`'s label no
  /// longer wraps at extreme text scales (it used to, silently eating the
  /// body available to map and panel), so at AX5 the map now reaches its
  /// full 545-pixel floor the same as every other stop — and with that much
  /// map, the same fixed-height top and bottom furniture leaves **152.0
  /// pixels**, matching xxLarge through AX4 rather than standing apart from
  /// them. See `mapFloorHoldsThrough`, which moved for the same reason.
  const clearBandHoldsThrough = 53 / 17; // AX5 — the whole ladder

  for (final asViewer in [false, true]) {
    final who = asViewer ? 'a viewer' : 'somebody who can save';
    for (final scale in iosTextScalesUpward) {
      testWidgets(
          'the bearings panel at ${textScaleName(scale)}, for $who',
          (tester) async {
        final overflows = collectLayoutOverflows();
        await setUpScreen(
          tester,
          bearings: 12,
          syncLive: true,
          asViewer: asViewer,
          textScale: scale,
        );
        final verdict = textScaleVerdict(tester, overflows);
        printOnFailure('$who at ${textScaleName(scale)}: $verdict');
        expect(
          verdict.clean,
          scale <= cleanThrough[asViewer]!,
          reason: textScaleFloorReason(
            panel: 'bearings panel, for $who',
            scale: scale,
            declaredCleanThrough: cleanThrough[asViewer]!,
            verdict: verdict,
          ),
        );

        // **The map's floor is the half that did not yield** (task 11.147).
        // Michael's decision was that the map keeps the height it needs and
        // the panel scrolls instead, so what is asserted here is the *split*:
        // the panel never takes the map below `_minMapHeight`. Before this
        // task the panel's own minimum — its furniture plus one scaled
        // bearing row — could and did push past it.
        //
        // **Asserted in both directions rather than skipped where it cannot
        // hold, because the skip is the blindness.** Above AX2 the body left
        // to map and panel *together* is smaller than the map's floor on its
        // own — 143 logical pixels at AX3 and 2.5 at AX4 — so no split of any
        // kind satisfies it and nothing on this screen could have. That is a
        // finding about the app shell, whose two banners, navigation bar and
        // this screen's tag selector all grow with the text and take the body
        // with them; it is filed as Discovered Scope, and pinning it here is
        // what stops it being quietly re-absorbed as "the map is small at big
        // text sizes".
        final clear = clearMapBand(tester);
        final mapRect = tester.getRect(find.byKey(const ValueKey('position-map')));
        final panelRect = tester.getRect(find.byKey(const ValueKey('bearings-panel')));
        final body = mapRect.height + panelRect.height;
        printOnFailure('${textScaleName(scale)}: body $body = map '
            '${mapRect.height} + panel ${panelRect.height}; clear band $clear');
        final minMapHeight = minMapHeightIn(tester);
        expect(
          mapRect.height >= minMapHeight - 1,
          scale <= mapFloorHoldsThrough,
          reason: 'At ${textScaleName(scale)} the map is ${mapRect.height} '
              'logical pixels of a $body-pixel body, against a floor of '
              '$minMapHeight. This file records that the floor holds through '
              '${textScaleName(mapFloorHoldsThrough)} and cannot above it.\n'
              'If it has stopped holding lower down the ladder, **the panel '
              'has started taking room from the map again** — that is the '
              'option Michael rejected on 2026-09-04, not a tuning question. '
              'The map is where a person judges whether the rays cross where '
              'the estimate says they do, and that does not get easier '
              'because their text is larger. See the MAP SPACE BUDGET in '
              'position_estimation_screen.dart.\n'
              'If it now holds higher up, somebody gave this screen its body '
              'back — probably in the app shell — and this number understates '
              'the app. Raise it.',
        );

        // **The end the floor is a means to** (task 11.148). Asserted beside
        // the split rather than instead of it: the map can be the height it
        // asked for and still have no band, because the reservation inside
        // that height is spent on text that grows.
        expect(
          // **A half-pixel of slack, and it is arithmetic rather than
          // generosity.** The map's height is a fraction of the body, so the
          // band lands on values like 95.99999999999997 — task 11.189 handed
          // this screen 57 more logical pixels and put AX1 exactly on the
          // floor, where a bare `>=` said no by three parts in a hundred
          // trillion. The same 0.5 every other measurement in this suite
          // uses, for the same reason.
          clear >= clearBandFloor - 0.5,
          scale <= clearBandHoldsThrough,
          reason: 'At ${textScaleName(scale)} the band of map with nothing '
              'drawn over it is $clear logical pixels against a floor of '
              '$clearBandFloor, on a map $body pixels tall.\n'
              'This is the part of the map somebody reads a ray crossing in, '
              'and it is what the map\'s floor is for. If it has stopped '
              'holding at or below ${textScaleName(clearBandHoldsThrough)}, '
              'something in the map\'s furniture grew without the '
              'reservation for it growing — read the MAP SPACE BUDGET in '
              'position_estimation_screen.dart, and note that scaling a '
              'constant by the text scaler is not a measurement.\n'
              'If it now holds higher up the ladder, the app shell gave this '
              'screen body back and this number understates it — raise it.',
        );

        // The legibility half, recorded per stop. See [wholeRowFitsAt].
        // Whichever row happens to be built — the list is lazy in the
        // fixed-frame panel, so a named row may not exist yet, and every row
        // is the same height anyway.
        final rowRect = tester.getRect(find.byType(CheckboxListTile).first);
        expect(
          panelRect.height >= rowRect.height - 0.5,
          wholeRowFitsAt.contains(scale),
          reason: 'At ${textScaleName(scale)} the panel is '
              '${panelRect.height} logical pixels and one bearing row is '
              '${rowRect.height}. This file records the exact set of text '
              'sizes at which a whole row fits — see [wholeRowFitsAt], which '
              'is a set rather than a threshold because this screen is not '
              'monotonic in text size.\n'
              'If a row now fits at a size not in that set, check *why* '
              'before adding it: a row fitting because the map gave up is '
              'not the same news as a row fitting because the panel got '
              'room. If it has stopped fitting at one that is in the set, '
              'the panel lost room it used to have and that is a regression '
              '— read the SPACE BUDGET at the top of '
              'position_estimation_screen.dart, and note that the body '
              'available to map and panel together is $body pixels here, '
              'which is mostly decided by the app shell rather than by this '
              'screen.',
        );

        await assertReachable(
          tester,
          expected: scale <= reachableThrough,
          scale: scale,
        );
      });
    }
  }

  /// **Task 11.139, the same question asked about screen size instead of text
  /// size** — and the answer `/w-11` filed as a judgement rather than a
  /// defect, now measured.
  ///
  /// `/w-11` photographed this screen on a 13-inch iPad and found it showing
  /// **four bearing rows** — the same four it shows on a phone — with **"N=5"
  /// and "5 of 5 selected" printed directly above the list.** Five is the
  /// number Michael says a real session holds, so this was the ordinary case,
  /// not a stress fixture, and the screen contradicted itself in one glance.
  ///
  /// It was a floor, not a coincidence of the fixture: the default split
  /// asked for at most four rows because a constant said four, while **666
  /// logical pixels of map sat unused below the panel.** The constant is
  /// gone; the split asks for every bearing and lets the ceiling decide.
  testWidgets('a five-bearing session fits whole on a tablet', (tester) async {
    await setUpScreen(tester, bearings: 5, geometry: tabletGeometry);
    final m = measure(tester);
    printOnFailure('tablet, 5 bearings: ${m.wholeRows} whole rows, '
        'list ${m.listHeight}, panel ${m.panelHeight}');
    expect(
      m.wholeRows,
      5,
      reason: 'On a 13-inch iPad this panel showed four of five bearings with '
          '"5 of 5 selected" written above them and most of a screen of map '
          'underneath. Every bearing must fit where there is room for it — '
          'the ceiling (60% of the surface, or whatever the map does not '
          'need) is what limits this, not a constant.',
    );
  });

  testWidgets('a tablet does not cost the phone its split', (tester) async {
    // The other half of the change above: asking for every bearing must not
    // move the phone, where the ceiling binds long before the row count does.
    await setUpScreen(tester, bearings: 5);
    final m = measure(tester);
    expect(
      m.panelHeight - m.listHeight,
      closeTo(declaredChromeHeight, 1.0),
      reason: 'the phone panel\'s furniture must be unchanged',
    );
    expect(m.wholeRows, greaterThanOrEqualTo(2));
  });

  // =====================================================================
  // Task 11.204 — the panel closed, up the text-size ladder.
  //
  // **A state nothing had ever measured.** Every number in this file is about
  // a split between a map and a panel; with the panel shut the map has the
  // whole body, and the question that matters is the one this file has always
  // asked — how much map is there with nothing drawn over it.
  //
  // It is the ladder rather than one stop because the closed strip grows with
  // the text (48 logical pixels scaled, so a gloved hand still hits it) and so
  // does the map's own furniture, and the two do not grow at the same rate.
  // =====================================================================
  /// The closed strip's height at a given text size —
  /// `_collapsedPanelHeightFor` in the screen: the 1.5-pixel hairline plus a
  /// 48-pixel touch target that scales with the text.
  double collapsedHeightFor(double scale) =>
      1.5 + math.max(48.0, TextScaler.linear(scale).scale(48.0));

  /// **The largest text size at which closing the panel gets the map to its
  /// floor**, measured with the sync surface live and twelve bearings.
  ///
  /// | text size | panel closed | clear band |
  /// |---|---|---|
  /// | Large (default) | 49.5 | 555.0 |
  /// | xLarge | 55.3 | 494.5 |
  /// | xxLarge | 61.0 | 452.4 |
  /// | xxxLarge | 66.4 | 415.6 |
  /// | AX1 | 80.6 | 344.5 |
  /// | AX2 | 94.7 | 298.4 |
  /// | AX3 | 114.4 | 164.1 |
  /// | AX4 | — | — (the panel declines to close; see below) |
  /// | AX5 | 151.1 | **12.0** |
  ///
  /// **AX5 is the stop it still misses, and closing the panel is not what
  /// fails there.** The map's own full-width furniture — the control row
  /// across the top and the readout column along the bottom — leaves 12
  /// pixels between them whatever the panel does, so no split of that body
  /// produces both a readable map and a bearing row.
  ///
  /// **Task 11.205 moved this one stop, from AX3 to AX4, for the same reason
  /// [mapFloorHoldsThrough] moved: `_TagSelectorBar`'s label no longer wraps
  /// at extreme text scales**, so the body available to a closed panel's map
  /// grew there too. Measured with the sync surface live: at AX4 closed, the
  /// map is 488.3 logical pixels and the clear band is 175.3 against the
  /// 96-pixel floor, comfortably over — where it used to fall short.
  const closedBandHoldsThrough = 47 / 17; // AX4

  group('the panel closed, at every text size', () {
    for (final scale in iosTextScalesUpward) {
      testWidgets(textScaleName(scale), (tester) async {
        await setUpScreen(
          tester,
          bearings: 12,
          syncLive: true,
          textScale: scale,
        );
        final openBand = clearMapBand(tester);
        final openPanel =
            tester.getRect(find.byKey(const ValueKey('bearings-panel'))).height;
        // Collected *after* the screen is up, so what it reports is the closed
        // strip rather than the open panel's own recorded behaviour at this
        // size — those are two different questions and this file already
        // records the other one.
        final overflows = collectLayoutOverflows();
        await closeThePanel(tester);

        final panel = tester.getRect(find.byKey(const ValueKey('bearings-panel')));
        final map = tester.getRect(find.byKey(const ValueKey('position-map')));
        final clear = clearMapBand(tester);
        printOnFailure('${textScaleName(scale)} closed: panel ${panel.height}, '
            'map ${map.height}, clear band $clear (open: $openBand)');

        // **Closing is offered only where it buys map**, which above the
        // ordinary slider it does not: at AX4 the open panel is already 47.5
        // logical pixels — squeezed under the map's floor — while the closed
        // strip is a scaled 48-pixel touch target, so closing would take room
        // *away* from the map. The screen declines, and this records where.
        final closes = panel.height < openPanel - 0.5;
        expect(
          closes,
          collapsedHeightFor(scale) < openPanel - 0.5,
          reason: 'At ${textScaleName(scale)} the open panel is $openPanel '
              'logical pixels and the closed strip would be '
              '${collapsedHeightFor(scale)}. The panel closes exactly when '
              'closing gains the map room; a control whose only effect is to '
              'make the subject smaller is not a control.',
        );
        if (!closes) return;

        expect(
          panel.height,
          greaterThanOrEqualTo(48.0),
          reason: 'At ${textScaleName(scale)} the closed panel is '
              '${panel.height} logical pixels. The bar a person pulls back up '
              'is the whole strip, and 48 is this project\'s floor for '
              'something a gloved hand has to hit. It scales with the text '
              'for the same reason every other row here does.',
        );
        expect(
          clear >= clearBandFloor - 0.5,
          scale <= closedBandHoldsThrough,
          reason: 'At ${textScaleName(scale)} the closed panel leaves '
              '$clear logical pixels of map with nothing over it, against a '
              'floor of $clearBandFloor. **Closing the panel is the one '
              'thing a person can do about a map that is too small**, so if '
              'it does not reach the floor here it does not reach it '
              'anywhere — that is a finding about the map\'s own furniture, '
              'not about the split. See the MAP SPACE BUDGET at the top of '
              'position_estimation_screen.dart.\n'
              'This file records the floor holding, with the panel closed, up '
              'to and including ${textScaleName(closedBandHoldsThrough)}.',
        );
        expect(
          clear,
          greaterThanOrEqualTo(openBand - 0.5),
          reason: 'closing the panel must not make the map worse',
        );
        final verdict = textScaleVerdict(tester, overflows);
        expect(verdict.clean, isTrue,
            reason: 'the closed strip must not stripe or silently clip at '
                'any text size: $verdict');
      });
    }
  });

  /// **Task 11.319 item 5: the map-type switch on this screen is the shared
  /// one, and it fits at every text size.**
  ///
  /// This screen had its own `SegmentedToggle` inside a near-white card, so
  /// it looked unlike the Map tab's and *Take on map*'s, and its labels did
  /// not follow the basemap (task 11.317's Discovered Scope). It now uses
  /// `MapTypeToggle`, with the width bound task 11.274 put around the old one
  /// kept: the corner column this sits in gives its children no width at all,
  /// and the toggle's `Row` of flex children throws out of layout without a
  /// bound.
  ///
  /// **Asked at every size in the ladder, with the panel open**, because the
  /// clipped-text sweep photographs this screen with the layers panel shut
  /// and never sees this control. What is checked is the toggle's own
  /// geometry and its own words: no layout overflow whose creator is the
  /// toggle, none of its three labels silently cut, and the whole thing
  /// inside the screen's edge with the corner column's 12-point margin.
  group('the map-type switch on this screen (task 11.319)', () {
    for (final scale in iosTextScales) {
      testWidgets(
          'is the shared MapTypeToggle and fits at ${textScaleName(scale)}',
          (tester) async {
        final overflows = collectLayoutOverflows();
        await setUpScreen(tester, bearings: 3, textScale: scale);

        await tester.tap(find.byTooltip('Map type'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(
          find.byType(MapTypeToggle),
          findsOneWidget,
          reason: 'this screen must use the shared control, not a copy of it',
        );

        final screenWidth =
            tester.view.physicalSize.width / tester.view.devicePixelRatio;
        final rect = tester.getRect(find.byType(MapTypeToggle));
        expect(rect.width, lessThanOrEqualTo(340.5),
            reason: "task 11.274's width bound must survive the swap");
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(screenWidth - 12 + 0.5),
            reason: 'the corner column keeps its 12-point margin');

        final verdict = textScaleVerdict(tester, overflows);
        printOnFailure('${textScaleName(scale)}: $verdict');
        expect(
          verdict.stripes.where(
            (s) => s.contains('Segment') || s.contains('MapTypeToggle'),
          ),
          isEmpty,
          reason: 'the switch overflowed at ${textScaleName(scale)}',
        );
        expect(
          verdict.clipped.where(
            (c) => const ['Terrain', 'Street', 'Satellite'].contains(c.text),
          ),
          isEmpty,
          reason: 'a label of the switch is cut off at '
              '${textScaleName(scale)}: a segment whose word cannot be read is '
              'not a choice',
        );
        for (final label in const ['Terrain', 'Street', 'Satellite']) {
          expect(find.text(label), findsWidgets);
        }
      });
    }
  });
}

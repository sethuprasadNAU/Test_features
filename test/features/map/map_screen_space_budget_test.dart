import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/navigation_target_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/map/widgets/map_furniture.dart';
import 'package:tritrack/widgets/sync_status_icon.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/text_scale_probe.dart';

/// Task 11.110 — the acceptance criterion the Main Map never had.
///
/// This is the screen a field tech spends the day on and the one with the
/// most accreted furniture in the app, and until now nothing measured it.
/// Task 11.109 found the Position screen's bearings list crowded down to one
/// row by four additions each of which was justified by the task that made
/// it; **no task's acceptance had ever been "and the screen still works with
/// all of this on it."**
///
/// The Main Map fails differently from a column-laid-out screen, which is why
/// it needs its own measurement rather than a copy of the panel's. Nothing
/// here pushes anything: every overlay simply covers a bit more of the map,
/// from an edge inward. So what is asserted is **the tallest horizontal band
/// across the full width of the map with nothing drawn over it** — the part
/// you could actually read a ray crossing in. The rules it holds are written
/// at the top of `map_screen.dart`.
///
/// Everything is measured **inside the real app shell** (see
/// `test/support/app_shell_harness.dart`), because a bare pump hands a screen
/// about a `NavigationBar`'s worth of height it never has in the app — and,
/// on the shell's bad days, two banners' worth more.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);
  // The tile signal is process-wide (every map in the app fetches through one
  // provider), so one test leaving it tripped would put a band on the next
  // test's screen and quietly shrink the number it measures.
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

  /// The floor, and the same one the Position screen's map half uses. A ray
  /// crossing is what somebody is looking for, and two rays arrive from
  /// different directions, so under about three 32pt marker heights there is
  /// no room to see a crossing *and* enough around it to know it is one.
  const clearBandFloor = 96.0;

  /// Everything drawn over the map, **derived from the `Stack`'s own
  /// children** (task 11.166) rather than listed here by hand.
  ///
  /// This used to be a list of seven keys under a comment asking the next
  /// person to add theirs to it. **A hand-maintained list acting as the
  /// control is this project's oldest defect**, and this one had already
  /// gone wrong: `map_screen.dart`'s legend card — the `Positioned` under
  /// `_showLegend` — has no key at all and was in no list, so the floor was
  /// being asserted only for the state where somebody has the legend
  /// switched off. Nothing said so, and the failure is silent in the
  /// dangerous direction: a missing overlay makes the band read *larger*
  /// than it is.
  ///
  /// See [clearBandOverStack] for how the set is derived and what it refuses.
  double clearMapBand(WidgetTester tester) =>
      clearBandOverStack(tester, const ValueKey('main-map'));


  /// A layout overflow, or a tile fetch, surfaces as a framework error. Drop
  /// exactly the tile-load noise — every real error still reports, which is
  /// what makes the overflow test below mean anything.
  void silenceTileLoadErrors() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  Future<ProviderContainer> setUpScreen(
    WidgetTester tester, {
    bool syncLive = false,
    bool navigating = false,
    int observations = 12,
    bool nothingToShow = false,
    bool tilesNotLoading = false,
    double textScale = 1.0,
  }) async {
    silenceTileLoadErrors();
    if (tilesNotLoading) {
      for (var i = 0; i < TileFetchHealth.failureThreshold; i++) {
        TileFetchHealth.instance.recordNetworkFailure();
      }
    }
    // Task 11.103's new band appears only when nothing supplied a place:
    // no fix, nothing recorded, no project extent. Reproducing that here
    // means stripping the fixture's extent as well as its recordings — an
    // extent alone is enough to keep the band away.
    final project = nothingToShow
        ? sampleProject(id: 'project-1', ownerUserId: 'user-1').copyWith(
            bboxMinLat: null,
            bboxMinLon: null,
            bboxMaxLat: null,
            bboxMaxLon: null,
          )
        : sampleProject(id: 'project-1', ownerUserId: 'user-1');
    final user = sampleUser(id: 'user-1', email: 'a@example.com');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        if (syncLive)
          syncControllerProvider.overrideWith(LiveSyncStatusController.new),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      final obsRepo = await container.read(observationRepositoryProvider.future);
      await userRepo.insert(user);
      await projectRepo.insert(project);
      await tagRepo.insert(tag);
      final base = DateTime.utc(2026, 8, 31, 12);
      for (var i = 0; i < (nothingToShow ? 0 : observations); i++) {
        await obsRepo.insert(
          sampleObservation(
            id: 'obs-$i',
            projectId: project.projectId,
            userId: user.userId,
            tagId: tag.tagId,
            sessionId: null,
            latitude: 35.10 + i * 0.004,
            longitude: -111.70 + i * 0.006,
          ).copyWith(
            trueNorthBearing: 60.0 + (i * 37) % 120,
            magneticBearing: 60.0 + (i * 37) % 120,
            timestampUtc: base.add(Duration(minutes: i)),
            timestampLocal: base.add(Duration(minutes: i)),
          ),
        );
      }
      await container.read(activeProjectIdProvider.notifier).set(project.projectId);
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const MapScreen(),
      tabIndex: 0, // **Map** / Record / Compass / Position / More
      textScale: textScale,
    );

    // Set after the first build: the notifier restores itself from
    // preferences on build, so a value written before the screen mounts is
    // overwritten by the restore.
    if (navigating) {
      container.read(navigationTargetProvider.notifier).set(
            const NavigationTarget(
              label: 'Coco — last estimate',
              latitude: 35.14,
              longitude: -111.66,
            ),
          );
      await tester.pump();
    }
    return container;
  }

  testWidgets('the map keeps a clear band with nothing drawn over it',
      (tester) async {
    await setUpScreen(tester);
    final clear = clearMapBand(tester);
    printOnFailure('clear map band: $clear logical pixels');
    expect(
      clear,
      greaterThanOrEqualTo(clearBandFloor),
      reason: 'This is the height of the tallest horizontal band of the Main '
          'Map with nothing drawn over it — the part you can actually read a '
          'ray crossing in. Nothing on this screen is laid out in a column, '
          'so an addition never looks like it pushed anything; it just '
          'covered a bit more map. Read the SPACE BUDGET at the top of '
          'map_screen.dart before adding anything here.',
    );
  });

  testWidgets(
      'the map keeps its clear band with every band this screen can raise at '
      'once', (tester) async {
    // The state a real device is usually in, not the calm one: the sync
    // status icon showing *and* a navigation target running. Task 11.109's
    // lesson is that **a conditional band appearing is the variable**, not a
    // list growing — that screen showed the same single row at 2 bearings
    // and at 200, and what flipped it to none was a caution.
    //
    // **Task 11.189 changed what "everything live" means on this screen and
    // did not relax the floor.** The app shell's two banners used to be part
    // of it, ~76 logical pixels off the top of every tab; they are gone, and
    // what this now switches on is the 28-pixel status icon above the "+",
    // which `clearBandOverStack` counts like any other overlay because it
    // derives the overlay set from the `Stack`'s own children.
    await setUpScreen(tester, syncLive: true, navigating: true);
    expect(
      find.byType(SyncStatusIcon),
      findsOneWidget,
      reason: 'the sync status icon is meant to be up — a fixture that '
          'quietly stopped producing it would leave this measuring the calm '
          'screen while claiming to measure the busy one',
    );
    expect(find.textContaining('Coco'), findsWidgets,
        reason: 'the navigation banner is meant to be up');

    final clear = clearMapBand(tester);
    printOnFailure('clear map band, everything live: $clear logical pixels');
    expect(
      clear,
      greaterThanOrEqualTo(clearBandFloor),
      reason: 'The shell alone takes about 76 logical pixels off the top of '
          'this screen, and every test that pumps it bare is blind to that. '
          'If this has dropped below the floor, the fix is not a smaller '
          'floor — it is one of the homes listed in rule 3 of the budget.',
    );
  });

  /// **Where Michael asked for it: "right above the + on the map"** (task
  /// 11.189).
  ///
  /// The two are one anchor, not two things at the same corner — rule 4 of
  /// this file's subject's SPACE BUDGET, which exists because a `Stack` says
  /// nothing when two children overlap and the later one simply paints over
  /// the earlier.
  group('the sync status icon (task 11.189)', () {
    testWidgets('sits directly above the "+" and nothing covers either',
        (tester) async {
      await setUpScreen(tester, syncLive: true, navigating: true);

      final icon = tester.getRect(find.byType(SyncStatusIcon));
      final fab = tester.getRect(find.byType(FloatingActionButton));
      expect(icon.bottom, lessThanOrEqualTo(fab.top + 0.5),
          reason: 'above the "+", not over it');
      expect(
        icon.center.dx,
        closeTo(fab.center.dx, 0.5),
        reason: 'centred on the same column, so the two read as one cluster '
            'rather than as two controls that happen to be near each other',
      );
      expect(
        fab.top - icon.bottom,
        lessThan(24),
        reason: 'and close enough to it to be read as belonging with it',
      );
    });
  });

  testWidgets('the navigation banner does not cover the north arrow',
      (tester) async {
    await setUpScreen(tester, navigating: true);
    // Both were `left: 12, top: 56` until task 11.110, and a `Stack` says
    // nothing when two children share an anchor — the later one simply
    // paints over the earlier. On a rotated map that hid the only control
    // that puts the map back north-up, while navigating, which is exactly
    // when somebody is least able to work out what happened.
    final arrows = find.byType(MapNorthArrow);
    if (arrows.evaluate().isNotEmpty) {
      final arrow = tester.getRect(arrows);
      final band = tester.getRect(find.byKey(const ValueKey('map-left-band')));
      expect(band.contains(arrow.topLeft), isTrue,
          reason: 'the arrow must live inside the one left-hand column, not '
              'at its own anchor underneath the banner');
    }
  });

  testWidgets(
      'the clear band survives the new-project band, with everything else '
      'live too', (tester) async {
    // Task 11.103 put a sentence on this screen — "TriTrack does not know
    // where you are…" — and a sentence is furniture. **No task's acceptance
    // has ever been "and the screen still works with all of this on it"**
    // (task 11.109), so this is that acceptance, measured in the state where
    // the new band is up *and* both shell banners *and* navigation.
    //
    // It costs the screen nothing on any day after the first: the band is
    // gone the moment a fix, a recording or a project extent arrives, which
    // is why the two tests above — which have all three — never see it.
    await setUpScreen(
      tester,
      nothingToShow: true,
      syncLive: true,
      navigating: true,
    );
    expect(
      find.byKey(const ValueKey('map-nothing-to-show')),
      findsOneWidget,
      reason: 'the band this test exists to measure is not up',
    );

    final clear = clearMapBand(tester);
    printOnFailure('clear map band, new project + everything live: '
        '$clear logical pixels');
    expect(clear, greaterThanOrEqualTo(clearBandFloor));
  });

  testWidgets(
      'the clear band survives the tiles-not-loading band, with everything '
      'else live too', (tester) async {
    // Task 11.134 put a second sentence in the left-hand column: tiles have
    // stopped arriving. **A conditional band appearing is the usual
    // variable** (task 11.109), and this one appears in the state a field
    // technician is most often in — out of signal — so it is measured in the
    // worst case rather than the calm one: tiles failing *and* the new-project
    // band up *and* both shell banners *and* navigation.
    await setUpScreen(
      tester,
      tilesNotLoading: true,
      nothingToShow: true,
      syncLive: true,
      navigating: true,
    );
    expect(
      find.byKey(const ValueKey('map-tiles-not-loading')),
      findsOneWidget,
      reason: 'the band this test exists to measure is not up',
    );

    final clear = clearMapBand(tester);
    printOnFailure('clear map band, tiles failing + everything live: '
        '$clear logical pixels');
    // **This is the measurement that changed the design.** The band first
    // carried three sentences — what had happened, what still worked, and
    // that the app could not tell why — and at 245 logical pixels wide those
    // wrap to four lines. Measured in this worst case it left **14 logical
    // pixels** of clear map against a floor of 96: the band was, on its own,
    // most of the screen's remaining budget. The sentence on the map is one
    // line now and the rest is one tap away, which is rule 3's answer rather
    // than a smaller floor.
    expect(clear, greaterThanOrEqualTo(clearBandFloor));
  });

  testWidgets('the clear band with the legend switched on', (tester) async {
    // **The state the old instrument could not see** (task 11.166). The
    // legend card is a `Positioned` with no key, and it was in neither
    // screen's hand-kept overlay list, so every number above was measured
    // with it off — which is its default, and not the state of anybody who
    // has ever pressed Legend in Layers & Filters. It stays on until they
    // press it again.
    await setUpScreen(tester, syncLive: true, navigating: true);
    final withoutLegend = clearMapBand(tester);

    await tester.tap(find.byTooltip('Layers & filters'));
    await tester.pumpAndSettle();
    final legendTile = find.widgetWithText(SwitchListTile, 'Legend');
    await tester.scrollUntilVisible(legendTile, 120,
        scrollable: find.byType(Scrollable).last);
    await tester.pumpAndSettle();
    expect(legendTile, findsOneWidget,
        reason: 'the Legend switch is how a person turns this overlay on');
    await tester.tap(legendTile);
    await tester.pumpAndSettle();
    // Close the sheet, so what is measured is the map and not the map under
    // a sheet.
    Navigator.of(tester.element(legendTile)).pop();
    await tester.pumpAndSettle();

    expect(find.byType(MapLegendCard), findsOneWidget,
        reason: 'the legend is meant to be on the map now');

    // **Task 11.189: the legend clears the whole bottom-right column, not
    // just the "+".** That anchor was the constant 84 — the button's 56, its
    // 20-pixel inset and an 8-pixel gap — written here while the widget it
    // described lived forty lines away in `map_screen.dart`. The sync status
    // icon then joined that column *conditionally*, so no constant could have
    // been right in both states; the height `_recordFabHeight` was already
    // measuring was read by nothing at all, and now it is what this clears.
    final columnRect =
        tester.getRect(find.byKey(const ValueKey('map-record-fab')));
    expect(
      tester.getRect(find.byType(MapLegendCard)).bottom,
      lessThanOrEqualTo(columnRect.top + 0.5),
      reason: 'the legend sits at the same corner as the sync status icon and '
          'the "+", and a Stack says nothing when two children overlap — the '
          'later one simply paints over the earlier',
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('map-record-fab')),
        matching: find.byType(SyncStatusIcon),
      ),
      findsOneWidget,
      reason: 'and the icon really is in that column, so the measurement '
          'above is of the thing it claims to be about rather than of the '
          '"+" on its own',
    );

    final withLegend = clearMapBand(tester);
    printOnFailure('clear map band: $withoutLegend without the legend, '
        '$withLegend with it');

    // **The band does not move: 438 logical pixels either way** (task
    // 11.204 re-measured this; it was 338 without the legend and 303 with it
    // immediately before, and the sentence here still claimed 229 either
    // way, which had been true of neither for some time).
    //
    // **The zero is now earned rather than lucky.** The legend is a card in
    // the bottom-right corner, and an overlay is charged the width it
    // actually covers, so the full-width strip of map above the bottom
    // furniture is unchanged by it. Before 11.204 the card was charged the
    // map's whole width and cost 35 pixels it never covered.
    //
    // Asserting the rectangle is in the derived set is what separates "the
    // legend costs nothing" from "the measurement cannot see the legend",
    // and without it this test would pass just as well if the legend were
    // invisible to the measurement — which is the defect it was written for.
    final (_, overlays) = stackSubjectAndOverlays(
        tester, const ValueKey('main-map'));
    final card = tester.getRect(find.byType(MapLegendCard));
    expect(
      overlays.any((r) => (r.top - card.top).abs() < 0.5 &&
          (r.bottom - card.bottom).abs() < 0.5),
      isTrue,
      reason: 'the legend card spans ${card.top}-${card.bottom} over the map, '
          'so that span must be one of the '
          '${overlays.length} rectangles this measurement derived from the '
          'Stack. If it is not, the number above is about a screen that is '
          'not the one on the phone.',
    );
    expect(
      withLegend,
      lessThanOrEqualTo(withoutLegend),
      reason: 'a card drawn over the map cannot make the clear band larger',
    );
    expect(
      withLegend,
      greaterThanOrEqualTo(clearBandFloor),
      reason: 'The legend is opt-in, but it is not transient: it stays on '
          'until somebody turns it off, so it is permanent space by rule 3 of '
          "the SPACE BUDGET at the top of map_screen.dart for anybody who "
          'uses it. Read that before adding a row to it.',
    );
  });

  testWidgets('nothing on the map overflows at phone width', (tester) async {
    await setUpScreen(tester, syncLive: true, navigating: true);
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // Task 11.139 — the map at the text size somebody's phone is set to.
  //
  // **This screen fails in a third way, and it is neither of the two that
  // task named.** Nothing here stripes at any text size on the ladder and
  // nothing is silently cut, because nothing on a map pushes anything: every
  // overlay just covers a bit more of it. What happens instead is that the
  // overlays grow with their labels and **the band of map with nothing drawn
  // over it — the part you can read a ray crossing in — closes up.**
  //
  // Measured with both shell banners live and a navigation target set, which
  // is the busiest ordinary state this screen has:
  //
  // | text size            | 11.139 | after 11.149 |
  // |----------------------|--------|--------------|
  // | Large (the default)  | 229 px | 229 px       |
  // | xLarge               | 191 px | 191 px       |
  // | xxLarge              | 152 px | 152 px       |
  // | xxxLarge             | 111 px | 134 px       |
  // | AX1                  |  46 px | 102 px       |
  // | AX2                  |  14 px |  30 px       |
  // | AX3                  |   8 px |  14 px       |
  // | AX4                  |   0 px |  14 px       |
  // | AX5                  |    —   |   8 px       |
  //
  // The floor is 96 — three 32pt marker heights, so a crossing and enough
  // around it to see that it is one. **The map holds its floor through the
  // whole ordinary Dynamic Type slider and loses it at the first
  // accessibility size.** Task 11.139 did not try to fix that: it is not a
  // fixed height anywhere, it is the sum of every label on the screen getting
  // bigger, and what to give up is a design decision rather than a mechanical
  // one. It is written down instead, and filed for the planning session.
  //
  // **Task 11.149 moved it one stop, and nothing on this screen changed.**
  // The app shell's two banners used to wrap without bound and take the body
  // with them; holding them to a quarter of the shell handed this map more
  // surface at every accessibility size and the clear band grew with it.
  // **Task 11.189 then deleted the banners outright**, which hands it the
  // rest — 109 logical pixels at the default text size and 623 at AX5. **The
  // map's own furniture is untouched by both**, and the stop below is
  // re-derived rather than assumed: it is measured on every run by the loop
  // that follows.
  // =====================================================================

  /// The largest text size at which the clear band still meets its floor.
  /// Written as the ladder's own fraction — AX4 is 47/17.
  ///
  /// **Raised from xxxLarge to AX1 by task 11.149, from AX1 to AX3 by task
  /// 11.189**, which gave every screen in the app the whole shell back by
  /// deleting the two banners above every tab, **and from AX3 to AX4 by task
  /// 11.204**, which changed the measurement rather than the screen.
  /// **Nothing on this screen was changed to earn any of the three moves.**
  ///
  /// **A floor that got easier to clear is a finding, not a bonus, so here is
  /// what task 11.204 did and what it did not do.** An overlay is now charged
  /// the width it actually covers rather than the map's full width, and this
  /// screen has three overlays that are not full width: the north arrow, the
  /// layers-and-location column and the legend card. **The map did not gain a
  /// pixel; the arithmetic stopped charging for pixels that were never
  /// covered.** The legend card is the clearest case — switching it on used
  /// to cost 35 logical pixels of band and now costs **zero**, because it is
  /// a card in a corner and there is a full-width strip of map above it
  /// either way. See [kClearRegionMinWidth] in `app_shell_harness.dart` for
  /// what stops that becoming a licence to ring the map with furniture.
  ///
  /// Measured with everything on this screen live — the status icon and a
  /// navigation target — on a 6.1-inch phone, in the test font (task 11.133),
  /// so a real phone wraps later and these are lower bounds. The middle
  /// column is what the same run said before task 11.204, kept because the
  /// difference is the whole finding:
  ///
  /// | text size | band, before 11.204 | clear band |
  /// |---|---|---|
  /// | Large (default) | 338 | 438 |
  /// | xLarge | 326 | 426 |
  /// | xxLarge | 297 | 397 |
  /// | xxxLarge | 289 | 389 |
  /// | AX1 | 254 | 354 |
  /// | AX2 | 169 | 269 |
  /// | AX3 | 115 | 215 |
  /// | AX4 | **21** | 121 |
  /// | AX5 | **14** | **14** |
  ///
  /// **AX5 is the one that did not move, and it is the informative row.**
  /// Everywhere else the gain is a flat 100 pixels — the north arrow and the
  /// side column, charged full width before and not charged now. At AX5 the
  /// map's furniture has grown until the *full-width* bands alone leave 14
  /// pixels between them, so nothing about width helps. The one accessibility
  /// size it still misses is the one task 11.139 wrote down and declined to
  /// fix: it is not a fixed height anywhere, it is every label on the screen
  /// growing at once, and what to give up is a design decision rather than a
  /// mechanical one.
  const bandHoldsThrough = 47 / 17;

  for (final scale in iosTextScalesUpward) {
    testWidgets('the map\'s clear band at ${textScaleName(scale)}',
        (tester) async {
      final overflows = collectLayoutOverflows();
      await setUpScreen(tester,
          syncLive: true, navigating: true, textScale: scale);
      final clear = clearMapBand(tester);
      final verdict = textScaleVerdict(tester, overflows);
      printOnFailure('clear band at ${textScaleName(scale)}: '
          '${clear.toStringAsFixed(0)}px — $verdict');

      expect(
        verdict.clean,
        isTrue,
        reason: 'The map has never striped or silently cut text at any text '
            'size, because its furniture sits over the map rather than in a '
            'column with it. If that has changed, something on this screen '
            'is now laid out in a box that cannot grow: $verdict',
      );
      expect(
        clear >= clearBandFloor,
        scale <= bandHoldsThrough,
        reason: 'The clear band is ${clear.toStringAsFixed(0)} logical pixels '
            'at ${textScaleName(scale)}, against a floor of $clearBandFloor. '
            'This screen holds its floor across the ordinary text-size slider '
            'and loses it at the accessibility sizes, where every label grows '
            'at once. If the band now holds at a size recorded as too big, '
            'raise the recorded stop; if it has stopped holding at one '
            'recorded as fine, an overlay grew — read the MAP SPACE BUDGET at '
            'the top of map_screen.dart.',
      );
    });
  }
}

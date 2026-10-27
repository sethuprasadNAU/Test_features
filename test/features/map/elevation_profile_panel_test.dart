import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/features/map/widgets/elevation_profile_panel.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

import '../../support/app_shell_harness.dart' show usePhoneGeometry;
import '../../support/fake_path_provider.dart';
import '../../support/roboto_font.dart';
import '../../support/text_scale_probe.dart';

/// Task 11.207 — the profile panel, on the measure tool and on navigation.
///
/// **Two of the things this asserts are easy to fake and are written not to
/// be.** The totals must not depend on the panel's height, so they are read
/// at two heights and compared rather than merely being present at one. And
/// the lifecycle rule carries a **positive control**: "no update while
/// paused" passes on its own if the panel never built, never subscribed, or
/// never had a fix to take, so the same test first watches an update *be*
/// taken while resumed.
void main() {
  setUp(installFakePathProvider);

  /// The tile the fixtures live in: 35.0–35.1 N, 111.7–111.6 W.
  const tile = DemTileId(350, -1117);

  /// A ramp up to a plateau and down again, as a function of longitude —
  /// climb 200 m, descent 150 m between the two points below, by
  /// construction. Same fixture as `terrain_profile_test.dart`, where the
  /// arithmetic is asserted exactly; here it is a known answer to look for on
  /// screen.
  double tent(double lon) {
    if (lon <= -111.66) return (lon + 111.70) * 10000.0;
    if (lon <= -111.64) return 400.0;
    return 400.0 - (lon + 111.64) * 7500.0;
  }

  const start = ll.LatLng(35.02, -111.68);
  const end = ll.LatLng(35.02, -111.62);

  /// Writes the fixture tile where the panel's own `DemTileStore` will find
  /// it. **Called inside `runAsync`** — this is file work on real time, and
  /// awaiting it under the fake pump clock is how a widget test hangs for ten
  /// minutes instead of failing.
  Future<void> seedTerrain([double Function(double lon)? elevation]) async {
    final surface = elevation ?? tent;
    final spec = tile.gridSpec();
    final data = Float64List(spec.ncols * spec.nrows);
    for (var r = 0; r < spec.nrows; r++) {
      for (var c = 0; c < spec.ncols; c++) {
        data[r * spec.ncols + c] =
            surface(spec.xllCorner + (c + 0.5) * spec.cellSizeDegrees);
      }
    }
    await DemTileStore().saveTile(
      tile,
      ElevationGrid(
        ncols: spec.ncols,
        nrows: spec.nrows,
        xllCorner: spec.xllCorner,
        yllCorner: spec.yllCorner,
        cellSizeDegrees: spec.cellSizeDegrees,
        data: data,
      ),
    );
  }

  Widget host(ProviderContainer container, Widget panel, {Size? size}) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: MediaQueryData(size: size ?? const Size(390, 844)),
          child: Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: panel),
          ),
        ),
      ),
    );
  }

  /// Pumps in real time until [until] holds, so the panel's own file reads
  /// and provider work can finish. Polled rather than slept for a guessed
  /// duration.
  ///
  /// **Task 11.210.** This used to return silently when [budget] ran out,
  /// so a caller could not tell "the condition became true" from "I gave up
  /// waiting for it" — the timeout could pass for success. It now throws,
  /// naming [reason] and how long it waited, the same shape as
  /// `pumpInAppShell` in `test/support/app_shell_harness.dart` and the
  /// `expect(..., reason: 'the map never built')` in
  /// `map_with_no_position_test.dart`.
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() until, {
    required String reason,
    Duration budget = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(budget);
    while (!until() && DateTime.now().isBefore(deadline)) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await tester.pump();
    if (!until()) {
      throw TestFailure(
        'pumpUntil: "$reason" did not become true within ${budget.inSeconds}s',
      );
    }
  }

  /// The panel's one header line, whatever it currently says.
  String headerText(WidgetTester tester) {
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((s) => s.contains('·'));
    return texts.isEmpty ? '' : texts.first;
  }

  bool headerHasTotals(WidgetTester tester) => headerText(tester).contains('↑');

  group('the totals on the measure tool', () {
    testWidgets('the totals on screen are the terrain\'s, exactly',
        (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await seedTerrain();
        await tester.pumpWidget(
          host(
            container,
            const ElevationProfilePanel(
              origin: start,
              destination: end,
              icon: Icons.straighten,
              lineColor: Colors.black,
              action: SizedBox.shrink(),
            ),
          ),
        );
        await pumpUntil(
          tester,
          () => headerHasTotals(tester),
          reason: 'the header showed climb/descent totals',
        );
      });

      final header = headerText(tester);
      expect(header, contains('↑200 m'),
          reason: 'the fixture climbs 200 m from 200 m to a 400 m plateau');
      expect(header, contains('↓150 m'),
          reason: 'and falls 150 m from the plateau to 250 m');
    });

    testWidgets(
        'the same line gives the same totals at two panel heights and on two '
        'screens', (tester) async {
      // **The number must not depend on the furniture it is shown in.** The
      // panel is drag-resizable and the chart's width follows it, so a total
      // derived from the drawing rather than from the DEM would move when
      // somebody dragged the handle — and would look perfectly reasonable
      // both times.
      //
      // **The terrain here is ridges rather than the smooth tent**, and that
      // is the whole point: a tent's totals are its two ends and its plateau,
      // so *any* sampling gets them right and the comparison would pass
      // against a profile sampled off the chart's own width. Ridges finer
      // than a coarse sampling would resolve make the totals sensitive to how
      // the line was sampled, which is what this is trying to detect.
      double ridges(double lon) {
        final phase = ((lon + 111.70) / 0.004) % 1.0;
        return 400.0 * (phase < 0.5 ? phase * 2 : (1 - phase) * 2);
      }

      final container = ProviderContainer();
      addTearDown(container.dispose);

      late String short;
      late String tall;
      late String otherScreen;
      await tester.runAsync(() async {
        await seedTerrain(ridges);
        await tester.pumpWidget(
          host(
            container,
            const ElevationProfilePanel(
              origin: start,
              destination: end,
              icon: Icons.straighten,
              lineColor: Colors.black,
              action: SizedBox.shrink(),
            ),
          ),
        );
        await pumpUntil(
          tester,
          () => headerHasTotals(tester),
          reason: 'the header showed climb/descent totals (short panel)',
        );
        short = headerText(tester);

        // Drag the handle up: a much taller panel and a much wider chart.
        await tester.drag(
          find.byType(ElevationProfilePanel),
          const Offset(0, -180),
        );
        await pumpUntil(
          tester,
          () => headerHasTotals(tester),
          reason: 'the header showed climb/descent totals (tall panel)',
        );
        tall = headerText(tester);

        // And a fresh panel on a tablet-sized screen, so the comparison is
        // not only between two states of one widget that computed once.
        await tester.pumpWidget(
          host(
            container,
            const ElevationProfilePanel(
              key: ValueKey('second'),
              origin: start,
              destination: end,
              icon: Icons.straighten,
              lineColor: Colors.black,
              action: SizedBox.shrink(),
            ),
            size: const Size(1024, 1366),
          ),
        );
        await pumpUntil(
          tester,
          () => headerHasTotals(tester),
          reason: 'the header showed climb/descent totals (other screen)',
        );
        otherScreen = headerText(tester);
      });

      expect(short, contains('↑'),
          reason: 'the ridged fixture must produce a climb at all, or this '
              'test is comparing two blanks');
      expect(
        tall,
        short,
        reason: 'the totals are a measurement of the ground, not of the '
            'panel — dragging the handle must not change them',
      );
      expect(
        otherScreen,
        short,
        reason: 'nor may they depend on the size of the phone',
      );
    });

    testWidgets('with no terrain downloaded it says so and still measures',
        (tester) async {
      // Nothing seeded: `composeForBounds` finds no tiles at all.
      final container = ProviderContainer();
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          host(
            container,
            const ElevationProfilePanel(
              origin: start,
              destination: end,
              icon: Icons.straighten,
              lineColor: Colors.black,
              action: SizedBox.shrink(),
            ),
          ),
        );
        await pumpUntil(
          tester,
          () => find.text(kNoElevationDataMessage).evaluate().isNotEmpty,
          reason: 'the "no elevation data" message appeared',
        );
      });

      expect(find.text(kNoElevationDataMessage), findsOneWidget);
      expect(headerText(tester), contains('km'),
          reason: 'losing the terrain must not lose the distance and bearing');
      expect(headerHasTotals(tester), isFalse,
          reason: 'and a climb of "0 m" over ground nobody has any elevation '
              'for would be a made-up number, not a missing one');
    });
  });

  group('the one row that is the whole panel when it is shut', () {
    /// The rendered header paragraph, which is the thing that either wrapped
    /// or hid something.
    /// The `Text` carries a `semanticsLabel`, so the render object at the
    /// widget itself is the annotation, not the paragraph — the paragraph is
    /// the `RichText` inside it.
    RenderParagraph headerParagraph(WidgetTester tester) =>
        tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is Text && (w.data ?? '').contains('·'),
            ),
            matching: find.byType(RichText),
          ),
        );

    Future<double> panelHeightWithLabel(
      WidgetTester tester,
      String label,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      late double height;
      await tester.runAsync(() async {
        await seedTerrain();
        await tester.pumpWidget(
          host(
            container,
            ElevationProfilePanel(
              key: ValueKey(label),
              origin: start,
              destination: end,
              icon: Icons.navigation,
              lineColor: Colors.blue,
              label: 'To $label',
              initiallyCollapsed: true,
              action: const SizedBox.shrink(),
            ),
          ),
        );
        await pumpUntil(
          tester,
          () => headerHasTotals(tester),
          reason: 'the header showed climb/descent totals',
        );
        height = tester.getSize(find.byType(ElevationProfilePanel)).height;
      });
      return height;
    }

    testWidgets('a long target name wraps to a second line instead of being '
        'hidden', (tester) async {
      // **Michael, walking with it, 2026-09-09:** the bar read *"To estimated
      // position · 8.96 km …"* with the rest behind an ellipsis **and no way
      // to see it**. This row is the whole panel when it is shut, so there is
      // nowhere else to read what it drops.
      //
      // Asserted two ways, because either alone is weak. `didExceedMaxLines`
      // says nothing was cut. The height comparison says the panel *grew* to
      // hold it — and it is a comparison that cannot pass by both sides
      // failing the same way: if the long label were being truncated instead
      // of wrapped, the two panels would be exactly the same height.
      //
      // **The wrap is capped at two lines and that is a measured cap**, not
      // an unbounded wrap: uncapped, this row took the map's clear band to 37
      // logical pixels at AX4 against a floor of 96. The name here is longer
      // than any real target's and still fits in two, which is the case this
      // is about; what the cap gives up is the far end of a very long name at
      // 2.76× text, and the panel's own layout note carries that trade.
      final shortPanel = await panelHeightWithLabel(tester, 'A');
      final longPanel = await panelHeightWithLabel(
        tester,
        'estimated position for the collared female at the north ridge',
      );

      expect(
        headerParagraph(tester).didExceedMaxLines,
        isFalse,
        reason: 'the header is cutting text off again, and there is nowhere '
            'else on this panel to read what it cut',
      );
      expect(
        longPanel,
        greaterThan(shortPanel),
        reason: 'the panel did not grow for the longer name, which means the '
            'name is being hidden rather than wrapped',
      );
    });
  });

  group('the navigation panel, which follows the person walking', () {
    /// A fix at [point], with an accuracy good enough that the panel's own
    /// 10 m floor is what decides whether somebody has moved.
    Position fixAt(ll.LatLng point, {double accuracy = 5}) => Position(
          latitude: point.latitude,
          longitude: point.longitude,
          timestamp: DateTime.utc(2026, 9, 9, 12),
          accuracy: accuracy,
          altitude: 1500,
          altitudeAccuracy: 4,
          heading: 0,
          headingAccuracy: 5,
          speed: 0,
          speedAccuracy: 0,
        );

    testWidgets(
        'it takes fixes while resumed and takes none while paused '
        '(both halves)', (tester) async {
      final fixes = StreamController<Position>.broadcast();
      addTearDown(fixes.close);
      final container = ProviderContainer(
        overrides: [gpsPositionProvider.overrideWith((ref) => fixes.stream)],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await seedTerrain();
        await tester.pumpWidget(
          host(
            container,
            const ElevationProfilePanel(
              origin: null, // follow the fix
              destination: end,
              icon: Icons.navigation,
              lineColor: Colors.blue,
              label: 'To Coco',
              action: SizedBox.shrink(),
            ),
          ),
        );

        // --- The positive control. Without this half, everything below
        // passes just as well on a panel that never built, never subscribed,
        // or never had a fix to take.
        fixes.add(fixAt(start));
        // **Totals as well as distance, for the same reason as the collapsed
        // test below — task 11.212.** Here the weak wait fails in the other
        // direction and is therefore worse: `first` captured before the
        // sampling lands has no totals, so the `headerText != first` wait
        // further down is satisfied by the totals *arriving* rather than by
        // the distance following the new fix, and the test goes green having
        // measured nothing about the subscription it exists to check.
        await pumpUntil(
          tester,
          () => headerText(tester).contains('km') && headerHasTotals(tester),
          reason:
              'the header showed a distance and the first sampling\'s totals',
        );
        final first = headerText(tester);
        expect(first, contains('To Coco'));
        expect(fixes.hasListener, isTrue,
            reason: 'the panel is not subscribed at all, so everything below '
                'would pass for the wrong reason');

        // A kilometre closer: the distance in the bar must follow.
        fixes.add(fixAt(const ll.LatLng(35.02, -111.67)));
        await pumpUntil(
          tester,
          () => headerText(tester) != first,
          reason: 'the header updated after a closer fix arrived',
        );
        final moved = headerText(tester);
        expect(moved, isNot(first),
            reason: 'a fix arrived while the app was in front of somebody and '
                'the bar did not move — the subscription is not live');

        // --- Now the app goes into a pocket. The whole cycle, because the
        // binding ignores a transition to the state it is already in.
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
        }

        // **What is asserted here is the subscription, not the screen — and
        // that is a finding rather than a preference.** Watched under a
        // deliberate sabotage that never drops the subscription: the fix was
        // taken, and the rendered header still did not move, because a paused
        // app is not producing frames. So a text comparison here cannot tell
        // *we ignored the fix* from *nothing was redrawn*, which is this
        // project's comparison-between-two-things-that-fail-identically
        // exactly. `hasListener` on the fixture's own stream can: the panel's
        // subscription is the only listener `gpsPositionProvider` has, so
        // when the panel drops it the autoDispose provider goes with it.
        await pumpUntil(
          tester,
          () => !fixes.hasListener,
          reason: 'the panel dropped its position subscription while paused',
        );
        expect(
          fixes.hasListener,
          isFalse,
          reason: 'the app is in a pocket and this panel is still subscribed '
              'to position updates — this is the whole containment: no work '
              'at all unless the app is in front of somebody',
        );

        // --- And back out of the pocket, so the containment is a pause and
        // not a one-way door.
        for (final state in [
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
        }
        await pumpUntil(
          tester,
          () => fixes.hasListener,
          reason: 'the panel resubscribed to position updates after resuming',
        );
        expect(fixes.hasListener, isTrue,
            reason: 'coming back to the app must subscribe again');

        fixes.add(fixAt(const ll.LatLng(35.02, -111.64)));
        await pumpUntil(
          tester,
          () => headerText(tester) != moved,
          reason: 'the header updated after resuming and a new fix arrived',
        );
        expect(headerText(tester), isNot(moved),
            reason: 'coming back to the app must start it following again');
      });
    });

    testWidgets('before the first fix it says what it is waiting for',
        (tester) async {
      // **Not a spinner.** Nothing is loading before a fix arrives — there is
      // no line to sample — so a spinner would turn forever while somebody
      // stood under a canopy, which is the app claiming to be busy when it is
      // waiting on the sky.
      final fixes = StreamController<Position>.broadcast();
      addTearDown(fixes.close);
      final container = ProviderContainer(
        overrides: [gpsPositionProvider.overrideWith((ref) => fixes.stream)],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await seedTerrain();
        await tester.pumpWidget(
          host(
            container,
            const ElevationProfilePanel(
              origin: null,
              destination: end,
              icon: Icons.navigation,
              lineColor: Colors.blue,
              label: 'To Coco',
              action: SizedBox.shrink(),
            ),
          ),
        );
        await pumpUntil(
          tester,
          () => find.text(kWaitingForFixMessage).evaluate().isNotEmpty,
          reason: 'the "waiting for fix" message appeared',
        );
      });

      expect(find.text(kWaitingForFixMessage), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('collapsed, it updates the distance but not the profile',
        (tester) async {
      // **The cheap half and the expensive half are deliberately different.**
      // Distance and bearing are two coordinates and a formula and are what
      // somebody glances at; the profile is the sampling, and nobody is
      // looking at it while the panel is a single grey bar.
      final fixes = StreamController<Position>.broadcast();
      addTearDown(fixes.close);
      final container = ProviderContainer(
        overrides: [gpsPositionProvider.overrideWith((ref) => fixes.stream)],
      );
      addTearDown(container.dispose);

      await tester.runAsync(() async {
        await seedTerrain();
        await tester.pumpWidget(
          host(
            container,
            const ElevationProfilePanel(
              origin: null,
              destination: end,
              icon: Icons.navigation,
              lineColor: Colors.blue,
              label: 'To Coco',
              initiallyCollapsed: true,
              action: SizedBox.shrink(),
            ),
          ),
        );

        fixes.add(fixAt(start));
        // **Wait for the totals, not just the distance — task 11.212.** These
        // are two different code paths in the header and only one of them is
        // synchronous: `numbers` is two coordinates and a formula, computed
        // the instant a fix sets the origin, while the `\u2191` totals stay empty
        // until the async terrain sampling fills the profile. A wait on 'km'
        // is therefore strictly weaker than the assertion three lines below,
        // and the gap between them is real time on a loaded machine.
        // **Measured: 1 failure in 10 full-suite runs before this line
        // changed, 0 in 20 after** — and it passed every time in isolation
        // both before and after, because an idle machine closes the gap
        // inside one pump.
        await pumpUntil(
          tester,
          () => headerText(tester).contains('km') && headerHasTotals(tester),
          reason:
              'the header showed a distance and the first sampling\'s totals',
        );
        final atStart = headerText(tester);
        // The first sampling happens on mount whatever the state — the panel
        // has to have something to show the moment somebody opens it.
        expect(headerHasTotals(tester), isTrue,
            reason: 'the first sampling never landed, so there are no totals '
                'to compare against after the walk — everything below would '
                'be measuring the arrival of the totals rather than the '
                'distance following the walk');
        final totalsAtStart =
            atStart.substring(atStart.indexOf('↑'));

        // Half a kilometre along the line, which is well past the 10 m
        // movement threshold — and up the ramp, so the climb from here really
        // is different terrain.
        fixes.add(fixAt(const ll.LatLng(35.02, -111.675)));
        await pumpUntil(
          tester,
          () => headerText(tester) != atStart,
          reason: 'the header updated after walking half a kilometre',
        );
        final afterWalking = headerText(tester);

        expect(afterWalking, isNot(atStart),
            reason: 'the distance did not follow the walk');
        expect(
          afterWalking.substring(afterWalking.indexOf('↑')),
          totalsAtStart,
          reason: 'the profile was re-sampled while the panel was shut — the '
              'expensive half is meant to wait until somebody opens it',
        );
      });
    });
  });

  /// **Task 11.332 item 2.** Two pieces of running text on this panel are
  /// capped at two lines and end in "…", and the clipped-text sweep's
  /// fixtures reach neither (the panel needs a measured line or a navigation
  /// target): the sentence saying part of the line has no elevation, and the
  /// navigation header before the first fix ("To Coco — last estimate ·
  /// Waiting for a position fix"), which the Map's own budget test sees cut
  /// in the test font. Measured here at the 6.1-inch phone's real surface,
  /// in Roboto, at every size up to the ordinary Dynamic Type slider's top
  /// stop.
  group('running text on the panel (task 11.332)', () {
    setUpAll(loadRobotoFromSdkCache);

    Future<void> pumpAt(
      WidgetTester tester,
      double scale,
      ProviderContainer container,
      Widget panel,
      Finder shown,
    ) async {
      // The phone's real surface, not the test's 800-pixel default: a
      // `MediaQuery` size alone does not narrow anything.
      usePhoneGeometry(tester);
      await tester.runAsync(() async {
        await seedTerrain();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: AppTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: Align(alignment: Alignment.bottomCenter, child: panel),
              ),
            ),
          ),
        );
        await pumpUntil(
          tester,
          () => shown.evaluate().isNotEmpty,
          reason: 'the text under test appeared',
        );
      });
    }

    for (final scale
        in iosTextScalesUpward.where((s) => s <= dynamicTypeSliderCeiling)) {
      testWidgets(
          'the partial-elevation sentence is whole at ${textScaleName(scale)}',
          (tester) async {
        final container = ProviderContainer();
        addTearDown(container.dispose);
        // Terrain for one tile only (35.0–35.1 N, 111.7–111.6 W); the line
        // runs on east, out of it, so part of it has no elevation.
        await pumpAt(
          tester,
          scale,
          container,
          const ElevationProfilePanel(
            origin: start,
            destination: ll.LatLng(35.02, -111.56),
            icon: Icons.straighten,
            lineColor: Colors.black,
            action: SizedBox.shrink(),
          ),
          find.text(kPartialElevationProfileMessage),
        );
        final cut = clippedTexts(tester)
            .where((c) => c.text == kPartialElevationProfileMessage)
            .toList();
        expect(cut, isEmpty,
            reason: 'cut short at ${textScaleName(scale)}: $cut');
      });

      testWidgets(
          'the navigation header before a fix is whole at '
          '${textScaleName(scale)}', (tester) async {
        final fixes = StreamController<Position>.broadcast();
        addTearDown(fixes.close);
        final container = ProviderContainer(
          overrides: [gpsPositionProvider.overrideWith((ref) => fixes.stream)],
        );
        addTearDown(container.dispose);
        await pumpAt(
          tester,
          scale,
          container,
          const ElevationProfilePanel(
            origin: null,
            destination: end,
            icon: Icons.navigation,
            lineColor: Colors.blue,
            label: 'To Coco — last estimate',
            initiallyCollapsed: true,
            action: SizedBox.shrink(),
          ),
          find.textContaining('Waiting for a position fix'),
        );
        final cut = clippedTexts(tester)
            .where((c) => c.text.startsWith('To Coco'))
            .toList();
        expect(cut, isEmpty,
            reason: 'cut short at ${textScaleName(scale)}: $cut');
      });
    }
  });
}

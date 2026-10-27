import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/download_manager.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/map/services/tile_fetch_health.dart';
import 'package:tritrack/features/more/screens/offline_data_map_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/text_scale_probe.dart';

/// Task 11.162 — the acceptance criterion the Offline Data Map never had.
///
/// Task 11.110 gave the Main Map a clear-band floor and task 11.148 narrowed
/// it to the default text size. **This screen was under that floor at the
/// default text size**, which is what makes it different from every other
/// screen-space finding in this phase: nothing had to be turned up in
/// Settings to reach it.
///
/// **The state is an ordinary evening before a field trip.** Queueing several
/// regions is the flow this screen exists for, and the tiles-not-arriving
/// band appears exactly when the connection is poor — which is the same
/// evening. The two conditions are correlated, so this measures them
/// together rather than treating the combination as rare.
///
/// The instrument is the one that already exists: `clearBandHeight` from
/// `test/support/app_shell_harness.dart`, pointed at this screen's outer
/// `Stack` (`offline-data-map`) with every overlay listed, inside the real
/// app shell. **A fresh probe beside a working one is two things to keep
/// true.**
class _FakeOfflineRegions extends OfflineRegions {
  @override
  Future<List<OfflineRegion>> build() async => const [];
}

class _FixedDownloadManager extends DownloadManager {
  _FixedDownloadManager(this._fixed);
  final List<DownloadJob> _fixed;

  @override
  List<DownloadJob> build() => _fixed;
}

void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);
  // The tile signal is process-wide (every map in the app fetches through one
  // provider), so one test leaving it tripped would put a band on the next
  // test's screen and quietly shrink the number it measures.
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

  /// Task 11.110's floor, written here as a literal **on purpose**, even
  /// though the screen exports [kOfflineMapClearBandFloor] and reserves it in
  /// its own layout. A test that reads the constant it is checking agrees
  /// with itself whatever the constant becomes; one test below asserts the
  /// two are equal, so lowering the floor in either place is a red rather
  /// than a silently smaller map.
  const clearBandFloor = 96.0;

  // **Task 11.204 changed what the number under this floor means, and the
  // floor's margin grew on every row of the table this file prints.** An
  // overlay is now charged the width it actually covers rather than the map's
  // full width, and the clear region is floored in both directions
  // ([kClearRegionMinWidth]) — see `app_shell_harness.dart`.
  //
  // Nothing on this screen changed and the map did not gain a pixel. What
  // moved is that the coverage legend, the layer buttons and the drawing
  // controls stopped being charged for map they never covered:
  //
  //   0 cards, warning down   383.0 -> 435.0      3 cards, xxxLarge   96.0 -> 128.0
  //   1 card,  warning down   278.0 -> 330.0      3 cards, AX1        96.0 -> 108.0
  //   2 cards, warning down   177.0 -> 229.0      3 cards, AX2-AX5    96.0 -> 96.0
  //   3 cards, warning down    96.0 -> 148.0      AX5, legend off     96.0 -> 268.0
  //   0 cards, warning up     315.0 -> 367.0
  //   1 card,  warning up     222.0 -> 274.0
  //   2 cards, warning up     121.0 -> 173.0
  //   3 cards, warning up      96.0 -> 148.0
  //
  // **A floor that got easier to clear is a finding, not a bonus.** The rows
  // that stayed at exactly 96.0 are the ones where task 11.162's `SizedBox`
  // is doing the work — the floor is *structure* on this screen, not an
  // assertion — so they are pinned by the layout and could not move. The rows
  // that grew are the ones that had headroom nobody knew about.

  const poly = [
    LatLng(35.0, -111.0),
    LatLng(35.0, -110.9),
    LatLng(35.1, -110.9),
  ];

  DownloadJob running(String id) => DownloadJob(
        id: id,
        kind: DownloadJobKind.tiles,
        polygon: poly,
        status: DownloadJobStatus.running,
        total: 4010,
        done: 1204,
      );

  /// Everything drawn over this screen's map, keyed in
  /// `offline_data_map_screen.dart`. **Add a new overlay here when you add
  /// one there** — an overlay missing from this list is an overlay that is
  /// not measured, and the clear band will read as larger than it is.
  ///
  /// **Still a hand-kept list, deliberately, and this is the one place it
  /// stays one** (task 11.166). The two map screens moved to
  /// [clearBandOverStack], which derives the set from the `Stack`'s own
  /// children; that works there because each overlay is its own `Positioned`
  /// child. **This screen's overlays are not.** They live inside a single
  /// `Positioned.fill` layer, so "every `Stack` child after the first"
  /// derives one blocker the height of the whole map and reports a clear
  /// band of zero. If somebody converts this anyway, it fails **red** rather
  /// than silently — a band of 0 against a floor of 96 — so the mistake is
  /// loud, which is why the list is left rather than guarded.
  ///
  /// It is also the weakest place for the missing-overlay defect to bite:
  /// this screen reserves [kOfflineMapClearBandFloor] **in its own layout**
  /// (task 11.162), so the floor here is held by structure and this list only
  /// checks it.
  final mapOverlays = [
    find.byKey(const ValueKey('offline-map-buttons')),
    find.byKey(const ValueKey('offline-coverage-legend')),
    find.byKey(const ValueKey('offline-bottom-panels')),
  ];

  double clearMapBand(WidgetTester tester) => clearBandHeight(
        tester,
        find.byKey(const ValueKey('offline-data-map')),
        mapOverlays,
      );

  /// Pumps the screen and returns the layout overflows it produced —
  /// **every** test here installs the collector, not only the ones that
  /// assert on it, because an overflow left uncaught fails whichever test
  /// happens to pump next and names the wrong one.
  Future<List<String>> pumpScreen(
    WidgetTester tester, {
    required int jobs,
    required bool tilesNotArriving,
    double textScale = 1.0,
  }) async {
    final overflows = collectLayoutOverflows();
    if (tilesNotArriving) {
      for (var i = 0; i < TileFetchHealth.failureThreshold; i++) {
        TileFetchHealth.instance.recordNetworkFailure();
      }
    }

    final container = ProviderContainer(
      overrides: [
        // Without this the real geolocator channel answers with a
        // MissingPluginException on a later frame, which surfaces as a
        // failure in whichever test happens to pump next.
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        offlineRegionsProvider.overrideWith(_FakeOfflineRegions.new),
        downloadManagerProvider.overrideWith(
          () => _FixedDownloadManager([
            for (var i = 0; i < jobs; i++) running('job-$i'),
          ]),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const OfflineDataMapScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
      textScale: textScale,
    );
    return overflows;
  }

  /// Every measurement this file takes, printed as one table when the run
  /// ends — **the sum is the finding, and a number that only appears in a
  /// failure message is a number nobody reads on a green run.**
  final measured = <String>[];
  tearDownAll(() {
    // ignore: avoid_print
    print(
      '\nOffline Data Map — clear map band, 6.1-inch phone, inside the app '
      'shell (floor $clearBandFloor):\n${measured.join('\n')}',
    );
  });

  group('the sum, across the card counts', () {
    // **Eight numbers, not one.** The band with zero, one, two and three job
    // cards, with the tiles-not-arriving band up and down, because a single
    // stress number cannot say where the budget actually runs out — and
    // "three downloads" is not the only shape of an evening before a trip.
    for (final tilesNotArriving in [false, true]) {
      for (final jobs in [0, 1, 2, 3]) {
        final band = tilesNotArriving ? 'warning up' : 'warning down';
        testWidgets('$jobs job card(s), $band', (tester) async {
          final overflows = await pumpScreen(
            tester,
            jobs: jobs,
            tilesNotArriving: tilesNotArriving,
          );
          final clear = clearMapBand(tester);
          measured.add(
            '  $jobs card(s), $band: ${clear.toStringAsFixed(1)}px',
          );
          expect(
            clear,
            greaterThanOrEqualTo(clearBandFloor),
            reason:
                'The Offline Data Map has ${clear.toStringAsFixed(1)} logical '
                'pixels of map with nothing drawn over it, against a floor of '
                '$clearBandFloor, with $jobs download card(s) and the '
                'tiles-not-arriving band $band, at the default text size.\n'
                'What a person sees: the region they are drawing, and the '
                'coverage they already have, hidden behind the progress cards '
                'of the downloads they queued — on the one screen whose job '
                'is to show them where their data is.',
          );
          expect(
            overflows,
            isEmpty,
            reason: 'The bounded card region must fit what it is given, not '
                'stripe it: $overflows',
          );
        });
      }
    }
  });

  testWidgets(
    'the floor the layout reserves is the floor this file asserts',
    (tester) async {
      // Two copies of one number, checked against each other. Without this
      // the screen could lower its own reserve and every assertion above
      // would agree with the smaller map.
      expect(kOfflineMapClearBandFloor, clearBandFloor);
    },
  );

  testWidgets('every download is still reachable, none is capped',
      (tester) async {
    // **The remedy must not have become a cap.** Three concurrent downloads
    // is a thing somebody chose; the cards scroll, so all three exist and
    // all three can be reached — including the Cancel on the one that is
    // scrolled out of view.
    await pumpScreen(tester, jobs: 3, tilesNotArriving: true);

    for (var i = 0; i < 3; i++) {
      expect(
        find.byKey(ValueKey('offline-job-card-$i')),
        findsOneWidget,
        reason: 'Card $i is not in the tree at all — the cards were capped, '
            'not bounded.',
      );
    }

    final scroller = find.byKey(const ValueKey('offline-bottom-panels'));
    final viewport = tester.getRect(scroller);
    // The warning band and the newest download are what is visible without
    // touching anything — the column is scrolled from the top.
    expect(
      isFullyVisibleIn(
          tester, find.byKey(const ValueKey('offline-tiles-not-loading')), scroller),
      isTrue,
      reason: 'The tiles-not-arriving band must not be the thing that scrolls '
          'out of sight — it is the reason the downloads are going nowhere. '
          'Viewport: $viewport',
    );
    expect(
      isFullyVisibleIn(
          tester, find.byKey(const ValueKey('offline-job-card-2')), scroller),
      isTrue,
      reason: 'The newest download should be the first card in view.',
    );
    // The oldest is the one below the fold, and a scroll reaches it.
    expect(
      isFullyVisibleIn(
          tester, find.byKey(const ValueKey('offline-job-card-0')), scroller),
      isFalse,
      reason: 'With three cards in a bounded box one of them has to be below '
          'the fold; if they all fit, this test is no longer measuring what '
          'it was written for.',
    );
    await tester.drag(scroller, const Offset(0, -200));
    await tester.pump();
    expect(
      isFullyVisibleIn(
          tester, find.byKey(const ValueKey('offline-job-card-0')), scroller),
      isTrue,
      reason: 'Scrolling the card stack did not bring the oldest download '
          'fully into view, so one of the three downloads cannot be seen or '
          'cancelled.',
    );
  });

  group('up the text-size ladder, three cards and the warning up', () {
    // The brief scopes this task to the default text size, where the defect
    // was. The ladder is here because the remedy claims to hold **at every**
    // text size — the floor is a box in the layout rather than a number
    // checked once — and a claim like that is worth an instrument.
    for (final scale in iosTextScalesUpward) {
      testWidgets(textScaleName(scale), (tester) async {
        final overflows = await pumpScreen(
          tester,
          jobs: 3,
          tilesNotArriving: true,
          textScale: scale,
        );
        final clear = clearMapBand(tester);
        measured.add(
          '  3 cards, warning up, ${textScaleName(scale)}: '
          '${clear.toStringAsFixed(1)}px'
          '${overflows.isEmpty ? '' : ' — ${overflows.length} overflow(s): '
              '${overflows.join('; ')}'}',
        );

        // **The exception that used to live here is gone, and it is worth
        // saying what it was** (task 11.149). AX5 was recorded as the one
        // state the floor could not hold: the coverage legend wrapped every
        // one of its four labels onto three lines, came out **632 logical
        // pixels tall against a 555-pixel map area**, cut the clear band to
        // 12 and overflowed the column by 101 — the yellow-and-black stripe.
        //
        // Two things closed it, and only one of them is on this screen. The
        // app shell's banners are now bounded (`AppShellBody`), which gave
        // this screen back the body they had taken; and the legend's rows
        // are one line each with the rest ellipsised, which is the same
        // rule applied to this screen's own furniture. **The floor now holds
        // at every stop on the ladder** — see `_CoverageLegend` in
        // `offline_data_map_screen.dart` for what a person gives up for it.
        expect(
          clear,
          greaterThanOrEqualTo(clearBandFloor),
          reason:
              'The Offline Data Map has ${clear.toStringAsFixed(1)} logical '
              'pixels of clear map at ${textScaleName(scale)} with three '
              'downloads running and the tiles-not-arriving band up.',
        );
        expect(overflows, isEmpty, reason: 'Overflows: $overflows');
      });
    }
  });

  testWidgets('AX5 with the legend switched off', (tester) async {
    // Kept after task 11.149 closed the AX5 exception, because the legend is
    // still the largest single piece of furniture on this screen and its
    // on/off control is still the biggest thing a person can do about it.
    // What changed is that this is now a *comparison* rather than a
    // workaround: the floor holds with the legend up too.
    final overflows = await pumpScreen(
      tester,
      jobs: 3,
      tilesNotArriving: true,
      textScale: iosTextScales.last,
    );
    await tester.tap(find.byTooltip('Toggle legend'));
    await tester.pump();
    final clear = clearMapBand(tester);
    measured.add(
      '  3 cards, warning up, AX5, legend off: ${clear.toStringAsFixed(1)}px',
    );
    expect(
      clear,
      greaterThanOrEqualTo(clearBandFloor),
      reason: 'With the legend off, nothing at the top of this screen grows '
          'with the text size, so the reserve should hold even at AX5. It '
          'has ${clear.toStringAsFixed(1)}px. Overflows seen: $overflows',
    );
  });
}

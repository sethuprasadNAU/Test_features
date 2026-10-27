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

/// Task 11.126 item B — the Offline Data Map's accidental `Stack` overlaps.
///
/// Task 11.118 read this screen's source and found two pairs of `Stack`
/// children that can paint on top of each other. This measures them at real
/// phone geometry inside the real app shell, which is where the numbers are
/// different from the ones a bare pump produces.
///
/// **Which painting world each child is in.** This screen has the same seam
/// the Main Map has — things drawn inside `flutter_map`'s own layers versus
/// things drawn over the map as `Stack` children — but **every widget
/// measured here is on the overlay side**: the coverage legend, the
/// right-hand button column, the selection readout and the job progress
/// cards are all children of the outer `Stack`, and so are the polygon's
/// vertex handles (deliberately, so their gesture detectors do not compete
/// with the map's own pan recognizer). Only the coverage polygons themselves
/// are map-layer widgets, and nothing here measures those. So for these
/// pairs, declaration order really is the whole story: the later child
/// simply paints over the earlier one.
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
  // The tile signal is process-wide, so one test leaving it tripped puts a
  // band on the next test's screen and quietly changes what it measures.
  setUp(TileFetchHealth.instance.reset);
  tearDown(TileFetchHealth.instance.reset);

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
        total: 20,
        done: 5,
      );

  Future<void> pumpScreen(WidgetTester tester, List<DownloadJob> jobs) async {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);

    final container = ProviderContainer(
      overrides: [
        // Without this the real geolocator channel answers with a
        // MissingPluginException on a later frame, which surfaces as a
        // failure in whichever test happens to pump next.
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        offlineRegionsProvider.overrideWith(_FakeOfflineRegions.new),
        downloadManagerProvider.overrideWith(() => _FixedDownloadManager(jobs)),
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
    );
  }

  void expectNoOverlap(
    WidgetTester tester,
    Finder a,
    Finder b, {
    required String what,
  }) {
    final ra = tester.getRect(a);
    final rb = tester.getRect(b);
    printOnFailure('$what\n  a = $ra\n  b = $rb');
    expect(
      ra.overlaps(rb),
      isFalse,
      reason: '$what\nThe two rectangles intersect: $ra and $rb. Both are '
          'children of the same `Stack`, so the one declared later simply '
          'paints over the other and nothing warns anybody.',
    );
  }

  testWidgets('the selection readout clears a second download', (tester) async {
    // Overlap (3): the readout lifts itself by a hard-coded `140` when any
    // job is running — a number sized for exactly one card — while the cards
    // stack at `12 + i * 84`. A second job reaches it and a third sits on it.
    await pumpScreen(tester, [running('tiles-1'), running('tiles-2')]);
    await tester.tap(find.text('New selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('offline-selection-readout')), findsOneWidget,
        reason: 'the selection readout this test measures is not up');

    for (var i = 0; i < 2; i++) {
      final card = find.byKey(ValueKey('offline-job-card-$i'));
      expect(card, findsOneWidget, reason: 'job card $i is not on screen');
      expectNoOverlap(
        tester,
        find.byKey(const ValueKey('offline-selection-readout')),
        card,
        what: 'The selection readout must clear download progress card $i.',
      );
    }
  });

  testWidgets('the coverage legend clears the button column', (tester) async {
    // Overlap (4), and **it does not reproduce**: the legend is
    // `left: 12, top: 12` and intrinsically sized, the button column is
    // `right: 12, top: 12`, and neither constrains its width — but measured
    // on a 393-pixel-wide phone the legend ends at x=283 and the buttons
    // start at x=333, so there are **50 logical pixels between them**. The
    // legend's four rows are fixed text, so nothing at runtime widens it.
    //
    // Nothing was changed for this one; a layout fix nobody watched fail is
    // how at least two of these defects arrived. This test is the guard
    // instead: add a fifth row, or lengthen a label, and it goes red here
    // rather than on somebody's phone.
    await pumpScreen(tester, const []);
    expectNoOverlap(
      tester,
      find.byKey(const ValueKey('offline-coverage-legend')),
      find.byKey(const ValueKey('offline-map-buttons')),
      what: 'The coverage legend must clear the right-hand button column.',
    );
  });

  // -------------------------------------------------------------------
  // Task 11.135 — the screen where somebody downloads tiles on purpose.
  // -------------------------------------------------------------------

  void tripTheTileSignal() {
    for (var i = 0; i < TileFetchHealth.failureThreshold; i++) {
      TileFetchHealth.instance.recordNetworkFailure();
    }
  }

  testWidgets('the tiles-not-arriving band appears here, and costs the screen '
      'nothing until it does', (tester) async {
    await pumpScreen(tester, [running('tiles-1')]);
    final quiet = tester.getRect(
      find.byKey(const ValueKey('offline-bottom-panels')),
    );
    expect(
      find.byKey(const ValueKey('offline-tiles-not-loading')),
      findsNothing,
      reason: 'nothing has failed, so there is nothing to say',
    );

    tripTheTileSignal();
    await tester.pump();
    final band = find.byKey(const ValueKey('offline-tiles-not-loading'));
    expect(
      band,
      findsOneWidget,
      reason:
          'This is the one screen in the app where somebody fetches tiles on '
          'purpose. Before task 11.135 a download returning nothing reported '
          'only a count.',
    );

    final loud = tester.getRect(
      find.byKey(const ValueKey('offline-bottom-panels')),
    );
    printOnFailure(
      'bottom column: ${quiet.height} logical pixels quiet, '
      '${loud.height} with the band up '
      '(cost ${loud.height - quiet.height})',
    );
    expect(
      loud.height,
      greaterThan(quiet.height),
      reason: 'the band has to actually take space when it is up',
    );
    expect(
      quiet.bottom,
      closeTo(loud.bottom, 0.5),
      reason: 'the column is anchored to the bottom edge, so the band grows '
          'it upward into the map rather than pushing the job cards off',
    );
  });

  testWidgets('the band does not cover the coverage legend or the buttons',
      (tester) async {
    // Task 11.109's rule: measure the screen **with the band up**. The band
    // joins the bottom column, and the two things it could reach are the
    // legend and the button column, both anchored at the top.
    tripTheTileSignal();
    await pumpScreen(tester, [running('tiles-1'), running('tiles-2')]);
    await tester.tap(find.text('New selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('offline-tiles-not-loading')),
        findsOneWidget);

    final panels = find.byKey(const ValueKey('offline-bottom-panels'));
    expectNoOverlap(
      tester,
      panels,
      find.byKey(const ValueKey('offline-coverage-legend')),
      what: 'The bottom column, with the tiles band up and two downloads '
          'running, must still clear the coverage legend.',
    );
    expectNoOverlap(
      tester,
      panels,
      find.byKey(const ValueKey('offline-map-buttons')),
      what: 'The bottom column, with the tiles band up and two downloads '
          'running, must still clear the right-hand button column.',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a download that lost tiles says so, and names no cause',
      (tester) async {
    // **The count was the whole message before this.** `(3 failed)` is what
    // happened; it is not what it means, whether it is a network fact at all,
    // or whether retrying costs the 4000 tiles that did arrive.
    await pumpScreen(tester, [
      DownloadJob(
        id: 'tiles-1',
        kind: DownloadJobKind.tiles,
        polygon: poly,
        status: DownloadJobStatus.complete,
        total: 4003,
        done: 4003,
        failed: 3,
      ),
    ]);

    expect(
      find.byKey(const ValueKey('offline-job-failed-note')),
      findsOneWidget,
      reason: 'a download that lost tiles must say more than a count',
    );
    expect(find.textContaining('4000/4003'), findsOneWidget,
        reason: 'the tiles that DID arrive are the other half of the fact, '
            'and the count used to replace them rather than join them');
    expect(find.textContaining('3 tiles did not arrive'), findsOneWidget);
    expect(find.textContaining('only for the ones still missing'),
        findsOneWidget,
        reason: 'the one thing a person can act on is that Retry is cheap');

    // The project's rule: the branch reached when the code does not know why
    // must not assert a cause. The downloader knows that some requests came
    // back with nothing usable, and that is all it knows.
    for (final claim in const [
      'blocked',
      'offline',
      'no internet',
      'rate limit',
      'your network',
    ]) {
      expect(
        find.textContaining(claim, findRichText: true),
        findsNothing,
        reason: 'this card cannot know that "$claim" is what happened',
      );
    }
  });

  testWidgets('a download with nothing lost says nothing extra',
      (tester) async {
    await pumpScreen(tester, [
      DownloadJob(
        id: 'tiles-1',
        kind: DownloadJobKind.tiles,
        polygon: poly,
        status: DownloadJobStatus.complete,
        total: 40,
        done: 40,
      ),
    ]);
    expect(
      find.byKey(const ValueKey('offline-job-failed-note')),
      findsNothing,
      reason: 'a clean download pays nothing for the sentence',
    );
  });

  testWidgets('nothing on this screen overflows at phone width',
      (tester) async {
    await pumpScreen(tester, [running('tiles-1'), running('tiles-2')]);
    await tester.tap(find.text('New selection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
  });
}

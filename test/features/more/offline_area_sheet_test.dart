import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/download_manager.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/map/widgets/offline_region_actions.dart';
import 'package:tritrack/features/more/screens/offline_data_map_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// **The Offline Data Map is the manager** — task 11.230, items 3 and 4.
///
/// A downloaded area on this map used to be a coloured shape and nothing
/// else; the only way to act on one was the list on the previous screen,
/// where it was "Tile area" and a bounding box. Now a new area is named as
/// it is drawn, a tap on an area opens a sheet with Rename / Update / Delete,
/// and a tap that lands inside two overlapping areas asks which — the
/// decision the plan asked to be made in writing, and the reason is on
/// `_onMapTap` in the screen.
///
/// Pumped in the tab shell at phone geometry, since the sheets and the
/// chooser have to be tappable where a person would tap them. The map is not
/// pumped to settle (the basemap's tile requests never resolve under
/// `flutter test`), and taps on the map are delivered by
/// calling `MapOptions.onTap` with a coordinate, the same way this suite's
/// sibling drives the vertex handles: the geometry under test is which area
/// a point is in, not `flutter_map`'s hit-testing.
class _FixedRegions extends OfflineRegions {
  _FixedRegions(this._fixed);
  final List<OfflineRegion> _fixed;

  @override
  Future<List<OfflineRegion>> build() async => _fixed;
}

/// Records what the screen asks to download and downloads nothing.
class _RecordingDownloadManager extends DownloadManager {
  final List<({String kind, String? name, String? id})> enqueued = [];
  final Set<String> inFlight = {};

  @override
  List<DownloadJob> build() => const [];

  @override
  bool isInFlight(String id) => inFlight.contains(id);

  @override
  String enqueueTiles({
    required List<LatLng> polygon,
    required String sourceId,
    required int minZoom,
    required int maxZoom,
    String? name,
    String? id,
  }) {
    enqueued.add((kind: 'tiles', name: name, id: id));
    return id ?? 'tiles-x';
  }

  @override
  String enqueueDem({required List<LatLng> polygon, String? name, String? id}) {
    enqueued.add((kind: 'dem', name: name, id: id));
    return id ?? 'dem-x';
  }
}

void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  final ts = DateTime.utc(2026, 1, 1);
  const west = [
    LatLng(35.10, -111.70),
    LatLng(35.10, -111.60),
    LatLng(35.20, -111.60),
    LatLng(35.20, -111.70),
  ];
  const east = [
    LatLng(35.15, -111.65),
    LatLng(35.15, -111.55),
    LatLng(35.25, -111.55),
    LatLng(35.25, -111.65),
  ];
  // Inside the west square only / inside both.
  const westOnly = LatLng(35.12, -111.68);
  const overlap = LatLng(35.17, -111.62);

  OfflineRegion area(
    String id,
    String? name,
    List<LatLng> polygon, {
    int sizeBytes = 4 * 1024 * 1024,
    int sharedBytes = 0,
    List<String> sharedWithIds = const [],
    String sourceId = 'osm_standard',
  }) =>
      OfflineRegion(
        id: id,
        kind: OfflineRegionKind.tiles,
        name: name,
        polygon: polygon,
        sourceId: sourceId,
        minZoom: 14,
        maxZoom: 14,
        tileTotal: 20,
        tileCompleted: 20,
        status: OfflineRegionStatus.complete,
        sizeBytes: sizeBytes,
        sharedBytes: sharedBytes,
        sharedWithIds: sharedWithIds,
        createdAt: ts,
        updatedAt: ts,
      );

  Future<_RecordingDownloadManager> pumpScreen(
    WidgetTester tester,
    List<OfflineRegion> regions,
  ) async {
    final manager = _RecordingDownloadManager();
    final container = ProviderContainer(
      overrides: [
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        offlineRegionsProvider.overrideWith(() => _FixedRegions(regions)),
        downloadManagerProvider.overrideWith(() => manager),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });
    // The basemap asks for real tiles, which fail under `flutter test`;
    // that is not what any case here is about.
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const OfflineDataMapScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
    await tester.pump(const Duration(milliseconds: 50));
    return manager;
  }

  Future<void> tapMap(WidgetTester tester, LatLng at) async {
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    map.options.onTap!(const TapPosition(Offset.zero, Offset.zero), at);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// What the name field on the download sheet currently holds.
  String nameFieldText(WidgetTester tester) => tester
      .widget<TextField>(find.descendant(
        of: find.byKey(const ValueKey('offline-area-name')),
        matching: find.byType(TextField),
      ))
      .controller!
      .text;

  Future<void> settleSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('naming an area as it is drawn', () {
    testWidgets('the download sheet offers "Area 1" when nothing is named',
        (tester) async {
      final manager = await pumpScreen(tester, const []);
      await tester.tap(find.byTooltip('Toggle legend'));
      await tester.pump();
      await tester.tap(find.text('New selection'));
      await tester.pump();
      await tester.tap(find.text('Download'));
      await settleSheet(tester);
      // The keep-open dialog first.
      await tester.tap(find.text('Continue'));
      await settleSheet(tester);

      final field = find.byKey(const ValueKey('offline-area-name'));
      expect(field, findsOneWidget);
      expect(nameFieldText(tester), 'Area 1');

      // Accepting the default names both downloads it queues.
      await tester.tap(find.byKey(const ValueKey('offline-download-confirm')));
      await settleSheet(tester);
      expect(manager.enqueued.map((e) => e.kind), ['tiles', 'dem']);
      expect(manager.enqueued.map((e) => e.name), ['Area 1', 'Area 1']);
    });

    testWidgets('the default skips names already in use', (tester) async {
      await pumpScreen(tester, [
        area('a', 'Area 1', west),
        area('b', 'Area 2', east),
        area('c', null, east),
      ]);
      await tester.tap(find.byTooltip('Toggle legend'));
      await tester.pump();
      await tester.tap(find.text('New selection'));
      await tester.pump();
      await tester.tap(find.text('Download'));
      await settleSheet(tester);
      await tester.tap(find.text('Continue'));
      await settleSheet(tester);
      expect(nameFieldText(tester), 'Area 3');
    });

    testWidgets('a typed name is what gets queued, and a blank one falls back',
        (tester) async {
      final manager = await pumpScreen(tester, const []);
      await tester.tap(find.byTooltip('Toggle legend'));
      await tester.pump();
      await tester.tap(find.text('New selection'));
      await tester.pump();
      await tester.tap(find.text('Download'));
      await settleSheet(tester);
      await tester.tap(find.text('Continue'));
      await settleSheet(tester);
      await tester.enterText(
          find.byKey(const ValueKey('offline-area-name')), '  North ridge ');
      await tester.tap(find.byKey(const ValueKey('offline-download-confirm')));
      await settleSheet(tester);
      expect(manager.enqueued.map((e) => e.name).toSet(), {'North ridge'});

      manager.enqueued.clear();
      await tester.tap(find.text('New selection'));
      await tester.pump();
      await tester.tap(find.text('Download'));
      await settleSheet(tester);
      await tester.tap(find.text('Continue'));
      await settleSheet(tester);
      await tester.enterText(
          find.byKey(const ValueKey('offline-area-name')), '   ');
      await tester.tap(find.byKey(const ValueKey('offline-download-confirm')));
      await settleSheet(tester);
      expect(manager.enqueued.map((e) => e.name).toSet(), {'Area 1'},
          reason: 'a blanked field must not queue an unnamed area');
    });
  });

  group('tapping an area on the map', () {
    testWidgets('one area under the tap opens its sheet directly',
        (tester) async {
      await pumpScreen(tester, [area('w', 'West block', west)]);
      await tapMap(tester, westOnly);

      expect(find.byKey(const ValueKey('offline-area-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('offline-area-chooser')), findsNothing);
      expect(find.text('West block'), findsOneWidget);
      expect(find.text('Rename'), findsOneWidget);
      expect(find.text('Update'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('a tap on bare map opens nothing', (tester) async {
      await pumpScreen(tester, [area('w', 'West block', west)]);
      await tapMap(tester, const LatLng(0, 0));
      expect(find.byKey(const ValueKey('offline-area-sheet')), findsNothing);
      expect(find.byKey(const ValueKey('offline-area-chooser')), findsNothing);
    });

    testWidgets('two areas under the tap ask which, then open the chosen one',
        (tester) async {
      await pumpScreen(tester, [
        area('w', 'West block', west),
        area('e', 'East block', east),
      ]);
      await tapMap(tester, overlap);

      final chooser = find.byKey(const ValueKey('offline-area-chooser'));
      expect(chooser, findsOneWidget,
          reason: 'a tap inside two areas must not pick one silently');
      expect(find.byKey(const ValueKey('offline-area-sheet')), findsNothing);
      expect(find.text('Which area?'), findsOneWidget);
      expect(find.text('West block'), findsOneWidget);
      expect(find.text('East block'), findsOneWidget);

      await tester.tap(find.text('East block'));
      await settleSheet(tester);
      expect(find.byKey(const ValueKey('offline-area-sheet')), findsOneWidget);
      expect(find.text('East block'), findsOneWidget);
      expect(find.text('West block'), findsNothing);
    });

    testWidgets('an area hidden by its layer toggle cannot be tapped',
        (tester) async {
      await pumpScreen(tester, [area('w', 'West block', west)]);
      await tester.tap(find.byTooltip('Toggle legend'));
      await tester.pump();

      // The layers menu is a popup; its item is driven by its own onTap so
      // the assertion is about the toggle, not about where the popup lands.
      Future<void> toggleTiles() async {
        await tester.tap(find.byTooltip('Layers'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        final item = find.widgetWithText(CheckedPopupMenuItem<void>, 'Tile coverage');
        expect(item, findsOneWidget);
        tester.widget<CheckedPopupMenuItem<void>>(item).onTap!();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        // Close the popup — onTap alone does not dismiss it.
        Navigator.of(tester.element(find.byType(FlutterMap))).maybePop();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await toggleTiles();
      await tapMap(tester, westOnly);
      expect(find.byKey(const ValueKey('offline-area-sheet')), findsNothing,
          reason: 'hidden areas are not tap targets');

      // The control: the same toggle back on, and the same tap opens it —
      // so the silence above was the toggle and not a broken tap.
      await toggleTiles();
      await tapMap(tester, westOnly);
      expect(find.byKey(const ValueKey('offline-area-sheet')), findsOneWidget);
    });

    testWidgets('while a selection is being drawn, taps do not open areas',
        (tester) async {
      await pumpScreen(tester, [area('w', 'West block', west)]);
      await tester.tap(find.byTooltip('Toggle legend'));
      await tester.pump();
      await tester.tap(find.text('New selection'));
      await tester.pump();
      await tapMap(tester, westOnly);
      expect(find.byKey(const ValueKey('offline-area-sheet')), findsNothing);
    });
  });

  group('the sheet\'s actions', () {
    testWidgets('Update re-queues the area under its own id and name',
        (tester) async {
      final manager =
          await pumpScreen(tester, [area('w', 'West block', west)]);
      await tapMap(tester, westOnly);
      await tester.tap(find.text('Update'));
      await settleSheet(tester);

      expect(manager.enqueued, [(kind: 'tiles', name: 'West block', id: 'w')]);
      expect(find.textContaining('Updating "West block"'), findsOneWidget);
      expect(find.textContaining('deletes nothing'), findsOneWidget);
    });

    testWidgets('Update on an area already downloading queues nothing',
        (tester) async {
      final manager =
          await pumpScreen(tester, [area('w', 'West block', west)]);
      manager.inFlight.add('w');
      await tapMap(tester, westOnly);
      await tester.tap(find.text('Update'));
      await settleSheet(tester);
      expect(manager.enqueued, isEmpty);
      expect(find.textContaining('already downloading'), findsOneWidget);
    });

    testWidgets('Delete confirms with the name and what it really frees',
        (tester) async {
      final w = area('w', 'West block', west,
          sizeBytes: 10 * 1024 * 1024,
          sharedBytes: 4 * 1024 * 1024,
          sharedWithIds: ['e']);
      final e = area('e', 'East block', east,
          sizeBytes: 8 * 1024 * 1024,
          sharedBytes: 4 * 1024 * 1024,
          sharedWithIds: ['w']);
      await pumpScreen(tester, [w, e]);
      await tapMap(tester, westOnly);
      // The sheet already says what is shared.
      expect(find.textContaining('4.0MB shared with "East block"'),
          findsOneWidget);
      await tester.tap(find.text('Delete'));
      await settleSheet(tester);

      expect(find.text('Delete "West block"?'), findsOneWidget);
      expect(find.text(deleteConfirmationSentence(w, [w, e])), findsOneWidget);
      expect(find.textContaining('Frees 6.0MB'), findsOneWidget,
          reason: 'the footprint is 10MB; 4MB of it stays for the East block');
      expect(find.textContaining('"East block"'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await settleSheet(tester);
    });

    testWidgets('Rename opens the name dialog with the current name',
        (tester) async {
      await pumpScreen(tester, [area('w', 'West block', west)]);
      await tapMap(tester, westOnly);
      await tester.tap(find.text('Rename'));
      await settleSheet(tester);
      expect(find.text('Name this area'), findsOneWidget);
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).controller!.text, 'West block');
      await tester.tap(find.text('Cancel'));
      await settleSheet(tester);
    });
  });

  group('a dead tile source (task 11.231)', () {
    testWidgets('the sheet names it and Update is refused', (tester) async {
      await pumpScreen(tester, [
        area('w', 'West block', west, sourceId: 'a-source-this-build-lacks'),
      ]);
      await tapMap(tester, westOnly);

      expect(find.byKey(const ValueKey('offline-area-dead-source')),
          findsOneWidget);
      expect(find.text(deadSourceSentence), findsOneWidget);

      final updateButton = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Update'),
          matching: find.byType(OutlinedButton),
        ),
      );
      expect(updateButton.onPressed, isNull,
          reason: 're-downloading needs a real tile provider to ask, and '
              'this build has none by that id');
    });

    testWidgets('an area with a known source shows no such note',
        (tester) async {
      await pumpScreen(tester, [area('w', 'West block', west)]);
      await tapMap(tester, westOnly);
      expect(find.byKey(const ValueKey('offline-area-dead-source')),
          findsNothing);
    });

    test('regionHasKnownSource is false only for a tile area with a dead id',
        () {
      expect(regionHasKnownSource(area('w', 'W', west)), isTrue);
      expect(
        regionHasKnownSource(
            area('w', 'W', west, sourceId: 'a-source-this-build-lacks')),
        isFalse,
      );
      // Elevation areas have no tile source; the question does not apply.
      expect(
        regionHasKnownSource(area('w', 'W', west).copyWith(
          kind: OfflineRegionKind.dem,
          sourceId: 'a-source-this-build-lacks',
        )),
        isTrue,
      );
    });
  });

  group('deleteConfirmationSentence', () {
    final w = area('w', 'West block', west,
        sizeBytes: 10 * 1024 * 1024,
        sharedBytes: 4 * 1024 * 1024,
        sharedWithIds: ['e']);
    final e = area('e', 'East block', east);

    test('nothing shared: the footprint, and that getting it back needs a '
        'connection', () {
      final s = deleteConfirmationSentence(e, [w, e]);
      expect(s, startsWith('Frees 4.0MB on this device.'));
      expect(s, contains('needs a connection'));
      expect(s, isNot(contains('stays')));
    });

    test('partly shared: the exclusive part frees, the shared part stays, '
        'and the neighbour is named', () {
      final s = deleteConfirmationSentence(w, [w, e]);
      expect(s, startsWith('Frees 6.0MB on this device.'));
      expect(s, contains('Another 4.0MB is also covered by "East block" and stays.'));
      expect(s, contains('needs a connection'));
    });

    test('wholly shared: frees nothing, says so, and says what it does do',
        () {
      final all = area('a', 'Copy', west,
          sizeBytes: 5 * 1024, sharedBytes: 5 * 1024, sharedWithIds: ['e']);
      final s = deleteConfirmationSentence(all, [all, e]);
      expect(s, startsWith('Frees nothing on this device'));
      expect(s, contains('"East block"'));
      expect(s, contains('only removes the area from the list'));
    });

    test('several neighbours are named, or counted past two', () {
      final r = area('r', 'R', west, sharedBytes: 1, sharedWithIds: ['a', 'b']);
      final a = area('a', 'A', east);
      final b = area('b', 'B', east);
      expect(sharedWithPhrase(r, [r, a, b]), '"A" and "B"');
      final c = area('c', null, east);
      final r3 = area('r', 'R', west, sharedBytes: 1, sharedWithIds: ['a', 'b', 'c']);
      expect(sharedWithPhrase(r3, [r3, a, b, c]), '"A" and 2 other areas');
      // An unnamed neighbour is named by its generic label, not skipped.
      final r1 = area('r', 'R', west, sharedBytes: 1, sharedWithIds: ['c']);
      expect(sharedWithPhrase(r1, [r1, c]), '"Tile area"');
    });
  });
}

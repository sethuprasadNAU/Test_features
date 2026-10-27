import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/more/screens/manage_offline_maps_screen.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Renders the reworked summary screen. [offlineRegionsProvider] does
/// file I/O (reconcileWithDisk / loadAll) via sqflite-adjacent path_provider
/// calls that don't resolve inside `testWidgets`' fake-async zone — pre-
/// resolve it with `tester.runAsync` first, the standard pattern for
/// path_provider-backed async in this test suite.
class _FixedRegions extends OfflineRegions {
  _FixedRegions(this._fixed);
  final List<OfflineRegion> _fixed;

  @override
  Future<List<OfflineRegion>> build() async => _fixed;
}

void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  testWidgets('renders empty state and storage rows with nothing downloaded', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });

    // Task 11.230 moved this file into the tab shell at phone geometry
    // (`pumpInAppShell`), so nothing here is measured at a height the screen
    // never has in the app.
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ManageOfflineMapsScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.takeException(), isNull);
    expect(find.text('Manage on map'), findsOneWidget);
    expect(find.textContaining('Nothing downloaded yet'), findsOneWidget);
    expect(find.text('Map tiles'), findsOneWidget);
    expect(find.text('Elevation (DEM)'), findsOneWidget);
    expect(find.text('Delete all tiles'), findsOneWidget);
    expect(find.text('Delete all elevation data'), findsOneWidget);
  });

  // --- Task 11.230: the row says what deleting it frees --------------------

  group('a downloaded-area row', () {
    final ts = DateTime.utc(2026, 1, 1);
    const poly = [
      LatLng(35.10, -111.70),
      LatLng(35.10, -111.60),
      LatLng(35.20, -111.60),
      LatLng(35.20, -111.70),
    ];
    OfflineRegion area(String id, String? name,
            {int size = 0,
            int shared = 0,
            List<String> with_ = const [],
            String sourceId = 'osm_standard'}) =>
        OfflineRegion(
          id: id,
          kind: OfflineRegionKind.tiles,
          name: name,
          polygon: poly,
          sourceId: sourceId,
          minZoom: 14,
          maxZoom: 14,
          tileTotal: 20,
          tileCompleted: 20,
          status: OfflineRegionStatus.complete,
          sizeBytes: size,
          sharedBytes: shared,
          sharedWithIds: with_,
          createdAt: ts,
          updatedAt: ts,
        );

    Future<void> pumpWith(WidgetTester tester, List<OfflineRegion> regions) async {
      final container = ProviderContainer(
        overrides: [
          offlineRegionsProvider.overrideWith(() => _FixedRegions(regions)),
        ],
      );
      addTearDown(container.dispose);
      await tester.runAsync(() async {
        await container.read(offlineRegionsProvider.future);
      });
      // In the shell at phone geometry: these cases tap rows and buttons.
      await pumpInAppShell(
        tester,
        container: container,
        screen: const ManageOfflineMapsScreen(),
        tabIndex: 4, // Map / Record / Compass / Position / **More**
      );
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('shows the exclusive size and names who the rest is shared with',
        (tester) async {
      await pumpWith(tester, [
        area('w', 'West block',
            size: 10 * 1024 * 1024, shared: 4 * 1024 * 1024, with_: ['e']),
        area('e', 'East block',
            size: 8 * 1024 * 1024, shared: 4 * 1024 * 1024, with_: ['w']),
      ]);
      // 10MB footprint, 4MB of it shared: the row's figure is the 6MB a
      // delete would free, and the footprint is recoverable from the line
      // below it. Before this task the row said 10MB and the two rows
      // together claimed 18MB for 14MB of files.
      expect(find.text('6.0MB'), findsOneWidget);
      expect(find.text('4.0MB'), findsOneWidget);
      expect(find.text('10.0MB'), findsNothing);
      expect(find.text('4.0MB shared with "East block"'), findsOneWidget);
      expect(find.text('4.0MB shared with "West block"'), findsOneWidget);
    });

    testWidgets('an unshared row has no shared line, and an unnamed one has '
        'the generic label', (tester) async {
      await pumpWith(tester, [area('w', null, size: 3 * 1024 * 1024)]);
      expect(find.text('Tile area'), findsOneWidget);
      expect(find.text('3.0MB'), findsOneWidget);
      expect(find.byKey(const ValueKey('offline-area-shared')), findsNothing);
    });

    testWidgets('tapping the row opens the name dialog', (tester) async {
      await pumpWith(tester, [area('w', 'West block')]);
      await tester.tap(find.text('West block'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Name this area'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'West block',
      );
    });

    testWidgets('the delete button asks with the name and the honest number',
        (tester) async {
      await pumpWith(tester, [
        area('w', 'West block',
            size: 10 * 1024 * 1024, shared: 4 * 1024 * 1024, with_: ['e']),
        area('e', 'East block', size: 8 * 1024 * 1024),
      ]);
      final row = find.ancestor(
          of: find.text('West block'), matching: find.byType(ListTile));
      await tester.tap(find.descendant(
          of: row, matching: find.byTooltip('Delete this area')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Delete "West block"?'), findsOneWidget);
      expect(find.textContaining('Frees 6.0MB on this device.'), findsOneWidget);
      expect(find.textContaining('Another 4.0MB is also covered by "East block" and stays.'),
          findsOneWidget);
      expect(find.textContaining('needs a connection'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
    });

    testWidgets('a dead tile source is named on the row (task 11.231)',
        (tester) async {
      await pumpWith(tester, [
        area('w', 'West block', sourceId: 'a-source-this-build-lacks'),
      ]);
      expect(find.byKey(const ValueKey('offline-area-dead-source')),
          findsOneWidget);
      expect(find.textContaining('this version no longer has'),
          findsOneWidget);
    });

    testWidgets('a known tile source shows no dead-source note',
        (tester) async {
      await pumpWith(tester, [area('w', 'West block')]);
      expect(find.byKey(const ValueKey('offline-area-dead-source')),
          findsNothing);
    });
  });
}

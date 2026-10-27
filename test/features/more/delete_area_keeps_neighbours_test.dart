import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/map/services/geo_polygon.dart';
import 'package:tritrack/features/map/services/offline_region_store.dart';
import 'package:tritrack/features/map/services/tile_cache.dart';
import 'package:tritrack/features/more/screens/manage_offline_maps_screen.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// **Deleting one downloaded area must not damage its neighbours** — task
/// 11.230, from Michael's prediction on 2026-09-12: *"the selected area might
/// have tiles that extend beyond the area selection... this could cause a
/// deletion of a large tile that overlaps with a different existing map area
/// that is still needed."*
///
/// Every downloaded tile lives in one shared tree, one file per
/// (source, zoom, x, y), and nothing records which area a tile belongs to. So
/// two areas that overlap share every tile in the overlap, and deleting one
/// area by walking its own polygon deletes the neighbour's tiles with it.
/// Before this task the "Offline Data" list did exactly that and its doc
/// comment called the result — the neighbour silently downgraded to
/// `partial` — a feature.
///
/// This is the end-to-end proof: two overlapping areas on a real (temporary)
/// disk, the real list screen, a tap on one area's delete button, and the
/// other area read back from the manifest. It was watched red against the
/// code as it stood on 2026-09-12 — the surviving area came back `partial`
/// with the shared tiles gone — before the fix was written.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  final ts = DateTime.utc(2026, 1, 1);

  // Two squares of one tenth of a degree, offset by half that, so their
  // overlap is a quarter of each. At zoom 14 that is a few dozen tiles each,
  // with a handful shared.
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

  OfflineRegion tileArea(String id, String name, List<LatLng> polygon) =>
      OfflineRegion(
        id: id,
        kind: OfflineRegionKind.tiles,
        name: name,
        polygon: polygon,
        sourceId: 'osm_standard',
        minZoom: 14,
        maxZoom: 14,
        tileTotal: 0,
        tileCompleted: 0,
        status: OfflineRegionStatus.downloading,
        sizeBytes: 0,
        createdAt: ts,
        updatedAt: ts,
      );

  OfflineRegion demArea(String id, String name, List<LatLng> polygon) =>
      OfflineRegion(
        id: id,
        kind: OfflineRegionKind.dem,
        name: name,
        polygon: polygon,
        tileTotal: 0,
        tileCompleted: 0,
        status: OfflineRegionStatus.downloading,
        sizeBytes: 0,
        createdAt: ts,
        updatedAt: ts,
      );

  /// Writes a 10-byte file for every zoom-14 tile of [polygon].
  Future<void> writeTiles(List<LatLng> polygon) async {
    for (final t in GeoPolygon.tilesInPolygon(
      polygon: polygon,
      zoomLevels: const [14],
    )) {
      final file = await TileCache.tileFile('osm_standard', t.z, t.x, t.y);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(Uint8List(10));
    }
  }

  ElevationGrid gridFor(DemTileId id) {
    final spec = id.gridSpec();
    final n = spec.ncols * spec.nrows;
    return ElevationGrid(
      ncols: spec.ncols,
      nrows: spec.nrows,
      xllCorner: spec.xllCorner,
      yllCorner: spec.yllCorner,
      cellSizeDegrees: spec.cellSizeDegrees,
      data: Float64List(n)..fillRange(0, n, 100),
    );
  }

  /// Writes a real DEM tile for every 0.1° tile [polygon] intersects.
  Future<void> writeDem(List<LatLng> polygon) async {
    final store = DemTileStore();
    for (final id in store.tilesIntersectingPolygon(polygon)) {
      await store.saveTile(id, gridFor(id));
    }
  }

  /// A bounded settle: the default is ten minutes of silence.
  Future<void> settle(WidgetTester tester) => tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 10),
      );

  Future<ProviderContainer> pumpList(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });
    // In the tab shell at phone geometry, as the app shows it: the rows
    // and their delete buttons have to be findable and tappable where a
    // person would find them.
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ManageOfflineMapsScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
    await settle(tester);
    return container;
  }

  /// Taps the delete button on the row titled [name], confirms, and waits
  /// for the manifest to be rewritten. The delete does real file I/O, so the
  /// whole interaction runs under `runAsync` and waits in real time — a fake
  /// clock never sees a file delete complete.
  Future<void> deleteRow(
    WidgetTester tester,
    ProviderContainer container,
    String name,
  ) async {
    final row = find.ancestor(
      of: find.text(name),
      matching: find.byType(ListTile),
    );
    expect(row, findsOneWidget, reason: 'the list should show "$name"');
    await tester.runAsync(() async {
      await tester.tap(find.descendant(
        of: row,
        matching: find.byTooltip('Delete this area'),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await settle(tester);
      expect(find.text('Delete'), findsOneWidget,
          reason: 'a confirmation should be up');
      await tester.tap(find.text('Delete'));
      // The delete walks the disk and rewrites the manifest before the
      // provider is invalidated; wait for the provider to come back.
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        final regions = container.read(offlineRegionsProvider).value;
        if (regions != null && !regions.any((r) => r.name == name)) return;
      }
      fail('"$name" was still in the list ten seconds after Delete');
    });
  }

  testWidgets(
      'deleting one of two overlapping tile areas leaves the other complete',
      (tester) async {
    // **Built inside `runAsync`.** The store's write queue starts as a
    // `Future.value()`, and a future made under the test's fake clock chains
    // its continuations onto that clock — so a store built in the test body
    // never finishes a write inside `runAsync`. Ten minutes of silence, then
    // a timeout; the `Completer` trap in `CLAUDE.md`, fourth disguise.
    late final OfflineRegionStore store;
    await tester.runAsync(() async {
      store = OfflineRegionStore();
      await writeTiles(west);
      await writeTiles(east);
      await store.upsert(tileArea('west', 'West block', west));
      await store.upsert(tileArea('east', 'East block', east));
    });

    final container = await pumpList(tester);
    // Both areas start whole, and they really do share tiles — otherwise
    // this test could pass without the fix.
    final before = container.read(offlineRegionsProvider).value!;
    expect(before.map((r) => r.status),
        everyElement(OfflineRegionStatus.complete));
    final westTiles = GeoPolygon.tilesInPolygon(
        polygon: west, zoomLevels: const [14]);
    final eastTiles = GeoPolygon.tilesInPolygon(
        polygon: east, zoomLevels: const [14]);
    final eastKeys = {for (final t in eastTiles) '${t.z}/${t.x}/${t.y}'};
    final shared = westTiles
        .where((t) => eastKeys.contains('${t.z}/${t.x}/${t.y}'))
        .length;
    expect(shared, greaterThan(0),
        reason: 'the fixture must overlap or it proves nothing');

    await deleteRow(tester, container, 'West block');

    final after = await tester.runAsync(() => store.loadAll());
    final survivor = after!.singleWhere((r) => r.id == 'east');
    expect(
      survivor.status,
      OfflineRegionStatus.complete,
      reason: 'The East block shares $shared tiles with the West block. '
          'Deleting the West block must leave every one of them, because '
          'the East block still covers them — it is '
          '${survivor.tileCompleted}/${survivor.tileTotal}.',
    );
    expect(survivor.tileCompleted, eastTiles.length);
    // And the West block's own tiles — the ones nobody else covers — are
    // really gone, so this is a delete and not a no-op.
    var westOnlyRemaining = 0;
    await tester.runAsync(() async {
      for (final t in westTiles) {
        if (eastKeys.contains('${t.z}/${t.x}/${t.y}')) continue;
        if (await (await TileCache.tileFile('osm_standard', t.z, t.x, t.y)).exists()) {
          westOnlyRemaining++;
        }
      }
    });
    expect(westOnlyRemaining, 0,
        reason: 'tiles only the deleted area covered should be gone');
  });

  testWidgets(
      'deleting one of two overlapping elevation areas leaves the other complete',
      (tester) async {
    late final OfflineRegionStore store;
    final dem = DemTileStore();
    await tester.runAsync(() async {
      store = OfflineRegionStore();
      await writeDem(west);
      await writeDem(east);
      await store.upsert(demArea('west-dem', 'West ground', west));
      await store.upsert(demArea('east-dem', 'East ground', east));
    });

    final container = await pumpList(tester);
    final before = container.read(offlineRegionsProvider).value!;
    expect(before.map((r) => r.status),
        everyElement(OfflineRegionStatus.complete));
    final westIds = dem.tilesIntersectingPolygon(west).toSet();
    final eastIds = dem.tilesIntersectingPolygon(east).toSet();
    final shared = westIds.intersection(eastIds);
    expect(shared, isNotEmpty,
        reason: 'the fixture must overlap or it proves nothing');

    await deleteRow(tester, container, 'West ground');

    final after = await tester.runAsync(() => store.loadAll());
    final survivor = after!.singleWhere((r) => r.id == 'east-dem');
    expect(
      survivor.status,
      OfflineRegionStatus.complete,
      reason: 'The East ground shares ${shared.length} elevation tiles with '
          'the West ground and must keep them — it is '
          '${survivor.tileCompleted}/${survivor.tileTotal}.',
    );
    var westOnlyRemaining = 0;
    await tester.runAsync(() async {
      for (final id in westIds.difference(eastIds)) {
        if (await dem.hasTile(id)) westOnlyRemaining++;
      }
    });
    expect(westOnlyRemaining, 0,
        reason: 'elevation tiles only the deleted area covered should be gone');
  });
}

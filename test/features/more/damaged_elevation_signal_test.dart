import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tritrack/features/map/models/offline_region.dart';
import 'package:tritrack/features/map/providers/offline_regions_provider.dart';
import 'package:tritrack/features/map/screens/map_screen.dart'
    show kPartialTerrainCaveat;
import 'package:tritrack/features/more/screens/manage_offline_maps_screen.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';

import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// **A terrain tile is refused and somebody is now told** — task 11.120,
/// carrying task 11.146.
///
/// `DemTileStore` knows a tile on disk is unusable and silently re-fetches it.
/// That repairs it when there is a connection; offline it stays a hole, and
/// nothing on the device said so. The row for that downloaded area now does.
class _FixedRegions extends OfflineRegions {
  _FixedRegions(this._regions);
  final List<OfflineRegion> _regions;

  @override
  Future<List<OfflineRegion>> build() async => _regions;
}

/// Reports a fixed damage count without touching a disk, so this measures the
/// row rather than the store. What `unusable` means, and that the store
/// reports it, is `test/viewshed/`'s job.
OfflineRegion _demRegion() => OfflineRegion(
      id: 'dem-1',
      kind: OfflineRegionKind.dem,
      name: 'North ridge',
      polygon: const [
        LatLng(35.0, -111.2),
        LatLng(35.0, -111.0),
        LatLng(35.2, -111.0),
        LatLng(35.2, -111.2),
      ],
      tileTotal: 48,
      tileCompleted: 48,
      status: OfflineRegionStatus.complete,
      sizeBytes: 1024 * 1024,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  Future<void> pump(WidgetTester tester, {required int damaged}) async {
    final container = ProviderContainer(
      overrides: [
        offlineRegionsProvider.overrideWith(() => _FixedRegions([_demRegion()])),
        elevationTileDamageProvider('dem-1')
            .overrideWith((ref) async => (damaged: damaged, total: 48)),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(offlineRegionsProvider.future);
    });

    // Real phone geometry inside the real tab shell (task 11.126): this row
    // grows by a wrapping sentence, and a bare pump measures it with height
    // the screen does not have.
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ManageOfflineMapsScreen(),
      tabIndex: 4, // Map / Record / Compass / Position / **More**
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('an area with unreadable elevation tiles says so, and says what '
      'to do about it', (tester) async {
    await pump(tester, damaged: 3);

    final line = find.byKey(const ValueKey('elevation-tiles-unreadable'));
    expect(line, findsOneWidget);
    final text = tester.widget<Text>(find.descendant(
      of: line,
      matching: find.byType(Text),
    ));
    printOnFailure('the row says: ${text.data}');

    expect(text.data, contains('3 of 48'));
    expect(
      text.data,
      contains('needs a connection'),
      reason: 'the remedy is a download, and the field is where the '
          'connection is not — a sentence naming an action somebody cannot '
          'take, without saying so, is worse than silence',
    );
    expect(
      text.data,
      contains('Manage on map'),
      reason: 'it names where the action is, and that button is at the top '
          'of this same screen',
    );
  });

  testWidgets('an area with nothing wrong says nothing', (tester) async {
    await pump(tester, damaged: 0);
    expect(
      find.byKey(const ValueKey('elevation-tiles-unreadable')),
      findsNothing,
      reason: 'a standing warning about a state that is not happening is how '
          'people learn to stop reading warnings',
    );
    // The ordinary row is still there and unchanged.
    expect(find.text('North ridge'), findsOneWidget);
  });

  test('the count comes from the store, not from a fixture', () async {
    // The two widget cases above override the provider, so on their own they
    // prove the row and nothing about the counting. This one uses the real
    // [DemTileStore] against a real temp directory: a file that is there and
    // will not parse is exactly `DemTileHealth.unusable`, which is the one
    // state this signal is about.
    final container = ProviderContainer(
      overrides: [
        offlineRegionsProvider.overrideWith(() => _FixedRegions([_demRegion()])),
      ],
    );
    addTearDown(container.dispose);

    final store = DemTileStore();
    final ids = store.tilesIntersectingPolygon(_demRegion().polygon);
    expect(ids, isNotEmpty, reason: 'the fixture polygon covers some tiles');

    final none = await container.read(elevationTileDamageProvider('dem-1').future);
    expect(
      none.damaged,
      0,
      reason: 'tiles that were never downloaded are absent, not unreadable — '
          '"Partial" on the row already says that',
    );
    expect(none.total, ids.length);

    final root = Directory(
      '${(await getApplicationSupportDirectory()).path}/dem_tiles',
    );
    await root.create(recursive: true);
    await File('${root.path}/${ids.first.latIndex}_${ids.first.lonIndex}.asc')
        .writeAsString('this is not an ASCII grid');

    container.invalidate(elevationTileDamageProvider('dem-1'));
    final some = await container.read(elevationTileDamageProvider('dem-1').future);
    printOnFailure('counted ${some.damaged} unreadable of ${some.total}');
    expect(some.damaged, 1);
    expect(some.total, ids.length);
  });

  test('it does not say the same thing as the viewshed caveat', () {
    // Task 11.146 required this comparison: 11.142 already tells somebody
    // that a *viewshed* was worked out over incomplete terrain. This one is
    // about the *stored data*, and the two must not read as one message
    // repeated in two places.
    final stored = damagedElevationSentence(3, 48);
    printOnFailure('stored data:  $stored');
    printOnFailure('viewshed:     $kPartialTerrainCaveat');

    List<String> sentences(String s) => [
          for (final part in s.split('. '))
            part.trim().replaceAll(RegExp(r'[.]$'), '').toLowerCase(),
        ]..removeWhere((p) => p.isEmpty);

    final shared =
        sentences(stored).toSet().intersection(sentences(kPartialTerrainCaveat).toSet());
    expect(
      shared,
      isEmpty,
      reason: 'these two messages share a sentence: $shared. They are about '
          'different facts — one about a result on screen, one about files on '
          'this device — and a reader who meets the same sentence twice will '
          'read the second one as the first.',
    );

    // And the subjects really are different, not merely differently worded.
    expect(stored, isNot(contains('viewshed')));
    expect(kPartialTerrainCaveat, isNot(contains('cannot be read')));
  });
}

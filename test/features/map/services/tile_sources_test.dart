import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/tile_sources.dart';

void main() {
  test('curated list covers all three basemap categories', () {
    final categories = TileSources.all.map((s) => s.category).toSet();
    expect(categories, {TileCategory.terrain, TileCategory.street, TileCategory.satellite});
  });

  test('every source has non-empty attribution (offline caching requires it)', () {
    for (final source in TileSources.all) {
      expect(source.attribution, isNotEmpty, reason: '${source.id} must attribute its data');
      expect(source.urlTemplate, contains('{z}'));
      expect(source.urlTemplate, contains('{x}'));
      expect(source.urlTemplate, contains('{y}'));
    }
  });

  test('byId refuses an unknown id rather than substituting a default', () {
    // Task 11.231: this used to fall back to OpenStreetMap, which is what
    // let 11.230's fixture ('osm') pass while deleting nothing at all — the
    // lookup silently returned a source whose files live under a different
    // directory. Watched failing against the old fallback before this fix.
    expect(() => TileSources.byId('nonexistent'), throwsArgumentError);
    expect(TileSources.byId(TileSources.openTopoMap.id), TileSources.openTopoMap);
  });

  test('tryById answers null for an unknown id, and the real source otherwise', () {
    expect(TileSources.tryById('nonexistent'), isNull);
    expect(TileSources.tryById(TileSources.esriWorldImagery.id),
        TileSources.esriWorldImagery);
  });
}

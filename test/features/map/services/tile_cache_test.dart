import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/features/map/services/tile_cache.dart';

import '../../../support/fake_path_provider.dart';

void main() {
  setUp(installFakePathProvider);

  test('tileFile is deterministic and namespaced by source', () async {
    final a = await TileCache.tileFile('osm', 5, 10, 15);
    final b = await TileCache.tileFile('osm', 5, 10, 15);
    final other = await TileCache.tileFile('opentopo', 5, 10, 15);
    expect(a.path, b.path);
    expect(a.path, isNot(other.path));
    expect(a.path, contains('osm'));
    expect(a.path, contains('5'));
  });

  test('sizeBytes and tileCount reflect what has actually been written', () async {
    expect(await TileCache.sizeBytes(), 0);
    expect(await TileCache.tileCount(), 0);

    final file = await TileCache.tileFile('osm', 1, 0, 0);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(List.filled(100, 0));

    expect(await TileCache.tileCount(), 1);
    expect(await TileCache.sizeBytes(), 100);
    expect(await TileCache.tileCount(sourceId: 'osm'), 1);
    expect(await TileCache.tileCount(sourceId: 'opentopo'), 0);
  });

  test('clear removes only the scoped source when given one', () async {
    final osmFile = await TileCache.tileFile('osm', 1, 0, 0);
    final otherFile = await TileCache.tileFile('opentopo', 1, 0, 0);
    for (final f in [osmFile, otherFile]) {
      await f.parent.create(recursive: true);
      await f.writeAsBytes([1, 2, 3]);
    }

    await TileCache.clear(sourceId: 'osm');
    expect(await osmFile.exists(), isFalse);
    expect(await otherFile.exists(), isTrue);

    await TileCache.clear();
    expect(await otherFile.exists(), isFalse);
  });
}

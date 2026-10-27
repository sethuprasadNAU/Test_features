import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../viewshed/dem_tile_store.dart';
import '../models/offline_region.dart';
import '../services/offline_region_store.dart';
import 'download_manager.dart';

part 'offline_regions_provider.g.dart';

/// The current offline-coverage manifest — what map tiles / DEM tiles are
/// actually on disk, reconciled against disk truth on every load so the
/// coverage overlays on [OfflineDataMapScreen] never lie about what's really
/// downloaded.
///
/// Rebuilds whenever a [DownloadJob] reaches (or leaves) a terminal state —
/// watched via a `.select` on [downloadManagerProvider] so a job's frequent
/// `done`/`total` progress ticks don't each trigger a disk reconcile, only an
/// actual completion/failure/cancellation does. Screens should also call
/// `ref.invalidate(offlineRegionsProvider)` directly after a manual delete.
@Riverpod(keepAlive: true)
class OfflineRegions extends _$OfflineRegions {
  @override
  Future<List<OfflineRegion>> build() async {
    ref.watch(downloadManagerProvider.select(
      (jobs) => [for (final j in jobs) '${j.id}:${j.status.name}'].join(','),
    ));
    final store = OfflineRegionStore();
    await store.reconcileWithDisk(
      tileCounter: const TileCacheCounter(),
      demStore: DemTileStore(),
    );
    return store.loadAll();
  }
}

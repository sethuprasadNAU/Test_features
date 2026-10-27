import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/map/models/offline_region.dart';
import '../../../features/map/providers/offline_regions_provider.dart';
import '../../../features/map/services/tile_cache.dart';
import '../../../features/map/widgets/offline_region_actions.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../../../widgets/load_failure.dart';

/// Offline data summary: lists what's been downloaded (from the coverage
/// manifest, see [offlineRegionsProvider]) with total disk usage, and hands
/// off to `OfflineDataMapScreen` for the actual "see coverage on a map,
/// select an area, download or erase" workflow (Phase C). This screen used
/// to hold the download UI itself (project-extent-only download dialogs, a
/// resolution slider, and a progress `AlertDialog` that had no "Completed"
/// state and only ever showed "Cancel") — all replaced by the map screen and
/// its honest per-job progress cards.
class ManageOfflineMapsScreen extends ConsumerWidget {
  const ManageOfflineMapsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final regionsAsync = ref.watch(offlineRegionsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Offline Data')),
      body: regionsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) =>
            LoadFailure('the list of downloaded map areas', error: e),
        data: (regions) => _Body(regions: regions),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.regions});
  final List<OfflineRegion> regions;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // **Task 11.230 — the totals are read off the disk, not summed from the
    // rows.** Summing `sizeBytes` counted a tile shared by two overlapping
    // areas twice; summing what each row now shows (its exclusive bytes)
    // would count it zero times. Neither is what "Delete all" frees. The
    // disk is, and it also holds tiles cached while panning that belong to
    // no area — so the total can legitimately exceed the rows, and the line
    // under the totals says so.
    final totals = ref.watch(offlineStorageTotalsProvider).value;
    final tileBytes = totals?.tileBytes;
    final demBytes = totals?.demBytes;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          height: 48,
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => context.push('/more/offline-data-map'),
            icon: const Icon(Icons.map_outlined),
            label: const Text('Manage on map'),
          ),
        ),
        const SizedBox(height: 16),
        const _SectionLabel('DOWNLOADED AREAS'),
        const SizedBox(height: 8),
        if (regions.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Nothing downloaded yet. Use "Manage on map" to select an area '
              'for offline map tiles and elevation data.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          )
        else
          for (final region in regions)
            _RegionTile(
              region: region,
              all: regions,
              onRename: () => renameRegionDialog(context, ref, region),
              onDelete: () => confirmAndDeleteRegion(context, ref, region, regions),
            ),
        const SizedBox(height: 16),
        const _SectionLabel('STORAGE'),
        const SizedBox(height: 8),
        ListTile(
          dense: true,
          leading: const Icon(Icons.layers_outlined),
          title: const Text('Map tiles'),
          trailing: Text(tileBytes == null ? '…' : formatBytes(tileBytes)),
        ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.terrain_outlined),
          title: const Text('Elevation (DEM)'),
          trailing: Text(demBytes == null ? '…' : formatBytes(demBytes)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Everything on this device, including tiles kept from panning '
            'the map. Areas that overlap share tiles, so the areas above '
            'may add up to less.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: () => _confirmDeleteAllTiles(context, ref),
          child: const Text('Delete all tiles'),
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: () => _confirmDeleteAllDem(context, ref),
                    child: const Text('Delete all elevation data'),
        ),
        const SizedBox(height: 16),
        const _SectionLabel('ELEVATION DATA'),
        const SizedBox(height: 8),
        // **Task 11.138 was asked to write this button's disabled reason on
        // the button. It established the reason first, and the reason turned
        // out to be an argument for removing the button.**
        //
        // What was here: `Import DEM file (.asc) — unavailable`, permanently
        // `onPressed: null`, with "temporarily disabled: needs re-wiring to
        // the tiled DEM store (see TODO in source)" in a `Tooltip` — a
        // sentence a phone cannot show, pointing at a source file the person
        // holding the phone cannot open.
        //
        // The reason, established rather than paraphrased — and it is worse
        // than the source comment said. That comment described re-wiring
        // `DemRepository` against the tiled store, as though the importer were
        // sitting there waiting. **`DemRepository` does not exist.** It was
        // deleted in `886d7ce` when elevation moved to `DemTileStore`, a 0.1°
        // lattice of tiles. So the button was not disabled pending a rewire;
        // it was disabled pending a rewrite of something already gone, and the
        // TODO it pointed a reader at had outlived the class it named.
        //
        // Why the button goes rather than gets a better sentence: **there is a
        // route that works, and nobody needs the other one.** Elevation for an
        // area is downloaded on the Offline Data Map by drawing the area and
        // ticking elevation (`DownloadManager.enqueueDem`), and everything
        // else on this screen — the size figure above, the region rows,
        // "Delete all elevation data" — is about data that arrived that way.
        // **Michael settled the remaining question on 2026-09-02: he never
        // needs to load an elevation file from disk**, so there is no
        // unwritten feature behind this control, only a dead affordance that
        // told somebody their app was broken when it was not.
        Text(
          'Elevation comes down with an area: on the Offline Data Map, draw '
          'the area and tick elevation. There is no separate file import.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDeleteAllTiles(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all cached tiles?'),
        content: const Text('Tiles can be re-downloaded later; this only frees storage now.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await TileCache.clear();
    ref.invalidate(offlineRegionsProvider);
  }

  Future<void> _confirmDeleteAllDem(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all elevation data?'),
        content: const Text('Viewshed prediction will be unavailable until elevation data is re-downloaded.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await DemTileStore().deleteAll();
    ref.invalidate(offlineRegionsProvider);
  }
}

/// Bytes of map tiles and of elevation on this device, read from the disk.
/// Re-read whenever the coverage manifest changes, which is what every
/// delete on this screen invalidates. Task 11.230 — see `_Body.build` for
/// why this is not a sum of the rows.
final offlineStorageTotalsProvider =
    FutureProvider<({int tileBytes, int demBytes})>((ref) async {
  await ref.watch(offlineRegionsProvider.future);
  return (
    tileBytes: await TileCache.sizeBytes(),
    demBytes: await DemTileStore().sizeBytes(),
  );
});

/// How many of an elevation area's tiles are on disk but **unusable**, out of
/// how many that area covers — task 11.120, carrying task 11.146.
///
/// `unusable` is one of [DemTileHealth]'s four states and is the only one this
/// counts. `absent` is not damage: a tile that was never fetched is what
/// "Partial" on the row above already says. `incomplete` is not damage
/// either — it is usable elevation that the store will top up when it next
/// gets the chance. **`unusable` is a file that is there and must not be
/// served**: it is not the length that was recorded for it, it will not
/// parse, or it carries no elevation at all. [DemTileStore] silently
/// re-fetches such a tile, which repairs it — **when there is a connection.**
/// Offline, it stays a hole and nothing on this device said so.
///
/// Keyed by region id rather than taking the region, so this re-derives
/// itself whenever the coverage manifest changes.
final elevationTileDamageProvider =
    FutureProvider.family<({int damaged, int total}), String>(
        (ref, regionId) async {
  final regions = await ref.watch(offlineRegionsProvider.future);
  OfflineRegion? region;
  for (final r in regions) {
    if (r.id == regionId) region = r;
  }
  if (region == null || region.kind != OfflineRegionKind.dem) {
    return (damaged: 0, total: 0);
  }
  final store = DemTileStore();
  final ids = store.tilesIntersectingPolygon(region.polygon);
  var damaged = 0;
  for (final id in ids) {
    if (await store.tileHealth(id) == DemTileHealth.unusable) damaged++;
  }
  return (damaged: damaged, total: ids.length);
});

/// **What a person is told about elevation files that cannot be read** —
/// task 11.120, carrying task 11.146.
///
/// Deliberately not the same fact as task 11.142's `kPartialTerrainCaveat`
/// (in `map_screen.dart` — not imported here, so that a screen about storage
/// does not depend on the map), which travels
/// with a *viewshed* and says that the answer on screen was worked out over
/// gaps. This is about the *data on this device*, it is true whether or not
/// anybody has computed anything, and it is on the screen somebody visits
/// **before** going out — which is the point of it: the remedy is a download,
/// the field is where the connection is not, and a fact that only surfaces
/// during a viewshed surfaces at the one moment nothing can be done about it.
///
/// Names no cause, because the store does not know one — an interrupted
/// write, a full disk and a source that returned nonsense all land in the
/// same state. It names the consequence, the action, and the one condition
/// the action has.
String damagedElevationSentence(int damaged, int total) =>
    '$damaged of $total elevation tiles here cannot be read, so ground they '
    'cover counts as having no elevation. Download this area again from '
    '"Manage on map" — that needs a connection.';

class _RegionTile extends ConsumerWidget {
  const _RegionTile({
    required this.region,
    required this.all,
    required this.onRename,
    required this.onDelete,
  });
  final OfflineRegion region;
  final List<OfflineRegion> all;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDem = region.kind == OfflineRegionKind.dem;
    final statusLabel = switch (region.status) {
      OfflineRegionStatus.complete => 'Complete',
      OfflineRegionStatus.partial => 'Partial',
      OfflineRegionStatus.downloading => 'Downloading',
      OfflineRegionStatus.failed => 'Failed',
    };
    final bbox = _boundsSummary(region);
    // Only elevation areas are asked: [elevationTileDamageProvider] answers 0
    // for a tile area, and asking would put a per-region disk walk behind
    // every row for a state that cannot arise there.
    final damage = isDem
        ? ref.watch(elevationTileDamageProvider(region.id)).value
        : null;

    // **Task 11.230 — the size on the row is what deleting the row frees.**
    // `sizeBytes` is the area's whole footprint and two overlapping areas
    // each count the tiles they share, so the rows overstated what a delete
    // would give back — in the one direction that sends somebody to delete
    // the wrong area. The trailing figure is now the exclusive part, and the
    // shared part is named on its own line, with whom, so the footprint is
    // still on the screen for anyone who wants it (exclusive + shared).
    final shared = region.sharedBytes > 0
        ? '${formatBytes(region.sharedBytes)} shared with '
            '${sharedWithPhrase(region, all)}'
        : null;
    final deadSource = !regionHasKnownSource(region);
    final threeLines = shared != null ||
        (damage != null && damage.damaged > 0) ||
        deadSource;

    return ListTile(
      dense: true,
      isThreeLine: threeLines,
      leading: Icon(isDem ? Icons.terrain_outlined : Icons.map_outlined),
      title: Text(region.displayName),
      // Tapping the row names it. The map's area sheet has the same action
      // as a labelled button; here the row is the affordance, which the
      // simplicity rule allows so long as a person can find it by trying.
      onTap: onRename,
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$bbox · $statusLabel · ${region.tileCompleted}/${region.tileTotal}'),
          if (shared != null)
            Text(shared, key: const ValueKey('offline-area-shared')),
          if (deadSource)
            Padding(
              key: const ValueKey('offline-area-dead-source'),
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                deadSourceSentence,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (damage != null && damage.damaged > 0)
            Padding(
              key: const ValueKey('elevation-tiles-unreadable'),
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                damagedElevationSentence(damage.damaged, damage.total),
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatBytes(region.exclusiveBytes)),
          // Task 11.94/11.101 exemption: labelled only by `tooltip:`,
          // adopting task 11.99's line — alone at the end of its row, and
          // `onDelete` (`_confirmDeleteRegion`) confirms before acting.
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Delete this area',
            visualDensity: VisualDensity.compact,
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  String _boundsSummary(OfflineRegion region) {
    if (region.polygon.isEmpty) return '—';
    var minLat = region.polygon.first.latitude, maxLat = region.polygon.first.latitude;
    var minLon = region.polygon.first.longitude, maxLon = region.polygon.first.longitude;
    for (final p in region.polygon) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLon) minLon = p.longitude;
      if (p.longitude > maxLon) maxLon = p.longitude;
    }
    return '${minLat.toStringAsFixed(2)},${minLon.toStringAsFixed(2)} – '
        '${maxLat.toStringAsFixed(2)},${maxLon.toStringAsFixed(2)}';
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

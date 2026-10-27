import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/models/project.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../../map/models/offline_region.dart';
import '../../map/providers/download_manager.dart';
import '../../map/services/geo_polygon.dart';
import '../../map/services/offline_tile_downloader.dart';
import '../../map/services/tile_sources.dart';

/// **"Finish setting up"** — task 11.324, item 1, from Michael's comments on
/// the printed guide (2026-10-02).
///
/// Right after an owner saves a new project, one short sheet offers the two
/// things a project needs before anybody goes into the field: **publish it to
/// the server now** (only when this phone is signed in), and **download the
/// offline maps for its area now**, with the size shown first. Both boxes
/// start ticked. *Later* writes nothing and starts nothing; both stay on the
/// Pre-Trip Checklist, which checks them for real. A member who has just been
/// accepted gets the maps half only, once ([MapsOfferedAfterJoining]).
///
/// The download is the Offline Data screen's own — the same queue, the same
/// "keep the app open" rule (it pauses if the app is left), the same saved
/// area afterwards — over the project's bounding box, at that screen's
/// default zoom range and map style.

/// The maps for one project's area: what a download would fetch, roughly how
/// big it is, and whether it has already been done.
class ProjectAreaDownload {
  ProjectAreaDownload._({
    required this.project,
    required this.polygon,
    required this.mapTiles,
    required this.elevationTiles,
  });

  /// The Offline Data Map's download sheet starts at zoom 12–16 with
  /// OpenStreetMap; this uses the same, so the two make the same area.
  static const int minZoom = 12;
  static const int maxZoom = 16;

  /// **Averages, measured 2026-10-08 on Michael's Mac** (the app's own
  /// caches): OpenStreetMap tiles 9.7 KB, OpenTopoMap 25 KB, 15.9 KB across
  /// 5,157 tiles; elevation 199 KB per tile across 9. The map figure is the
  /// one the Offline Data Map's readout already uses. What would make these
  /// wrong: a different default map style, or a change to how elevation tiles
  /// are stored (`dem_ascii.dart`).
  static const int bytesPerMapTile = 15 * 1024;
  static const int bytesPerElevationTile = 200 * 1024;

  /// The project's area as a download, or null when it has none set.
  static ProjectAreaDownload? of(Project project) {
    final minLat = project.bboxMinLat;
    final minLon = project.bboxMinLon;
    final maxLat = project.bboxMaxLat;
    final maxLon = project.bboxMaxLon;
    if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
      return null;
    }
    final polygon = [
      LatLng(minLat, minLon),
      LatLng(minLat, maxLon),
      LatLng(maxLat, maxLon),
      LatLng(maxLat, minLon),
    ];
    return ProjectAreaDownload._(
      project: project,
      polygon: polygon,
      mapTiles: OfflineTileDownloader.estimateTileCount(
        minLat: minLat,
        minLon: minLon,
        maxLat: maxLat,
        maxLon: maxLon,
        zoomLevels: [for (var z = minZoom; z <= maxZoom; z++) z],
      ),
      elevationTiles: DemTileStore().tilesIntersectingPolygon(polygon).length,
    );
  }

  final Project project;
  final List<LatLng> polygon;
  final int mapTiles;
  final int elevationTiles;

  int get estimatedBytes =>
      mapTiles * bytesPerMapTile + elevationTiles * bytesPerElevationTile;

  /// "about 34 MB" — rounded up, because it is said before a download on
  /// somebody's data plan, and "about 0 MB" would be a promise.
  String get sizeLabel {
    final mb = (estimatedBytes / (1024 * 1024)).ceil();
    return 'about ${mb < 1 ? 1 : mb} MB';
  }

  /// One id per project, so asking twice does not queue the area twice
  /// (`DownloadManager` refuses an id already in flight) and the saved area
  /// is replaced rather than duplicated.
  String get _tilesId => 'project-area-${project.projectId}-tiles';
  String get _elevationId => 'project-area-${project.projectId}-dem';

  /// Whether this area's download is queued or running right now.
  bool isDownloading(List<DownloadJob> jobs) => jobs.any(
    (j) => (j.id == _tilesId || j.id == _elevationId) && !j.isTerminal,
  );

  /// Starts the download in the Offline Data queue, named after the project.
  void start(DownloadManager manager) {
    manager.enqueueTiles(
      polygon: polygon,
      sourceId: TileSources.openStreetMap.id,
      minZoom: minZoom,
      maxZoom: maxZoom,
      name: project.projectName,
      id: _tilesId,
    );
    manager.enqueueDem(
      polygon: polygon,
      name: project.projectName,
      id: _elevationId,
    );
  }

  /// Whether finished map tiles **and** finished elevation each cover the
  /// whole area — however they were downloaded (this sheet, or by hand on
  /// the Offline Data Map). Judged on each saved area's outline's bounds,
  /// which is exact for the rectangles this sheet and that screen make.
  bool isDownloaded(List<OfflineRegion> regions) {
    bool covered(OfflineRegionKind kind) => regions.any((r) {
      if (r.kind != kind || r.status != OfflineRegionStatus.complete) {
        return false;
      }
      if (r.polygon.length < 3) return false;
      final bb = GeoPolygon.boundingBox(r.polygon);
      return bb.minLat <= project.bboxMinLat! &&
          bb.minLon <= project.bboxMinLon! &&
          bb.maxLat >= project.bboxMaxLat! &&
          bb.maxLon >= project.bboxMaxLon!;
    });
    return covered(OfflineRegionKind.tiles) && covered(OfflineRegionKind.dem);
  }
}

/// What the person ticked. Both false for *Later*, or a sheet dismissed.
class FinishSetupChoice {
  const FinishSetupChoice({required this.publish, required this.downloadMaps});

  final bool publish;
  final bool downloadMaps;
}

/// The sheet. [publishAs] is the signed-in account that would become the
/// project's owner, or null to leave the publish box out (not signed in, or
/// a member). [maps] is null when the project has no area. Callers do not
/// open it with neither.
Future<FinishSetupChoice> showFinishSettingUpSheet(
  BuildContext context, {
  required String? publishAs,
  required ProjectAreaDownload? maps,
}) async {
  var publish = publishAs != null;
  var download = maps != null;
  final choice = await showModalBottomSheet<FinishSetupChoice>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setSheetState) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Finish setting up',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (publishAs != null)
                CheckboxListTile(
                  key: const ValueKey('finish_setup_publish'),
                  contentPadding: EdgeInsets.zero,
                  value: publish,
                  onChanged: (v) => setSheetState(() => publish = v ?? false),
                  title: const Text('Publish to the server now'),
                  subtitle: Text(
                    'Makes $publishAs its owner, so your team can join it.',
                  ),
                ),
              if (maps != null)
                CheckboxListTile(
                  key: const ValueKey('finish_setup_maps'),
                  contentPadding: EdgeInsets.zero,
                  value: download,
                  onChanged: (v) => setSheetState(() => download = v ?? false),
                  title: Text(
                    'Download offline maps for this area now '
                    '(${maps.sizeLabel})',
                  ),
                  subtitle: const Text(
                    'Map and elevation, for working without cell or wifi '
                    'coverage. Keep TriTrack open until it finishes — it '
                    'pauses if you leave the app.',
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                'Later leaves these on the Pre-Trip Checklist.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(
                      const FinishSetupChoice(
                        publish: false,
                        downloadMaps: false,
                      ),
                    ),
                    child: const Text('Later'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      FinishSetupChoice(
                        publish: publish,
                        downloadMaps: download,
                      ),
                    ),
                    child: const Text('Start'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return choice ??
      const FinishSetupChoice(publish: false, downloadMaps: false);
}

/// **"Once", for a member** — the maps half is offered the first time a
/// project arrives after the person's request is accepted, and never again on
/// this device, whatever they answered.
abstract final class MapsOfferedAfterJoining {
  static const _prefsKey = 'maps_offered_after_joining_v1';

  /// True the first time it is asked about [projectId], recording the ask;
  /// false every time after.
  static Future<bool> claim(String projectId) async {
    final prefs = SharedPreferencesAsync();
    final offered = await prefs.getStringList(_prefsKey) ?? const <String>[];
    if (offered.contains(projectId)) return false;
    await prefs.setStringList(_prefsKey, [...offered, projectId]);
    return true;
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/map_settings_provider.dart';
import '../../../core/providers/terrain_cache_provider.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../../../data/models/project.dart';
import '../../map/map_camera_target.dart';
import '../../map/models/offline_region.dart';
import '../../map/providers/download_manager.dart';
import '../../map/providers/offline_regions_provider.dart';
import '../../map/services/cached_tile_provider.dart';
import '../../map/services/desktop_map_gestures.dart';
import '../../map/services/geo_polygon.dart';
import '../../map/services/offline_region_store.dart';
import '../../map/services/offline_tile_downloader.dart';
import '../../map/services/tile_fetch_health.dart';
import '../../map/services/tile_sources.dart';
import '../../map/widgets/map_furniture.dart';
import '../../map/widgets/offline_region_actions.dart';

/// The offline-download map: shows exactly what's been downloaded (tile and
/// DEM coverage, in distinct colors), lets the user draw/edit a polygon to
/// download or erase, and surfaces honest download progress. Reuses the
/// pan/zoom/`CachedTileProvider` base from `project_extent_picker_screen.dart`
/// and the draggable-handle drag technique (`camera.latLngToScreenOffset` /
/// `screenOffsetToLatLng`) from `map_screen.dart`'s measure tool.
class OfflineDataMapScreen extends ConsumerStatefulWidget {
  const OfflineDataMapScreen({super.key});

  @override
  ConsumerState<OfflineDataMapScreen> createState() => _OfflineDataMapScreenState();
}

/// The least map this screen may leave with nothing drawn over it — the same
/// floor the Main Map holds (`map_screen_space_budget_test.dart`, task
/// 11.110): about three 32pt marker heights, which is the least you can see a
/// feature in and enough around it to know where it is. On this screen it is
/// what you draw a download region on and what shows you the coverage you
/// already have.
///
/// **It is public so the test that asserts the floor and the layout that
/// reserves it are the same number**, and it is reserved as a real box in
/// [_OfflineDataMapScreenState.build] rather than checked after the fact.
/// Task 11.162.
const double kOfflineMapClearBandFloor = 96.0;

enum _Mode { view, add, erase }

/// What the area sheet (task 11.230) was closed with.
enum _AreaAction { rename, update, delete }

class _OfflineDataMapScreenState extends ConsumerState<OfflineDataMapScreen> {
  final _mapController = MapController();

  _Mode _mode = _Mode.view;
  List<ll.LatLng>? _polygon;
  int? _selectedVertex;

  bool _showTileCoverage = true;
  bool _showDemCoverage = true;
  bool _showLegend = true;

  double _cameraRotation = 0;
  // Task 11.103: seeded from `chooseMapCameraTarget` on the first build, and
  // never from a coordinate nobody supplied. The initialiser is only ever
  // read if that first build somehow does not happen; it is the whole-planet
  // framing, which claims nothing.
  ll.LatLng _cameraCenter = MapCameraTarget.worldViewCenter;
  double _cameraZoom = MapCameraTarget.worldViewZoom;

  /// True once a **supplied** source has placed the camera — a device fix or
  /// the project extent. Stays false for the whole-planet framing, so a fix
  /// or a project arriving later still gets to place the map.
  bool _cameraPlaced = false;

  /// True once the person has moved the map themselves. After that nothing
  /// places it for them: a camera that jumps out from under a finger is
  /// worse than one that opened somewhere unhelpful.
  bool _personMovedCamera = false;

  /// True between `onMapReady` and dispose — [MapController] cannot be moved
  /// before the map exists.
  bool _mapReady = false;

  /// A target decided before the map could accept it, applied on ready.
  MapCameraTarget? _pendingTarget;

  // Cached size estimate for the current polygon, recomputed whenever the
  // polygon or add-sheet zoom range changes.
  int _tileZoomMin = 12;
  int _tileZoomMax = 16;

  final Set<String> _dismissedJobIds = {};

  @override
  Widget build(BuildContext context) {
    final gps = ref.watch(gpsPositionProvider).value;
    // **Step 3 of the chain, wired here by task 11.120.** `currentProject` is
    // a `keepAlive` provider that runs once per app launch and is cached
    // afterwards, so this watch is a map lookup on every rebuild of this
    // screen — measured below. Task 11.103 reported that wiring it made this
    // file's suite 250x slower; that was measured, re-measured by 11.120 and
    // **is not this provider**. See `_placeCameraIfPossible`.
    final projectAsync = ref.watch(currentProjectProvider);
    final tileSourceAsync = ref.watch(selectedTileSourceProvider);
    final tileSource = tileSourceAsync.value ?? TileSources.openStreetMap;
    final regionsAsync = ref.watch(offlineRegionsProvider);
    final jobs = ref.watch(downloadManagerProvider);

    _placeCameraIfPossible(gps, projectAsync);

    final regions = regionsAsync.value ?? const [];
    final activeJobs = jobs.where((j) => !_dismissedJobIds.contains(j.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Data Map'),
        // Task 11.94/11.101 exemption: every icon-only control on this
        // screen and its map overlay (terrain auto-cache, legend, my
        // location, layers, north-reset, close) is labelled only by
        // `tooltip:`. Left as-is: each is a non-destructive, reversible
        // toggle or a conventional glyph (close, crosshair, layers stack),
        // none sits beside a destructive twin, and this AppBar has no room
        // for four text labels without pushing the title off — the same
        // trade task 11.99 made deliberately for its own overflow menu.
        actions: [
          IconButton(
            tooltip: 'Terrain auto-cache',
            icon: const Icon(Icons.sd_storage_outlined),
            onPressed: _showTerrainAutoCacheSheet,
          ),
          IconButton(
            tooltip: 'Toggle legend',
            icon: Icon(_showLegend ? Icons.info : Icons.info_outline),
            onPressed: () => setState(() => _showLegend = !_showLegend),
          ),
        ],
      ),
      body: Stack(
        // The subject of this screen's clear-band measurement (task 11.162),
        // the same instrument `map_screen_space_budget_test.dart` points at
        // the Main Map's `main-map`. Everything drawn over the map is a
        // child of this `Stack`, so its rectangle is the map you can see.
        key: const ValueKey('offline-data-map'),
        children: [
          DesktopTrackpadZoom(
            mapController: _mapController,
            child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _cameraCenter,
              initialZoom: _cameraZoom,
              interactionOptions: InteractionOptions(
                flags: mapInteractionFlags(),
                enableMultiFingerGestureRace: true,
                rotationThreshold: 30.0,
                pinchZoomThreshold: 0.5,
                pinchMoveThreshold: 40.0,
              ),
              // Task 11.230 — a downloaded area is tappable when nothing
              // is being drawn. See [_onMapTap] for the overlap rule.
              onTap: (_, point) => _onMapTap(point, regions),
              onMapReady: () {
                _mapReady = true;
                final pending = _pendingTarget;
                if (pending != null) {
                  _pendingTarget = null;
                  _applyTarget(pending);
                }
              },
              onMapEvent: (event) => setState(() {
                if (_movedByAPerson(event.source)) _personMovedCamera = true;
                _cameraRotation = event.camera.rotation;
                _cameraCenter = event.camera.center;
                _cameraZoom = event.camera.zoom;
              }),
            ),
            children: [
              TileLayer(
                urlTemplate: tileSource.urlTemplate,
                subdomains: tileSource.subdomains,
                maxZoom: tileSource.maxZoom.toDouble(),
                tileProvider: CachedTileProvider(source: tileSource),
              ),
              if (_showTileCoverage || _showDemCoverage)
                PolygonLayer(
                  polygons: [
                    for (final r in regions)
                      if ((r.kind == OfflineRegionKind.tiles && _showTileCoverage) ||
                          (r.kind == OfflineRegionKind.dem && _showDemCoverage))
                        _coveragePolygon(r, jobs),
                  ],
                ),
              // In-progress downloads have no manifest region yet (that's
              // written on completion), so draw their polygons directly from
              // the live job list in the "downloading" blue.
              PolygonLayer(
                polygons: [
                  for (final j in jobs)
                    if (!j.isTerminal && j.polygon.length >= 3)
                      Polygon(
                        points: j.polygon,
                        color: Colors.blue.withValues(alpha: 0.22),
                        borderColor: Colors.blue,
                        borderStrokeWidth: 1.5,
                      ),
                ],
              ),
              if (_polygon != null)
                PolygonLayer(
                  polygons: [
                    Polygon(
                      points: _polygon!,
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.18),
                      borderColor: Theme.of(context).colorScheme.primary,
                      borderStrokeWidth: 2,
                    ),
                  ],
                ),
            ],
            ),
          ),
          // Vertex/midpoint/delete handles live in the OUTER stack (not as
          // flutter_map Marker children) so their gesture detectors don't
          // compete with the map's own pan/scale recognizer — dragging a
          // handle moves the vertex instead of panning the map. Positions are
          // recomputed each build from the camera (build runs on every
          // onMapEvent, so they track pan/zoom).
          if (_polygon != null) ..._handleOverlay(),
          // **Task 11.162 — the map's floor is reserved in the layout, and
          // the download cards are what yields.**
          //
          // Every overlay on this screen used to be its own `Positioned`,
          // each correctly sized, and nothing anywhere added them up. With
          // three downloads running and the tiles-not-arriving band up — the
          // ordinary evening before a field trip, since queueing several
          // regions is what this screen is *for* and the band appears
          // exactly when the connection is poor — the map had **20 logical
          // pixels** with nothing drawn over it, at the default text size.
          // The floor is 96 (see [kOfflineMapClearBandFloor]).
          //
          // So the furniture now lives in one column with the floor in it as
          // a real box. Reading down: the top controls take their natural
          // height; [kOfflineMapClearBandFloor] pixels are reserved and
          // nothing may be laid out in them; and the bottom column gets
          // whatever is left. **The reserve is not a number this code checks
          // afterwards — it is a `SizedBox` the layout has to make room for**,
          // so the floor cannot be breached by adding a fourth thing, by a
          // fourth download, or at any text size.
          //
          // **What yields is the download cards, and the reason is that they
          // are the only furniture here that is unbounded in number.** The
          // band is one sentence; the readout is one panel; the cards are
          // however many regions a person queued. They scroll inside the
          // space that is left, so nothing is hidden and nothing is capped —
          // **three concurrent downloads is a thing somebody chose, and this
          // screen's job is to show them, not to prevent them.** The
          // rejected alternatives were collapsing the cards to a single
          // counted line (a new wording for a state that already has one,
          // and it takes away per-download progress and Cancel) and standing
          // the warning band down during a download (it is at its most
          // useful exactly then).
          //
          // **One behaviour changed:** a vertical drag that starts on the
          // card stack now scrolls the cards instead of panning the map. The
          // map still pans everywhere else — including the reserved band,
          // which is now guaranteed to exist.
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // `Flexible`, because the legend is the one thing up
                      // here that grows with the text size: laid out at its
                      // own width it pushes the buttons off the right edge
                      // from xxLarge (measured: 1.8px over at xxLarge, 416
                      // at AX5). It wraps instead. The `Spacer` in its place
                      // keeps the buttons on the right edge when the legend
                      // is switched off.
                      if (_showLegend)
                        const Flexible(
                          child: _CoverageLegend(
                            key: ValueKey('offline-coverage-legend'),
                          ),
                        )
                      else
                        const Spacer(),
                      Column(
                        key: const ValueKey('offline-map-buttons'),
                        children: [
                          _LayerToggleButton(
                            showTiles: _showTileCoverage,
                            showDem: _showDemCoverage,
                            onToggleTiles: () => setState(() => _showTileCoverage = !_showTileCoverage),
                            onToggleDem: () => setState(() => _showDemCoverage = !_showDemCoverage),
                          ),
                          const SizedBox(height: 8),
                          _RoundIconButton(
                            icon: Icons.my_location,
                            tooltip: 'Center on my location',
                            onPressed: () => _centerOnMyLocation(gps),
                          ),
                          const SizedBox(height: 8),
                          _NorthArrowButton(
                            rotationDeg: _cameraRotation,
                            onTap: () => _mapController.rotate(0),
                          ),
                        ],
                      ),
                    ],
                  ),
                  Expanded(
                    child: Padding(
                      // The floor, as a box. Everything below it is laid out
                      // in what remains.
                      padding: const EdgeInsets.only(
                        top: kOfflineMapClearBandFloor,
                      ),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: _bottomPanels(activeJobs),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: _buildBottomBar(context),
      ),
    );
  }

  /// **One bottom column, not a constant** (task 11.126 item B). The
  /// selection readout used to lift itself by a hard-coded `140` when any job
  /// was running — a number sized for exactly one card — while the cards
  /// stacked at `12 + i * 84`. Measured at phone geometry with two downloads
  /// running, the second card covered 32 logical pixels of the readout,
  /// including the line saying how many tiles the download will fetch. A
  /// third would have sat on it outright.
  ///
  /// Nothing here is a constant now: the readout and the cards are laid out
  /// in one column, so each is exactly as tall as it renders and the next one
  /// starts where it ends. Card 0 stays nearest the bottom, as before.
  ///
  /// **Task 11.135 put the tiles-not-arriving band at the top of this same
  /// column, and this is the screen that most needed it.** It is the one
  /// place in the app somebody downloads tiles *on purpose*, so a person
  /// watching a download return nothing is already asking the question the
  /// signal answers — and before this the screen's only answer was a count.
  /// The column is unconditional; when nothing is up it is a zero-height box
  /// on the bottom edge and costs the map nothing.
  ///
  /// The band speaks for the **live** basemap under the person's finger. What
  /// a *download* is doing is a different fact with a different scope, and it
  /// is reported on the job's own card — see [_JobProgressCard]. Deliberately
  /// not merged: a region download failing every tile while the visible map
  /// is fully cached is a real state, and one sentence covering both would
  /// have to lie about one of them.
  ///
  /// **Task 11.162 — this whole column is now laid out inside a box bounded
  /// by [kOfflineMapClearBandFloor], and it is one scroll region rather than
  /// a stack of fixed panels.** When the furniture fits, nothing changes: the
  /// list shrink-wraps to its content and sits on the bottom edge exactly
  /// where it always has, card 0 nearest the map's edge. When it does not
  /// fit, it scrolls instead of taking the map — and it is scrolled from the
  /// top, so the tiles-not-arriving band and the readout stay visible and the
  /// **oldest** card is the one below the fold.
  ///
  /// **Why one list rather than a pinned band above a scrolling stack**,
  /// which is what this was first written as: at AX4 and above the band alone
  /// is taller than the space left after the reserve, so a pinned band
  /// striped the screen by 25 and then 79 pixels. A `ListView` cannot
  /// overflow. **The floor holds at every text size and nothing is clipped
  /// at any of them** — see `offline_data_map_space_budget_test.dart`, which
  /// walks the whole iOS ladder.
  Widget _bottomPanels(List<DownloadJob> activeJobs) {
    return ListView(
      key: const ValueKey('offline-bottom-panels'),
      // Sizes to its content, so on the ordinary day this is the same fixed
      // column it has always been and scrolls nowhere.
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        // **Task 11.157 — declined, in writing, with the numbers.** Step 4 of
        // this screen's fallback chain (no fix, no project extent) reaches
        // the whole-planet framing with no sentence explaining it, while the
        // Main Map says so in words for the identical state
        // (`MapCameraTarget.nothingSuppliedMessage`). Reusing that exact
        // sentence here was measured before shipping and costs roughly 136
        // logical pixels of this column at the default text size, on a screen
        // that task 11.162 then found was already 76 pixels under its floor
        // with three downloads running. Not shipped; see `DEVELOPMENT_PLAN.md`
        // task 11.157. **Task 11.162's bound does not change that answer** —
        // the sentence would now push the cards down the scroll region rather
        // than take the map, but it is still a fourth thing on a column that
        // has no room, and a condensed wording is a new wording and a new
        // task's call.
        const TilesNotLoadingBand(
          bannerKey: ValueKey('offline-tiles-not-loading'),
          padding: EdgeInsets.only(bottom: 8),
        ),
        if (_polygon != null) ...[
          _SelectionReadout(
            key: const ValueKey('offline-selection-readout'),
            polygon: _polygon!,
            zoomMin: _tileZoomMin,
            zoomMax: _tileZoomMax,
          ),
          const SizedBox(height: 8),
        ],
        for (var i = activeJobs.length - 1; i >= 0; i--) ...[
          _JobProgressCard(
            key: ValueKey('offline-job-card-$i'),
            job: activeJobs[i],
            onCancel: () =>
                ref.read(downloadManagerProvider.notifier).cancel(activeJobs[i].id),
            onRetry: () =>
                ref.read(downloadManagerProvider.notifier).retry(activeJobs[i].id),
            onResume: () =>
                ref.read(downloadManagerProvider.notifier).resume(activeJobs[i].id),
            onDismiss: () =>
                setState(() => _dismissedJobIds.add(activeJobs[i].id)),
          ),
          if (i > 0) const SizedBox(height: 8),
        ],
      ],
    );
  }

  /// **Michael's fallback chain, steps 1, 3 and 4** — task 11.120.
  ///
  /// This screen had steps 1 and 4 only: a device fix, or the whole planet.
  /// With no fix, somebody who had drawn a project extent still had to pan
  /// from a world view to their study area before they could draw a download
  /// region — on the one screen whose whole purpose is downloading data for
  /// that study area.
  ///
  /// **Why step 2 (the most recent recordings) is deliberately not here.**
  /// The Main Map ranks recordings above the extent because it is showing
  /// somebody their data and "where you were working last" is the better
  /// answer. This screen is choosing an area to *cover*, and the project
  /// extent is that area by definition — it is the rectangle somebody drew to
  /// say "this is my study site". Reaching step 2 would also mean pulling
  /// four recording repositories into a screen that has never read one, for a
  /// worse answer. If that judgement is ever reversed, `chooseMapCameraTarget`
  /// already takes `recorded:` and the order is decided there, not here.
  ///
  /// **On the 250x slowdown task 11.103 attributed to this watch.** Measured
  /// again on 2026-09-04 and the attribution was wrong. With the watch in and
  /// the current `estimateTileCount`, this file's suite runs in **1 second**,
  /// the same as without it. With the watch *removed* and 11.103's *old*
  /// `estimateTileCount` restored, one test takes **4 minutes 18 seconds**.
  /// The cost was always the tile counter building the whole tile list to
  /// measure its length at whole-planet zoom — the defect 11.103 found and
  /// fixed in the same commit — and not this provider, which is `keepAlive`
  /// and answers from cache.
  void _placeCameraIfPossible(Position? gps, AsyncValue<Project?> projectAsync) {
    if (_cameraPlaced || _personMovedCamera) return;
    // Nothing to decide from yet: a fix may still arrive, and the project is
    // still loading. Leave the whole-planet framing up — it is pannable and
    // tappable, which is what somebody with no fix needs.
    if (gps == null && projectAsync.isLoading) return;

    final project = projectAsync.value;
    final target = chooseMapCameraTarget(
      devicePosition:
          gps == null ? null : ll.LatLng(gps.latitude, gps.longitude),
      projectExtent: project == null
          ? null
          : GeoExtent.fromProjectBbox(
              minLat: project.bboxMinLat,
              minLon: project.bboxMinLon,
              maxLat: project.bboxMaxLat,
              maxLon: project.bboxMaxLon,
            ),
    );
    // Step 4 places nothing. `_cameraPlaced` stays false so that a fix
    // arriving a moment later, or a project that resolves after this build,
    // still gets to place the map.
    if (!target.isSupplied) return;

    _cameraPlaced = true;
    _cameraCenter = target.center!;
    _cameraZoom = target.zoom;
    if (_mapReady) {
      // Not during a build: `fitCamera`/`move` write to the controller.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _applyTarget(target);
      });
    } else {
      // First build. `initialCenter`/`initialZoom` below already read the
      // fields just set, so there is no flash; this is what fits an extent
      // once the map knows how big it is.
      _pendingTarget = target;
    }
  }

  /// Puts [target] on the map: a rectangle is fitted, a point is moved to.
  void _applyTarget(MapCameraTarget target) {
    final extent = target.extent;
    if (extent == null) {
      _mapController.move(target.center!, target.zoom);
      return;
    }
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds(
          ll.LatLng(extent.minLat, extent.minLon),
          ll.LatLng(extent.maxLat, extent.maxLon),
        ),
        padding: const EdgeInsets.all(24),
      ),
    );
  }

  /// Whether a map event came from the person rather than from this screen.
  /// `fitCamera`/`move` above both report themselves, and so does a window
  /// resize; treating either as a pan would freeze the camera at whatever the
  /// first placement chose.
  static bool _movedByAPerson(MapEventSource source) => switch (source) {
        MapEventSource.mapController ||
        MapEventSource.fitCamera ||
        MapEventSource.nonRotatedSizeChange ||
        MapEventSource.interactiveFlagsChanged ||
        MapEventSource.custom =>
          false,
        _ => true,
      };

  Widget _buildBottomBar(BuildContext context) {
    if (_polygon == null) {
      return SizedBox(
        height: 48,
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _startNewSelection,
          icon: const Icon(Icons.crop_free),
          label: const Text('New selection'),
        ),
      );
    }
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: () => setState(() {
              _polygon = null;
              _selectedVertex = null;
            }),
            child: const Text('Cancel'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: SegmentedButton<_Mode>(
            segments: const [
              ButtonSegment(value: _Mode.add, label: Text('Add'), icon: Icon(Icons.add)),
              ButtonSegment(value: _Mode.erase, label: Text('Erase'), icon: Icon(Icons.delete_outline)),
            ],
            selected: {_mode == _Mode.erase ? _Mode.erase : _Mode.add},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton(
            onPressed: _mode == _Mode.erase ? _eraseSelection : _openAddSheet,
            child: Text(_mode == _Mode.erase ? 'Delete data' : 'Download'),
          ),
        ),
      ],
    );
  }

  // --- Selection tool ---------------------------------------------------

  void _startNewSelection() {
    ll.LatLng center = _cameraCenter;
    var halfLatSpan = 0.02;
    var halfLonSpan = 0.02;
    try {
      final camera = _mapController.camera;
      center = camera.center;
      final bounds = camera.visibleBounds;
      // ~60% of the current viewport, centered.
      halfLatSpan = (bounds.north - bounds.south) * 0.3;
      halfLonSpan = (bounds.east - bounds.west) * 0.3;
    } catch (_) {
      // MapController.camera throws until FlutterMap has completed its
      // first layout; fall back to the pre-seeded values above.
    }
    setState(() {
      _mode = _Mode.add;
      _polygon = [
        ll.LatLng(center.latitude + halfLatSpan, center.longitude - halfLonSpan),
        ll.LatLng(center.latitude + halfLatSpan, center.longitude + halfLonSpan),
        ll.LatLng(center.latitude - halfLatSpan, center.longitude + halfLonSpan),
        ll.LatLng(center.latitude - halfLatSpan, center.longitude - halfLonSpan),
      ];
      _selectedVertex = null;
    });
  }

  List<Widget> _handleOverlay() {
    final polygon = _polygon!;
    MapCamera camera;
    try {
      camera = _mapController.camera;
    } catch (_) {
      // Camera not available until the map's first layout; this build will
      // be followed by an onMapEvent that rebuilds with a valid camera.
      return const [];
    }

    final widgets = <Widget>[];

    // Midpoint handles first (drawn under vertices): dragging one inserts a
    // new vertex at that edge, converting the rectangle into a polygon.
    for (var i = 0; i < polygon.length; i++) {
      final mid = _midpoint(polygon[i], polygon[(i + 1) % polygon.length]);
      final off = camera.latLngToScreenOffset(mid);
      widgets.add(Positioned(
        left: off.dx - 16,
        top: off.dy - 16,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => _insertVertexAtMidpoint(i),
          child: const _MidpointHandle(),
        ),
      ));
    }

    // Vertex handles: tap to select/deselect, drag to move.
    for (var i = 0; i < polygon.length; i++) {
      final off = camera.latLngToScreenOffset(polygon[i]);
      widgets.add(Positioned(
        left: off.dx - 22,
        top: off.dy - 22,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _selectedVertex = _selectedVertex == i ? null : i),
          onPanUpdate: (d) => _dragVertex(i, d.delta),
          child: _VertexHandle(selected: _selectedVertex == i),
        ),
      ));
    }

    // Delete affordance for the selected vertex (only when removing it still
    // leaves a valid ≥3-point polygon).
    final sel = _selectedVertex;
    if (sel != null && sel < polygon.length && polygon.length > 3) {
      final off = camera.latLngToScreenOffset(polygon[sel]);
      widgets.add(Positioned(
        left: off.dx - 14,
        top: off.dy - 22 - 28,
        child: _DeleteVertexButton(onTap: _deleteSelectedVertex),
      ));
    }

    return widgets;
  }

  ll.LatLng _midpoint(ll.LatLng a, ll.LatLng b) =>
      ll.LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);

  void _dragVertex(int index, Offset delta) {
    final camera = _mapController.camera;
    final current = camera.latLngToScreenOffset(_polygon![index]);
    final updated = camera.screenOffsetToLatLng(current + delta);
    setState(() => _polygon![index] = updated);
  }

  /// A drag on a midpoint handle inserts a new vertex there, turning it into
  /// a permanent vertex the user then drags directly.
  void _insertVertexAtMidpoint(int afterIndex) {
    setState(() {
      final mid = _midpoint(_polygon![afterIndex], _polygon![(afterIndex + 1) % _polygon!.length]);
      _polygon!.insert(afterIndex + 1, mid);
      _selectedVertex = null;
    });
  }

  void _deleteSelectedVertex() {
    final index = _selectedVertex;
    if (index == null) return;
    if (_polygon!.length <= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A selection needs at least 3 points.')),
      );
      return;
    }
    setState(() {
      _polygon!.removeAt(index);
      _selectedVertex = null;
    });
  }

  void _centerOnMyLocation(Position? gps) {
    if (gps == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Waiting for a GPS fix…')),
      );
      return;
    }
    _mapController.move(ll.LatLng(gps.latitude, gps.longitude), _cameraZoom);
  }

  // --- Coverage overlay ---------------------------------------------------

  Polygon _coveragePolygon(OfflineRegion region, List<DownloadJob> jobs) {
    final isDem = region.kind == OfflineRegionKind.dem;
    // Tint by base kind, shaded by status; a region whose id matches a
    // currently-running job shows the live "downloading" color regardless of
    // its (possibly stale) manifest status.
    final runningJob = jobs.where((j) => j.id == region.id && !j.isTerminal).firstOrNull;
    final Color fill;
    final Color border;
    if (runningJob != null) {
      fill = Colors.blue.withValues(alpha: 0.25);
      border = Colors.blue;
    } else if (region.status == OfflineRegionStatus.partial) {
      fill = Colors.amber.withValues(alpha: 0.25);
      border = Colors.amber.shade800;
    } else {
      fill = (isDem ? Colors.green : Colors.purple).withValues(alpha: 0.22);
      border = isDem ? Colors.green.shade700 : Colors.purple.shade700;
    }
    return Polygon(points: region.polygon, color: fill, borderColor: border, borderStrokeWidth: 1.5);
  }

  // --- Add / download ------------------------------------------------------

  Future<void> _openAddSheet() async {
    if (_polygon == null) return;
    final keepOpen = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Keep TriTrack open'),
        content: const Text(
          'Downloads pause if you leave the app. Keep it open in the '
          'foreground until the download finishes.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Continue')),
        ],
      ),
    );
    if (keepOpen != true || !mounted) return;
    await _showAddSheet();
  }

  /// The name offered for a new area: the lowest "Area N" nobody has used,
  /// counting areas already saved and downloads still running. A person in
  /// a hurry accepts it; the row it makes is still telling two areas apart.
  String _defaultAreaName() {
    final taken = <String>{
      for (final r in ref.read(offlineRegionsProvider).value ?? const [])
        if (r.name != null) r.name!,
      for (final j in ref.read(downloadManagerProvider))
        if (j.name != null) j.name!,
    };
    for (var n = 1;; n++) {
      final candidate = 'Area $n';
      if (!taken.contains(candidate)) return candidate;
    }
  }

  Future<void> _showAddSheet() async {
    var wantTiles = true;
    var wantDem = true;
    var source = TileSources.openStreetMap;
    var minZoom = _tileZoomMin;
    var maxZoom = _tileZoomMax;
    // Task 11.230 — every area gets a name. Pre-filled so accepting the
    // default is one tap, and selected so typing replaces it.
    var name = _defaultAreaName();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final polygon = _polygon!;
          final zoomLevels = [for (var z = minZoom; z <= maxZoom; z++) z];
          // **Task 11.230 found task 11.103's fix had missed this line.** It
          // called `GeoPolygon.tilesInPolygon(...).length` — building every
          // tile in the selection at every zoom to count them — and 11.103's
          // note that "the only caller of the list form is the downloader,
          // which is bounded by a polygon a person has confirmed" was wrong
          // in both halves: this sheet is a second caller, and it opens
          // *before* anything is confirmed. At the whole-planet framing a
          // "New selection" box is a third of the Earth, and this line asked
          // for two gigabytes on the UI thread (measured: the widget test
          // that first opened this sheet died of OutOfMemory). The estimate
          // is over the bounding box, as the readout's already is; for a
          // rectangle it is exact and for any other shape it errs high,
          // which is the direction a "≈" may err before a download.
          final bb = GeoPolygon.boundingBox(polygon);
          final tileEstimate = OfflineTileDownloader.estimateTileCount(
            minLat: bb.minLat,
            minLon: bb.minLon,
            maxLat: bb.maxLat,
            maxLon: bb.maxLon,
            zoomLevels: zoomLevels,
          );
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Download this area', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                OwnedTextField(
                  key: const ValueKey('offline-area-name'),
                  initial: name,
                  onChanged: (v) => name = v,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: wantTiles,
                  title: const Text('Map tiles'),
                  onChanged: (v) => setSheetState(() => wantTiles = v ?? false),
                ),
                if (wantTiles) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: DropdownButton<TileSource>(
                      value: source,
                      isExpanded: true,
                      items: [
                        for (final s in TileSources.all) DropdownMenuItem(value: s, child: Text(s.name)),
                      ],
                      onChanged: (s) => setSheetState(() => source = s ?? source),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              const Text('Min zoom'),
                              Slider(
                                value: minZoom.toDouble(),
                                min: 1,
                                max: maxZoom.toDouble(),
                                divisions: maxZoom.clamp(1, 100),
                                label: '$minZoom',
                                onChanged: (v) => setSheetState(() => minZoom = v.round()),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: Column(
                            children: [
                              const Text('Max zoom'),
                              Slider(
                                value: maxZoom.toDouble(),
                                min: minZoom.toDouble(),
                                max: 19,
                                divisions: (19 - minZoom).clamp(1, 100),
                                label: '$maxZoom',
                                onChanged: (v) => setSheetState(() => maxZoom = v.round()),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Text('≈ $tileEstimate tiles'),
                  ),
                ],
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: wantDem,
                  title: const Text('Elevation'),
                  onChanged: (v) => setSheetState(() => wantDem = v ?? false),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    key: const ValueKey('offline-download-confirm'),
                    onPressed: (wantTiles || wantDem)
                        ? () {
                            _tileZoomMin = minZoom;
                            _tileZoomMax = maxZoom;
                            final typed = name.trim();
                            Navigator.of(context).pop();
                            _startDownload(
                              polygon: polygon,
                              wantTiles: wantTiles,
                              wantDem: wantDem,
                              source: source,
                              minZoom: minZoom,
                              maxZoom: maxZoom,
                              // A blanked field falls back to the default
                              // rather than to no name: an unnamed area is
                              // the thing this task exists to stop making.
                              name: typed.isEmpty ? _defaultAreaName() : typed,
                            );
                          }
                        : null,
                    child: const Text('Download'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _startDownload({
    required List<ll.LatLng> polygon,
    required bool wantTiles,
    required bool wantDem,
    required TileSource source,
    required int minZoom,
    required int maxZoom,
    required String name,
  }) {
    final manager = ref.read(downloadManagerProvider.notifier);
    if (wantTiles) {
      manager.enqueueTiles(
        polygon: polygon,
        sourceId: source.id,
        minZoom: minZoom,
        maxZoom: maxZoom,
        name: name,
      );
    }
    if (wantDem) {
      manager.enqueueDem(polygon: polygon, name: name);
    }
    setState(() {
      _polygon = null;
      _selectedVertex = null;
      _mode = _Mode.view;
    });
  }

  // --- Erase ---------------------------------------------------------------

  /// **Task 11.231 — Erase now subtracts saved areas, the same rule
  /// `OfflineRegionStore.deleteRegion` uses for the per-area delete.**
  ///
  /// Before this, Erase deleted every tile and DEM square under the drawn
  /// shape with no check for a saved area, so drawing a shape that happened
  /// to cross one silently made that area Partial — the exact defect task
  /// 11.230 fixed for the per-area delete, one screen over. The planning
  /// session's decision (recorded in `DEVELOPMENT_PLAN.md` task 11.231):
  /// erasing too much costs a field download that needs a connection nobody
  /// has in the field; erasing too little costs disk space and is undone
  /// offline in two taps. Prefer the recoverable side.
  ///
  /// **Pan-cache tiles — the ones no area claims — are still erased.** That
  /// is this tool's real use beyond the per-area delete: a tile fetched by
  /// panning the map belongs to no manifest entry, so nothing protects it
  /// and nothing needs to.
  ///
  /// **What was kept is reported, not folded silently into a smaller
  /// number.** A tool that quietly frees less than the person expected is
  /// the same defect as one that quietly deletes too much — both leave a
  /// wrong belief. The areas actually named are the ones that still cover at
  /// least one tile the drawn shape reached, using `areaNamesPhrase` so the
  /// wording matches the per-area delete's "shared with" line.
  Future<void> _eraseSelection() async {
    final polygon = _polygon;
    if (polygon == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete data in this area?'),
        content: const Text(
          'Removes downloaded map tiles and elevation data inside this '
          'selection, except what a saved area still needs. You can download '
          'it again later.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final regions = ref.read(offlineRegionsProvider).value ?? const [];
    final result = await OfflineRegionStore().eraseInPolygon(
      polygon: polygon,
      tileSources: [
        for (final s in TileSources.all) (sourceId: s.id, maxZoom: s.maxZoom),
      ],
      tileCounter: const TileCacheCounter(),
      demStore: DemTileStore(),
    );

    ref.invalidate(offlineRegionsProvider);
    if (!mounted) return;
    setState(() {
      _polygon = null;
      _selectedVertex = null;
      _mode = _Mode.view;
    });

    final freedSentence = 'Freed ${result.tilesDeleted} tile(s) and '
        '${result.demDeleted} DEM tile(s).';
    final message = result.totalKept > 0
        ? '$freedSentence Kept ${result.totalKept} that '
            '${areaNamesPhrase(result.keptForIds, regions)} still cover.'
        : freedSentence;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // --- Managing an area from the map (task 11.230) -------------------------

  /// A tap on the map, with nothing being drawn, opens the area under it.
  ///
  /// **When the tap lands inside more than one area, a chooser lists them
  /// and the person picks.** The alternatives were the smallest area (a
  /// silent guess — and the overlap is exactly where a tap is least likely to
  /// mean one area rather than the other) and the topmost (whichever the
  /// manifest happens to list last, which nobody chose). A chooser costs one
  /// extra tap only where areas overlap, and it is the one option under
  /// which the name of the area about to be deleted is on screen before
  /// anything is committed. Areas hidden by the layer toggles are not
  /// candidates: a tap cannot mean something the person cannot see.
  Future<void> _onMapTap(ll.LatLng point, List<OfflineRegion> regions) async {
    if (_polygon != null) return;
    final hits = [
      for (final r in regions)
        if (((r.kind == OfflineRegionKind.tiles && _showTileCoverage) ||
                (r.kind == OfflineRegionKind.dem && _showDemCoverage)) &&
            GeoPolygon.pointInPolygon(point, r.polygon))
          r,
    ];
    if (hits.isEmpty) return;
    OfflineRegion? chosen = hits.length == 1 ? hits.single : null;
    chosen ??= await showModalBottomSheet<OfflineRegion>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          key: const ValueKey('offline-area-chooser'),
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Which area?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final r in hits)
              ListTile(
                leading: Icon(_kindIcon(r)),
                title: Text(r.displayName),
                subtitle: Text(_areaSummary(r)),
                onTap: () => Navigator.of(context).pop(r),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _showAreaSheet(chosen, regions);
  }

  IconData _kindIcon(OfflineRegion r) => r.kind == OfflineRegionKind.dem
      ? Icons.terrain_outlined
      : Icons.map_outlined;

  String _areaSummary(OfflineRegion r) {
    final kind = r.kind == OfflineRegionKind.dem ? 'Elevation' : 'Map tiles';
    final status = switch (r.status) {
      OfflineRegionStatus.complete => 'Complete',
      OfflineRegionStatus.partial => 'Partial',
      OfflineRegionStatus.downloading => 'Downloading',
      OfflineRegionStatus.failed => 'Failed',
    };
    return '$kind · $status · ${r.tileCompleted}/${r.tileTotal} · '
        '${formatBytes(r.exclusiveBytes)}';
  }

  /// The small sheet for one area: what it is, and Rename / Update / Delete.
  /// Rename and Delete are the same dialogs the "Offline Data" list uses
  /// (`offline_region_actions.dart`), so the two screens say the same thing.
  Future<void> _showAreaSheet(
    OfflineRegion region,
    List<OfflineRegion> all,
  ) async {
    final action = await showModalBottomSheet<_AreaAction>(
      context: context,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            key: const ValueKey('offline-area-sheet'),
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_kindIcon(region)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      region.displayName,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(_areaSummary(region)),
              if (region.sharedBytes > 0)
                Text(
                  '${formatBytes(region.sharedBytes)} shared with '
                  '${sharedWithPhrase(region, all)}',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              if (!regionHasKnownSource(region))
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    deadSourceSentence,
                    key: const ValueKey('offline-area-dead-source'),
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pop(_AreaAction.rename),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Rename'),
                  ),
                  OutlinedButton.icon(
                    onPressed: regionHasKnownSource(region)
                        ? () => Navigator.of(context).pop(_AreaAction.update)
                        : null,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('Update'),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: () =>
                        Navigator.of(context).pop(_AreaAction.delete),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _AreaAction.rename:
        await renameRegionDialog(context, ref, region);
      case _AreaAction.update:
        // Adds files, removes none — see `updateRegion`. The job runs under
        // the area's own id, so a card dismissed for that id earlier in this
        // visit has to be un-dismissed or the new download would be
        // invisible.
        final started = updateRegion(ref, region);
        if (!mounted) return;
        if (started) setState(() => _dismissedJobIds.remove(region.id));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              started
                  ? 'Updating "${region.displayName}" — fetches whatever is '
                      'missing and deletes nothing.'
                  : '"${region.displayName}" is already downloading.',
            ),
          ),
        );
      case _AreaAction.delete:
        await confirmAndDeleteRegion(context, ref, region, all);
    }
  }

  // --- Terrain auto-cache ---------------------------------------------------

  Future<void> _showTerrainAutoCacheSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _TerrainAutoCacheSheet(),
    );
  }
}

// --- Small widgets -----------------------------------------------------

/// Pure visual for a polygon corner — the tap/drag gestures are handled by
/// the surrounding `GestureDetector` in the outer-stack overlay. The 44×44
/// box gives a generous touch target around the 18px dot.
class _VertexHandle extends StatelessWidget {
  const _VertexHandle({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: selected ? Colors.orange : Theme.of(context).colorScheme.primary,
            border: Border.all(color: Colors.white, width: 2),
          ),
        ),
      ),
    );
  }
}

/// Pure visual for an edge midpoint — the drag-to-insert gesture is handled
/// by the surrounding `GestureDetector` in the overlay.
class _MidpointHandle extends StatelessWidget {
  const _MidpointHandle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: Center(
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
          ),
        ),
      ),
    );
  }
}

class _DeleteVertexButton extends StatelessWidget {
  const _DeleteVertexButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.red),
        child: const Icon(Icons.close, size: 18, color: Colors.white),
      ),
    );
  }
}

class _SelectionReadout extends StatelessWidget {
  const _SelectionReadout({
    super.key,
    required this.polygon,
    required this.zoomMin,
    required this.zoomMax,
  });
  final List<ll.LatLng> polygon;
  final int zoomMin;
  final int zoomMax;

  @override
  Widget build(BuildContext context) {
    final areaSqM = GeoPolygon.polygonAreaSqMeters(polygon);
    final zoomLevels = [for (var z = zoomMin; z <= zoomMax; z++) z];
    final tileCount = OfflineTileDownloader.estimateTileCount(
      minLat: GeoPolygon.boundingBox(polygon).minLat,
      minLon: GeoPolygon.boundingBox(polygon).minLon,
      maxLat: GeoPolygon.boundingBox(polygon).maxLat,
      maxLon: GeoPolygon.boundingBox(polygon).maxLon,
      zoomLevels: zoomLevels,
    );
    // Rough size estimate: ~15KB average tile.
    final estimatedBytes = tileCount * 15 * 1024;
    final demTiles = DemTileStore().tilesIntersectingPolygon(polygon).length;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${(areaSqM / 1e6).toStringAsFixed(2)} km²'),
            Text('≈ $tileCount tiles (${formatBytes(estimatedBytes)}) at zoom $zoomMin–$zoomMax'),
            Text('≈ $demTiles DEM tiles'),
          ],
        ),
      ),
    );
  }
}


class _CoverageLegend extends StatelessWidget {
  const _CoverageLegend({super.key});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _row(Colors.purple, 'Tiles — complete'),
            _row(Colors.green, 'Elevation — complete'),
            _row(Colors.amber, 'Partial coverage'),
            _row(Colors.blue, 'Downloading'),
          ],
        ),
      ),
    );
  }

  Widget _row(Color color, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(width: 12, height: 12, color: color),
            const SizedBox(width: 6),
            // **One line, and the rest ellipsised** (task 11.149). The
            // legend sits in a `Flexible` (task 11.162) so it cannot push
            // the map buttons off the right edge, which means it can be
            // narrower than its labels want: from xxLarge these rows
            // overflowed by 1.8 pixels and by 416 at AX5.
            //
            // Wrapping fixed the stripe on the *row* and moved it to the
            // screen. Measured at AX5 on a 6.1-inch phone with three
            // downloads running: **this legend was 632 logical pixels tall
            // against a 555-pixel map area**, so it covered the map outright,
            // cut the clear band to 12 pixels against a floor of 96, and
            // overflowed the column by 101 — the yellow-and-black stripe,
            // which reads as a crash to somebody who has never seen one.
            //
            // **This is rule 1 of the shedding decision applied to a
            // screen's own furniture** (see `BudgetedColumn`, which is where
            // that rule lives now that the app shell's banners are gone): a
            // piece of furniture shows what fits and *marks* what does not,
            // rather than growing until it covers the thing it annotates. A
            // legend row is a swatch and a short phrase; a legend row that wraps to
            // three lines has become a paragraph on top of a map.
            //
            // **What a person loses:** at the largest accessibility sizes
            // the labels read "Tiles — c…" rather than "Tiles — complete".
            // The colour swatch beside each one is the part that does the
            // work, and it is untouched. **What they gain** is the map: the
            // 96-pixel clear band now holds at every text size on the
            // ladder, and nothing stripes. Nobody has looked at this on a
            // device — in `flutter_test`'s font, about twice Roboto's width,
            // truncation starts around AX1; on a phone it will start
            // considerably higher.
            Flexible(
              child: Text(
                label,
                style: const TextStyle(fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
}

class _JobProgressCard extends StatelessWidget {
  const _JobProgressCard({
    super.key,
    required this.job,
    required this.onCancel,
    required this.onRetry,
    required this.onResume,
    required this.onDismiss,
  });

  final DownloadJob job;
  final VoidCallback onCancel;
  final VoidCallback onRetry;
  final VoidCallback onResume;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final kind = job.kind == DownloadJobKind.tiles ? 'Map tiles' : 'Elevation';
    // Task 11.230: the area's name, when it has one, so two downloads on the
    // stack can be told apart. The card text wraps inside its column.
    final kindLabel = job.name == null ? kind : '$kind · ${job.name}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _content(context, kindLabel),
                  // **Task 11.135 — why a download is failing, on the card
                  // that is already there.**
                  //
                  // Before this the card said `(3 failed)` and stopped. A
                  // count is what happened; it is not what to do, and it is
                  // not even clear that it *is* a network fact rather than
                  // something wrong with the region drawn. This line is a
                  // line inside a panel that already exists, so it costs the
                  // map nothing (the card grows by one wrapped sentence, and
                  // only while a download has actually lost tiles), and it is
                  // one tap from the same explanation the map band opens.
                  //
                  // **It names no cause**, for the same reason the band does
                  // not: the downloader knows one fact — some requests came
                  // back with nothing usable — and a refusal, a rate limit, a
                  // dead radio and a provider outage are indistinguishable
                  // from here. It says what a retry will and will not do,
                  // which is the part a person can act on.
                  if (job.failed > 0) ...[
                    const SizedBox(height: 4),
                    _FailedTilesNote(
                      key: const ValueKey('offline-job-failed-note'),
                      failed: job.failed,
                    ),
                  ],
                ],
              ),
            ),
            ..._actions(context),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, String kindLabel) {
    switch (job.status) {
      case DownloadJobStatus.queued:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$kindLabel: queued…'),
            const SizedBox(height: 4),
            const LinearProgressIndicator(),
          ],
        );
      case DownloadJobStatus.running:
        // Indeterminate only until we know the tile count; once we do, the
        // bar is determinate so the user sees real movement.
        final value = job.total == 0 ? null : job.done / job.total;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$kindLabel: downloading ${job.done} / ${job.total == 0 ? '…' : job.total}'),
            const SizedBox(height: 4),
            LinearProgressIndicator(value: value),
          ],
        );
      case DownloadJobStatus.paused:
        return Text('$kindLabel: paused — ${job.done}/${job.total} done');
      case DownloadJobStatus.complete:
        // **"Completed" and "some tiles never arrived" are two facts, and
        // this used to print only one of them** — the parenthesised count
        // replaced the done/total rather than joining it, so a run that
        // fetched 4000 of 4003 tiles said "(3 failed)" and nothing about the
        // 4000. Both now, with the why on the line below.
        return Text(
          job.failed > 0
              ? '$kindLabel: Completed ✓ '
                  '(${job.done - job.failed}/${job.total}, '
                  '${job.failed} did not arrive)'
              : '$kindLabel: Completed ✓ (${job.done}/${job.total})',
        );
      case DownloadJobStatus.failed:
        return Text('$kindLabel: Failed — ${job.error ?? 'unknown error'}');
      case DownloadJobStatus.cancelled:
        return Text('$kindLabel: Canceled (${job.done}/${job.total} done)');
    }
  }

  List<Widget> _actions(BuildContext context) {
    switch (job.status) {
      case DownloadJobStatus.queued:
      case DownloadJobStatus.running:
        return [TextButton(onPressed: onCancel, child: const Text('Cancel'))];
      case DownloadJobStatus.paused:
        return [TextButton(onPressed: onResume, child: const Text('Resume'))];
      case DownloadJobStatus.failed:
        return [
          TextButton(onPressed: onRetry, child: const Text('Retry')),
          IconButton(onPressed: onDismiss, icon: const Icon(Icons.close)),
        ];
      case DownloadJobStatus.complete:
      case DownloadJobStatus.cancelled:
        return [
          if (job.status == DownloadJobStatus.complete && job.failed > 0)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          IconButton(onPressed: onDismiss, icon: const Icon(Icons.close), tooltip: 'Done'),
        ];
    }
  }
}

/// The line under a download that lost tiles: how many, what a retry does,
/// and one tap to the same honest explanation the map band opens.
///
/// **Task 11.135.** Sized by its text rather than by a constant, and present
/// only while `failed > 0`, so a download that goes cleanly pays nothing for
/// it. Tapping opens [showTilesNotLoadingSheet] — the same words the Main Map
/// and this screen's own band lead to, because it is the same question.
class _FailedTilesNote extends StatelessWidget {
  const _FailedTilesNote({super.key, required this.failed});

  final int failed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => showTilesNotLoadingSheet(context),
      borderRadius: BorderRadius.circular(6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_off_outlined, size: 14, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${TileFetchHealth.notArrivedCount(failed)} '
              '${TileFetchHealth.retryFetchesOnlyWhatIsMissing}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.info_outline, size: 14, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _LayerToggleButton extends StatelessWidget {
  const _LayerToggleButton({
    required this.showTiles,
    required this.showDem,
    required this.onToggleTiles,
    required this.onToggleDem,
  });

  final bool showTiles;
  final bool showDem;
  final VoidCallback onToggleTiles;
  final VoidCallback onToggleDem;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: PopupMenuButton<void>(
        tooltip: 'Layers',
        icon: const Icon(Icons.layers_outlined),
        itemBuilder: (context) => [
          CheckedPopupMenuItem<void>(
            checked: showTiles,
            onTap: onToggleTiles,
            child: const Text('Tile coverage'),
          ),
          CheckedPopupMenuItem<void>(
            checked: showDem,
            onTap: onToggleDem,
            child: const Text('Elevation coverage'),
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
      ),
      child: IconButton(tooltip: tooltip, icon: Icon(icon), onPressed: onPressed),
    );
  }
}

class _NorthArrowButton extends StatelessWidget {
  const _NorthArrowButton({required this.rotationDeg, required this.onTap});
  final double rotationDeg;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _RoundIconButton(icon: Icons.explore_outlined, tooltip: 'Reset north', onPressed: onTap);
  }
}

/// Bottom sheet for the viewshed tool's auto-downloaded DEM terrain cache —
/// distinct from the permanent terrain backing a saved offline DEM region
/// (which is protected and never counted or evicted here). Shows the current
/// on-disk size against the user's configured limit and lets them change the
/// limit or clear the cache outright.
class _TerrainAutoCacheSheet extends ConsumerStatefulWidget {
  const _TerrainAutoCacheSheet();

  @override
  ConsumerState<_TerrainAutoCacheSheet> createState() => _TerrainAutoCacheSheetState();
}

class _TerrainAutoCacheSheetState extends ConsumerState<_TerrainAutoCacheSheet> {
  // Held in State (never built inline in a FutureBuilder.future) so it's only
  // recomputed when we explicitly ask it to be, via _refresh().
  late Future<int> _sizeFuture;

  @override
  void initState() {
    super.initState();
    _sizeFuture = _computeUnprotectedBytes();
  }

  void _refresh() {
    setState(() => _sizeFuture = _computeUnprotectedBytes());
  }

  Future<Set<DemTileId>> _protectedIds() async {
    final regions = ref.read(offlineRegionsProvider).value ?? const [];
    final store = DemTileStore();
    final protected = <DemTileId>{};
    for (final r in regions) {
      if (r.kind == OfflineRegionKind.dem) {
        protected.addAll(store.tilesIntersectingPolygon(r.polygon));
      }
    }
    return protected;
  }

  Future<int> _computeUnprotectedBytes() async {
    final protected = await _protectedIds();
    return DemTileStore().unprotectedSizeBytes(protected);
  }

  Future<void> _changeLimit(int currentLimitMb) async {
    var value = currentLimitMb.toDouble().clamp(
          TerrainCacheLimit.minLimitMb.toDouble(),
          2000.0,
        );
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Auto-cache size limit'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${value.round()} MB'),
              Slider(
                value: value,
                min: TerrainCacheLimit.minLimitMb.toDouble(),
                max: 2000,
                divisions: (2000 - TerrainCacheLimit.minLimitMb) ~/ 25,
                label: '${value.round()} MB',
                onChanged: (v) => setDialogState(() => value = v),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(value.round()),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await ref.read(terrainCacheLimitProvider.notifier).set(result);
    if (!mounted) return;
    _refresh();
  }

  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear auto-cached terrain?'),
        content: const Text(
          'Removes elevation data that was fetched automatically for the '
          'viewshed tool. Terrain saved in your offline regions is not affected.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Clear')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final protected = await _protectedIds();
    final evicted = await DemTileStore().enforceCacheLimit(maxBytes: 0, protectedIds: protected);
    if (!mounted) return;
    _refresh();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cleared $evicted terrain tile(s).')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final limitAsync = ref.watch(terrainCacheLimitProvider);
    final limitMb = limitAsync.value ?? TerrainCacheLimit.defaultLimitMb;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Terrain auto-cache', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Elevation fetched automatically for the viewshed tool. Terrain inside '
            'your saved offline regions is never counted or deleted here.',
          ),
          const SizedBox(height: 12),
          FutureBuilder<int>(
            future: _sizeFuture,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              final text = bytes == null
                  ? 'Calculating…'
                  : '${formatBytes(bytes)} of $limitMb MB used';
              return Text(text, style: Theme.of(context).textTheme.bodyMedium);
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _changeLimit(limitMb),
                  child: const Text('Change limit'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _clearCache,
                  child: const Text('Clear cache'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

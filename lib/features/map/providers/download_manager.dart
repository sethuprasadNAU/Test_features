import 'dart:collection';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/errors/failure_message.dart';
import '../../../viewshed/dem_tile_fetcher.dart';
import '../../../viewshed/dem_tile_store.dart';
import '../models/offline_region.dart';
import '../services/geo_polygon.dart' show GeoPolygon;
import '../services/offline_region_store.dart';
import '../services/offline_tile_downloader.dart';
import '../services/tile_sources.dart';

part 'download_manager.g.dart';

/// What an app-level download job fetches.
enum DownloadJobKind { tiles, dem }

/// A job's lifecycle state. `paused` is only ever entered/exited by the
/// manager's app-lifecycle observer (backgrounded while running); `queued`
/// covers both "never started" and "resumed, waiting its turn."
enum DownloadJobStatus { queued, running, paused, complete, failed, cancelled }

/// One user-requested download (either a tile region or a DEM region). A
/// single "download this area" action from the UI enqueues one job per kind
/// (Phase C sends tiles and dem as separate jobs).
///
/// `done`/`failed` are honest per-tile tallies, not just a fraction: `failed`
/// is only ever 0 once every attempted tile succeeded, so the UI can show
/// "Completed with N failures" distinctly from a clean completion. `error` is
/// set only for a hard failure (nothing succeeded, or an exception outside
/// the per-tile loop).
class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.kind,
    required this.polygon,
    this.name,
    this.sourceId,
    this.minZoom,
    this.maxZoom,
    this.status = DownloadJobStatus.queued,
    this.total = 0,
    this.done = 0,
    this.failed = 0,
    this.error,
  });

  final String id;
  final DownloadJobKind kind;
  final List<LatLng> polygon;
  final String? name;

  /// Tiles only.
  final String? sourceId;
  final int? minZoom;
  final int? maxZoom;

  final DownloadJobStatus status;
  final int total;
  final int done;
  final int failed;
  final String? error;

  bool get isTerminal =>
      status == DownloadJobStatus.complete ||
      status == DownloadJobStatus.failed ||
      status == DownloadJobStatus.cancelled;

  DownloadJob copyWith({
    DownloadJobStatus? status,
    int? total,
    int? done,
    int? failed,
    String? error,
    bool clearError = false,
  }) =>
      DownloadJob(
        id: id,
        kind: kind,
        polygon: polygon,
        name: name,
        sourceId: sourceId,
        minZoom: minZoom,
        maxZoom: maxZoom,
        status: status ?? this.status,
        total: total ?? this.total,
        done: done ?? this.done,
        failed: failed ?? this.failed,
        error: clearError ? null : (error ?? this.error),
      );
}

/// App-level download queue: runs tile/DEM downloads independent of any
/// dialog or screen, so navigating within the app never kills an in-flight
/// download (only backgrounding the whole app pauses it — see class doc on
/// [didChangeAppLifecycleState]).
///
/// `keepAlive`d and never tied to a widget's lifetime. Phase C screens
/// `ref.watch(downloadManagerProvider)` for the job list (id, kind,
/// status, done/total/failed, error) and call [enqueueTiles]/[enqueueDem]/
/// [cancel]/[retry]/[resume] to drive it — no other public surface is
/// needed.
@Riverpod(keepAlive: true)
class DownloadManager extends _$DownloadManager with WidgetsBindingObserver {
  final Map<String, DownloadJob> _jobs = {};
  final Set<String> _cancelled = {};
  final Queue<String> _queue = Queue<String>();
  bool _appBackgrounded = false;
  bool _pumping = false;

  // Testing-only injection seam: lets tests substitute a fake HTTP client so
  // job-lifecycle tests never touch the network. Both tile fetches and DEM
  // (terrain-tile) fetches go through http, so one client covers both.
  // Production code never sets this, so the services fall back to their real
  // defaults.
  http.Client? _httpClientOverride;

  @visibleForTesting
  void debugConfigureForTesting({http.Client? httpClient}) {
    _httpClientOverride = httpClient;
  }

  OfflineRegionStore get _store => OfflineRegionStore();
  DemTileStore get _demStore => DemTileStore();

  @override
  List<DownloadJob> build() {
    WidgetsBinding.instance.addObserver(this);
    ref.onDispose(() => WidgetsBinding.instance.removeObserver(this));
    return const [];
  }

  /// Backgrounding the app (not merely navigating within it) pauses any
  /// running job at its next cooperative checkpoint; resuming re-queues
  /// whatever was paused. True OS backgrounding (app fully killed) is out of
  /// scope for this phase — the UI is expected to tell the user to keep the
  /// app open.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _appBackgrounded = true;
      case AppLifecycleState.resumed:
        _appBackgrounded = false;
        for (final job in _jobs.values.toList()) {
          if (job.status == DownloadJobStatus.paused) {
            _setJob(job.copyWith(status: DownloadJobStatus.queued));
            _queue.add(job.id);
          }
        }
        _pump();
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Whether a job with [id] is queued, running or paused — the states in
  /// which enqueueing it again would be a second copy of the same download.
  bool isInFlight(String id) {
    final job = _jobs[id];
    return job != null && !job.isTerminal;
  }

  /// **Re-queuing an existing id is how a saved area is downloaded again**
  /// (task 11.230's "Update"): the job carries the area's own id, so
  /// [_finishJob] upserts the same manifest entry. Two things that has to
  /// get right, both found by reading this class rather than by a report:
  /// a still-running job with that id must not be queued twice, and a
  /// cancellation left in [_cancelled] from the area's *first* download
  /// would stop the second one at its first tile.
  bool _admit(String jobId) {
    if (isInFlight(jobId)) return false;
    _cancelled.remove(jobId);
    return true;
  }

  /// Enqueues a tile-region download over [polygon] across
  /// `[minZoom, maxZoom]` and starts the queue if idle. Returns the job id.
  /// Passing the [id] of a job already in flight returns that id and queues
  /// nothing — ask [isInFlight] first to tell the two apart.
  String enqueueTiles({
    required List<LatLng> polygon,
    required String sourceId,
    required int minZoom,
    required int maxZoom,
    String? name,
    String? id,
  }) {
    final jobId = id ?? 'tiles-${DateTime.now().microsecondsSinceEpoch}';
    if (!_admit(jobId)) return jobId;
    _setJob(DownloadJob(
      id: jobId,
      kind: DownloadJobKind.tiles,
      polygon: polygon,
      name: name,
      sourceId: sourceId,
      minZoom: minZoom,
      maxZoom: maxZoom,
    ));
    _queue.add(jobId);
    _pump();
    return jobId;
  }

  /// Enqueues a DEM-region download over [polygon] and starts the queue if
  /// idle. Returns the job id.
  String enqueueDem({
    required List<LatLng> polygon,
    String? name,
    String? id,
  }) {
    final jobId = id ?? 'dem-${DateTime.now().microsecondsSinceEpoch}';
    if (!_admit(jobId)) return jobId;
    _setJob(DownloadJob(id: jobId, kind: DownloadJobKind.dem, polygon: polygon, name: name));
    _queue.add(jobId);
    _pump();
    return jobId;
  }

  /// Cooperatively cancels job [jobId]. A queued/paused job is cancelled
  /// immediately; a running job stops at its next per-tile checkpoint.
  void cancel(String jobId) {
    _cancelled.add(jobId);
    final job = _jobs[jobId];
    if (job == null) return;
    if (job.status == DownloadJobStatus.queued ||
        job.status == DownloadJobStatus.paused) {
      _queue.remove(jobId);
      _setJob(job.copyWith(status: DownloadJobStatus.cancelled));
    }
  }

  /// Re-queues a failed or cancelled job from scratch (progress counters
  /// reset; already-downloaded tiles are skipped again as cache hits).
  void retry(String jobId) {
    final job = _jobs[jobId];
    if (job == null) return;
    _cancelled.remove(jobId);
    _setJob(job.copyWith(
      status: DownloadJobStatus.queued,
      done: 0,
      failed: 0,
      total: 0,
      clearError: true,
    ));
    _queue.add(jobId);
    _pump();
  }

  /// Re-queues a job the lifecycle observer paused. (Auto-resume also
  /// happens on app resume; this lets the UI offer an explicit control too.)
  void resume(String jobId) {
    final job = _jobs[jobId];
    if (job == null || job.status != DownloadJobStatus.paused) return;
    _cancelled.remove(jobId);
    _setJob(job.copyWith(status: DownloadJobStatus.queued));
    _queue.add(jobId);
    _pump();
  }

  void _setJob(DownloadJob job) {
    _jobs[job.id] = job;
    state = List.unmodifiable(_jobs.values);
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty) {
        if (_appBackgrounded) break;
        final jobId = _queue.removeFirst();
        final job = _jobs[jobId];
        if (job == null || job.status == DownloadJobStatus.cancelled) continue;
        await _run(job);
      }
    } finally {
      _pumping = false;
    }
  }

  bool _shouldStop(String jobId) =>
      _cancelled.contains(jobId) || _appBackgrounded;

  Future<void> _run(DownloadJob job) async {
    _setJob(job.copyWith(status: DownloadJobStatus.running));
    try {
      if (job.kind == DownloadJobKind.tiles) {
        await _runTiles(job.id);
      } else {
        await _runDem(job.id);
      }
    } catch (e) {
      final current = _jobs[job.id];
      if (current == null) return;
      // `error` is rendered verbatim by the job card on the Offline Data Map
      // screen ("Failed — …"), so the sentence a person reads is composed
      // here, where the code knows what was being downloaded. A raw `$e`
      // here put an HTTP or filesystem exception on that card.
      final message = describeFailure(
        e,
        fallback: job.kind == DownloadJobKind.tiles
            ? 'Could not finish downloading these map tiles; those already '
                  'downloaded are kept. Check your connection and tap Retry.'
            : 'Could not finish downloading this elevation data; what '
                  'already downloaded is kept. Check your connection and tap '
                  'Retry.',
      );
      _setJob(
        current.copyWith(status: DownloadJobStatus.failed, error: message),
      );
    }
  }

  Future<void> _runTiles(String jobId) async {
    final job = _jobs[jobId]!;
    final zoomLevels = [for (var z = job.minZoom!; z <= job.maxZoom!; z++) z];
    final tiles = GeoPolygon.tilesInPolygon(polygon: job.polygon, zoomLevels: zoomLevels);
    final source = TileSources.byId(job.sourceId!);
    _setJob(_jobs[jobId]!.copyWith(total: tiles.length));

    final result = await OfflineTileDownloader.downloadTiles(
      tiles: tiles,
      source: source,
      onProgress: (done, total) {
        final current = _jobs[jobId];
        if (current != null) _setJob(current.copyWith(done: done, total: total));
      },
      isCancelled: () => _shouldStop(jobId),
      client: _httpClientOverride,
    );

    await _finishJob(
      jobId,
      done: result.completed,
      failed: result.failed,
      total: result.total,
    );
  }

  Future<void> _runDem(String jobId) async {
    final job = _jobs[jobId]!;
    final missing = await _demStore.missingTilesForPolygon(job.polygon);
    _setJob(_jobs[jobId]!.copyWith(total: missing.length));

    var done = 0;
    var failed = 0;
    // Shared across this whole job (task 11.281): adjacent DEM tiles overlap
    // in which terrarium tiles cover them, so one cache spanning the loop
    // avoids re-fetching a terrarium tile every DEM tile that needs it.
    final terrainCache = TerrainTileCache();
    for (final id in missing) {
      if (_shouldStop(jobId)) break;
      try {
        final grid = await DemTileFetcher.fetchTile(
          id,
          client: _httpClientOverride,
          isCancelled: () => _shouldStop(jobId),
          cache: terrainCache,
        );
        await _demStore.saveTile(id, grid);
        done++;
      } catch (_) {
        failed++;
      }
      final current = _jobs[jobId];
      if (current != null) {
        _setJob(current.copyWith(done: done, failed: failed, total: missing.length));
      }
    }

    await _finishJob(jobId, done: done, failed: failed, total: missing.length);
  }

  /// Maps a finished attempt to a terminal state and persists the manifest.
  ///
  /// [DownloadJobStatus] itself has no `partial` value: a job is `complete`
  /// once it finished attempting every tile (even if some individually
  /// failed — `failed`/`total` on the job say how many), and only `failed`
  /// when NOTHING succeeded. The finer complete/partial/failed distinction
  /// the manifest needs lives on [OfflineRegion.status] instead, computed
  /// from the same counts.
  Future<void> _finishJob(
    String jobId, {
    required int done,
    required int failed,
    required int total,
  }) async {
    final job = _jobs[jobId];
    if (job == null) return;

    if (_appBackgrounded) {
      // Don't re-queue here: `didChangeAppLifecycleState(resumed)` re-queues
      // every `paused` job exactly once. Adding it here too would leave two
      // copies of this job id in the queue once the app resumes.
      _setJob(job.copyWith(status: DownloadJobStatus.paused, done: done, failed: failed, total: total));
      return;
    }
    if (_cancelled.contains(jobId)) {
      _setJob(job.copyWith(status: DownloadJobStatus.cancelled, done: done, failed: failed, total: total));
      return;
    }

    final regionStatus = failed == 0
        ? OfflineRegionStatus.complete
        : (done > 0 ? OfflineRegionStatus.partial : OfflineRegionStatus.failed);

    final now = DateTime.now();
    final existing = (await _store.loadAll()).where((r) => r.id == jobId).firstOrNull;
    await _store.upsert(OfflineRegion(
      id: jobId,
      kind: job.kind == DownloadJobKind.tiles ? OfflineRegionKind.tiles : OfflineRegionKind.dem,
      // A name given on the manifest since this job was queued (a rename
      // during an update) outranks the one the job was queued with.
      name: existing?.name ?? job.name,
      polygon: job.polygon,
      sourceId: job.sourceId,
      minZoom: job.minZoom,
      maxZoom: job.maxZoom,
      cellSizeMeters: job.kind == DownloadJobKind.dem ? kDemCellSizeMeters : null,
      tileTotal: total,
      tileCompleted: done,
      status: regionStatus,
      sizeBytes: existing?.sizeBytes ?? 0,
      sharedBytes: existing?.sharedBytes ?? 0,
      sharedWithIds: existing?.sharedWithIds ?? const [],
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    ));
    await _store.reconcileWithDisk(
      tileCounter: const TileCacheCounter(),
      demStore: _demStore,
      now: now,
    );

    // Set the job's own terminal status only after the manifest write above
    // has landed, so anything that watches this provider to decide "is it
    // safe to read the manifest now" never observes a terminal job whose
    // manifest entry hasn't been persisted yet.
    final jobStatus = (total > 0 && done == 0)
        ? DownloadJobStatus.failed
        : DownloadJobStatus.complete;
    _setJob(job.copyWith(
      status: jobStatus,
      done: done,
      failed: failed,
      total: total,
      error: jobStatus == DownloadJobStatus.failed ? 'All tiles failed' : null,
      clearError: jobStatus != DownloadJobStatus.failed,
    ));
  }
}

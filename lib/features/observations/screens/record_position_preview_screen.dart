import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/map_settings_provider.dart';
import '../../../core/theme/app_theme.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import '../../../data/models/project.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../localization/angles.dart';
import '../../../localization/declination/declination_override_provider.dart';
import '../../../localization/declination/record_declination.dart';
import '../../../localization/declination/wmm_provider.dart';
import '../../map/map_camera_target.dart';
import '../../map/services/cached_tile_provider.dart';
import '../../map/services/desktop_map_gestures.dart';
import '../../map/services/geo_math.dart';
import '../../map/services/tile_sources.dart';
import '../../map/widgets/map_furniture.dart';
import '../providers/observation_form_provider.dart';

/// Full-screen map preview for the record form (design ask #16). Shows where
/// the record will be placed — and, for a directional bearing, the true-north
/// bearing ray + its uncertainty wedge fanning from that point — and lets the
/// user **tap or drag** to move the position by hand.
///
/// This replaces typing a latitude/longitude: GPS multipath in canyons and
/// dense forest can put the fix tens of metres off, and the field user can see
/// on the map where they actually are far more easily than they can read a
/// corrected coordinate. Moving the point writes it straight into the shared
/// [observationFormProvider] draft as a manual position, so returning (via the
/// AppBar back arrow) carries the adjustment into the record. Works for every
/// record type; the bearing overlay only appears for a directional record.
/// **Task 11.93 — the same picker, asked a different question.**
///
/// Given to [RecordPositionPreviewScreen] it stops reading and writing the
/// record draft and instead starts at [initial], keeps the moved point in its
/// own state, and hands it back when the person confirms — so correcting a
/// truth point's position uses this map, its gestures, its no-double-tap-zoom
/// rule and its help banner, rather than a second implementation that would
/// drift from them.
///
/// Task 11.92 argued a truth point's position should be fixed, and that
/// reasoning was wrong for the case the feature exists for: **nobody walks
/// into a pride**, so the recorded position is a place *near* the animal, and
/// deleting and re-recording changes nothing because the person is still in
/// the truck.
class PositionPickRequest {
  const PositionPickRequest({
    required this.initial,
    required this.title,
    required this.helpText,
  });

  /// Where the record currently says it is — the pin's starting point.
  final ll.LatLng initial;

  /// AppBar title, e.g. "Move truth point".
  final String title;

  /// One line under the coordinate in the banner, saying what moving the pin
  /// will mean for this record.
  final String helpText;
}

/// **Where the record being written says it is** — the manual pin if one has
/// been placed on this screen, else the GPS fix, else null.
///
/// The one answer to that question for every map beside the record form:
/// this screen places it and *Take on map* (task 11.315) sweeps from it, so a
/// pin moved here is the point the sweep fans out from there.
ll.LatLng? recordDraftMapPosition(ObservationDraftState draft, Position? gps) {
  if (draft.useManualPosition &&
      draft.manualLat != null &&
      draft.manualLon != null) {
    return ll.LatLng(draft.manualLat!, draft.manualLon!);
  }
  if (gps != null) return ll.LatLng(gps.latitude, gps.longitude);
  return null;
}

class RecordPositionPreviewScreen extends ConsumerStatefulWidget {
  const RecordPositionPreviewScreen({super.key, this.pick});

  /// Null in the ordinary case: the screen places the record draft's position
  /// (design ask #16). Non-null when it is being used to correct an existing
  /// record's position and hand it back — see [PositionPickRequest].
  final PositionPickRequest? pick;

  @override
  ConsumerState<RecordPositionPreviewScreen> createState() =>
      _RecordPositionPreviewScreenState();
}

class _RecordPositionPreviewScreenState
    extends ConsumerState<RecordPositionPreviewScreen> {
  final _mapController = MapController();

  /// Where the pin has been moved to in pick mode. Null until somebody moves
  /// it, which is what lets the Save label say whether anything changed.
  ll.LatLng? _picked;

  bool get _picking => widget.pick != null;

  ll.LatLng? _effectivePosition(ObservationDraftState? draft, Position? gps) {
    if (_picking) return _picked ?? widget.pick!.initial;
    if (draft == null) return null;
    return recordDraftMapPosition(draft, gps);
  }

  /// The true-north bearing to draw, mirroring the save path: a manual
  /// declination override wins, else the WMM value at [pos]; falls back to the
  /// magnetic bearing until WMM finishes loading. Null unless this is a
  /// directional record with a captured bearing. The rule itself is
  /// [recordDeclinationDeg], shared with *Take on map* (task 11.315).
  double? _trueNorthBearing(ObservationDraftState? draft, ll.LatLng pos) {
    final mag = draft?.bearingDeg;
    if (draft == null ||
        draft.recordType != RecordType.directional ||
        mag == null) {
      return null;
    }
    final manual = ref.watch(declinationOverrideProvider).value;
    final declination = recordDeclinationDeg(
      manualOverrideDeg: manual,
      wmm: manual != null ? null : ref.watch(wmmServiceProvider).value,
      latitude: pos.latitude,
      longitude: pos.longitude,
      date: DateTime.now(),
    );
    if (declination == null) return mag;
    return Angles.normalizeDegrees(mag + declination);
  }

  void _setPosition(ll.LatLng p) {
    if (!p.latitude.isFinite ||
        !p.longitude.isFinite ||
        p.latitude > 90.0 ||
        p.latitude < -90.0) {
      return;
    }
    // In pick mode the moved point is this screen's own answer, handed back on
    // confirm — it must not touch the record draft, which may hold an
    // unrelated half-written bearing.
    if (_picking) {
      setState(() => _picked = p);
      return;
    }
    ref
        .read(observationFormProvider.notifier)
        .setManualPosition(true, lat: p.latitude, lon: p.longitude);
  }

  void _dragPin(ll.LatLng current, Offset delta) {
    final camera = _mapController.camera;
    final moved = camera.screenOffsetToLatLng(
      camera.latLngToScreenOffset(current) + delta,
    );
    _setPosition(moved);
  }

  @override
  Widget build(BuildContext context) {
    // Pick mode does not read the draft at all — it is correcting a record
    // that was saved long ago, and waiting on a draft would leave it spinning.
    final draft = _picking ? null : ref.watch(observationFormProvider).value;
    final gps = ref.watch(gpsPositionProvider).value;
    final tileSource =
        ref.watch(selectedTileSourceProvider).value ?? TileSources.openStreetMap;
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final project = ref.watch(currentProjectProvider).value;

    final pos = _effectivePosition(draft, gps);
    final pick = widget.pick;

    return Scaffold(
      appBar: AppBar(
        title: Text(pick?.title ?? 'Adjust position'),
        actions: [
          if (pick != null)
            TextButton.icon(
              // Pops the position rather than writing it: the caller owns the
              // record and decides what moving it means for its
              // `position_source` (task 11.93).
              onPressed: () =>
                  Navigator.of(context).pop(_picked ?? pick.initial),
              icon: const Icon(Icons.check),
              label: const Text('Use this position'),
            ),
          if (draft != null && draft.useManualPosition)
            TextButton.icon(
              onPressed: () {
                ref
                    .read(observationFormProvider.notifier)
                    .setManualPosition(false);
              },
              icon: const Icon(Icons.gps_fixed),
              label: const Text('Use GPS'),
            ),
        ],
      ),
      body: draft == null && !_picking
          ? const Center(child: CircularProgressIndicator())
          : pos == null
              ? _buildNoFixMap(context, project, tileSource)
              : _buildMap(context, draft, gps, pos, tileSource, colors),
    );
  }

  /// Shown when there's neither a GPS fix nor a manual pin yet — the normal
  /// state on a desktop build with no location hardware (see 5.1/5.2), but
  /// also just the ordinary "no fix yet" moment on any platform. Centers on
  /// the active project's extent (falling back to a wide world view if the
  /// project has none) rather than dead-ending on a spinner, since tapping
  /// this map is the *only* way to place a first pin when GPS never
  /// resolves — the Record screen's save-blocked snackbar already points
  /// here for exactly that reason.
  Widget _buildNoFixMap(BuildContext context, Project? project, TileSource tileSource) {
    final bounds = _projectBounds(project);

    return Stack(
      children: [
        DesktopTrackpadZoom(
          mapController: _mapController,
          child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCameraFit: bounds != null
                ? CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(40))
                : null,
            // Task 11.103: the same named whole-planet framing every other
            // map in the app falls back to, rather than a literal repeated
            // here. This screen was already doing the honest thing — it is
            // the one place the pattern was right — so only the names change.
            initialCenter: MapCameraTarget.worldViewCenter,
            initialZoom:
                bounds != null ? 13 : MapCameraTarget.worldViewZoom,
            minZoom: 2,
            cameraConstraint: const CameraConstraint.containLatitude(
              85.05112878,
              -85.05112878,
            ),
            interactionOptions: InteractionOptions(
              // Placing a pin is the point of this screen — two quick taps
              // to adjust the pin twice must stay two taps, not get
              // reinterpreted as "zoom in here" (flutter_map's default
              // double-tap-zoom gesture, which also tends to zoom straight
              // past the tile source's usable range and blank the map).
              flags: mapInteractionFlags(doubleTapZoom: false),
              enableMultiFingerGestureRace: true,
              rotationThreshold: 30.0,
              pinchZoomThreshold: 0.5,
              pinchMoveThreshold: 40.0,
            ),
            onTap: (_, point) => _setPosition(point),
          ),
          children: [
            TileLayer(
              urlTemplate: tileSource.urlTemplate,
              subdomains: tileSource.subdomains,
              maxZoom: tileSource.maxZoom.toDouble(),
              tileProvider: CachedTileProvider(source: tileSource),
            ),
          ],
          ),
        ),
        // **Task 11.135 — verdict: show it, stacked under the banner that
        // is already here rather than at an anchor of its own.**
        //
        // Both maps on this screen have exactly one overlay, at the top, and
        // the subject is a pin somebody is placing near the middle. A second
        // top-corner anchor would have been a `Stack` with two children on
        // the same edge — the shape task 11.126 spent a task collapsing — so
        // the band joins the existing column and the two move together.
        //
        // This map in particular is where it matters most on this screen:
        // there is no fix, so **tapping the basemap is the only way to place
        // a first pin**, and a basemap that is not arriving makes that
        // impossible with no explanation.
        const Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: Column(
            children: [
              _NoFixBanner(),
              TilesNotLoadingBand(
                bannerKey: ValueKey('record-preview-tiles-not-loading'),
                padding: EdgeInsets.only(top: 8),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The project's bounding box as [LatLngBounds], or null if any corner is
  /// missing (a project created without an extent).
  LatLngBounds? _projectBounds(Project? project) {
    final minLat = project?.bboxMinLat;
    final minLon = project?.bboxMinLon;
    final maxLat = project?.bboxMaxLat;
    final maxLon = project?.bboxMaxLon;
    if (minLat == null || minLon == null || maxLat == null || maxLon == null) {
      return null;
    }
    return LatLngBounds(ll.LatLng(minLat, minLon), ll.LatLng(maxLat, maxLon));
  }

  Widget _buildMap(
    BuildContext context,
    ObservationDraftState? draft,
    Position? gps,
    ll.LatLng pos,
    TileSource tileSource,
    TriTrackColors colors,
  ) {
    final bearing = _trueNorthBearing(draft, pos);
    const rangeM = 300.0;
    final half = (draft?.bearingUncertaintyDeg ?? 0.0).clamp(0.0, 90.0);
    final gpsPoint =
        gps != null ? ll.LatLng(gps.latitude, gps.longitude) : null;

    return Stack(
      children: [
        DesktopTrackpadZoom(
          mapController: _mapController,
          child: FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: pos,
            initialZoom: 16,
            minZoom: 2,
            cameraConstraint: const CameraConstraint.containLatitude(
              85.05112878,
              -85.05112878,
            ),
            interactionOptions: InteractionOptions(
              // Placing a pin is the point of this screen — two quick taps
              // to adjust the pin twice must stay two taps, not get
              // reinterpreted as "zoom in here" (flutter_map's default
              // double-tap-zoom gesture, which also tends to zoom straight
              // past the tile source's usable range and blank the map).
              flags: mapInteractionFlags(doubleTapZoom: false),
              enableMultiFingerGestureRace: true,
              rotationThreshold: 30.0,
              pinchZoomThreshold: 0.5,
              pinchMoveThreshold: 40.0,
            ),
            onTap: (_, point) => _setPosition(point),
          ),
          children: [
            TileLayer(
              urlTemplate: tileSource.urlTemplate,
              subdomains: tileSource.subdomains,
              maxZoom: tileSource.maxZoom.toDouble(),
              tileProvider: CachedTileProvider(source: tileSource),
            ),
            if (bearing != null)
              PolygonLayer(
                polygons: [
                  Polygon(
                    points: [
                      for (final p in bearingWedgePoints(
                        origin: GeoPoint(pos.latitude, pos.longitude),
                        bearingDeg: bearing,
                        halfWidthDeg: half,
                        rangeMeters: rangeM,
                      ))
                        ll.LatLng(p.latitude, p.longitude),
                    ],
                    color: colors.bearingRay.withValues(alpha: 0.15),
                    borderColor: colors.bearingRay.withValues(alpha: 0.4),
                    borderStrokeWidth: 0.5,
                  ),
                ],
              ),
            if (bearing != null)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: [
                      pos,
                      () {
                        final dest = destinationPoint(
                          GeoPoint(pos.latitude, pos.longitude),
                          bearing,
                          rangeM,
                        );
                        return ll.LatLng(dest.latitude, dest.longitude);
                      }(),
                    ],
                    color: colors.bearingRay,
                    strokeWidth: 3,
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                // Faint blue GPS dot for reference — so a corrected pin can be
                // compared against where GPS thinks the user is.
                if (gpsPoint != null && (_picking || draft!.useManualPosition))
                  Marker(
                    point: gpsPoint,
                    width: 18,
                    height: 18,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                // The record's position — draggable for fine adjustment; tap
                // anywhere on the map moves it there too.
                Marker(
                  point: pos,
                  width: 44,
                  height: 44,
                  alignment: Alignment.topCenter,
                  child: GestureDetector(
                    onPanUpdate: (d) => _dragPin(pos, d.delta),
                    child: Icon(
                      Icons.location_on,
                      size: 44,
                      color: colors.bearingRay,
                      shadows: const [
                        Shadow(color: Colors.white, blurRadius: 3),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
          ),
        ),
        Positioned(
          top: 8,
          left: 12,
          right: 12,
          child: Column(
            children: [
              _HelpBanner(
            // Pick mode is manual by definition: the person is placing this
            // point by hand, whatever the record used to say.
            manual: _picking || draft!.useManualPosition,
            position: pos,
            note: widget.pick?.helpText,
              ),
              // Task 11.135, same verdict and same reason as the no-fix map
              // above: one existing top column, joined rather than a second
              // anchor on the same edge.
              const TilesNotLoadingBand(
                bannerKey: ValueKey('record-preview-tiles-not-loading'),
                padding: EdgeInsets.only(top: 8),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HelpBanner extends StatelessWidget {
  const _HelpBanner({
    required this.manual,
    required this.position,
    this.note,
  });
  final bool manual;
  final ll.LatLng position;

  /// What moving this pin will mean for the record being corrected — supplied
  /// only in pick mode (task 11.93), where the person is editing a saved
  /// record rather than placing a draft.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(10),
      color: scheme.surface.withValues(alpha: 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              manual
                  ? '✋ Manual position — tap or drag the pin to adjust'
                  : 'Tap the map or drag the pin to set the position by hand',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              '${position.latitude.toStringAsFixed(5)}, '
              '${position.longitude.toStringAsFixed(5)}'
              '${manual ? '' : ' · from GPS'}',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            if (note != null)
              Text(
                note!,
                style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
              )
            else if (!manual)
              Text(
                'Useful when GPS is off from canyon/forest multipath.',
                style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// Persistent notice shown while the map has no GPS fix and no pin yet — the
/// map is centered on the project extent (or a wide fallback view), which is
/// **not** a position fix, so a pin placed from here must never read as
/// GPS-derived. Deliberately a fixed banner rather than a transient snackbar,
/// per this task's acceptance criteria, so it can't be missed.
class _NoFixBanner extends StatelessWidget {
  const _NoFixBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(10),
      color: scheme.surface.withValues(alpha: 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '📍 No GPS fix — map centered on the project area, not your position',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              'Tap the map to place a pin at the actual position.',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

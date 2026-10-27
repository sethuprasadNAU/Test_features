import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart' as ll;

import '../../../compass/bearing_capture.dart';
import '../../../compass/compass_controller.dart';
import '../../../compass/compass_reading.dart';
import '../../../compass/heading_smoother.dart';
import '../../../core/providers/app_context_provider.dart';
import '../../../core/providers/deployments_provider.dart';
import '../../../core/providers/gps_provider.dart';
import '../../../core/providers/map_settings_provider.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/deployment.dart';
import '../../../data/models/observation.dart';
import '../../../data/repositories/deployment_repository.dart';
import '../../../localization/angles.dart';
import '../../../localization/coordinate_projection.dart';
import '../../../localization/declination/declination_override_provider.dart';
import '../../../localization/declination/record_declination.dart';
import '../../../localization/declination/wmm_provider.dart';
import '../../../routing/tab_visibility.dart';
import '../../../widgets/raw_hold_gesture.dart';
import '../../map/services/bearing_wedge_cache.dart';
import '../../map/services/cached_tile_provider.dart';
import '../../map/services/desktop_map_gestures.dart';
import '../../map/services/geo_math.dart';
import '../../map/services/tile_sources.dart';
import '../../map/widgets/map_furniture.dart';
import '../providers/bearing_map_provider.dart';
import '../providers/observation_form_provider.dart';
import 'record_position_preview_screen.dart' show recordDraftMapPosition;

/// # Take on map — a range bearing taken over the day's other bearings
///
/// **Task 11.315, found by Michael on a trail on 2026-09-27**: after every
/// bearing he opened the map to see how it crossed his earlier ones. This
/// screen puts the sweep on that map while it is being swept.
///
/// What it draws, from the bottom up:
///
/// - **The person's position** — the record draft's, the same point Preview
///   places, including a pin moved there ([recordDraftMapPosition]).
/// - **Today's earlier bearings on the selected collar**, each a center line
///   and a faint wedge, from their stored true-north values — the way the Map
///   tab draws them. Which bearings count is [earlierBearingsToday].
/// - **The sweep**, brighter: a thin line where the phone points before the
///   button is held, the wedge swept while it is held, and the resulting
///   bearing after release.
///
/// ## Every line is drawn out to [kMaxBearingRangeMeters]
///
/// The brief asked for every line and wedge to reach the edge of the screen,
/// redrawn on every pan, zoom and rotation, capped at the Map tab's 40 km.
/// **Drawing every line at the cap is exactly that picture**: a line longer
/// than the screen is cut by the screen's edge wherever the camera is, and
/// `flutter_map` re-projects it on every frame, so it meets the edge after any
/// pan, zoom or turn without this screen doing anything; zoomed out past 40
/// km, it stops at the cap. The one thing a length computed per frame would
/// add is cost — a new wedge per bearing per frame — where a fixed length
/// lets [BearingWedgeCache] compute each earlier wedge once for the life of
/// the screen. `bearing_map_capture_screen_test.dart` measures the claim
/// itself: after a pan, a zoom and a rotation, every line's far end is off
/// the screen or 40 km out.
///
/// ## True north throughout
///
/// The compass reads magnetic. The sweep is turned to true north with
/// [recordDeclinationDeg] — the override if one is set, else the World
/// Magnetic Model at the position — the same function Preview uses. What
/// Confirm writes into the form is the **magnetic** sweep, exactly what the
/// RANGE button writes, so the save path converts it once, as it always has.
///
/// ## What it never does
///
/// **It never saves.** Confirm fills the record form and closes; the person
/// still reviews the form and taps Save, so there is one save path. Cancel,
/// or the back arrow, leaves the form exactly as it was.
class BearingMapCaptureScreen extends ConsumerStatefulWidget {
  const BearingMapCaptureScreen({super.key, this.wedgeCache});

  /// Handed in only by a test, so it can count what the screen recomputes —
  /// the one way to tell "cached" from "recomputed and identical". Null in
  /// the app, where the screen makes its own.
  @visibleForTesting
  final BearingWedgeCache? wedgeCache;

  @override
  ConsumerState<BearingMapCaptureScreen> createState() =>
      _BearingMapCaptureScreenState();
}

class _BearingMapCaptureScreenState
    extends ConsumerState<BearingMapCaptureScreen> {
  final _mapController = MapController();

  /// Memoised wedges, keyed by observation — the Map tab's cache, not a
  /// second one. Earlier bearings never change on this screen, so each is
  /// computed once; the live sweep's entry is the only one recomputed, once
  /// per compass sample.
  late final _wedgeCache = widget.wedgeCache ?? BearingWedgeCache();

  /// The RANGE button's own start-and-end logic, reused so a sweep taken
  /// here resolves to the same midpoint and half-width as one taken there.
  final _capture = BearingCaptureController();

  final _smoother = HeadingSmoother();

  static const _liveWedgeKey = '__take_on_map_sweep__';

  bool _mapReady = false;

  /// The pointer holding the sweep button down, or null when nobody is.
  int? _holdPointer;
  bool get _holding => _holdPointer != null;

  /// The sweep just released, waiting for Confirm, Retake or Cancel.
  CapturedBearing? _captured;

  /// Facing up follows the phone until somebody pans the map away; then it
  /// holds still until *Back to me* (task 11.315 item 4), so the map does not
  /// fight the finger.
  bool _following = true;

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(observationFormProvider).value;
    final gps = ref.watch(gpsPositionProvider).value;
    // Pushed over the tab shell, so no tab can hide it and this is an
    // ordinary watch — the gated form is what `hidden_tab_liveness_test`
    // asks every compass watch in `lib/` to use, and it is right to ask.
    final reading = ref.watchWhileTabVisible(
      context,
      compassControllerProvider,
      whileHidden: CompassReading.initial,
    );
    final orientation =
        ref.watch(bearingMapOrientationProvider).value ??
        BearingMapOrientation.northUp;

    // Facing up turns the map from here, outside build: a compass sample is
    // an event, and a map controller must not be driven from inside a build.
    ref.listen(compassControllerProvider, (_, next) => _onCompass(next));

    final pos = draft == null ? null : recordDraftMapPosition(draft, gps);

    return Scaffold(
      appBar: AppBar(title: const Text('Take on map')),
      body: draft == null
          ? const Center(child: CircularProgressIndicator())
          : pos == null
          ? const _NoPositionMessage()
          : _buildBody(context, draft, pos, reading, orientation),
    );
  }

  Widget _buildBody(
    BuildContext context,
    ObservationDraftState draft,
    ll.LatLng pos,
    CompassReading reading,
    BearingMapOrientation orientation,
  ) {
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final tileSource =
        ref.watch(selectedTileSourceProvider).value ??
        TileSources.openStreetMap;
    final tileCategoryAsync = ref.watch(selectedTileCategoryProvider);
    final project = ref.watch(currentProjectProvider).value;
    final tagId = draft.tagId;
    final todaysBearings = project == null || tagId == null
        ? const <Observation>[]
        : ref
                  .watch(
                    todaysBearingsOnTagProvider((
                      projectId: project.projectId,
                      tagId: tagId,
                    )),
                  )
                  .value ??
              const <Observation>[];
    final deployments = project == null
        ? const <Deployment>[]
        : ref.watch(projectDeploymentsProvider(project.projectId)).value ??
              const <Deployment>[];
    // On a day the collar changes hands, leave out bearings taken while it
    // belonged to a different animal (task 11.317 item 4) — otherwise the
    // morning's bearings, on the animal that had it then, would be drawn
    // under the afternoon's sweep as if they were about today's animal.
    // Same derivation the Map tab and Log use, so this screen can never
    // disagree with them about whose bearing something is.
    final earlier = tagId == null
        ? const <Observation>[]
        : () {
            final current = DeploymentRepository.animalForObservationIn(
              deployments,
              tagId: tagId,
              at: DateTime.now(),
            );
            return [
              for (final o in todaysBearings)
                if (sameAnimalAttribution(
                  current,
                  DeploymentRepository.animalForObservationIn(
                    deployments,
                    tagId: tagId,
                    at: o.timestampUtc,
                  ),
                ))
                  o,
            ];
          }();
    final manual = ref.watch(declinationOverrideProvider).value;
    final declination = recordDeclinationDeg(
      manualOverrideDeg: manual,
      wmm: manual != null ? null : ref.watch(wmmServiceProvider).value,
      latitude: pos.latitude,
      longitude: pos.longitude,
      date: DateTime.now(),
    );
    double toTrue(double magnetic) =>
        Angles.normalizeDegrees(magnetic + (declination ?? 0));

    final liveMagnetic = reading.magneticHeadingDeg;
    final sweep = _sweepToDraw(liveMagnetic);
    final origin = GeoPoint(pos.latitude, pos.longitude);

    ll.LatLng tipOf(GeoPoint from, double trueDeg) {
      final p = destinationPoint(from, trueDeg, kMaxBearingRangeMeters);
      return ll.LatLng(p.latitude, p.longitude);
    }

    final earlierWedges = [
      for (final o in earlier)
        Polygon(
          points: _wedgeCache.points(
            observationId: o.observationId,
            latitude: o.latitude,
            longitude: o.longitude,
            bearingDeg: o.trueNorthBearing!,
            halfWidthDeg: (o.bearingUncertainty ?? 12.0)
                .clamp(0.0, 90.0)
                .toDouble(),
            rangeMeters: kMaxBearingRangeMeters,
          ),
          color: colors.bearingRay.withValues(alpha: 0.08),
          borderColor: colors.bearingRay.withValues(alpha: 0.3),
          borderStrokeWidth: 0.5,
        ),
    ];
    final earlierLines = [
      for (final o in earlier)
        Polyline(
          points: [
            ll.LatLng(o.latitude, o.longitude),
            tipOf(GeoPoint(o.latitude, o.longitude), o.trueNorthBearing!),
          ],
          color: colors.bearingRay.withValues(alpha: 0.55),
          strokeWidth: 2,
        ),
    ];

    final sweepWedge = sweep == null
        ? null
        : Polygon(
            points: _wedgeCache.points(
              observationId: _liveWedgeKey,
              latitude: pos.latitude,
              longitude: pos.longitude,
              bearingDeg: toTrue(sweep.midpointDeg),
              halfWidthDeg: sweep.halfWidthDeg.clamp(0.0, 90.0).toDouble(),
              rangeMeters: kMaxBearingRangeMeters,
            ),
            color: colors.bearingRay.withValues(alpha: 0.3),
            borderColor: colors.bearingRay,
            borderStrokeWidth: 1.5,
          );
    final sweepLine = sweep == null
        ? null
        : Polyline(
            points: [pos, tipOf(origin, toTrue(sweep.midpointDeg))],
            color: colors.bearingRay,
            strokeWidth: 4,
          );
    // Where the phone points, before anything is held: a thin line, so a
    // person can aim before they sweep. Gone while a sweep or its result is
    // on the map, where it would only be a second line to misread.
    final pointerLine = sweep != null || liveMagnetic == null
        ? null
        : Polyline(
            points: [pos, tipOf(origin, toTrue(liveMagnetic))],
            color: colors.bearingRay,
            strokeWidth: 2,
            pattern: StrokePattern.dashed(segments: const [10.0, 6.0]),
          );

    final camera = _mapReady ? _mapController.camera : null;
    final facingUp = orientation == BearingMapOrientation.facingUp;

    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              // **While the button is held the map ignores every touch**
              // (task 11.315 item 4) — a thumb brushing the screen mid-sweep
              // must not move the map the sweep is being read against.
              IgnorePointer(
                key: const ValueKey('bearing-map-map'),
                ignoring: _holding,
                child: DesktopTrackpadZoom(
                  mapController: _mapController,
                  child: FlutterMap(
                    mapController: _mapController,
                    options: MapOptions(
                      initialCenter: pos,
                      initialZoom: 14,
                      minZoom: 2,
                      cameraConstraint: const CameraConstraint.containLatitude(
                        85.05112878,
                        -85.05112878,
                      ),
                      interactionOptions: InteractionOptions(
                        // No rotate gesture: which way the map points is the
                        // orientation button's decision, and in facing up the
                        // compass's. A two-finger twist turning a north-up
                        // map would make it neither.
                        flags:
                            mapInteractionFlags(doubleTapZoom: false) &
                            ~InteractiveFlag.rotate,
                        enableMultiFingerGestureRace: true,
                        pinchZoomThreshold: 0.5,
                        pinchMoveThreshold: 40.0,
                      ),
                      onMapReady: _onMapReady,
                      onMapEvent: _onMapEvent,
                    ),
                    children: [
                      TileLayer(
                        urlTemplate: tileSource.urlTemplate,
                        subdomains: tileSource.subdomains,
                        maxZoom: tileSource.maxZoom.toDouble(),
                        tileProvider: CachedTileProvider(source: tileSource),
                      ),
                      PolygonLayer(
                        key: const ValueKey('bearing-map-wedges'),
                        polygons: [
                          ...earlierWedges,
                          ?sweepWedge,
                        ],
                      ),
                      PolylineLayer(
                        key: const ValueKey('bearing-map-lines'),
                        polylines: [
                          ...earlierLines,
                          ?sweepLine,
                          ?pointerLine,
                        ],
                      ),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: pos,
                            width: 20,
                            height: 20,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: colors.bearingRay,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                top: 8,
                left: 12,
                right: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // The same halo control the Map tab uses (task 11.317
                    // item 1), backed by the same provider: changing the map
                    // type here changes it there too.
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: tileCategoryAsync.when(
                          data: (category) => MapTypeToggle(
                            category: category,
                            onChanged: (c) => ref
                                .read(selectedTileCategoryProvider.notifier)
                                .set(c),
                          ),
                          loading: () => const SizedBox.shrink(),
                          error: (_, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    if (tagId == null)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: MapNoticeBanner(
                          bannerKey: ValueKey('bearing-map-no-tag-notice'),
                          icon: Icons.linear_scale,
                          message: 'No tag selected, so no earlier bearings '
                              'are shown.',
                        ),
                      ),
                    if (facingUp && !reading.isHeadingReliable)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: MapNoticeBanner(
                          bannerKey: const ValueKey('bearing-map-compass-notice'),
                          icon: Icons.explore_off_outlined,
                          message: liveMagnetic == null
                              ? 'No compass heading, so the map has stopped '
                                    'turning.'
                              : 'The compass is disturbed, so the map has '
                                    'stopped turning.',
                        ),
                      )
                    else if (facingUp && !_following)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: MapNoticeBanner(
                          bannerKey: ValueKey('bearing-map-paused-notice'),
                          icon: Icons.pause_circle_outline,
                          message: 'The map stopped turning while you move '
                              'it. Tap Back to me to start again.',
                        ),
                      ),
                    const TilesNotLoadingBand(
                      bannerKey: ValueKey('bearing-map-tiles-not-loading'),
                      padding: EdgeInsets.only(top: 8),
                    ),
                  ],
                ),
              ),
              if (camera != null)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: MapScaleBar(
                    latitude: camera.center.latitude,
                    zoom: camera.zoom,
                  ),
                ),
              Positioned(
                right: 12,
                bottom: 12,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Only while the map is turned, as on the Map tab: on a
                    // north-up map the arrow says nothing, and in facing up
                    // it is the one thing on screen that says where north is.
                    if (camera != null && camera.rotation.abs() > 0.5)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: MapNorthArrow(
                          rotationDeg: camera.rotation,
                          onTap: () => _setOrientation(
                            BearingMapOrientation.northUp,
                          ),
                        ),
                      ),
                    // On the map rather than in the title bar: both are
                    // about the view, and beside the back arrow the title
                    // had no room left at the largest text sizes.
                    _MapControlChip(
                      buttonKey: const ValueKey('bearing-map-orientation'),
                      icon: facingUp
                          ? Icons.navigation_outlined
                          : Icons.north,
                      label: facingUp ? 'Facing up' : 'North up',
                      onPressed: () => _toggleOrientation(orientation),
                    ),
                    const SizedBox(height: 8),
                    _MapControlChip(
                      buttonKey: const ValueKey('bearing-map-back-to-me'),
                      icon: Icons.my_location,
                      label: 'Back to me',
                      onPressed: () => _backToMe(pos),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _BottomPanel(
          liveMagneticDeg: liveMagnetic,
          holding: _holding,
          captured: _captured,
          onHoldStart: (pointer) => _onHoldStart(pointer, liveMagnetic),
          onHoldEnd: (pointer) => _onHoldEnd(pointer, liveMagnetic),
          onHoldCancel: _onHoldCancel,
          onConfirm: _confirm,
          onRetake: _retake,
          onCancel: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  /// The sweep to draw, in magnetic degrees: the arc from the start to where
  /// the phone points now while the button is held, or the released result.
  ({double midpointDeg, double halfWidthDeg})? _sweepToDraw(
    double? liveMagnetic,
  ) {
    final captured = _captured;
    if (captured != null) {
      return (
        midpointDeg: captured.magneticBearingDeg,
        halfWidthDeg: captured.uncertaintyDeg,
      );
    }
    final start = _capture.rangeStartDeg;
    if (!_holding || start == null || liveMagnetic == null) return null;
    final arc = rangeCaptureBearing(start, liveMagnetic);
    return (midpointDeg: arc.midpointDegrees, halfWidthDeg: arc.halfWidthDegrees);
  }

  // ---------------------------------------------------------------------
  // The map
  // ---------------------------------------------------------------------

  void _onMapReady() {
    setState(() => _mapReady = true);
    final orientation = ref.read(bearingMapOrientationProvider).value;
    if (orientation == BearingMapOrientation.facingUp) {
      _onCompass(ref.read(compassControllerProvider));
    }
  }

  void _onMapEvent(MapEvent event) {
    // The scale bar and the north arrow read the camera, so any movement at
    // all is a rebuild — the same as the Map tab, and cheap, because every
    // earlier wedge is a cache hit.
    setState(() {});
    final orientation = ref.read(bearingMapOrientationProvider).value;
    if (orientation != BearingMapOrientation.facingUp) return;
    switch (event.source) {
      // One finger dragging the map is somebody looking elsewhere, and a
      // following map would drag it straight back.
      case MapEventSource.dragStart ||
          MapEventSource.onDrag ||
          MapEventSource.flingAnimationController:
        if (_following) setState(() => _following = false);
      // Two fingers are a zoom. A pinch moves the center a little as well,
      // so a following map puts the position back once the fingers lift.
      case MapEventSource.multiFingerEnd:
        if (_following) _recenterFacing();
      default:
        break;
    }
  }

  void _onCompass(CompassReading reading) {
    final orientation = ref.read(bearingMapOrientationProvider).value;
    if (orientation != BearingMapOrientation.facingUp) return;
    final trueHeading = _trueHeadingOf(reading);
    if (!reading.isHeadingReliable || trueHeading == null) {
      // Stop turning rather than spin (task 11.315 item 3). Forgetting the
      // smoothed value means the map goes straight to the right heading when
      // the compass comes back, instead of easing through a stale one.
      _smoother.reset();
      return;
    }
    _smoother.add(trueHeading);
    if (!_following || !_mapReady) return;
    if (_smoother.shouldApply()) _recenterFacing();
  }

  /// The phone's heading in true degrees at the record's position, or null
  /// with no heading or no position yet.
  double? _trueHeadingOf(CompassReading reading) {
    final magnetic = reading.magneticHeadingDeg;
    final draft = ref.read(observationFormProvider).value;
    final pos = draft == null
        ? null
        : recordDraftMapPosition(draft, ref.read(gpsPositionProvider).value);
    if (magnetic == null || pos == null) return null;
    final manual = ref.read(declinationOverrideProvider).value;
    final declination = recordDeclinationDeg(
      manualOverrideDeg: manual,
      wmm: manual != null ? null : ref.read(wmmServiceProvider).value,
      latitude: pos.latitude,
      longitude: pos.longitude,
      date: DateTime.now(),
    );
    return Angles.normalizeDegrees(magnetic + (declination ?? 0));
  }

  /// Puts the position in the middle and the phone's heading at the top.
  void _recenterFacing() {
    final heading = _smoother.value;
    final draft = ref.read(observationFormProvider).value;
    final pos = draft == null
        ? null
        : recordDraftMapPosition(draft, ref.read(gpsPositionProvider).value);
    if (!_mapReady || pos == null) return;
    _mapController.moveAndRotate(
      pos,
      _mapController.camera.zoom,
      heading == null ? _mapController.camera.rotation : mapRotationFacing(heading),
    );
  }

  void _backToMe(ll.LatLng pos) {
    if (!_mapReady) return;
    final orientation = ref.read(bearingMapOrientationProvider).value;
    if (orientation == BearingMapOrientation.facingUp) {
      setState(() => _following = true);
      _recenterFacing();
      return;
    }
    _mapController.move(pos, _mapController.camera.zoom);
  }

  void _toggleOrientation(BearingMapOrientation current) => _setOrientation(
    current == BearingMapOrientation.northUp
        ? BearingMapOrientation.facingUp
        : BearingMapOrientation.northUp,
  );

  void _setOrientation(BearingMapOrientation next) {
    ref.read(bearingMapOrientationProvider.notifier).set(next);
    if (!_mapReady) return;
    if (next == BearingMapOrientation.northUp) {
      _mapController.rotate(0);
      return;
    }
    setState(() => _following = true);
    _smoother.reset();
    final trueHeading = _trueHeadingOf(ref.read(compassControllerProvider));
    if (trueHeading != null) {
      _smoother.add(trueHeading);
      _smoother.shouldApply();
    }
    _recenterFacing();
  }

  // ---------------------------------------------------------------------
  // The sweep
  // ---------------------------------------------------------------------

  void _onHoldStart(int pointer, double? liveMagnetic) {
    if (_holding || _captured != null || liveMagnetic == null) return;
    HapticFeedback.mediumImpact();
    _capture.markRangeStart(liveMagnetic);
    setState(() => _holdPointer = pointer);
  }

  void _onHoldEnd(int pointer, double? liveMagnetic) {
    if (_holdPointer != pointer) return;
    setState(() => _holdPointer = null);
    // Released with no heading: nothing honest to record, exactly as the
    // RANGE button does.
    if (liveMagnetic == null) {
      _capture.cancelRange();
      return;
    }
    final captured = _capture.markRangeEnd(liveMagnetic);
    if (captured == null) return;
    HapticFeedback.mediumImpact();
    setState(() => _captured = captured);
  }

  void _onHoldCancel(int pointer) {
    if (_holdPointer != pointer) return;
    _capture.cancelRange();
    setState(() => _holdPointer = null);
  }

  /// Retake clears the sweep and stays on the map.
  void _retake() {
    HapticFeedback.lightImpact();
    _capture.cancelRange();
    setState(() => _captured = null);
  }

  /// Confirm writes the sweep into the record form — the same call, with the
  /// same values, as the RANGE button's release — and closes. **It does not
  /// save**: the person still reviews the form and taps Save.
  void _confirm() {
    final captured = _captured;
    if (captured == null) return;
    ref
        .read(observationFormProvider.notifier)
        .setBearing(
          bearingDeg: captured.magneticBearingDeg,
          uncertaintyDeg: captured.uncertaintyDeg,
          captureMethodDb: 'range_capture',
          startDeg: captured.magneticStartDeg,
          endDeg: captured.magneticEndDeg,
          ambiguousSweep: captured.ambiguousSweep,
        );
    Navigator.of(context).pop();
  }
}

/// **The map rotation that puts a true heading at the top of the screen.**
///
/// `flutter_map` turns the map by the camera's rotation, and a camera rotated
/// by *h* shows the direction *h* at the top — `bearing_map_capture_screen_test`
/// projects a point along the heading and checks it lands straight above the
/// center, which is the only way to know the sign rather than believe it.
double mapRotationFacing(double trueHeadingDeg) => -trueHeadingDeg;

/// Whether an earlier bearing's attribution counts as the collar's current
/// one, for task 11.317 item 4. Both sides having no animal is "the same"
/// (Michael: a bearing with no animal attributed stays, as today, when the
/// current one has none either); otherwise it is a shared candidate — an
/// overlap rather than exact equality, so a contested moment on either side
/// is not silently dropped.
@visibleForTesting
bool sameAnimalAttribution(
  AnimalAttribution current,
  AnimalAttribution earlier,
) {
  if (current.isNobody || earlier.isNobody) {
    return current.isNobody && earlier.isNobody;
  }
  return earlier.candidates.any(current.candidates.contains);
}

/// A labelled button floating on the map — the orientation switch, which
/// says which way the map is held now and changes it when tapped, and *Back
/// to me*.
class _MapControlChip extends StatelessWidget {
  const _MapControlChip({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(10),
      child: TextButton.icon(
        key: buttonKey,
        onPressed: onPressed,
        icon: Icon(icon),
        label: Text(label),
      ),
    );
  }
}

class _NoPositionMessage extends StatelessWidget {
  const _NoPositionMessage();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No position yet. Wait for a GPS fix, or go back and set the '
          'position with Preview/Set.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

/// The live reading, the hold-to-sweep button, and after release the three
/// choices.
class _BottomPanel extends StatelessWidget {
  const _BottomPanel({
    required this.liveMagneticDeg,
    required this.holding,
    required this.captured,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onHoldCancel,
    required this.onConfirm,
    required this.onRetake,
    required this.onCancel,
  });

  final double? liveMagneticDeg;
  final bool holding;
  final CapturedBearing? captured;
  final void Function(int pointer) onHoldStart;
  final void Function(int pointer) onHoldEnd;
  final void Function(int pointer) onHoldCancel;
  final VoidCallback onConfirm;
  final VoidCallback onRetake;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = Theme.of(context).extension<TriTrackColors>()!;
    final captured = this.captured;
    // The same words the Record screen's bearing box shows, so the number
    // read here is the number found there after Confirm.
    final readout = captured != null
        ? '${captured.magneticBearingDeg.round()}° ± '
              '${captured.uncertaintyDeg.round()}°'
        : liveMagneticDeg == null
        ? '—'
        : '${liveMagneticDeg!.round()}°';

    return Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                readout,
                key: const ValueKey('bearing-map-readout'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (captured != null && captured.ambiguousSweep)
                Text(
                  'Swept 180° or more, so the middle may be the wrong way '
                  'round. Retake if unsure.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              const SizedBox(height: 10),
              if (captured == null)
                _HoldButton(
                  enabled: holding || liveMagneticDeg != null,
                  holding: holding,
                  color: colors.bearingRay,
                  onStart: onHoldStart,
                  onEnd: onHoldEnd,
                  onCancel: onHoldCancel,
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('bearing-map-cancel'),
                        onPressed: onCancel,
                        child: const Text('Cancel'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton(
                        key: const ValueKey('bearing-map-retake'),
                        onPressed: onRetake,
                        child: const Text('Retake'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton(
                        key: const ValueKey('bearing-map-confirm'),
                        onPressed: onConfirm,
                        child: const Text('Confirm'),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Hold to sweep, release to stop — [RawHoldGestureDetector], which RANGE
/// (task 11.317 item 3) now also uses rather than a second copy of it.
class _HoldButton extends StatelessWidget {
  const _HoldButton({
    required this.enabled,
    required this.holding,
    required this.color,
    required this.onStart,
    required this.onEnd,
    required this.onCancel,
  });

  final bool enabled;
  final bool holding;
  final Color color;
  final void Function(int pointer) onStart;
  final void Function(int pointer) onEnd;
  final void Function(int pointer) onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final disabledColor = scheme.onSurfaceVariant.withValues(alpha: 0.7);
    return Semantics(
      button: true,
      enabled: enabled,
      label: holding ? 'Sweeping. Release to stop' : 'Hold to sweep',
      excludeSemantics: true,
      child: RawHoldGestureDetector(
        key: const ValueKey('bearing-map-hold'),
        enabled: enabled,
        onStart: onStart,
        onEnd: onEnd,
        onCancel: onCancel,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: holding ? color : null,
            border: Border.all(
              color: enabled ? color : disabledColor,
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(28),
          ),
          child: Text(
            holding ? 'SWEEPING — release to stop' : 'HOLD TO SWEEP',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: holding
                  ? Colors.white
                  : (enabled ? color : disabledColor),
            ),
          ),
        ),
      ),
    );
  }
}
